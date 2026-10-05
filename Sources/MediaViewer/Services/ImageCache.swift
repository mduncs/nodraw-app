import Foundation
import AppKit
import CoreImage
import os.signpost

/// Coalesces equivalent image work without letting one cancelled SwiftUI waiter
/// cancel a producer that is still serving another view.
actor SharedImageLoadBroker {
    private struct Entry {
        let id: UUID
        let task: Task<NSImage?, Never>
        var waiters: Set<UUID>
    }

    private var entries: [String: Entry] = [:]

    func value(
        for key: String,
        priority: TaskPriority = .userInitiated,
        producer: @escaping @Sendable () async -> NSImage?
    ) async -> NSImage? {
        guard !Task.isCancelled else { return nil }

        let waiterID = UUID()
        let loadID: UUID
        let task: Task<NSImage?, Never>
        if var entry = entries[key] {
            entry.waiters.insert(waiterID)
            entries[key] = entry
            loadID = entry.id
            task = entry.task
        } else {
            loadID = UUID()
            task = Task.detached(priority: priority, operation: producer)
            entries[key] = Entry(id: loadID, task: task, waiters: [waiterID])
        }

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task.detached { [weak self] in
                await self?.releaseWaiter(
                    waiterID,
                    for: key,
                    loadID: loadID,
                    cancelIfUnused: true
                )
            }
        }

        let wasCancelled = Task.isCancelled
        releaseWaiter(
            waiterID,
            for: key,
            loadID: loadID,
            cancelIfUnused: wasCancelled
        )
        return wasCancelled ? nil : result
    }

    /// Internal visibility is intentional so cancellation behavior can be tested
    /// without invoking AppKit decoders or ffmpeg.
    func waiterCount(for key: String) -> Int {
        entries[key]?.waiters.count ?? 0
    }

    private func releaseWaiter(
        _ waiterID: UUID,
        for key: String,
        loadID: UUID,
        cancelIfUnused: Bool
    ) {
        guard var entry = entries[key],
              entry.id == loadID,
              entry.waiters.remove(waiterID) != nil else { return }

        if entry.waiters.isEmpty {
            if cancelIfUnused {
                entry.task.cancel()
            }
            entries[key] = nil
        } else {
            entries[key] = entry
        }
    }
}

/// Bounded, expiring negative cache. Keys include item, size, and effective
/// source, so a changed display source is never suppressed by an earlier
/// failure. Monotonic timestamps keep expiry deterministic across wall-clock
/// changes and injectable in tests.
struct ImageLoadFailureSuppression {
    static let defaultMaximumEntryCount = 2_048
    static let defaultTimeToLive: TimeInterval = 5 * 60

    private struct Failure {
        let expiresAt: TimeInterval
        let sequence: UInt64
    }

    private var failures: [String: Failure] = [:]
    private var nextSequence: UInt64 = 0
    let maximumEntryCount: Int
    let timeToLive: TimeInterval

    init(
        maximumEntryCount: Int = Self.defaultMaximumEntryCount,
        timeToLive: TimeInterval = Self.defaultTimeToLive
    ) {
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.timeToLive = max(0, timeToLive)
    }

    var entryCount: Int {
        failures.count
    }

    mutating func shouldAttempt(
        _ key: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard let failure = failures[key] else { return true }
        guard failure.expiresAt > now else {
            failures[key] = nil
            return true
        }
        return false
    }

    mutating func recordFailure(
        _ key: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        removeExpiredEntries(now: now)
        guard failures[key] == nil else { return false }
        guard maximumEntryCount > 0, timeToLive > 0 else { return true }

        nextSequence &+= 1
        failures[key] = Failure(
            expiresAt: now + timeToLive,
            sequence: nextSequence
        )
        trimToLimit()
        return true
    }

    mutating func recordSuccess(_ key: String) {
        failures[key] = nil
    }

    mutating func invalidate(itemID: UUID) {
        let prefix = itemID.uuidString + "|"
        failures = failures.filter { !$0.key.hasPrefix(prefix) }
    }

    mutating func invalidate(sourceURL: URL) {
        let suffix = "|" + sourceURL.standardizedFileURL.path
        failures = failures.filter { !$0.key.hasSuffix(suffix) }
    }

    mutating func removeAll() {
        failures.removeAll(keepingCapacity: true)
    }

    private mutating func removeExpiredEntries(now: TimeInterval) {
        failures = failures.filter { $0.value.expiresAt > now }
    }

    private mutating func trimToLimit() {
        while failures.count > maximumEntryCount,
              let oldest = failures.min(by: { lhs, rhs in
                  if lhs.value.sequence == rhs.value.sequence {
                      return lhs.key < rhs.key
                  }
                  return lhs.value.sequence < rhs.value.sequence
              })?.key {
            failures[oldest] = nil
        }
    }
}

/// Tracks the item-owned keys stored in `NSCache`. `NSCache` can evict objects
/// without exposing their keys, so this reverse index is both periodically
/// reconciled against the cache and hard-capped. Any live key discarded by the
/// cap is also removed from `NSCache`, preserving exact per-item invalidation.
struct ItemMemoryKeyIndex {
    private struct Entry {
        let itemID: UUID
        var sequence: UInt64
    }

    private var entriesByKey: [String: Entry] = [:]
    private var keysByItem: [UUID: Set<String>] = [:]
    private var nextSequence: UInt64 = 0
    private(set) var maximumKeyCount: Int

    init(maximumKeyCount: Int) {
        self.maximumKeyCount = max(0, maximumKeyCount)
    }

    var trackedKeyCount: Int {
        entriesByKey.count
    }

    var trackedItemCount: Int {
        keysByItem.count
    }

    var allKeys: Set<String> {
        Set(entriesByKey.keys)
    }

    func keys(for itemID: UUID) -> Set<String> {
        keysByItem[itemID] ?? []
    }

