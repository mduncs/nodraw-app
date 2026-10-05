/// Basic PhotoPipeline search example.
///
/// Usage: swift run basic-search /path/to/photos "search query"

import Foundation
import PhotoPipeline
import ImageIO

@main
struct BasicSearch {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("Usage: basic-search <image-directory> <search-query>")
            print("Example: basic-search ~/Photos \"sunset at the beach\"")
            return
        }

        let imagesDir = URL(fileURLWithPath: args[1])
        let query = args[2]

        // Check compatibility
        let report = Diagnostics.systemReport()
        print(report)
        print()

        // Create index with minimal config (fast)
        let storePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("photopipeline-example-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storePath) }

        let index = try SearchIndex(configuration: .minimal, storePath: storePath)
        let manager = IndexManager(searchIndex: index)

        // Index all images
        print("Indexing \(imagesDir.path)...")
        let indexReport = try await manager.indexDirectory(imagesDir) { done, total in
            print("\r  \(done)/\(total)", terminator: "")
        }
        print()
        print("Indexed \(indexReport.succeeded)/\(indexReport.totalProcessed) in \(String(format: "%.1f", indexReport.duration))s")

        if !indexReport.errors.isEmpty {
            print("Errors:")
            for (id, err) in indexReport.errors.prefix(3) {
                print("  \(id): \(err)")
            }
        }
        print()

        // Search
        print("Searching: \"\(query)\"")
        let results = try await index.search(query, limit: 10)

        if results.isEmpty {
            print("No results found.")
        } else {
            for (i, result) in results.enumerated() {
                print("  \(i + 1). \(result.assetID)")
                print("     Score: \(String(format: "%.3f", result.score))")
                print("     Match: \(result.matchType.rawValue)")
                print("     Detail: \(result.detail)")
            }
        }

        // Show stats
        let stats = try index.stats()
        print()
        print("Index stats:")
        print("  Assets: \(stats.totalAssets)")
        print("  Embeddings: \(stats.embeddingCount)")
        print("  Size: \(stats.storeSizeBytes / 1024) KB")
    }
}
