import XCTest
import GRDB
import Accelerate
@testable import MediaViewer

/// Tests for CLIP-based clustering engine and similarity search.
final class ClusteringTests: XCTestCase {

    // MARK: - SIMD Similarity Tests

    func testCosineSimilarity_IdenticalVectors() async throws {
        let vector = normalizedVector(dimension: CLIPVectorRecord.dimension)
        let candidates = [vector, vector, vector]

        let similarities = computeSimilarities(query: vector, candidates: candidates, k: 3)

        XCTAssertEqual(similarities.count, 3)
        for sim in similarities {
            XCTAssertEqual(sim.similarity, 1.0, accuracy: 0.001)
        }
    }

    func testCosineSimilarity_OrthogonalVectors() async throws {
        var vectorA = [Float](repeating: 0, count: 100)
        var vectorB = [Float](repeating: 0, count: 100)
        vectorA[0] = 1.0
        vectorB[1] = 1.0

        let similarities = computeSimilarities(query: vectorA, candidates: [vectorB], k: 1)

        XCTAssertEqual(similarities.count, 1)
        XCTAssertEqual(similarities[0].similarity, 0.0, accuracy: 0.001)
    }

    func testCosineSimilarity_SortedDescending() async throws {
        let query = normalizedVector(dimension: 100, seed: 42)

        var similar = query
        similar[0] += 0.1
        normalize(&similar)

        var lessSimilar = query.map { $0 * 0.5 + Float.random(in: -0.5...0.5) }
        normalize(&lessSimilar)

        var dissimilar = normalizedVector(dimension: 100, seed: 999)
        normalize(&dissimilar)

        let candidates = [similar, lessSimilar, dissimilar]
        let similarities = computeSimilarities(query: query, candidates: candidates, k: 3)

        XCTAssertEqual(similarities.count, 3)
        XCTAssertGreaterThanOrEqual(similarities[0].similarity, similarities[1].similarity)
        XCTAssertGreaterThanOrEqual(similarities[1].similarity, similarities[2].similarity)
    }

    func testCosineSimilarity_TopKLimiting() async throws {
        let query = normalizedVector(dimension: 100)
        let candidates = (0..<20).map { _ in normalizedVector(dimension: 100) }

        let k = 5
        let similarities = computeSimilarities(query: query, candidates: candidates, k: k)

        XCTAssertEqual(similarities.count, k)
    }

    // MARK: - ThemeCluster Tests

    func testThemeClusterIdentifiable() {
        let theme = ThemeCluster(
            id: 0,
            itemIds: [UUID(), UUID()],
            representativeIds: [UUID()],
            count: 2,
            name: "Test Theme"
        )
        XCTAssertEqual(theme.id, 0)
        XCTAssertEqual(theme.count, 2)
    }

    func testSimilarityResultFields() {
        let id = UUID()
        let result = SimilarityResult(itemId: id, similarity: 0.95)
        XCTAssertEqual(result.itemId, id)
        XCTAssertEqual(result.similarity, 0.95)
    }

    // MARK: - Performance Tests

    func testSIMDSimilarityPerformance() async throws {
        let query = normalizedVector(dimension: CLIPVectorRecord.dimension)
        let candidates = (0..<5000).map { _ in normalizedVector(dimension: CLIPVectorRecord.dimension) }

        let start = CFAbsoluteTimeGetCurrent()
        let _ = computeSimilarities(query: query, candidates: candidates, k: 10)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 1.0, "SIMD similarity for 5000 candidates should complete in <1s")
    }

    // MARK: - Helpers

    private func normalizedVector(dimension: Int, seed: Int? = nil) -> [Float] {
        var vector: [Float]
        if let seed = seed {
            srand48(seed)
            vector = (0..<dimension).map { _ in Float(drand48() * 2 - 1) }
        } else {
            vector = (0..<dimension).map { _ in Float.random(in: -1...1) }
        }
        normalize(&vector)
        return vector
    }

    private func normalize(_ vector: inout [Float]) {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 0 else { return }
        vDSP_vsdiv(vector, 1, &norm, &vector, 1, vDSP_Length(vector.count))
    }

    private func computeSimilarities(
        query: [Float],
        candidates: [[Float]],
        k: Int
    ) -> [(index: Int, similarity: Float)] {
        let n = candidates.count
        let d = query.count

        guard n > 0 && d > 0 else { return [] }

        var matrix = [Float](repeating: 0, count: n * d)
        for (i, row) in candidates.enumerated() {
            let startIdx = i * d
            for (j, val) in row.enumerated() {
                matrix[startIdx + j] = val
            }
        }

        var similarities = [Float](repeating: 0, count: n)

        vDSP_mmul(
            matrix, 1,
            query, 1,
            &similarities, 1,
            vDSP_Length(n),
            1,
            vDSP_Length(d)
        )

        return similarities.enumerated()
            .sorted { $0.element > $1.element }
            .prefix(k)
            .map { (index: $0.offset, similarity: $0.element) }
    }
}
