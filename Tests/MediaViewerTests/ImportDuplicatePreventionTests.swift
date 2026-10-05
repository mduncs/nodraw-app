import XCTest
import GRDB
@testable import MediaViewer

final class ImportDuplicatePreventionTests: XCTestCase {
    private var root: URL!
    private var archive: URL!
    private var source: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ImportReplay-\(UUID())")
        archive = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        source = root.appendingPathComponent("source.png")
        try ImportDurabilityTests.png.write(to: source)
        database = DatabaseManager(databaseURL: root.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        store = MediaStore(database: database)
    }

    override func tearDown() async throws {
        store = nil
        database = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func service() -> ImportService {
        ImportService(mediaStore: store, visionQueue: nil, archivePath: archive)
    }

    private func rowCount() async throws -> Int {
        try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items") ?? 0 }
    }

    func testRepeatedAndSymlinkSourceURLsCreateOneOperationBeforePublication() async throws {
        let alias = root.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let result = try await service().importFiles([source, source, alias])
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertEqual(result.createdItemIds.count, 1)
        XCTAssertEqual(try ImportOperationJournal(archivePath: archive).operations().count, 1)
        let count = try await rowCount()
        XCTAssertEqual(count, 1)
    }

    func testCompletedReceiptSkipsUnchangedSourceAcrossServiceRestart() async throws {
        _ = try await service().importFiles([source], tags: ["original"])
        let result = try await service().importFiles([source], tags: ["not-applied-to-skipped-item"])
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(try ImportOperationJournal(archivePath: archive).operations().count, 1)
        let count = try await rowCount()
        XCTAssertEqual(count, 1)
    }

    func testTwoConcurrentServicesCoalesceSameSource() async throws {
        let firstService = service(), secondService = service()
        let sourceURL = source!
        async let first = firstService.importFiles([sourceURL])
        async let second = secondService.importFiles([sourceURL])
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.importedCount + b.importedCount, 1)
        XCTAssertEqual(a.skippedCount + b.skippedCount, 1)
        XCTAssertEqual(try ImportOperationJournal(archivePath: archive).operations().count, 1)
        let count = try await rowCount()
        XCTAssertEqual(count, 1)
    }

    func testChangedSourceAndExplicitCopyAreNotSuppressed() async throws {
        _ = try await service().importFiles([source])
        var changed = ImportDurabilityTests.png
        changed.append(Data("new source bytes".utf8))
        try changed.write(to: source)
        let updated = try await service().importFiles([source])
        XCTAssertEqual(updated.importedCount, 1)
        let copy = try await service().importFiles([source], options: ImportOptions(useFileDateAsArchiveDate: false, repeatPolicy: .importAnotherCopy))
        XCTAssertEqual(copy.importedCount, 1)
        let count = try await rowCount()
        XCTAssertEqual(count, 3)
    }

    func testChangedSourceSidecarIsNotSuppressed() async throws {
        let sidecar = source.deletingPathExtension().appendingPathExtension("md")
        try "---\nsource: https://example.com/a\nplatform: import\nnotes: first\n---\n".write(to: sidecar, atomically: true, encoding: .utf8)
        _ = try await service().importFiles([source])
        try "---\nsource: https://example.com/a\nplatform: import\nnotes: second\n---\n".write(to: sidecar, atomically: true, encoding: .utf8)
        let updated = try await service().importFiles([source])
        XCTAssertEqual(updated.importedCount, 1)
        let item = try await store.fetchItem(id: XCTUnwrap(updated.createdItemIds.first))
        XCTAssertEqual(item?.metadata.notes, "second")
    }

    func testArchiveResidentDropDoesNotCopyBackIntoArchive() async throws {
        _ = try await service().importFiles([source])
        let operation = try XCTUnwrap(ImportOperationJournal(archivePath: archive).operations().first)
        let result = try await service().importFiles([operation.destinationURL])
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(try ImportOperationJournal(archivePath: archive).operations().count, 1)
    }

