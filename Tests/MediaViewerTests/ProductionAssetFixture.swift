import Foundation
import GRDB
@testable import MediaViewer

/// Record tests use the real migration chain and real member files, not an
/// annotation-only schema that cannot enforce persistent asset membership.
struct ProductionAssetFixture {
    let directory: URL
    let database: DatabaseManager
    let files: [URL]

    init() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("production-asset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixtureDirectory = directory
        files = (0..<3).map { fixtureDirectory.appendingPathComponent("\($0).mp4") }
        for file in files { try Data("record fixture".utf8).write(to: file) }
        database = DatabaseManager(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        try await database.initialize()
    }

    func insertItem(_ id: UUID, in db: Database) throws {
        let item = MediaItem(id: id, basePath: directory, metadataFile: directory.appendingPathComponent("\(id).md"), mediaFiles: files, metadata: MediaMetadata(source: URL(string: "https://example.com/\(id)")!, platform: "test"))
        try MediaItemRecord(from: item).insert(db)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    /// Reconstruct a real pre-P1/P3 schema before replaying older migrations.
    /// Deleting only migration-version rows leaves newer tables/triggers behind.
    static func removePost42Schema(in db: Database) throws {
        for table in ["duplicate_review_history", "duplicate_review_decisions", "duplicate_digest_cache"] {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
        try db.execute(sql: "DROP INDEX IF EXISTS idx_duplicate_groups_evidence_key")
        let duplicateColumns = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(duplicate_groups)").compactMap { $0["name"] as String? })
        for column in ["evidenceKey", "evidenceJSON", "isCurrent"] where duplicateColumns.contains(column) {
            try db.execute(sql: "ALTER TABLE duplicate_groups DROP COLUMN \(column)")
        }
    }

    static func removePost38Schema(in db: Database) throws {
        try removePost42Schema(in: db)
        for name in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND (name GLOB 'metadata_intent_*' OR name GLOB 'asset_*')") {
            try db.execute(sql: "DROP TRIGGER \(name)")
        }
        for table in ["annotations", "media_file_ocr", "video_segments", "transcript_segments"] {
            try db.execute(sql: "DROP INDEX idx_\(table)_asset")
            for column in ["asset_id", "association_state", "legacy_file_index"] { try db.execute(sql: "ALTER TABLE \(table) DROP COLUMN \(column)") }
        }
        for table in ["asset_association_resolutions", "item_assets", "vision_pending_jobs", "metadata_outbox", "metadata_projection_conflicts", "metadata_projection_clock", "metadata_projection_context"] {
            try db.execute(sql: "DROP TABLE \(table)")
        }
    }
}
