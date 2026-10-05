import Foundation

/// Manages the storage silo for a PhotoPipeline instance.
///
/// Each app gets its own isolated storage directory:
/// ```
/// {storePath}/
///   embeddings/     — MADVectorDatabase IVF index files
///   gallery/        — VUGallery CoreData face identity store
///   classifications/ — scene/object/domain classification cache
///   text/           — recognized text per asset
///   config.json     — index configuration, versions
/// ```
public final class PipelineStore: @unchecked Sendable {

    public let rootPath: URL

    public var embeddingsPath: URL { rootPath.appendingPathComponent("embeddings") }
    public var galleryPath: URL { rootPath.appendingPathComponent("gallery") }
    public var classificationsPath: URL { rootPath.appendingPathComponent("classifications") }
    public var textPath: URL { rootPath.appendingPathComponent("text") }
    public var configPath: URL { rootPath.appendingPathComponent("config.json") }

    /// Create or open a pipeline store at the given root path.
    public init(rootPath: URL) throws {
        self.rootPath = rootPath
        try createDirectoryStructure()
    }

    /// Create the default silo in Application Support.
    ///
    /// Path: `~/Library/Application Support/{bundleID}/PhotoPipeline/`
    public static func defaultStore() throws -> PipelineStore {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.photopipeline.default"
        let root = appSupport.appendingPathComponent(bundleID).appendingPathComponent("PhotoPipeline")
        return try PipelineStore(rootPath: root)
    }

    /// Total size of all stored data in bytes.
    public func totalSizeBytes() throws -> UInt64 {
        var total: UInt64 = 0
        let fm = FileManager.default

        if let enumerator = fm.enumerator(at: rootPath, includingPropertiesForKeys: [.fileSizeKey]) {
            while let url = enumerator.nextObject() as? URL {
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += UInt64(size)
                }
            }
        }

        return total
    }

    /// Number of indexed assets (by counting embedding files).
    public func indexedAssetCount() throws -> Int {
        let metaPath = embeddingsPath.appendingPathComponent("meta")
        guard FileManager.default.fileExists(atPath: metaPath.path) else { return 0 }
        let files = try FileManager.default.contentsOfDirectory(at: metaPath, includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension == "emb" }.count
    }

    /// Delete all stored data and recreate the directory structure.
    public func reset() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: rootPath.path) {
            try fm.removeItem(at: rootPath)
        }
        try createDirectoryStructure()
    }

    /// Save the current configuration.
    public func saveConfig(_ config: IndexConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(config)
        try data.write(to: configPath)
    }

    /// Load saved configuration, or nil if none exists.
    public func loadConfig() -> IndexConfiguration? {
        guard let data = try? Data(contentsOf: configPath) else { return nil }
        return try? JSONDecoder().decode(IndexConfiguration.self, from: data)
    }

    // MARK: - Private

    private func createDirectoryStructure() throws {
        let fm = FileManager.default
        let dirs = [rootPath, embeddingsPath, galleryPath, classificationsPath, textPath]
        for dir in dirs {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
