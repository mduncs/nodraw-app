import XCTest
import GRDB
@testable import MediaViewer

final class SmartFolderTests: XCTestCase {

    // MARK: - SmartFolder Creation Tests

    func testSmartFolderCreationWithDefaults() {
        let folder = SmartFolder(
            name: "Test Folder",
            rules: [.starred(true)]
        )

        XCTAssertEqual(folder.name, "Test Folder")
        XCTAssertEqual(folder.icon, "folder.badge.gearshape")
        XCTAssertEqual(folder.rules.count, 1)
        XCTAssertTrue(folder.matchAll)
        XCTAssertEqual(folder.sortOrder, .archivedDateDescending)
    }

    func testSmartFolderCreationWithAllFields() {
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1700000000)
        let updated = Date(timeIntervalSince1970: 1700100000)

        let folder = SmartFolder(
            id: id,
            name: "Custom Folder",
            icon: "star.fill",
            rules: [.starred(true), .hasVideo(true)],
            matchAll: false,
            sortOrder: .originalDateDescending,
            createdAt: created,
            updatedAt: updated
        )

        XCTAssertEqual(folder.id, id)
        XCTAssertEqual(folder.name, "Custom Folder")
        XCTAssertEqual(folder.icon, "star.fill")
        XCTAssertEqual(folder.rules.count, 2)
        XCTAssertFalse(folder.matchAll)
        XCTAssertEqual(folder.sortOrder, .originalDateDescending)
        XCTAssertEqual(folder.createdAt, created)
        XCTAssertEqual(folder.updatedAt, updated)
    }

    // MARK: - FilterRule SQL Generation Tests

    func testPlatformEqualsRule() {
        let rule = FilterRule.platform(.equals("twitter"))
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "platform = ?")
        XCTAssertEqual(args.count, 1)
        XCTAssertEqual(args[0] as? String, "twitter")
    }

    func testPlatformOneOfRule() {
        let rule = FilterRule.platform(.oneOf(["twitter", "instagram", "reddit"]))
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "platform IN (?, ?, ?)")
        XCTAssertEqual(args.count, 3)
    }

    func testAuthorEqualsRule() {
        let rule = FilterRule.author(.equals("@testuser"))
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "author = ?")
        XCTAssertEqual(args[0] as? String, "@testuser")
    }

    func testAuthorContainsRule() {
        let rule = FilterRule.author(.contains("test"))
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "author LIKE ? ESCAPE '\\'")
        XCTAssertEqual(args[0] as? String, "%test%")
    }

    func testAuthorStartsWithRule() {
        let rule = FilterRule.author(.startsWith("@"))
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "author LIKE ? ESCAPE '\\'")
        XCTAssertEqual(args[0] as? String, "@%")
    }

    func testAuthorIsEmptyRule() {
        let rule = FilterRule.author(.isEmpty)
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "(author IS NULL OR author = '')")
        XCTAssertTrue(args.isEmpty)
    }

    func testAuthorIsNotEmptyRule() {
        let rule = FilterRule.author(.isNotEmpty)
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "author IS NOT NULL AND author != ''")
        XCTAssertTrue(args.isEmpty)
    }

    func testDateRangeAfterRule() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let rule = FilterRule.dateRange(DateRangeFilter(field: .archived, range: .after(date)))
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "archivedDate > ?")
        XCTAssertEqual(args.count, 1)
    }

    func testDateRangeBeforeRule() {
        let date = Date(timeIntervalSince1970: 1700000000)
        let rule = FilterRule.dateRange(DateRangeFilter(field: .original, range: .before(date)))
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "originalDate < ?")
        XCTAssertEqual(args.count, 1)
    }

    func testDateRangeBetweenRule() {
        let start = Date(timeIntervalSince1970: 1700000000)
        let end = Date(timeIntervalSince1970: 1700100000)
        let rule = FilterRule.dateRange(DateRangeFilter(field: .archived, range: .between(start, end)))
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "archivedDate BETWEEN ? AND ?")
        XCTAssertEqual(args.count, 2)
    }

    func testDateRangeLastNDaysRule() {
        let rule = FilterRule.dateRange(DateRangeFilter(field: .archived, range: .lastNDays(7)))
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "archivedDate > ?")
        XCTAssertEqual(args.count, 1)
        // Date should be approximately 7 days ago
        if let date = args[0] as? Date {
            let daysAgo = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
            XCTAssertEqual(daysAgo, 7, accuracy: 1)
        }
    }

    func testDateRangeThisMonthRule() {
        let rule = FilterRule.dateRange(DateRangeFilter(field: .archived, range: .thisMonth))
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "archivedDate >= ?")
        XCTAssertEqual(args.count, 1)
    }

    func testDateRangeThisYearRule() {
        let rule = FilterRule.dateRange(DateRangeFilter(field: .original, range: .thisYear))
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "originalDate >= ?")
        XCTAssertEqual(args.count, 1)
    }

    func testHasTextEqualsRule() {
        let rule = FilterRule.hasText(.equals("exact phrase"))
        let (sql, args) = rule.sqlFragment()

        XCTAssertTrue(sql.contains("media_items_fts"))
        XCTAssertTrue(sql.contains("MATCH"))
        XCTAssertEqual(args[0] as? String, "\"exact phrase\"")
    }

    func testHasTextContainsRule() {
        let rule = FilterRule.hasText(.contains("search"))
        let (sql, args) = rule.sqlFragment()

        // Contains uses LIKE fallback since FTS5 doesn't support prefix wildcard
        XCTAssertEqual(sql, "ocrText LIKE ? ESCAPE '\\'")
        XCTAssertEqual(args[0] as? String, "%search%")
    }

    func testHasTextStartsWithRule() {
        let rule = FilterRule.hasText(.startsWith("hello"))
        let (sql, args) = rule.sqlFragment()

        XCTAssertTrue(sql.contains("MATCH"))
        // FTS5 suffix wildcard for prefix match
        XCTAssertTrue((args[0] as? String)?.hasSuffix("*") ?? false)
    }

    func testHasTextIsEmptyRule() {
        let rule = FilterRule.hasText(.isEmpty)
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "(ocrText IS NULL OR ocrText = '')")
        XCTAssertTrue(args.isEmpty)
    }

    func testHasTextIsNotEmptyRule() {
        let rule = FilterRule.hasText(.isNotEmpty)
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "ocrText IS NOT NULL AND ocrText != ''")
        XCTAssertTrue(args.isEmpty)
    }

    func testColorBucketRule() {
        let rule = FilterRule.colorBucket(.red)
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "dominantColorsJSON LIKE ? ESCAPE '\\'")
        XCTAssertTrue((args[0] as? String)?.contains("red") ?? false)
    }

    func testStarredTrueRule() {
        let rule = FilterRule.starred(true)
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "starred = ?")
        XCTAssertEqual(args[0] as? Bool, true)
    }

    func testStarredFalseRule() {
        let rule = FilterRule.starred(false)
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "starred = ?")
        XCTAssertEqual(args[0] as? Bool, false)
    }

    func testHasTagRule() {
        let rule = FilterRule.hasTag("art")
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "tagsJSON LIKE ? ESCAPE '\\'")
        XCTAssertTrue((args[0] as? String)?.contains("art") ?? false)
    }

    func testTagsEmptyRule() {
        let rule = FilterRule.tagsEmpty
        let (sql, args) = rule.sqlFragment()

        XCTAssertTrue(sql.contains("tagsJSON IS NULL"))
        XCTAssertTrue(sql.contains("'[]'"))
        XCTAssertTrue(args.isEmpty)
    }

    func testHasNotesTrueRule() {
        let rule = FilterRule.hasNotes(true)
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "notes IS NOT NULL AND notes != ''")
        XCTAssertTrue(args.isEmpty)
    }

    func testHasNotesFalseRule() {
        let rule = FilterRule.hasNotes(false)
        let (sql, args) = rule.sqlFragment()

        XCTAssertTrue(sql.contains("notes IS NULL"))
        XCTAssertTrue(args.isEmpty)
    }

    func testHasVideoTrueRule() {
        let rule = FilterRule.hasVideo(true)
        let (sql, args) = rule.sqlFragment()

        XCTAssertTrue(sql.contains(".mp4"))
        XCTAssertTrue(sql.contains(".mov"))
        XCTAssertTrue(sql.contains(".webm"))
        XCTAssertTrue(sql.contains("OR"))
        XCTAssertTrue(args.isEmpty)
    }

    func testHasVideoFalseRule() {
        let rule = FilterRule.hasVideo(false)
        let (sql, args) = rule.sqlFragment()

        XCTAssertTrue(sql.contains("NOT LIKE"))
        XCTAssertTrue(sql.contains("AND"))
        XCTAssertTrue(args.isEmpty)
    }

    func testHasContextImageTrueRule() {
        let rule = FilterRule.hasContextImage(true)
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "contextImageString IS NOT NULL")
        XCTAssertTrue(args.isEmpty)
    }

    func testHasContextImageFalseRule() {
        let rule = FilterRule.hasContextImage(false)
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "contextImageString IS NULL")
        XCTAssertTrue(args.isEmpty)
    }

    func testParseStatusEqualsRule() {
        let rule = FilterRule.parseStatus(.equals(.partial))
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "parseStatus = ?")
        XCTAssertEqual(args[0] as? String, "partial")
    }

    func testParseStatusNotEqualsRule() {
        let rule = FilterRule.parseStatus(.notEquals(.success))
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "parseStatus != ?")
        XCTAssertEqual(args[0] as? String, "success")
    }

    func testParseStatusHasIssuesRule() {
        let rule = FilterRule.parseStatus(.hasIssues)
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "parseStatus != 'success'")
        XCTAssertTrue(args.isEmpty)
    }

    func testIsMetadataOnlyTrueRule() {
        let rule = FilterRule.isMetadataOnly(true)
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "mediaFilesJSON = '[]'")
        XCTAssertTrue(args.isEmpty)
    }

    func testIsMetadataOnlyFalseRule() {
        let rule = FilterRule.isMetadataOnly(false)
        let (sql, args) = rule.sqlFragment()

        XCTAssertEqual(sql, "mediaFilesJSON != '[]'")
        XCTAssertTrue(args.isEmpty)
    }

    func testIsProcessedTrueRule() {
        let rule = FilterRule.isProcessed(true)
        let (sql, args) = rule.sqlFragment()

        XCTAssertTrue(sql.contains("ocrText IS NOT NULL"))
        XCTAssertTrue(sql.contains("OR"))
        XCTAssertTrue(args.isEmpty)
    }

    func testIsProcessedFalseRule() {
        let rule = FilterRule.isProcessed(false)
        let (sql, args) = rule.sqlFragment()

        XCTAssertTrue(sql.contains("ocrText IS NULL"))
        XCTAssertTrue(sql.contains("AND"))
        XCTAssertTrue(args.isEmpty)
    }

    // MARK: - FilterRule Description Tests

    func testFilterRuleDescriptions() {
        XCTAssertEqual(FilterRule.platform(.twitter).description, "Platform is Twitter")
        XCTAssertEqual(FilterRule.starred(true).description, "Is starred")
        XCTAssertEqual(FilterRule.starred(false).description, "Not starred")
        XCTAssertEqual(FilterRule.hasTag("art").description, "Has tag \"art\"")
        XCTAssertEqual(FilterRule.tagsEmpty.description, "No tags")
        XCTAssertEqual(FilterRule.hasNotes(true).description, "Has notes")
        XCTAssertEqual(FilterRule.hasNotes(false).description, "No notes")
        XCTAssertEqual(FilterRule.hasVideo(true).description, "Contains video")
        XCTAssertEqual(FilterRule.hasVideo(false).description, "No video")
        XCTAssertEqual(FilterRule.isMetadataOnly(true).description, "Metadata only (no media)")
        XCTAssertEqual(FilterRule.isMetadataOnly(false).description, "Has media files")
        XCTAssertEqual(FilterRule.isProcessed(true).description, "Has been processed")
        XCTAssertEqual(FilterRule.isProcessed(false).description, "Not yet processed")
    }

    // MARK: - SmartFolder Rule Composition Tests

    func testMatchAllComposition() {
        let folder = SmartFolder(
            name: "Test",
            rules: [
                .platform(.twitter),
                .starred(true),
                .hasVideo(true)
            ],
            matchAll: true
        )

        XCTAssertTrue(folder.matchAll)
        XCTAssertEqual(folder.rules.count, 3)

        // When combining rules, matchAll=true means AND
        // Each rule should generate valid SQL that can be ANDed together
        for rule in folder.rules {
            let (sql, _) = rule.sqlFragment()
            XCTAssertFalse(sql.isEmpty)
        }
    }

    func testMatchAnyComposition() {
        let folder = SmartFolder(
            name: "Test",
            rules: [
                .platform(.twitter),
                .platform(.instagram)
            ],
            matchAll: false
        )

        XCTAssertFalse(folder.matchAll)

        // When matchAll=false, rules are ORed
        for rule in folder.rules {
            let (sql, _) = rule.sqlFragment()
            XCTAssertFalse(sql.isEmpty)
        }
    }

    // MARK: - Default SmartFolders Validation Tests

    func testDefaultSmartFoldersAreValid() {
        let defaults = SmartFolder.defaultFolders

        XCTAssertFalse(defaults.isEmpty)

        for folder in defaults {
            // Each default folder should have a name
            XCTAssertFalse(folder.name.isEmpty, "Folder '\(folder.name)' has empty name")

            // Each should have an icon
            XCTAssertFalse(folder.icon.isEmpty, "Folder '\(folder.name)' has empty icon")

            // Each should have at least one rule
            XCTAssertFalse(folder.rules.isEmpty, "Folder '\(folder.name)' has no rules")

            // Each rule should generate valid SQL
            for rule in folder.rules {
                let (sql, _) = rule.sqlFragment()
                XCTAssertFalse(sql.isEmpty, "Rule in '\(folder.name)' generates empty SQL")
            }
        }
    }

    func testDefaultSmartFoldersContainExpectedFolders() {
        let defaults = SmartFolder.defaultFolders
        let names = defaults.map(\.name)

        XCTAssertTrue(names.contains("Twitter"))
        XCTAssertTrue(names.contains("Starred"))
        XCTAssertTrue(names.contains("Recent"))
        XCTAssertTrue(names.contains("Has Text"))
        XCTAssertTrue(names.contains("Videos"))
        XCTAssertTrue(names.contains("Untagged"))
        XCTAssertTrue(names.contains("Parse Issues"))
        XCTAssertTrue(names.contains("Metadata Only"))
    }

    // MARK: - SortOrder Tests

    func testSortOrderSQLFragments() {
        XCTAssertEqual(SortOrder.archivedDateDescending.sqlFragment, "archivedDate DESC")
        XCTAssertEqual(SortOrder.archivedDateAscending.sqlFragment, "archivedDate ASC")
        XCTAssertEqual(SortOrder.originalDateDescending.sqlFragment, "originalDate DESC NULLS LAST")
        XCTAssertEqual(SortOrder.originalDateAscending.sqlFragment, "originalDate ASC NULLS LAST")
        XCTAssertEqual(SortOrder.authorAscending.sqlFragment, "author ASC NULLS LAST")
        XCTAssertEqual(SortOrder.platformAscending.sqlFragment, "platform ASC")
    }

    func testSortOrderDisplayNames() {
        XCTAssertEqual(SortOrder.archivedDateDescending.displayName, "Newest archived")
        XCTAssertEqual(SortOrder.archivedDateAscending.displayName, "Oldest archived")
        XCTAssertEqual(SortOrder.originalDateDescending.displayName, "Newest created")
        XCTAssertEqual(SortOrder.originalDateAscending.displayName, "Oldest created")
        XCTAssertEqual(SortOrder.authorAscending.displayName, "Author A-Z")
        XCTAssertEqual(SortOrder.platformAscending.displayName, "Platform A-Z")
    }

    func testSortOrderRawValues() {
        XCTAssertEqual(SortOrder(rawValue: "archived_desc"), .archivedDateDescending)
        XCTAssertEqual(SortOrder(rawValue: "archived_asc"), .archivedDateAscending)
        XCTAssertEqual(SortOrder(rawValue: "original_desc"), .originalDateDescending)
        XCTAssertEqual(SortOrder(rawValue: "original_asc"), .originalDateAscending)
        XCTAssertEqual(SortOrder(rawValue: "author_asc"), .authorAscending)
        XCTAssertEqual(SortOrder(rawValue: "platform_asc"), .platformAscending)
        XCTAssertNil(SortOrder(rawValue: "invalid"))
    }

    // MARK: - PlatformFilter Tests

    func testPlatformFilterPresets() {
        XCTAssertEqual(PlatformFilter.twitter, .equals("twitter"))
        XCTAssertEqual(PlatformFilter.instagram, .equals("instagram"))
        XCTAssertEqual(PlatformFilter.reddit, .equals("reddit"))
        XCTAssertEqual(PlatformFilter.youtube, .equals("youtube"))
    }

    func testPlatformFilterDescriptions() {
        XCTAssertEqual(PlatformFilter.equals("twitter").description, "is Twitter")
        XCTAssertEqual(PlatformFilter.equals("googlearts").description, "is Google Arts")
        XCTAssertEqual(PlatformFilter.oneOf(["bsky", "youtube"]).description, "is one of: Bluesky, YouTube")
        XCTAssertEqual(PlatformFilter.oneOf(["a", "b"]).description, "is one of: A, B")
    }

    // MARK: - StringFilter Tests

    func testStringFilterDescriptions() {
        XCTAssertEqual(StringFilter.equals("test").description, "is \"test\"")
        XCTAssertEqual(StringFilter.contains("test").description, "contains \"test\"")
        XCTAssertEqual(StringFilter.startsWith("test").description, "starts with \"test\"")
        XCTAssertEqual(StringFilter.isEmpty.description, "is empty")
        XCTAssertEqual(StringFilter.isNotEmpty.description, "is not empty")
    }

    // MARK: - DateRangeFilter Tests

    func testDateRangeFilterDescriptions() {
        let filter1 = DateRangeFilter(field: .archived, range: .lastNDays(7))
        XCTAssertEqual(filter1.description, "Archived in last 7 days")

        let filter2 = DateRangeFilter(field: .original, range: .thisMonth)
        XCTAssertEqual(filter2.description, "Created this month")

        let filter3 = DateRangeFilter(field: .archived, range: .thisYear)
        XCTAssertEqual(filter3.description, "Archived this year")
    }

    // MARK: - GRDB Record Tests

    func testSmartFolderRecordRoundtrip() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try SmartFolder.createTable(in: db)

            let original = SmartFolder(
                name: "Test Folder",
                icon: "star.fill",
                rules: [
                    .platform(.twitter),
                    .starred(true),
                    .hasVideo(false)
                ],
                matchAll: true,
                sortOrder: .originalDateDescending
            )

            try original.insert(db)

            let fetched = try SmartFolder.fetchOne(db)
            XCTAssertNotNil(fetched)
            XCTAssertEqual(fetched?.id, original.id)
            XCTAssertEqual(fetched?.name, "Test Folder")
            XCTAssertEqual(fetched?.icon, "star.fill")
            XCTAssertEqual(fetched?.rules.count, 3)
            XCTAssertTrue(fetched?.matchAll ?? false)
            XCTAssertEqual(fetched?.sortOrder, .originalDateDescending)
        }
    }

    func testSmartFolderRulesSerializationDeserialization() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try SmartFolder.createTable(in: db)

            let rules: [FilterRule] = [
                .platform(.equals("twitter")),
                .author(.contains("test")),
                .dateRange(DateRangeFilter(field: .archived, range: .lastNDays(30))),
                .hasText(.isNotEmpty),
                .colorBucket(.red),
                .starred(true),
                .hasTag("art"),
                .tagsEmpty,
                .hasNotes(true),
                .hasVideo(true),
                .hasContextImage(true),
                .parseStatus(.hasIssues),
                .isMetadataOnly(false),
                .isProcessed(true)
            ]

            let folder = SmartFolder(name: "All Rules", rules: rules)
            try folder.insert(db)

            let fetched = try SmartFolder.fetchOne(db)
            XCTAssertNotNil(fetched)
            XCTAssertEqual(fetched?.rules.count, rules.count)

            // Verify each rule type survived serialization
            let fetchedRules = fetched!.rules
            XCTAssertTrue(fetchedRules.contains { if case .platform = $0 { return true } else { return false } })
            XCTAssertTrue(fetchedRules.contains { if case .author = $0 { return true } else { return false } })
            XCTAssertTrue(fetchedRules.contains { if case .dateRange = $0 { return true } else { return false } })
            XCTAssertTrue(fetchedRules.contains { if case .hasText = $0 { return true } else { return false } })
            XCTAssertTrue(fetchedRules.contains { if case .colorBucket = $0 { return true } else { return false } })
            XCTAssertTrue(fetchedRules.contains { if case .starred = $0 { return true } else { return false } })
            XCTAssertTrue(fetchedRules.contains { if case .hasTag = $0 { return true } else { return false } })
            XCTAssertTrue(fetchedRules.contains { if case .tagsEmpty = $0 { return true } else { return false } })
            XCTAssertTrue(fetchedRules.contains { if case .hasNotes = $0 { return true } else { return false } })
            XCTAssertTrue(fetchedRules.contains { if case .hasVideo = $0 { return true } else { return false } })
            XCTAssertTrue(fetchedRules.contains { if case .hasContextImage = $0 { return true } else { return false } })
            XCTAssertTrue(fetchedRules.contains { if case .parseStatus = $0 { return true } else { return false } })
            XCTAssertTrue(fetchedRules.contains { if case .isMetadataOnly = $0 { return true } else { return false } })
            XCTAssertTrue(fetchedRules.contains { if case .isProcessed = $0 { return true } else { return false } })
        }
    }

    func testSmartFolderUpdate() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try SmartFolder.createTable(in: db)

            var folder = SmartFolder(
                name: "Original",
                rules: [.starred(true)]
            )
            try folder.insert(db)

            folder.name = "Updated"
            folder.rules = [.starred(false), .hasVideo(true)]
            try folder.update(db)

            let fetched = try SmartFolder.fetchOne(db)
            XCTAssertEqual(fetched?.name, "Updated")
            XCTAssertEqual(fetched?.rules.count, 2)
        }
    }

    func testSmartFolderDelete() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try SmartFolder.createTable(in: db)

            let folder = SmartFolder(name: "ToDelete", rules: [.starred(true)])
            try folder.insert(db)

            XCTAssertEqual(try SmartFolder.fetchCount(db), 1)

            try folder.delete(db)

            XCTAssertEqual(try SmartFolder.fetchCount(db), 0)
        }
    }

    // MARK: - Equatable Tests

    func testSmartFolderEquality() {
        let id = UUID()
        let date = Date()

        let folder1 = SmartFolder(
            id: id,
            name: "Test",
            icon: "star",
            rules: [.starred(true)],
            matchAll: true,
            sortOrder: .archivedDateDescending,
            createdAt: date,
            updatedAt: date
        )

        let folder2 = SmartFolder(
            id: id,
            name: "Test",
            icon: "star",
            rules: [.starred(true)],
            matchAll: true,
            sortOrder: .archivedDateDescending,
            createdAt: date,
            updatedAt: date
        )

        XCTAssertEqual(folder1, folder2)
    }

    func testFilterRuleEquality() {
        XCTAssertEqual(FilterRule.starred(true), FilterRule.starred(true))
        XCTAssertNotEqual(FilterRule.starred(true), FilterRule.starred(false))
        XCTAssertEqual(FilterRule.platform(.twitter), FilterRule.platform(.equals("twitter")))
        XCTAssertEqual(FilterRule.hasTag("art"), FilterRule.hasTag("art"))
        XCTAssertNotEqual(FilterRule.hasTag("art"), FilterRule.hasTag("meme"))
    }

    func testFilterRuleHashable() {
        var set: Set<FilterRule> = []
        set.insert(.starred(true))
        set.insert(.starred(true))
        set.insert(.starred(false))

        XCTAssertEqual(set.count, 2)
    }
}

// MARK: - ParseStatusFilter Tests

extension SmartFolderTests {

    func testParseStatusFilterDescriptions() {
        XCTAssertEqual(ParseStatusFilter.equals(.success).description, "is success")
        XCTAssertEqual(ParseStatusFilter.equals(.partial).description, "is partial")
        XCTAssertEqual(ParseStatusFilter.equals(.failed).description, "is failed")
        XCTAssertEqual(ParseStatusFilter.notEquals(.success).description, "is not success")
        XCTAssertEqual(ParseStatusFilter.hasIssues.description, "has issues")
    }
}
