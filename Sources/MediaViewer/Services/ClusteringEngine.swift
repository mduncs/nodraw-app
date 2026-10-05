import Foundation
import Accelerate
import GRDB

// MARK: - Clustering Result Types

/// Result of a similarity search
struct SimilarityResult: Sendable {
    let itemId: UUID
    let similarity: Float
}

// MARK: - Clustering Engine (CLIP 768D)

/// Actor-based engine for semantic clustering and similarity search.
/// Uses 768-dimensional CLIP embeddings via CLIPVectorStore.
/// Replaces the old 2048D VNFeaturePrint-based engine.
actor ClusteringEngine {

    nonisolated(unsafe) private static var _shared: ClusteringEngine?

    nonisolated static var shared: ClusteringEngine {
        guard let instance = _shared else {
            fatalError("ClusteringEngine.shared accessed before setShared(_:) was called")
        }
        return instance
    }

    /// Optional access for call sites that can gracefully skip work until configured.
    nonisolated static var sharedIfConfigured: ClusteringEngine? {
        _shared
    }

    nonisolated static func setShared(_ engine: ClusteringEngine) {
        _shared = engine
    }

    nonisolated static var isConfigured: Bool { _shared != nil }

    // MARK: - Dependencies

    private let database: DatabaseManager
    private let vectorStore: CLIPVectorStore

    // MARK: - State

    private(set) var isClustering: Bool = false
    private var cachedThemes: [ThemeCluster] = []
    /// User-overridden cluster names (ephemeral, in-memory)
    private var customNames: [Int: String] = [:]

    // MARK: - Init

    init(database: DatabaseManager = .shared) {
        self.database = database
        self.vectorStore = CLIPVectorStore(db: database)
    }

    // MARK: - Similarity Search

    /// Find k most similar items to a given item using CLIP cosine similarity.
    func findSimilar(to itemId: UUID, k: Int = 10) async throws -> [SimilarityResult] {
        let results = try await vectorStore.findSimilar(to: itemId, k: k)
        return results.map { SimilarityResult(itemId: $0.itemId, similarity: $0.similarity) }
    }

    /// Find items similar to a query vector.
    func findSimilar(toVector vector: [Float], k: Int = 10, excludeIds: Set<UUID> = []) async throws -> [SimilarityResult] {
        let results = try await vectorStore.findSimilar(toVector: vector, k: k, excludeIds: excludeIds)
        return results.map { SimilarityResult(itemId: $0.itemId, similarity: $0.similarity) }
    }

    // MARK: - Theme Clustering

    /// Run k-means clustering on CLIP vectors to find visual themes.
    /// Returns cluster assignments stored in memory (not persisted — themes are ephemeral).
    func computeThemes(k: Int = 20) async throws -> [ThemeCluster] {
        guard !isClustering else { return [] }
        isClustering = true
        defer { isClustering = false }

        let allVectors = try await vectorStore.fetchAll()
        guard allVectors.count >= k else {
            logWarning("ClusteringEngine: Not enough vectors (\(allVectors.count)) for k=\(k) themes")
            return []
        }

        let vectors = allVectors.map { $0.1 }
        let itemIds = allVectors.map { $0.0 }
        let d = CLIPVectorRecord.dimension

        // K-means++ initialization
        var centroids = initializeCentroids(from: vectors, k: k)

        // Run k-means iterations
        let iterations = 10
        for _ in 0..<iterations {
            // Assign each vector to nearest centroid
            var assignments = [Int](repeating: 0, count: vectors.count)
            for (i, vec) in vectors.enumerated() {
                var bestCluster = 0
                var bestSim: Float = -.infinity
                for (j, centroid) in centroids.enumerated() {
                    var dot: Float = 0
                    vDSP_dotpr(vec, 1, centroid, 1, &dot, vDSP_Length(d))
                    if dot > bestSim {
                        bestSim = dot
                        bestCluster = j
                    }
                }
                assignments[i] = bestCluster
            }

            // Recompute centroids
            for j in 0..<k {
                let members = (0..<vectors.count).filter { assignments[$0] == j }
                guard !members.isEmpty else { continue }

                var newCentroid = [Float](repeating: 0, count: d)
                for idx in members {
                    vDSP_vadd(newCentroid, 1, vectors[idx], 1, &newCentroid, 1, vDSP_Length(d))
                }
                // Normalize
                var norm: Float = 0
                vDSP_svesq(newCentroid, 1, &norm, vDSP_Length(d))
                norm = sqrt(norm)
                if norm > 0 {
                    vDSP_vsdiv(newCentroid, 1, &norm, &newCentroid, 1, vDSP_Length(d))
                }
                centroids[j] = newCentroid
            }
        }

        // Build theme clusters
        var themes: [ThemeCluster] = []
        for j in 0..<k {
            var members: [(UUID, Float)] = []
            for (i, vec) in vectors.enumerated() {
                var dot: Float = 0
                vDSP_dotpr(vec, 1, centroids[j], 1, &dot, vDSP_Length(d))
                if dot > 0 {
                    // Only include items actually assigned to this cluster
                    var bestCluster = 0
                    var bestSim: Float = -.infinity
                    for (c, centroid) in centroids.enumerated() {
                        var d2: Float = 0
                        vDSP_dotpr(vec, 1, centroid, 1, &d2, vDSP_Length(d))
                        if d2 > bestSim { bestSim = d2; bestCluster = c }
                    }
                    if bestCluster == j {
                        members.append((itemIds[i], dot))
                    }
                }
            }

            if !members.isEmpty {
                members.sort { $0.1 > $1.1 }
                themes.append(ThemeCluster(
                    id: j,
                    itemIds: members.map { $0.0 },
                    representativeIds: Array(members.prefix(5).map { $0.0 }),
                    count: members.count,
                    name: "Cluster \(j)"
                ))
            }
        }

        // Sort by size descending
        themes.sort { $0.count > $1.count }
        cachedThemes = themes
        logInfo("ClusteringEngine: computed \(themes.count) themes from \(allVectors.count) vectors")
        return themes
    }

    // MARK: - Cluster Browser API

    /// Run clustering, derive names, and cache results for browsing.
    func runClustering(k: Int = 20) async throws {
        let _ = try await computeThemes(k: k)
        try await deriveClusterNames()
    }

    /// Derive descriptive names for each cached cluster from ML labels.
    private func deriveClusterNames() async throws {
        guard !cachedThemes.isEmpty else { return }

        var named: [ThemeCluster] = []
        for var theme in cachedThemes {
            // Use all item IDs (not just representatives) for better label coverage
            let sampleIds = Array(theme.itemIds.prefix(50))
            let labels = try await database.read { db in
                try MediaAttribute.fetchTopLabels(db: db, itemIds: sampleIds, topK: 5)
            }

            if let top = labels.first {
                theme.name = customNames[theme.id] ?? Self.titleCase(top.key)
                theme.topLabels = labels.prefix(3).map { Self.titleCase($0.key) }
            } else {
                theme.name = customNames[theme.id] ?? "Cluster \(theme.id)"
            }
            named.append(theme)
        }
        cachedThemes = named
    }

    /// Set a custom name for a cluster (overrides auto-derived name).
    func renameCluster(_ clusterId: Int, to name: String) {
        customNames[clusterId] = name
        if let idx = cachedThemes.firstIndex(where: { $0.id == clusterId }) {
            cachedThemes[idx].name = name
        }
    }

    /// Get the display name for a cluster.
    func clusterName(_ clusterId: Int) -> String {
        cachedThemes.first { $0.id == clusterId }?.name ?? "Cluster \(clusterId)"
    }

    /// Title-case a label key: "outdoor_scene" -> "Outdoor Scene"
    private nonisolated static func titleCase(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ")
           .split(separator: " ")
           .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
           .joined(separator: " ")
    }

    /// Summary of cached clusters with names and labels.
    func clusterSummary() throws -> [(clusterId: Int, count: Int, name: String, topLabels: [String])] {
        cachedThemes.map { (clusterId: $0.id, count: $0.count, name: $0.name, topLabels: $0.topLabels) }
    }

    /// Representative item IDs per cluster from cache.
    func clusterRepresentatives(perCluster: Int = 3) throws -> [Int: [UUID]] {
        var result: [Int: [UUID]] = [:]
        for theme in cachedThemes {
            result[theme.id] = Array(theme.representativeIds.prefix(perCluster))
        }
        return result
    }

    /// All item IDs in a given cluster from cache.
    func itemsInCluster(_ clusterId: Int) throws -> [UUID] {
        cachedThemes.first { $0.id == clusterId }?.itemIds ?? []
    }

    // MARK: - K-means++ Init

    private nonisolated func initializeCentroids(from vectors: [[Float]], k: Int) -> [[Float]] {
        guard !vectors.isEmpty && k > 0 else { return [] }
        let d = vectors[0].count

        var centroids: [[Float]] = []
        var usedIndices = Set<Int>()

        let firstIdx = Int.random(in: 0..<vectors.count)
        centroids.append(vectors[firstIdx])
        usedIndices.insert(firstIdx)

        while centroids.count < k && centroids.count < vectors.count {
            var distances = [Float](repeating: 0, count: vectors.count)
            var totalDist: Float = 0

            for (i, vec) in vectors.enumerated() where !usedIndices.contains(i) {
                var minDist: Float = .infinity
                for centroid in centroids {
                    var dot: Float = 0
                    vDSP_dotpr(vec, 1, centroid, 1, &dot, vDSP_Length(d))
                    let dist = 1 - dot
                    minDist = min(minDist, dist)
                }
                distances[i] = minDist * minDist
                totalDist += distances[i]
            }

            guard totalDist > 0 else { break }
            var threshold = Float.random(in: 0..<totalDist)
            for (i, dist) in distances.enumerated() where !usedIndices.contains(i) {
                threshold -= dist
                if threshold <= 0 {
                    centroids.append(vectors[i])
                    usedIndices.insert(i)
                    break
                }
            }
        }

        return centroids
    }
}

// MARK: - Theme Cluster

/// A visual theme cluster computed from CLIP embeddings.
struct ThemeCluster: Identifiable, Sendable {
    let id: Int
    let itemIds: [UUID]
    let representativeIds: [UUID]
    let count: Int
    /// Auto-derived name from ML labels (e.g. "Outdoor Scene")
    var name: String
    /// Top label tags for display as subtitle
    var topLabels: [String] = []
}
