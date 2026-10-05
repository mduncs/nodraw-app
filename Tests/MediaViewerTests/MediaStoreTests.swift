import XCTest
import GRDB
@testable import MediaViewer

/// Tests for MediaStore operations - the data access layer for MediaItems.
/// These tests validate the SQL queries and business logic by directly
/// testing against a temporary database since MediaStore uses shared DatabaseManager.
final class MediaStoreTests: XCTestCase {

    private var testPool: DatabasePool!
    private var tempDir: URL!

    override func setUpWithError() throws {
        // Create temp directory
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create test database
        let dbPath = tempDir.appendingPathComponent("test.sqlite")
        testPool = try DatabasePool(path: dbPath.path)

        // Run migrations - simulating what DatabaseManager does
        try testPool.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try MediaItemRecord.createTable(in: db)
            try SmartFolder.createTable(in: db)

            // Junction tables (required by insertWithFTSSync)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS media_tags (
                    item_id TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    PRIMARY KEY (item_id, tag),
                    FOREIGN KEY (item_id) REFERENCES media_items(id) ON DELETE CASCADE
                )
            """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS media_colors (
                    item_id TEXT NOT NULL,
                    color_bucket TEXT NOT NULL,
                    PRIMARY KEY (item_id, color_bucket),
                    FOREIGN KEY (item_id) REFERENCES media_items(id) ON DELETE CASCADE
                )
            """)
        }
    }

    override func tearDownWithError() throws {
        testPool = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Fetch Tests

    func testFetchItemsEmpty() async throws {
        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(db)
        }
        XCTAssertTrue(items.isEmpty)
    }

    func testFetchItemsReturnsInserted() async throws {
        // Insert test items
        let item1 = createTestMediaItem(platform: "twitter")
        let item2 = createTestMediaItem(platform: "instagram")

        try await testPool.write { db in
            try MediaItemRecord(from: item1).insert(db)
            try MediaItemRecord(from: item2).insert(db)
        }

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(db)
        }
        XCTAssertEqual(items.count, 2)
    }

    func testFetchItemById() async throws {
        let item = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        let fetched = try await testPool.read { db in
            try MediaItemRecord.fetchOne(
                db,
                sql: "SELECT * FROM media_items WHERE id = ?",
                arguments: [item.id.uuidString]
            )
        }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, item.id)
        XCTAssertEqual(fetched?.platform, item.metadata.platform)
    }

    func testFetchItemByIdNotFound() async throws {
        let fetched = try await testPool.read { db in
            try MediaItemRecord.fetchOne(
                db,
                sql: "SELECT * FROM media_items WHERE id = ?",
                arguments: [UUID().uuidString]
            )
        }
        XCTAssertNil(fetched)
    }

    func testFetchItemByMetadataPath() async throws {
        let item = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        let fetched = try await testPool.read { db in
            try MediaItemRecord.fetchOne(
                db,
                sql: "SELECT * FROM media_items WHERE metadataFileString = ?",
                arguments: [item.metadataFile.path]
            )
        }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, item.id)
    }

    func testExistingMetadataFileStringsReturnsOnlyPersistedPaths() async throws {
        let dbURL = tempDir.appendingPathComponent("existing-paths.sqlite")
        let database = DatabaseManager(databaseURL: dbURL)
        try await database.initialize()
        let store = MediaStore(database: database)

        let item1 = createTestMediaItem()
        let item2 = createTestMediaItem()
        let missingPath = tempDir.appendingPathComponent("missing.md").path

        try await database.write { db in
            try MediaItemRecord(from: item1).insertWithFTSSync(db: db)
            try MediaItemRecord(from: item2).insertWithFTSSync(db: db)
        }

        let existing = try await store.existingMetadataFileStrings(for: [
            item1.metadataFile.path,
            missingPath,
            item2.metadataFile.path,
            item1.metadataFile.path,
        ])

        XCTAssertEqual(existing, [item1.metadataFile.path, item2.metadataFile.path])
    }

    // MARK: - Filter Tests

    func testFilterByPlatform() async throws {
        let item1 = createTestMediaItem(platform: "twitter")
        let item2 = createTestMediaItem(platform: "twitter")
        let item3 = createTestMediaItem(platform: "instagram")
        try await testPool.write { db in
            try MediaItemRecord(from: item1).insert(db)
            try MediaItemRecord(from: item2).insert(db)
            try MediaItemRecord(from: item3).insert(db)
        }

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items WHERE platform = ?",
                arguments: ["twitter"]
            )
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.platform == "twitter" })
    }

    func testFilterByStarred() async throws {
        var starredItemTemp = createTestMediaItem()
        starredItemTemp.metadata = MediaMetadata(
            source: starredItemTemp.metadata.source,
            platform: starredItemTemp.metadata.platform,
            starred: true
        )
        let starredItem = starredItemTemp

        var unstarredItemTemp = createTestMediaItem()
        unstarredItemTemp.metadata = MediaMetadata(
            source: unstarredItemTemp.metadata.source,
            platform: unstarredItemTemp.metadata.platform,
            starred: false
        )
        let unstarredItem = unstarredItemTemp

        try await testPool.write { db in
            try MediaItemRecord(from: starredItem).insert(db)
            try MediaItemRecord(from: unstarredItem).insert(db)
        }

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items WHERE starred = ?",
                arguments: [true]
            )
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, starredItem.id)
    }

    func testFilterByDateRange() async throws {
        let now = Date()
        let oldDate = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let recentCutoff = Calendar.current.date(byAdding: .day, value: -7, to: now)!

        let recentItem = createTestMediaItem()

        var oldItemTemp = createTestMediaItem()
        oldItemTemp.metadata = MediaMetadata(
            source: oldItemTemp.metadata.source,
            platform: oldItemTemp.metadata.platform,
            archivedDate: oldDate
        )
        let oldItem = oldItemTemp

        try await testPool.write { db in
            try MediaItemRecord(from: recentItem).insert(db)
            try MediaItemRecord(from: oldItem).insert(db)
        }

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items WHERE archivedDate > ?",
                arguments: [recentCutoff]
            )
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, recentItem.id)
    }

    func testFilterByAuthor() async throws {
        let item1 = createTestMediaItem(author: "@alice")
        let item2 = createTestMediaItem(author: "@bob")
        let item3 = createTestMediaItem(author: "@alice")
        try await testPool.write { db in
            try MediaItemRecord(from: item1).insert(db)
            try MediaItemRecord(from: item2).insert(db)
            try MediaItemRecord(from: item3).insert(db)
        }

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items WHERE author = ?",
                arguments: ["@alice"]
            )
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.author == "@alice" })
    }

    func testFilterByTags() async throws {
        let item1Base = createTestMediaItem()
        let item1 = MediaItem(
            id: item1Base.id,
            basePath: item1Base.basePath,
            metadataFile: item1Base.metadataFile,
            mediaFiles: item1Base.mediaFiles,
            metadata: MediaMetadata(
                source: item1Base.metadata.source,
                platform: item1Base.metadata.platform,
                tags: ["art", "photography"]
            )
        )

        let item2Base = createTestMediaItem()
        let item2 = MediaItem(
            id: item2Base.id,
            basePath: item2Base.basePath,
            metadataFile: item2Base.metadataFile,
            mediaFiles: item2Base.mediaFiles,
            metadata: MediaMetadata(
                source: item2Base.metadata.source,
                platform: item2Base.metadata.platform,
                tags: ["meme", "funny"]
            )
        )

        try await testPool.write { db in
            try MediaItemRecord(from: item1).insert(db)
            try MediaItemRecord(from: item2).insert(db)
        }

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items WHERE tagsJSON LIKE ?",
                arguments: ["%\"art\"%"]
            )
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, item1.id)
    }

    func testFilterCombination() async throws {
        let twitterStarredBase = createTestMediaItem(platform: "twitter")
        let twitterStarred = MediaItem(
            id: twitterStarredBase.id,
            basePath: twitterStarredBase.basePath,
            metadataFile: twitterStarredBase.metadataFile,
            mediaFiles: twitterStarredBase.mediaFiles,
            metadata: MediaMetadata(
                source: twitterStarredBase.metadata.source,
                platform: "twitter",
                starred: true
            )
        )

        let twitterUnstarredBase = createTestMediaItem(platform: "twitter")
        let twitterUnstarred = MediaItem(
            id: twitterUnstarredBase.id,
            basePath: twitterUnstarredBase.basePath,
            metadataFile: twitterUnstarredBase.metadataFile,
            mediaFiles: twitterUnstarredBase.mediaFiles,
            metadata: MediaMetadata(
                source: twitterUnstarredBase.metadata.source,
                platform: "twitter",
                starred: false
            )
        )

        let instaStarredBase = createTestMediaItem(platform: "instagram")
        let instaStarred = MediaItem(
            id: instaStarredBase.id,
            basePath: instaStarredBase.basePath,
            metadataFile: instaStarredBase.metadataFile,
            mediaFiles: instaStarredBase.mediaFiles,
            metadata: MediaMetadata(
                source: instaStarredBase.metadata.source,
                platform: "instagram",
                starred: true
            )
        )

        try await testPool.write { db in
            try MediaItemRecord(from: twitterStarred).insert(db)
            try MediaItemRecord(from: twitterUnstarred).insert(db)
            try MediaItemRecord(from: instaStarred).insert(db)
        }

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items WHERE platform = ? AND starred = ?",
                arguments: ["twitter", true]
            )
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, twitterStarred.id)
    }

    func testFilterWithLimit() async throws {
        for _ in 0..<10 {
            let item = createTestMediaItem(platform: "twitter")
            try await testPool.write { db in
                try MediaItemRecord(from: item).insert(db)
            }
        }

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items LIMIT 5"
            )
        }
        XCTAssertEqual(items.count, 5)
    }

    func testFilterWithOffset() async throws {
        for i in 0..<10 {
            let item = createTestMediaItem(platform: "platform_\(i)")
            try await testPool.write { db in
                try MediaItemRecord(from: item).insert(db)
            }
        }

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items ORDER BY platform LIMIT 5 OFFSET 5"
            )
        }
        XCTAssertEqual(items.count, 5)
    }

    func testSearchText() async throws {
        let item1Base = createTestMediaItem()
        let item1 = MediaItem(
            id: item1Base.id,
            basePath: item1Base.basePath,
            metadataFile: item1Base.metadataFile,
            mediaFiles: item1Base.mediaFiles,
            metadata: MediaMetadata(
                source: item1Base.metadata.source,
                platform: item1Base.metadata.platform,
                author: "findme"
            )
        )

        let item2Base = createTestMediaItem()
        let item2 = MediaItem(
            id: item2Base.id,
            basePath: item2Base.basePath,
            metadataFile: item2Base.metadataFile,
            mediaFiles: item2Base.mediaFiles,
            metadata: MediaMetadata(
                source: item2Base.metadata.source,
                platform: item2Base.metadata.platform,
                author: "other"
            )
        )

        try await testPool.write { db in
            try MediaItemRecord(from: item1).insert(db)
            try MediaItemRecord(from: item2).insert(db)
        }

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items WHERE author LIKE ?",
                arguments: ["%findme%"]
            )
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.author, "findme")
    }

    // MARK: - Insert/Update/Delete Tests

    func testInsertItem() async throws {
        let item = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        let fetched = try await testPool.read { db in
            try MediaItemRecord.fetchOne(
                db,
                sql: "SELECT * FROM media_items WHERE id = ?",
                arguments: [item.id.uuidString]
            )
        }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.platform, item.metadata.platform)
    }

    func testUpdateItem() async throws {
        let originalItem = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: originalItem).insert(db)
        }

        // Update
        let updatedItem = MediaItem(
            id: originalItem.id,
            basePath: originalItem.basePath,
            metadataFile: originalItem.metadataFile,
            mediaFiles: originalItem.mediaFiles,
            metadata: MediaMetadata(
                source: originalItem.metadata.source,
                platform: originalItem.metadata.platform,
                author: originalItem.metadata.author,
                originalDate: originalItem.metadata.originalDate,
                archivedDate: originalItem.metadata.archivedDate,
                starred: true,
                tags: ["updated"],
                notes: "Updated notes"
            )
        )

        try await testPool.write { db in
            try MediaItemRecord(from: updatedItem).update(db)
        }

        let fetched = try await testPool.read { db in
            try MediaItemRecord.fetchOne(
                db,
                sql: "SELECT * FROM media_items WHERE id = ?",
                arguments: [originalItem.id.uuidString]
            )
        }
        XCTAssertEqual(fetched?.starred, true)
        XCTAssertEqual(fetched?.notes, "Updated notes")
    }

    func testDeleteItem() async throws {
        let item = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        // Verify exists
        var count = try await testPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE id = ?", arguments: [item.id.uuidString])
        }
        XCTAssertEqual(count, 1)

        // Delete
        try await testPool.write { db in
            try db.execute(sql: "DELETE FROM media_items WHERE id = ?", arguments: [item.id.uuidString])
        }

        // Verify gone
        count = try await testPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE id = ?", arguments: [item.id.uuidString])
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Star/Tag Operations

    func testToggleStar() async throws {
        let itemBase = createTestMediaItem()
        let item = MediaItem(
            id: itemBase.id,
            basePath: itemBase.basePath,
            metadataFile: itemBase.metadataFile,
            mediaFiles: itemBase.mediaFiles,
            metadata: MediaMetadata(
                source: itemBase.metadata.source,
                platform: itemBase.metadata.platform,
                starred: false
            )
        )
        let itemID = item.id.uuidString
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        // Toggle to true
        try await testPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET starred = NOT starred WHERE id = ?",
                arguments: [itemID]
            )
        }

        var isStarred = try await testPool.read { db in
            try Bool.fetchOne(db, sql: "SELECT starred FROM media_items WHERE id = ?", arguments: [itemID])
        }
        XCTAssertTrue(isStarred ?? false)

        // Toggle back to false
        try await testPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET starred = NOT starred WHERE id = ?",
                arguments: [itemID]
            )
        }

        isStarred = try await testPool.read { db in
            try Bool.fetchOne(db, sql: "SELECT starred FROM media_items WHERE id = ?", arguments: [itemID])
        }
        XCTAssertFalse(isStarred ?? true)
    }

    func testAddTag() async throws {
        let itemBase = createTestMediaItem()
        let item = MediaItem(
            id: itemBase.id,
            basePath: itemBase.basePath,
            metadataFile: itemBase.metadataFile,
            mediaFiles: itemBase.mediaFiles,
            metadata: MediaMetadata(
                source: itemBase.metadata.source,
                platform: itemBase.metadata.platform,
                tags: []
            )
        )
        let itemID = item.id.uuidString
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        // Add tag
        try await testPool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                arguments: [itemID]
            ) else { return }

            let json: String = row["tagsJSON"]
            var tags = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
            tags.append("newtag")
            let newJSON = (try? JSONEncoder().encode(tags))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            try db.execute(
                sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                arguments: [newJSON, itemID]
            )
        }

        let tagsJSON = try await testPool.read { db in
            try String.fetchOne(db, sql: "SELECT tagsJSON FROM media_items WHERE id = ?", arguments: [itemID])
        }
        XCTAssertTrue(tagsJSON?.contains("newtag") ?? false)
    }

    func testRemoveTag() async throws {
        let itemBase = createTestMediaItem()
        let item = MediaItem(
            id: itemBase.id,
            basePath: itemBase.basePath,
            metadataFile: itemBase.metadataFile,
            mediaFiles: itemBase.mediaFiles,
            metadata: MediaMetadata(
                source: itemBase.metadata.source,
                platform: itemBase.metadata.platform,
                tags: ["tag1", "tag2", "tag3"]
            )
        )
        let itemID = item.id.uuidString
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        // Remove tag2
        try await testPool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                arguments: [itemID]
            ) else { return }

            let json: String = row["tagsJSON"]
            var tags = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
            tags.removeAll { $0 == "tag2" }
            let newJSON = (try? JSONEncoder().encode(tags))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            try db.execute(
                sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                arguments: [newJSON, itemID]
            )
        }

        let tagsJSON = try await testPool.read { db in
            try String.fetchOne(db, sql: "SELECT tagsJSON FROM media_items WHERE id = ?", arguments: [itemID])
        }
        let tags = try JSONDecoder().decode([String].self, from: Data(tagsJSON!.utf8))
        XCTAssertEqual(tags, ["tag1", "tag3"])
    }

    // MARK: - Soft Delete Tests

    func testSoftDelete() async throws {
        let item1 = createTestMediaItem()
        let item2 = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: item1).insert(db)
            try MediaItemRecord(from: item2).insert(db)
        }

        // Soft delete item1
        try await testPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET deletedAt = ? WHERE id = ?",
                arguments: [Date(), item1.id.uuidString]
            )
        }

        // Check that item1 has deletedAt set
        let count = try await testPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE deletedAt IS NOT NULL")
        }
        XCTAssertEqual(count, 1)
    }

    func testRestoreDeleted() async throws {
        let item = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
            try db.execute(
                sql: "UPDATE media_items SET deletedAt = ? WHERE id = ?",
                arguments: [Date(), item.id.uuidString]
            )
        }

        // Verify deleted
        var deletedCount = try await testPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE deletedAt IS NOT NULL")
        }
        XCTAssertEqual(deletedCount, 1)

        // Restore
        try await testPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET deletedAt = NULL WHERE id = ?",
                arguments: [item.id.uuidString]
            )
        }

        // Verify restored
        deletedCount = try await testPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE deletedAt IS NOT NULL")
        }
        XCTAssertEqual(deletedCount, 0)
    }

    // MARK: - Fetch Platforms/Tags Tests

    func testFetchPlatforms() async throws {
        let item1 = createTestMediaItem(platform: "twitter")
        let item2 = createTestMediaItem(platform: "instagram")
        let item3 = createTestMediaItem(platform: "twitter")
        let item4 = createTestMediaItem(platform: "reddit")
        try await testPool.write { db in
            try MediaItemRecord(from: item1).insert(db)
            try MediaItemRecord(from: item2).insert(db)
            try MediaItemRecord(from: item3).insert(db)
            try MediaItemRecord(from: item4).insert(db)
        }

        let platforms = try await testPool.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT platform FROM media_items ORDER BY platform")
        }
        XCTAssertEqual(platforms, ["instagram", "reddit", "twitter"])
    }

    func testFetchAllTags() async throws {
        let item1Base = createTestMediaItem()
        let item1 = MediaItem(
            id: item1Base.id,
            basePath: item1Base.basePath,
            metadataFile: item1Base.metadataFile,
            mediaFiles: item1Base.mediaFiles,
            metadata: MediaMetadata(
                source: item1Base.metadata.source,
                platform: item1Base.metadata.platform,
                tags: ["art", "photo"]
            )
        )

        let item2Base = createTestMediaItem()
        let item2 = MediaItem(
            id: item2Base.id,
            basePath: item2Base.basePath,
            metadataFile: item2Base.metadataFile,
            mediaFiles: item2Base.mediaFiles,
            metadata: MediaMetadata(
                source: item2Base.metadata.source,
                platform: item2Base.metadata.platform,
                tags: ["meme", "art"]
            )
        )

        try await testPool.write { db in
            try MediaItemRecord(from: item1).insert(db)
            try MediaItemRecord(from: item2).insert(db)
        }

        let allTags = try await testPool.read { db -> Set<String> in
            let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT tagsJSON FROM media_items")
            var tags = Set<String>()

            for row in rows {
                let json: String = row["tagsJSON"]
                if let tagArray = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) {
                    tags.formUnion(tagArray)
                }
            }

            return tags
        }

        XCTAssertEqual(allTags, Set(["art", "photo", "meme"]))
    }

    // MARK: - Count Tests

    func testCountItems() async throws {
        for _ in 0..<5 {
            let item = createTestMediaItem(platform: "twitter")
            try await testPool.write { db in
                try MediaItemRecord(from: item).insert(db)
            }
        }
        for _ in 0..<3 {
            let item = createTestMediaItem(platform: "instagram")
            try await testPool.write { db in
                try MediaItemRecord(from: item).insert(db)
            }
        }

        let totalCount = try await testPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items")
        }
        XCTAssertEqual(totalCount, 8)

        let twitterCount = try await testPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE platform = ?", arguments: ["twitter"])
        }
        XCTAssertEqual(twitterCount, 5)
    }

    // MARK: - Smart Folder Query Tests

    func testSmartFolderQueryPlatform() async throws {
        let item1 = createTestMediaItem(platform: "twitter")
        let item2 = createTestMediaItem(platform: "instagram")
        try await testPool.write { db in
            try MediaItemRecord(from: item1).insert(db)
            try MediaItemRecord(from: item2).insert(db)
        }

        // Test the SQL fragment from PlatformFilter
        let filter = PlatformFilter.equals("twitter")
        let (sql, args) = filter.sqlFragment(column: "platform")

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items WHERE \(sql)",
                arguments: StatementArguments(args)
            )
        }

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.platform, "twitter")
    }

    func testSmartFolderQueryDateRange() async throws {
        let now = Date()
        let oldDate = Calendar.current.date(byAdding: .day, value: -30, to: now)!

        var oldItemTemp = createTestMediaItem()
        oldItemTemp.metadata = MediaMetadata(
            source: oldItemTemp.metadata.source,
            platform: oldItemTemp.metadata.platform,
            archivedDate: oldDate
        )
        let oldItem = oldItemTemp

        let recentItem = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: recentItem).insert(db) // Recent
            try MediaItemRecord(from: oldItem).insert(db) // Old
        }

        // Test the SQL fragment from DateRangeFilter
        let filter = DateRangeFilter(field: .archived, range: .lastNDays(7))
        let (sql, args) = filter.sqlFragment()

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items WHERE \(sql)",
                arguments: StatementArguments(args)
            )
        }

        XCTAssertEqual(items.count, 1)
    }

    func testSmartFolderQueryStarred() async throws {
        let starredBase = createTestMediaItem()
        let starred = MediaItem(
            id: starredBase.id,
            basePath: starredBase.basePath,
            metadataFile: starredBase.metadataFile,
            mediaFiles: starredBase.mediaFiles,
            metadata: MediaMetadata(
                source: starredBase.metadata.source,
                platform: starredBase.metadata.platform,
                starred: true
            )
        )

        let unstarred = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: starred).insert(db)
            try MediaItemRecord(from: unstarred).insert(db) // Not starred
        }

        let rule = FilterRule.starred(true)
        let (sql, args) = rule.sqlFragment()

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items WHERE \(sql)",
                arguments: StatementArguments(args)
            )
        }

        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.first?.starred ?? false)
    }

    func testSmartFolderQueryHasTag() async throws {
        let withTagBase = createTestMediaItem()
        let withTag = MediaItem(
            id: withTagBase.id,
            basePath: withTagBase.basePath,
            metadataFile: withTagBase.metadataFile,
            mediaFiles: withTagBase.mediaFiles,
            metadata: MediaMetadata(
                source: withTagBase.metadata.source,
                platform: withTagBase.metadata.platform,
                tags: ["important"]
            )
        )

        let withoutTag = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: withTag).insert(db)
            try MediaItemRecord(from: withoutTag).insert(db)
        }

        let rule = FilterRule.hasTag("important")
        let (sql, args) = rule.sqlFragment()

        let items = try await testPool.read { db in
            try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items WHERE \(sql)",
                arguments: StatementArguments(args)
            )
        }

        XCTAssertEqual(items.count, 1)
    }

    // MARK: - FTS Sync Tests

    func testFTSSyncOnInsert() async throws {
        let item = createTestMediaItem()

        // Get initial FTS count
        let initialCount = try await testPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items_fts")
        } ?? 0

        try await testPool.write { db in
            let record = MediaItemRecord(from: item)
            try record.insertWithFTSSync(db: db)
        }

        // Verify FTS entry was added (count increased by 1)
        // Note: Contentless FTS5 with UNINDEXED id doesn't support WHERE id = ?
        let newCount = try await testPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items_fts")
        }
        XCTAssertEqual(newCount, initialCount + 1)
    }

    func testFTSSyncOnDelete() async throws {
        let item = createTestMediaItem()

        try await testPool.write { db in
            let record = MediaItemRecord(from: item)
            try record.insertWithFTSSync(db: db)
        }

        // Delete from main table only (FTS cleanup is limited for contentless tables)
        try await testPool.write { db in
            try db.execute(sql: "DELETE FROM media_items WHERE id = ?", arguments: [item.id.uuidString])
        }

        // Verify main table entry is gone
        let mainCount = try await testPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE id = ?", arguments: [item.id.uuidString])
        }
        XCTAssertEqual(mainCount, 0)

        // Note: Contentless FTS5 doesn't support DELETE WHERE id = ? for UNINDEXED columns
        // FTS entry may remain as orphan until rebuildFTSIndex is called
    }

    // MARK: - Helpers

    private func createTestMediaItem(platform: String = "twitter", author: String? = nil) -> MediaItem {
        let id = UUID()
        let basePath = URL(fileURLWithPath: "/test/archive/2025-01")
        let metadataFile = basePath.appendingPathComponent("\(id.uuidString).md")

        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: metadataFile,
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString).jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://\(platform).com/test/\(id.uuidString)")!,
                platform: platform,
                author: author ?? "@testuser",
                originalDate: Date(),
                archivedDate: Date()
            )
        )
    }
}
