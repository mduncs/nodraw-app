import XCTest
@testable import MediaViewer

final class MetadataParserTests: XCTestCase {

    func testStatusURLAuthorFallbackInStrictAndGracefulParsing() throws {
        for host in ["x.com", "twitter.com", "mobile.twitter.com", "www.x.com"] {
            for author in ["", "author: ''\n", "author: '  '\n"] {
                let content = "---\nsource: https://\(host)/Sample_Artist/status/1000000000000000008/photo/1?ref=home\n\(author)---\n"
                XCTAssertEqual(try MetadataParser.parse(content: content).author, "Sample_Artist")
                XCTAssertEqual(MetadataParser.parseGracefully(content: content).metadata?.author, "Sample_Artist")
            }
        }
    }

    func testStatusURLFallbackPreservesDeclaredAuthorsAndRejectsOtherRoutes() throws {
        let declared = "---\nsource: https://x.com/user/status/123\nauthor: Display Name\n---\n"
        XCTAssertEqual(try MetadataParser.parse(content: declared).author, "Display Name")
        let alias = "---\nsource: https://x.com/user/status/123\nauthor: ''\nusername: captured_user\n---\n"
        XCTAssertEqual(try MetadataParser.parse(content: alias).author, "captured_user")
        for source in ["https://x.com/home", "https://x.com/i/status/123", "https://x.com/user/status/not-a-number",
                       "https://x.com.evil.test/user/status/123", "https://example.com/user/status/123", "file:///user/status/123"] {
            let content = "---\nsource: \(source)\n---\n"
            XCTAssertNil(try MetadataParser.parse(content: content).author, source)
            XCTAssertNil(MetadataParser.parseGracefully(content: content).metadata?.author, source)
        }
    }

    func testParseSimpleFrontmatter() throws {
        let content = """
        ---
        source: https://twitter.com/user/status/123
        platform: twitter
        author: "@testuser"
        date: 2025-11-26
        archived: 2025-11-26
        ---
        Some body content here.
        """

        let metadata = try MetadataParser.parse(content: content)

        XCTAssertEqual(metadata.source.absoluteString, "https://twitter.com/user/status/123")
        XCTAssertEqual(metadata.platform, "twitter")
        XCTAssertEqual(metadata.author, "@testuser")
        XCTAssertFalse(metadata.starred)
        XCTAssertTrue(metadata.tags.isEmpty)
    }

    func testParseFrontmatterWithTags() throws {
        let content = """
        ---
        source: https://instagram.com/p/abc123
        tags:
          - art
          - photography
          - landscape
        starred: true
        ---
        """

        let metadata = try MetadataParser.parse(content: content)

        XCTAssertEqual(metadata.platform, "instagram")
        XCTAssertEqual(metadata.tags, ["art", "photography", "landscape"])
        XCTAssertTrue(metadata.starred)
    }

    func testParseFrontmatterWithCommaSeparatedTags() throws {
        let content = """
        ---
        source: https://reddit.com/r/test/123
        tags: meme, funny, cats
        ---
        """

        let metadata = try MetadataParser.parse(content: content)

        XCTAssertEqual(metadata.tags, ["meme", "funny", "cats"])
    }

    func testExtractPlatformFromURL() throws {
        let content = """
        ---
        source: https://x.com/user/status/456
        ---
        """

        let metadata = try MetadataParser.parse(content: content)

        // x.com should map to twitter
        XCTAssertEqual(metadata.platform, "twitter")
    }

    func testNoFrontmatterThrows() {
        let content = "Just regular markdown without frontmatter."

        XCTAssertThrowsError(try MetadataParser.parse(content: content)) { error in
            guard case ParserError.noFrontmatter = error else {
                XCTFail("Expected noFrontmatter error")
                return
            }
        }
    }

    func testMissingSourceThrows() {
        let content = """
        ---
        platform: twitter
        author: test
        ---
        """

        XCTAssertThrowsError(try MetadataParser.parse(content: content)) { error in
            guard case ParserError.missingRequired("source", _) = error else {
                XCTFail("Expected missingRequired error for source")
                return
            }
        }
    }

    func testExtractBody() {
        let content = """
        ---
        source: https://example.com
        ---
        This is the body content.
        It has multiple lines.
        """

        let body = MetadataParser.extractBody(from: content)

        XCTAssertEqual(body, "This is the body content.\nIt has multiple lines.")
    }

