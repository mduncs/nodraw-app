import XCTest
import GRDB
@testable import MediaViewer

final class BoardExportDurabilityTests: XCTestCase {
    private var root: URL!
    private var output: URL!
    private var item: MediaItem!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nodraw-export-test-\(UUID())")
        output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("original.png")
        try Data("fixture bytes".utf8).write(to: media)
        let sidecar = root.appendingPathComponent("original.md")
        try Data("---\nnotes: preserve\n---\nBody".utf8).write(to: sidecar)
        item = MediaItem(id: UUID(), basePath: root, metadataFile: sidecar, mediaFiles: [media],
            metadata: MediaMetadata(source: URL(string: "https://example.invalid/export")!, platform: "fixture"))
    }

    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    private func previous(_ name: String) throws -> URL {
        let directory = output.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("previous export must survive".utf8).write(to: directory.appendingPathComponent("sentinel"))
        return directory
    }

    func testDefaultCollisionNeverRemovesExistingExport() throws {
        let old = try previous("Board")
        XCTAssertThrowsError(try BoardExporter().exportAsFolder(board: CollectionBoard(name: "Board"), items: [item], to: output))
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("sentinel")), "previous export must survive")
    }

    func testFailedReplacementPreservesPreviousAndReportsOwnedStage() throws {
        let old = try previous("Board")
        try FileManager.default.removeItem(at: item.mediaFiles[0])
        let exporter = BoardExporter()
        let result = try exporter.exportAsFolder(board: CollectionBoard(name: "Board"), items: [item], to: output,
            collisionPolicy: .replacePreservingPrevious)
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("sentinel")), "previous export must survive")
        XCTAssertTrue(try exporter.recoverableExportDirectories(in: output).contains(XCTUnwrap(result.recoveryURL)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appendingPathComponent("manifest.json").path))
    }

    func testExplicitReplacementAtomicallyRetainsPreviousDirectory() throws {
        let old = try previous("Board")
        let exporter = BoardExporter()
        let result = try exporter.exportAsFolder(board: CollectionBoard(name: "Board"), items: [item], to: output,
            collisionPolicy: .replacePreservingPrevious)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.outputURL.standardizedFileURL.path, old.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("manifest.json").path))
        let recovery = try XCTUnwrap(result.recoveryURL)
        XCTAssertEqual(try String(contentsOf: recovery.appendingPathComponent("sentinel")), "previous export must survive")
        XCTAssertEqual(try Data(contentsOf: item.mediaFiles[0]), Data("fixture bytes".utf8))
        XCTAssertTrue(try exporter.recoverableExportDirectories(in: output).contains(recovery))
    }

    func testInterruptedReadyExportIsDiscoverableWithoutChangingPrevious() throws {
        let old = try previous("Board_gallery")
        let exporter = BoardExporter(beforePublication: { throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try exporter.exportAsHTML(board: CollectionBoard(name: "Board"), items: [item], to: output,
            collisionPolicy: .replacePreservingPrevious))
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("sentinel")), "previous export must survive")
        let stages = try BoardExporter().recoverableExportDirectories(in: output)
        XCTAssertEqual(stages.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stages[0].appendingPathComponent("index.html").path))
    }

    func testLateCollisionAndTraversalNamesNeverClobberPeerDirectory() throws {
        let exporter = BoardExporter(beforePublication: { [output = output!] in
            let occupied = output.appendingPathComponent("Untitled Board")
            try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
            try Data("external".utf8).write(to: occupied.appendingPathComponent("peer"))
        })
        XCTAssertThrowsError(try exporter.exportAsFolder(board: CollectionBoard(name: ".."), items: [item], to: output))
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("Untitled Board/peer")), "external")
        XCTAssertEqual(try exporter.recoverableExportDirectories(in: output).count, 1)
    }
}

