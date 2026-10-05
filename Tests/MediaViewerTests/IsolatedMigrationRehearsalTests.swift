import XCTest
import GRDB
import CryptoKit
@testable import MediaViewer

final class IsolatedMigrationRehearsalTests: XCTestCase {
    func testExplicitIsolatedFullLibraryMigrationAndIdempotentRestart() async throws {
        guard let path = ProcessInfo.processInfo.environment["NODRAW_MIGRATION_REHEARSAL_DB"] else {
            throw XCTSkip("Requires an explicitly remapped disposable migration-probe database")
        }
        guard path.contains("/migration-probe/"), path.hasSuffix("/media.sqlite") else {
            XCTFail("Refusing a database outside the explicitly isolated migration-probe directory")
            return
        }
        let url = URL(fileURLWithPath: path)
        let fixture = try DatabaseQueue(path: path)
        let before = try await fixture.read { db in try Self.contentSnapshot(db) }
        let manager = DatabaseManager(databaseURL: url)
        try await manager.initialize()
        let after = try await manager.read { db in try Self.contentSnapshot(db) }
        XCTAssertEqual(before, after, "Item UUIDs and all annotation/OCR/video/transcript content must survive")
        let assets = try await manager.read { db in try String.fetchAll(db, sql: "SELECT asset_id FROM item_assets ORDER BY asset_id") }
        let restarted = DatabaseManager(databaseURL: url)
        try await restarted.initialize()
        let again = try await restarted.read { db in try String.fetchAll(db, sql: "SELECT asset_id FROM item_assets ORDER BY asset_id") }
        XCTAssertEqual(assets, again)
        let checks = try await restarted.read { db -> [String] in
            let integrity = try String.fetchOne(db, sql: "PRAGMA quick_check") ?? "missing"
            let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
            var results = ["quick_check=\(integrity)", "foreign_key_errors=\(foreignKeys)", "assets=\(assets.count)"]
            for table in ["annotations", "media_file_ocr", "video_segments", "transcript_segments"] {
                let groups = try Row.fetchAll(db, sql: "SELECT association_state, COUNT(*) AS count FROM \(table) GROUP BY association_state")
                results += groups.map { "\(table).\($0["association_state"] as String)=\($0["count"] as Int)" }
            }
            return results
        }
        XCTAssertTrue(checks.contains("quick_check=ok"))
        XCTAssertTrue(checks.contains("foreign_key_errors=0"))
        print("MIGRATION_REHEARSAL \(checks.joined(separator: " "))")
        for key in before.keys.sorted() { print("MIGRATION_CONTENT \(key)=\(before[key]!)") }
    }

    private static func contentSnapshot(_ db: Database) throws -> [String: String] {
        let queries = [
            "items": "SELECT id FROM media_items ORDER BY id",
            "annotations": "SELECT json_object('id',id,'content',annotationsJSON) FROM annotations ORDER BY id",
            "ocr": "SELECT json_object('id',id,'text',ocr_text,'regions',ocr_regions_json) FROM media_file_ocr ORDER BY id",
            "video": "SELECT json_object('id',id,'start',start_time,'end',end_time,'summary',summary,'labels',labels_json,'confidence',confidence) FROM video_segments ORDER BY id",
            "transcript": "SELECT json_object('id',id,'start',start_time,'end',end_time,'text',text,'confidence',confidence,'language',language,'model',model) FROM transcript_segments ORDER BY id"
        ]
        var result: [String: String] = [:]
        for (name, sql) in queries {
            let rows = try String.fetchAll(db, sql: sql)
            let digest = SHA256.hash(data: Data(rows.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
            result[name] = "\(rows.count):\(digest)"
        }
        return result
    }
}
