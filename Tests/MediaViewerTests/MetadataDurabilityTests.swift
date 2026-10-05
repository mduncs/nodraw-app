import XCTest
import GRDB
import Darwin
import Yams
@testable import MediaViewer

/// These exercise production migrations, mutations, queue, and publisher with
/// disposable databases/sidecars. No app process or live archive is involved.
final class MetadataDurabilityTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var item: MediaItem!

    override func setUp() async throws {
        directory = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("metadata-durability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        let sidecar = directory.appendingPathComponent("item.md")
        try "---\nsource: https://example.com/item\nplatform: test\ntags: []\nnotes: base\nunknown:\n  unicode: 雪\n---\nBody stays **exact**.\n".write(to: sidecar, atomically: false, encoding: .utf8)
        let media = directory.appendingPathComponent("item.jpg")
        try Data([1]).write(to: media)
        item = MediaItem(id: UUID(), basePath: directory, metadataFile: sidecar, mediaFiles: [media], metadata: MediaMetadata(source: URL(string: "https://example.com/item")!, platform: "test", notes: "base"))
        let record = MediaItemRecord(from: item)
        try await database.write { db in try record.insert(db) }
    }

    override func tearDown() async throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func setNotes(_ notes: String) async throws {
        let id = item.id.uuidString
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET notes = ? WHERE id = ?", arguments: [notes, id])
        }
    }

    private func yaml() throws -> [String: Any] {
        let content = try String(contentsOf: item.metadataFile, encoding: .utf8)
        return try XCTUnwrap(Yams.load(yaml: FrontmatterWriter.parseBoundaries(content).yamlText) as? [String: Any])
    }

    private func importSidecar(_ fields: String) async throws {
        try "---\nsource: https://example.com/item\n\(fields)\n---\nBody stays **exact**.\n".write(to: item.metadataFile, atomically: false, encoding: .utf8)
        item.metadata = try MetadataParser.parse(fileAt: item.metadataFile)
        let record = MediaItemRecord(from: item)
        try await database.write { db in
            try MetadataOutbox.importing(in: db) { try record.update(db) }
        }
    }

    func testProjectionEditsDescriptionBackedNotesWithoutConflict() async throws {
        try await importSidecar("description: captured description")
        try await setNotes("edited note")
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        let pending = try await queue.statuses()
        XCTAssertEqual(pending.first?.baseJSON, "\"captured description\"")
        await queue.flushNow()
        let remaining = try await queue.statuses()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(try MetadataParser.parse(fileAt: item.metadataFile).notes, "edited note")
        XCTAssertEqual(try yaml()["description"] as? String, "captured description")
    }

    func testProjectionEditsCommaSeparatedTagsWithoutConflict() async throws {
        try await importSidecar("tags: ' one, 雪, , two '")
        let id = item.id.uuidString
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?", arguments: ["[\"new\"]", id])
        }
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        let pending = try await queue.statuses()
        XCTAssertEqual(pending.first?.baseJSON, "[\"one\",\"雪\",\"two\"]")
        await queue.flushNow()
        let remaining = try await queue.statuses()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(try MetadataParser.parse(fileAt: item.metadataFile).tags, ["new"])
    }

    func testProjectionClearsNotesWithoutExposingDescription() async throws {
        try await importSidecar("notes: base\ndescription: captured description")
        try await setNotes("")
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        await queue.flushNow()
        XCTAssertEqual(try yaml()["notes"] as? String, "")
        XCTAssertEqual(try MetadataParser.parse(fileAt: item.metadataFile).notes, "")
        XCTAssertEqual(try yaml()["description"] as? String, "captured description")
    }

    func testProjectionUnstarsWithoutExposingFavorite() async throws {
        try await importSidecar("starred: true\nfavorite: true")
        let id = item.id.uuidString
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET starred = 0 WHERE id = ?", arguments: [id])
        }
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        await queue.flushNow()
        XCTAssertEqual(try yaml()["starred"] as? Bool, false)
        XCTAssertFalse(try MetadataParser.parse(fileAt: item.metadataFile).starred)
        XCTAssertEqual(try yaml()["favorite"] as? Bool, true)
    }

    func testProjectionUnstarsFavoriteBackedValueWithoutConflict() async throws {
        try await importSidecar("favorite: true")
        let id = item.id.uuidString
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET starred = 0 WHERE id = ?", arguments: [id])
        }
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        let pending = try await queue.statuses()
        XCTAssertEqual(pending.first?.baseJSON, "true")
        await queue.flushNow()
        let remaining = try await queue.statuses()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(try MetadataParser.parse(fileAt: item.metadataFile).starred)
        XCTAssertEqual(try yaml()["favorite"] as? Bool, true)
    }

    func testProjectionEditsTrimmedListTagsWithoutConflict() async throws {
        try await importSidecar("tags: [' one ', ' 雪 ']")
        let id = item.id.uuidString
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?", arguments: ["[\"new\"]", id])
        }
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        await queue.flushNow()
        let remaining = try await queue.statuses()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(try MetadataParser.parse(fileAt: item.metadataFile).tags, ["new"])
    }

    func testProjectionClearsKeysWithoutAliases() async throws {
        try await importSidecar("notes: base\nstarred: true\ndeleted: true\nannotated: false")
        let id = item.id.uuidString
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET notes = NULL, starred = 0, deletedAt = NULL WHERE id = ?", arguments: [id])
        }
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        await queue.flushNow()
        let values = try yaml()
        XCTAssertNil(values["notes"])
        XCTAssertNil(values["starred"])
        XCTAssertNil(values["deleted"])
        XCTAssertNil(try MetadataParser.parse(fileAt: item.metadataFile).notes)
        XCTAssertFalse(try MetadataParser.parse(fileAt: item.metadataFile).starred)
    }

    func testCommittedMutationWithoutEnqueueSurvivesRestartAndInflightRecovery() async throws {
        try await setNotes("durable before wake")
        try await database.write { db in try db.execute(sql: "UPDATE metadata_outbox SET state = 'inFlight'") }
        // New DatabaseManager/queue models a restart before any file IO completed.
        let reopened = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        try await reopened.initialize()
        let queue = WriteBackQueue(database: reopened, selfWriteTracker: SelfWriteTracker())
        let pending = await queue.isPending(item.id)
        XCTAssertTrue(pending)
        await queue.flushNow()
        XCTAssertEqual(try yaml()["notes"] as? String, "durable before wake")
        let after = await queue.isPending(item.id)
        XCTAssertFalse(after)
    }

    func testProjectionBeforeDatabaseInitializationIsDeferredAndResumesAutomatically() async throws {
        try await setNotes("waiting for database")
        let reopened = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let queue = WriteBackQueue(database: reopened, selfWriteTracker: SelfWriteTracker())

        await queue.resume()
        await queue.enqueue(item.id)
        await queue.retry()
        // This returns while the DB is unopened; it must not drop the durable intent.
        await queue.flushNow()
        XCTAssertEqual(try yaml()["notes"] as? String, "base")

        try await reopened.initialize()
        // No enqueue or explicit flush after initialization: the deferred wake survives.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let statuses = try await queue.statuses()
            if statuses.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pending = try await queue.statuses()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(try yaml()["notes"] as? String, "waiting for database")
    }

    func testDatabaseReadinessSurvivesInitializationFailureAndRetry() async throws {
        let support = directory.appendingPathComponent("delayed-support", isDirectory: true)
        let unopened = DatabaseManager(databaseURL: support.appendingPathComponent("test.sqlite"))
        let readiness = Task { await unopened.waitUntilInitialized() }
        do {
            try await unopened.initialize()
            XCTFail("Expected opening a database in a missing directory to fail")
        } catch {}

        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try await unopened.initialize()
        let ready = await readiness.value
        XCTAssertTrue(ready)
    }

    func testMutationRollbackAlsoRollsBackIntent() async throws {
        enum Expected: Error { case rollback }
        let id = item.id.uuidString
        do {
            try await database.write { db in
                try db.execute(sql: "UPDATE media_items SET notes = 'uncommitted' WHERE id = ?", arguments: [id])
                throw Expected.rollback
            }
            XCTFail("Expected rollback")
        } catch Expected.rollback {}
        let count = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metadata_outbox") }
        XCTAssertEqual(count, 0)
    }

    func testRestartAfterFilePublicationBeforeAcknowledgementIsIdempotent() async throws {
        try await setNotes("published before crash")
        try FrontmatterWriter.processFrontmatter(at: item.metadataFile) { $0["notes"] = "published before crash" }
        try await database.write { db in try db.execute(sql: "UPDATE metadata_outbox SET state = 'inFlight'") }
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        await queue.flushNow()
        let final = try await queue.statuses()
        XCTAssertTrue(final.isEmpty)
        XCTAssertEqual(try yaml()["notes"] as? String, "published before crash")
    }

    func testAnnotationRecordMutationPersistsFlagWithoutEnqueue() async throws {
        let record = AnnotationRecord(itemId: item.id, mediaFileIndex: 0, annotationSet: .empty)
        try await database.write { db in try record.upsert(db: db) }
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        let pending = try await queue.statuses()
        XCTAssertEqual(pending.map(\.field), ["annotated"])
        await queue.flushNow()
        XCTAssertEqual(try yaml()["annotated"] as? Bool, true)
        let id = item.id
        try await database.write { db in try AnnotationRecord.deleteAll(db: db, itemId: id) }
        await queue.flushNow()
        XCTAssertNil(try yaml()["annotated"])
    }

    func testMissingSidecarRetainsIntentThenRetries() async throws {
        let original = try Data(contentsOf: item.metadataFile)
        try await setNotes("survives missing file")
        try FileManager.default.removeItem(at: item.metadataFile)
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        await queue.flushNow()
        let failed = try await queue.statuses(itemID: item.id)
        XCTAssertEqual(failed.first?.state, "retry")
        XCTAssertNotNil(failed.first?.error)
        try original.write(to: item.metadataFile)
        await queue.flushNow()
        XCTAssertEqual(try yaml()["notes"] as? String, "survives missing file")
    }

    func testWatcherDeletionCannotCascadeDeletePendingIntent() async throws {
        try await setNotes("must survive missing sidecar event")
        try FileManager.default.removeItem(at: item.metadataFile)
        let store = MediaStore(database: database)
        try await store.deleteItem(id: item.id, preservePendingMetadata: true)
        let retained = try await store.fetchItem(id: item.id)
        XCTAssertEqual(retained?.metadata.notes, "must survive missing sidecar event")
        let pending = await store.writeBackQueue.isPending(item.id)
        XCTAssertTrue(pending)
    }

    func testFilesystemFailureRetainsIntentThenRetries() async throws {
        let lock = directory.appendingPathComponent(".item.md.nodraw-lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        try await setNotes("survives IO failure")
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        await queue.flushNow()
        XCTAssertEqual(try yaml()["notes"] as? String, "base")
        let failed = try await queue.statuses()
        XCTAssertEqual(failed.first?.state, "retry")
        try FileManager.default.removeItem(at: lock)
        await queue.flushNow()
        XCTAssertEqual(try yaml()["notes"] as? String, "survives IO failure")
    }

    func testDisjointWriterMergesAndSameFieldConflictKeepsBothValues() async throws {
        try await setNotes("local notes")
        try FrontmatterWriter.processFrontmatter(at: item.metadataFile) { $0["tags"] = ["external", "雪"] }
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        await queue.flushNow()
        XCTAssertEqual(try yaml()["notes"] as? String, "local notes")
        XCTAssertEqual(try yaml()["tags"] as? [String], ["external", "雪"])
        try await setNotes("second local")
        try FrontmatterWriter.processFrontmatter(at: item.metadataFile) { $0["notes"] = "remote notes" }
        await queue.flushNow()
        XCTAssertEqual(try yaml()["notes"] as? String, "remote notes")
        let conflicts = try await queue.statuses(itemID: item.id)
        let conflict = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(conflict.state, "conflict")
        XCTAssertEqual(conflict.desiredJSON, "\"second local\"")
        XCTAssertEqual(conflict.externalJSON, "\"remote notes\"")
        try await queue.resolveConflict(itemID: item.id, field: "notes", revision: conflict.revision, keepLocal: true)
        await queue.flushNow()
        XCTAssertEqual(try yaml()["notes"] as? String, "second local")
        let retained = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metadata_projection_conflicts") }
        XCTAssertEqual(retained, 1)
    }

    func testNewerMutationDuringActualOlderFlushCannotBeAcknowledgedAway() async throws {
        try await setNotes("older")
        let lockPath = directory.appendingPathComponent(".item.md.nodraw-lock").path
        let lock = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(lock, 0)
        XCTAssertEqual(flock(lock, LOCK_EX), 0)
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        let flush = Task { await queue.flushNow() }
        var sawInflight = false
        for _ in 0..<200 {
            if try await queue.statuses().first?.state == "inFlight" { sawInflight = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(sawInflight)
        try await setNotes("newer")
        XCTAssertEqual(flock(lock, LOCK_UN), 0)
        await flush.value
        XCTAssertEqual(try yaml()["notes"] as? String, "older")
        let remaining = try await queue.statuses()
        XCTAssertEqual(remaining.first?.state, "pending")
        XCTAssertEqual(remaining.first?.baseJSON, "\"older\"")
        XCTAssertEqual(remaining.first?.desiredJSON, "\"newer\"")
        await queue.flushNow()
        XCTAssertEqual(try yaml()["notes"] as? String, "newer")
        let final = await queue.isPending(item.id)
        XCTAssertFalse(final)
    }

    func testConflictResolutionDoesNotApproveAnUnseenExternalVersion() async throws {
        try await setNotes("local")
        try FrontmatterWriter.processFrontmatter(at: item.metadataFile) { $0["notes"] = "external shown" }
        let queue = WriteBackQueue(database: database, selfWriteTracker: SelfWriteTracker())
        await queue.flushNow()
        let shownRows = try await queue.statuses()
        let shown = try XCTUnwrap(shownRows.first)
        try FrontmatterWriter.processFrontmatter(at: item.metadataFile) { $0["notes"] = "external unseen" }
        try await queue.resolveConflict(itemID: item.id, field: "notes", revision: shown.revision, keepLocal: true)
        await queue.flushNow()
        XCTAssertEqual(try yaml()["notes"] as? String, "external unseen")
        let remaining = try await queue.statuses()
        XCTAssertEqual(remaining.first?.state, "conflict")
        XCTAssertGreaterThan(remaining.first?.revision ?? 0, shown.revision)
        XCTAssertEqual(remaining.first?.externalJSON, "\"external unseen\"")
    }

    func testWatcherImportPreservesPendingFieldsAndDoesNotCreateWriteLoop() async throws {
        let store = MediaStore(database: database)
        try await store.updateNotes(id: item.id, notes: "local pending")
        try FrontmatterWriter.processFrontmatter(at: item.metadataFile) { $0["tags"] = ["external"] }
        // Deliberately use a stale snapshot; source acceptance reads latest file.
        try await store.updateItem(item, source: .sidecar)
        let fetched = try await store.fetchItem(id: item.id)
        XCTAssertEqual(fetched?.metadata.notes, "local pending")
        XCTAssertEqual(fetched?.metadata.tags, ["external"])
        let pending = try await store.writeBackQueue.statuses()
        XCTAssertEqual(pending.map(\.field), ["notes"])
        await store.writeBackQueue.flushNow()
        try await store.updateItem(item, source: .sidecar)
        let finalItem = try await store.fetchItem(id: item.id)
        XCTAssertEqual(finalItem?.metadata.notes, "local pending")
        let final = try await store.writeBackQueue.statuses()
        XCTAssertTrue(final.isEmpty)
        let importing = try await database.read { db in try Int.fetchOne(db, sql: "SELECT importing FROM metadata_projection_context") }
        XCTAssertEqual(importing, 0)
    }

    func testAtomicWriterPreservesUnicodeCRLFBodyUnknownKeysAndFinderMetadata() throws {
        let content = "---\r\nnotes: |\r\n  old line\r\n  雪\r\ntags:\r\n  - one\r\nunknown:\r\n  nested: [雪, two]\r\n---\r\nBody\r\n---\r\nEnd\r\n"
        try content.write(to: item.metadataFile, atomically: false, encoding: .utf8)
        let attribute = "com.apple.metadata:kMDItemDateAdded"
        let value = Data("finder-date-added-fixture".utf8)
        let result = value.withUnsafeBytes { Darwin.setxattr(item.metadataFile.path, attribute, $0.baseAddress, value.count, 0, 0) }
        XCTAssertEqual(result, 0)
        try FrontmatterWriter.processFrontmatter(at: item.metadataFile) { $0["notes"] = "new\n多行" }
        let updated = try String(contentsOf: item.metadataFile, encoding: .utf8)
        XCTAssertTrue(updated.hasSuffix("---\r\nBody\r\n---\r\nEnd\r\n"))
        XCTAssertEqual(try yaml()["notes"] as? String, "new\n多行")
        XCTAssertNotNil(try yaml()["unknown"] as? [String: Any])
        var bytes = [UInt8](repeating: 0, count: 128)
        let length = Darwin.getxattr(item.metadataFile.path, attribute, &bytes, bytes.count, 0, 0)
        XCTAssertEqual(Data(bytes.prefix(max(0, length))), value)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(".item.md.nodraw-previous"), encoding: .utf8), content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".item.md.nodraw-lock").path))
    }

    func testSelfWriteReceiptDetectsImmediateExternalChange() async throws {
        let tracker = SelfWriteTracker()
        let content = try String(contentsOf: item.metadataFile, encoding: .utf8)
        await tracker.markPublished(item.metadataFile.path, content: content)
        let before = await tracker.shouldSkip(item.metadataFile.path)
        XCTAssertTrue(before)
        try (content + "External change").write(to: item.metadataFile, atomically: false, encoding: .utf8)
        let after = await tracker.shouldSkip(item.metadataFile.path)
        XCTAssertFalse(after)
    }

    func testNoncooperatingEditorChangeAbortsPublication() throws {
        let path: URL = item.metadataFile
        let external = "---\nnotes: external\n---\nBody from editor\n"
        XCTAssertThrowsError(try FrontmatterWriter.processFrontmatter(at: path) { yaml in
            yaml["notes"] = "local"
            // Simulates an editor that writes while the shared flock is held.
            try external.write(to: path, atomically: false, encoding: .utf8)
        })
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), external)
    }
}