    mutating func record(key: String, itemID: UUID) -> Set<String> {
        remove(key: key)
        nextSequence &+= 1
        entriesByKey[key] = Entry(itemID: itemID, sequence: nextSequence)
        keysByItem[itemID, default: []].insert(key)
        return discardOverflow()
    }

    mutating func touch(key: String) {
        guard var entry = entriesByKey[key] else { return }
        nextSequence &+= 1
        entry.sequence = nextSequence
        entriesByKey[key] = entry
    }

    mutating func setMaximumKeyCount(_ count: Int) -> Set<String> {
        maximumKeyCount = max(0, count)
        return discardOverflow()
    }

    @discardableResult
    mutating func retainOnly(_ liveKeys: Set<String>) -> Set<String> {
        let staleKeys = allKeys.subtracting(liveKeys)
        remove(keys: staleKeys)
        return staleKeys
    }

    mutating func remove(itemID: UUID) -> Set<String> {
        guard let keys = keysByItem.removeValue(forKey: itemID) else { return [] }
        for key in keys {
            entriesByKey[key] = nil
        }
        return keys
    }

    mutating func remove(keys: Set<String>) {
        for key in keys {
            remove(key: key)
        }
    }

    mutating func removeAll() {
        entriesByKey.removeAll(keepingCapacity: true)
        keysByItem.removeAll(keepingCapacity: true)
    }

    private mutating func remove(key: String) {
        guard let entry = entriesByKey.removeValue(forKey: key) else { return }
        keysByItem[entry.itemID]?.remove(key)
        if keysByItem[entry.itemID]?.isEmpty == true {
            keysByItem[entry.itemID] = nil
        }
    }

    private mutating func discardOverflow() -> Set<String> {
        var discarded: Set<String> = []
        while entriesByKey.count > maximumKeyCount,
              let oldestKey = entriesByKey.min(by: { lhs, rhs in
                  if lhs.value.sequence == rhs.value.sequence {
                      return lhs.key < rhs.key
                  }
                  return lhs.value.sequence < rhs.value.sequence
              })?.key {
            remove(key: oldestKey)
            discarded.insert(oldestKey)
        }
        return discarded
    }
}

// MARK: - ImageCache

