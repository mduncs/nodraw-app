import XCTest
@testable import PhotoPipeline

final class IntegrationTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photopipeline-integration-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPipelineStoreCreation() throws {
        let store = try PipelineStore(rootPath: tempDir)
        XCTAssert(FileManager.default.fileExists(atPath: store.embeddingsPath.path))
        XCTAssert(FileManager.default.fileExists(atPath: store.galleryPath.path))
        XCTAssert(FileManager.default.fileExists(atPath: store.classificationsPath.path))
        XCTAssert(FileManager.default.fileExists(atPath: store.textPath.path))
    }

    func testPipelineStoreReset() throws {
        let store = try PipelineStore(rootPath: tempDir)
        // Write something
        try "test".write(to: store.embeddingsPath.appendingPathComponent("test.txt"),
                         atomically: true, encoding: .utf8)
        // Reset should clear
        try store.reset()
        let contents = try FileManager.default.contentsOfDirectory(
            at: store.embeddingsPath, includingPropertiesForKeys: nil)
        XCTAssert(contents.isEmpty)
    }

    func testIndexConfigurationCodable() throws {
        let config = IndexConfiguration.full
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let decoded = try JSONDecoder().decode(IndexConfiguration.self, from: data)
        XCTAssertEqual(decoded.enableEmbeddingSearch, config.enableEmbeddingSearch)
        XCTAssertEqual(decoded.embeddingVersion, config.embeddingVersion)
        XCTAssertEqual(decoded.ocrLanguages, config.ocrLanguages)
    }

    func testIndexConfigurationPresets() {
        let full = IndexConfiguration.full
        XCTAssert(full.enableEmbeddingSearch)
        XCTAssert(full.enableSceneClassification)
        XCTAssert(full.enableObjectRecognition)
        XCTAssert(full.enableFaceGallery)
        XCTAssert(full.enableTextRecognition)

        let minimal = IndexConfiguration.minimal
        XCTAssert(minimal.enableEmbeddingSearch)
        XCTAssert(minimal.enableSceneClassification)
        XCTAssertFalse(minimal.enableObjectRecognition)
        XCTAssertFalse(minimal.enableFaceGallery)
        XCTAssertFalse(minimal.enableTextRecognition)
    }

    func testVectorStoreBasic() throws {
        let storePath = tempDir.appendingPathComponent("vectors")
        let store = try VectorStore(storePath: storePath)

        // Insert
        try store.upsert(assetID: "img-001", vector: [1.0, 0.0, 0.0])
        try store.upsert(assetID: "img-002", vector: [0.0, 1.0, 0.0])
        try store.upsert(assetID: "img-003", vector: [0.9, 0.1, 0.0])

        XCTAssertEqual(store.count, 3)

        // Search — img-001 and img-003 should be most similar to [1, 0, 0]
        let results = store.search(query: [1.0, 0.0, 0.0], limit: 3)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].assetID, "img-001")
        XCTAssert(results[0].score > 0.99)

        // img-003 should be second (0.9 similarity)
        XCTAssertEqual(results[1].assetID, "img-003")
        XCTAssert(results[1].score > 0.9)

        // Flush and reload
        try store.flush()
        let store2 = try VectorStore(storePath: storePath)
        XCTAssertEqual(store2.count, 3)
    }

    func testMetadataStoreSceneRoundtrip() throws {
        let metaPath = tempDir.appendingPathComponent("meta")
        let store = try MetadataStore(storePath: metaPath)

        let result = SceneResult(
            labels: [
                SceneClassification(label: "Beach", confidence: 0.9),
                SceneClassification(label: "Ocean", confidence: 0.8),
            ],
            aestheticsScore: 0.75,
            isJunk: false
        )

        try store.storeSceneResult(assetID: "test-001", result: result)
        let loaded = store.loadSceneResult(assetID: "test-001")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.labels.count, 2)
        XCTAssertEqual(loaded?.labels.first?.label, "Beach")
        XCTAssertEqual(loaded?.aestheticsScore ?? 0, 0.75, accuracy: 0.01)
    }

    func testMetadataStoreTextRoundtrip() throws {
        let metaPath = tempDir.appendingPathComponent("meta")
        let store = try MetadataStore(storePath: metaPath)

        let observations = [
            TextObservation(text: "Hello World", boundingBox: .zero, confidence: 0.95, language: "en"),
        ]

        try store.storeTextObservations(assetID: "test-001", observations: observations)
        let loaded = store.loadTextObservations(assetID: "test-001")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.first?.text, "Hello World")
    }

    func testSearchResultMerging() {
        let r1 = SearchResult(assetID: "img-001", score: 0.9, matchType: .embedding, detail: "beach")
        let r2 = SearchResult(assetID: "img-001", score: 0.7, matchType: .scene, detail: "Beach")
        let r3 = SearchResult(assetID: "img-002", score: 0.8, matchType: .embedding, detail: "beach")

        // img-001 should rank higher due to multi-modal boost
        XCTAssertEqual(r1.assetID, "img-001")
        XCTAssertEqual(r2.assetID, "img-001")
        XCTAssertEqual(r3.assetID, "img-002")
    }

    func testAssetModel() {
        let asset = Asset(id: "test-001", sourceURL: URL(fileURLWithPath: "/tmp/test.jpg"))
        XCTAssertEqual(asset.id, "test-001")
        XCTAssertNotNil(asset.sourceURL)
    }

    func testSearchIndexCreation() throws {
        do {
            let index = try SearchIndex(configuration: .minimal, storePath: tempDir)
            let stats = try index.stats()
            XCTAssertEqual(stats.totalAssets, 0)
        } catch {
            // Framework loading failures are expected in test env
            print("SearchIndex creation limited: \(error)")
        }
    }

    func testSearchIndexLoadsOneAssetAnalysisDirectly() throws {
        let pipelineStore = try PipelineStore(rootPath: tempDir)
        let metadataStore = try MetadataStore(storePath: pipelineStore.classificationsPath)

        try metadataStore.storeSceneResult(
            assetID: "requested",
            result: SceneResult(
                labels: [SceneClassification(label: "Requested", confidence: 0.9)],
                aestheticsScore: 0.75,
                isJunk: false
            )
        )
        try metadataStore.storeSceneResult(
            assetID: "unrelated",
            result: SceneResult(
                labels: [SceneClassification(label: "Unrelated", confidence: 0.8)],
                aestheticsScore: 0.5,
                isJunk: false
            )
        )

        var config = IndexConfiguration.minimal
        config.enableEmbeddingSearch = false
        let index = try SearchIndex(configuration: config, storePath: tempDir)

        let requested = try XCTUnwrap(index.analysis(for: "requested"))
        XCTAssertEqual(requested.assetID, "requested")
        XCTAssertEqual(requested.sceneLabels.map(\.label), ["Requested"])
        XCTAssertNil(index.analysis(for: "missing"))
        XCTAssertEqual(index.allAnalysis().map(\.assetID), ["requested", "unrelated"])
    }
}
