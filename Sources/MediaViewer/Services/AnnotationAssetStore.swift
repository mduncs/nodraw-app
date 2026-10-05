import Foundation
import AppKit
import CryptoKit

// MARK: - AnnotationAssetStore

/// Actor-based storage for extracted subject PNG assets.
/// Uses content hash as key to dedupe repeated extractions.
/// Assets are stored in app support cache directory.
actor AnnotationAssetStore {

    /// Shared instance for app-wide asset storage
    static let shared = AnnotationAssetStore()

    // MARK: - Memory Cache

    /// NSCache for decoded NSImage, keyed by asset key
    private let imageCache: NSCache<NSString, NSImage>

    /// Cache wrapper for actor isolation
    private final class CacheWrapper: @unchecked Sendable {
        let cache: NSCache<NSString, NSImage>

        init() {
            cache = NSCache()
            cache.totalCostLimit = 100_000_000  // ~100MB
            cache.countLimit = 50
            cache.name = "com.nodraw.annotationassets"
        }
    }

    private let cacheWrapper: CacheWrapper

    // MARK: - Disk Storage

    /// Directory for persisted asset files
    private let assetDirectory: URL

    // MARK: - Initialization

    init(assetDirectory: URL? = nil) {
        self.cacheWrapper = CacheWrapper()
        self.imageCache = cacheWrapper.cache

        // Keep assets under the canonical app data root to avoid split state.
        let cacheDir = assetDirectory ?? AppPaths.appDataDirectory.appendingPathComponent("AnnotationAssets", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } catch {
            print("[AnnotationAssetStore] Failed to create asset directory: \(error)")
        }

        self.assetDirectory = cacheDir
    }

    // MARK: - Public API

    /// Save PNG data and return the asset key (content hash)
    func savePNG(_ data: Data) throws -> String {
        guard data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), NSImage(data: data) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: data)
        let assetKey = hash.compactMap { String(format: "%02x", $0) }.joined()

        let filePath = assetDirectory.appendingPathComponent("\(assetKey).png")

        // Skip write if already exists (deduplication)
        if FileManager.default.fileExists(atPath: filePath.path) {
            guard (try filePath.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
            guard try Data(contentsOf: filePath) == data else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            let staged = assetDirectory.appendingPathComponent(".asset-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: staged) }
            try DurableArchiveFile.write(data, to: staged)
            do { try DurableArchiveFile.publish(staged, to: filePath) }
            catch {
                // Another store can publish the same content hash concurrently.
                guard (try? Data(contentsOf: filePath)) == data else { throw error }
            }
        }
        try DurableArchiveFile.sync(filePath)
        try DurableArchiveFile.sync(assetDirectory)
        try DurableArchiveFile.sync(assetDirectory.deletingLastPathComponent())

        // Cache the decoded image (use pixel dimensions for cost, not point dimensions)
        if let nsImage = NSImage(data: data),
           let rep = nsImage.representations.first {
            let cost = rep.pixelsWide * rep.pixelsHigh * 4
            imageCache.setObject(nsImage, forKey: assetKey as NSString, cost: cost)
        }

        return assetKey
    }

    /// Load image by asset key (checks memory cache, then disk)
    /// Offloads disk I/O to background to avoid blocking actor executor
    func loadImage(_ assetKey: String) async -> NSImage? {
        // Check memory cache first (fast path, no disk I/O)
        if let cached = imageCache.object(forKey: assetKey as NSString) {
            return cached
        }

        // Offload disk read to background executor to avoid blocking actor
        let filePath = assetDirectory.appendingPathComponent("\(assetKey).png")
        let loadedImage: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: filePath),
                  let nsImage = NSImage(data: data) else {
                return nil
            }
            return nsImage
        }.value

        guard let nsImage = loadedImage else { return nil }

        // Cache for future use (use pixel dimensions for cost)
        if let rep = nsImage.representations.first {
            let cost = rep.pixelsWide * rep.pixelsHigh * 4
            imageCache.setObject(nsImage, forKey: assetKey as NSString, cost: cost)
        }

        return nsImage
    }

    /// Check if asset exists (either in memory or on disk)
    func exists(_ assetKey: String) -> Bool {
        if imageCache.object(forKey: assetKey as NSString) != nil {
            return true
        }
        let filePath = assetDirectory.appendingPathComponent("\(assetKey).png")
        return FileManager.default.fileExists(atPath: filePath.path)
    }

    /// Remove asset by key
    func remove(_ assetKey: String) {
        imageCache.removeObject(forKey: assetKey as NSString)

        let filePath = assetDirectory.appendingPathComponent("\(assetKey).png")
        try? FileManager.default.removeItem(at: filePath)
    }

    /// Remove assets not referenced by any current annotation set
    /// Call periodically to clean up orphaned assets
    func garbageCollect(referencedKeys: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: assetDirectory, includingPropertiesForKeys: nil) else {
            return
        }

        for file in files {
            let key = file.deletingPathExtension().lastPathComponent
            if !referencedKeys.contains(key) {
                try? FileManager.default.removeItem(at: file)
                imageCache.removeObject(forKey: key as NSString)
            }
        }
    }

    /// Clear all cached images from memory (disk assets preserved)
    func clearMemoryCache() {
        imageCache.removeAllObjects()
    }
}

// MARK: - Convenience Extensions

extension AnnotationAssetStore {
    /// Save CGImage as PNG and return asset key
    func saveCGImage(_ cgImage: CGImage) throws -> String {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try savePNG(pngData)
    }
}
