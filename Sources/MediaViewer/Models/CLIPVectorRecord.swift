import Foundation
import GRDB
import Accelerate

// MARK: - CLIPVectorRecord

/// GRDB record for the `clip_vectors` table.
/// Stores 768-dimensional CLIP embeddings quantized to Float16 (1536 bytes each).
/// Pre-normalized to unit length so dot product = cosine similarity.
struct CLIPVectorRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "clip_vectors"

    /// CLIP embedding dimension (from pipeline)
    static let dimension = 768

    let itemId: UUID
    let vectorData: Data  // 1536 bytes (768 × Float16)
    let version: Int
    let extractedAt: Date

    // MARK: - Creation

    /// Create a record from raw float vector, normalizing and quantizing.
    static func create(from floats: [Float], itemId: UUID, version: Int = 1) -> Self {
        // Normalize to unit length
        var normalized = floats
        var norm: Float = 0
        vDSP_svesq(floats, 1, &norm, vDSP_Length(floats.count))
        norm = sqrt(norm)

        if norm > 0 {
            vDSP_vsdiv(floats, 1, &norm, &normalized, 1, vDSP_Length(floats.count))
        }

        // Quantize to Float16
        let float16 = normalized.map { Float16($0) }
        let data = float16.withUnsafeBufferPointer { Data(buffer: $0) }

        return Self(itemId: itemId, vectorData: data, version: version, extractedAt: Date())
    }

    // MARK: - Conversion

    /// Upcast stored Float16 data back to Float32 for computation.
    func asFloats() -> [Float] {
        vectorData.withUnsafeBytes { ptr in
            let float16 = ptr.bindMemory(to: Float16.self)
            return float16.map { Float($0) }
        }
    }

    // MARK: - GRDB PersistableRecord

    func encode(to container: inout PersistenceContainer) {
        container["itemId"] = itemId.uuidString
        container["vectorData"] = vectorData
        container["version"] = version
        container["extractedAt"] = extractedAt
    }

    // MARK: - GRDB FetchableRecord

    init(row: Row) throws {
        guard let idString: String = row["itemId"],
              let id = UUID(uuidString: idString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in clip_vectors itemId"
                )
            )
        }
        self.itemId = id
        self.vectorData = row["vectorData"]
        self.version = row["version"]
        self.extractedAt = row["extractedAt"]
    }

    // MARK: - Direct init

    init(itemId: UUID, vectorData: Data, version: Int, extractedAt: Date) {
        self.itemId = itemId
        self.vectorData = vectorData
        self.version = version
        self.extractedAt = extractedAt
    }
}

// MARK: - Query Methods

extension CLIPVectorRecord {
    func upsert(db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO clip_vectors (itemId, vectorData, version, extractedAt)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(itemId) DO UPDATE SET
                    vectorData = excluded.vectorData,
                    version = excluded.version,
                    extractedAt = excluded.extractedAt
            """,
            arguments: [itemId.uuidString, vectorData, version, extractedAt]
        )
    }

    static func fetch(db: Database, itemId: UUID) throws -> CLIPVectorRecord? {
        try CLIPVectorRecord.fetchOne(
            db,
            sql: "SELECT * FROM clip_vectors WHERE itemId = ?",
            arguments: [itemId.uuidString]
        )
    }

    static func fetchBatch(db: Database, itemIds: [UUID]) throws -> [CLIPVectorRecord] {
        guard !itemIds.isEmpty else { return [] }
        let placeholders = itemIds.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT * FROM clip_vectors WHERE itemId IN (\(placeholders))"
        let arguments = StatementArguments(itemIds.map { $0.uuidString })
        return try CLIPVectorRecord.fetchAll(db, sql: sql, arguments: arguments)
    }

    static func fetchAll(db: Database) throws -> [CLIPVectorRecord] {
        try CLIPVectorRecord.fetchAll(db, sql: "SELECT * FROM clip_vectors")
    }

    static func delete(db: Database, itemId: UUID) throws {
        try db.execute(
            sql: "DELETE FROM clip_vectors WHERE itemId = ?",
            arguments: [itemId.uuidString]
        )
    }

    static func count(db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_vectors") ?? 0
    }
}

// MARK: - CLIPVectorStore

/// Actor-based store for CLIP vectors, providing similarity search.
actor CLIPVectorStore {
    private let db: DatabaseManager

    init(db: DatabaseManager = .shared) {
        self.db = db
    }

    func store(vector: [Float], for itemId: UUID) async throws {
        let record = CLIPVectorRecord.create(from: vector, itemId: itemId)
        try await db.write { db in
            try record.upsert(db: db)
        }
    }

    func fetch(for itemId: UUID) async throws -> [Float]? {
        try await db.read { db in
            try CLIPVectorRecord.fetch(db: db, itemId: itemId)?.asFloats()
        }
    }

    func fetchAll() async throws -> [(UUID, [Float])] {
        try await db.read { db in
            let records = try CLIPVectorRecord.fetchAll(db: db)
            return records.map { ($0.itemId, $0.asFloats()) }
        }
    }

    func delete(for itemId: UUID) async throws {
        try await db.write { db in
            try CLIPVectorRecord.delete(db: db, itemId: itemId)
        }
    }

    func count() async throws -> Int {
        try await db.read { db in
            try CLIPVectorRecord.count(db: db)
        }
    }

    /// Find k most similar items using CLIP cosine similarity.
    func findSimilar(to itemId: UUID, k: Int = 10) async throws -> [(itemId: UUID, similarity: Float)] {
        guard let queryVector = try await fetch(for: itemId) else { return [] }
        return try await findSimilar(toVector: queryVector, k: k, excludeIds: [itemId])
    }

    /// Find k most similar items to a query vector.
    func findSimilar(toVector query: [Float], k: Int = 10, excludeIds: Set<UUID> = []) async throws -> [(itemId: UUID, similarity: Float)] {
        let allVectors = try await fetchAll()
        let candidates = allVectors.filter { !excludeIds.contains($0.0) }
        guard !candidates.isEmpty else { return [] }

        // Compute similarities using SIMD
        var similarities: [(UUID, Float)] = []
        for (id, vec) in candidates {
            var dot: Float = 0
            vDSP_dotpr(query, 1, vec, 1, &dot, vDSP_Length(min(query.count, vec.count)))
            similarities.append((id, dot))
        }

        return similarities
            .sorted { $0.1 > $1.1 }
            .prefix(k)
            .map { (itemId: $0.0, similarity: $0.1) }
    }
}