/// Actor-based image cache with three tiers per ADR-003:
/// 1. Pre-generated thumbnails on disk
/// 2. NSCache for memory caching with auto-eviction
/// 3. On-demand generation from source files
///
/// Thread-safe via actor isolation. Handles memory pressure automatically.
actor ImageCache {

    private enum MemoryPressureTier: Sendable {
        case normal
        case warning
        case critical
    }

    /// Shared instance for app-wide caching
    static let shared = ImageCache()

    /// Alias for thumbnail size tiers
    typealias ThumbnailSize = ThumbnailGenerator.Size

    /// A cheap structural snapshot for diagnostics and regression tests. The
    /// tracked counts cover item-owned thumbnails; URL-only and full-image cache
    /// entries intentionally have no per-item invalidation metadata.
    struct RetentionStats: Sendable, Equatable {
        let trackedItemCount: Int
        let trackedItemKeyCount: Int
        let liveTrackedItemKeyCount: Int
        let staleTrackedItemKeyCount: Int
        let trackedItemKeyLimit: Int
        let suppressedThumbnailFailureCount: Int
        let suppressedThumbnailFailureLimit: Int
    }

    // MARK: - Concurrency Control

    /// Limit concurrent thumbnail generation to prevent CPU and memory spikes.
    private let generationSemaphore = AsyncSemaphore(limit: 4)
    private let normalGenerationConcurrency = 4
    private let warningGenerationConcurrency = 2
    private let criticalGenerationConcurrency = 1

    // MARK: - Memory Cache

    /// NSCache for in-memory thumbnails
    /// Cost-limited to ~200MB, auto-evicts under memory pressure
    private let memoryCache: NSCache<NSString, NSImage>
    private let normalMemoryCostLimit = 200_000_000
    private let warningMemoryCostLimit = 120_000_000
    private let criticalMemoryCostLimit = 80_000_000
    private let normalMemoryCountLimit = 500
    private let warningMemoryCountLimit = 300
    private let criticalMemoryCountLimit = 150
    private var memoryTier: MemoryPressureTier = .normal
    private var memorySource: DispatchSourceMemoryPressure?
    /// Prevent repeated regeneration loops for dark video thumbnails.
    private var darkVideoRefreshAttempts = Set<String>()
    /// Coalesce identical requests. The work itself runs outside actor isolation,
    /// so a slow decode or ffmpeg fallback never stalls unrelated cache hits.
    private let thumbnailLoadBroker = SharedImageLoadBroker()
    private let fullImageLoadBroker = SharedImageLoadBroker()
    private var thumbnailFailures = ImageLoadFailureSuppression()
    private var itemMemoryKeys = ItemMemoryKeyIndex(maximumKeyCount: 500)
    private var itemMemoryStoresSincePrune = 0
    private let itemMemoryIndexPruneInterval = 32

    /// Cache wrapper to make NSCache work with actor isolation
    private final class CacheWrapper: @unchecked Sendable {
        let cache: NSCache<NSString, NSImage>

        init() {
            cache = NSCache()
            cache.totalCostLimit = 200_000_000  // ~200MB
            cache.countLimit = 500
            cache.name = "com.nodraw.imagecache"
        }
    }

    private let cacheWrapper: CacheWrapper

    // MARK: - Initialization

    init() {
        self.cacheWrapper = CacheWrapper()
        self.memoryCache = cacheWrapper.cache

        setupLifecycleNotifications()
        Task { await setupMemoryPressureMonitor() }
    }

    private nonisolated func setupLifecycleNotifications() {
        // Flush medium thumbnails when app goes to background
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak cacheWrapper] _ in
            // On resign active, we could selectively evict larger thumbnails
            // For now, NSCache handles this automatically
            _ = cacheWrapper  // Silence unused warning
        }
    }

    private func setupMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data
            Task {
                await self.handleMemoryPressureEvent(event)
            }
        }
        source.resume()
        memorySource = source
    }

    private func handleMemoryPressureEvent(_ event: DispatchSource.MemoryPressureEvent) async {
        if event.contains(.critical) {
            await applyMemoryPressureTier(.critical)
        } else if event.contains(.warning) {
            await applyMemoryPressureTier(.warning)
        } else {
            await applyMemoryPressureTier(.normal)
        }
    }

    private func applyMemoryPressureTier(_ tier: MemoryPressureTier) async {
        guard tier != memoryTier else { return }
        memoryTier = tier

        switch tier {
        case .normal:
            memoryCache.totalCostLimit = normalMemoryCostLimit
            memoryCache.countLimit = normalMemoryCountLimit
            reconcileItemMemoryKeys(maximumKeyCount: normalMemoryCountLimit)
            await generationSemaphore.setLimit(normalGenerationConcurrency)
            logInfo("ImageCache: memory normal, restoring full cache and generation speed")
        case .warning:
            memoryCache.totalCostLimit = warningMemoryCostLimit
            memoryCache.countLimit = warningMemoryCountLimit
            reconcileItemMemoryKeys(maximumKeyCount: warningMemoryCountLimit)
            await generationSemaphore.setLimit(warningGenerationConcurrency)
            logInfo("ImageCache: memory warning, reducing cache limits and generation concurrency")
        case .critical:
            memoryCache.totalCostLimit = criticalMemoryCostLimit
            memoryCache.countLimit = criticalMemoryCountLimit
            memoryCache.removeAllObjects()
            itemMemoryKeys.removeAll()
            _ = itemMemoryKeys.setMaximumKeyCount(criticalMemoryCountLimit)
            itemMemoryStoresSincePrune = 0
            await generationSemaphore.setLimit(criticalGenerationConcurrency)
            logWarning("ImageCache: memory critical, clearing memory cache and throttling generation")
        }
    }

    private var batchGenerationConcurrency: Int {
        switch memoryTier {
        case .normal: normalGenerationConcurrency
        case .warning: warningGenerationConcurrency
        case .critical: criticalGenerationConcurrency
        }
    }

    private var preloadReadConcurrency: Int {
        switch memoryTier {
        case .normal: 8
        case .warning: 3
        case .critical: 1
        }
    }

    private var preloadItemLimit: Int {
        switch memoryTier {
        case .normal: 240
        case .warning: 120
        case .critical: 40
        }
    }

    // MARK: - Cache Key

    nonisolated static func thumbnailLoadIdentity(
        for item: MediaItem,
        size: ThumbnailSize = .small,
        displaySize: CGSize? = nil,
        displayScale: CGFloat = 1
    ) -> String {
        let source = item.thumbnailSource?.standardizedFileURL.path ?? "missing"
        let display = thumbnailPixelSize(displaySize: displaySize, displayScale: displayScale)
            .map { "|pixels-\($0)@\(backingScale(displayScale))" } ?? ""
        return "\(item.id.uuidString)|\(size.rawValue)\(display)|\(source)"
    }

    /// Context thumbnails cannot share the legacy primary-media filename. The
    /// stable path fingerprint also prevents a replaced context source from
    /// resurrecting an earlier context thumbnail after relaunch.
    nonisolated static func diskCacheVariant(for item: MediaItem) -> String? {
        guard let source = item.thumbnailSource,
              source == item.contextImage else { return nil }
        return "context-\(stablePathFingerprint(source.standardizedFileURL.path))"
    }

    nonisolated private static func stablePathFingerprint(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    nonisolated static func thumbnailPixelSize(displaySize: CGSize?, displayScale: CGFloat) -> Int? {
        guard let displaySize,
              displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width > 0, displaySize.height > 0 else { return nil }
        let pixels = ceil(max(displaySize.width, displaySize.height) * backingScale(displayScale))
        return Int(min(pixels, CGFloat(ThumbnailSize.medium.maxPixelDimension)))
    }

    nonisolated private static func backingScale(_ scale: CGFloat) -> CGFloat {
        scale.isFinite && scale > 0 ? scale : 1
    }

    private func preferredSize(for item: MediaItem, size: ThumbnailSize, pixels: Int?) -> ThumbnailSize {
        if size == .small, let pixels, pixels > size.maxPixelDimension,
           ThumbnailGenerator.thumbnailExists(for: item.id, size: .medium, variant: Self.diskCacheVariant(for: item)) {
            return .medium
        }
        return size
    }

    private func cacheKey(
        for item: MediaItem,
        size: ThumbnailSize,
        displaySize: CGSize? = nil,
        displayScale: CGFloat = 1
    ) -> NSString {
        Self.thumbnailLoadIdentity(for: item, size: size, displaySize: displaySize, displayScale: displayScale) as NSString
    }

    private func cacheKey(itemId: UUID, sourceURL: URL, size: ThumbnailSize) -> NSString {
        "\(itemId.uuidString)|\(size.rawValue)|\(sourceURL.standardizedFileURL.path)" as NSString
    }

    private func fullImageCacheKey(for url: URL) -> NSString {
        "full|\(url.standardizedFileURL.path)" as NSString
    }

    private func refreshedDarkVideoThumbnailIfNeeded(
        cachedImage: NSImage,
        item: MediaItem,
        size: ThumbnailSize,
        maxPixelSize: Int? = nil,
        displayScale: CGFloat = 1
    ) async -> NSImage? {
        guard let sourceURL = item.thumbnailSource,
              ThumbnailGenerator.isVideo(sourceURL),
              ThumbnailGenerator.isLikelyDarkFrame(cachedImage) else {
            return nil
        }

        let refreshKey = Self.thumbnailLoadIdentity(for: item, size: size)
        guard !darkVideoRefreshAttempts.contains(refreshKey) else {
            return nil
        }
        darkVideoRefreshAttempts.insert(refreshKey)

        return await generateThumbnail(
            sourceURL: sourceURL,
            itemId: item.id,
            size: size,
            variant: Self.diskCacheVariant(for: item),
            requestKey: refreshKey + "|dark-refresh",
            forceGenerate: true,
            maxPixelSize: maxPixelSize,
            displayScale: displayScale
        )
    }

    // MARK: - Public API

    /// Load thumbnail for a media item.
    /// Checks memory cache first, then disk cache, then generates on-demand.
    ///
    /// - Parameters:
    ///   - item: The media item
    ///   - size: Thumbnail size tier (default: small for grid)
    /// - Returns: Cached or generated thumbnail, nil if unavailable
    func loadThumbnail(
        for item: MediaItem,
        size requestedSize: ThumbnailSize = .small,
        displaySize: CGSize? = nil,
        displayScale: CGFloat = 1
    ) async -> NSImage? {
        let startTime = CFAbsoluteTimeGetCurrent()
        let pixels = Self.thumbnailPixelSize(displaySize: displaySize, displayScale: displayScale)
        let scale = pixels == nil ? 1 : Self.backingScale(displayScale)
        let size = preferredSize(for: item, size: requestedSize, pixels: pixels)
        let diskOnlyUpgrade = size != requestedSize
        let key = cacheKey(for: item, size: size, displaySize: displaySize, displayScale: scale)
        let requestKey = key as String

        // Tier 1: Check memory cache
        if let cached = memoryCache.object(forKey: key) {
            if !diskOnlyUpgrade, let refreshed = await refreshedDarkVideoThumbnailIfNeeded(
                cachedImage: cached,
                item: item,
                size: size,
                maxPixelSize: pixels,
                displayScale: scale
            ) {
                let cost = estimatedBytes(for: refreshed)
                memoryCache.setObject(refreshed, forKey: key, cost: cost)
                PerfLog.cacheResult("loadThumbnail", hit: true, source: "memory-refresh")
                return refreshed
            }
            PerfLog.cacheResult("loadThumbnail", hit: true, source: "memory")
            return cached
        }

        guard let sourceURL = item.thumbnailSource else {
            logWarning("ImageCache: No thumbnailSource for item \(item.id) - no media files or contextImage")
            return nil
        }
        guard thumbnailFailures.shouldAttempt(requestKey) else { return nil }
        let variant = Self.diskCacheVariant(for: item)
        let generated = await generateThumbnail(
            sourceURL: sourceURL,
            itemId: item.id,
            size: size,
            variant: variant,
            requestKey: requestKey,
            forceGenerate: false,
            maxPixelSize: pixels,
            displayScale: scale,
            fallbackSize: diskOnlyUpgrade ? requestedSize : nil
        )

        if let image = generated {
            thumbnailFailures.recordSuccess(requestKey)
            var resolved = image
            if !diskOnlyUpgrade, let refreshed = await refreshedDarkVideoThumbnailIfNeeded(
                cachedImage: image,
                item: item,
                size: size,
                maxPixelSize: pixels,
                displayScale: scale
            ) {
                resolved = refreshed
            }
            storeInMemory(resolved, key: key, itemId: item.id)
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            PerfLog.cacheResult("loadThumbnail", hit: false, source: "disk-or-generated", elapsed: elapsed)
            return resolved
        } else if !Task.isCancelled,
                  thumbnailFailures.recordFailure(requestKey) {
            logWarning("ImageCache: Failed to generate thumbnail from \(sourceURL.path) - file may be corrupted or unsupported")
        }

        return nil
    }

    /// Load full-resolution image for detail view.
    /// Uses memory cache but does NOT generate thumbnails.
    /// Falls back to contextImage for context-only items.
    ///
    /// - Parameter item: The media item
    /// - Returns: Full resolution image or nil
    func loadFullImage(for item: MediaItem) async -> NSImage? {
        guard let sourceURL = item.thumbnailSource else {
            logWarning("ImageCache: No thumbnailSource for full image, item \(item.id)")
            return nil
        }

        return await loadFullImage(from: sourceURL)
    }

    /// Load full-resolution image from a specific URL.
    /// Used for carousel views where we need to display a specific media file.
    ///
    /// - Parameter url: The URL of the image to load
    /// - Returns: Full resolution image or nil
    func loadFullImage(from url: URL) async -> NSImage? {
        let key = fullImageCacheKey(for: url)
        let requestKey = key as String

        guard FileManager.default.fileExists(atPath: url.path) else {
            logWarning("ImageCache: File missing at \(url.path)")
            return nil
        }

        // Check memory cache
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        let semaphore = generationSemaphore
        let image = await fullImageLoadBroker.value(for: requestKey) {
            do { try await semaphore.acquire() } catch { return nil }
            guard !Task.isCancelled else {
                await semaphore.release()
                return nil
            }
            let image = Self.loadFullImageOffActor(from: url)
            await semaphore.release()
            return Task.isCancelled ? nil : image
        }

        if let image = image {
            // Only cache reasonably-sized full images (< 20MB estimated)
            let cost = estimatedBytes(for: image)
            if cost < 20_000_000 {
                memoryCache.setObject(image, forKey: key, cost: cost)
            }
        } else if !Task.isCancelled {
            logWarning("ImageCache: NSImage failed to load from \(url.path)")
        }

        return image
    }

    /// Load image by item ID and URL directly (for when you don't have full MediaItem)
    func loadThumbnail(itemId: UUID, from url: URL, size: ThumbnailSize = .small) async -> NSImage? {
        let key = cacheKey(itemId: itemId, sourceURL: url, size: size)
        let requestKey = key as String
        let variant = "source-\(Self.stablePathFingerprint(url.standardizedFileURL.path))"

        // Check memory cache
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }
        guard thumbnailFailures.shouldAttempt(requestKey) else { return nil }

        let generated = await generateThumbnail(
            sourceURL: url,
            itemId: itemId,
            size: size,
            variant: variant,
            requestKey: requestKey,
            forceGenerate: false
        )

        if let image = generated {
            thumbnailFailures.recordSuccess(requestKey)
            storeInMemory(image, key: key, itemId: itemId)
        } else if !Task.isCancelled {
            _ = thumbnailFailures.recordFailure(requestKey)
        }

        return generated
    }

    /// Load a thumbnail for a particular URL (carousel/mosaic slots). This shares
    /// the same bounded worker pool and request coalescing as item thumbnails,
    /// without creating an unbounded detached task per SwiftUI cell.
    func loadThumbnail(from url: URL, size: ThumbnailSize = .small) async -> NSImage? {
        let requestKey = "url|\(size.rawValue)|\(url.standardizedFileURL.path)"
        let key = requestKey as NSString
        if let cached = memoryCache.object(forKey: key) { return cached }
        guard thumbnailFailures.shouldAttempt(requestKey) else { return nil }

        let semaphore = generationSemaphore
        let image = await thumbnailLoadBroker.value(for: requestKey) {
            do { try await semaphore.acquire() } catch { return nil }
            guard !Task.isCancelled else {
                await semaphore.release()
                return nil
            }
            let image = ThumbnailGenerator.generate(from: url, size: size)
                .flatMap { ThumbnailGenerator.preparedThumbnail($0) }
            await semaphore.release()
            return Task.isCancelled ? nil : image
        }
        if let image {
            thumbnailFailures.recordSuccess(requestKey)
            let cost = estimatedBytes(for: image)
            memoryCache.setObject(image, forKey: key, cost: cost)
        } else if !Task.isCancelled {
            _ = thumbnailFailures.recordFailure(requestKey)
        }
        return image
    }

    /// Small, eagerly rendered blur backgrounds share the thumbnail memory budget.
    func loadBlurredThumbnail(for item: MediaItem, source: NSImage) async -> NSImage? {
        let key = "\(item.id.uuidString)|blur|\(source.size.width)x\(source.size.height)|\(item.thumbnailSource?.standardizedFileURL.path ?? "missing")"
        if let cached = memoryCache.object(forKey: key as NSString) { return cached }
        let semaphore = generationSemaphore
        let blurred = await thumbnailLoadBroker.value(for: key) {
            do { try await semaphore.acquire() } catch { return nil }
            let image = Task.isCancelled ? nil : Self.createBlurredThumbnail(source)
            await semaphore.release()
            return Task.isCancelled ? nil : image
        }
        if let blurred { storeInMemory(blurred, key: key as NSString, itemId: item.id) }
        return blurred
    }

    private nonisolated static let blurContext = CIContext(options: [.cacheIntermediates: false])

    private nonisolated static func createBlurredThumbnail(_ source: NSImage) -> NSImage? {
        guard let small = ThumbnailGenerator.preparedThumbnail(source, maxPixelSize: 128),
              let cg = small.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        let radius = 20 * CGFloat(max(cg.width, cg.height)) / max(source.size.width, source.size.height)
        let output = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: input.extent)
        guard let bitmap = blurContext.createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: bitmap, size: source.size)
    }

    // MARK: - Cache Management

    func retentionSnapshot() -> RetentionStats {
        let liveTrackedKeyCount = itemMemoryKeys.allKeys.reduce(into: 0) { count, key in
            if memoryCache.object(forKey: key as NSString) != nil {
                count += 1
            }
        }
        return RetentionStats(
            trackedItemCount: itemMemoryKeys.trackedItemCount,
            trackedItemKeyCount: itemMemoryKeys.trackedKeyCount,
            liveTrackedItemKeyCount: liveTrackedKeyCount,
            staleTrackedItemKeyCount: itemMemoryKeys.trackedKeyCount - liveTrackedKeyCount,
            trackedItemKeyLimit: itemMemoryKeys.maximumKeyCount,
            suppressedThumbnailFailureCount: thumbnailFailures.entryCount,
            suppressedThumbnailFailureLimit: thumbnailFailures.maximumEntryCount
        )
    }

    /// Prefetch thumbnails for items (call before they scroll into view)
    func prefetch(
        items: [MediaItem],
        size: ThumbnailSize = .small,
        displaySize: CGSize? = nil,
        displayScale: CGFloat = 1
    ) async {
        let token = PerfLog.begin("prefetch", category: .image, context: "\(items.count) items")
        defer { PerfLog.end(token) }

        // Disk hits need the same eager decode as visible requests.
        let toGenerate = items.filter { item in
            let tier = preferredSize(for: item, size: size,
                pixels: Self.thumbnailPixelSize(displaySize: displaySize, displayScale: displayScale))
            let key = cacheKey(for: item, size: tier, displaySize: displaySize, displayScale: displayScale)
            return memoryCache.object(forKey: key) == nil
        }

        guard !toGenerate.isEmpty else { return }
        PerfLog.event("prefetchCount", category: .image, context: "\(toGenerate.count) need loading")

        let candidates = Array(toGenerate.prefix(preloadItemLimit))
        let concurrency = batchGenerationConcurrency
        await withTaskGroup(of: Void.self) { group in
            var iterator = candidates.makeIterator()
            var inFlight = 0

            func addNext() -> Bool {
                guard !Task.isCancelled else { return false }
                guard let item = iterator.next() else { return false }
                group.addTask { [weak self] in
                    guard !Task.isCancelled else { return }
                    _ = await self?.loadThumbnail(for: item, size: size, displaySize: displaySize, displayScale: displayScale)
                }
                inFlight += 1
                return true
            }
            while inFlight < concurrency, addNext() {}
            for await _ in group {
                inFlight -= 1
                if Task.isCancelled {
                    group.cancelAll()
                } else {
                    _ = addNext()
                }
            }
        }
    }

    /// Hint that these items are in the active viewport window.
    /// "Touches" each cached image to prevent NSCache from evicting them.
    func hintActiveWindow(itemIds: Set<UUID>) {
        var staleKeys: Set<String> = []
        for id in itemIds {
            for keyString in itemMemoryKeys.keys(for: id) {
                let key = keyString as NSString
                if let img = memoryCache.object(forKey: key) {
                    let cost = estimatedBytes(for: img)
                    memoryCache.setObject(img, forKey: key, cost: cost)
                    itemMemoryKeys.touch(key: keyString)
                } else {
                    staleKeys.insert(keyString)
                }
            }
        }
        itemMemoryKeys.remove(keys: staleKeys)
    }

    /// Evict a specific item from memory cache
    func evict(itemId: UUID) {
        for key in itemMemoryKeys.remove(itemID: itemId) {
            memoryCache.removeObject(forKey: key as NSString)
        }
        thumbnailFailures.invalidate(itemID: itemId)
    }

    /// Evict a full-size image loaded by URL. Used after in-place image edits.
    func evict(url: URL) {
        memoryCache.removeObject(forKey: fullImageCacheKey(for: url))
        thumbnailFailures.invalidate(sourceURL: url)
    }

    /// Clear all memory cache (disk cache persists)
    func clearMemoryCache() {
        memoryCache.removeAllObjects()
        itemMemoryKeys.removeAll()
        itemMemoryStoresSincePrune = 0
    }

    /// Preload thumbnails from disk cache into memory for faster initial grid display.
    /// Call this during app initialization after items are loaded.
    ///
    /// Shares the bounded off-actor decode path used by visible requests.
    func preloadFromDisk(
        items: [MediaItem],
        size: ThumbnailSize = .small,
        displaySize: CGSize? = nil,
        displayScale: CGFloat = 1
    ) async {
        let token = PerfLog.begin("preloadFromDisk", category: .image, context: "\(items.count) items")
        defer { PerfLog.end(token) }

        let diskItems = items.compactMap { item -> MediaItem? in
            let tier = preferredSize(for: item, size: size,
                pixels: Self.thumbnailPixelSize(displaySize: displaySize, displayScale: displayScale))
            let key = cacheKey(for: item, size: tier, displaySize: displaySize, displayScale: displayScale)
            guard memoryCache.object(forKey: key) == nil,
                  ThumbnailGenerator.thumbnailExists(
                      for: item.id,
                      size: tier,
                      variant: Self.diskCacheVariant(for: item)
                  ) else { return nil }
            return item
        }

        guard !diskItems.isEmpty else {
            PerfLog.event("preloadSkipped", category: .image, context: "all \(items.count) in memory")
            return
        }

        let trimmedItems = Array(diskItems.prefix(preloadItemLimit))
        if trimmedItems.count < diskItems.count {
            PerfLog.event("preloadTrimmed", category: .image, context: "\(trimmedItems.count)/\(diskItems.count)")
        }

        var loadedCount = 0
        await withTaskGroup(of: Bool.self) { group in
            var iterator = trimmedItems.makeIterator()
            var inFlight = 0

            func addNextTask() -> Bool {
                guard !Task.isCancelled else { return false }
                guard let item = iterator.next() else { return false }
                group.addTask { [weak self] in
                    guard !Task.isCancelled else { return false }
                    return await self?.loadThumbnail(for: item, size: size, displaySize: displaySize, displayScale: displayScale) != nil
                }
                inFlight += 1
                return true
            }

            while inFlight < preloadReadConcurrency {
                if !addNextTask() { break }
            }

            for await loaded in group {
                inFlight -= 1

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                if loaded { loadedCount += 1 }

                _ = addNextTask()
            }
        }

        PerfLog.event("preloadComplete", category: .image, context: "\(loadedCount)/\(trimmedItems.count) loaded")
    }

    /// Clear both memory and disk cache for an item
    func clearAll(itemId: UUID) {
        evict(itemId: itemId)
        ThumbnailGenerator.deleteThumbnails(for: itemId)
    }

    // MARK: - Thumbnail Regeneration

    /// Regenerate thumbnail for a single item, optionally using saliency data.
    /// Clears existing cache and generates fresh thumbnail.
    ///
    /// - Parameters:
    ///   - item: The media item to regenerate thumbnail for
    ///   - size: Thumbnail size tier
    ///   - useSaliency: If true, uses item's saliency rect for smart cropping.
    ///                  WARNING: Saliency cropping changes aspect ratio - don't use for grid thumbnails.
    /// - Returns: The regenerated thumbnail or nil on failure
    func regenerateThumbnail(
        for item: MediaItem,
        size: ThumbnailSize = .small,
        useSaliency: Bool = false
    ) async -> NSImage? {
        // Clear existing cache
        clearAll(itemId: item.id)

        guard let sourceURL = item.thumbnailSource else {
            return nil
        }

        // Determine saliency rect to use
        let saliencyRect: CGRect? = useSaliency ? item.indexedContent?.cgSaliencyRect : nil

        let key = cacheKey(for: item, size: size)
        let generated = await generateThumbnail(
            sourceURL: sourceURL,
            itemId: item.id,
            size: size,
            variant: Self.diskCacheVariant(for: item),
            requestKey: (key as String) + "|regenerate",
            forceGenerate: true,
            saliencyRect: saliencyRect
        )

        if let image = generated {
            storeInMemory(image, key: key, itemId: item.id)
        }

        return generated
    }

    /// Regenerate thumbnails for multiple items.
    /// Clears existing cache and generates fresh thumbnails in batches.
    ///
    /// - Parameters:
    ///   - items: The media items to regenerate thumbnails for
    ///   - size: Thumbnail size tier
    ///   - useSaliency: If true, uses each item's saliency rect for smart cropping.
    ///   - progressCallback: Optional callback with (completed, total) counts
    func regenerateThumbnails(
        for items: [MediaItem],
        size: ThumbnailSize = .small,
        useSaliency: Bool = false,
        progressCallback: ((Int, Int) -> Void)? = nil
    ) async {
        let total = items.count
        var completed = 0

        // Process in batches to avoid memory spikes
        let batchSize = 20
        for batch in stride(from: 0, to: items.count, by: batchSize) {
            let endIndex = min(batch + batchSize, items.count)
            let batchItems = Array(items[batch..<endIndex])

            // Clear cache for batch
            for item in batchItems {
                clearAll(itemId: item.id)
            }

            for item in batchItems {
                guard let sourceURL = item.thumbnailSource else { continue }
                let key = cacheKey(for: item, size: size)
                let generated = await generateThumbnail(
                    sourceURL: sourceURL,
                    itemId: item.id,
                    size: size,
                    variant: Self.diskCacheVariant(for: item),
                    requestKey: (key as String) + "|regenerate",
                    forceGenerate: true,
                    saliencyRect: useSaliency ? item.indexedContent?.cgSaliencyRect : nil
                )
                if let generated {
                    storeInMemory(generated, key: key, itemId: item.id)
                }
            }

            completed += batchItems.count
            progressCallback?(completed, total)
        }
    }

    // MARK: - Private Helpers

    private func generateThumbnail(
        sourceURL: URL,
        itemId: UUID,
        size: ThumbnailSize,
        variant: String?,
        requestKey: String,
        forceGenerate: Bool,
        saliencyRect: CGRect? = nil,
        maxPixelSize: Int? = nil,
        displayScale: CGFloat = 1,
        fallbackSize: ThumbnailSize? = nil
    ) async -> NSImage? {
        let semaphore = generationSemaphore
        return await thumbnailLoadBroker.value(for: requestKey) {
            do { try await semaphore.acquire() } catch { return nil }
            guard !Task.isCancelled else {
                await semaphore.release()
                return nil
            }
            if !forceGenerate,
               let cached = ThumbnailGenerator.loadThumbnail(
                   for: itemId,
                   size: size,
                   variant: variant,
                   maxPixelSize: maxPixelSize,
                   displayScale: displayScale
               ) {
                await semaphore.release()
                return cached
            }
            // An md upgrade only consumes an existing file. A corrupt or removed
            // md falls back to sm; scrolling never generates the larger tier.
            let generationSize = fallbackSize ?? size
            if !forceGenerate, fallbackSize != nil,
               let fallback = ThumbnailGenerator.loadThumbnail(for: itemId, size: generationSize,
                   variant: variant, maxPixelSize: maxPixelSize, displayScale: displayScale) {
                await semaphore.release()
                return fallback
            }
            let generated = PerfLog.measure(
                "generateThumbnail",
                category: .image,
                context: sourceURL.lastPathComponent
            ) {
                ThumbnailGenerator.generateAndSave(
                    from: sourceURL,
                    itemId: itemId,
                    size: generationSize,
                    saliencyRect: saliencyRect,
                    variant: variant
                )
            }
            let decoded = generated.flatMap {
                ThumbnailGenerator.preparedThumbnail($0, maxPixelSize: maxPixelSize, displayScale: displayScale)
            }
            await semaphore.release()
            return Task.isCancelled ? nil : decoded
        }
    }

    private func storeInMemory(_ image: NSImage, key: NSString, itemId: UUID) {
        let cost = estimatedBytes(for: image)
        memoryCache.setObject(image, forKey: key, cost: cost)
        itemMemoryStoresSincePrune += 1
        if itemMemoryStoresSincePrune >= itemMemoryIndexPruneInterval {
            pruneStaleItemMemoryKeys()
        }

        let discardedKeys = itemMemoryKeys.record(key: key as String, itemID: itemId)
        removeDiscardedItemMemoryKeysFromCache(discardedKeys)
    }

    private func reconcileItemMemoryKeys(maximumKeyCount: Int) {
        pruneStaleItemMemoryKeys()
        let discardedKeys = itemMemoryKeys.setMaximumKeyCount(maximumKeyCount)
        removeDiscardedItemMemoryKeysFromCache(discardedKeys)
    }

    private func pruneStaleItemMemoryKeys() {
        let liveKeys = Set(itemMemoryKeys.allKeys.filter { key in
            memoryCache.object(forKey: key as NSString) != nil
        })
        itemMemoryKeys.retainOnly(liveKeys)
        itemMemoryStoresSincePrune = 0
    }

    private func removeDiscardedItemMemoryKeysFromCache(_ keys: Set<String>) {
        for key in keys {
            memoryCache.removeObject(forKey: key as NSString)
        }
    }

    private nonisolated static func loadFullImageOffActor(from url: URL) -> NSImage? {
        guard !Task.isCancelled,
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if (width * height) / 1_000_000 > 20 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4000,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                imageSource,
                0,
                options as CFDictionary
            ) else { return nil }
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }
        return NSImage(contentsOf: url)
    }

    /// Estimate memory cost of an image in bytes
    private func estimatedBytes(for image: NSImage) -> Int {
        // Use actual pixel dimensions from CGImage, not points (which underestimate on Retina)
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cgImage.bytesPerRow * cgImage.height
        }
        // Fallback: use points * 2 scale factor assumption
        let size = image.size
        return Int(size.width * size.height * 4 * 4)  // 2x scale squared
    }

    /// Load large image with downsampling
    private func loadDownsampled(from url: URL, maxPixels: Int) -> NSImage? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            logWarning("ImageCache: CGImageSource failed for \(url.path)")
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

