import XCTest
import GRDB
@testable import MediaViewer

/// Tests for WindowedGridDataSource - windowed loading for virtualized grids.
/// Uses real MediaStore with a test database for proper isolation.
@MainActor
final class WindowedGridDataSourceTests: XCTestCase {

    // MARK: - Setup

    private var testDatabaseManager: DatabaseManager!
    private var tempDir: URL!
    private var mediaStore: MediaStore!
    private var sut: WindowedGridDataSource!

    override func setUp() async throws {
        // Create temp directory
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowedGridDataSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create test database via DatabaseManager (runs all migrations)
        let dbPath = tempDir.appendingPathComponent("test.sqlite")
        testDatabaseManager = DatabaseManager(databaseURL: dbPath)
        try await testDatabaseManager.initialize()

        // Create MediaStore backed by test database
        mediaStore = MediaStore(database: testDatabaseManager)

        // Create SUT
        let heightIndex = MasonryHeightIndex(columnCount: 4, spacing: 8, columnWidth: 200)
        sut = WindowedGridDataSource(
            mediaStore: mediaStore,
            heightIndex: heightIndex,
            windowSize: 100,
            bufferSize: 20,
            debounceMs: 10  // Short for testing
        )
    }

    override func tearDown() async throws {
        sut = nil
        mediaStore = nil
        testDatabaseManager = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Initialization Tests

    func testInitialState() {
        XCTAssertTrue(sut.windowedItems.isEmpty)
        XCTAssertFalse(sut.isLoading)
        XCTAssertEqual(sut.totalCount, 0)
        XCTAssertEqual(sut.windowOffset, 0)
    }

    // MARK: - Load Initial Tests

    func testLoadInitialEmpty() async {
        await sut.loadInitial()

        XCTAssertTrue(sut.windowedItems.isEmpty)
        XCTAssertEqual(sut.totalCount, 0)
        XCTAssertEqual(sut.windowOffset, 0)
    }

    func testLoadInitialWithItems() async throws {
        let items = createTestItems(count: 50)
        try await insertItems(items)

        await sut.loadInitial()

        XCTAssertEqual(sut.windowedItems.count, 50)
        XCTAssertEqual(sut.totalCount, 50)
        XCTAssertEqual(sut.windowOffset, 0)
    }

    func testLoadInitialWithMoreItemsThanWindowSize() async throws {
        let items = createTestItems(count: 250)
        try await insertItems(items)

        await sut.loadInitial()

        // Should only load window size
        XCTAssertEqual(sut.windowedItems.count, 100)
        XCTAssertEqual(sut.totalCount, 250)
        XCTAssertEqual(sut.windowOffset, 0)
    }

    func testLoadInitialWithFilter() async throws {
        let twitterItems = createTestItems(count: 30, platform: "twitter")
        let instaItems = createTestItems(count: 20, platform: "instagram")
        try await insertItems(twitterItems + instaItems)

        var filter = FilterState()
        filter.platform = "twitter"
        await sut.loadInitial(filter: filter)

        XCTAssertEqual(sut.windowedItems.count, 30)
        XCTAssertEqual(sut.totalCount, 30)
        XCTAssertTrue(sut.windowedItems.allSatisfy { $0.metadata.platform == "twitter" })
    }

    func testLoadInitialWithBlueskyAliasFilter() async throws {
        let bskyItems = createTestItems(count: 12, platform: "bsky")
        let blueskyItems = createTestItems(count: 8, platform: "bluesky")
        let twitterItems = createTestItems(count: 5, platform: "twitter")
        try await insertItems(bskyItems + blueskyItems + twitterItems)

        var filter = FilterState()
        filter.platform = "bluesky"
        await sut.loadInitial(filter: filter)

        XCTAssertEqual(sut.totalCount, 20)
        XCTAssertEqual(sut.windowedItems.count, 20)
        XCTAssertTrue(sut.windowedItems.allSatisfy { ["bsky", "bluesky"].contains($0.metadata.platform) })
    }

    // MARK: - Window Loading Tests

    func testLoadWindowMidRange() async throws {
        let items = createTestItems(count: 500)
        try await insertItems(items)

        await sut.loadInitial()
        XCTAssertEqual(sut.windowOffset, 0)

        // Load window in middle
        await sut.loadWindow(from: 200, to: 300)

        // Window should have shifted to center on requested range
        XCTAssertTrue(sut.windowOffset > 0)
        XCTAssertEqual(sut.windowedItems.count, 100)
    }

    func testLoadWindowAtEnd() async throws {
        let items = createTestItems(count: 500)
        try await insertItems(items)

        await sut.loadInitial()

        // Load window at end
        await sut.loadWindow(from: 450, to: 500)

        XCTAssertTrue(sut.windowOffset > 0)
        XCTAssertLessThanOrEqual(sut.windowedItems.count, 100)
    }

    func testLoadWindowClampsToValidRange() async throws {
        let items = createTestItems(count: 50)
        try await insertItems(items)

        await sut.loadInitial()

        // Request beyond actual count
        await sut.loadWindow(from: 100, to: 200)

        // Should not crash, items unchanged
        XCTAssertEqual(sut.windowedItems.count, 50)
    }

    // MARK: - Scroll Handling Tests

    func testOnScrollUpdatesWindow() async throws {
        let items = createTestItems(count: 500)
        try await insertItems(items)

        await sut.loadInitial()

        // Rapid scroll calls should not crash
        sut.onScroll(offset: 100, viewportHeight: 600)
        sut.onScroll(offset: 200, viewportHeight: 600)
        sut.onScroll(offset: 300, viewportHeight: 600)

        // Wait for debounce
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // Basic sanity check - windowedItems should still exist
        XCTAssertFalse(sut.windowedItems.isEmpty)
    }

    // MARK: - Filter Update Tests

    func testUpdateFilter() async throws {
        let twitterItems = createTestItems(count: 30, platform: "twitter")
        let instaItems = createTestItems(count: 20, platform: "instagram")
        try await insertItems(twitterItems + instaItems)

        // Initial load - all items
        await sut.loadInitial()
        XCTAssertEqual(sut.totalCount, 50)

        // Update filter
        var filter = FilterState()
        filter.platform = "instagram"
        await sut.updateFilter(filter)

        XCTAssertEqual(sut.totalCount, 20)
        XCTAssertTrue(sut.windowedItems.allSatisfy { $0.metadata.platform == "instagram" })
    }

    func testUpdateFilterWithBskyAlias() async throws {
        let bskyItems = createTestItems(count: 7, platform: "bsky")
        let blueskyItems = createTestItems(count: 9, platform: "bluesky")
        let redditItems = createTestItems(count: 4, platform: "reddit")
        try await insertItems(bskyItems + blueskyItems + redditItems)

        await sut.loadInitial()
        XCTAssertEqual(sut.totalCount, 20)

        var filter = FilterState()
        filter.platform = "bsky"
        await sut.updateFilter(filter)

        XCTAssertEqual(sut.totalCount, 16)
        XCTAssertEqual(sut.windowedItems.count, 16)
        XCTAssertTrue(sut.windowedItems.allSatisfy { ["bsky", "bluesky"].contains($0.metadata.platform) })
    }

    // MARK: - Window Query Tests

    func testIsInWindow() async throws {
        let items = createTestItems(count: 200)
        try await insertItems(items)

        await sut.loadInitial()

        // Items 0-99 should be in window
        XCTAssertTrue(sut.isInWindow(0))
        XCTAssertTrue(sut.isInWindow(50))
        XCTAssertTrue(sut.isInWindow(99))
        XCTAssertFalse(sut.isInWindow(100))
        XCTAssertFalse(sut.isInWindow(150))
    }

    func testItemAtGlobalIndex() async throws {
        let items = createTestItems(count: 50)
        try await insertItems(items)

        await sut.loadInitial()

        // Valid indices
        XCTAssertNotNil(sut.item(at: 0))
        XCTAssertNotNil(sut.item(at: 25))
        XCTAssertNotNil(sut.item(at: 49))

        // Invalid indices
        XCTAssertNil(sut.item(at: -1))
        XCTAssertNil(sut.item(at: 50))
        XCTAssertNil(sut.item(at: 100))
    }

    func testLocalIndex() async throws {
        let items = createTestItems(count: 50)
        try await insertItems(items)

        await sut.loadInitial()

        // With offset 0, local = global
        XCTAssertEqual(sut.localIndex(for: 0), 0)
        XCTAssertEqual(sut.localIndex(for: 25), 25)
        XCTAssertEqual(sut.localIndex(for: 49), 49)
        XCTAssertNil(sut.localIndex(for: 50))
    }

    // MARK: - Layout Configuration Tests

    func testUpdateLayoutConfiguration() async throws {
        let items = createTestItems(count: 50)
        try await insertItems(items)

        await sut.loadInitial()

        // Update layout
        await sut.updateLayoutConfiguration(columnCount: 6, columnWidth: 150)

        XCTAssertEqual(sut.masonry.columnCount, 6)
        XCTAssertEqual(sut.masonry.columnWidth, 150)
    }

    // MARK: - Refresh Tests

    func testRefresh() async throws {
        let items = createTestItems(count: 50)
        try await insertItems(items)

        await sut.loadInitial()
        XCTAssertEqual(sut.totalCount, 50)

        // Add more items directly to DB
        let moreItems = createTestItems(count: 25)
        try await insertItems(moreItems)

        // Refresh should pick up new items
        await sut.refresh()
        XCTAssertEqual(sut.totalCount, 75)
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentScrollCalls() async throws {
        let items = createTestItems(count: 500)
        try await insertItems(items)

        await sut.loadInitial()

        // Concurrent scroll handling
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask { @MainActor in
                    self.sut.onScroll(offset: CGFloat(i * 100), viewportHeight: 600)
                }
            }
        }

        // Wait for debounced fetches
        try await Task.sleep(nanoseconds: 100_000_000)

        // Should not crash and should have valid state
        XCTAssertFalse(sut.windowedItems.isEmpty)
    }

    // MARK: - Helpers

    private func createTestItems(count: Int, platform: String = "twitter") -> [MediaItem] {
        (0..<count).map { i in
            let id = UUID()
            let basePath = URL(fileURLWithPath: "/test/archive/2025-01")
            let metadataFile = basePath.appendingPathComponent("\(id.uuidString).md")

            return MediaItem(
                id: id,
                basePath: basePath,
                metadataFile: metadataFile,
                mediaFiles: [basePath.appendingPathComponent("\(id.uuidString).jpg")],
                metadata: MediaMetadata(
                    source: URL(string: "https://\(platform).com/test/\(id.uuidString)")!,
                    platform: platform,
                    author: "@testuser",
                    originalDate: Date(),
                    archivedDate: Date()
                ),
                aspectRatio: CGFloat.random(in: 0.5...2.0)
            )
        }
    }

    private func insertItems(_ items: [MediaItem]) async throws {
        try await testDatabaseManager.write { db in
            for item in items {
                let record = MediaItemRecord(from: item)
                try record.insert(db)
            }
        }
    }
}
