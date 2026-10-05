import XCTest
import GRDB
@testable import MediaViewer

final class ContextAssociationRepairTests: XCTestCase {
    private var root: URL!
    private var archive: URL!
    private var database: DatabaseManager!
    private var coordinator: AppCoordinator!
    private var store: MediaStore!

    override func setUp() async throws {
        root = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("context-repair-\(UUID())")
        archive = root.appendingPathComponent("archive/2026-01")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: root.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        coordinator = AppCoordinator(database: database, archivePath: archive)
        store = await coordinator.getMediaStore()
    }

    override func tearDown() async throws {
        coordinator = nil
        store = nil
        database = nil
        try FileManager.default.removeItem(at: root)
    }

    private func fixture(tags: [String] = [], parentMedia: Bool = true) async throws -> (post: MediaItem, orphan: MediaItem) {
        let name = "2026-01-11-twitter-samplecontext-1000000000000000011"
        let parent = archive.appendingPathComponent("\(name).md")
        let media = archive.appendingPathComponent("\(name)-1.png")
        let context = archive.appendingPathComponent("\(name)-1.context.png")
        if parentMedia { try ImportDurabilityTests.png.write(to: media) }
        try ImportDurabilityTests.png.write(to: context)
        try "---\nsource: https://x.com/user/status/1000000000000000011\nplatform: twitter\narchived: 2026-01-11T12:00:00Z\ntags: [existing]\n---\n\(parentMedia ? "![[\(media.lastPathComponent)]]" : "Post without downloaded media")\n".write(to: parent, atomically: true, encoding: .utf8)
        let orphanSidecar = try MetadataParser.createMetadataFile(forMediaAt: context, source: context, platform: "twitter")
        let post = MediaItem(id: UUID(), basePath: archive, metadataFile: parent,
                             mediaFiles: parentMedia ? [media] : [], metadata: try MetadataParser.parse(fileAt: parent),
                             indexedContent: IndexedContent(ocrText: "retained OCR"), aspectRatio: 1,
                             pipelineStatus: "complete")
        var orphanMetadata = try MetadataParser.parse(fileAt: orphanSidecar)
        orphanMetadata.tags = tags
        let orphan = MediaItem(id: UUID(), basePath: archive, metadataFile: orphanSidecar, mediaFiles: [],
                               contextImage: context, metadata: orphanMetadata, aspectRatio: 1)
        try await database.write { db in
            try MediaItemRecord(from: post).insertWithFTSSync(db: db)
            try MediaItemRecord(from: orphan).insertWithFTSSync(db: db)
            try db.execute(sql: "UPDATE media_items SET pipeline_version = 7 WHERE id = ?", arguments: [post.id.uuidString])
        }
        return (post, orphan)
    }

    private func scan() async throws {
        _ = try await coordinator.performInitialScan(watcher: ArchiveWatcher(archivePath: archive))
    }

