import Foundation
import CoreGraphics
import Darwin

// MARK: - Subject Mask Cache

/// Actor-based cache for pre-analyzed subject masks.
/// Prevents redundant Vision analysis when returning to previously viewed images.
/// Uses FIFO eviction when cache exceeds max entry count OR byte budget.
@available(macOS 14.0, *)
actor SubjectMaskCache {

    /// Shared instance for app-wide caching
    static let shared = SubjectMaskCache()

    /// Maximum number of cached entries
    private let maxEntries: Int

    /// Maximum total byte budget (~200MB)
    private let maxBytes: Int

    /// Maximum subjects per entry (caller should prefix before storing)
    static let maxSubjectsPerEntry: Int = 10

    /// Cache storage: URL path -> cached masks
    private var cache: [String: CacheEntry] = [:]

    /// Insertion order for FIFO eviction
    private var insertionOrder: [String] = []

    /// Running total of cached bytes
    private var totalBytes: Int = 0

    init(maxEntries: Int = 30, maxBytes: Int = 200 * 1024 * 1024) {
        self.maxEntries = max(1, maxEntries)
        self.maxBytes = max(0, maxBytes)
    }

    /// Fresh on-disk identity, not URL resource values (which Foundation can cache).
    struct SourceVersion: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let byteSize: Int64
    }

    nonisolated static func sourceVersion(for url: URL) -> SourceVersion? {
        guard url.isFileURL else { return nil }
        var info = stat()
        // fstatat with flags=0 follows file symlinks and always fetches fresh metadata.
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return fstatat(AT_FDCWD, path, &info, 0)
        }
        guard result == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        return SourceVersion(device: info.st_dev, inode: UInt64(info.st_ino),
                             modifiedSeconds: info.st_mtimespec.tv_sec,
                             modifiedNanoseconds: info.st_mtimespec.tv_nsec, byteSize: info.st_size)
    }

    // MARK: - Cache Entry

    private struct CacheEntry {
        let masks: [SubjectMask]
        let sourceVersion: SourceVersion
        let byteSize: Int
    }

    // MARK: - Public API

    /// Get cached masks for a URL, if available
    /// - Parameter url: Image URL
    /// - Returns: Cached SubjectMask array, or nil if not cached
    func get(for url: URL) -> [SubjectMask]? {
        let key = url.path
        guard let entry = cache[key] else { return nil }
        guard let version = Self.sourceVersion(for: url), version == entry.sourceVersion else {
            evict(url)
            return nil
        }
        return entry.masks
    }

    /// Store masks for a URL
    /// - Parameters:
    ///   - masks: Array of SubjectMask from Vision analysis
    ///   - url: Image URL
    ///   - expectedVersion: Version captured before analysis; changed-source results are discarded.
    func set(_ masks: [SubjectMask], for url: URL, expectedVersion: SourceVersion? = nil) {
        let key = url.path
        guard let version = Self.sourceVersion(for: url) else {
            evict(url)
            return
        }
        if let expectedVersion, expectedVersion != version {
            // A late old analysis must not overwrite (or evict) a newer valid entry.
            if cache[key]?.sourceVersion != version { evict(url) }
            return
        }
        let boundedMasks = Array(masks.prefix(Self.maxSubjectsPerEntry))
        let entryBytes = Self.estimateBytes(for: boundedMasks)
        guard entryBytes <= maxBytes else {
            evict(url)
            return
        }

        // If key exists, update in place
        if let existing = cache[key] {
            totalBytes -= existing.byteSize
            cache[key] = CacheEntry(masks: boundedMasks, sourceVersion: version, byteSize: entryBytes)
            totalBytes += entryBytes
            evictUntilWithinBudget()
            return
        }

        // Evict until within both limits
        while cache.count >= maxEntries || (totalBytes + entryBytes > maxBytes && !cache.isEmpty) {
            evictOldest()
        }

        // Insert new entry
        cache[key] = CacheEntry(masks: boundedMasks, sourceVersion: version, byteSize: entryBytes)
        insertionOrder.append(key)
        totalBytes += entryBytes
    }

    /// Check if masks are cached for a URL
    /// - Parameter url: Image URL
    /// - Returns: True if cached
    func contains(_ url: URL) -> Bool {
        get(for: url) != nil
    }

    /// Remove cached masks for a specific URL
    /// - Parameter url: Image URL to evict
    func evict(_ url: URL) {
        let key = url.path
        if let entry = cache.removeValue(forKey: key) {
            totalBytes -= entry.byteSize
        }
        insertionOrder.removeAll { $0 == key }
    }

    /// Clear entire cache (call on memory pressure)
    func clearAll() {
        cache.removeAll()
        insertionOrder.removeAll()
        totalBytes = 0
        Log.info("SubjectMaskCache: cleared all entries")
    }

    /// Current cache size
    var count: Int {
        cache.count
    }

    /// Current estimated memory usage in bytes
    var estimatedBytes: Int {
        totalBytes
    }

    // MARK: - Private

    /// Estimate byte size of a mask array (maskPixelData is the dominant cost)
    private static func estimateBytes(for masks: [SubjectMask]) -> Int {
        masks.reduce(0) { total, mask in
            // maskPixelData + CGImage backing (~4 bytes/pixel for RGBA)
            total + mask.maskPixelData.count + (mask.mask.width * mask.mask.height * 4)
        }
    }

    /// Evict the oldest entry (FIFO)
    private func evictOldest() {
        guard let oldestKey = insertionOrder.first else { return }
        if let entry = cache.removeValue(forKey: oldestKey) {
            totalBytes -= entry.byteSize
        }
        insertionOrder.removeFirst()
    }

    /// Evict entries until total bytes is within budget
    private func evictUntilWithinBudget() {
        while totalBytes > maxBytes && !insertionOrder.isEmpty {
            evictOldest()
        }
    }
}
