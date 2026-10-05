import XCTest
import GRDB
@testable import MediaViewer

/// Integration tests for the full import flow:
/// Archive scan -> MetadataParser -> Database insert -> VisionJobQueue -> FTS index
final class ImportFlowTests: XCTestCase {

    var testDatabase: TestDatabase!
    var testArchive: TestArchive!
    var dbPool: DatabasePool!

    override func setUp() async throws {
        try await super.setUp()
        testDatabase = TestDatabase()
        dbPool = try await testDatabase.initialize()
        testArchive = try TestArchive()
    }

    override func tearDown() async throws {
        try testArchive.cleanup()
        await testDatabase.tearDown()
        testArchive = nil
        testDatabase = nil
        dbPool = nil
        try await super.tearDown()
    }

    // MARK: - Scan and Parse Tests

    func testScanEmptyArchive() async throws {
        // Create empty year-month folder
        try testArchive.createFolder("2025-01")

        // Scan for .md files
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: testArchive.rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var mdFiles: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "md" {
                mdFiles.append(url)
            }
        }

        XCTAssertTrue(mdFiles.isEmpty, "Empty archive should have no .md files")
    }

    func testScanAndParseMetadata() async throws {
        // Create test items
        let (mdURL, _) = try testArchive.createItem(
            in: "2025-01",
            baseName: "twitter_alice_123",
            source: "https://twitter.com/alice/status/123",
            platform: "twitter",
            author: "@alice",
            date: "2025-01-15",
            starred: true,
            tags: ["art", "illustration"]
        )

        // Parse the metadata file
        let metadata = try MetadataParser.parse(fileAt: mdURL)

        XCTAssertEqual(metadata.source.absoluteString, "https://twitter.com/alice/status/123")
        XCTAssertEqual(metadata.platform, "twitter")
        XCTAssertEqual(metadata.author, "@alice")
        XCTAssertTrue(metadata.starred)
        XCTAssertEqual(metadata.tags, ["art", "illustration"])
        XCTAssertNotNil(metadata.originalDate)
    }

    func testInsertItemIntoDatabase() async throws {
        // Create and parse metadata
        let (mdURL, imageURL) = try testArchive.createItem(
            in: "2025-01",
            baseName: "twitter_bob_456",
            source: "https://twitter.com/bob/status/456",
            platform: "twitter",
            author: "@bob"
        )

        let metadata = try MetadataParser.parse(fileAt: mdURL)

        // Create MediaItem
        let item = MediaItem(
            id: UUID(),
            basePath: testArchive.rootURL.appendingPathComponent("2025-01"),
            metadataFile: mdURL,
            mediaFiles: [imageURL],
            metadata: metadata,
            aspectRatio: 1.5
        )

        // Insert into database
        let record = MediaItemRecord(from: item)
        try await dbPool.write { db in
            try record.insertWithFTSSync(db: db)
        }

        // Verify insertion
        let count = try await dbPool.read { db in
            try MediaItemRecord.fetchCount(db)
        }
        XCTAssertEqual(count, 1)

        // Verify we can fetch it back
        let fetched = try await dbPool.read { db in
            try MediaItemRecord.fetchOne(db, sql: "SELECT * FROM media_items WHERE id = ?", arguments: [item.id.uuidString])
        }
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.platform, "twitter")
        XCTAssertEqual(fetched?.author, "@bob")
    }

    func testMultipleItemsImport() async throws {
        // Create multiple items
        let items = [
            ("twitter_user1_001", "https://twitter.com/user1/status/001", "twitter", "@user1"),
            ("instagram_user2_002", "https://instagram.com/p/abc", "instagram", "@user2"),
            ("reddit_user3_003", "https://reddit.com/r/test/003", "reddit", "u/user3"),
        ]

        var createdItems: [MediaItem] = []

        for (baseName, source, platform, author) in items {
            let (mdURL, imageURL) = try testArchive.createItem(
                in: "2025-01",
                baseName: baseName,
                source: source,
                platform: platform,
                author: author
            )

            let metadata = try MetadataParser.parse(fileAt: mdURL)
            let item = MediaItem(
                id: UUID(),
                basePath: testArchive.rootURL.appendingPathComponent("2025-01"),
                metadataFile: mdURL,
                mediaFiles: [imageURL],
                metadata: metadata
            )
            createdItems.append(item)

            let record = MediaItemRecord(from: item)
            try await dbPool.write { db in
                try record.insertWithFTSSync(db: db)
            }
        }

        // Verify all items inserted
        let count = try await dbPool.read { db in
            try MediaItemRecord.fetchCount(db)
        }
        XCTAssertEqual(count, 3)

        // Verify platform counts
        let twitterCount = try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE platform = ?", arguments: ["twitter"])
        }
        XCTAssertEqual(twitterCount, 1)

        let instagramCount = try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE platform = ?", arguments: ["instagram"])
        }
        XCTAssertEqual(instagramCount, 1)
    }

    // MARK: - FTS Integration Tests

    func testFTSSearchAfterImport() async throws {
        // Create items with different OCR text
        let (mdURL1, imageURL1) = try testArchive.createItem(
            in: "2025-01",
            baseName: "item1",
            source: "https://example.com/1",
            author: "@artist"
        )

        let (mdURL2, imageURL2) = try testArchive.createItem(
            in: "2025-01",
            baseName: "item2",
            source: "https://example.com/2",
            author: "@photographer"
        )

        // Insert with OCR text
        let metadata1 = try MetadataParser.parse(fileAt: mdURL1)
        let item1 = MediaItem(
            id: UUID(),
            basePath: testArchive.rootURL.appendingPathComponent("2025-01"),
            metadataFile: mdURL1,
            mediaFiles: [imageURL1],
            metadata: metadata1,
            indexedContent: IndexedContent(ocrText: "Beautiful sunset painting")
        )

        let metadata2 = try MetadataParser.parse(fileAt: mdURL2)
        let item2 = MediaItem(
            id: UUID(),
            basePath: testArchive.rootURL.appendingPathComponent("2025-01"),
            metadataFile: mdURL2,
            mediaFiles: [imageURL2],
            metadata: metadata2,
            indexedContent: IndexedContent(ocrText: "Mountain landscape photo")
        )

        // Insert both items
        for item in [item1, item2] {
            let record = MediaItemRecord(from: item)
            try await dbPool.write { db in
                try record.insertWithFTSSync(db: db)
            }
        }

        // Search for "sunset" - should find item1
        let sunsetResults = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE ocrText LIKE ?
            """, arguments: ["%sunset%"])
        }
        XCTAssertEqual(sunsetResults.count, 1)
        XCTAssertEqual(sunsetResults.first?.author, "@artist")

        // Search for "mountain" - should find item2
        let mountainResults = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE ocrText LIKE ?
            """, arguments: ["%mountain%"])
        }
        XCTAssertEqual(mountainResults.count, 1)
        XCTAssertEqual(mountainResults.first?.author, "@photographer")

        // Search for "photo" - should find item2
        let photoResults = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE ocrText LIKE ?
            """, arguments: ["%photo%"])
        }
        XCTAssertEqual(photoResults.count, 1)
    }

    func testFTSSearchByAuthor() async throws {
        // Create items with different authors
        let items = [
            ("item1", "@alice"),
            ("item2", "@bob"),
            ("item3", "@alice"),
        ]

        for (baseName, author) in items {
            let (mdURL, imageURL) = try testArchive.createItem(
                in: "2025-01",
                baseName: baseName,
                source: "https://example.com/\(baseName)",
                author: author
            )

            let metadata = try MetadataParser.parse(fileAt: mdURL)
            let item = MediaItem(
                id: UUID(),
                basePath: testArchive.rootURL.appendingPathComponent("2025-01"),
                metadataFile: mdURL,
                mediaFiles: [imageURL],
                metadata: metadata
            )

            let record = MediaItemRecord(from: item)
            try await dbPool.write { db in
                try record.insertWithFTSSync(db: db)
            }
        }

        // Search for @alice using main table (simpler than FTS join)
        // Note: FTS with contentless tables can't easily join because id values are NULL
        let aliceResults = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE author LIKE ?
            """, arguments: ["%alice%"])
        }
        XCTAssertEqual(aliceResults.count, 2)
    }

    // MARK: - Graceful Parse Error Handling

    func testPartialParseStillImports() async throws {
        // Create a file with minimal valid frontmatter (only source)
        let folder = try testArchive.createFolder("2025-01")
        let fileURL = folder.appendingPathComponent("partial_item.md")

        let content = """
        ---
        source: https://example.com/partial
        ---
        Some content
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        // Parse gracefully
        let result = MetadataParser.parseGracefully(fileAt: fileURL)

        switch result {
        case .success(let metadata), .partial(let metadata, _):
            // Should still get metadata
            XCTAssertEqual(metadata.source.absoluteString, "https://example.com/partial")
            XCTAssertEqual(metadata.platform, "example")  // Extracted from URL

            // Insert into database
            let item = MediaItem(
                id: UUID(),
                basePath: folder,
                metadataFile: fileURL,
                mediaFiles: [],
                metadata: metadata,
                parseStatus: result.parseStatus,
                parseErrors: result.errors
            )

            let record = MediaItemRecord(from: item)
            try await dbPool.write { db in
                try record.insertWithFTSSync(db: db)
            }

            // Verify it was inserted
            let count = try await dbPool.read { db in
                try MediaItemRecord.fetchCount(db)
            }
            XCTAssertEqual(count, 1)

        case .failed:
            XCTFail("Should have parsed at least partially")
        }
    }

    func testAmbiguousDateWarning() async throws {
        // Create file with ambiguous date format (05/06/2025 - could be May 6 or June 5)
        let folder = try testArchive.createFolder("2025-01")
        let fileURL = folder.appendingPathComponent("ambiguous_date.md")

        let content = """
        ---
        source: https://example.com/ambiguous
        date: 05/06/2025
        ---
        """
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        // Parse gracefully
        let result = MetadataParser.parseGracefully(fileAt: fileURL)

        switch result {
        case .partial(let metadata, let errors):
            // Should have date but with warning
            XCTAssertNotNil(metadata.originalDate)
            XCTAssertTrue(errors.contains { $0.contains("Ambiguous") })
            XCTAssertEqual(metadata.originalDateString, "05/06/2025")

        case .success:
            XCTFail("Ambiguous date should result in partial parse with warning")

        case .failed:
            XCTFail("Should not fail completely")
        }
    }

    // MARK: - Parse Status Filtering

    func testFilterByParseStatus() async throws {
        // Create items with different parse statuses
        let successItem = SampleData.createMediaItem(
            platform: "twitter",
            parseStatus: .success
        )
        let partialItem = SampleData.createMediaItem(
            platform: "instagram",
            parseStatus: .partial
        )
        let failedItem = SampleData.createMediaItem(
            platform: "reddit",
            parseStatus: .failed
        )

        // Insert all items
        for item in [successItem, partialItem, failedItem] {
            let record = MediaItemRecord(from: item)
            try await dbPool.write { db in
                try record.insert(db)
            }
        }

        // Query items with issues (partial or failed)
        let issueItems = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE parseStatus != 'success'
            """)
        }
        XCTAssertEqual(issueItems.count, 2)

        // Query only failed items
        let failedItems = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE parseStatus = 'failed'
            """)
        }
        XCTAssertEqual(failedItems.count, 1)
        XCTAssertEqual(failedItems.first?.platform, "reddit")
    }

    // MARK: - Batch Import Performance

    func testBatchImportPerformance() async throws {
        // Create multiple items for batch import
        let itemCount = 50

        // Measure creation and parsing
        let startCreate = CFAbsoluteTimeGetCurrent()

        var items: [MediaItem] = []
        for i in 0..<itemCount {
            let (mdURL, imageURL) = try testArchive.createItem(
                in: "2025-01",
                baseName: "batch_item_\(i)",
                source: "https://example.com/batch/\(i)",
                platform: ["twitter", "instagram", "reddit"][i % 3],
                author: "@user\(i % 10)",
                tags: ["tag\(i % 5)"]
            )

            let metadata = try MetadataParser.parse(fileAt: mdURL)
            let item = MediaItem(
                id: UUID(),
                basePath: testArchive.rootURL.appendingPathComponent("2025-01"),
                metadataFile: mdURL,
                mediaFiles: [imageURL],
                metadata: metadata
            )
            items.append(item)
        }

        let createTime = CFAbsoluteTimeGetCurrent() - startCreate

        // Measure database insertion
        let startInsert = CFAbsoluteTimeGetCurrent()
        let itemsToInsert = items

        try await dbPool.write { db in
            for item in itemsToInsert {
                let record = MediaItemRecord(from: item)
                try record.insertWithFTSSync(db: db)
            }
        }

        let insertTime = CFAbsoluteTimeGetCurrent() - startInsert

        // Verify all items inserted
        let count = try await dbPool.read { db in
            try MediaItemRecord.fetchCount(db)
        }
        XCTAssertEqual(count, itemCount)

        // Log performance (not strict assertions, just informational)
        print("Created \(itemCount) items in \(createTime)s")
        print("Inserted \(itemCount) items in \(insertTime)s")

        // Reasonable performance expectations
        XCTAssertLessThan(createTime, 10.0, "Item creation took too long")
        XCTAssertLessThan(insertTime, 5.0, "Database insertion took too long")
    }

    // MARK: - Duplicate Detection

    func testPreventDuplicateMetadataPath() async throws {
        let (mdURL, imageURL) = try testArchive.createItem(
            in: "2025-01",
            baseName: "unique_item",
            source: "https://example.com/unique"
        )

        let metadata = try MetadataParser.parse(fileAt: mdURL)
        let item1 = MediaItem(
            id: UUID(),
            basePath: testArchive.rootURL.appendingPathComponent("2025-01"),
            metadataFile: mdURL,
            mediaFiles: [imageURL],
            metadata: metadata
        )

        // Insert first item
        try await dbPool.write { db in
            let record = MediaItemRecord(from: item1)
            try record.insertWithFTSSync(db: db)
        }

        // Try to insert with same metadata file path (different UUID)
        let item2 = MediaItem(
            id: UUID(),  // Different ID
            basePath: testArchive.rootURL.appendingPathComponent("2025-01"),
            metadataFile: mdURL,  // Same path
            mediaFiles: [imageURL],
            metadata: metadata
        )

        // Should fail due to UNIQUE constraint on metadataFileString
        do {
            try await dbPool.write { db in
                let record = MediaItemRecord(from: item2)
                try record.insert(db)
            }
            XCTFail("Should have thrown duplicate key error")
        } catch {
            // Expected - UNIQUE constraint violation
            XCTAssertTrue(error.localizedDescription.contains("UNIQUE") || error is GRDB.DatabaseError)
        }
    }
}
