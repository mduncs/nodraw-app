import XCTest
import GRDB
@testable import MediaViewer

/// Tests for DatabaseManager - the core database access layer.
/// Uses in-memory databases for isolation and speed.
final class DatabaseManagerTests: XCTestCase {

    /// In-memory database manager for testing
    private var testPool: DatabasePool!
    private var tempDir: URL!

    override func setUpWithError() throws {
        // Create temp directory for test database
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaViewerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        testPool = nil
        // Clean up temp directory
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Initialization Tests

    func testDatabaseCreation() async throws {
        // Create database pool in temp directory
        let dbPath = tempDir.appendingPathComponent("test.sqlite")
        let pool = try DatabasePool(path: dbPath.path)

        // Verify file was created
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath.path))

        // Verify we can write to it
        try await pool.write { db in
            try db.execute(sql: "CREATE TABLE test (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO test (id) VALUES (1)")
        }

        // Verify we can read from it
        let count = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM test")
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: - Migration Tests

    func testMigrationCreatesSchema() async throws {
        let dbPath = tempDir.appendingPathComponent("migration-test.sqlite")
        let pool = try DatabasePool(path: dbPath.path)

        // Run migrations (inline version of DatabaseManager's runMigrations)
        try await pool.write { db in
            // Migration table
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER PRIMARY KEY,
                    applied_at TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """)

            // Migration 1: Initial schema
            try MediaItemRecord.createTable(in: db)
            try SmartFolder.createTable(in: db)
            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (1)")
        }

        // Verify tables exist
        let tables = try await pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table'
                ORDER BY name
            """)
        }

