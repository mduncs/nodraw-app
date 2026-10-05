import Foundation
import GRDB

// MARK: - Video Segment

struct VideoSegmentLabel: Codable, Hashable, Sendable {
    let label: String
    let confidence: Double
}

struct VideoSegment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let itemId: UUID
    let mediaFileIndex: Int
    let sourcePath: String
    let startTime: Double
    let endTime: Double
    let summary: String
    let labels: [VideoSegmentLabel]
    let confidence: Double
    let analysisSource: String
    let version: Int

    var timestampRange: String {
        "\(Self.formatTime(startTime))-\(Self.formatTime(endTime))"
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Database Record

struct VideoSegmentRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "video_segments"

    let id: UUID
    let itemId: UUID
    let assetID: UUID?
    let mediaFileIndex: Int
    let sourcePath: String
    let startTime: Double
    let endTime: Double
    let summary: String
    let labelsJSON: String
    let confidence: Double
    let analysisSource: String
    let version: Int
    let createdAt: String
    let updatedAt: String

    init(segment: VideoSegment, timestamp: String = ISO8601DateFormatter().string(from: Date()), assetID: UUID? = nil) {
        self.id = segment.id
        self.itemId = segment.itemId
        self.assetID = assetID
        self.mediaFileIndex = segment.mediaFileIndex
        self.sourcePath = segment.sourcePath
        self.startTime = segment.startTime
        self.endTime = segment.endTime
        self.summary = segment.summary
        self.labelsJSON = (try? JSONEncoder().encode(segment.labels))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        self.confidence = segment.confidence
        self.analysisSource = segment.analysisSource
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
                    debugDescription: "Invalid UUID in video_segments row"
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
        self.summary = row["summary"]
        self.labelsJSON = row["labels_json"]
        self.confidence = row["confidence"]
        self.analysisSource = row["analysis_source"]
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
        container["summary"] = summary
        container["labels_json"] = labelsJSON
        container["confidence"] = confidence
        container["analysis_source"] = analysisSource
        container["version"] = version
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }

    func toVideoSegment() -> VideoSegment {
        let labels = (try? JSONDecoder().decode([VideoSegmentLabel].self, from: Data(labelsJSON.utf8))) ?? []
        return VideoSegment(
            id: id,
            itemId: itemId,
            mediaFileIndex: mediaFileIndex,
            sourcePath: sourcePath,
            startTime: startTime,
            endTime: endTime,
            summary: summary,
            labels: labels,
            confidence: confidence,
            analysisSource: analysisSource,
            version: version
        )
    }

    func aroundInsert(_ db: Database, insert: () throws -> InsertionSuccess) throws {
        let asset = try ItemAssetStore.prepareWrite(in: db, itemID: itemId, assetID: assetID, path: sourcePath, index: mediaFileIndex)
        _ = try insert()
        try db.execute(sql: "UPDATE video_segments SET asset_id = ?, media_file_index = ?, source_path = ?, association_state = 'attached' WHERE id = ?", arguments: [asset.id.uuidString, asset.index, asset.path, id.uuidString])
    }
}

extension VideoSegmentRecord {
    static func createTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS video_segments (
                id               TEXT PRIMARY KEY,
                item_id          TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
                media_file_index INTEGER NOT NULL DEFAULT 0,
                source_path      TEXT NOT NULL,
                start_time       REAL NOT NULL,
                end_time         REAL NOT NULL,
                summary          TEXT NOT NULL,
                labels_json      TEXT NOT NULL DEFAULT '[]',
                confidence       REAL NOT NULL DEFAULT 0,
                analysis_source  TEXT NOT NULL DEFAULT 'native_vision',
                version          INTEGER NOT NULL DEFAULT 1,
                created_at       TEXT NOT NULL,
                updated_at       TEXT NOT NULL
            )
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_video_segments_item
            ON video_segments(item_id, media_file_index, start_time)
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_video_segments_source
            ON video_segments(analysis_source, version)
        """)
    }

    static func fetchAll(db: Database, itemId: UUID) throws -> [VideoSegment] {
        try VideoSegmentRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM video_segments
                WHERE item_id = ?
                  AND association_state = 'attached'
                ORDER BY media_file_index, start_time
            """,
            arguments: [itemId.uuidString]
        ).map { $0.toVideoSegment() }
    }
}