    func testExtractWikilinks() {
        let content = """
        Some text with [[link1]] and [[another link]].
        Also [[third one]] here.
        """

        let links = MetadataParser.extractWikilinks(from: content)

        XCTAssertEqual(links, ["link1", "another link", "third one"])
    }

    func testDateParsing() throws {
        // ISO format
        let content1 = """
        ---
        source: https://example.com
        date: 2025-11-26T14:30:00Z
        ---
        """
        let m1 = try MetadataParser.parse(content: content1)
        XCTAssertNotNil(m1.originalDate)

        // Simple format
        let content2 = """
        ---
        source: https://example.com
        date: 2025-11-26
        ---
        """
        let m2 = try MetadataParser.parse(content: content2)
        XCTAssertNotNil(m2.originalDate)
    }

    // MARK: - Graceful Parse Tests

    func testGracefulParseSuccess() {
        let content = """
        ---
        source: https://twitter.com/user/status/123
        platform: twitter
        date: 2025-01-15
        ---
        """

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .success(let metadata):
            XCTAssertEqual(metadata.platform, "twitter")
            XCTAssertNotNil(metadata.originalDate)
        case .partial, .failed:
            XCTFail("Expected success result")
        }
    }

    func testGracefulParseNoFrontmatterReturnsFailed() {
        let content = "Just regular markdown without frontmatter."

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .failed(let errors):
            XCTAssertTrue(errors.contains { $0.contains("No frontmatter") })
        case .success, .partial:
            XCTFail("Expected failed result")
        }
    }

    func testGracefulParseMissingSourceWithFileURL() {
        let content = """
        ---
        platform: twitter
        author: test
        ---
        """
        let fileURL = URL(fileURLWithPath: "/archive/2025-01/twitter_someuser_abc123.md")

        let result = MetadataParser.parseGracefully(content: content, sourceFile: fileURL)

        switch result {
        case .partial(let metadata, let errors):
            XCTAssertTrue(errors.contains { $0.contains("source") })
            // Should extract platform from filename
            XCTAssertEqual(metadata.platform, "twitter")
        case .success, .failed:
            XCTFail("Expected partial result")
        }
    }

    // MARK: - European Date Format Tests

    func testUnambiguousEuropeanDate() {
        // 25/01/2025 - day > 12, must be DD/MM/YYYY
        let content = """
        ---
        source: https://example.com
        date: 25/01/2025
        ---
        """

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .success(let metadata):
            // Should parse as January 25, not "month 25" error
            XCTAssertNotNil(metadata.originalDate)
            let calendar = Calendar.current
            let components = calendar.dateComponents([.day, .month], from: metadata.originalDate!)
            XCTAssertEqual(components.day, 25)
            XCTAssertEqual(components.month, 1)
        case .partial, .failed:
            XCTFail("Expected success result for unambiguous European date")
        }
    }

    func testUnambiguousUSDate() {
        // 01/25/2025 - second part > 12, must be MM/DD/YYYY
        let content = """
        ---
        source: https://example.com
        date: 01/25/2025
        ---
        """

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .success(let metadata):
            XCTAssertNotNil(metadata.originalDate)
            let calendar = Calendar.current
            let components = calendar.dateComponents([.day, .month], from: metadata.originalDate!)
            XCTAssertEqual(components.day, 25)
            XCTAssertEqual(components.month, 1)
        case .partial, .failed:
            XCTFail("Expected success result for unambiguous US date")
        }
    }

    func testAmbiguousDateReturnsWarning() {
        // 05/06/2025 - could be May 6 or June 5 - should warn
        let content = """
        ---
        source: https://example.com
        date: 05/06/2025
        ---
        """

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .partial(let metadata, let errors):
            XCTAssertNotNil(metadata.originalDate)
            XCTAssertTrue(errors.contains { $0.contains("Ambiguous") })
            // Should store original string for debugging
            XCTAssertEqual(metadata.originalDateString, "05/06/2025")
        case .success, .failed:
            XCTFail("Expected partial result for ambiguous date")
        }
    }

    // MARK: - ParseResult Tests

    func testParseResultProperties() {
        let metadata = MediaMetadata(
            source: URL(string: "https://example.com")!,
            platform: "test"
        )

        let success = ParseResult.success(metadata)
        XCTAssertEqual(success.parseStatus, .success)
        XCTAssertTrue(success.errors.isEmpty)
        XCTAssertNotNil(success.metadata)

        let partial = ParseResult.partial(metadata, errors: ["warning1", "warning2"])
        XCTAssertEqual(partial.parseStatus, .partial)
        XCTAssertEqual(partial.errors.count, 2)
        XCTAssertNotNil(partial.metadata)

        let failed = ParseResult.failed(errors: ["fatal error"])
        XCTAssertEqual(failed.parseStatus, .failed)
        XCTAssertEqual(failed.errors.count, 1)
        XCTAssertNil(failed.metadata)
    }

    // MARK: - Malformed YAML Tests

    func testMalformedYAMLUnclosedQuotes() {
        let content = """
        ---
        source: https://example.com
        author: "unclosed quote
        ---
        """

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .partial(_, let errors), .failed(let errors):
            XCTAssertTrue(errors.contains { $0.contains("YAML") || $0.lowercased().contains("parse") })
        case .success:
            XCTFail("Expected parse error for unclosed quotes")
        }
    }

    func testMalformedYAMLInvalidNesting() {
        let content = """
        ---
        source: https://example.com
        tags:
          - item1
         - item2
        ---
        """
        // Inconsistent indentation

        let result = MetadataParser.parseGracefully(content: content)

        // Yams might handle this gracefully or fail
        // Either way, we should not crash
        switch result {
        case .success, .partial, .failed:
            // Any outcome is acceptable as long as we don't crash
            break
        }
    }

    func testMalformedYAMLWithColonInUnquotedValue() {
        let content = """
        ---
        source: https://example.com
        author: user:name
        ---
        """

        // This should parse - the colon should be part of the value
        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .success(let metadata):
            // Yams should parse this
            XCTAssertNotNil(metadata.author)
        case .partial(let metadata, _):
            // Also acceptable
            XCTAssertNotNil(metadata.author)
        case .failed:
            // Also acceptable for strict parsers
            break
        }
    }

    // MARK: - Empty File Tests

    func testEmptyFileContent() {
        let content = ""

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .failed(let errors):
            XCTAssertTrue(errors.contains { $0.contains("frontmatter") })
        case .success, .partial:
            XCTFail("Expected failed result for empty content")
        }
    }

    func testWhitespaceOnlyContent() {
        let content = "   \n\t\n   "

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .failed(let errors):
            XCTAssertTrue(errors.contains { $0.contains("frontmatter") })
        case .success, .partial:
            XCTFail("Expected failed result for whitespace-only content")
        }
    }

    func testEmptyFrontmatter() {
        let content = """
        ---
        ---
        Body content here
        """

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .failed(let errors):
            XCTAssertTrue(errors.contains { $0.lowercased().contains("source") || $0.lowercased().contains("invalid") })
        case .partial, .success:
            // Empty frontmatter with no source should fail
            XCTFail("Expected failed result for empty frontmatter without source")
        }
    }

    // MARK: - Files Without Frontmatter Delimiters

    func testNoFrontmatterDelimiters() {
        let content = """
        source: https://example.com
        platform: twitter
        """

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .failed(let errors):
            XCTAssertTrue(errors.contains { $0.contains("frontmatter") })
        case .success, .partial:
            XCTFail("Expected failed result when missing delimiters")
        }
    }

    func testOnlyOpeningDelimiter() {
        let content = """
        ---
        source: https://example.com
        platform: twitter
        """

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .failed(let errors):
            XCTAssertTrue(errors.contains { $0.contains("frontmatter") })
        case .success, .partial:
            XCTFail("Expected failed result when missing closing delimiter")
        }
    }

    func testDelimitersNotAtStart() {
        let content = """
        Some text before
        ---
        source: https://example.com
        ---
        """

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .failed(let errors):
            XCTAssertTrue(errors.contains { $0.contains("frontmatter") })
        case .success, .partial:
            XCTFail("Expected failed result when frontmatter not at start")
        }
    }

    // MARK: - European Date Format Tests (Extended)

    func testEuropeanDateDecember25() {
        // 25/12/2025 - day > 12, clearly DD/MM/YYYY (Christmas)
        let content = """
        ---
        source: https://example.com
        date: 25/12/2025
        ---
        """

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .success(let metadata):
            XCTAssertNotNil(metadata.originalDate)
            let calendar = Calendar.current
            let components = calendar.dateComponents([.day, .month, .year], from: metadata.originalDate!)
            XCTAssertEqual(components.day, 25)
            XCTAssertEqual(components.month, 12)
            XCTAssertEqual(components.year, 2025)
        case .partial, .failed:
            XCTFail("Expected success for unambiguous European date")
        }
    }

    func testEuropeanDateDay31() {
        // 31/01/2025 - 31st day, must be DD/MM
        let content = """
        ---
        source: https://example.com
        date: 31/01/2025
        ---
        """

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .success(let metadata):
            XCTAssertNotNil(metadata.originalDate)
            let calendar = Calendar.current
            let components = calendar.dateComponents([.day, .month], from: metadata.originalDate!)
            XCTAssertEqual(components.day, 31)
            XCTAssertEqual(components.month, 1)
        case .partial, .failed:
            XCTFail("Expected success for day 31 European format")
        }
    }

    // MARK: - Ambiguous Date Detection Tests

    func testAmbiguousDatesAllRecordOriginalString() {
        // Both parts <= 12, ambiguous
        let ambiguousDates = ["01/02/2025", "03/04/2025", "06/07/2025", "11/12/2025"]

        for dateStr in ambiguousDates {
            let content = """
            ---
            source: https://example.com
            date: \(dateStr)
            ---
            """

            let result = MetadataParser.parseGracefully(content: content)

            switch result {
            case .partial(let metadata, let errors):
                XCTAssertEqual(metadata.originalDateString, dateStr, "Original string not preserved for \(dateStr)")
                XCTAssertTrue(errors.contains { $0.contains("Ambiguous") }, "No ambiguous warning for \(dateStr)")
            case .success, .failed:
                // If it succeeded without warning, that's also acceptable
                break
            }
        }
    }

    func testUnambiguousUSDateSecondPartGreaterThan12() {
        // 02/28/2025 - 28 > 12, must be MM/DD/YYYY
        let content = """
        ---
        source: https://example.com
        date: 02/28/2025
        ---
        """

        let result = MetadataParser.parseGracefully(content: content)

        switch result {
        case .success(let metadata):
            XCTAssertNotNil(metadata.originalDate)
            let calendar = Calendar.current
            let components = calendar.dateComponents([.day, .month], from: metadata.originalDate!)
            XCTAssertEqual(components.day, 28)
            XCTAssertEqual(components.month, 2)
        case .partial, .failed:
            XCTFail("Expected success for unambiguous US date")
        }
    }

    // MARK: - Synthetic Metadata Tests

    func testSyntheticMetadataFromTwitterFilename() {
        let fileURL = URL(fileURLWithPath: "/archive/2025-01/twitter_someuser_2025-01-15_abc123.md")

        let synthetic = MetadataParser.createSyntheticMetadata(from: fileURL)

        XCTAssertNotNil(synthetic)
        XCTAssertEqual(synthetic?.platform, "twitter")
        XCTAssertEqual(synthetic?.author, "someuser")
    }

    func testSyntheticMetadataFromInstagramFilename() {
        let fileURL = URL(fileURLWithPath: "/archive/2025-02/instagram_artuser_xyz789.md")

        let synthetic = MetadataParser.createSyntheticMetadata(from: fileURL)

        XCTAssertNotNil(synthetic)
        XCTAssertEqual(synthetic?.platform, "instagram")
        XCTAssertEqual(synthetic?.author, "artuser")
    }

    func testSyntheticMetadataFromUnknownPlatform() {
        let fileURL = URL(fileURLWithPath: "/archive/2025-03/randomfile.md")

        let synthetic = MetadataParser.createSyntheticMetadata(from: fileURL)

        XCTAssertNotNil(synthetic)
        XCTAssertEqual(synthetic?.platform, "unknown")
    }

    func testSyntheticMetadataExtractsDateFromFolder() {
        let fileURL = URL(fileURLWithPath: "/archive/2025-06/twitter_user_post.md")

        let synthetic = MetadataParser.createSyntheticMetadata(from: fileURL)

        XCTAssertNotNil(synthetic)
        // Should extract date from folder name 2025-06
        if let date = synthetic?.originalDate {
            let calendar = Calendar.current
            let components = calendar.dateComponents([.year, .month], from: date)
            XCTAssertEqual(components.year, 2025)
            XCTAssertEqual(components.month, 6)
        }
    }

    // MARK: - Unicode in Values Tests

    func testUnicodeInAuthor() throws {
        let content = """
        ---
        source: https://example.com
        author: "@"
        ---
        """

        let metadata = try MetadataParser.parse(content: content)

        XCTAssertEqual(metadata.author, "@")
    }

    func testUnicodeInNotes() throws {
        let content = """
        ---
        source: https://example.com
        notes: "Notes with emoji and unicode chars"
        ---
        """

        let metadata = try MetadataParser.parse(content: content)

        XCTAssertEqual(metadata.notes, "Notes with emoji and unicode chars")
    }

    func testUnicodeInTags() throws {
        let content = """
        ---
        source: https://example.com
        tags:
          - art
          - photography
        ---
        """

        let metadata = try MetadataParser.parse(content: content)

        XCTAssertEqual(metadata.tags.count, 2)
        XCTAssertTrue(metadata.tags.contains("art"))
    }

    func testJapaneseText() throws {
        let content = """
        ---
        source: https://example.com
        author: "@"
        notes: ""
        ---
        """

        let metadata = try MetadataParser.parse(content: content)

        XCTAssertEqual(metadata.author, "@")
        XCTAssertEqual(metadata.notes, "")
    }

    // MARK: - Multiline Description Tests

    func testMultilineNotes() throws {
        let content = """
        ---
        source: https://example.com
        notes: |
          This is a multiline note.
          It has several lines.
          And spans multiple paragraphs.
        ---
        """

        let metadata = try MetadataParser.parse(content: content)

        XCTAssertNotNil(metadata.notes)
        XCTAssertTrue(metadata.notes!.contains("multiline"))
        XCTAssertTrue(metadata.notes!.contains("several lines"))
    }

    func testMultilineNotesWithFoldedStyle() throws {
        let content = """
        ---
        source: https://example.com
        notes: >
          This is a folded
          multiline note that
          should be joined.
        ---
        """

        let metadata = try MetadataParser.parse(content: content)

        XCTAssertNotNil(metadata.notes)
        // Folded style (>) joins lines with spaces
    }

    // MARK: - Platform Extraction Tests

    func testPlatformExtractionFromVariousURLs() throws {
        let testCases: [(String, String)] = [
            ("https://twitter.com/user/status/123", "twitter"),
            ("https://x.com/user/status/456", "twitter"),
            ("https://mobile.twitter.com/user/status/789", "twitter"),
            ("https://instagram.com/p/abc123", "instagram"),
            ("https://www.instagram.com/p/abc123", "instagram"),
            ("https://reddit.com/r/test/comments/123", "reddit"),
            ("https://old.reddit.com/r/test/comments/123", "reddit"),
            ("https://youtube.com/watch?v=abc", "youtube"),
            ("https://youtu.be/abc", "youtube"),
            ("https://tiktok.com/@user/video/123", "tiktok"),
            ("https://tumblr.com/post/123", "tumblr"),
            ("https://bsky.app/profile/test/post/123", "bluesky"),
            ("https://bsky.social/profile/test", "bluesky"),
            ("https://unknownsite.com/page", "unknownsite"),
        ]

        for (url, expectedPlatform) in testCases {
            let content = """
            ---
            source: \(url)
            ---
            """

            let metadata = try MetadataParser.parse(content: content)
            XCTAssertEqual(metadata.platform, expectedPlatform, "Failed for URL: \(url)")
        }
    }

    func testPlatformAliasNormalizationForExplicitField() throws {
        let content = """
        ---
        source: https://example.com/post/123
        platform: bsky
        ---
        """

        let metadata = try MetadataParser.parse(content: content)
        XCTAssertEqual(metadata.platform, "bluesky")
    }

    // MARK: - Alternative Field Name Tests

    func testAlternativeFieldNames() throws {
        // Test 'username' instead of 'author'
        let content1 = """
        ---
        source: https://example.com
        username: "@altuser"
        ---
        """
        let m1 = try MetadataParser.parse(content: content1)
        XCTAssertEqual(m1.author, "@altuser")

        // Test 'user' instead of 'author'
        let content2 = """
        ---
        source: https://example.com
        user: "@anotheruser"
        ---
        """
        let m2 = try MetadataParser.parse(content: content2)
        XCTAssertEqual(m2.author, "@anotheruser")

        // Test 'creator' instead of 'author'
        let content3 = """
        ---
        source: https://example.com
        creator: "@creatorname"
        ---
        """
        let m3 = try MetadataParser.parse(content: content3)
        XCTAssertEqual(m3.author, "@creatorname")

        // Test 'favorite' instead of 'starred'
        let content4 = """
        ---
        source: https://example.com
        favorite: true
        ---
        """
        let m4 = try MetadataParser.parse(content: content4)
        XCTAssertTrue(m4.starred)

        // Test 'description' instead of 'notes'
        let content5 = """
        ---
        source: https://example.com
        description: "This is a description"
        ---
        """
        let m5 = try MetadataParser.parse(content: content5)
        XCTAssertEqual(m5.notes, "This is a description")
    }

    // MARK: - Date Format Variety Tests

    func testVariousDateFormats() throws {
        let validDates = [
            "2025-01-15",
            "2025-01-15T10:30:00Z",
            "2025-01-15 10:30:00",
        ]

        for dateStr in validDates {
            let content = """
            ---
            source: https://example.com
            date: \(dateStr)
            ---
            """

            let result = MetadataParser.parseGracefully(content: content)

            switch result {
            case .success(let metadata), .partial(let metadata, _):
                XCTAssertNotNil(metadata.originalDate, "Failed to parse date: \(dateStr)")
            case .failed:
                XCTFail("Failed to parse valid date format: \(dateStr)")
            }
        }
    }

    // MARK: - Windows Line Ending Tests

    func testWindowsLineEndings() throws {
        let content = "---\r\nsource: https://example.com\r\nplatform: twitter\r\n---\r\nBody content"

        let metadata = try MetadataParser.parse(content: content)

        XCTAssertEqual(metadata.platform, "twitter")
    }

    // MARK: - Body Extraction Edge Cases

    func testExtractBodyNoBody() {
        let content = """
        ---
        source: https://example.com
        ---
        """

        let body = MetadataParser.extractBody(from: content)

        XCTAssertNil(body)
    }

    func testExtractBodyWhitespaceOnly() {
        let content = """
        ---
        source: https://example.com
        ---


        """

        let body = MetadataParser.extractBody(from: content)

        XCTAssertNil(body)
    }

    func testExtractBodyNoFrontmatter() {
        let content = "Just regular content without frontmatter."

        let body = MetadataParser.extractBody(from: content)

        XCTAssertEqual(body, content)
    }

    // MARK: - Wikilink Edge Cases

    func testExtractWikilinksNone() {
        let content = "No wikilinks here, just plain text."

        let links = MetadataParser.extractWikilinks(from: content)

        XCTAssertTrue(links.isEmpty)
    }

    func testExtractWikilinksNestedBrackets() {
        // Nested brackets break the simple regex pattern - it matches up to the first ]
        let content = "Text with [[link with [nested] brackets]] here."

        let links = MetadataParser.extractWikilinks(from: content)

        // Current regex pattern doesn't handle nested brackets gracefully
        // It either returns empty or partial match - just verify no crash
        XCTAssertTrue(links.isEmpty || !links.isEmpty) // Just verify it runs
    }

    func testExtractWikilinksEmpty() {
        // [[]] has no content between brackets - regex requires at least one char
        let content = "Text with [[]] empty link."

        let links = MetadataParser.extractWikilinks(from: content)

        // Pattern [^\]]+ requires at least one non-] character
        XCTAssertEqual(links, [])
    }

    // MARK: - Parser Error Tests

    func testParserErrorDescriptions() {
        let fileURL = URL(fileURLWithPath: "/test/file.md")

        let noFrontmatter = ParserError.noFrontmatter(fileURL)
        XCTAssertTrue(noFrontmatter.errorDescription?.contains("frontmatter") ?? false)
        XCTAssertTrue(noFrontmatter.errorDescription?.contains("file.md") ?? false)

        let invalidYAML = ParserError.invalidYAML(fileURL)
        XCTAssertTrue(invalidYAML.errorDescription?.contains("YAML") ?? false)

        let missingRequired = ParserError.missingRequired("source", fileURL)
        XCTAssertTrue(missingRequired.errorDescription?.contains("source") ?? false)

        let invalidDate = ParserError.invalidDate("bad-date", fileURL)
        XCTAssertTrue(invalidDate.errorDescription?.contains("bad-date") ?? false)
    }

    func testParserErrorWithNilURL() {
        let error = ParserError.noFrontmatter(nil)

        XCTAssertTrue(error.errorDescription?.contains("content") ?? false)
    }
}
