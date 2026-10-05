import XCTest
@testable import PhotoPipeline

/// Performance benchmarks for storage and search operations.
final class PerformanceTests: XCTestCase {

    var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photopipeline-perf-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - VectorStore Performance

    func testVectorStoreInsert1000() throws {
        let storePath = tempDir.appendingPathComponent("vectors")
        let store = try VectorStore(storePath: storePath)
        let dim = 512

        measure {
            for i in 0..<1000 {
                let vector = (0..<dim).map { _ in Float.random(in: -1...1) }
                try! store.upsert(assetID: "perf-\(i)", vector: vector)
            }
        }

        XCTAssertEqual(store.count, 1000)
    }

    func testVectorStoreSearch1000() throws {
        let storePath = tempDir.appendingPathComponent("vectors")
        let store = try VectorStore(storePath: storePath)
        let dim = 512

        // Pre-populate
        for i in 0..<1000 {
            let vector = (0..<dim).map { _ in Float.random(in: -1...1) }
            try store.upsert(assetID: "vec-\(i)", vector: vector)
        }

        let query = (0..<dim).map { _ in Float.random(in: -1...1) }

        measure {
            let results = store.search(query: query, limit: 20)
            XCTAssertEqual(results.count, 20)
        }
    }

    func testVectorStoreFlushAndReload1000() throws {
        let storePath = tempDir.appendingPathComponent("vectors")
        let dim = 128

        // Create and populate
        let store = try VectorStore(storePath: storePath)
        for i in 0..<1000 {
            let vector = (0..<dim).map { _ in Float.random(in: -1...1) }
            try store.upsert(assetID: "flush-\(i)", vector: vector)
        }

        measure {
            try! store.flush()
        }

        // Verify reload
        let reloaded = try VectorStore(storePath: storePath)
        XCTAssertEqual(reloaded.count, 1000)
    }

    func testVectorStoreSearchAccuracy() throws {
        let storePath = tempDir.appendingPathComponent("vectors-accuracy")
        let store = try VectorStore(storePath: storePath)

        // Insert known vectors
        try store.upsert(assetID: "north", vector: [0, 1, 0])
        try store.upsert(assetID: "south", vector: [0, -1, 0])
        try store.upsert(assetID: "east", vector: [1, 0, 0])
        try store.upsert(assetID: "west", vector: [-1, 0, 0])
        try store.upsert(assetID: "northeast", vector: [0.707, 0.707, 0])

        // Search for north-ish direction
        let results = store.search(query: [0.1, 0.99, 0], limit: 5)
        XCTAssertEqual(results[0].assetID, "north", "Nearest to [0.1, 0.99, 0] should be 'north'")
        XCTAssertEqual(results[1].assetID, "northeast", "Second nearest should be 'northeast'")

        // Verify scores are descending
        for i in 0..<(results.count - 1) {
            XCTAssertGreaterThanOrEqual(results[i].score, results[i + 1].score)
        }
    }

    // MARK: - MetadataStore Performance

    func testMetadataStoreBulkWrite() throws {
        let metaPath = tempDir.appendingPathComponent("meta")
        let store = try MetadataStore(storePath: metaPath)

        measure {
            for i in 0..<500 {
                let result = SceneResult(
                    labels: [
                        SceneClassification(label: "Beach", confidence: 0.9),
                        SceneClassification(label: "Ocean", confidence: 0.8),
                        SceneClassification(label: "Sunset", confidence: 0.7),
                    ],
                    aestheticsScore: Float.random(in: 0...1),
                    isJunk: false
                )
                try! store.storeSceneResult(assetID: "bulk-\(i)", result: result)
            }
        }
    }

    func testMetadataStoreBulkRead() throws {
        let metaPath = tempDir.appendingPathComponent("meta")
        let store = try MetadataStore(storePath: metaPath)

        // Pre-populate
        for i in 0..<500 {
            let result = SceneResult(
                labels: [SceneClassification(label: "Beach", confidence: 0.9)],
                aestheticsScore: 0.5,
                isJunk: false
            )
            try store.storeSceneResult(assetID: "read-\(i)", result: result)
        }

        measure {
            for i in 0..<500 {
                let loaded = store.loadSceneResult(assetID: "read-\(i)")
                XCTAssertNotNil(loaded)
            }
        }
    }

    // MARK: - PipelineStore Performance

    func testPipelineStoreSizeCalculation() throws {
        let store = try PipelineStore(rootPath: tempDir)

        // Write some test data
        for i in 0..<100 {
            let data = Data(repeating: UInt8(i % 256), count: 1024)
            let path = store.embeddingsPath.appendingPathComponent("test-\(i).emb")
            try data.write(to: path)
        }

        measure {
            let bytes = try! store.totalSizeBytes()
            XCTAssertGreaterThan(bytes, 0)
        }
    }

    // MARK: - IndexConfiguration Performance

    func testConfigurationEncodeDecode() throws {
        let config = IndexConfiguration.full
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        measure {
            for _ in 0..<1000 {
                let data = try! encoder.encode(config)
                let _ = try! decoder.decode(IndexConfiguration.self, from: data)
            }
        }
    }
}