// MARK: - Convenience Extensions

extension ImageCache {

    /// Get cache statistics for debugging
    var stats: CacheStats {
        get async {
            let diskSize = await ThumbnailCacheManager.shared.getCacheSize()
            return CacheStats(
                memoryCacheCount: memoryCache.countLimit,
                diskCacheSize: diskSize
            )
        }
    }

    struct CacheStats: Sendable {
        let memoryCacheCount: Int
        let diskCacheSize: Int64

        var diskCacheSizeFormatted: String {
            ByteCountFormatter.string(fromByteCount: diskCacheSize, countStyle: .file)
        }
    }

    /// Clear all caches (memory and disk)
    func clearAllCaches() async {
        clearMemoryCache()
        thumbnailFailures.removeAll()
        await ThumbnailCacheManager.shared.clearCache()
    }

    /// Clear disk cache only (keeps memory cache)
    func clearDiskCache() async {
        thumbnailFailures.removeAll()
        await ThumbnailCacheManager.shared.clearCache()
    }

    /// Perform LRU eviction if cache exceeds size limit
    func performEvictionIfNeeded() async {
        await ThumbnailCacheManager.shared.evictIfNeeded()
    }

    /// Check available disk space before batch operations
    /// Returns true if there's enough space (at least 100MB)
    func hasAvailableDiskSpace(requiredMB: Int = 100) -> Bool {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        do {
            let attrs = try fm.attributesOfFileSystem(forPath: appSupport.path)
            if let freeSize = attrs[.systemFreeSize] as? Int64 {
                let requiredBytes = Int64(requiredMB) * 1_000_000
                return freeSize > requiredBytes
            }
        } catch {
            logWarning("ImageCache: Failed to check disk space: \(error.localizedDescription)")
        }

        return true  // Assume we have space on error
    }
}

