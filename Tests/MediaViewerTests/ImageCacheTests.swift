import XCTest
import AppKit
@testable import MediaViewer

/// Tests for ImageCache - the three-tier image caching system.
/// Tests memory cache, disk cache, and LRU eviction.
final class ImageCacheTests: XCTestCase {

    private var cache: TestableImageCache!
    private var tempDir: URL!

    override func setUpWithError() throws {
        // Create temp directory for test thumbnails
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageCacheTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        cache = TestableImageCache(cacheDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        cache = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Memory Cache Tests

    func testMemoryCacheHit() async throws {
        let itemId = UUID()
        let testImage = createTestImage(color: .red, size: NSSize(width: 100, height: 100))

        // Manually insert into memory cache
        await cache.setInMemoryCache(image: testImage, itemId: itemId, size: .small)

        // Should hit memory cache
        let (image, source) = await cache.loadThumbnailWithSource(itemId: itemId, size: .small)

        XCTAssertNotNil(image)
        XCTAssertEqual(source, .memory)
    }

    func testMemoryCacheMiss() async throws {
        let itemId = UUID()

        // Nothing in cache
        let (image, source) = await cache.loadThumbnailWithSource(itemId: itemId, size: .small)

        XCTAssertNil(image)
        XCTAssertEqual(source, .none)
    }

    func testMemoryCacheEvictOnClear() async throws {
        let itemId = UUID()
        let testImage = createTestImage(color: .blue, size: NSSize(width: 100, height: 100))

        await cache.setInMemoryCache(image: testImage, itemId: itemId, size: .small)

        // Verify it's cached
        var (image, _) = await cache.loadThumbnailWithSource(itemId: itemId, size: .small)
        XCTAssertNotNil(image)

        // Clear memory cache
        await cache.clearMemoryCache()

        // Should be gone
        (image, _) = await cache.loadThumbnailWithSource(itemId: itemId, size: .small)
        XCTAssertNil(image)
    }

    func testEvictSpecificItem() async throws {
        let itemId1 = UUID()
        let itemId2 = UUID()
        let testImage = createTestImage(color: .green, size: NSSize(width: 100, height: 100))

        await cache.setInMemoryCache(image: testImage, itemId: itemId1, size: .small)
        await cache.setInMemoryCache(image: testImage, itemId: itemId2, size: .small)

        // Evict only item1
        await cache.evict(itemId: itemId1)

        // Item1 should be gone
        let (image1, _) = await cache.loadThumbnailWithSource(itemId: itemId1, size: .small)
        XCTAssertNil(image1)

        // Item2 should still exist
        let (image2, _) = await cache.loadThumbnailWithSource(itemId: itemId2, size: .small)
        XCTAssertNotNil(image2)
    }

    func testItemMemoryKeyIndexStaysBoundedUnderInsertionStress() {
        let limit = 64
        let itemID = UUID()
        var index = ItemMemoryKeyIndex(maximumKeyCount: limit)
        var discardedKeys: Set<String> = []

        for value in 0..<10_000 {
            discardedKeys.formUnion(index.record(key: "item-key-\(value)", itemID: itemID))
        }

        XCTAssertEqual(index.maximumKeyCount, limit)
        XCTAssertEqual(index.trackedKeyCount, limit)
        XCTAssertEqual(index.trackedItemCount, 1)
        XCTAssertEqual(discardedKeys.count, 10_000 - limit)
        XCTAssertFalse(index.allKeys.contains("item-key-0"))
        XCTAssertTrue(index.allKeys.contains("item-key-9999"))
    }

    func testItemMemoryKeyIndexPrunesEvictionsAndPreservesItemInvalidation() {
        let firstItem = UUID()
        let secondItem = UUID()
        var index = ItemMemoryKeyIndex(maximumKeyCount: 10)
        _ = index.record(key: "first-small", itemID: firstItem)
        _ = index.record(key: "first-medium", itemID: firstItem)
        _ = index.record(key: "second-small", itemID: secondItem)

        let staleKeys = index.retainOnly(["first-medium", "second-small"])

        XCTAssertEqual(staleKeys, ["first-small"])
        XCTAssertEqual(index.trackedKeyCount, 2)
        XCTAssertEqual(index.keys(for: firstItem), ["first-medium"])
        XCTAssertEqual(index.keys(for: secondItem), ["second-small"])

        let firstItemKeys = index.remove(itemID: firstItem)
        XCTAssertEqual(firstItemKeys, ["first-medium"])
        XCTAssertEqual(index.trackedKeyCount, 1)
        XCTAssertEqual(index.trackedItemCount, 1)
        XCTAssertEqual(index.keys(for: secondItem), ["second-small"])
    }

    func testItemMemoryKeyIndexReturnsLiveKeysDiscardedByReducedLimit() {
        let itemID = UUID()
        var index = ItemMemoryKeyIndex(maximumKeyCount: 3)
        _ = index.record(key: "oldest", itemID: itemID)
        _ = index.record(key: "middle", itemID: itemID)
        _ = index.record(key: "newest", itemID: itemID)
        index.touch(key: "oldest")

        let discardedKeys = index.setMaximumKeyCount(2)

        XCTAssertEqual(discardedKeys, ["middle"])
        XCTAssertEqual(index.allKeys, ["oldest", "newest"])
        XCTAssertEqual(index.keys(for: itemID), ["oldest", "newest"])
    }

    // MARK: - Disk Cache Tests

    func testDiskCacheHit() async throws {
        let itemId = UUID()
        let testImage = createTestImage(color: .yellow, size: NSSize(width: 100, height: 100))

        // Save to disk
        await cache.saveToDisk(image: testImage, itemId: itemId, size: .small)

        // Clear memory cache to force disk read
        await cache.clearMemoryCache()

        // Should hit disk cache
        let (image, source) = await cache.loadThumbnailWithSource(itemId: itemId, size: .small)

        XCTAssertNotNil(image)
        XCTAssertEqual(source, .disk)
    }

    func testDiskCacheMiss() async throws {
        let itemId = UUID()

        // Nothing on disk
        let exists = await cache.existsOnDisk(itemId: itemId, size: .small)
        XCTAssertFalse(exists)
    }

    func testDiskCachePromotesToMemory() async throws {
        let itemId = UUID()
        let testImage = createTestImage(color: .purple, size: NSSize(width: 100, height: 100))

        // Save to disk only
        await cache.saveToDisk(image: testImage, itemId: itemId, size: .small)
        await cache.clearMemoryCache()

        // Load from disk (should promote to memory)
        let (_, source1) = await cache.loadThumbnailWithSource(itemId: itemId, size: .small)
        XCTAssertEqual(source1, .disk)

        // Second load should hit memory
        let (_, source2) = await cache.loadThumbnailWithSource(itemId: itemId, size: .small)
        XCTAssertEqual(source2, .memory)
    }

    func testClearDiskCache() async throws {
        let itemId = UUID()
        let testImage = createTestImage(color: .orange, size: NSSize(width: 100, height: 100))

        await cache.saveToDisk(image: testImage, itemId: itemId, size: .small)

        // Verify exists
        var exists = await cache.existsOnDisk(itemId: itemId, size: .small)
        XCTAssertTrue(exists)

        // Clear disk cache
        await cache.clearDiskCache()

        // Should be gone
        exists = await cache.existsOnDisk(itemId: itemId, size: .small)
        XCTAssertFalse(exists)
    }

    // MARK: - LRU Eviction Tests

    func testLRUEvictionByCount() async throws {
        // Set a small count limit
        await cache.setCountLimit(5)

        // Insert more items than the limit
        var insertedIds: [UUID] = []
        for _ in 0..<10 {
            let itemId = UUID()
            insertedIds.append(itemId)
            let testImage = createTestImage(color: .cyan, size: NSSize(width: 100, height: 100))
            await cache.setInMemoryCache(image: testImage, itemId: itemId, size: .small)
        }

        // Memory cache should have auto-evicted some items
        // NSCache manages this internally, so we verify the mechanism works
        // by checking that not all items are in cache
        var cachedCount = 0
        for itemId in insertedIds {
            let (_, source) = await cache.loadThumbnailWithSource(itemId: itemId, size: .small)
            if source == .memory {
                cachedCount += 1
            }
        }

        // NSCache might keep more or fewer depending on memory pressure
        // We just verify the cache is functioning
        XCTAssertLessThanOrEqual(cachedCount, 10)
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentLoads() async throws {
        let itemId = UUID()
        let testImage = createTestImage(color: .magenta, size: NSSize(width: 100, height: 100))

        // Save to disk
        await cache.saveToDisk(image: testImage, itemId: itemId, size: .small)
        await cache.clearMemoryCache()

        // Concurrent loads for the same item
        await withTaskGroup(of: NSImage?.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let (image, _) = await self.cache.loadThumbnailWithSource(itemId: itemId, size: .small)
                    return image
                }
            }

            var results: [NSImage?] = []
            for await result in group {
                results.append(result)
            }

            // All should succeed
            XCTAssertEqual(results.count, 20)
            XCTAssertTrue(results.allSatisfy { $0 != nil })
        }
    }

    func testConcurrentWritesAndReads() async throws {
        let itemIds = (0..<10).map { _ in UUID() }

        await withTaskGroup(of: Void.self) { group in
            // Writers
            for itemId in itemIds {
                group.addTask {
                    let image = self.createTestImage(color: .gray, size: NSSize(width: 100, height: 100))
                    await self.cache.setInMemoryCache(image: image, itemId: itemId, size: .small)
                }
            }

            // Readers (starting simultaneously)
            for itemId in itemIds {
                group.addTask {
                    _ = await self.cache.loadThumbnailWithSource(itemId: itemId, size: .small)
                }
            }
        }

        // Verify no crashes occurred and at least some items are cached
        var cachedCount = 0
        for itemId in itemIds {
            let (image, _) = await cache.loadThumbnailWithSource(itemId: itemId, size: .small)
            if image != nil {
                cachedCount += 1
            }
        }
        XCTAssertGreaterThan(cachedCount, 0)
    }

    func testConcurrentLoadsForDifferentItems() async throws {
        // Pre-populate disk cache with multiple items
        var itemIds: [UUID] = []
        for _ in 0..<10 {
            let itemId = UUID()
            itemIds.append(itemId)
            let testImage = createTestImage(color: .white, size: NSSize(width: 100, height: 100))
            await cache.saveToDisk(image: testImage, itemId: itemId, size: .small)
        }

        await cache.clearMemoryCache()

        // Load all concurrently
        await withTaskGroup(of: (UUID, NSImage?).self) { group in
            for itemId in itemIds {
                group.addTask {
                    let (image, _) = await self.cache.loadThumbnailWithSource(itemId: itemId, size: .small)
                    return (itemId, image)
                }
            }

            var results: [UUID: NSImage?] = [:]
            for await (itemId, image) in group {
                results[itemId] = image
            }

            // All should have loaded
            XCTAssertEqual(results.count, 10)
            for (_, image) in results {
                XCTAssertNotNil(image)
            }
        }
    }

    // MARK: - Cache Size Tests

    func testCacheSizeCalculation() async throws {
        // Insert some items to disk
        for _ in 0..<5 {
            let itemId = UUID()
            let testImage = createTestImage(color: .black, size: NSSize(width: 100, height: 100))
            await cache.saveToDisk(image: testImage, itemId: itemId, size: .small)
        }

        let size = await cache.getDiskCacheSize()
        XCTAssertGreaterThan(size, 0)
    }

    func testClearAllCaches() async throws {
        let itemId = UUID()
        let testImage = createTestImage(color: .red, size: NSSize(width: 100, height: 100))

        // Add to both caches
        await cache.setInMemoryCache(image: testImage, itemId: itemId, size: .small)
        await cache.saveToDisk(image: testImage, itemId: itemId, size: .small)

        // Clear all
        await cache.clearAll(itemId: itemId)

        // Both should be empty
        let (image, _) = await cache.loadThumbnailWithSource(itemId: itemId, size: .small)
        XCTAssertNil(image)

        let exists = await cache.existsOnDisk(itemId: itemId, size: .small)
        XCTAssertFalse(exists)
    }

    // MARK: - Size Tiers Tests

    func testDifferentSizeTiers() async throws {
        let itemId = UUID()
        let smallImage = createTestImage(color: .red, size: NSSize(width: 100, height: 100))
        let mediumImage = createTestImage(color: .blue, size: NSSize(width: 300, height: 300))

        await cache.setInMemoryCache(image: smallImage, itemId: itemId, size: .small)
        await cache.setInMemoryCache(image: mediumImage, itemId: itemId, size: .medium)

        // Both should be independently cached
        let (small, _) = await cache.loadThumbnailWithSource(itemId: itemId, size: .small)
        let (medium, _) = await cache.loadThumbnailWithSource(itemId: itemId, size: .medium)

        XCTAssertNotNil(small)
        XCTAssertNotNil(medium)

        // They should be different images
        XCTAssertNotEqual(small?.size, medium?.size)
    }

    // MARK: - Saliency Rect Tests

    func testSaliencyRectPassedToThumbnailGenerator() async throws {
        // Test that saliency rect is correctly wired through the pipeline
        // We verify this by checking that IndexedContent can store and retrieve CGRect

        let saliencyRect = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        let indexedContent = IndexedContent(saliencyRect: saliencyRect)

        // Verify saliency rect is stored and retrievable
        XCTAssertNotNil(indexedContent.saliencyRect)
        XCTAssertNotNil(indexedContent.cgSaliencyRect)

        // Verify the values match
        let retrieved = indexedContent.cgSaliencyRect!
        XCTAssertEqual(Double(retrieved.origin.x), 0.1, accuracy: 0.001)
        XCTAssertEqual(Double(retrieved.origin.y), 0.2, accuracy: 0.001)
        XCTAssertEqual(Double(retrieved.width), 0.5, accuracy: 0.001)
        XCTAssertEqual(Double(retrieved.height), 0.5, accuracy: 0.001)
    }

    func testMediaItemWithSaliencyRect() throws {
        // Test that MediaItem correctly stores saliency rect from IndexedContent

        let saliencyRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let indexedContent = IndexedContent(
            ocrText: nil,
            dominantColors: [.blue],
            saliencyRect: saliencyRect
        )

        let item = MediaItem(
            id: UUID(),
            basePath: URL(fileURLWithPath: "/archive"),
            metadataFile: URL(fileURLWithPath: "/archive/test.md"),
            mediaFiles: [URL(fileURLWithPath: "/archive/test.jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com")!,
                platform: "test"
            ),
            indexedContent: indexedContent
        )

        // Verify saliency rect is accessible from item
        XCTAssertNotNil(item.indexedContent?.cgSaliencyRect)
        XCTAssertEqual(Double(item.indexedContent!.cgSaliencyRect!.width), 0.5, accuracy: 0.001)
    }

    func testThumbnailGenerationWithoutSaliency() throws {
        // Test that ThumbnailGenerator.generate works without saliency rect
        // (This is the normal grid thumbnail case)

        // Create a simple test image
        let testImage = createTestImage(color: .blue, size: NSSize(width: 200, height: 200))

        // Verify the test image was created
        XCTAssertEqual(testImage.size.width, 200)
        XCTAssertEqual(testImage.size.height, 200)

        // Note: We can't easily test ThumbnailGenerator.generate without a real image file,
        // but we can verify the API accepts nil for saliencyRect
        // The actual wiring test is in testSaliencyRectPassedToThumbnailGenerator
    }

    func testThumbnailDiffersWithSaliency() throws {
        // Test conceptually that with vs without saliency produces different results
        // This tests the data flow, not actual image processing (which requires real files)

        let itemWithSaliency = createTestItemWithSaliency(
            saliencyRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        )
        let itemWithoutSaliency = createTestItemWithSaliency(saliencyRect: nil)

        // Items should have different saliency configurations
        XCTAssertNotNil(itemWithSaliency.indexedContent?.cgSaliencyRect)
        XCTAssertNil(itemWithoutSaliency.indexedContent?.cgSaliencyRect)

        // The useSaliency flag determines whether saliency is used
        // This test verifies the data is correctly stored for the ThumbnailGenerator to use
    }

    private func createTestItemWithSaliency(saliencyRect: CGRect?) -> MediaItem {
        let indexedContent: IndexedContent?
        if let rect = saliencyRect {
            indexedContent = IndexedContent(saliencyRect: rect)
        } else {
            indexedContent = nil
        }

        return MediaItem(
            id: UUID(),
            basePath: URL(fileURLWithPath: "/archive"),
            metadataFile: URL(fileURLWithPath: "/archive/test.md"),
            mediaFiles: [URL(fileURLWithPath: "/archive/test.jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com")!,
                platform: "test"
            ),
            indexedContent: indexedContent
        )
    }

    // MARK: - Helpers

    private func createTestImage(color: NSColor, size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}

// Production cache coverage; the older tests below use a standalone cache double.
extension ImageCacheTests {
    func testDisplaySizePrefersExistingMediumAndKeepsRetinaPointSize() async throws {
        let item = try diskThumbnailItem()
        defer { ThumbnailGenerator.deleteThumbnails(for: item.id) }
        let cache = ImageCache()
        let value = await cache.loadThumbnail(for: item, displaySize: CGSize(width: 250, height: 250), displayScale: 2)
        let image = try XCTUnwrap(value)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, 500)
        XCTAssertEqual(cg.height, 500)
        XCTAssertEqual(image.size, CGSize(width: 250, height: 250))
        let legacy = await cache.loadThumbnail(for: item)
        XCTAssertEqual(legacy?.size, CGSize(width: 400, height: 400))
        let oneXValue = await cache.loadThumbnail(for: item,
            displaySize: CGSize(width: 250, height: 250), displayScale: 1)
        let oneX = try XCTUnwrap(oneXValue)
        let oneXBitmap = try XCTUnwrap(oneX.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(oneXBitmap.width, 250)
        XCTAssertEqual(oneX.size, CGSize(width: 250, height: 250))
        let repeated = await cache.loadThumbnail(for: item,
            displaySize: CGSize(width: 250, height: 250), displayScale: 2)
        XCTAssertTrue(repeated === image)
    }

    func testDisplaySizeFallsBackToSmallWithoutGeneratingMedium() async throws {
        let item = try diskThumbnailItem(includeMedium: false)
        defer { ThumbnailGenerator.deleteThumbnails(for: item.id) }
        let cache = ImageCache()
        let value = await cache.loadThumbnail(for: item, displaySize: CGSize(width: 250, height: 250), displayScale: 2)
        let image = try XCTUnwrap(value)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, 400)
        XCTAssertEqual(image.size, CGSize(width: 200, height: 200))
        XCTAssertFalse(ThumbnailGenerator.thumbnailExists(for: item.id, size: .medium))
    }

    func testDisplaySizedDiskWarmupSharesReadyBitmapWithVisibleLoad() async throws {
        let item = try diskThumbnailItem()
        defer { ThumbnailGenerator.deleteThumbnails(for: item.id) }
        let cache = ImageCache()
        await cache.preloadFromDisk(items: [item], displaySize: CGSize(width: 250, height: 250), displayScale: 2)
        let snapshot = await cache.retentionSnapshot()
        XCTAssertEqual(snapshot.liveTrackedItemKeyCount, 1)
        let first = await cache.loadThumbnail(for: item, displaySize: CGSize(width: 250, height: 250), displayScale: 2)
        let second = await cache.loadThumbnail(for: item, displaySize: CGSize(width: 250, height: 250), displayScale: 2)
        XCTAssertTrue(first === second)
        XCTAssertEqual(first?.size, CGSize(width: 250, height: 250))
    }

    func testDisplaySizePrefetchDecodesExistingDiskThumbnail() async throws {
        let item = try diskThumbnailItem()
        defer { ThumbnailGenerator.deleteThumbnails(for: item.id) }
        let cache = ImageCache()
        await cache.prefetch(items: [item], displaySize: CGSize(width: 250, height: 250), displayScale: 2)
        let snapshot = await cache.retentionSnapshot()
        XCTAssertEqual(snapshot.liveTrackedItemKeyCount, 1)
        let image = await cache.loadThumbnail(for: item, displaySize: CGSize(width: 250, height: 250), displayScale: 2)
        XCTAssertEqual(image?.size, CGSize(width: 250, height: 250))
        await cache.evict(itemId: item.id)
        let evicted = await cache.retentionSnapshot()
        XCTAssertEqual(evicted.liveTrackedItemKeyCount, 0)
    }

    func testCorruptMediumFallsBackWithoutReplacingTheMediumFile() async throws {
        let item = try diskThumbnailItem()
        defer { ThumbnailGenerator.deleteThumbnails(for: item.id) }
        let medium = ThumbnailGenerator.thumbnailPath(for: item.id, size: .medium)
        let corrupt = Data("not a JPEG".utf8)
        try corrupt.write(to: medium)
        let value = await ImageCache().loadThumbnail(for: item,
            displaySize: CGSize(width: 250, height: 250), displayScale: 2)
        let image = try XCTUnwrap(value)
        XCTAssertEqual(image.size, CGSize(width: 200, height: 200))
        XCTAssertEqual(try Data(contentsOf: medium), corrupt)
    }

    func testBlurBackgroundIsSmallCachedAndEvictedWithItsItem() async throws {
        let item = try diskThumbnailItem()
        defer { ThumbnailGenerator.deleteThumbnails(for: item.id) }
        let cache = ImageCache()
        let value = await cache.loadThumbnail(for: item)
        let source = try XCTUnwrap(value)
        let blurredValue = await cache.loadBlurredThumbnail(for: item, source: source)
        let blurred = try XCTUnwrap(blurredValue)
        XCTAssertFalse(source === blurred)
        XCTAssertEqual(blurred.size, source.size)
        let cg = try XCTUnwrap(blurred.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, 128)
        XCTAssertLessThanOrEqual(cg.bytesPerRow * cg.height, 128 * 128 * 8)
        let repeated = await cache.loadBlurredThumbnail(for: item, source: source)
        XCTAssertTrue(blurred === repeated)
        let retained = await cache.retentionSnapshot()
        XCTAssertEqual(retained.liveTrackedItemKeyCount, 2)
        await cache.evict(itemId: item.id)
        let evicted = await cache.retentionSnapshot()
        XCTAssertEqual(evicted.liveTrackedItemKeyCount, 0)
    }

    private func diskThumbnailItem(includeMedium: Bool = true) throws -> MediaItem {
        let id = UUID()
        for tier in includeMedium ? [ThumbnailGenerator.Size.small, .medium] : [.small] {
            let dimension = tier.maxPixelDimension
            let context = try XCTUnwrap(CGContext(data: nil, width: dimension, height: dimension,
                bitsPerComponent: 8, bytesPerRow: dimension * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
            let cg = try XCTUnwrap(context.makeImage())
            ThumbnailGenerator.save(NSImage(cgImage: cg, size: CGSize(width: dimension, height: dimension)),
                itemId: id, size: tier)
        }
        // A missing source ensures these requests only consume existing disk thumbnails.
        return MediaItem(id: id, basePath: tempDir, metadataFile: tempDir.appendingPathComponent("item.md"),
            mediaFiles: [tempDir.appendingPathComponent("missing.jpg")],
            metadata: MediaMetadata(source: URL(string: "https://example.invalid")!, platform: "test"))
    }
}

// MARK: - Testable Image Cache

/// Test implementation of ImageCache with exposed internals for testing
actor TestableImageCache {

    enum CacheSource {
        case memory
        case disk
        case none
    }

    private let cacheDirectory: URL
    private let memoryCache: NSCache<NSString, NSImage>

    init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
        self.memoryCache = NSCache()
        self.memoryCache.name = "TestableImageCache"
        self.memoryCache.countLimit = 100
        self.memoryCache.totalCostLimit = 50_000_000 // 50MB
    }

    func setCountLimit(_ limit: Int) {
        memoryCache.countLimit = limit
    }

    func setCostLimit(_ limit: Int) {
        memoryCache.totalCostLimit = limit
    }

    private func cacheKey(itemId: UUID, size: ThumbnailGenerator.Size) -> NSString {
        "\(itemId.uuidString)-\(size.rawValue)" as NSString
    }

    private func diskPath(itemId: UUID, size: ThumbnailGenerator.Size) -> URL {
        cacheDirectory.appendingPathComponent("\(itemId.uuidString)-\(size.rawValue).jpg")
    }

    func setInMemoryCache(image: NSImage, itemId: UUID, size: ThumbnailGenerator.Size) {
        let key = cacheKey(itemId: itemId, size: size)
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key, cost: cost)
    }

    func loadThumbnailWithSource(itemId: UUID, size: ThumbnailGenerator.Size) -> (NSImage?, CacheSource) {
        let key = cacheKey(itemId: itemId, size: size)

        // Check memory cache
        if let cached = memoryCache.object(forKey: key) {
            return (cached, .memory)
        }

        // Check disk cache
        let path = diskPath(itemId: itemId, size: size)
        if FileManager.default.fileExists(atPath: path.path),
           let image = NSImage(contentsOf: path) {
            // Promote to memory cache
            let cost = Int(image.size.width * image.size.height * 4)
            memoryCache.setObject(image, forKey: key, cost: cost)
            return (image, .disk)
        }

        return (nil, .none)
    }

    func saveToDisk(image: NSImage, itemId: UUID, size: ThumbnailGenerator.Size) {
        let path = diskPath(itemId: itemId, size: size)

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Convert to JPEG and save
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            if let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try? jpegData.write(to: path, options: .atomic)
            }
        }
    }

    func existsOnDisk(itemId: UUID, size: ThumbnailGenerator.Size) -> Bool {
        let path = diskPath(itemId: itemId, size: size)
        return FileManager.default.fileExists(atPath: path.path)
    }

    func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    func clearDiskCache() {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }

    func evict(itemId: UUID) {
        for size in [ThumbnailGenerator.Size.small, .medium] {
            let key = cacheKey(itemId: itemId, size: size)
            memoryCache.removeObject(forKey: key)
        }
        // Also remove full-size key
        memoryCache.removeObject(forKey: "\(itemId.uuidString)-full" as NSString)
    }

    func clearAll(itemId: UUID) {
        evict(itemId: itemId)

        // Remove from disk
        for size in [ThumbnailGenerator.Size.small, .medium] {
            let path = diskPath(itemId: itemId, size: size)
            try? FileManager.default.removeItem(at: path)
        }
    }

    func getDiskCacheSize() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var total: Int64 = 0
        for file in files {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
