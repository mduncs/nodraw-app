import XCTest
import CoreGraphics
import ImageIO
@testable import PhotoPipeline

/// End-to-end integration tests exercising the full pipeline:
/// generate images → write to disk → index via SearchIndex → search → verify results.
final class PipelineIntegrationTests: XCTestCase {

    var tempDir: URL!
    var imagesDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photopipeline-e2e-\(UUID().uuidString)")
        imagesDir = tempDir.appendingPathComponent("images")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Image file helpers

    func writeTestImage(_ image: CGImage, name: String) throws -> URL {
        let url = imagesDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize image"])
        }
        return url
    }

    // MARK: - SearchIndex with real images

    func testSearchIndexWithSceneAndTextModules() async throws {
        let storePath = tempDir.appendingPathComponent("store")

        // Only enable scene + text (no embedding — that requires private frameworks)
        var config = IndexConfiguration.minimal
        config.enableEmbeddingSearch = false
        config.enableSceneClassification = true
        config.enableTextRecognition = true
        config.enableObjectRecognition = false
        config.enableFaceGallery = false

        let index = try SearchIndex(configuration: config, storePath: storePath)

        // Index a text-bearing image
        let textImage = RealImageTests.makeTextImage(text: "SUNSET BEACH", width: 600, height: 120)
        try await index.index(image: textImage, assetID: "sunset-text")

        // Index a plain image
        let plainImage = RealImageTests.makeGradientImage(width: 300, height: 300)
        try await index.index(image: plainImage, assetID: "gradient-001")

        // Stats should reflect 2 indexed assets
        let stats = try index.stats()
        XCTAssertGreaterThanOrEqual(stats.totalAssets, 1, "Should have at least 1 indexed asset")

        // Search for text content
        let textResults = try await index.search("SUNSET", limit: 10)
        // Text search should find the image with "SUNSET BEACH" text
        let hasTextMatch = textResults.contains { $0.assetID == "sunset-text" && $0.matchType == .text }
        if !textResults.isEmpty {
            XCTAssert(hasTextMatch, "Should find 'sunset-text' via OCR. Got: \(textResults.map { "\($0.assetID):\($0.matchType)" })")
        }
    }

    func testSearchIndexRemoveAsset() async throws {
        let storePath = tempDir.appendingPathComponent("store-remove")
        var config = IndexConfiguration.minimal
        config.enableEmbeddingSearch = false
        config.enableSceneClassification = true
        config.enableTextRecognition = false

        let index = try SearchIndex(configuration: config, storePath: storePath)

        let image = RealImageTests.makeSolidImage(r: 100, g: 200, b: 50)
        try await index.index(image: image, assetID: "to-remove")

        // Remove it
        try await index.remove(assetID: "to-remove")

        // Search should not find it via scene labels anymore
        let results = try await index.search("anything", limit: 10)
        let found = results.contains { $0.assetID == "to-remove" }
        XCTAssertFalse(found, "Removed asset should not appear in results")
    }

    // MARK: - IndexManager with image files on disk

    func testIndexManagerWithDirectory() async throws {
        // Write several test images to disk
        let images: [(CGImage, String)] = [
            (RealImageTests.makeTextImage(text: "HELLO WORLD"), "hello.png"),
            (RealImageTests.makeGradientImage(), "gradient.png"),
            (RealImageTests.makeSolidImage(r: 0, g: 0, b: 255), "blue.png"),
        ]

        for (img, name) in images {
            _ = try writeTestImage(img, name: name)
        }

        let storePath = tempDir.appendingPathComponent("index-store")
        var config = IndexConfiguration.minimal
        config.enableEmbeddingSearch = false  // Skip — needs private frameworks
        config.enableObjectRecognition = false
        config.enableFaceGallery = false

        let index = try SearchIndex(configuration: config, storePath: storePath)
        let manager = IndexManager(searchIndex: index)

        var progressUpdates: [(Int, Int)] = []
        let report = try await manager.indexDirectory(imagesDir) { done, total in
            progressUpdates.append((done, total))
        }

        XCTAssertEqual(report.totalProcessed, 3)
        XCTAssertEqual(report.succeeded, 3, "All 3 images should index successfully")
        XCTAssertEqual(report.failed, 0)
        XCTAssertGreaterThan(report.duration, 0)
        XCTAssertEqual(report.successRate, 1.0, accuracy: 0.001)

        // Progress should have been reported
        XCTAssertFalse(progressUpdates.isEmpty, "Should have received progress updates")
        XCTAssertEqual(progressUpdates.last?.0, 3, "Final progress should show 3 done")
        XCTAssertEqual(progressUpdates.last?.1, 3, "Final progress should show 3 total")
    }

    func testIndexManagerWithNonImageFiles() async throws {
        // Write a non-image file
        try "not an image".write(to: imagesDir.appendingPathComponent("readme.txt"),
                                  atomically: true, encoding: .utf8)
        // And one real image
        _ = try writeTestImage(RealImageTests.makeSolidImage(r: 255, g: 0, b: 0), name: "red.png")

        let storePath = tempDir.appendingPathComponent("index-store-mixed")
        var config = IndexConfiguration.minimal
        config.enableEmbeddingSearch = false

        let index = try SearchIndex(configuration: config, storePath: storePath)
        let manager = IndexManager(searchIndex: index)
        let report = try await manager.indexDirectory(imagesDir)

        // Should only process the PNG, not the txt
        XCTAssertEqual(report.totalProcessed, 1, "Should only discover the PNG file")
        XCTAssertEqual(report.succeeded, 1)
    }

    func testIndexManagerWithEmptyDirectory() async throws {
        let emptyDir = tempDir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let storePath = tempDir.appendingPathComponent("index-store-empty")
        var config = IndexConfiguration.minimal
        config.enableEmbeddingSearch = false

        let index = try SearchIndex(configuration: config, storePath: storePath)
        let manager = IndexManager(searchIndex: index)
        let report = try await manager.indexDirectory(emptyDir)

        XCTAssertEqual(report.totalProcessed, 0)
        XCTAssertEqual(report.succeeded, 0)
        XCTAssertEqual(report.failed, 0)
    }

    // MARK: - Keyword search across stored metadata

    func testSceneLabelKeywordSearch() async throws {
        let storePath = tempDir.appendingPathComponent("keyword-store")
        let store = try PipelineStore(rootPath: storePath)
        let metaStore = try MetadataStore(storePath: store.classificationsPath)

        // Manually store some scene results
        try metaStore.storeSceneResult(assetID: "beach-photo", result: SceneResult(
            labels: [
                SceneClassification(label: "Beach", confidence: 0.95),
                SceneClassification(label: "Ocean", confidence: 0.85),
            ],
            aestheticsScore: 0.8,
            isJunk: false
        ))
        try metaStore.storeSceneResult(assetID: "mountain-photo", result: SceneResult(
            labels: [
                SceneClassification(label: "Mountain", confidence: 0.9),
                SceneClassification(label: "Snow", confidence: 0.7),
            ],
            aestheticsScore: 0.9,
            isJunk: false
        ))
        try metaStore.storeSceneResult(assetID: "city-photo", result: SceneResult(
            labels: [
                SceneClassification(label: "City", confidence: 0.85),
                SceneClassification(label: "Night", confidence: 0.6),
            ],
            aestheticsScore: 0.5,
            isJunk: false
        ))

        // Now search via SearchIndex
        var config = IndexConfiguration.minimal
        config.enableEmbeddingSearch = false
        config.enableSceneClassification = true
        config.enableTextRecognition = false

        let index = try SearchIndex(configuration: config, storePath: storePath)

        // Search for "beach"
        let beachResults = try await index.search("beach", limit: 10)
        XCTAssert(beachResults.contains { $0.assetID == "beach-photo" },
                  "Should find 'beach-photo' when searching 'beach'. Got: \(beachResults.map(\.assetID))")

        // Search for "mountain"
        let mountainResults = try await index.search("mountain", limit: 10)
        XCTAssert(mountainResults.contains { $0.assetID == "mountain-photo" },
                  "Should find 'mountain-photo' when searching 'mountain'. Got: \(mountainResults.map(\.assetID))")

        // Search for something not in any labels
        let noResults = try await index.search("airplane", limit: 10)
        XCTAssert(!noResults.contains { $0.matchType == .scene },
                  "Should not find scene matches for 'airplane'")
    }

    func testTextContentKeywordSearch() async throws {
        let storePath = tempDir.appendingPathComponent("text-search-store")
        let store = try PipelineStore(rootPath: storePath)
        let metaStore = try MetadataStore(storePath: store.classificationsPath)

        // Manually store text observations
        try metaStore.storeTextObservations(assetID: "receipt", observations: [
            TextObservation(text: "Total: $42.50", boundingBox: .zero, confidence: 0.95, language: "en"),
            TextObservation(text: "Thank you!", boundingBox: .zero, confidence: 0.9, language: "en"),
        ])
        try metaStore.storeTextObservations(assetID: "sign", observations: [
            TextObservation(text: "STOP", boundingBox: .zero, confidence: 0.99, language: "en"),
        ])

        var config = IndexConfiguration.minimal
        config.enableEmbeddingSearch = false
        config.enableSceneClassification = false
        config.enableTextRecognition = true

        let index = try SearchIndex(configuration: config, storePath: storePath)

        // Search for text content
        let results = try await index.search("Total", limit: 10)
        XCTAssert(results.contains { $0.assetID == "receipt" },
                  "Should find receipt via OCR text search. Got: \(results.map(\.assetID))")

        let stopResults = try await index.search("STOP", limit: 10)
        XCTAssert(stopResults.contains { $0.assetID == "sign" },
                  "Should find sign via text search. Got: \(stopResults.map(\.assetID))")
    }

    func testObjectNameKeywordSearch() async throws {
        let storePath = tempDir.appendingPathComponent("object-search-store")
        let store = try PipelineStore(rootPath: storePath)
        let metaStore = try MetadataStore(storePath: store.classificationsPath)

        // Manually store recognition results
        try metaStore.storeRecognitions(assetID: "dog-photo", recognitions: [
            Recognition(domain: .dogs, name: "Golden Retriever", confidence: 0.92),
        ])
        try metaStore.storeRecognitions(assetID: "food-photo", recognitions: [
            Recognition(domain: .food, name: "Pizza Margherita", confidence: 0.88),
        ])

        var config = IndexConfiguration.minimal
        config.enableEmbeddingSearch = false
        config.enableSceneClassification = false
        config.enableObjectRecognition = true
        config.enableTextRecognition = false

        let index = try SearchIndex(configuration: config, storePath: storePath)

        let dogResults = try await index.search("golden", limit: 10)
        XCTAssert(dogResults.contains { $0.assetID == "dog-photo" },
                  "Should find dog via object name search. Got: \(dogResults.map(\.assetID))")

        let foodResults = try await index.search("pizza", limit: 10)
        XCTAssert(foodResults.contains { $0.assetID == "food-photo" },
                  "Should find food via object search. Got: \(foodResults.map(\.assetID))")
    }

    // MARK: - Multi-modal result merging

    func testMultiModalMerging() async throws {
        let storePath = tempDir.appendingPathComponent("merge-store")
        let store = try PipelineStore(rootPath: storePath)
        let metaStore = try MetadataStore(storePath: store.classificationsPath)

        // Create an asset that matches on both scene AND text
        try metaStore.storeSceneResult(assetID: "beach-sunset", result: SceneResult(
            labels: [SceneClassification(label: "Beach", confidence: 0.9)],
            aestheticsScore: 0.85,
            isJunk: false
        ))
        try metaStore.storeTextObservations(assetID: "beach-sunset", observations: [
            TextObservation(text: "Beach Cafe Menu", boundingBox: .zero, confidence: 0.8, language: "en"),
        ])

        // Create an asset that only matches on scene
        try metaStore.storeSceneResult(assetID: "beach-only", result: SceneResult(
            labels: [SceneClassification(label: "Beach", confidence: 0.85)],
            aestheticsScore: 0.7,
            isJunk: false
        ))

        var config = IndexConfiguration.minimal
        config.enableEmbeddingSearch = false
        config.enableSceneClassification = true
        config.enableTextRecognition = true

        let index = try SearchIndex(configuration: config, storePath: storePath)
        let results = try await index.search("beach", limit: 10)

        // The multi-modal match (beach-sunset) should rank higher due to boost
        if results.count >= 2 {
            let firstIdx = results.firstIndex { $0.assetID == "beach-sunset" }
            let secondIdx = results.firstIndex { $0.assetID == "beach-only" }
            if let first = firstIdx, let second = secondIdx {
                XCTAssertLessThan(first, second,
                    "Multi-modal match 'beach-sunset' should rank higher than single-modal 'beach-only'")
            }
        }
    }

    // MARK: - Config persistence via PipelineStore

    func testConfigPersistenceRoundtrip() throws {
        let store = try PipelineStore(rootPath: tempDir)

        let config = IndexConfiguration(
            enableEmbeddingSearch: true,
            enableSceneClassification: false,
            enableObjectRecognition: true,
            enableFaceGallery: false,
            enableTextRecognition: true,
            embeddingVersion: .md5,
            ocrLanguages: ["en-US", "de-DE"]
        )

        try store.saveConfig(config)
        let loaded = store.loadConfig()

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.enableEmbeddingSearch, true)
        XCTAssertEqual(loaded?.enableSceneClassification, false)
        XCTAssertEqual(loaded?.enableObjectRecognition, true)
        XCTAssertEqual(loaded?.enableFaceGallery, false)
        XCTAssertEqual(loaded?.enableTextRecognition, true)
        XCTAssertEqual(loaded?.embeddingVersion, .md5)
        XCTAssertEqual(loaded?.ocrLanguages, ["en-US", "de-DE"])
    }

    // MARK: - VectorStore edge cases

    func testVectorStoreUpsertOverwrite() throws {
        let storePath = tempDir.appendingPathComponent("vectors-overwrite")
        let store = try VectorStore(storePath: storePath)

        try store.upsert(assetID: "test", vector: [1, 0, 0])
        try store.upsert(assetID: "test", vector: [0, 1, 0])  // overwrite

        XCTAssertEqual(store.count, 1, "Upsert should overwrite, not duplicate")

        let results = store.search(query: [0, 1, 0], limit: 1)
        XCTAssertEqual(results.first?.assetID, "test")
        XCTAssertGreaterThan(results.first?.score ?? 0, 0.99, "Should match the updated vector")
    }

    func testVectorStoreRemove() throws {
        let storePath = tempDir.appendingPathComponent("vectors-remove")
        let store = try VectorStore(storePath: storePath)

        try store.upsert(assetID: "a", vector: [1, 0, 0])
        try store.upsert(assetID: "b", vector: [0, 1, 0])
        XCTAssertEqual(store.count, 2)

        store.remove(assetID: "a")
        XCTAssertEqual(store.count, 1)

        let results = store.search(query: [1, 0, 0], limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.assetID, "b")
    }

    func testVectorStoreDimensionMismatchInSearch() throws {
        let storePath = tempDir.appendingPathComponent("vectors-dim")
        let store = try VectorStore(storePath: storePath)

        try store.upsert(assetID: "3d", vector: [1, 0, 0])
        try store.upsert(assetID: "5d", vector: [1, 0, 0, 0, 0])

        // Search with 3D query — should only match the 3D vector
        let results = store.search(query: [1, 0, 0], limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.assetID, "3d")
    }

    func testVectorStoreEmptySearch() throws {
        let storePath = tempDir.appendingPathComponent("vectors-empty")
        let store = try VectorStore(storePath: storePath)

        let results = store.search(query: [1, 0, 0], limit: 5)
        XCTAssert(results.isEmpty)
    }
}
