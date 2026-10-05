import XCTest
import GRDB
import Darwin
@testable import MediaViewer

final class ImportDurabilityTests: XCTestCase {
    private var root: URL!
    private var archive: URL!
    private var source: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=")!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ImportDurability-\(UUID().uuidString)")
        archive = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        source = root.appendingPathComponent("source.png")
        try Self.png.write(to: source)
        database = DatabaseManager(databaseURL: root.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        store = MediaStore(database: database)
    }

    override func tearDown() async throws {
        store = nil
        database = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testFailureAtEachPublicationBoundaryRecoversWithoutRecopyingOrDuplicateRows() async throws {
        for boundary in [ImportOperation.Phase.staged, .mediaPublished, .filesPublished] {
            let file = root.appendingPathComponent("\(boundary.rawValue).png")
            try Self.png.write(to: file)
            let service = ImportService(mediaStore: store, visionQueue: nil, archivePath: archive, checkpoint: { phase in
                if phase == boundary { throw CocoaError(.fileWriteOutOfSpace) }
            })
            let failed = try await service.importFiles([file], tags: ["preserved"])
            XCTAssertEqual(failed.failedCount, 1)
            XCTAssertEqual(try Data(contentsOf: file), Self.png)
            let journal = ImportOperationJournal(archivePath: archive)
            let operation = try XCTUnwrap(journal.operations().first { $0.sourceURL == file })
            XCTAssertFalse(FileManager.default.fileExists(atPath: operation.metadataURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: journal.stagedMedia(operation).path))
            // Restart recovery must use the completed stage, not re-read source.
            try FileManager.default.removeItem(at: file)
            let restarted = ImportService(mediaStore: store, visionQueue: nil, archivePath: archive)
            let recovered = await restarted.recoverInterruptedImports()
            XCTAssertEqual(recovered.failedCount, 0)
            XCTAssertTrue(recovered.createdItemIds.contains(operation.itemID))
            let item = try await store.fetchItem(id: operation.itemID)
            XCTAssertEqual(item?.metadata.tags, ["preserved"])
            XCTAssertEqual(try Data(contentsOf: operation.destinationURL), Self.png)
            let again = await restarted.recoverInterruptedImports()
            XCTAssertEqual(again.importedCount, 0)
        }
        let count = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items") }
        XCTAssertEqual(count, 3)
    }

    func testSidecarCollisionPreservesUnrelatedFileAndRetriesSameAttempt() async throws {
        let journal = ImportOperationJournal(archivePath: archive)
        let service = ImportService(mediaStore: store, visionQueue: nil, archivePath: archive, checkpoint: { phase in
            if phase == .staged {
                let operation = try XCTUnwrap(journal.operations().first)
                try Data("unrelated sidecar".utf8).write(to: operation.metadataURL)
            }
        })
        let failed = try await service.importFiles([source])
        XCTAssertEqual(failed.failedCount, 1)
        let operation = try XCTUnwrap(journal.operations().first)
        XCTAssertEqual(try String(contentsOf: operation.metadataURL), "unrelated sidecar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: operation.destinationURL.path))
        let recovery = ImportService(mediaStore: store, visionQueue: nil, archivePath: archive)
        let stillFailed = await recovery.recoverInterruptedImports()
        XCTAssertEqual(stillFailed.failedCount, 1)
        XCTAssertEqual(try String(contentsOf: operation.metadataURL), "unrelated sidecar")
        try FileManager.default.removeItem(at: operation.metadataURL)
        let retried = try await recovery.importFiles([source])
        XCTAssertEqual(retried.createdItemIds, [operation.itemID])
        XCTAssertEqual(try journal.operations().count, 1)
    }

    func testCancellationPreservesBatchIntentAndRequiresExplicitRetry() async throws {
        let second = root.appendingPathComponent("second.png")
        try Self.png.write(to: second)
        let service = ImportService(mediaStore: store, visionQueue: nil, archivePath: archive, checkpoint: { phase in
            if phase == .mediaPublished { withUnsafeCurrentTask { $0?.cancel() } }
        })
        let sourceURL = source!
        let result = try await Task { try await service.importFiles([sourceURL, second]) }.value
        XCTAssertEqual(result.cancelledCount, 2)
        XCTAssertEqual(result.importedCount, 0)
        let journal = ImportOperationJournal(archivePath: archive)
        XCTAssertEqual(try journal.operations().count, 2)
        let recovery = ImportService(mediaStore: store, visionQueue: nil, archivePath: archive)
        let recovered = await recovery.recoverInterruptedImports()
        XCTAssertEqual(recovered.importedCount, 0)
        XCTAssertEqual(recovered.failedCount, 2)
        let retried = try await recovery.importFiles([sourceURL, second])
        XCTAssertEqual(retried.importedCount, 2)
        XCTAssertEqual(try Data(contentsOf: sourceURL), Self.png)
    }

    func testDatabaseCommitWinsOverLostJournalAcknowledgement() async throws {
        let service = ImportService(mediaStore: store, visionQueue: nil, archivePath: archive)
        let result = try await service.importFiles([source])
        let journal = ImportOperationJournal(archivePath: archive)
        var operation = try XCTUnwrap(journal.operations().first)
        operation.phase = .filesPublished
        try journal.save(operation)
        let recovered = await service.recoverInterruptedImports()
        XCTAssertEqual(recovered.createdItemIds, result.createdItemIds)
        let count = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items") }
        XCTAssertEqual(count, 1)
    }

    func testBatchReservesMediaAndSidecarNamesBeforeAnyCopy() async throws {
        let sibling = root.appendingPathComponent("another")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let duplicateName = sibling.appendingPathComponent("source.png")
        try Self.png.write(to: duplicateName)
        let service = ImportService(mediaStore: store, visionQueue: nil, archivePath: archive)
        let result = try await service.importFiles([source, duplicateName])
        XCTAssertEqual(result.importedCount, 2)
        let operations = try ImportOperationJournal(archivePath: archive).operations()
        XCTAssertEqual(Set(operations.map(\.destinationURL)).count, 2)
        XCTAssertEqual(Set(operations.map(\.metadataURL)).count, 2)
    }

    func testMalformedRecoveryRecordDoesNotBlockValidSiblingRecovery() async throws {
        let service = ImportService(mediaStore: store, visionQueue: nil, archivePath: archive, checkpoint: { phase in
            if phase == .staged { throw CocoaError(.fileWriteOutOfSpace) }
        })
        _ = try await service.importFiles([source])
        let journal = ImportOperationJournal(archivePath: archive)
        let corruptID = UUID()
        try FileManager.default.createDirectory(at: journal.folder(corruptID), withIntermediateDirectories: true)
        try Data("incomplete record".utf8).write(to: journal.recordURL(corruptID))
        let restarted = ImportService(mediaStore: store, visionQueue: nil, archivePath: archive)
        let result = await restarted.recoverInterruptedImports()
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.errors.first?.operationID, corruptID)
    }

    func testWatcherExcludesNestedHiddenStagingNotVisiblePeerFiles() {
        XCTAssertTrue(ArchiveWatcher.isHiddenArchivePath(archive.appendingPathComponent(".nodraw-imports/operation/visible.png"), archivePath: archive))
        XCTAssertTrue(ArchiveWatcher.isHiddenArchivePath(archive.appendingPathComponent("2026-09/.hidden.jpg"), archivePath: archive))
        XCTAssertFalse(ArchiveWatcher.isHiddenArchivePath(archive.appendingPathComponent("2026-09/visible.jpg"), archivePath: archive))
    }
}

