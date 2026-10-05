import XCTest
import GRDB
@testable import MediaViewer

final class LibraryDropImportTests: XCTestCase {
    private var root: URL!
    private var archive: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!

    override func setUp() async throws {
        let support = try XCTUnwrap(ProcessInfo.processInfo.environment["NODRAW_APP_SUPPORT_DIR"])
        root = URL(fileURLWithPath: support).appendingPathComponent("LibraryDrop-\(UUID())")
        archive = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: root.appendingPathComponent("fixture.sqlite"))
        try await database.initialize()
        store = MediaStore(database: database)
    }

    override func tearDown() async throws {
        await store?.writeBackQueue.flushNow()
        store = nil
        database = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func service() -> ImportService {
        ImportService(mediaStore: store, visionQueue: nil, archivePath: archive)
    }

    private func bytes(_ suffix: String = "") -> Data {
        var data = ImportDurabilityTests.png
        data.append(Data(suffix.utf8))
        return data
    }

    private func file(_ name: String, contents: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }

    private func seed(_ name: String = "existing", contents: [Data] = [ImportDurabilityTests.png]) async throws -> MediaItem {
        let folder = archive.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sidecar = folder.appendingPathComponent("post.md")
        try "---\nsource: https://example.com/\(name)\nplatform: test\n---\n".write(to: sidecar, atomically: false, encoding: .utf8)
        let media = try contents.enumerated().map { index, contents in
            try file("archive/\(name)/post-\(index).png", contents: contents)
        }
        let item = MediaItem(id: UUID(), basePath: folder, metadataFile: sidecar, mediaFiles: media,
            metadata: MediaMetadata(source: URL(string: "https://example.com/\(name)")!, platform: "test"))
        try await store.insertItem(item)
        return item
    }

    private func rowCount() async throws -> Int {
        try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items") ?? 0 }
    }

    private func digestCount() async throws -> Int {
        try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM duplicate_digest_cache") ?? 0 }
    }

    private func archiveSnapshot() throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: archive, includingPropertiesForKeys: [.isRegularFileKey]))
        var files: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            files[url.path] = try Data(contentsOf: url)
        }
        return files
    }

    private func assertSkipped(_ result: ImportResult, existing item: MediaItem, source: URL,
        file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(result.importedCount, 0, file: file, line: line)
        XCTAssertEqual(result.failedCount, 0, file: file, line: line)
        XCTAssertEqual(result.skippedCount, 1, file: file, line: line)
        XCTAssertTrue(result.createdItemIds.isEmpty, file: file, line: line)
        let skipped = try XCTUnwrap(result.skippedItems.first, file: file, line: line)
        XCTAssertEqual(skipped.existingItemID, item.id, file: file, line: line)
        XCTAssertEqual(skipped.sourceURL, source, file: file, line: line)
        XCTAssertFalse(skipped.existingName.isEmpty, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skipped.existingURL.path), file: file, line: line)
    }

    func testArchiveFolderAndMediaDropLeaveItemAndSidecarUntouched() async throws {
        let item = try await seed()
        let importer = service()
        let before = try archiveSnapshot()
        for source in [item.basePath, item.mediaFiles[0]] {
            let result = try await importer.importFiles([source], options: .fileDrop)
            try assertSkipped(result, existing: item, source: source)
        }
        XCTAssertEqual(try archiveSnapshot(), before)
        XCTAssertEqual(try ImportOperationJournal(archivePath: archive).operations().count, 0)
        let count = try await rowCount()
        XCTAssertEqual(count, 1)
    }

    func testUnindexedArchiveMediaWithoutSidecarIsSkipped() async throws {
        let orphan = try file("archive/unindexed.png", contents: bytes("orphan"))
        let importer = service()
        let before = try archiveSnapshot()
        let result = try await importer.importFiles([orphan], options: .fileDrop)
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        let skipped = try XCTUnwrap(result.skippedItems.first)
        XCTAssertNil(skipped.existingItemID)
        XCTAssertEqual(skipped.existingURL, orphan)
        XCTAssertFalse(skipped.existingName.isEmpty)
        XCTAssertEqual(try archiveSnapshot(), before)
        XCTAssertEqual(try ImportOperationJournal(archivePath: archive).operations().count, 0)
        let count = try await rowCount()
        XCTAssertEqual(count, 0)
    }

    func testArchiveSymlinkAliasCannotReimportAnItem() async throws {
        let item = try await seed()
        let alias = root.appendingPathComponent("outside-alias.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: item.mediaFiles[0])
        let importer = service()
        let before = try archiveSnapshot()
        let result = try await importer.importFiles([alias], options: .fileDrop)
        try assertSkipped(result, existing: item, source: alias)
        XCTAssertEqual(try archiveSnapshot(), before)
        XCTAssertEqual(try ImportOperationJournal(archivePath: archive).operations().count, 0)
    }

    func testArchivePrefixPeerIsExternalAndImports() async throws {
        _ = try await seed()
        let peer = try file("archive-peer/new.png", contents: bytes("new peer bytes"))
        let result = try await service().importFiles([peer], options: .fileDrop)
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(try Data(contentsOf: peer), bytes("new peer bytes"))
        let count = try await rowCount()
        XCTAssertEqual(count, 2)
    }

    func testExternalByteIdenticalFileIsSkippedWithoutReceiptsOrDigestCache() async throws {
        let item = try await seed()
        let source = try file("outside/renamed.png", contents: ImportDurabilityTests.png)
        try "---\nsource: https://example.com/changed-sidecar\nplatform: import\n---\n".write(
            to: source.deletingPathExtension().appendingPathExtension("md"), atomically: false, encoding: .utf8)
        let importer = service()
        XCTAssertEqual(try ImportOperationJournal(archivePath: archive).operations().count, 0)
        let cacheCount = try await digestCount()
        XCTAssertEqual(cacheCount, 0)
        let before = try archiveSnapshot()
        let sidecarBefore = try Data(contentsOf: source.deletingPathExtension().appendingPathExtension("md"))
        let result = try await importer.importFiles([source], options: .fileDrop)
        try assertSkipped(result, existing: item, source: source)
        XCTAssertEqual(try Data(contentsOf: source), ImportDurabilityTests.png)
        XCTAssertEqual(try Data(contentsOf: source.deletingPathExtension().appendingPathExtension("md")), sidecarBefore)
        XCTAssertEqual(try archiveSnapshot(), before)
        XCTAssertEqual(try ImportOperationJournal(archivePath: archive).operations().count, 0)
        let count = try await rowCount()
        XCTAssertEqual(count, 1)
    }

    func testMixedArchiveExistingAndNewDropOnlyImportsNewFile() async throws {
        let item = try await seed()
        let duplicate = try file("outside/copy.png", contents: ImportDurabilityTests.png)
        let newFile = try file("outside/new.png", contents: bytes("new media"))
        let before = try archiveSnapshot()
        let result = try await service().importFiles([item.basePath, duplicate, newFile], options: .fileDrop)
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.skippedItems.compactMap(\.existingItemID), [item.id, item.id])
        XCTAssertEqual(Set(result.skippedItems.map(\.sourceURL)), Set([item.basePath, duplicate]))
        XCTAssertEqual(result.createdItemIds.count, 1)
        let created = try await store.fetchItem(id: XCTUnwrap(result.createdItemIds.first))
        let media = try XCTUnwrap(created?.mediaFiles.first)
        XCTAssertEqual(try Data(contentsOf: media), bytes("new media"))
        let after = try archiveSnapshot()
        for (path, contents) in before { XCTAssertEqual(after[path], contents) }
        XCTAssertEqual(try Data(contentsOf: duplicate), ImportDurabilityTests.png)
        XCTAssertEqual(try Data(contentsOf: newFile), bytes("new media"))
        XCTAssertEqual(try ImportOperationJournal(archivePath: archive).operations().count, 1)
        let count = try await rowCount()
        XCTAssertEqual(count, 2)
    }

    func testExternalCopyOfSecondaryGalleryAssetIsSkipped() async throws {
        let item = try await seed(contents: [bytes("first"), bytes("secondary")])
        let source = try file("outside/secondary-renamed.png", contents: bytes("secondary"))
        let result = try await service().importFiles([source], options: .fileDrop)
        try assertSkipped(result, existing: item, source: source)
        XCTAssertEqual(try ImportOperationJournal(archivePath: archive).operations().count, 0)
    }

    func testExternalCopyOfDeletedItemImportsWithoutRestoringTombstone() async throws {
        let item = try await seed()
        try await store.softDelete(ids: [item.id], reason: .user)
        await store.writeBackQueue.flushNow()
        let source = try file("outside/new-copy.png", contents: ImportDurabilityTests.png)
        let result = try await service().importFiles([source], options: .fileDrop)
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.failedCount, 0)
        let tombstone = try await store.fetchItem(id: item.id)
        XCTAssertEqual(tombstone?.metadata.deleted, true)
        XCTAssertEqual(tombstone?.deletionReason, .user)
        XCTAssertFalse(result.createdItemIds.contains(item.id))
        let count = try await rowCount()
        XCTAssertEqual(count, 2)
    }

    func testChangedArchiveAssetInvalidatesPreviouslyCachedDigest() async throws {
        let original = bytes("AAAA")
        let replacement = bytes("BBBB")
        let item = try await seed(contents: [original])
        let source = try file("outside/copy.png", contents: original)
        let importer = service()
        let first = try await importer.importFiles([source], options: .fileDrop)
        try assertSkipped(first, existing: item, source: source)
        let cacheCount = try await digestCount()
        XCTAssertEqual(cacheCount, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: item.mediaFiles[0].path)
        let modifiedDate = try XCTUnwrap(attributes[.modificationDate] as? Date)
        try replacement.write(to: item.mediaFiles[0], options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modifiedDate], ofItemAtPath: item.mediaFiles[0].path)
        let second = try await importer.importFiles([source], options: .fileDrop)
        XCTAssertEqual(second.importedCount, 1)
        XCTAssertEqual(second.skippedCount, 0)
        XCTAssertEqual(second.failedCount, 0)
        XCTAssertEqual(try Data(contentsOf: item.mediaFiles[0]), replacement)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try ImportOperationJournal(archivePath: archive).operations().count, 1)
        let count = try await rowCount()
        XCTAssertEqual(count, 2)
    }

    func testMultiFileDropBuildsOneIndexAndStatsEachExistingFileOnce() async throws {
        let first = try await seed("first", contents: [bytes("first"), bytes("secondary")])
        let second = try await seed("second", contents: [bytes("second")])
        let duplicate = try file("outside/copy.png", contents: bytes("secondary"))
        let newFile = try file("outside/new.png", contents: bytes("different new file size"))
        let observations = IndexObservations()
        let importer = ImportService(mediaStore: store, visionQueue: nil, archivePath: archive,
            libraryFileVersionReader: { url in
                observations.recordRead(url)
                return try DuplicateFileVersion.read(url)
            }, libraryIndexDidBuild: { observations.recordBuild($0) })
        let result = try await importer.importFiles([first.mediaFiles[0], duplicate, newFile], options: .fileDrop)
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertEqual(result.failedCount, 0)
        let state = observations.snapshot()
        XCTAssertEqual(state.reads, Dictionary(uniqueKeysWithValues: (first.mediaFiles + second.mediaFiles).map { ($0.path, 1) }))
        XCTAssertEqual(state.builds.count, 1)
        let metrics = try XCTUnwrap(state.builds.first)
        XCTAssertEqual(metrics.itemCount, 2)
        XCTAssertEqual(metrics.fileCount, 3)
        XCTAssertEqual(metrics.pageCount, 1)
        XCTAssertGreaterThanOrEqual(metrics.durationSeconds, 0)
    }

    private final class IndexObservations: @unchecked Sendable {
        private let lock = NSLock()
        private var reads: [String: Int] = [:]
        private var builds: [ImportLibraryDuplicatePrevention.IndexMetrics] = []

        func recordRead(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            reads[url.path, default: 0] += 1
        }

        func recordBuild(_ metrics: ImportLibraryDuplicatePrevention.IndexMetrics) {
            lock.lock()
            defer { lock.unlock() }
            builds.append(metrics)
        }

        func snapshot() -> (reads: [String: Int], builds: [ImportLibraryDuplicatePrevention.IndexMetrics]) {
            lock.lock()
            defer { lock.unlock() }
            return (reads, builds)
        }
    }

    func testFileDropOptionsOverrideExplicitCopyAndPreserveFileDatePreference() async throws {
        let item = try await seed()
        let source = try file("outside/copy.png", contents: ImportDurabilityTests.png)
        let options = ImportOptions(useFileDateAsArchiveDate: true, repeatPolicy: .importAnotherCopy).forFileDrop
        XCTAssertTrue(options.useFileDateAsArchiveDate)
        XCTAssertTrue(options.preventLibraryDuplicates)
        let result = try await service().importFiles([source], options: options)
        try assertSkipped(result, existing: item, source: source)
        let count = try await rowCount()
        XCTAssertEqual(count, 1)
    }
}
