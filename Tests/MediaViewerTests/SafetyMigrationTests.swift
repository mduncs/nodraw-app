import XCTest
import GRDB
@testable import MediaViewer

final class SafetyMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        let support = try XCTUnwrap(ProcessInfo.processInfo.environment["NODRAW_APP_SUPPORT_DIR"])
        directory = URL(fileURLWithPath: support).appendingPathComponent("safety-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testRegisteredMigrationRepairsFlagsAndPreservesPipelineState() async throws {
        let url = directory.appendingPathComponent("migration.sqlite")
        let original = DatabaseManager(databaseURL: url)
        try await original.initialize()
        let items = (0..<7).map(makeItem)
        try await original.write { db in
            for item in items { try MediaItemRecord(from: item).insert(db) }
            try db.execute(sql: "UPDATE media_items SET pipeline_status = 'complete', pipeline_version = 7, pipeline_retry_count = 2")
            try db.execute(sql: "DELETE FROM schema_migrations WHERE version = 45")
            let fixtures: [(Int, String, Double)] = [
                (0, "is_safe", 0), (0, "adult", 0.99), (0, "adult_cat", 0.8),
                (1, "adult_cat", 0.99),
                (2, "is_safe", 1), (2, "sword", 0.5), (2, "adult", 0.9),
                (3, "is_safe", 0), (3, "sword", 0.4999),
                (4, "sword", 0.8), (5, "is_safe", 0)
            ]
            for (index, key, value) in fixtures {
                try MediaAttribute(itemId: items[index].id, module: .safety, key: key, value: value, metadata: "preserve", version: 3).upsert(db: db)
            }
            try MediaAttribute(itemId: items[0].id, module: .scene, key: "adult", value: 0.99).upsert(db: db)
            try db.execute(sql: "INSERT INTO vision_pending_jobs(item_id) VALUES (?)", arguments: [items[6].id.uuidString])
        }
        let migrated = DatabaseManager(databaseURL: url)
        try await migrated.initialize()
        let flags = try await migrated.read { db in
            try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT item_id, value FROM media_attributes WHERE module = 'safety' AND key = 'is_safe'").map {
                ($0["item_id"] as String, $0["value"] as Double)
            })
        }
        XCTAssertEqual(flags.count, 6)
        for index in 0..<6 { XCTAssertEqual(flags[items[index].id.uuidString], [1.0, 1, 0, 1, 0, 1][index]) }
        let snapshot = try await migrated.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM media_attributes ORDER BY item_id, module, key")
        }
        try await migrated.read { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT DISTINCT key FROM media_attributes WHERE module = 'safety' ORDER BY key"), ["is_safe", "sword"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE pipeline_status = 'complete' AND pipeline_version = 7 AND pipeline_retry_count = 2"), 7)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vision_pending_jobs"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT MAX(version) FROM schema_migrations"), 45)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT version FROM media_attributes WHERE item_id = ? AND key = 'is_safe'", arguments: [items[0].id.uuidString]), 3)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT metadata FROM media_attributes WHERE item_id = ? AND key = 'is_safe'", arguments: [items[0].id.uuidString]), "preserve")
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT value FROM media_attributes WHERE module = 'scene' AND key = 'adult'"), 0.99)
        }
        let restarted = DatabaseManager(databaseURL: url)
        try await restarted.initialize()
        let afterRestart = try await restarted.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM media_attributes ORDER BY item_id, module, key")
        }
        XCTAssertEqual(snapshot, afterRestart)

        let store = MediaStore(database: restarted)
        var filter = FilterState.all
        filter.hideSafetyFlagged = true
        let visible = try await store.countItems(filter: filter)
        XCTAssertEqual(visible, 5, "Only the two actual sword flags should be hidden")
        let engine = TagRuleEngine(database: restarted)
        engine.rules = [TagRule(name: "Unsafe", sourceField: .safetyFlag, pattern: "unsafe", tagName: "sensitive")]
        for index in 0..<6 {
            let attributes = try await store.fetchAttributes(itemId: items[index].id)
            XCTAssertEqual(engine.evaluateRules(for: items[index].metadata, attributes: attributes), [2, 4].contains(index) ? ["sensitive"] : [])
        }
    }

    func testRepairIsIdempotent() async throws {
        let database = DatabaseManager(databaseURL: directory.appendingPathComponent("idempotent.sqlite"))
        try await database.initialize()
        let item = makeItem(0)
        try await database.write { db in
            try MediaItemRecord(from: item).insert(db)
            try MediaAttribute(itemId: item.id, module: .safety, key: "adult_cat", value: 1).upsert(db: db)
            try SafetyAttributes.repairLegacyFlags(in: db)
            let once = try Row.fetchAll(db, sql: "SELECT * FROM media_attributes")
            try SafetyAttributes.repairLegacyFlags(in: db)
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT * FROM media_attributes"), once)
            XCTAssertEqual(once.count, 1)
            XCTAssertEqual(once.first?["value"] as Double?, 1)
        }
    }

    @MainActor
    func testSidecarRefreshCannotRestoreBadSafetyFlagsOrRewriteSidecar() async throws {
        let database = DatabaseManager(databaseURL: directory.appendingPathComponent("sidecar.sqlite"))
        try await database.initialize()
        let item = makeItem(0)
        let content = "---\nsource: https://example.com/item\nplatform: test\nis_safe: false\nsafety:\n  adult: 0.99\n  adult_cat: 0.99\nml_attributes:\n  safety.is_safe: 0\n---\nBody\n"
        try content.write(to: item.metadataFile, atomically: true, encoding: .utf8)
        try await database.write { db in
            try MediaItemRecord(from: item).insert(db)
            try MediaAttribute(itemId: item.id, module: .safety, key: "adult", value: 0.99).upsert(db: db)
            try SafetyAttributes.repairLegacyFlags(in: db)
        }
        let store = MediaStore(database: database)
        try await store.updateItem(item, source: .sidecar)
        let attributes = try await store.fetchAttributes(itemId: item.id)
        XCTAssertEqual(attributes.map(\.key), ["is_safe"])
        XCTAssertEqual(attributes.first?.value, 1)
        XCTAssertEqual(try String(contentsOf: item.metadataFile, encoding: .utf8), content)
    }

    private func makeItem(_ index: Int) -> MediaItem {
        MediaItem(
            id: UUID(), basePath: directory,
            metadataFile: directory.appendingPathComponent("item-\(index).md"),
            mediaFiles: [directory.appendingPathComponent("item-\(index).jpg")],
            metadata: MediaMetadata(source: URL(string: "https://example.com/item/\(index)")!, platform: "test")
        )
    }
}
