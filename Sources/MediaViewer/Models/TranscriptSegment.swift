import Foundation
import GRDB

// MARK: - Transcript Segment

struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let itemId: UUID
    let mediaFileIndex: Int
    let sourcePath: String
    let startTime: Double
    let endTime: Double
    let text: String
    let confidence: Double
    let language: String?
    let model: String
    let version: Int

    var timestampRange: String {
        "\(VideoSegment.formatTime(startTime))-\(VideoSegment.formatTime(endTime))"
    }
}

// MARK: - Database Record

struct TranscriptSegmentRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcript_segments"

    let id: UUID
    let itemId: UUID
    let assetID: UUID?
    let mediaFileIndex: Int
    let sourcePath: String
    let startTime: Double
    let endTime: Double
    let text: String
    let confidence: Double
    let language: String?
    let model: String
    let version: Int
    let createdAt: String
    let updatedAt: String

    init(segment: TranscriptSegment, timestamp: String = ISO8601DateFormatter().string(from: Date()), assetID: UUID? = nil) {
        self.id = segment.id
        self.itemId = segment.itemId
        self.assetID = assetID
        self.mediaFileIndex = segment.mediaFileIndex
        self.sourcePath = segment.sourcePath
        self.startTime = segment.startTime
        self.endTime = segment.endTime
        self.text = segment.text
        self.confidence = segment.confidence
        self.language = segment.language
        self.model = segment.model
        self.version = segment.version
        self.createdAt = timestamp
        self.updatedAt = timestamp
    }

    init(row: Row) throws {
        guard let idString: String = row["id"],
              let id = UUID(uuidString: idString),
              let itemIdString: String = row["item_id"],
              let itemId = UUID(uuidString: itemIdString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid UUID in transcript_segments row"
                )
            )
        }

        self.id = id
        self.itemId = itemId
        self.assetID = (row["asset_id"] as String?).flatMap(UUID.init(uuidString:))
        self.mediaFileIndex = row["media_file_index"]
        self.sourcePath = row["source_path"]
        self.startTime = row["start_time"]
        self.endTime = row["end_time"]
        self.text = row["text"]
        self.confidence = row["confidence"]
        self.language = row["language"]
        self.model = row["model"]
        self.version = row["version"]
        self.createdAt = row["created_at"]
        self.updatedAt = row["updated_at"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["item_id"] = itemId.uuidString
        container["asset_id"] = assetID?.uuidString
        container["association_state"] = "attached"
        container["media_file_index"] = mediaFileIndex
        container["source_path"] = sourcePath
        container["start_time"] = startTime
        container["end_time"] = endTime
        container["text"] = text
        container["confidence"] = confidence
        container["language"] = language
        container["model"] = model
        container["version"] = version
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }

    func toTranscriptSegment() -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            itemId: itemId,
            mediaFileIndex: mediaFileIndex,
            sourcePath: sourcePath,
            startTime: startTime,
            endTime: endTime,
            text: text,
            confidence: confidence,
            language: language,
            model: model,
            version: version
        )
    }

    func aroundInsert(_ db: Database, insert: () throws -> InsertionSuccess) throws {
        let asset = try ItemAssetStore.prepareWrite(in: db, itemID: itemId, assetID: assetID, path: sourcePath, index: mediaFileIndex)
        _ = try insert()
        try db.execute(sql: "UPDATE transcript_segments SET asset_id = ?, media_file_index = ?, source_path = ?, association_state = 'attached' WHERE id = ?", arguments: [asset.id.uuidString, asset.index, asset.path, id.uuidString])
    }
}

extension TranscriptSegmentRecord {
    static func createTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS transcript_segments (
                id               TEXT PRIMARY KEY,
                item_id          TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
                media_file_index INTEGER NOT NULL DEFAULT 0,
                source_path      TEXT NOT NULL,
                start_time       REAL NOT NULL,
                end_time         REAL NOT NULL,
                text             TEXT NOT NULL,
                confidence       REAL NOT NULL DEFAULT 0,
                language         TEXT,
                model            TEXT NOT NULL DEFAULT 'parakeet',
                version          INTEGER NOT NULL DEFAULT 1,
                created_at       TEXT NOT NULL,
                updated_at       TEXT NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_transcript_segments_item
            ON transcript_segments(item_id, media_file_index, start_time)
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_transcript_segments_source
            ON transcript_segments(model, version)
        """)
    }

    static func fetchAll(db: Database, itemId: UUID) throws -> [TranscriptSegment] {
        try TranscriptSegmentRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM transcript_segments
                WHERE item_id = ?
                  AND association_state = 'attached'
                ORDER BY media_file_index, start_time
            """,
            arguments: [itemId.uuidString]
        ).map { $0.toTranscriptSegment() }
    }
}
