/// CLI tool to index a folder of photos and persist the index.
///
/// Usage:
///   photo-indexer index /path/to/photos --store /path/to/store
///   photo-indexer search "sunset beach" --store /path/to/store
///   photo-indexer stats --store /path/to/store
///   photo-indexer reset --store /path/to/store

import Foundation
import PhotoPipeline
import ImageIO

@main
struct PhotoIndexer {
    static func main() async throws {
        let args = CommandLine.arguments

        guard args.count >= 2 else {
            printUsage()
            return
        }

        let command = args[1]
        let storePath = parseStore(args) ?? defaultStorePath()

        switch command {
        case "index":
            guard args.count >= 3 else {
                print("Usage: photo-indexer index <directory> [--store <path>]")
                return
            }
            try await runIndex(directory: args[2], storePath: storePath)

        case "search":
            guard args.count >= 3 else {
                print("Usage: photo-indexer search <query> [--store <path>]")
                return
            }
            try await runSearch(query: args[2], storePath: storePath)

        case "stats":
            try runStats(storePath: storePath)

        case "reset":
            try runReset(storePath: storePath)

        case "diagnostics":
            runDiagnostics()

        default:
            printUsage()
        }
    }

    static func runIndex(directory: String, storePath: URL) async throws {
        let dir = URL(fileURLWithPath: directory)
        let config = IndexConfiguration.full
        let index = try SearchIndex(configuration: config, storePath: storePath)
        let manager = IndexManager(searchIndex: index)

        print("Indexing \(dir.path) → \(storePath.path)")
        let start = Date()
        let report = try await manager.indexDirectory(dir) { done, total in
            let pct = total > 0 ? Int(Double(done) / Double(total) * 100) : 0
            print("\r  [\(pct)%] \(done)/\(total)", terminator: "")
            fflush(stdout)
        }
        print()

        let duration = Date().timeIntervalSince(start)
        print("Done in \(String(format: "%.1f", duration))s")
        print("  Succeeded: \(report.succeeded)")
        print("  Failed: \(report.failed)")
        print("  Success rate: \(String(format: "%.1f", report.successRate * 100))%")

        if !report.errors.isEmpty {
            print("  Errors:")
            for (id, err) in report.errors.prefix(5) {
                print("    \(id): \(err)")
            }
        }
    }

    static func runSearch(query: String, storePath: URL) async throws {
        guard let config = PipelineStore(rootPath: storePath).loadConfig() ?? Optional(IndexConfiguration.full) else {
            print("No index found at \(storePath.path). Run 'index' first.")
            return
        }

        let index = try SearchIndex(configuration: config, storePath: storePath)
        let results = try await index.search(query, limit: 20)

        print("Results for \"\(query)\":")
        if results.isEmpty {
            print("  (none)")
        }
        for (i, r) in results.enumerated() {
            print("  \(i + 1). \(r.assetID) — \(r.detail) [\(r.matchType.rawValue)] score=\(String(format: "%.3f", r.score))")
        }
    }

    static func runStats(storePath: URL) throws {
        let store = try PipelineStore(rootPath: storePath)
        let bytes = (try? store.totalSizeBytes()) ?? 0
        let count = (try? store.indexedAssetCount()) ?? 0

        print("Store: \(storePath.path)")
        print("  Assets: \(count)")
        print("  Size: \(bytes / 1024) KB (\(bytes / 1024 / 1024) MB)")

        if let config = store.loadConfig() {
            print("  Config:")
            print("    Embeddings: \(config.enableEmbeddingSearch)")
            print("    Scenes: \(config.enableSceneClassification)")
            print("    Objects: \(config.enableObjectRecognition)")
            print("    Faces: \(config.enableFaceGallery)")
            print("    Text: \(config.enableTextRecognition)")
            print("    Embedding version: \(config.embeddingVersion.rawValue)")
            print("    OCR languages: \(config.ocrLanguages.joined(separator: ", "))")
        }
    }

    static func runReset(storePath: URL) throws {
        let store = try PipelineStore(rootPath: storePath)
        try store.reset()
        print("Store reset: \(storePath.path)")
    }

    static func runDiagnostics() {
        let report = Diagnostics.systemReport()
        print(report)
    }

    static func parseStore(_ args: [String]) -> URL? {
        if let idx = args.firstIndex(of: "--store"), idx + 1 < args.count {
            return URL(fileURLWithPath: args[idx + 1])
        }
        return nil
    }

    static func defaultStorePath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("PhotoPipelineIndexer")
    }

    static func printUsage() {
        print("""
        photo-indexer — Index and search photos using Apple's ML pipeline

        Commands:
          index <directory> [--store <path>]    Index images in a directory
          search <query> [--store <path>]       Search the index
          stats [--store <path>]                Show index statistics
          reset [--store <path>]                Clear all indexed data
          diagnostics                           Show system compatibility

        Default store: ~/Library/Application Support/PhotoPipelineIndexer/
        """)
    }
}

extension PipelineStore {
    convenience init(rootPath: URL) {
        try! self.init(rootPath: rootPath)
    }

    func loadConfig() -> IndexConfiguration? {
        guard let data = try? Data(contentsOf: configPath) else { return nil }
        return try? JSONDecoder().decode(IndexConfiguration.self, from: data)
    }
}