final class DeleteFailureTruthTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nodraw-delete-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: root.appendingPathComponent("fixture.sqlite"))
        try await database.initialize()
        store = MediaStore(database: database)
    }
    override func tearDown() async throws {
        store = nil
        database = nil
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func makeItem(_ name: String, shared: URL? = nil, count: Int = 1) async throws -> MediaItem {
        var files: [URL] = []
        for index in 0..<count {
            let path = shared ?? root.appendingPathComponent("\(name)-\(index).png")
            if !FileManager.default.fileExists(atPath: path.path) { try Data("\(name) original".utf8).write(to: path) }
            files.append(path)
        }
        let sidecar = root.appendingPathComponent("\(name).md")
        try Data("---\nsource: https://example.invalid\n---\n".utf8).write(to: sidecar)
        let item = MediaItem(id: UUID(), basePath: root, metadataFile: sidecar, mediaFiles: files,
            metadata: MediaMetadata(source: URL(string: "https://example.invalid/\(name)")!, platform: "fixture"))
        let record = MediaItemRecord(from: item)
        try await database.write { db in try record.insertWithFTSSync(db: db) }
        return item
    }

    func testSharedOriginalIsProtectedFromWholeItemTrashAndSingleRemoval() async throws {
        let first = try await makeItem("first")
        _ = try await makeItem("peer", shared: first.mediaFiles[0])
        let calls = TrashProbe()
        let service = DeleteService(mediaStore: store, deleteFromDisk: true, trashOperation: { await calls.record($0); return "must not run" })
        let result = try await service.deleteItems([first])
        XCTAssertTrue(result.fileErrors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.mediaFiles[0].path))
        let wholeItemCalls = await calls.count
        XCTAssertEqual(wholeItemCalls, 0)
        let third = try await makeItem("third", shared: first.mediaFiles[0])
        let removal = try await service.removeFile(from: third, at: 0)
        XCTAssertTrue(removal.updatedItem.mediaFiles.isEmpty)
        XCTAssertFalse(removal.hasFileErrors)
        let singleFileCalls = await calls.count
        XCTAssertEqual(singleFileCalls, 0)
    }

    func testSingleFileFailureReturnsCommittedItemAndExplicitRetryTargets() async throws {
        let item = try await makeItem("carousel", count: 2)
        let service = DeleteService(mediaStore: store, deleteFromDisk: true, trashOperation: { _ in "Permission denied" })
        let result = try await service.removeFile(from: item, at: 0)
        XCTAssertTrue(result.hasFileErrors)
        XCTAssertEqual(result.updatedItem.mediaFiles, [item.mediaFiles[1]])
        XCTAssertEqual(result.failedFileURLs, [item.mediaFiles[0]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.mediaFiles[0].path))
        let retry = try await service.retryTrashFiles(result.retryTargets, excludingItemIDs: [])
        XCTAssertEqual(retry.fileErrors, ["Permission denied"])
    }

    func testRetryRefusesSamePathReplacementInsteadOfTrashingIt() async throws {
        let item = try await makeItem("replacement")
        let calls = TrashProbe()
        let service = DeleteService(mediaStore: store, deleteFromDisk: true, trashOperation: { url in
            await calls.record(url)
            return "Permission denied"
        })
        let result = try await service.deleteItems([item])
        XCTAssertEqual(result.retryTargets.count, 1)
        let target = item.mediaFiles[0]
        try FileManager.default.moveItem(at: target, to: target.appendingPathExtension("preserved-original"))
        try Data("unrelated replacement".utf8).write(to: target)
        let retry = try await service.retryTrashFiles(result.retryTargets, excludingItemIDs: [item.id])
        XCTAssertTrue(retry.fileErrors.first?.contains("changed") == true)
        XCTAssertTrue(retry.retryTargets.isEmpty, "A changed target must not silently receive a new deletion identity")
        XCTAssertEqual(try String(contentsOf: target), "unrelated replacement")
        let callCount = await calls.count
        XCTAssertEqual(callCount, 1)
    }

    func testWholeItemDeletionRereadsFilesAndDoesNotInflateMissingIDCount() async throws {
        let stale = try await makeItem("stale", count: 2)
        // An earlier carousel mutation removed the first member while this UI
        // payload remained stale. Deletion must not trash that stale URL.
        let assets = try await store.fetchAssets(itemID: stale.id)
        let asset = try XCTUnwrap(assets.first(where: { $0.url == stale.mediaFiles[0] }))
        _ = try await store.removeAsset(itemID: stale.id, assetID: asset.assetID)
        let missing = MediaItem(id: UUID(), basePath: stale.basePath, metadataFile: stale.metadataFile,
            mediaFiles: stale.mediaFiles, metadata: stale.metadata)
        let calls = TrashProbe()
        let service = DeleteService(mediaStore: store, deleteFromDisk: true, trashOperation: { url in
            await calls.record(url)
            return "Intentional failure for \(url.lastPathComponent)"
        })
        let result = try await service.deleteItems([stale, missing, stale])
        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertEqual(result.failedFileURLs, [stale.mediaFiles[1]])
        let callCount = await calls.count
        XCTAssertEqual(callCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.mediaFiles[0].path))
    }

    @MainActor
    func testPartialDeleteRetainsUndoAndFailedUndoDoesNotClaimSuccess() async throws {
        let item = try await makeItem("partial", count: 2)
        let removed = item.mediaFiles[0]
        let service = DeleteService(mediaStore: store, deleteFromDisk: true, trashOperation: { url in
            if url == removed {
                // Simulate a successful Trash move within this disposable fixture.
                do { try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("test-trash")); return nil }
                catch { return error.localizedDescription }
            }
            return "Permission denied"
        })
        let stack = UndoStack()
        let action = DeleteItemsAction(itemIds: [item.id], mediaStore: store, deleteService: service)
        do { try await stack.performAction(action); XCTFail("Expected partial result") }
        catch let error as DeleteService.PartialDeletionError { XCTAssertEqual(error.result.failedFileURLs, [item.mediaFiles[1]]) }
        XCTAssertTrue(stack.canUndo)
        XCTAssertTrue(stack.currentToast?.message.contains("some files") == true)
        let deleted = try await store.isSoftDeleted(id: item.id)
        XCTAssertTrue(deleted)
        do { _ = try await stack.undo(); XCTFail("Missing original must refuse Undo") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Finder Trash")) }
        XCTAssertTrue(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
        XCTAssertFalse(stack.currentToast?.message.hasPrefix("Undid:") == true)
        try FileManager.default.moveItem(at: removed.appendingPathExtension("test-trash"), to: removed)
        _ = try await stack.undo()
        XCTAssertFalse(stack.canUndo)
        XCTAssertTrue(stack.canRedo)
        let restored = try await store.isSoftDeleted(id: item.id)
        XCTAssertFalse(restored)
    }
}

private actor TrashProbe {
    private(set) var count = 0
    func record(_ url: URL) { count += 1 }
}
