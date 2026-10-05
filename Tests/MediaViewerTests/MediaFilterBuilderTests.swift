import XCTest
@testable import MediaViewer

final class MediaFilterBuilderTests: XCTestCase {
    func testRecentlyDeletedBaseFilterNeverHidesRecoveryRowsByContentFlags() throws {
        let filter = try XCTUnwrap(
            MediaFilterBuilder.makeBaseFilter(
                sidebarSelection: .recentlyDeleted,
                activeSmartFolder: nil,
                unsupportedSelectionBehavior: .keepUnfiltered
            )
        )
        XCTAssertEqual(filter.deletionScope, .deletedOnly)
        XCTAssertFalse(filter.hideJunk)
        XCTAssertFalse(filter.hideSafetyFlagged)
    }

    func testParseSearchInputSeparatesStructuredFiltersFromFreeText() {
        let parsed = MediaFilterBuilder.parseSearchInput(
            "platform:bsky tag:Art recent:7d sunset painting"
        )

        XCTAssertEqual(parsed.platform, "bsky")
        XCTAssertEqual(parsed.tags, ["art"])
        XCTAssertEqual(parsed.recentDays, 7)
        XCTAssertEqual(parsed.freeText, "sunset painting")
    }

    func testParseSearchInputSupportsVideoAndUntaggedTokens() {
        let parsed = MediaFilterBuilder.parseSearchInput("type:video tags:none")

        XCTAssertEqual(parsed.fileExtensions, ["mp4", "mov", "webm", "m4v", "avi", "mkv"])
        XCTAssertEqual(parsed.tagsEmpty, true)
        XCTAssertEqual(parsed.freeText, "")
    }

    func testParseSearchInputSupportsNegativeAndExactTagFilters() {
        let parsed = MediaFilterBuilder.parseSearchInput(
            "tag:reference -tag:spoilers tag-only:art -tag-only:drafts"
        )

        XCTAssertEqual(parsed.tags, ["reference"])
        XCTAssertEqual(parsed.tagFilters, [
            TagFilter(name: "spoilers", polarity: .exclude, scope: .subtree),
            TagFilter(name: "art", polarity: .include, scope: .exact),
            TagFilter(name: "drafts", polarity: .exclude, scope: .exact),
        ])
        XCTAssertTrue(parsed.freeText.isEmpty)
    }

    func testParseSearchInputSupportsAuthorAndFileTypeTokens() {
        let parsed = MediaFilterBuilder.parseSearchInput("author:@samplegif source:twitter.com ext:gif type:webm")

        XCTAssertEqual(parsed.authorQuery, "@samplegif")
        XCTAssertEqual(parsed.sourceQuery, "twitter.com")
        XCTAssertEqual(parsed.fileExtensions, ["gif", "webm"])
        XCTAssertEqual(parsed.freeText, "")
    }

    func testParseSearchInputSupportsFileTypeAliases() {
        let parsed = MediaFilterBuilder.parseSearchInput("type:image type:audio type:pdf/document type:gif")

        XCTAssertTrue(parsed.fileExtensions.contains("jpg"))
        XCTAssertTrue(parsed.fileExtensions.contains("png"))
        XCTAssertTrue(parsed.fileExtensions.contains("mp3"))
        XCTAssertTrue(parsed.fileExtensions.contains("m4a"))
        XCTAssertTrue(parsed.fileExtensions.contains("pdf"))
        XCTAssertTrue(parsed.fileExtensions.contains("docx"))
        XCTAssertEqual(parsed.fileExtensions.filter { $0 == "gif" }.count, 1)
        XCTAssertEqual(parsed.freeText, "")
    }

    func testParseSearchInputSupportsSlashSeparatedTypeValues() {
        let parsed = MediaFilterBuilder.parseSearchInput("type:pdf/document")

        XCTAssertEqual(parsed.fileExtensions, ["pdf", "doc", "docx", "rtf", "txt"])
        XCTAssertEqual(parsed.freeText, "")
    }

    func testParseSearchInputSupportsAspectRatioTokens() {
        let parsed = MediaFilterBuilder.parseSearchInput("ratio:16:9")

        XCTAssertNotNil(parsed.aspectRatio)
        XCTAssertEqual(parsed.aspectRatio?.min ?? 0, 1.724, accuracy: 0.01)
        XCTAssertEqual(parsed.aspectRatio?.max ?? 0, 1.831, accuracy: 0.01)
        XCTAssertEqual(parsed.freeText, "")
    }

    func testParseSearchInputSupportsQuotedFieldQueriesAndQuotedFreeText() {
        let parsed = MediaFilterBuilder.parseSearchInput("ocr:\"dance major\" notes:\"revisit later\" \"sunset painting\"")

        XCTAssertEqual(parsed.ocrQuery, "dance major")
        XCTAssertEqual(parsed.notesQuery, "revisit later")
        XCTAssertEqual(parsed.freeText, "\"sunset painting\"")
    }

    func testIsSearchTextEligibleUsesResidualFreeText() {
        XCTAssertFalse(MediaFilterBuilder.isSearchTextEligible("platform:twitter"))
        XCTAssertTrue(MediaFilterBuilder.isSearchTextEligible("platform:twitter sunset"))
    }

