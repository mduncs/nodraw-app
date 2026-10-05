import XCTest
import GRDB
@testable import MediaViewer

final class ItemAssetDurabilityTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("asset-durability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: directory.appendingPathComponent("assets.sqlite"))
        try await database.initialize()
        store = MediaStore(database: database)
    }

    override func tearDown() async throws {
        store = nil
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeItem(_ name: String, count: Int = 2, contextOnly: Bool = false) async throws -> MediaItem {
        let folder = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sidecar = folder.appendingPathComponent("item.md")
        try "---\nsource: https://example.com/\(name)\nplatform: test\ntags: []\n---\n".write(to: sidecar, atomically: false, encoding: .utf8)
        var files: [URL] = []
        for index in 0..<count {
            let file = folder.appendingPathComponent("\(index).jpg")
            try Data("same fixture bytes".utf8).write(to: file)
            files.append(file)
        }
        let item = MediaItem(id: UUID(), basePath: folder, metadataFile: sidecar, mediaFiles: contextOnly ? [] : files, contextImage: contextOnly ? files.first : nil, metadata: MediaMetadata(source: URL(string: "https://example.com/\(name)")!, platform: "test"))
        try await store.insertItem(item)
        let fetched = try await store.fetchItem(id: item.id)
        return try XCTUnwrap(fetched)
    }

    private func seedDependencies(_ item: MediaItem) async throws {
        let records = item.assets.map { asset -> (AnnotationRecord, MediaFileOCRRecord, VideoSegmentRecord, TranscriptSegmentRecord) in
            var annotation = AnnotationSet.empty
            annotation.addShape(.text(id: UUID(), position: NormalizedPoint(x: 0.2, y: 0.3), content: "annotation-\(asset.order)", style: .default))
            let video = VideoSegment(id: UUID(), itemId: item.id, mediaFileIndex: asset.order, sourcePath: asset.url.path, startTime: 0, endTime: 1, summary: "video-\(asset.order)", labels: [], confidence: 1, analysisSource: "fixture", version: 1)
            let transcript = TranscriptSegment(id: UUID(), itemId: item.id, mediaFileIndex: asset.order, sourcePath: asset.url.path, startTime: 0, endTime: 1, text: "transcript-\(asset.order)", confidence: 1, language: "en", model: "fixture", version: 1)
            return (
                AnnotationRecord(itemId: item.id, mediaFileIndex: asset.order, annotationSet: annotation, assetID: asset.assetID),
                MediaFileOCRRecord(itemId: item.id, fileURL: asset.url.path, fileIndex: asset.order, ocrText: "ocr-\(asset.order)", assetID: asset.assetID),
                VideoSegmentRecord(segment: video, assetID: asset.assetID),
                TranscriptSegmentRecord(segment: transcript, assetID: asset.assetID)
            )
        }
        try await database.write { db in
            for record in records {
                try record.0.upsert(db: db)
                try record.1.upsert(db: db)
                try record.2.insert(db)
                try record.3.insert(db)
            }
        }
    }

    func testReorderPreservesAllFourAssociationKindsAndIDs() async throws {
        let item = try await makeItem("reorder")
        try await seedDependencies(item)
        let original = item.assets.sorted { $0.order < $1.order }
        try await store.reorderAssets(itemID: item.id, orderedAssetIDs: original.reversed().map(\.assetID))
        let fetched = try await store.fetchItem(id: item.id)
        let reordered = try XCTUnwrap(fetched)
        XCTAssertEqual(reordered.assets.map(\.assetID), original.reversed().map(\.assetID))
        XCTAssertEqual(reordered.mediaFiles, original.reversed().map(\.url))
        XCTAssertEqual(reordered.perFileOCR[0]?.ocrText, "ocr-1")
        XCTAssertEqual(reordered.videoSegments.first?.summary, "video-1")
        XCTAssertEqual(reordered.transcriptSegments.first?.text, "transcript-1")
        let id = item.id
        let annotation = try await database.read { db in try AnnotationRecord.fetch(db: db, itemId: id, mediaFileIndex: 0) }
        XCTAssertEqual(annotation?.assetID, original[1].assetID)
        XCTAssertTrue(annotation?.annotationsJSON.contains("annotation-1") == true)
    }

    func testRemovalKeepsRemovedDataRecoverableAndRemapsSurvivorAtomically() async throws {
        let item = try await makeItem("remove")
        try await seedDependencies(item)
        let assets = item.assets.sorted { $0.order < $1.order }
        let updated = try await store.removeAsset(itemID: item.id, assetID: assets[0].assetID)
        XCTAssertEqual(updated.assets.map(\.assetID), [assets[1].assetID])
        XCTAssertEqual(updated.perFileOCR[0]?.ocrText, "ocr-1")
        let id = item.id
        let issues = try await database.read { db in try ItemAssetStore.issues(in: db, itemID: id) }
        XCTAssertEqual(issues.count, 4)
        XCTAssertTrue(issues.allSatisfy { $0.reason == "removed" })
        let retained = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM annotations WHERE itemId = ?", arguments: [id.uuidString]) }
        XCTAssertEqual(retained, 2)
        // Compatibility adapter must not shift a second time.
        try await store.reindexPerFileData(itemID: item.id, removedIndex: 0)
        let afterAdapter = try await store.fetchItem(id: item.id)
        XCTAssertEqual(afterAdapter?.perFileOCR[0]?.ocrText, "ocr-1")
    }

    func testSamePathReplacementRetiresIdentityAndRejectsStaleAnalysis() async throws {
        let item = try await makeItem("replace", count: 1)
        try await seedDependencies(item)
        let asset = try XCTUnwrap(item.assets.first)
        try Data("a replacement with different bytes and length".utf8).write(to: asset.url, options: .atomic)
        try await store.refreshAssets(itemID: item.id)
        let refreshed = try await store.fetchAssets(itemID: item.id)
        XCTAssertNotEqual(refreshed.first?.assetID, asset.assetID)
        let stale = MediaFileOCRRecord(itemId: item.id, fileURL: asset.url.path, fileIndex: 0, ocrText: "stale analysis", assetID: asset.assetID)
        do {
            try await database.write { db in try stale.upsert(db: db) }
            XCTFail("Stale asset must not attach to replacement")
        } catch ItemAssetStore.AssociationError.staleAsset {}
        let fetched = try await store.fetchItem(id: item.id)
        XCTAssertTrue(fetched?.perFileOCR.isEmpty == true)
        XCTAssertTrue(fetched?.videoSegments.isEmpty == true)
        let id = item.id
        let issues = try await database.read { db in try ItemAssetStore.issues(in: db, itemID: id) }
        XCTAssertEqual(issues.count, 4)
        XCTAssertTrue(issues.allSatisfy { $0.reason == "replacement" })
    }

    /// Pins the file's times to whole seconds (as downloads and copies carry them) and re-reads
    /// its fingerprint, so a later times-preserving copy reproduces the stat evidence exactly.
    private func makeSettledItem(_ name: String) async throws -> MediaItem {
        let item = try await makeItem(name, count: 1)
        let url = try XCTUnwrap(item.assets.first).url
        let settled = Date(timeIntervalSince1970: 1_765_932_654)
        try FileManager.default.setAttributes([.modificationDate: settled, .creationDate: settled], ofItemAtPath: url.path)
        try await store.refreshAssets(itemID: item.id)
        let fetched = try await store.fetchItem(id: item.id)
        let current = try XCTUnwrap(fetched)
        try await seedDependencies(current)
        let id = current.id.uuidString
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET ocrText = 'the leopard shall lie down with the kid' WHERE id = ?", arguments: [id])
        }
        let seeded = try await store.fetchItem(id: current.id)
        return try XCTUnwrap(seeded)
    }

    private func leopardMatches() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items_fts WHERE media_items_fts MATCH 'leopard'") ?? 0
        }
    }

    func testTimesPreservingCopyKeepsIdentityAndOCRThroughMetadataEdit() async throws {
        let item = try await makeSettledItem("copied")
        let asset = try XCTUnwrap(item.assets.first)
        let before = try await leopardMatches()
        XCTAssertEqual(before, 1)

        // A backup restore / drive migration / demo snapshot: same bytes and times, new inode.
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: asset.url.path)
        let parked = directory.appendingPathComponent("parked-original.jpg")
        try fm.moveItem(at: asset.url, to: parked)
        try fm.copyItem(at: parked, to: asset.url)
        try fm.setAttributes([.modificationDate: attributes[.modificationDate]!, .creationDate: attributes[.creationDate]!], ofItemAtPath: asset.url.path)
        let copied = try fm.attributesOfItem(atPath: asset.url.path)
        XCTAssertNotEqual(copied[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber, "precondition: the copy has a new inode")

        // Any full-row metadata write (tag add → sidecar re-import) reconciles assets.
        try await store.addTag(id: item.id, tag: "animals")
        let fetchedTagged = try await store.fetchItem(id: item.id)
        var tagged = try XCTUnwrap(fetchedTagged)
        tagged.metadata.tags = ["animals"]
        try await store.updateItem(tagged)

        let fetchedAfter = try await store.fetchItem(id: item.id)
        let after = try XCTUnwrap(fetchedAfter)
        XCTAssertEqual(after.assets.map(\.assetID), [asset.assetID])
        XCTAssertEqual(after.perFileOCR[0]?.ocrText, "ocr-0")
        XCTAssertEqual(after.indexedContent?.ocrText, "the leopard shall lie down with the kid")
        let afterMatches = try await leopardMatches()
        XCTAssertEqual(afterMatches, 1)
        let issues = try await store.assetAssociationIssues(itemID: item.id)
        XCTAssertTrue(issues.isEmpty, "a moved inode is not a replacement: \(issues.map(\.reason))")

        // The stored evidence follows the file, so the next write compares against the copy.
        let storedFingerprint = try await database.read { db in
            try String.fetchOne(db, sql: "SELECT fingerprint FROM item_assets WHERE asset_id = ?", arguments: [asset.assetID.uuidString])
        }
        XCTAssertEqual(storedFingerprint?.split(separator: ":")[1], "\((copied[.systemFileNumber] as? NSNumber)?.stringValue ?? "?")")
    }

    func testSameSizeReplacementWithNewTimesStillRetiresIdentity() async throws {
        let item = try await makeSettledItem("same-size")
        let asset = try XCTUnwrap(item.assets.first)
        try Data("SAME FIXTURE BYTES".utf8).write(to: asset.url, options: .atomic)
        try await store.refreshAssets(itemID: item.id)
        let fetched = try await store.fetchItem(id: item.id)
        let after = try XCTUnwrap(fetched)
        XCTAssertNotEqual(after.assets.first?.assetID, asset.assetID)
        XCTAssertTrue(after.perFileOCR.isEmpty)
        XCTAssertNil(after.indexedContent?.ocrText)
    }

    func testRestoringRemovedUnchangedFileRestoresItsOriginalIdentityAndData() async throws {
        let item = try await makeItem("restore")
        try await seedDependencies(item)
        let removed = try XCTUnwrap(item.assets.first { $0.order == 0 })
        _ = try await store.removeAsset(itemID: item.id, assetID: removed.assetID)
        try await store.updateMediaFiles(id: item.id, files: item.mediaFiles)
        let restored = try await store.fetchItem(id: item.id)
        XCTAssertEqual(restored?.assets.first?.assetID, removed.assetID)
        XCTAssertEqual(restored?.perFileOCR[0]?.ocrText, "ocr-0")
        let id = item.id
        let annotations = try await database.read { db in try AnnotationRecord.fetchAll(db: db, itemId: id) }
        XCTAssertEqual(annotations.count, 2)
    }

    func testSameBytesAcrossItemsDoNotShareIdentityAndContextOnlyWorks() async throws {
        let first = try await makeItem("one", count: 1)
        let second = try await makeItem("two", count: 1)
        XCTAssertNotEqual(first.assets.first?.assetID, second.assets.first?.assetID)
        let context = try await makeItem("context", count: 1, contextOnly: true)
        XCTAssertEqual(context.assets.first?.role, .context)
        try await seedDependencies(context)
        let id = context.id
        let annotation = try await database.read { db in try AnnotationRecord.fetch(db: db, itemId: id, mediaFileIndex: 0) }
        XCTAssertEqual(annotation?.assetID, context.assets.first?.assetID)
    }

    func testCombineAdoptsSecondaryIdentityAndAllAssociations() async throws {
        let first = try await makeItem("combine-one", count: 1)
        let second = try await makeItem("combine-two", count: 1)
        try await seedDependencies(first)
        try await seedDependencies(second)
        _ = try await store.combineItems(primaryID: first.id, secondaryIDs: [second.id])
        let merged = try await store.fetchItem(id: first.id)
        XCTAssertEqual(Set(merged?.assets.map(\.assetID) ?? []), Set(first.assets.map(\.assetID) + second.assets.map(\.assetID)))
        XCTAssertEqual(merged?.perFileOCR.count, 2)
        XCTAssertEqual(merged?.videoSegments.count, 2)
        XCTAssertEqual(merged?.transcriptSegments.count, 2)
        let id = first.id
        let annotations = try await database.read { db in try AnnotationRecord.fetchAll(db: db, itemId: id) }
        XCTAssertEqual(annotations.count, 2)
    }

    func testAliasOnlyPathCorrectionKeepsAssetIdentity() async throws {
        let item = try await makeItem("canonical", count: 1)
        try await seedDependencies(item)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: item.basePath)
        try await store.updateMediaFiles(id: item.id, files: [alias.appendingPathComponent("0.jpg")])
        let changed = try await store.fetchItem(id: item.id)
        XCTAssertEqual(changed?.assets.first?.assetID, item.assets.first?.assetID)
        XCTAssertEqual(changed?.perFileOCR[0]?.ocrText, "ocr-0")
    }

    func testExplicitRenamePreservesIdentityAndCapturedAnalysisUsesCurrentPath() async throws {
        let item = try await makeItem("rename", count: 1)
        try await seedDependencies(item)
        let asset = try XCTUnwrap(item.assets.first)
        let renamed = asset.url.deletingLastPathComponent().appendingPathComponent("renamed.jpg")
        try FileManager.default.moveItem(at: asset.url, to: renamed)
        let oldPath = asset.url.path
        let newPath = renamed.path
        try await database.write { db in
            _ = try MediaItemRecord.updateFilePath(db: db, oldPath: oldPath, newPath: newPath)
        }
        try await store.refreshAssets(itemID: item.id)
        let fetched = try await store.fetchItem(id: item.id)
        XCTAssertEqual(fetched?.assets.first?.assetID, asset.assetID)
        XCTAssertEqual(fetched?.videoSegments.first?.sourcePath, newPath)
        XCTAssertEqual(fetched?.transcriptSegments.first?.sourcePath, newPath)
        let captured = MediaFileOCRRecord(itemId: item.id, fileURL: oldPath, fileIndex: 0, ocrText: "captured before rename", assetID: asset.assetID)
        try await database.write { db in try captured.upsert(db: db) }
        let id = item.id.uuidString
        let path = try await database.read { db in try String.fetchOne(db, sql: "SELECT file_url FROM media_file_ocr WHERE item_id = ? AND association_state = 'attached'", arguments: [id]) }
        XCTAssertEqual(path, newPath)
    }

    func testExplicitAnnotationRecoveryDoesNotOverwriteOccupiedDestination() async throws {
        let item = try await makeItem("recover")
        try await seedDependencies(item)
        let original = item.assets.sorted { $0.order < $1.order }
        _ = try await store.removeAsset(itemID: item.id, assetID: original[0].assetID)
        let issues = try await store.assetAssociationIssues(itemID: item.id)
        let annotation = try XCTUnwrap(issues.first { $0.table == "annotations" })
        do {
            try await store.reattachAnnotation(recordID: annotation.recordID, itemID: item.id, to: original[1].assetID)
            XCTFail("Occupied destination must retain both versions")
        } catch ItemAssetStore.AssociationError.occupiedAsset {}
        try Data("replacement bytes for explicit recovery".utf8).write(to: original[1].url, options: .atomic)
        try await store.refreshAssets(itemID: item.id)
        let assets = try await store.fetchAssets(itemID: item.id)
        let replacement = try XCTUnwrap(assets.first)
        try await store.reattachAnnotation(recordID: annotation.recordID, itemID: item.id, to: replacement.assetID)
        let id = item.id
        let recovered = try await database.read { db in try AnnotationRecord.fetch(db: db, itemId: id, mediaFileIndex: 0, assetID: replacement.assetID) }
        XCTAssertEqual(recovered?.id.uuidString, annotation.recordID)
        XCTAssertTrue(recovered?.annotationsJSON.contains("annotation-0") == true)
        let history = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_association_resolutions") }
        XCTAssertEqual(history, 1)
    }

    func testOrphanedAnnotationRemainsGloballyInspectableWithoutReassociation() async throws {
        let orphanID = UUID()
        let record = AnnotationRecord(itemId: orphanID, mediaFileIndex: 0, annotationSet: .empty)
        try await database.write { db in
            try db.execute(sql: "INSERT INTO annotations(id,itemId,mediaFileIndex,annotationsJSON,createdAt,updatedAt,association_state) VALUES (?,?,0,?,?,?,'legacy')", arguments: [record.id.uuidString, orphanID.uuidString, record.annotationsJSON, Date(), Date()])
        }
        let issues = try await store.assetAssociationIssues()
        XCTAssertEqual(issues.first?.reason, "orphaned-item")
        XCTAssertEqual(issues.first?.itemID, orphanID)
        let content = try await store.retainedAnnotationContent(recordID: record.id.uuidString)
        XCTAssertEqual(content, record.annotationsJSON)
        let id = orphanID.uuidString
        let inventedItem = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(inventedItem, 0)
    }

    @MainActor
    func testUnsavedDraftForReplacedFileIsDurablyRetainedWithoutOverwritingOriginal() async throws {
        let item = try await makeItem("draft", count: 1)
        try await seedDependencies(item)
        let asset = try XCTUnwrap(item.assets.first)
        let annotations = AnnotationStore(database: database)
        var draft = AnnotationSet.empty
        draft.addShape(.text(id: UUID(), position: NormalizedPoint(x: 0.5, y: 0.5), content: "unsaved draft preserved", style: .default))
        try Data("replacement while editing".utf8).write(to: asset.url, options: .atomic)
        for _ in 0..<2 {
            do {
                try await annotations.saveAnnotations(itemId: item.id, mediaFileIndex: 0, annotationSet: draft, assetID: asset.assetID)
                XCTFail("Replacement must require explicit draft review")
            } catch ItemAssetStore.AssociationError.draftRetained {}
        }
        let id = item.id.uuidString
        let rows = try await database.read { db in try Row.fetchAll(db, sql: "SELECT annotationsJSON, association_state FROM annotations WHERE itemId = ?", arguments: [id]) }
        XCTAssertEqual(rows.count, 2, "Repeated retries update one separate draft")
        XCTAssertTrue(rows.contains { ($0["annotationsJSON"] as String).contains("annotation-0") })
        XCTAssertTrue(rows.contains { ($0["association_state"] as String) == "retained-draft" && ($0["annotationsJSON"] as String).contains("unsaved draft preserved") })
        let reopened = DatabaseManager(databaseURL: directory.appendingPathComponent("assets.sqlite"))
        try await reopened.initialize()
        let issueCount = try await reopened.read { db in try ItemAssetStore.issues(in: db, itemID: item.id).filter { $0.table == "annotations" }.count }
        XCTAssertEqual(issueCount, 2)
    }

    func testFailedLegacyMigrationRollsBackAndRestartPreservesAmbiguousAnnotationBytes() async throws {
        var first = try await makeItem("legacy-one", count: 1)
        let context = first.basePath.appendingPathComponent("context.png")
        try Data("context image".utf8).write(to: context)
        first.contextImage = context
        try await store.updateItem(first)
        let reloaded = try await store.fetchItem(id: first.id)
        first = try XCTUnwrap(reloaded)
        var annotation = AnnotationSet.empty
        annotation.addShape(.text(id: UUID(), position: NormalizedPoint(x: 0.4, y: 0.5), content: "legacy content must survive", style: .default))
        let mediaAsset = try XCTUnwrap(first.assets.first { $0.role == .media })
        let record = AnnotationRecord(itemId: first.id, mediaFileIndex: 0, annotationSet: annotation, assetID: mediaAsset.assetID)
        try await database.write { db in try record.upsert(db: db) }
        let second = try await makeItem("legacy-two", count: 1)
        let secondID = second.id.uuidString
        let properJSON = String(decoding: try JSONEncoder().encode(second.mediaFiles.map(\.path)), as: UTF8.self)
        try await database.write { db in
            // Reconstruct the pre-migration40 fixture from production schemas,
            // preserving every actual legacy record and its original bytes.
            for table in ["annotations", "media_file_ocr", "video_segments", "transcript_segments"] {
                try db.execute(sql: "DROP TRIGGER asset_attach_\(table)")
                try db.execute(sql: "DROP INDEX idx_\(table)_asset")
                try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN asset_id")
                try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN association_state")
                try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN legacy_file_index")
            }
            try db.execute(sql: "DROP TRIGGER asset_annotation_parent_delete")
            try db.execute(sql: "DROP TABLE asset_association_resolutions")
            try db.execute(sql: "DROP TABLE item_assets")
            try ProductionAssetFixture.removePost42Schema(in: db)
            try db.execute(sql: "DELETE FROM schema_migrations WHERE version >= 41")
            try db.execute(sql: "UPDATE media_items SET mediaFilesJSON = '{' WHERE id = ?", arguments: [secondID])
        }
        let dbURL = directory.appendingPathComponent("assets.sqlite")
        let failedAttempt = DatabaseManager(databaseURL: dbURL)
        do { try await failedAttempt.initialize(); XCTFail("Expected malformed legacy association to abort migration") } catch {}
        let rolledBack = try await database.read { db in try db.tableExists("item_assets") }
        XCTAssertFalse(rolledBack)
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET mediaFilesJSON = ? WHERE id = ?", arguments: [properJSON, secondID])
        }
        let recovered = DatabaseManager(databaseURL: dbURL)
        try await recovered.initialize()
        let id = record.id.uuidString
        let after = try await recovered.read { db in try Row.fetchOne(db, sql: "SELECT annotationsJSON, association_state FROM annotations WHERE id = ?", arguments: [id]) }
        XCTAssertEqual(after?["annotationsJSON"] as String?, record.annotationsJSON)
        XCTAssertEqual(after?["association_state"] as String?, "ambiguous")
        let identities = try await recovered.read { db in try String.fetchAll(db, sql: "SELECT asset_id FROM item_assets ORDER BY asset_id") }
        let restarted = DatabaseManager(databaseURL: dbURL)
        try await restarted.initialize()
        let again = try await restarted.read { db in try String.fetchAll(db, sql: "SELECT asset_id FROM item_assets ORDER BY asset_id") }
        XCTAssertEqual(identities, again)
    }
}
