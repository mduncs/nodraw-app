import XCTest
import GRDB
@testable import MediaViewer

/// Integration tests for filtering end-to-end:
/// Insert items -> Apply filters -> Verify correct items returned
final class FilterFlowTests: XCTestCase {

    var testDatabase: TestDatabase!
    var dbPool: DatabasePool!

    // Sample items inserted at setUp
    var insertedItems: [MediaItem] = []

    override func setUp() async throws {
        try await super.setUp()
        testDatabase = TestDatabase()
        dbPool = try await testDatabase.initialize()

        // Insert sample items for filter testing
        insertedItems = await insertSampleItems()
    }

    override func tearDown() async throws {
        await testDatabase.tearDown()
        testDatabase = nil
        dbPool = nil
        insertedItems = []
        try await super.tearDown()
    }

    // MARK: - Sample Data Setup

    /// Insert a variety of items with different metadata for comprehensive filter testing
    private func insertSampleItems() async -> [MediaItem] {
        let baseDate = Date()
        let calendar = Calendar.current

        let items = [
            // Twitter items
            SampleData.createMediaItem(
                id: UUID(),
                source: "https://twitter.com/alice/1",
                platform: "twitter",
                author: "@alice",
                originalDate: calendar.date(byAdding: .day, value: -1, to: baseDate),
                starred: true,
                tags: ["art", "illustration"],
                ocrText: "Beautiful sunset painting"
            ),
            SampleData.createMediaItem(
                id: UUID(),
                source: "https://twitter.com/alice/2",
                platform: "twitter",
                author: "@alice",
                originalDate: calendar.date(byAdding: .hour, value: -2, to: baseDate),
                starred: false,
                tags: ["art"],
                notes: "Remember to share this"
            ),
            SampleData.createMediaItem(
                id: UUID(),
                source: "https://twitter.com/charlie/1",
                platform: "twitter",
                author: "@charlie",
                originalDate: calendar.date(byAdding: .month, value: -1, to: baseDate),
                starred: true,
                tags: ["meme"],
                ocrText: "Funny cat meme text"
            ),

            // Instagram items
            SampleData.createMediaItem(
                id: UUID(),
                source: "https://instagram.com/bob/1",
                platform: "instagram",
                author: "@bob",
                originalDate: calendar.date(byAdding: .day, value: -7, to: baseDate),
                starred: false,
                tags: ["photo", "landscape"],
                ocrText: "Mountain landscape"
            ),
            SampleData.createMediaItem(
                id: UUID(),
                source: "https://instagram.com/eve/1",
                platform: "instagram",
                author: "@eve",
                originalDate: calendar.date(byAdding: .day, value: -14, to: baseDate),
                starred: true,
                tags: ["photo"],
                ocrText: "Ocean waves crashing"
            ),

            // Reddit items
            SampleData.createMediaItem(
                id: UUID(),
                source: "https://reddit.com/r/test/1",
                platform: "reddit",
                author: "u/dave",
                originalDate: calendar.date(byAdding: .day, value: -3, to: baseDate),
                starred: false,
                tags: [],  // No tags
                ocrText: nil  // No OCR text
            ),
            SampleData.createMediaItem(
                id: UUID(),
                source: "https://reddit.com/r/test/2",
                platform: "reddit",
                author: "u/frank",
                originalDate: calendar.date(byAdding: .day, value: -5, to: baseDate),
                starred: false,
                tags: ["programming"],
                ocrText: "Code snippet example"
            ),
        ]

        // Insert all items
        for item in items {
            let record = MediaItemRecord(from: item)
            do {
                try await dbPool.write { db in
                    try record.insertWithFTSSync(db: db)
                }
            } catch {
                XCTFail("Failed to insert sample item: \(error)")
            }
        }

        return items
    }

    // MARK: - Text Filter Tests