    func testApplySearchAppliesStructuredFiltersAndFreeText() async throws {
        var filter = FilterState()

        _ = try await MediaFilterBuilder.applySearch(
            to: &filter,
            filterText: "platform:twitter tag:art recent:7d sunset",
            searchScope: .notesOnly,
            allowVisualSearch: false
        )

        XCTAssertEqual(filter.platform, "twitter")
        XCTAssertEqual(filter.tags, ["art"])
        XCTAssertEqual(filter.dateRange, DateRangeFilter(field: .archived, range: .lastNDays(7)))
        XCTAssertEqual(filter.searchText, "sunset")
        XCTAssertEqual(filter.searchScope, .notesOnly)
    }

    func testApplySearchAppliesAuthorAndFileExtensionFilters() async throws {
        var filter = FilterState()

        _ = try await MediaFilterBuilder.applySearch(
            to: &filter,
            filterText: "author:@artist source:example.com ext:jpg,png ratio:square",
            searchScope: .all,
            allowVisualSearch: false
        )

        XCTAssertEqual(filter.authorQuery, "@artist")
        XCTAssertEqual(filter.sourceQuery, "example.com")
        XCTAssertEqual(filter.fileExtensions, ["jpg", "png"])
        XCTAssertEqual(filter.aspectRatio, AspectRatioFilter(min: 0.9, max: 1.1))
        XCTAssertTrue(filter.searchText.isEmpty)
    }

    func testApplySearchCombinesPositiveAndNegativeTagFilters() async throws {
        var filter = FilterState()

        _ = try await MediaFilterBuilder.applySearch(
            to: &filter,
            filterText: "tag:art -tag:spoilers tag-only:art",
            searchScope: .all,
            allowVisualSearch: false
        )

        XCTAssertEqual(filter.tags, ["art"])
        XCTAssertEqual(filter.tagFilters, [
            TagFilter(name: "spoilers", polarity: .exclude, scope: .subtree),
            TagFilter(name: "art", polarity: .include, scope: .exact),
        ])
    }

    func testApplySearchAppliesQuotedOCRAndNotesFilters() async throws {
        var filter = FilterState()

        _ = try await MediaFilterBuilder.applySearch(
            to: &filter,
            filterText: "ocr:\"dance major\" notes:\"save for later\"",
            searchScope: .all,
            allowVisualSearch: false
        )

        XCTAssertEqual(filter.ocrQuery, "dance major")
        XCTAssertEqual(filter.notesQuery, "save for later")
        XCTAssertTrue(filter.searchText.isEmpty)
    }

    func testMakeBaseFilterAppliesFolderYearSelection() throws {
        let filter = try XCTUnwrap(MediaFilterBuilder.makeBaseFilter(
            sidebarSelection: .folderYear("2026"),
            activeSmartFolder: nil,
            unsupportedSelectionBehavior: .returnEmpty
        ))

        XCTAssertEqual(filter.folderPath, "2026-")
    }

    func testFilterStateCompositionOrderCombinesBaseNarrowingSearchSortAndPagination() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_086_400)
        var filter = try XCTUnwrap(MediaFilterBuilder.makeBaseFilter(
            sidebarSelection: .folderYear("2026"),
            activeSmartFolder: nil,
            unsupportedSelectionBehavior: .returnEmpty
        ))

        MediaFilterBuilder.applyCommonFilters(
            to: &filter,
            dateRangeFilter: start...end,
            colorFilters: [.red],
            colorSearchRGB: ColorSearchRGB(r: 255, g: 0, b: 0, tolerance: 8),
            starredFilter: true,
            hasOCRFilter: true,
            platformFilter: "twitter",
            hideJunk: false,
            hideSafetyFlagged: false
        )

        _ = try await MediaFilterBuilder.applySearch(
            to: &filter,
            filterText: "ocr:\"invoice\" author:@alice sunset",
            searchScope: .ocrOnly,
            allowVisualSearch: false
        )

        filter.sortOrder = .authorAscending
        filter.shuffleSeed = 42
        filter.limit = 100
        filter.offset = 200

        XCTAssertEqual(filter.folderPath, "2026-")
        XCTAssertEqual(filter.dateRange, DateRangeFilter(field: .archived, range: .between(start, end)))
        XCTAssertEqual(filter.colorFilters, [.red])
        XCTAssertEqual(filter.colorSearchRGB, ColorSearchRGB(r: 255, g: 0, b: 0, tolerance: 8))
        XCTAssertEqual(filter.starred, true)
        XCTAssertEqual(filter.hasOCR, true)
        XCTAssertEqual(filter.platform, "twitter")
        XCTAssertEqual(filter.authorQuery, "@alice")
        XCTAssertEqual(filter.ocrQuery, "invoice")
        XCTAssertEqual(filter.searchText, "sunset")
        XCTAssertEqual(filter.searchScope, .ocrOnly)
        XCTAssertEqual(filter.sortOrder, .authorAscending)
        XCTAssertEqual(filter.shuffleSeed, 42)
        XCTAssertEqual(filter.limit, 100)
        XCTAssertEqual(filter.offset, 200)
        XCTAssertFalse(filter.hideJunk)
        XCTAssertFalse(filter.hideSafetyFlagged)
    }
}