    func testDistinctSourcesWithSameFilenameStayIndependentAfterRealStartupScan() async throws {
        var sources: [URL] = []
        for index in 0..<12 {
            let folder = root.appendingPathComponent("input-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("photo.png")
            try ImportDurabilityTests.png.write(to: file)
            sources.append(file)
        }
        let result = try await service().importFiles(sources)
        XCTAssertEqual(result.importedCount, 12)
        let scanned = try await ArchiveWatcher(archivePath: archive).scanArchive()
        XCTAssertEqual(scanned.count, 12)
        XCTAssertTrue(scanned.values.allSatisfy { $0.metadataFile != nil && $0.mediaFiles.count == 1 })
        for files in scanned.values {
            XCTAssertEqual(files.metadataFile?.deletingPathExtension(), files.mediaFiles.first?.deletingPathExtension())
        }
    }

    func testFileReappearanceCannotRestoreManualOrCombinedTombstones() async throws {
        let first = try await service().importFiles([source])
        let second = try await service().importFiles([source], options: ImportOptions(useFileDateAsArchiveDate: false, repeatPolicy: .importAnotherCopy))
        let third = try await service().importFiles([source], options: ImportOptions(useFileDateAsArchiveDate: false, repeatPolicy: .importAnotherCopy))
        let user = try XCTUnwrap(first.createdItemIds.first)
        let combined = try XCTUnwrap(second.createdItemIds.first)
        let missing = try XCTUnwrap(third.createdItemIds.first)
        try await store.softDelete(ids: [user], reason: .user)
        try await store.softDelete(ids: [combined], reason: .combined)
        try await store.softDelete(ids: [missing], reason: .missingFiles)
        let restored = try await store.restoreMissingFiles(ids: [user, combined, missing])
        XCTAssertEqual(restored, [missing])
        let userItem = try await store.fetchItem(id: user)
        let combinedItem = try await store.fetchItem(id: combined)
        let missingItem = try await store.fetchItem(id: missing)
        XCTAssertEqual(userItem?.metadata.deleted, true)
        XCTAssertEqual(combinedItem?.metadata.deleted, true)
        XCTAssertEqual(missingItem?.metadata.deleted, false)
        XCTAssertEqual(missingItem?.deletionReason, nil)
    }
}

final class ArchiveAssociationResolverTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ArchiveAssociation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    @discardableResult
    private func file(_ name: String, body: String = "") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
        return url
    }

    func testProductionStartupAndRuntimeAgreeOnMultidigitGallery() async throws {
        let sidecar = try file("post.md")
        let first = try file("post-1.jpg")
        let tenth = try file("post-10.jpg")
        _ = try file("post.context.png")
        let scanned = try await ArchiveWatcher(archivePath: root).scanArchive()
        XCTAssertEqual(scanned.count, 1)
        let startup = try XCTUnwrap(scanned[sidecar.deletingPathExtension()])
        let runtime = try XCTUnwrap(ArchiveAssociationResolver.files(for: sidecar, archivePath: root))
        XCTAssertEqual(startup.mediaFiles, [first, tenth])
        XCTAssertEqual(runtime.mediaFiles, startup.mediaFiles)
        XCTAssertEqual(runtime.contextImage, startup.contextImage)
        XCTAssertEqual(ArchiveAssociationResolver.owner(of: tenth, archivePath: root), sidecar)
    }

    func testExactSidecarReservesCollisionCopyBeforeEmbedsOrGallery() async throws {
        let original = try file("photo.md", body: "![[photo_1.jpg]]")
        let copy = try file("photo_1.md")
        let originalMedia = try file("photo.jpg")
        let copiedMedia = try file("photo_1.jpg")
        let scanned = try await ArchiveWatcher(archivePath: root).scanArchive()
        XCTAssertEqual(scanned.count, 2)
        XCTAssertEqual(scanned[original.deletingPathExtension()]?.mediaFiles, [originalMedia])
        XCTAssertEqual(scanned[copy.deletingPathExtension()]?.mediaFiles, [copiedMedia])
        XCTAssertEqual(ArchiveAssociationResolver.owner(of: copiedMedia, archivePath: root), copy)
    }

    func testExplicitEmbedClaimsBeforeGalleryAndDoesNotSearchRemoteStatus() async throws {
        let gallery = try file("post.md")
        let explicit = try file("quote.md", body: "---\nsource: https://x.com/a/status/999\nplatform: twitter\n---\n![[post-10.jpg]]\n![[#]]")
        let first = try file("post-1.jpg")
        let claimed = try file("post-10.jpg")
        _ = try file("elsewhere/capture-999.jpg")
        let scanned = try await ArchiveWatcher(archivePath: root).scanArchive()
        XCTAssertEqual(scanned[gallery.deletingPathExtension()]?.mediaFiles, [first])
        XCTAssertEqual(scanned[explicit.deletingPathExtension()]?.mediaFiles, [claimed])
        XCTAssertEqual(ArchiveAssociationResolver.files(for: explicit, archivePath: root)?.mediaFiles, [claimed])
    }

    func testDistinctContextSidecarDoesNotOverwriteOriginalCapture() async throws {
        let regular = try file("capture.md")
        let context = try file("capture.context.md", body: "![[capture.jpg]]")
        let media = try file("capture.jpg")
        let screenshot = try file("capture.context.png")
        let scanned = try await ArchiveWatcher(archivePath: root).scanArchive()
        XCTAssertEqual(scanned.count, 2)
        XCTAssertEqual(scanned[regular.deletingPathExtension()]?.mediaFiles, [media])
        XCTAssertNil(scanned[regular.deletingPathExtension()]?.contextImage)
        XCTAssertEqual(scanned[context.deletingPathExtension()]?.mediaFiles, [])
        XCTAssertEqual(scanned[context.deletingPathExtension()]?.contextImage, screenshot)
    }

    func testAmbiguousGalleryNeverPicksAnArbitraryCapture() async throws {
        let first = try file("capture-1.md")
        let second = try file("capture-2.md")
        let media1 = try file("capture-1.jpg")
        let media2 = try file("capture-2.jpg")
        let extra = try file("capture-10.jpg")
        let scanned = try await ArchiveWatcher(archivePath: root).scanArchive()
        XCTAssertEqual(scanned[first.deletingPathExtension()]?.mediaFiles, [media1])
        XCTAssertEqual(scanned[second.deletingPathExtension()]?.mediaFiles, [media2])
        XCTAssertNil(ArchiveAssociationResolver.owner(of: extra, archivePath: root))
        XCTAssertNil(scanned[extra.deletingPathExtension()]?.metadataFile)
    }
}