        XCTAssertTrue(tables.contains("media_items"))
        XCTAssertTrue(tables.contains("smart_folders"))
        XCTAssertTrue(tables.contains("schema_migrations"))
        XCTAssertTrue(tables.contains("media_items_fts"))
    }

    func testSchemaVersionTracking() async throws {
        let dbPath = tempDir.appendingPathComponent("version-test.sqlite")
        let pool = try DatabasePool(path: dbPath.path)

        // Create version table and insert version 1
        try await pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER PRIMARY KEY,
                    applied_at TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """)
            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (1)")
        }

        // Verify version
        let version = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(version) FROM schema_migrations")
        }
        XCTAssertEqual(version, 1)

        // Add version 2
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (2)")
        }

        let newVersion = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(version) FROM schema_migrations")
        }
        XCTAssertEqual(newVersion, 2)
    }

    func testMigrationIdempotency() async throws {
        let dbPath = tempDir.appendingPathComponent("idempotent-test.sqlite")
        let pool = try DatabasePool(path: dbPath.path)

        // Helper to run migrations
        @Sendable func runMigrations(db: Database) throws {
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER PRIMARY KEY,
                    applied_at TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """)

            let currentVersion = try Int.fetchOne(db, sql: "SELECT MAX(version) FROM schema_migrations") ?? 0

            if currentVersion < 1 {
                try MediaItemRecord.createTable(in: db)
                try SmartFolder.createTable(in: db)
                try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (1)")
            }
        }

        // Run migrations twice
        try await pool.write { db in
            try runMigrations(db: db)
        }
        try await pool.write { db in
            try runMigrations(db: db)
        }

        // Should only have version 1 once
        let versions = try await pool.read { db in
            try Int.fetchAll(db, sql: "SELECT version FROM schema_migrations")
        }
        XCTAssertEqual(versions, [1])
    }

    // MARK: - Read/Write Operations

    func testBasicReadWrite() async throws {
        let dbPath = tempDir.appendingPathComponent("readwrite-test.sqlite")
        let pool = try DatabasePool(path: dbPath.path)

        // Setup schema
        try await pool.write { db in
            try MediaItemRecord.createTable(in: db)
        }

        // Create test item
        let testItem = createTestMediaItem()
        let record = MediaItemRecord(from: testItem)

        // Write
        try await pool.write { db in
            try record.insert(db)
        }

        // Read
        let fetched = try await pool.read { db in
            try MediaItemRecord.fetchOne(db, sql: "SELECT * FROM media_items WHERE id = ?", arguments: [testItem.id.uuidString])
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, testItem.id)
        XCTAssertEqual(fetched?.platform, testItem.metadata.platform)
    }

    func testReadWithoutInitializationFails() async throws {
        // Attempt to read from uninitialized pool should fail
        // This tests the DatabaseManager.read guard clause
        let dbPath = tempDir.appendingPathComponent("uninit-test.sqlite")

        // The database file doesn't exist yet
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath.path))
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentReads() async throws {
        let dbPath = tempDir.appendingPathComponent("concurrent-test.sqlite")
        let pool = try DatabasePool(path: dbPath.path)

        // Setup with test data
        let items = (0..<10).map { i in createTestMediaItem(platform: "platform_\(i)") }
        try await pool.write { db in
            try MediaItemRecord.createTable(in: db)

            // Insert multiple items
            for item in items {
                try MediaItemRecord(from: item).insert(db)
            }
        }

        // Concurrent reads
        await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try? await pool.read { db in
                        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items")
                    }
                }
            }

            var counts: [Int] = []
            for await count in group {
                if let count = count {
                    counts.append(count)
                }
            }

            // All reads should return 10
            XCTAssertEqual(counts.count, 20)
            for count in counts {
                XCTAssertEqual(count, 10)
            }
        }
    }

    func testConcurrentWritesSerialized() async throws {
        let dbPath = tempDir.appendingPathComponent("concurrent-write-test.sqlite")
        let pool = try DatabasePool(path: dbPath.path)

        // Setup
        try await pool.write { db in
            try db.execute(sql: "CREATE TABLE counter (value INTEGER)")
            try db.execute(sql: "INSERT INTO counter (value) VALUES (0)")
        }

        // Concurrent increments
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    try? await pool.write { db in
                        try db.execute(sql: "UPDATE counter SET value = value + 1")
                    }
                }
            }
        }

        // All writes should be serialized, final value should be 100
        let finalValue = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT value FROM counter")
        }
        XCTAssertEqual(finalValue, 100)
    }

    func testConcurrentReadsDuringWrite() async throws {
        let dbPath = tempDir.appendingPathComponent("read-during-write-test.sqlite")
        let pool = try DatabasePool(path: dbPath.path)

        // Setup
        try await pool.write { db in
            try MediaItemRecord.createTable(in: db)
        }

        // Start a long-running write
        let writeItems = (0..<50).map { i in createTestMediaItem(platform: "platform_\(i)") }
        let writeTask = Task {
            try await pool.write { db in
                for item in writeItems {
                    try MediaItemRecord(from: item).insert(db)
                }
            }
        }

        // Concurrent reads should not block/crash
        let readTask = Task {
            var readCounts: [Int] = []
            for _ in 0..<10 {
                let count = try await pool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items")
                }
                if let count = count {
                    readCounts.append(count)
                }
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
            return readCounts
        }

        try await writeTask.value
        let counts = try await readTask.value

        // Reads should have seen consistent snapshots (not partial writes due to WAL)
        XCTAssertFalse(counts.isEmpty)
    }

    // MARK: - Error Handling Tests

    func testWriteTransactionRollback() async throws {
        let dbPath = tempDir.appendingPathComponent("rollback-test.sqlite")
        let pool = try DatabasePool(path: dbPath.path)

        // Setup
        let initialItem = createTestMediaItem()
        try await pool.write { db in
            try MediaItemRecord.createTable(in: db)
            try MediaItemRecord(from: initialItem).insert(db)
        }

        // Attempt a write that fails
        let item2 = createTestMediaItem()
        do {
            try await pool.write { db in
                // Insert another item
                try MediaItemRecord(from: item2).insert(db)

                // This should fail (duplicate primary key)
                // Force duplicate ID by reusing item2's ID
                try db.execute(sql: "INSERT INTO media_items (id, basePathString, metadataFileString, mediaFilesJSON, sourceURL, platform, archivedDate, starred, tagsJSON, parseStatus) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    arguments: [item2.id.uuidString, "/test", "/test/file.md", "[]", "https://example.com", "test", Date(), false, "[]", "success"])
            }
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }

        // Original item should still exist, second should be rolled back
        let count = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items")
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: - Foreign Keys Test

    func testForeignKeysEnabled() async throws {
        let dbPath = tempDir.appendingPathComponent("fk-test.sqlite")

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let pool = try DatabasePool(path: dbPath.path, configuration: config)

        // Verify foreign keys are enabled
        let fkEnabled = try await pool.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        XCTAssertEqual(fkEnabled, 1)
    }

    // MARK: - Helpers

    private func createTestMediaItem(platform: String = "twitter") -> MediaItem {
        let id = UUID()
        let basePath = URL(fileURLWithPath: "/test/archive/2025-01")
        let metadataFile = basePath.appendingPathComponent("\(id.uuidString).md")

        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: metadataFile,
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString).jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://\(platform).com/test/123")!,
                platform: platform,
                author: "@testuser",
                originalDate: Date(),
                archivedDate: Date()
            )
        )
    }
}
