import XCTest
import GRDB
@testable import MediaViewer

final class DatabaseQueryPerformanceTests: XCTestCase {
    private var tempDirectory: URL!
    private var database: DatabaseManager!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseQueryPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: tempDirectory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
    }

    override func tearDown() async throws {
        database = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try await super.tearDown()
    }

    func testDefaultLibraryPageUsesOrderedPartialIndexWithoutTemporarySort() async throws {
        let plan = try await database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT *
                    FROM media_items
                    WHERE COALESCE(deletedAt, '') = ''
                      AND (
                        mediaFilesJSON != '[]'
                        OR (contextImageString IS NOT NULL AND contextImageString != '')
                      )
                    ORDER BY archivedDate DESC, id ASC
                    LIMIT 240
                """,
                adapter: ColumnMapping(["detail": "detail"])
            )
        }

        XCTAssertTrue(
            plan.contains { $0.contains("idx_media_items_active_displayable_archivedDate") },
            "Expected the default library page to use its ordered partial index; plan: \(plan)"
        )
        XCTAssertFalse(
            plan.contains { $0.contains("USE TEMP B-TREE FOR ORDER BY") },
            "Default library paging must not materialize a temporary sort tree; plan: \(plan)"
        )
    }

    func testMigration38IsRecordedAndIdempotent() async throws {
        let initialCount = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_migrations WHERE version = 38") ?? 0
        }
        XCTAssertEqual(initialCount, 1)

        try await database.initialize()

        let finalCount = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_migrations WHERE version = 38") ?? 0
        }
        XCTAssertEqual(finalCount, 1)
    }

    func testOptimizedActivePredicatePreservesNullAndLegacyEmptyStringSemantics() async throws {
        try await database.write { db in
            for (index, deletedAt) in ([nil, "", "2026-09-04 12:00:00"] as [String?]).enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO media_items (
                            id, basePathString, metadataFileString, mediaFilesJSON,
                            sourceURL, platform, archivedDate, starred, tagsJSON,
                            deletedAt, parseStatus
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, '[]', ?, 'success')
                    """,
                    arguments: [
                        UUID().uuidString,
                        "/tmp/item-\(index)",
                        "/tmp/item-\(index).md",
                        "[\"/tmp/item-\(index).jpg\"]",
                        "https://example.com/\(index)",
                        "test",
                        Date(timeIntervalSince1970: Double(index)),
                        deletedAt
                    ]
                )
            }
        }

        let counts = try await database.read { db -> (legacy: Int, optimized: Int) in
            let legacy = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_items WHERE deletedAt IS NULL OR deletedAt = ''"
            ) ?? 0
            let optimized = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_items WHERE COALESCE(deletedAt, '') = ''"
            ) ?? 0
            return (legacy, optimized)
        }

        XCTAssertEqual(counts.legacy, 2)
        XCTAssertEqual(counts.optimized, counts.legacy)
    }

    func testBatchAttributeFetchGroupsAndDeduplicatesItemIDs() async throws {
        let firstID = UUID()
        let secondID = UUID()
        try await database.write { db in
            for (index, id) in [firstID, secondID].enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO media_items (
                            id, basePathString, metadataFileString, mediaFilesJSON,
                            sourceURL, platform, archivedDate, starred, tagsJSON, parseStatus
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, '[]', 'success')
                    """,
                    arguments: [
                        id.uuidString,
                        "/tmp/attribute-item-\(index)",
                        "/tmp/attribute-item-\(index).md",
                        "[\"/tmp/attribute-item-\(index).jpg\"]",
                        "https://example.com/attribute/\(index)",
                        "test",
                        Date(timeIntervalSince1970: Double(index))
                    ]
                )
            }

            try MediaAttribute(
                itemId: firstID,
                module: .scene,
                key: "outdoor",
                value: 0.9
            ).insert(db)
            try MediaAttribute(
                itemId: firstID,
                module: .object,
                key: "tree",
                value: 0.8
            ).insert(db)
            try MediaAttribute(
                itemId: secondID,
                module: .scene,
                key: "indoor",
                value: 0.7
            ).insert(db)
        }

        let store = MediaStore(database: database)
        let grouped = try await store.fetchAttributes(itemIds: [secondID, firstID, firstID])

        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[firstID]?.map(\.key), ["tree", "outdoor"])
        XCTAssertEqual(grouped[secondID]?.map(\.key), ["indoor"])
    }
}