    func testTextFilterContains() async throws {
        // Search for "sunset" - should find 1 item
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items
                WHERE ocrText LIKE ? OR notes LIKE ? OR author LIKE ?
            """, arguments: ["%sunset%", "%sunset%", "%sunset%"])
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.author, "@alice")
    }

    func testTextFilterNoMatch() async throws {
        // Search for text that doesn't exist
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items
                WHERE ocrText LIKE ? OR notes LIKE ? OR author LIKE ?
            """, arguments: ["%nonexistent%", "%nonexistent%", "%nonexistent%"])
        }

        XCTAssertEqual(results.count, 0)
    }

    func testTextFilterInNotes() async throws {
        // Search for "share" - should find item with notes
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items
                WHERE notes LIKE ?
            """, arguments: ["%share%"])
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(results.first?.notes)
    }

    func testTextFilterByAuthor() async throws {
        // Search for "alice" - should find both of her items
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items
                WHERE author LIKE ?
            """, arguments: ["%alice%"])
        }

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.author == "@alice" })
    }

    // MARK: - Platform Filter Tests

    func testPlatformFilterTwitter() async throws {
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE platform = ?
            """, arguments: ["twitter"])
        }

        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.platform == "twitter" })
    }

    func testPlatformFilterInstagram() async throws {
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE platform = ?
            """, arguments: ["instagram"])
        }

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.platform == "instagram" })
    }

    func testPlatformFilterMultiple() async throws {
        // Filter for twitter OR instagram
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE platform IN (?, ?)
            """, arguments: ["twitter", "instagram"])
        }

        XCTAssertEqual(results.count, 5)  // 3 twitter + 2 instagram
    }

    // MARK: - Starred Filter Tests

    func testStarredFilter() async throws {
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE starred = ?
            """, arguments: [true])
        }

        XCTAssertEqual(results.count, 3)  // alice, charlie, eve
        XCTAssertTrue(results.allSatisfy { $0.starred })
    }

    func testNotStarredFilter() async throws {
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE starred = ?
            """, arguments: [false])
        }

        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results.allSatisfy { !$0.starred })
    }

    // MARK: - Tag Filter Tests

    func testSingleTagFilter() async throws {
        // Find items with "art" tag
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE tagsJSON LIKE ?
            """, arguments: ["%\"art\"%"])
        }

        XCTAssertEqual(results.count, 2)  // Both alice items have "art"
    }

    func testMultipleTagsFilter() async throws {
        // Find items with both "art" AND "illustration" tags
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items
                WHERE tagsJSON LIKE ? AND tagsJSON LIKE ?
            """, arguments: ["%\"art\"%", "%\"illustration\"%"])
        }

        XCTAssertEqual(results.count, 1)  // Only first alice item
    }

    func testUntaggedFilter() async throws {
        // Find items with no tags
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items
                WHERE tagsJSON IS NULL OR tagsJSON = '[]'
            """)
        }

        XCTAssertEqual(results.count, 1)  // Only dave's reddit item
        XCTAssertEqual(results.first?.author, "u/dave")
    }

    // MARK: - Date Range Filter Tests

    func testDateRangeLastWeek() async throws {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!

        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE archivedDate > ?
            """, arguments: [weekAgo])
        }

        // All items should be within last week (they were just inserted)
        XCTAssertEqual(results.count, 7)
    }

    func testDateRangeByOriginalDate() async throws {
        // Items within last 5 days by originalDate
        let fiveDaysAgo = Calendar.current.date(byAdding: .day, value: -5, to: Date())!

        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE originalDate > ?
            """, arguments: [fiveDaysAgo])
        }

        // Should find items created 1 day, 2 hours, and 3 days ago
        XCTAssertEqual(results.count, 3)
    }

    // MARK: - Smart Folder Rule Tests

    func testSmartFolderPlatformRule() async throws {
        let rule = FilterRule.platform(.equals("twitter"))
        let fragment = rule.sqlFragment()

        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE \(fragment.sql)
            """, arguments: StatementArguments(fragment.arguments))
        }

        XCTAssertEqual(results.count, 3)
    }

    func testSmartFolderStarredRule() async throws {
        let rule = FilterRule.starred(true)
        let fragment = rule.sqlFragment()

        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE \(fragment.sql)
            """, arguments: StatementArguments(fragment.arguments))
        }

        XCTAssertEqual(results.count, 3)
    }

    func testSmartFolderTagRule() async throws {
        let rule = FilterRule.hasTag("photo")
        let fragment = rule.sqlFragment()

        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE \(fragment.sql)
            """, arguments: StatementArguments(fragment.arguments))
        }

        XCTAssertEqual(results.count, 2)  // bob and eve
    }

    func testSmartFolderEmptyTagsRule() async throws {
        let rule = FilterRule.tagsEmpty
        let fragment = rule.sqlFragment()

        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE \(fragment.sql)
            """, arguments: StatementArguments(fragment.arguments))
        }

        XCTAssertEqual(results.count, 1)  // dave
    }

    func testSmartFolderHasNotesRule() async throws {
        let rule = FilterRule.hasNotes(true)
        let fragment = rule.sqlFragment()

        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE \(fragment.sql)
            """, arguments: StatementArguments(fragment.arguments))
        }

        XCTAssertEqual(results.count, 1)  // second alice item
    }

    func testSmartFolderHasTextRule() async throws {
        let rule = FilterRule.hasText(.isNotEmpty)
        let fragment = rule.sqlFragment()

        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE \(fragment.sql)
            """, arguments: StatementArguments(fragment.arguments))
        }

        // Items with ocrText: alice/1, charlie, bob, eve, frank = 5
        // Items without: alice/2 (only notes), dave (nil) = 2
        XCTAssertEqual(results.count, 5)
    }

    func testSmartFolderTextContainsRule() async throws {
        let rule = FilterRule.hasText(.contains("cat"))
        let fragment = rule.sqlFragment()

        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE \(fragment.sql)
            """, arguments: StatementArguments(fragment.arguments))
        }

        XCTAssertEqual(results.count, 1)  // charlie's meme
    }

    // MARK: - Combined Filter Tests (AND logic)

    func testCombinedFiltersAND() async throws {
        // Find starred twitter items
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items
                WHERE platform = ? AND starred = ?
            """, arguments: ["twitter", true])
        }

        XCTAssertEqual(results.count, 2)  // alice and charlie
    }

    func testCombinedFiltersWithText() async throws {
        // Find instagram items with "Ocean" in OCR text
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items
                WHERE platform = ? AND ocrText LIKE ?
            """, arguments: ["instagram", "%Ocean%"])
        }

        XCTAssertEqual(results.count, 1)  // eve
    }

    func testCombinedFiltersWithTagAndPlatform() async throws {
        // Find twitter items with "art" tag
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items
                WHERE platform = ? AND tagsJSON LIKE ?
            """, arguments: ["twitter", "%\"art\"%"])
        }

        XCTAssertEqual(results.count, 2)  // both alice items
    }

    func testCombinedFiltersThreeConditions() async throws {
        // Find starred twitter items with "art" tag
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items
                WHERE platform = ?
                AND starred = ?
                AND tagsJSON LIKE ?
            """, arguments: ["twitter", true, "%\"art\"%"])
        }

        XCTAssertEqual(results.count, 1)  // Only first alice item
    }

    // MARK: - Combined Filter Tests (OR logic)

    func testCombinedFiltersOR() async throws {
        // Find items that are starred OR have "meme" tag
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items
                WHERE starred = ? OR tagsJSON LIKE ?
            """, arguments: [true, "%\"meme\"%"])
        }

        XCTAssertEqual(results.count, 3)  // alice, charlie, eve (charlie is both starred AND has meme tag)
    }

    // MARK: - Sort Order Tests

    func testSortByArchivedDateDesc() async throws {
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items ORDER BY archivedDate DESC
            """)
        }

        XCTAssertEqual(results.count, 7)
        // All items were inserted with same archivedDate (Date()), so order may not be deterministic
        // But we verify count is correct
    }

    func testSortByPlatform() async throws {
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items ORDER BY platform ASC
            """)
        }

        XCTAssertEqual(results.count, 7)
        // Verify alphabetical order: instagram, reddit, twitter
        let platforms = results.map { $0.platform }
        XCTAssertEqual(platforms.prefix(2).filter { $0 == "instagram" }.count, 2)
        XCTAssertEqual(platforms.dropFirst(2).prefix(2).filter { $0 == "reddit" }.count, 2)
    }

    func testSortByAuthor() async throws {
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items ORDER BY author ASC
            """)
        }

        XCTAssertEqual(results.count, 7)
        // First should be @alice or @bob (both start with letters after @)
        XCTAssertTrue(results.first?.author?.starts(with: "@") ?? false)
    }

    // MARK: - Edge Cases

    func testEmptyResultSet() async throws {
        // Filter that matches nothing
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE platform = ?
            """, arguments: ["tiktok"])
        }

        XCTAssertEqual(results.count, 0)
    }

    func testNullHandling() async throws {
        // Find items where originalDate is NOT NULL
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE originalDate IS NOT NULL
            """)
        }

        XCTAssertEqual(results.count, 7)  // All items have originalDate
    }

    func testCaseInsensitiveSearch() async throws {
        // Search should be case insensitive with LIKE
        let results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items
                WHERE ocrText LIKE ? COLLATE NOCASE
            """, arguments: ["%SUNSET%"])
        }

        XCTAssertEqual(results.count, 1)  // Should find "Beautiful sunset painting"
    }

    // MARK: - Pagination Tests

    func testLimitAndOffset() async throws {
        // Get first 3 items
        let page1 = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items ORDER BY id LIMIT 3
            """)
        }

        XCTAssertEqual(page1.count, 3)

        // Get next 3 items
        let page2 = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items ORDER BY id LIMIT 3 OFFSET 3
            """)
        }

        XCTAssertEqual(page2.count, 3)

        // Verify no overlap
        let page1Ids = Set(page1.map { $0.id })
        let page2Ids = Set(page2.map { $0.id })
        XCTAssertTrue(page1Ids.isDisjoint(with: page2Ids))
    }

    func testCountWithFilter() async throws {
        // Count starred items
        let count = try await dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM media_items WHERE starred = ?
            """, arguments: [true])
        }

        XCTAssertEqual(count, 3)
    }
}
