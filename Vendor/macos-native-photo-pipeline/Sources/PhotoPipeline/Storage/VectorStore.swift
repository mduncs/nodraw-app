import Foundation

/// Lightweight vector storage backed by flat files.
///
/// Used as fallback when MADVectorDatabase isn't available.
/// Supports brute-force cosine similarity search — adequate for
/// collections under ~10K vectors. For larger collections,
/// MADVectorDatabase's IVF index is strongly preferred.
public final class VectorStore: @unchecked Sendable {

    private let storePath: URL
    private let lock = NSLock()
    private var cache: [String: [Float]] = [:]
    private var dirty = false

    public init(storePath: URL) throws {
        self.storePath = storePath
        try FileManager.default.createDirectory(at: storePath, withIntermediateDirectories: true)
        try loadIndex()
    }

    /// Insert or replace an embedding for an asset.
    public func upsert(assetID: String, vector: [Float]) throws {
        lock.lock()
        defer { lock.unlock() }
        cache[assetID] = vector
        dirty = true
    }

    /// Get an embedding vector by asset ID.
    public func get(assetID: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return cache[assetID]
    }

    /// Remove an embedding.
    public func remove(assetID: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: assetID)
        dirty = true
    }

    /// Brute-force cosine similarity search.
    public func search(query: [Float], limit: Int = 20) -> [(assetID: String, score: Float)] {
        lock.lock()
        let snapshot = cache
        lock.unlock()

        guard !query.isEmpty else { return [] }

        let queryNorm = l2Norm(query)
        guard queryNorm > 0 else { return [] }

        var results: [(String, Float)] = []
        for (assetID, vector) in snapshot {
            guard vector.count == query.count else { continue }
            let sim = cosineSim(query, vector, queryNorm: queryNorm)
            results.append((assetID, sim))
        }

        return results
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }

    /// Number of stored vectors.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    /// Flush cached vectors to disk.
    public func flush() throws {
        lock.lock()
        defer { lock.unlock() }
        guard dirty else { return }

        for (assetID, vector) in cache {
            let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
            let filePath = storePath.appendingPathComponent("\(assetID).vec")
            try data.write(to: filePath)
        }
        dirty = false
    }

    // MARK: - Private

    private func loadIndex() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storePath.path) else { return }
        let files = try fm.contentsOfDirectory(at: storePath, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "vec" }

        for file in files {
            let assetID = file.deletingPathExtension().lastPathComponent
            let data = try Data(contentsOf: file)
            let floats = data.withUnsafeBytes { buf in
                Array(buf.bindMemory(to: Float.self))
            }
            cache[assetID] = floats
        }
    }

    private func l2Norm(_ v: [Float]) -> Float {
        var sum: Float = 0
        for x in v { sum += x * x }
        return sqrtf(sum)
    }

    private func cosineSim(_ a: [Float], _ b: [Float], queryNorm: Float) -> Float {
        var dot: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normB += b[i] * b[i]
        }
        let denom = queryNorm * sqrtf(normB)
        return denom > 0 ? dot / denom : 0
    }
}
