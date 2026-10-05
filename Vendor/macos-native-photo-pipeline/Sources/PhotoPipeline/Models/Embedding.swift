import Foundation

/// Embedding version corresponding to Apple's internal MD generations.
/// MD7v2 is the current version on macOS 14+.
public enum EmbeddingVersion: String, Sendable, Hashable, CaseIterable, Codable {
    case md4 = "MD4"
    case md5 = "MD5"
    case md6 = "MD6"
    case md7v2 = "MD7v2"
}

/// A dense float vector produced by CLIP-style embedding models.
public struct Embedding: Sendable, Hashable {
    public let vector: [Float]
    public let version: EmbeddingVersion
    public let dimension: Int

    public init(vector: [Float], version: EmbeddingVersion) {
        self.vector = vector
        self.version = version
        self.dimension = vector.count
    }

    /// Cosine similarity to another embedding.
    public func cosineSimilarity(to other: Embedding) -> Float {
        guard dimension == other.dimension, dimension > 0 else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<dimension {
            dot += vector[i] * other.vector[i]
            normA += vector[i] * vector[i]
            normB += other.vector[i] * other.vector[i]
        }
        let denom = sqrtf(normA) * sqrtf(normB)
        return denom > 0 ? dot / denom : 0
    }
}
