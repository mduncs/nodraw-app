import XCTest
import Combine
import GRDB
@testable import MediaViewer

final class StartupScanBatchTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("startup-batch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: root)
    }

    func testPhaseLabelsAndFractionsDescribeTheirOwnWork() {
        let parsing = InitializationPhase.parsingMetadata(current: 50, total: 525)
        let updating = InitializationPhase.updatingChangedItems(current: 312, total: 525)
        XCTAssertEqual(parsing.displayText, "Reading metadata… 50/525")
        XCTAssertEqual(updating.displayText, "Updating 525 changed items… 312/525")
        XCTAssertEqual(updating.progressFraction!, 312.0 / 525.0, accuracy: 0.0001)
        XCTAssertNil(InitializationPhase.preparingArchive.progressFraction)
        XCTAssertNil(InitializationPhase.reconcilingArchive.progressFraction)
        XCTAssertEqual(InitializationPhase.generatingSidecars(current: 3, total: 7).displayText, "Creating metadata… 3/7")
        XCTAssertEqual(InitializationPhase.insertingItems(total: 42).displayText, "Adding 42 new items…")
    }

    @MainActor
    func testChangedItemProgressAdvancesPerCommittedBatchAndBackgroundKeepsPhase() async throws {
        let fixture = try makeFixture(count: 525)
        let database = try await seededDatabase(name: "progress", records: fixture.records)
        let coordinator = AppCoordinator(database: database, archivePath: root)
        let states = try await (await coordinator.getMediaStore()).fetchStartupScanStates()
        let changes = try fixture.parsed.map { parsed in
            (parsed: parsed, state: try XCTUnwrap(states[parsed.metadataFile.path]))
        }
        var phases: [InitializationPhase] = []
        let subscription = coordinator.phase.sink { phases.append($0) }
        defer { subscription.cancel() }

        try await coordinator.applyChangedScannedItems(changes, reportsProgress: true)
        XCTAssertEqual(phases, [
            .notStarted,
            .updatingChangedItems(current: 0, total: 525),
            .updatingChangedItems(current: 150, total: 525),
            .updatingChangedItems(current: 300, total: 525),
            .updatingChangedItems(current: 450, total: 525),
            .reconcilingArchive
        ])
        phases.removeAll()
        try await coordinator.applyChangedScannedItems(changes)
        XCTAssertTrue(phases.isEmpty)
    }

    @MainActor
    func testBatchMatchesPerItemRowsAndMeasures525ChangedItems() async throws {
        let fixture = try makeFixture(count: 525)
        let perItemDB = try await seededDatabase(name: "per-item", records: fixture.records)
        let batchDB = try await seededDatabase(name: "batch", records: fixture.records)
        let perItemStore = MediaStore(database: perItemDB)
        let batchStore = MediaStore(database: batchDB)
        var perItemNotifications = 0
        var batchNotifications = 0
        let perItemSubscription = perItemStore.changes.sink { perItemNotifications += 1 }
        let batchSubscription = batchStore.changes.sink { batchNotifications += 1 }
        defer { perItemSubscription.cancel(); batchSubscription.cancel() }

        let before = ContinuousClock.now
        for parsed in fixture.parsed {
            let fetched = try await perItemStore.fetchItem(id: parsed.id)
            let existing = try XCTUnwrap(fetched)
            let updated = AppCoordinator.changedScannedItem(parsed, preserving: existing)
            try await perItemStore.updateItem(updated, source: .sidecar)
        }
        let perItemDuration = before.duration(to: .now)
        let batchStart = ContinuousClock.now
        for start in stride(from: 0, to: fixture.parsed.count, by: 150) {
            let end = min(start + 150, fixture.parsed.count)
            try await batchStore.updateChangedScannedItemsBatch(fixture.parsed[start..<end].map { ($0, $0.id) })
        }
        let batchDuration = batchStart.duration(to: .now)
        let tables = ["media_items", "media_tags", "media_colors", "archive_scan_cache", "media_items_fts", "metadata_outbox", "metadata_projection_clock", "media_file_ocr", "media_attributes", "video_segments", "transcript_segments", "item_assets"]
        for table in tables {
            let perItemRows = try await rows(in: perItemDB, table: table)
            let batchRows = try await rows(in: batchDB, table: table)
            XCTAssertEqual(batchRows, perItemRows, table)
        }
        XCTAssertEqual(perItemNotifications, 525)
        XCTAssertEqual(batchNotifications, 4)
        let activeCount = try await batchDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE deletedAt IS NULL")
        }
        XCTAssertEqual(activeCount, 132)
        print("STARTUP_BATCH_BENCHMARK items=525 perItem=\(perItemDuration) batch=\(batchDuration) transactions=525->4 notifications=\(perItemNotifications)->\(batchNotifications)")
    }

    func testFailedBatchRollsBackAndMissingIDsAreSkipped() async throws {
        let fixture = try makeFixture(count: 3)
        let database = try await seededDatabase(name: "rollback", records: fixture.records)
        let store = MediaStore(database: database)
        let before = try await rows(in: database, table: "media_items")
        try FileManager.default.removeItem(at: fixture.parsed[1].metadataFile)
        do {
            try await store.updateChangedScannedItemsBatch(fixture.parsed.map { ($0, $0.id) })
            XCTFail("Unreadable sidecar must fail the batch")
        } catch {}
        let after = try await rows(in: database, table: "media_items")
        XCTAssertEqual(after, before)
        try await store.updateChangedScannedItemsBatch([(fixture.parsed[0], UUID())])
        let afterMissing = try await rows(in: database, table: "media_items")
        XCTAssertEqual(afterMissing, before)
    }

    func testCoordinatorFailureRetainsPerItemPrefixCommits() async throws {
        let fixture = try makeFixture(count: 3)
        let database = try await seededDatabase(name: "prefix", records: fixture.records)
        let coordinator = AppCoordinator(database: database, archivePath: root)
        let store = await coordinator.getMediaStore()
        let states = try await store.fetchStartupScanStates()
        let changes = try fixture.parsed.map { parsed in
            (parsed: parsed, state: try XCTUnwrap(states[parsed.metadataFile.path]))
        }
        try FileManager.default.removeItem(at: fixture.parsed[1].metadataFile)
        do {
            try await coordinator.applyChangedScannedItems(changes)
            XCTFail("Unreadable sidecar must stop the update")
        } catch {}
        let first = try await store.fetchItem(id: fixture.parsed[0].id)
        let last = try await store.fetchItem(id: fixture.parsed[2].id)
        XCTAssertEqual(first?.contextImage, fixture.parsed[0].contextImage)
        XCTAssertNil(last?.contextImage)
    }

    @MainActor
    func testCancellationStopsBeforeNextBatch() async throws {
        let fixture = try makeFixture(count: 301)
        let database = try await seededDatabase(name: "cancellation", records: fixture.records)
        let coordinator = AppCoordinator(database: database, archivePath: root)
        let store = await coordinator.getMediaStore()
        let states = try await store.fetchStartupScanStates()
        let changes = try fixture.parsed.map { parsed in
            (parsed: parsed, state: try XCTUnwrap(states[parsed.metadataFile.path]))
        }
        var task: Task<Void, Error>?
        let subscription = coordinator.phase.sink { phase in
            if phase == .updatingChangedItems(current: 150, total: 301) { task?.cancel() }
        }
        defer { subscription.cancel() }
        task = Task { try await coordinator.applyChangedScannedItems(changes, reportsProgress: true) }
        do {
            try await task!.value
            XCTFail("Canceled scan must stop before the next transaction")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let changedCount = try await database.read { db in
            // Combined rows retain their file paths, but still import source metadata.
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE sourceURL LIKE 'https://example.com/changed/%'")
        }
        XCTAssertEqual(changedCount, 150)
    }

    private func rows(in database: DatabaseManager, table: String) async throws -> [Row] {
        try await database.read { db in
            // New asset UUIDs are intentionally random; compare their stable roles,
            // paths and availability while child rows retain the seeded identities.
            let columns = table == "item_assets"
                ? "item_id, path, role, position, is_current, fingerprint, availability, retirement_reason" : "*"
            return try Row.fetchAll(db, sql: "SELECT \(columns) FROM \(table) ORDER BY 1, 2")
        }
    }

    private func seededDatabase(name: String, records: [MediaItemRecord]) async throws -> DatabaseManager {
        let database = DatabaseManager(databaseURL: root.appendingPathComponent("\(name).sqlite"))
        try await database.initialize()
        try await database.write { db in
            for record in records {
                try record.insertWithFTSSync(db: db)
                try db.execute(sql: "UPDATE item_assets SET asset_id = item_id WHERE item_id = ?", arguments: [record.id.uuidString])
                let mediaPath = try JSONDecoder().decode([String].self, from: Data(record.mediaFilesJSON.utf8))[0]
                try MediaFileOCRRecord(id: record.id, itemId: record.id, fileURL: mediaPath, fileIndex: 0, ocrText: "per-file OCR").insert(db)
                try db.execute(sql: "INSERT INTO media_attributes(item_id, module, key, value, version) VALUES (?, 'aesthetic', 'score', 0.7, 1)", arguments: [record.id.uuidString])
                try db.execute(sql: """
                    INSERT INTO video_segments(id, item_id, source_path, start_time, end_time, summary, created_at, updated_at)
                    VALUES (?, ?, ?, 0, 1, 'retained video', '2026-01-01', '2026-01-01')
                    """, arguments: [record.id.uuidString, record.id.uuidString, mediaPath])
                try db.execute(sql: """
                    INSERT INTO transcript_segments(id, item_id, source_path, start_time, end_time, text, created_at, updated_at)
                    VALUES (?, ?, ?, 0, 1, 'retained transcript', '2026-01-01', '2026-01-01')
                    """, arguments: [record.id.uuidString, record.id.uuidString, mediaPath])
            }
            // Conflicted intent is still protected from external edits, and stays
            // untouched by the autonomous projector throughout the timing run.
            for (field, desired) in [("tags", "[\"local\"]"), ("notes", "\"local notes\""), ("starred", "true"), ("deleted", "false")] {
                try db.execute(sql: """
                    INSERT INTO metadata_outbox(itemID, field, revision, baseJSON, desiredJSON, state)
                    VALUES (?, ?, 1, 'null', ?, 'conflict')
                    """, arguments: [records[0].id.uuidString, field, desired])
            }
        }
        return database
    }

    private func makeFixture(count: Int) throws -> (records: [MediaItemRecord], parsed: [MediaItem]) {
        let archive = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        var records: [MediaItemRecord] = []
        var parsed: [MediaItem] = []
        for index in 0..<count {
            let media = archive.appendingPathComponent("item-\(index).png")
            let context = archive.appendingPathComponent("item-\(index).context.png")
            let sidecar = archive.appendingPathComponent("item-\(index).md")
            try ImportDurabilityTests.png.write(to: media)
            try ImportDurabilityTests.png.write(to: context)
            try "---\nsource: https://example.com/changed/\(index)\nplatform: test\narchived: 2026-01-11T12:00:00Z\ntags: [external]\nnotes: updated notes\n---\n".write(to: sidecar, atomically: true, encoding: .utf8)
            let metadata = MediaMetadata(source: URL(string: "https://example.com/original/\(index)")!, platform: "test", archivedDate: Date(timeIntervalSince1970: 1_700_000_000), tags: ["original"], notes: "old notes")
            let existing = MediaItem(id: UUID(), basePath: archive, metadataFile: sidecar, mediaFiles: [media], metadata: metadata,
                                     indexedContent: IndexedContent(ocrText: "retained OCR \(index)"), aspectRatio: 1,
                                     generatedCaption: "retained caption", pipelineStatus: "complete",
                                     videoUnderstandingStatus: "failed", videoUnderstandingRetryCount: 3,
                                     transcriptionStatus: "complete", transcriptionVersion: 7)
            var record = MediaItemRecord(from: existing)
            if index % 4 != 0 {
                record.deletedAt = Date(timeIntervalSince1970: 1_710_000_000)
                record.deletionReason = index % 4 == 1 ? MediaItemDeletionReason.combined.rawValue
                    : index % 4 == 2 ? MediaItemDeletionReason.contextReattached.rawValue : MediaItemDeletionReason.user.rawValue
            }
            records.append(record)
            parsed.append(MediaItem(id: existing.id, basePath: archive, metadataFile: sidecar, mediaFiles: [media], contextImage: context,
                                    metadata: try MetadataParser.parse(fileAt: sidecar), aspectRatio: 2))
        }
        return (records, parsed)
    }
}
