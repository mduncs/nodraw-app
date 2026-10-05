import XCTest
@testable import PhotoPipeline

final class EmbeddingTests: XCTestCase {

    func testEmbeddingCosineSimilarity() {
        let a = Embedding(vector: [1, 0, 0], version: .md7v2)
        let b = Embedding(vector: [1, 0, 0], version: .md7v2)
        XCTAssertEqual(a.cosineSimilarity(to: b), 1.0, accuracy: 0.001)
    }

    func testEmbeddingOrthogonal() {
        let a = Embedding(vector: [1, 0, 0], version: .md7v2)
        let b = Embedding(vector: [0, 1, 0], version: .md7v2)
        XCTAssertEqual(a.cosineSimilarity(to: b), 0.0, accuracy: 0.001)
    }

    func testEmbeddingOpposite() {
        let a = Embedding(vector: [1, 0, 0], version: .md7v2)
        let b = Embedding(vector: [-1, 0, 0], version: .md7v2)
        XCTAssertEqual(a.cosineSimilarity(to: b), -1.0, accuracy: 0.001)
    }

    func testEmbeddingDimensionMismatch() {
        let a = Embedding(vector: [1, 0], version: .md7v2)
        let b = Embedding(vector: [1, 0, 0], version: .md7v2)
        XCTAssertEqual(a.cosineSimilarity(to: b), 0.0)
    }

    func testEmbeddingEmpty() {
        let a = Embedding(vector: [], version: .md7v2)
        let b = Embedding(vector: [], version: .md7v2)
        XCTAssertEqual(a.cosineSimilarity(to: b), 0.0)
    }

    func testEmbeddingSearchInit() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photopipeline-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Init should create directory and try loading frameworks
        do {
            _ = try EmbeddingSearch(storePath: tempDir)
        } catch {
            // Framework loading may fail — that's expected in test env
            print("EmbeddingSearch init failed (expected without frameworks): \(error)")
        }

        // Directory should exist regardless
        XCTAssert(FileManager.default.fileExists(atPath: tempDir.path))
    }
}
