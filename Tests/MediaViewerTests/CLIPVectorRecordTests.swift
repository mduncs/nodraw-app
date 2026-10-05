import XCTest
import GRDB
import Accelerate
@testable import MediaViewer

/// Tests for CLIP vector storage and Float16 quantization.
final class CLIPVectorRecordTests: XCTestCase {

    private var tempDir: URL!
    private var pool: DatabasePool!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaViewerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbPath = tempDir.appendingPathComponent("test.sqlite")
        pool = try DatabasePool(path: dbPath.path)

        try pool.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try MediaItemRecord.createTable(in: db)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS clip_vectors (
                    itemId TEXT PRIMARY KEY REFERENCES media_items(id) ON DELETE CASCADE,
                    vectorData BLOB NOT NULL,
                    version INTEGER NOT NULL DEFAULT 1,
                    extractedAt DATETIME NOT NULL
                )
            """)
        }
    }

    override func tearDownWithError() throws {
        pool = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Schema Tests

    func testTableHasCorrectSchema() async throws {
        let columns = try await pool.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(clip_vectors)")
        }

        let columnNames = columns.compactMap { $0["name"] as? String }
        XCTAssertTrue(columnNames.contains("itemId"))
        XCTAssertTrue(columnNames.contains("vectorData"))
        XCTAssertTrue(columnNames.contains("version"))
        XCTAssertTrue(columnNames.contains("extractedAt"))
    }

    // MARK: - Float16 Round-Trip Tests

    func testFloat16RoundTripPreservesSimilarity() async throws {
        let vectorA = (0..<CLIPVectorRecord.dimension).map { _ in Float.random(in: -1...1) }
        let vectorB = vectorA.map { $0 + Float.random(in: -0.01...0.01) }

        let originalSimilarity = cosineSimilarity(vectorA, vectorB)

        let recordA = CLIPVectorRecord.create(from: vectorA, itemId: UUID())
        let recordB = CLIPVectorRecord.create(from: vectorB, itemId: UUID())

        let restoredA = recordA.asFloats()
        let restoredB = recordB.asFloats()

        let restoredSimilarity = cosineSimilarity(restoredA, restoredB)

        let tolerance: Float = 0.001
        XCTAssertEqual(originalSimilarity, restoredSimilarity, accuracy: tolerance,
                       "Similarity should be preserved after Float16 round-trip")
    }

    func testFloat16RoundTripForUnitVector() async throws {
        var vector = (0..<CLIPVectorRecord.dimension).map { _ in Float.random(in: -1...1) }
        normalize(&vector)

        let record = CLIPVectorRecord.create(from: vector, itemId: UUID())
        let restored = record.asFloats()

        var restoredNorm: Float = 0
        vDSP_svesq(restored, 1, &restoredNorm, vDSP_Length(restored.count))
        restoredNorm = sqrt(restoredNorm)

        XCTAssertEqual(restoredNorm, 1.0, accuracy: 0.01,
                       "Unit vector should remain unit length after Float16 round-trip")
    }

    func testFloat16DataSize() async throws {
        let vector = [Float](repeating: 0.5, count: CLIPVectorRecord.dimension)
        let record = CLIPVectorRecord.create(from: vector, itemId: UUID())

        // 768 floats * 2 bytes each = 1536 bytes
        XCTAssertEqual(record.vectorData.count, CLIPVectorRecord.dimension * 2)
    }

    func testDimensionIs768() {
        XCTAssertEqual(CLIPVectorRecord.dimension, 768)
    }

    // MARK: - Database CRUD Tests

    func testInsertAndFetch() async throws {
        let itemId = UUID()
        try await insertTestMediaItem(id: itemId)

        let vector = [Float](repeating: 0.5, count: CLIPVectorRecord.dimension)
        let record = CLIPVectorRecord.create(from: vector, itemId: itemId)

        try await pool.write { db in
            try record.insert(db)
        }

        let fetched = try await pool.read { db in
            try CLIPVectorRecord.fetchOne(db, key: itemId.uuidString)
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.itemId, itemId)
        XCTAssertEqual(fetched?.vectorData.count, CLIPVectorRecord.dimension * 2)
    }

    func testCascadeDeleteOnMediaItemDelete() async throws {
        let itemId = UUID()
        try await insertTestMediaItem(id: itemId)

        let vector = [Float](repeating: 0.5, count: CLIPVectorRecord.dimension)
        let record = CLIPVectorRecord.create(from: vector, itemId: itemId)
        try await pool.write { db in
            try record.insert(db)
        }

        let beforeDelete = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_vectors")
        }
        XCTAssertEqual(beforeDelete, 1)

        try await pool.write { db in
            try db.execute(sql: "DELETE FROM media_items WHERE id = ?", arguments: [itemId.uuidString])
        }

        let afterDelete = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_vectors")
        }
        XCTAssertEqual(afterDelete, 0)
    }

    // MARK: - Helpers

    private func insertTestMediaItem(id: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO media_items (id, basePathString, metadataFileString, mediaFilesJSON, sourceURL, platform, archivedDate, starred, tagsJSON, parseStatus)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [id.uuidString, "/test/archive/2025-01", "/test/archive/2025-01/\(id.uuidString).md", "[]", "https://twitter.com/test/123", "twitter", Date(), false, "[]", "success"]
            )
        }
    }

    private func normalize(_ vector: inout [Float]) {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 0 else { return }
        vDSP_vsdiv(vector, 1, &norm, &vector, 1, vDSP_Length(vector.count))
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        var dotProduct: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))

        var normA: Float = 0
        var normB: Float = 0
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))

        normA = sqrt(normA)
        normB = sqrt(normB)

        guard normA > 0 && normB > 0 else { return 0 }
        return dotProduct / (normA * normB)
    }
}