/// One parent assertion launches the same test method as a disposable child.
/// The injected production checkpoint exits without unwinding or rollback.
final class ImportHardCrashTests: XCTestCase {
    func testHardCrashRecoveryAtPublicationAndDatabaseAcknowledgement() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let childPath = environment["NODRAW_IMPORT_CRASH_FIXTURE"],
           let boundary = environment["NODRAW_IMPORT_CRASH_BOUNDARY"] {
            let root = URL(fileURLWithPath: childPath)
            guard root.lastPathComponent.hasPrefix("nodraw-hard-import-"),
                  root.deletingLastPathComponent().resolvingSymlinksInPath() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else {
                XCTFail("Refusing non-temporary crash fixture")
                return
            }
            let database = DatabaseManager(databaseURL: root.appendingPathComponent("fixture.sqlite"))
            try await database.initialize()
            let service = ImportService(mediaStore: MediaStore(database: database), visionQueue: nil,
                archivePath: root.appendingPathComponent("archive"), checkpoint: { phase in
                    if phase.rawValue == boundary { Darwin._exit(73) }
                })
            _ = try await service.importFiles([root.appendingPathComponent("source.png")])
            XCTFail("Crash checkpoint was not reached")
            return
        }

        for boundary in [ImportOperation.Phase.mediaPublished, .filesPublished, .databaseCommitted] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("nodraw-hard-import-\(UUID())")
            let archive = root.appendingPathComponent("archive")
            try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.png")
            try ImportDurabilityTests.png.write(to: source)
            let log = root.appendingPathComponent("child.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            child.arguments = ["xctest", "-XCTest", "MediaViewerTests.ImportHardCrashTests/testHardCrashRecoveryAtPublicationAndDatabaseAcknowledgement", Bundle(for: Self.self).bundleURL.path]
            child.environment = environment.merging([
                "NODRAW_IMPORT_CRASH_FIXTURE": root.path,
                "NODRAW_IMPORT_CRASH_BOUNDARY": boundary.rawValue
            ]) { _, new in new }
            child.standardOutput = output
            child.standardError = output
            try child.run()
            let deadline = Date().addingTimeInterval(30)
            while child.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            if child.isRunning {
                child.terminate()
                XCTFail("Crash child exceeded deadline")
                return
            }
            let diagnostics = (try? String(contentsOf: log, encoding: .utf8)) ?? "No child log"
            XCTAssertEqual(child.terminationStatus, 73, diagnostics)
            guard child.terminationStatus == 73 else { return }
            let journal = ImportOperationJournal(archivePath: archive)
            let operation = try XCTUnwrap(journal.operations().first)
            XCTAssertTrue(FileManager.default.fileExists(atPath: operation.destinationURL.path))
            XCTAssertEqual(try Data(contentsOf: source), ImportDurabilityTests.png)
            // Force recovery to use the verified journal, never the source.
            try FileManager.default.removeItem(at: source)
            let database = DatabaseManager(databaseURL: root.appendingPathComponent("fixture.sqlite"))
            try await database.initialize()
            let store = MediaStore(database: database)
            let recovery = ImportService(mediaStore: store, visionQueue: nil, archivePath: archive)
            let result = await recovery.recoverInterruptedImports()
            XCTAssertEqual(result.failedCount, 0, result.errors.map(\.reason).joined(separator: "; "))
            XCTAssertEqual(result.createdItemIds, [operation.itemID])
            XCTAssertEqual(try Data(contentsOf: operation.destinationURL), ImportDurabilityTests.png)
            let count = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items") }
            XCTAssertEqual(count, 1)
            let repeated = await recovery.recoverInterruptedImports()
            XCTAssertEqual(repeated.importedCount, 0)
        }
    }
}

final class AnnotationAssetDurabilityTests: XCTestCase {
    func testFailedPNGWriteThrowsAndNeverReturnsAReference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationDurability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("existing unrelated file".utf8).write(to: root)
        let store = AnnotationAssetStore(assetDirectory: root)
        do { _ = try await store.savePNG(ImportDurabilityTests.png); XCTFail("Expected directory failure") }
        catch { XCTAssertEqual(try String(contentsOf: root), "existing unrelated file") }
    }

    func testCorruptExistingAssetIsNotOverwrittenOrAcknowledged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationDurability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AnnotationAssetStore(assetDirectory: root)
        let key = try await store.savePNG(ImportDurabilityTests.png)
        let path = root.appendingPathComponent("\(key).png")
        try Data("preserve corrupt evidence".utf8).write(to: path)
        do { _ = try await store.savePNG(ImportDurabilityTests.png); XCTFail("Expected corrupt-file failure") }
        catch { XCTAssertEqual(try String(contentsOf: path), "preserve corrupt evidence") }
    }
}