// MARK: - ThumbnailCacheManager

/// Manages disk-based thumbnail cache with LRU eviction
actor ThumbnailCacheManager {
    static let shared = ThumbnailCacheManager()

    /// Maximum cache size in bytes (1GB default)
    private let maxCacheSizeBytes: Int64 = 1_000_000_000

    /// Minimum free space to maintain (500MB)
    private let minFreeSpaceBytes: Int64 = 500_000_000

    private var cachedSize: Int64?
    private var lastSizeCheck: Date?

    private init() {}

    /// Get current cache size in bytes
    func getCacheSize() -> Int64 {
        // Cache the result for 30 seconds to avoid constant disk access
        if let cached = cachedSize, let lastCheck = lastSizeCheck,
           Date().timeIntervalSince(lastCheck) < 30 {
            return cached
        }

        let size = ThumbnailGenerator.cacheSize()
        cachedSize = size
        lastSizeCheck = Date()
        return size
    }

    /// Clear the entire thumbnail cache
    func clearCache() {
        do {
            try ThumbnailGenerator.clearCache()
            cachedSize = 0
            lastSizeCheck = Date()
            logInfo("ThumbnailCacheManager: Cache cleared")
        } catch {
            logError("ThumbnailCacheManager: Failed to clear cache: \(error.localizedDescription)")
        }
    }

    /// Evict oldest thumbnails if cache exceeds size limit
    func evictIfNeeded() {
        let currentSize = getCacheSize()

        guard currentSize > maxCacheSizeBytes else { return }

        let bytesToEvict = currentSize - maxCacheSizeBytes + (maxCacheSizeBytes / 10)  // Evict extra 10%
        evictOldestThumbnails(bytes: bytesToEvict)
    }

    /// Check if batch thumbnail generation is safe
    /// Returns false if disk space is critically low
    func canGenerateBatch(estimatedCount: Int) -> Bool {
        let fm = FileManager.default
        let cacheDir = ThumbnailGenerator.thumbnailCacheDirectory

        do {
            let attrs = try fm.attributesOfFileSystem(forPath: cacheDir.path)
            if let freeSize = attrs[.systemFreeSize] as? Int64 {
                // Estimate ~50KB per thumbnail
                let estimatedBytes = Int64(estimatedCount * 50_000)
                return freeSize > (minFreeSpaceBytes + estimatedBytes)
            }
        } catch {
            logWarning("ThumbnailCacheManager: Failed to check disk space: \(error.localizedDescription)")
        }

        return true  // Assume OK on error
    }

    // MARK: - Private

    private func evictOldestThumbnails(bytes targetBytes: Int64) {
        let fm = FileManager.default
        let cacheDir = ThumbnailGenerator.thumbnailCacheDirectory

        guard let enumerator = fm.enumerator(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        // Collect all cache files with their metadata
        var files: [(url: URL, size: Int, date: Date)] = []

        for case let fileURL as URL in enumerator {
            do {
                let attrs = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = attrs.fileSize ?? 0
                let date = attrs.contentModificationDate ?? Date.distantPast
                files.append((fileURL, size, date))
            } catch {
                continue
            }
        }

        // Sort by modification date (oldest first)
        files.sort { $0.date < $1.date }

        // Evict oldest files until we've freed enough space
        var evictedBytes: Int64 = 0
        var evictedCount = 0

        for file in files {
            guard evictedBytes < targetBytes else { break }

            do {
                try fm.removeItem(at: file.url)
                evictedBytes += Int64(file.size)
                evictedCount += 1
            } catch {
                continue
            }
        }

        // Invalidate cached size
        cachedSize = nil
        lastSizeCheck = nil

        logInfo("ThumbnailCacheManager: Evicted \(evictedCount) files, freed \(ByteCountFormatter.string(fromByteCount: evictedBytes, countStyle: .file))")
    }
}

// MARK: - AsyncSemaphore

/// FIFO, cancellation-aware limiter. Lowering the limit never revokes active permits;
/// releases pay down that excess before admitting another waiter.
actor AsyncSemaphore {
    private var limit: Int
    private var count: Int = 0
    private var waiterOrder = DeduplicatingFIFOBuffer<UUID>()
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    struct Snapshot: Sendable {
        let limit: Int
        let active: Int
        let waiting: Int
    }

    var snapshot: Snapshot { Snapshot(limit: limit, active: count, waiting: waiters.count) }

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)

        admitWaiters()
    }

    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Covers cancellation before registration; after registration the handler
                // removes the waiter on this actor. A granted permit belongs to the caller.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiterOrder.append(id)
                waiters[id] = continuation
                admitWaiters()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        precondition(count > 0, "Released an unowned semaphore permit")
        count -= 1
        admitWaiters()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        waiter.resume(throwing: CancellationError())
        admitWaiters()
    }

    private func admitWaiters() {
        while count < limit, let id = waiterOrder.popFirst() {
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            count += 1
            waiter.resume()
        }
    }
}
