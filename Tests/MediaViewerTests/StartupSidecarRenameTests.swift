import XCTest
import GRDB
@testable import MediaViewer

final class StartupSidecarRenameTests: XCTestCase {
    private var root: URL!
    private var archive: URL!
    private var database: DatabaseManager!
    private var coordinator: AppCoordinator!
    private var store: MediaStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("StartupSidecarRename-\(UUID())")
        archive = root.appendingPathComponent("archive/2026-10")
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
        try? FileManager.default.removeItem(at: root)
    }

    private func makeItem(_ name: String = "a", mediaNames: [String] = ["a.png"], stemBase: Bool = false) async throws -> MediaItem {
        let sidecar = archive.appendingPathComponent("\(name).md")
        let media = mediaNames.map { archive.appendingPathComponent($0) }
        for url in media { try ImportDurabilityTests.png.write(to: url) }
        let content = """
        ---
        source: https://example.com/original
        platform: test
        archived: 2026-10-01T12:00:00Z
        tags: [keep-me]
        ---
        \(mediaNames.map { "![[\($0)]]" }.joined(separator: "\n"))
        """
        try content.write(to: sidecar, atomically: true, encoding: .utf8)
        let item = MediaItem(
            id: UUID(), basePath: stemBase ? sidecar.deletingPathExtension() : archive,
            metadataFile: sidecar, mediaFiles: media,
            metadata: try await MetadataParser.parseAsync(fileAt: sidecar),
            indexedContent: IndexedContent(ocrText: "retained OCR"), aspectRatio: 1
        )
        try await store.insertItem(item)
        return item
    }

    private func rename(_ item: MediaItem, to name: String = "b") throws -> URL {
        let destination = archive.appendingPathComponent("\(name).md")
        try FileManager.default.moveItem(at: item.metadataFile, to: destination)
        return destination
    }

    private func startup() async throws -> MediaStore.ReconciliationResult {
        _ = try await coordinator.performInitialScan(watcher: ArchiveWatcher(archivePath: archive))
        return try await store.reconcileOrphans()
    }

    private func rowCount() async throws -> Int {
        try await database.read { db in try MediaItemRecord.fetchCount(db) }
    }

    private func assertRename(stemBase: Bool) async throws {
        let item = try await makeItem(stemBase: stemBase)
        let destination = try rename(item)
        let result = try await startup()
        let restored = try await store.fetchItem(byMetadataPath: destination.path)
        XCTAssertEqual(restored?.id, item.id)
        XCTAssertEqual(restored?.mediaFiles, item.mediaFiles)
        XCTAssertEqual(restored?.indexedContent, item.indexedContent)
        XCTAssertEqual(restored?.metadata.tags, item.metadata.tags)
        XCTAssertEqual(restored?.metadata.deleted, false)
        XCTAssertNil(restored?.deletionReason)
        XCTAssertEqual(restored?.basePath, destination.deletingPathExtension())
        let count = try await rowCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(result.regeneratedCount, 0)
        XCTAssertEqual(result.softDeletedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.metadataFile.path))
        _ = try await startup()
        let secondCount = try await rowCount()
        XCTAssertEqual(secondCount, 1, "a second startup must keep the adopted identity")
    }

    func testOfflineRenameWithImportedFolderBaseKeepsIdentity() async throws {
        try await assertRename(stemBase: false)
    }

    func testOfflineRenameWithStartupStemBaseKeepsIdentity() async throws {
        try await assertRename(stemBase: true)
    }

    func testOfflineRenameKeepsBoardMembershipAndAnnotationAddedAfterIndexing() async throws {
        let item = try await makeItem()
        let board = CollectionBoard(name: "Keep identity")
        let annotation = AnnotationRecord(itemId: item.id, annotationSet: AnnotationSet())
        try await database.write { db in
            try board.insert(db)
            try BoardMembership(boardId: board.id, itemId: item.id, position: 3).insert(db)
            try annotation.insert(db)
        }
        let destination = try rename(item)
        _ = try await startup()
        let adopted = try await store.fetchItem(byMetadataPath: destination.path)
        XCTAssertEqual(adopted?.id, item.id)
        let pending = try await store.writeBackQueue.statuses()
        XCTAssertEqual(pending.first { $0.field == "annotated" }?.itemID, item.id.uuidString)
        XCTAssertEqual(pending.first { $0.field == "annotated" }?.metadataPath, destination.path)
        try await database.read { db in
            XCTAssertEqual(try board.fetchItems(db: db).map(\.metadataFile), [destination])
            let retained = try AnnotationRecord.fetchOne(db, key: annotation.id.uuidString)
            XCTAssertEqual(retained?.itemId, adopted?.id)
            XCTAssertEqual(retained?.annotationsJSON, annotation.annotationsJSON)
        }
    }

    func testTwoMissingItemsWithSameMediaSetAreNotAdopted() async throws {
        let first = try await makeItem()
        let second = try await makeItem("c")
        let destination = try rename(first)
        try FileManager.default.removeItem(at: second.metadataFile)
        let result = try await startup()
        let indexed = try await store.fetchItem(byMetadataPath: destination.path)
        XCTAssertNotEqual(indexed?.id, first.id)
        XCTAssertNotEqual(indexed?.id, second.id)
        let count = try await rowCount()
        XCTAssertEqual(count, 3)
        XCTAssertEqual(result.regeneratedCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.metadataFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.metadataFile.path))
    }

    func testPartialMediaSetDoesNotAdopt() async throws {
        let item = try await makeItem(mediaNames: ["a.png", "second.png"])
        let destination = try rename(item)
        var content = try String(contentsOf: destination, encoding: .utf8)
        content = content.replacingOccurrences(of: "![[second.png]]", with: "")
        try content.write(to: destination, atomically: true, encoding: .utf8)
        _ = try await startup()
        let indexed = try await store.fetchItem(byMetadataPath: destination.path)
        XCTAssertNotEqual(indexed?.id, item.id)
        let original = try await store.fetchItem(id: item.id)
        XCTAssertEqual(original?.metadataFile, item.metadataFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.metadataFile.path))
    }

    func testTwoIncomingSidecarsWithSameMediaSetAreNotAdopted() async throws {
        let item = try await makeItem()
        let destination = try rename(item)
        try FileManager.default.copyItem(at: destination, to: archive.appendingPathComponent("c.md"))
        let result = try await startup()
        let original = try await store.fetchItem(id: item.id)
        XCTAssertEqual(original?.metadataFile, item.metadataFile)
        let count = try await rowCount()
        XCTAssertEqual(count, 3)
        XCTAssertEqual(result.regeneratedCount, 1)
    }

    func testStartupNeverAdoptsUserDeletedItem() async throws {
        let item = try await makeItem()
        let destination = try rename(item)
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET deletedAt = ?, deletionReason = 'user' WHERE id = ?",
                           arguments: [Date(), item.id.uuidString])
        }
        _ = try await startup()
        let indexed = try await store.fetchItem(byMetadataPath: destination.path)
        XCTAssertNotEqual(indexed?.id, item.id)
        let original = try await store.fetchItem(id: item.id)
        XCTAssertEqual(original?.metadataFile, item.metadataFile)
        XCTAssertEqual(original?.metadata.deleted, true)
        let count = try await rowCount()
        XCTAssertEqual(count, 2)
    }

    func testNewSidecarForUnownedMediaIsIndexedAsNew() async throws {
        let seed = try await makeItem("new", mediaNames: ["new.png"])
        try await database.write { db in _ = try MediaItemRecord.deleteOne(db, key: seed.id.uuidString) }
        let result = try await startup()
        let indexed = try await store.fetchItem(byMetadataPath: seed.metadataFile.path)
        XCTAssertNotNil(indexed)
        XCTAssertNotEqual(indexed?.id, seed.id)
        let count = try await rowCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(result.regeneratedCount, 0)
    }

    func testDeletedSidecarWithPresentMediaIsRegenerated() async throws {
        let item = try await makeItem()
        try FileManager.default.removeItem(at: item.metadataFile)
        _ = try await startup()
        let retained = try await store.fetchItem(id: item.id)
        XCTAssertEqual(retained?.metadataFile, item.metadataFile)
        XCTAssertEqual(retained?.metadata.deleted, false)
        let count = try await rowCount()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.metadataFile.path))
    }

    func testStartupAdoptsMissingFilesTombstone() async throws {
        let item = try await makeItem()
        let destination = try rename(item)
        try await store.markSidecarMissing(id: item.id)
        _ = try await startup()
        let restored = try await store.fetchItem(byMetadataPath: destination.path)
        XCTAssertEqual(restored?.id, item.id)
        XCTAssertEqual(restored?.metadata.deleted, false)
        let count = try await rowCount()
        XCTAssertEqual(count, 1)
    }

    func testWatcherDoesNotChooseBetweenTwoMissingFilesTombstones() async throws {
        let first = try await makeItem()
        let second = try await makeItem("c")
        let destination = try rename(first)
        try FileManager.default.removeItem(at: second.metadataFile)
        try await store.markSidecarMissing(id: first.id)
        try await store.markSidecarMissing(id: second.id)
        let adopted = try await store.adoptMovedSidecar(at: destination, mediaFiles: first.mediaFiles)
        XCTAssertNil(adopted)
    }
}