    func testStartupReattachesContextRetiresOrphanAndWritesOnlyTaggedPost() async throws {
        let pair = try await fixture(tags: ["art", "EXISTING"])
        let originalOrphan = try Data(contentsOf: pair.orphan.metadataFile)
        let files = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        let before = try Dictionary(uniqueKeysWithValues: files.map { ($0, try Data(contentsOf: $0)) })
        try await scan()
        let postValue = try await store.fetchItem(id: pair.post.id)
        let post = try XCTUnwrap(postValue)
        let orphanValue = try await store.fetchItem(id: pair.orphan.id)
        let orphan = try XCTUnwrap(orphanValue)
        XCTAssertEqual(post.contextImage, pair.orphan.contextImage)
        XCTAssertEqual(post.metadata.tags, ["existing", "art"])
        XCTAssertEqual(post.pipelineStatus, "complete")
        XCTAssertEqual(post.indexedContent?.ocrText, "retained OCR")
        XCTAssertTrue(orphan.metadata.deleted)
        XCTAssertEqual(orphan.deletionReason, .contextReattached)
        XCTAssertEqual(orphan.contextImage, pair.orphan.contextImage)
        let pending = try await store.writeBackQueue.statuses().filter { $0.state != "synced" }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.itemID, pair.post.id.uuidString)
        XCTAssertEqual(pending.first?.field, "tags")
        try await database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT pipeline_version FROM media_items WHERE id = ?", arguments: [pair.post.id.uuidString]), 7)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_tags WHERE item_id = ? AND tag = 'art'", arguments: [pair.post.id.uuidString]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vision_pending_jobs"), 0)
        }
        let enrichmentIDs = try await store.itemIdsWithEnrichment()
        XCTAssertFalse(enrichmentIDs.contains(pair.orphan.id))
        try await store.writeBackQueue.persistBackfill([pair.orphan.id])
        let afterBackfill = try await store.writeBackQueue.statuses().filter { $0.state != "synced" }
        XCTAssertEqual(afterBackfill.count, 1)
        XCTAssertEqual(afterBackfill.first?.itemID, pair.post.id.uuidString)
        await store.writeBackQueue.flushNow()
        let changed = try files.filter { try Data(contentsOf: $0) != before[$0] }
        XCTAssertEqual(changed.map(ArchiveAssociationResolver.canonicalPath),
                       [ArchiveAssociationResolver.canonicalPath(pair.post.metadataFile)])
        XCTAssertEqual(try Data(contentsOf: pair.orphan.metadataFile), originalOrphan)
        XCTAssertEqual(try MetadataParser.parse(fileAt: pair.post.metadataFile).tags, ["existing", "art"])
        try await scan()
        let activeCount = try await store.countItems()
        XCTAssertEqual(activeCount, 1)
        let replayPending = try await store.writeBackQueue.statuses().filter { $0.state != "synced" }
        XCTAssertTrue(replayPending.isEmpty)
    }

    func testRemovedGeneratedSidecarIsNotRegeneratedOrAutomaticallyRestored() async throws {
        let pair = try await fixture(tags: ["art"])
        try FileManager.default.removeItem(at: pair.orphan.metadataFile)
        try await scan()
        let result = try await store.reconcileOrphans()
        XCTAssertEqual(result.regeneratedCount, 0)
        let retiredValue = try await store.fetchItem(id: pair.orphan.id)
        let retired = try XCTUnwrap(retiredValue)
        XCTAssertEqual(retired.deletionReason, .contextReattached)
        XCTAssertTrue(retired.metadata.deleted)
        XCTAssertFalse(ArchiveReappearancePolicy.shouldRestore(retired))
        try await store.markSidecarMissing(id: pair.orphan.id)
        let afterMissingValue = try await store.fetchItem(id: pair.orphan.id)
        let afterMissing = try XCTUnwrap(afterMissingValue)
        XCTAssertEqual(afterMissing.deletionReason, .contextReattached)
        let parent = try await store.fetchItem(id: pair.post.id)
        XCTAssertEqual(parent?.metadata.tags, ["existing", "art"])
        await store.writeBackQueue.flushNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pair.orphan.metadataFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(pair.orphan.contextImage).path))
    }

    func testRepairWithoutDownloadedMediaAndExplicitRecoveryAreStable() async throws {
        let pair = try await fixture(parentMedia: false)
        try await scan()
        let parentValue = try await store.fetchItem(id: pair.post.id)
        let parent = try XCTUnwrap(parentValue)
        XCTAssertEqual(parent.contextImage, pair.orphan.contextImage)
        XCTAssertTrue(parent.mediaFiles.isEmpty)
        var deleted = FilterState.all
        deleted.deletionScope = .deletedOnly
        let deletedItems = try await store.fetchItems(filter: deleted)
        XCTAssertEqual(deletedItems.map(\.id), [pair.orphan.id])
        try await store.restoreDeletedWithFileValidation(ids: [pair.orphan.id])
        let groups = try await ArchiveWatcher(archivePath: archive).scanArchive()
        let replay = try await store.reconcileContextAssociations(groups)
        XCTAssertTrue(replay.retiredIDs.isEmpty)
        let restoredValue = try await store.fetchItem(id: pair.orphan.id)
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertFalse(restored.metadata.deleted)
        XCTAssertEqual(restored.deletionReason, .contextReattached)
        var stale = restored
        stale.deletionReason = nil
        try await store.updateItem(stale)
        let afterUpdate = try await store.fetchItem(id: pair.orphan.id)
        XCTAssertEqual(afterUpdate?.deletionReason, .contextReattached)
        let afterReplay = try await store.reconcileContextAssociations(groups)
        XCTAssertTrue(afterReplay.retiredIDs.isEmpty)
    }

    func testAnnotationsAndPendingUserContentAreNotRetired() async throws {
        let pair = try await fixture()
        let annotation = AnnotationRecord(itemId: pair.orphan.id, annotationSet: AnnotationSet())
        try await database.write { db in try annotation.insert(db) }
        try await scan()
        let orphanValue = try await store.fetchItem(id: pair.orphan.id)
        let orphan = try XCTUnwrap(orphanValue)
        XCTAssertFalse(orphan.metadata.deleted)
        XCTAssertNil(orphan.deletionReason)
        let kept = try await database.read { db in try AnnotationRecord.fetchOne(db, key: annotation.id.uuidString) }
        XCTAssertEqual(kept?.itemId, pair.orphan.id)
    }

    func testUnacceptedOwnerAssociationDoesNotRetireOrphan() async throws {
        let pair = try await fixture()
        let groups = try await ArchiveWatcher(archivePath: archive).scanArchive()
        let result = try await store.reconcileContextAssociations(groups)
        XCTAssertTrue(result.retiredIDs.isEmpty)
        let orphan = try await store.fetchItem(id: pair.orphan.id)
        XCTAssertFalse(try XCTUnwrap(orphan).metadata.deleted)
        let parent = try await store.fetchItem(id: pair.post.id)
        XCTAssertNil(parent?.contextImage)
    }

    func testDeletedOwnerDoesNotRetireOrphan() async throws {
        let pair = try await fixture(tags: ["art"])
        try await store.softDelete(ids: [pair.post.id])
        try await scan()
        let orphan = try await store.fetchItem(id: pair.orphan.id)
        XCTAssertFalse(try XCTUnwrap(orphan).metadata.deleted)
        XCTAssertNil(orphan?.deletionReason)
    }

    func testPendingTagIntentDoesNotRetireOrphan() async throws {
        let pair = try await fixture()
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET tagsJSON = '[\"art\"]' WHERE id = ?", arguments: [pair.orphan.id.uuidString])
        }
        try await scan()
        let orphan = try await store.fetchItem(id: pair.orphan.id)
        XCTAssertFalse(try XCTUnwrap(orphan).metadata.deleted)
        let pending = try await store.writeBackQueue.statuses()
        XCTAssertTrue(pending.contains { $0.itemID == pair.orphan.id.uuidString && $0.field == "tags" && $0.state != "synced" })
    }

    func testRebuiltDBCarriesSuppressedSidecarTagsToPost() async throws {
        let pair = try await fixture()
        try await database.write { db in _ = try MediaItemRecord.deleteOne(db, key: pair.orphan.id.uuidString) }
        try "---\narchived: 2026-01-11T12:00:00Z\nsource: \(try XCTUnwrap(pair.orphan.contextImage).absoluteString)\ntags: [art]\n---\n".write(to: pair.orphan.metadataFile, atomically: true, encoding: .utf8)
        try await scan()
        let parentValue = try await store.fetchItem(id: pair.post.id)
        let parent = try XCTUnwrap(parentValue)
        XCTAssertEqual(parent.metadata.tags, ["existing", "art"])
        let orphanValue = try await store.fetchItem(byMetadataPath: pair.orphan.metadataFile.path)
        let orphan = try XCTUnwrap(orphanValue)
        XCTAssertTrue(orphan.metadata.deleted)
        XCTAssertEqual(orphan.deletionReason, .contextReattached)
    }
}
