import XCTest
import GRDB
@testable import MediaViewer

final class StartupScanCacheTests: XCTestCase {
    private var tempDir: URL!
    private var databaseManager: DatabaseManager!
    private var mediaStore: MediaStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StartupScanCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        databaseManager = DatabaseManager(databaseURL: tempDir.appendingPathComponent("test.sqlite"))
        mediaStore = MediaStore(database: databaseManager)
        try await databaseManager.initialize()
    }

    override func tearDown() async throws {
        databaseManager = nil
        mediaStore = nil

        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil

        try await super.tearDown()
    }

    func testInsertedItemsPopulateStartupScanCache() async throws {
        let item = try makeItem()
        try await mediaStore.insertItem(item)

        let states = try await mediaStore.fetchStartupScanStates()
        let state = try XCTUnwrap(states[item.metadataFile.path])
        let fingerprint = try XCTUnwrap(MetadataFileFingerprint.current(for: item.metadataFile))

        XCTAssertTrue(state.matchesDiscoveredFiles(mediaFiles: item.mediaFiles, contextImage: nil))
        XCTAssertTrue(state.matchesCache(fingerprint: fingerprint, mediaFiles: item.mediaFiles, contextImage: nil))

        try changedMetadataContent.write(to: item.metadataFile, atomically: true, encoding: .utf8)
        let changedFingerprint = try XCTUnwrap(MetadataFileFingerprint.current(for: item.metadataFile))

        XCTAssertTrue(state.matchesDiscoveredFiles(mediaFiles: item.mediaFiles, contextImage: nil))
        XCTAssertFalse(state.matchesCache(fingerprint: changedFingerprint, mediaFiles: item.mediaFiles, contextImage: nil))
    }

    func testBackfillStartupScanCachePopulatesLegacyRows() async throws {
        let item = try makeItem()
        let record = MediaItemRecord(from: item)

        try await databaseManager.write { db in
            try record.insert(db)
        }

        var states = try await mediaStore.fetchStartupScanStates()
        var state = try XCTUnwrap(states[item.metadataFile.path])
        XCTAssertNil(state.cachedFingerprint)

        let fingerprint = try XCTUnwrap(MetadataFileFingerprint.current(for: item.metadataFile))
        try await mediaStore.backfillStartupScanCache([(state: state, fingerprint: fingerprint)])

        states = try await mediaStore.fetchStartupScanStates()
        state = try XCTUnwrap(states[item.metadataFile.path])
        XCTAssertTrue(state.matchesCache(fingerprint: fingerprint, mediaFiles: item.mediaFiles, contextImage: nil))
    }

    func testStartupScanCacheTracksContextImageAndMediaFileSet() async throws {
        let item = try makeItem(includeContextImage: true)
        try await mediaStore.insertItem(item)

        let states = try await mediaStore.fetchStartupScanStates()
        let state = try XCTUnwrap(states[item.metadataFile.path])
        let fingerprint = try XCTUnwrap(MetadataFileFingerprint.current(for: item.metadataFile))
        let extraMediaFile = item.basePath.appendingPathComponent("\(UUID().uuidString).png")

        XCTAssertTrue(state.matchesDiscoveredFiles(mediaFiles: item.mediaFiles, contextImage: item.contextImage))
        XCTAssertTrue(state.matchesCache(fingerprint: fingerprint, mediaFiles: item.mediaFiles, contextImage: item.contextImage))
        XCTAssertFalse(state.matchesDiscoveredFiles(mediaFiles: item.mediaFiles + [extraMediaFile], contextImage: item.contextImage))
        XCTAssertFalse(state.matchesCache(fingerprint: fingerprint, mediaFiles: item.mediaFiles, contextImage: nil))
    }

    func testStartupScanCacheMatchesDiscoveredMediaFilesInStableOrder() async throws {
        let item = try makeItem(mediaFileCount: 2)
        try await mediaStore.insertItem(item)

        let states = try await mediaStore.fetchStartupScanStates()
        let state = try XCTUnwrap(states[item.metadataFile.path])
        let fingerprint = try XCTUnwrap(MetadataFileFingerprint.current(for: item.metadataFile))
        let reversedMediaFiles = Array(item.mediaFiles.reversed())

        XCTAssertTrue(state.matchesDiscoveredFiles(mediaFiles: reversedMediaFiles, contextImage: nil))
        XCTAssertTrue(state.matchesCache(fingerprint: fingerprint, mediaFiles: reversedMediaFiles, contextImage: nil))
    }

    func testUpdatingItemPathReplacesStartupScanCacheRow() async throws {
        let item = try makeItem()
        try await mediaStore.insertItem(item)
        let initialCacheRows = try await cacheRowCount(metadataPath: item.metadataFile.path)
        XCTAssertEqual(initialCacheRows, 1)

        let movedBasePath = tempDir.appendingPathComponent("2026-05", isDirectory: true)
        let movedMetadataFile = movedBasePath.appendingPathComponent(item.metadataFile.lastPathComponent)
        let movedMediaFile = movedBasePath.appendingPathComponent(item.mediaFiles[0].lastPathComponent)
        try FileManager.default.createDirectory(at: movedBasePath, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: item.metadataFile, to: movedMetadataFile)
        try FileManager.default.moveItem(at: item.mediaFiles[0], to: movedMediaFile)

        let movedItem = MediaItem(
            id: item.id,
            basePath: movedBasePath,
            metadataFile: movedMetadataFile,
            mediaFiles: [movedMediaFile],
            metadata: item.metadata,
            aspectRatio: item.aspectRatio
        )
        try await mediaStore.updateItem(movedItem)

        let states = try await mediaStore.fetchStartupScanStates()
        let state = try XCTUnwrap(states[movedMetadataFile.path])
        let fingerprint = try XCTUnwrap(MetadataFileFingerprint.current(for: movedMetadataFile))

        XCTAssertNil(states[item.metadataFile.path])
        XCTAssertTrue(state.matchesCache(fingerprint: fingerprint, mediaFiles: [movedMediaFile], contextImage: nil))
        let oldCacheRows = try await cacheRowCount(metadataPath: item.metadataFile.path)
        let movedCacheRows = try await cacheRowCount(metadataPath: movedMetadataFile.path)
        XCTAssertEqual(oldCacheRows, 0)
        XCTAssertEqual(movedCacheRows, 1)
    }

    private var metadataContent: String {
        """
        ---
        source: https://example.com/original
        platform: test
        archived: 2026-04-25T12:00:00Z
        tags: []
        ---

        """
    }

    private var changedMetadataContent: String {
        """
        ---
        source: https://example.com/changed
        platform: test
        archived: 2026-04-25T12:00:00Z
        tags: []
        notes: changed
        ---

        """
    }

    private func makeItem(mediaFileCount: Int = 1, includeContextImage: Bool = false) throws -> MediaItem {
        let id = UUID()
        let basePath = tempDir.appendingPathComponent("2026-04", isDirectory: true)
        try FileManager.default.createDirectory(at: basePath, withIntermediateDirectories: true)

        let metadataFile = basePath.appendingPathComponent("\(id.uuidString).md")
        var mediaFiles: [URL] = []
        let contextImage = includeContextImage ? basePath.appendingPathComponent("\(id.uuidString).context.png") : nil
        try metadataContent.write(to: metadataFile, atomically: true, encoding: .utf8)
        for index in 0..<mediaFileCount {
            let suffix = index == 0 ? "" : "-\(index + 1)"
            let mediaFile = basePath.appendingPathComponent("\(id.uuidString)\(suffix).jpg")
            FileManager.default.createFile(atPath: mediaFile.path, contents: Data([0xFF, 0xD8, 0xFF, 0xD9]))
            mediaFiles.append(mediaFile)
        }
        if let contextImage {
            FileManager.default.createFile(atPath: contextImage.path, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        }

        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: metadataFile,
            mediaFiles: mediaFiles,
            contextImage: contextImage,
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/original")!,
                platform: "test",
                archivedDate: Date(timeIntervalSince1970: 1_777_118_400)
            ),
            aspectRatio: 1.0
        )
    }

    private func cacheRowCount(metadataPath: String) async throws -> Int {
        try await databaseManager.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM archive_scan_cache WHERE metadataFileString = ?",
                arguments: [metadataPath]
            ) ?? 0
        }
    }
}
