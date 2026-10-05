import XCTest
@testable import MediaViewer

final class WorkbenchFilterContractTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkbenchFilters-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        store = MediaStore(database: database)
        let now = Date()
        let fixtures = [
            item("recent-twitter", platform: "twitter", folder: "2026-A", date: now),
            item("old-twitter", platform: "twitter", folder: "2026-B", date: now.addingTimeInterval(-20 * 86400)),
            item("recent-import", platform: "import", folder: "2026-A", date: now)
        ]
        try await store.insertItemsBatch(fixtures)
    }

    override func tearDown() async throws {
        store = nil
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func item(_ author: String, platform: String, folder: String, date: Date) -> MediaItem {
        let base = directory.appendingPathComponent(folder)
        return SampleData.createMediaItem(basePath: base,
            metadataFile: base.appendingPathComponent(author + ".md"),
            mediaFiles: [base.appendingPathComponent(author + ".jpg")],
            source: "https://example.com/\(author)", platform: platform,
            author: author, archivedDate: date, tags: [])
    }

    func testSidebarAndToolbarConflictHasZeroRowsAndZeroCount() async throws {
        var filter = try XCTUnwrap(MediaFilterBuilder.makeBaseFilter(sidebarSelection: .platform("twitter"),
            activeSmartFolder: nil, unsupportedSelectionBehavior: .returnEmpty))
        MediaFilterBuilder.applyCommonFilters(to: &filter, dateRangeFilter: nil, colorFilters: [], colorSearchRGB: nil,
            starredFilter: nil, hasOCRFilter: nil, platformFilter: "import")
        let rows = try await store.fetchItems(filter: filter)
        let count = try await store.countItems(filter: filter)
        XCTAssertTrue(rows.isEmpty, "An enabled Import constraint must not return Twitter rows")
        XCTAssertEqual(count, 0)

        var all = FilterState()
        MediaFilterBuilder.applyCommonFilters(to: &all, dateRangeFilter: nil, colorFilters: [], colorSearchRGB: nil,
            starredFilter: nil, hasOCRFilter: nil, platformFilter: "import")
        let control = try await store.fetchItems(filter: all)
        XCTAssertEqual(control.map(\.metadata.author), ["recent-import"])
    }

    func testSearchAndControlOrderCannotChangeTheAnswer() async throws {
        for searchFirst in [true, false] {
            var filter = FilterState()
            if searchFirst {
                _ = try await MediaFilterBuilder.applySearch(to: &filter, filterText: "platform:import", searchScope: .all, allowVisualSearch: false)
            }
            MediaFilterBuilder.applyCommonFilters(to: &filter, dateRangeFilter: nil, colorFilters: [], colorSearchRGB: nil,
                starredFilter: nil, hasOCRFilter: nil, platformFilter: "twitter")
            if !searchFirst {
                _ = try await MediaFilterBuilder.applySearch(to: &filter, filterText: "platform:import", searchScope: .all, allowVisualSearch: false)
            }
            let rows = try await store.fetchItems(filter: filter)
            let count = try await store.countItems(filter: filter)
            XCTAssertTrue(rows.isEmpty)
            XCTAssertEqual(count, rows.count)
        }
    }

    func testTypedFolderAndRecentAreAppliedInsideExistingScope() async throws {
        var folder = try XCTUnwrap(MediaFilterBuilder.makeBaseFilter(sidebarSelection: .folder("2026-A"),
            activeSmartFolder: nil, unsupportedSelectionBehavior: .returnEmpty))
        _ = try await MediaFilterBuilder.applySearch(to: &folder, filterText: "folder:2026-B", searchScope: .all, allowVisualSearch: false)
        let rows = try await store.fetchItems(filter: folder)
        XCTAssertTrue(rows.isEmpty)

        var dated = FilterState()
        let now = Date()
        MediaFilterBuilder.applyCommonFilters(to: &dated,
            dateRangeFilter: now.addingTimeInterval(-30 * 86400)...now.addingTimeInterval(-10 * 86400),
            colorFilters: [], colorSearchRGB: nil, starredFilter: nil, hasOCRFilter: nil, platformFilter: nil)
        _ = try await MediaFilterBuilder.applySearch(to: &dated, filterText: "recent:7d", searchScope: .all, allowVisualSearch: false)
        let datedRows = try await store.fetchItems(filter: dated)
        XCTAssertTrue(datedRows.isEmpty, "Recent query must not be silently shadowed by the timeline")
    }

    func testArchiveOptionTotalsReflectMutation() async throws {
        let before = try await store.fetchPlatformCounts()
        XCTAssertEqual(before["twitter"], 2)
        try await store.insertItemsBatch([item("new-import", platform: "import", folder: "2026-A", date: Date())])
        let after = try await store.fetchPlatformCounts()
        XCTAssertEqual(after["import"], 2)
    }

    func testEveryRepeatedConstraintDisplayedInTheSummaryIsApplied() async throws {
        for query in ["platform:twitter platform:import", "folder:2026-A folder:2026-B", "author:recent-twitter author:recent-import", "ratio:portrait ratio:landscape"] {
            var filter = FilterState()
            _ = try await MediaFilterBuilder.applySearch(to: &filter, filterText: query, searchScope: .all, allowVisualSearch: false)
            let rows = try await store.fetchItems(filter: filter)
            let count = try await store.countItems(filter: filter)
            XCTAssertTrue(rows.isEmpty, query)
            XCTAssertEqual(count, 0, query)
        }
        var recent = FilterState()
        _ = try await MediaFilterBuilder.applySearch(to: &recent, filterText: "recent:7d recent:30d", searchScope: .all, allowVisualSearch: false)
        let rows = try await store.fetchItems(filter: recent)
        XCTAssertEqual(rows.count, 2, "The wider last token must not replace the seven-day constraint")
    }

    func testRepeatedSourceTermsMatchIndependentlyAndIntersect() async throws {
        for query in [
            "source:example.com source:recent-twitter",
            "source:recent-twitter source:example.com"
        ] {
            var filter = FilterState()
            _ = try await MediaFilterBuilder.applySearch(
                to: &filter,
                filterText: query,
                searchScope: .all,
                allowVisualSearch: false
            )
            let rows = try await store.fetchItems(filter: filter)
            let count = try await store.countItems(filter: filter)
            XCTAssertEqual(rows.map(\.metadata.author), ["recent-twitter"], query)
            XCTAssertEqual(count, 1, query)
        }

        var contradiction = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &contradiction,
            filterText: "source:recent-twitter source:recent-import",
            searchScope: .all,
            allowVisualSearch: false
        )
        let contradictoryRows = try await store.fetchItems(filter: contradiction)
        let contradictoryCount = try await store.countItems(filter: contradiction)
        XCTAssertTrue(contradictoryRows.isEmpty)
        XCTAssertEqual(contradictoryCount, 0)
    }

    func testPlatformNameCanonicalizesAliasesAndCase() {
        XCTAssertEqual(MediaStore.canonicalPlatformName(" BSKY "), "bluesky")
        XCTAssertEqual(MediaStore.canonicalPlatformName(" INSTAGRAM "), "instagram")
    }

    func testPresentationRemovalPreservesQuotedTagsAndFreeText() {
        let text = "sunset tag-only:\"digital art\" platform:twitter recent:7d ratio:portrait tag:none"
        let tokens = LibraryFilterPresentation.tokens(in: text)
        XCTAssertEqual(tokens.count, 5)
        XCTAssertTrue(tokens.contains { $0.label == "Without tags" })
        let withoutPlatform = LibraryFilterPresentation.removing(keys: ["platform"], from: text)
        let parsed = MediaFilterBuilder.parseSearchInput(withoutPlatform)
        XCTAssertNil(parsed.platform)
        XCTAssertEqual(parsed.freeText, "sunset")
        XCTAssertEqual(parsed.tagFilters.first?.name, "digital art")
        XCTAssertEqual(parsed.tagsEmpty, true)
    }

    func testRemovingOneFormatFromCombinedQueryPreservesTheOthers() {
        let text = "sunset format:png,jpg ext:jpeg tag:\"digital art\""
        let updated = LibraryFilterPresentation.togglingExtensions("jpg,jpeg", in: text)
        let parsed = MediaFilterBuilder.parseSearchInput(updated)
        XCTAssertEqual(parsed.fileExtensions, ["png"])
        XCTAssertEqual(parsed.tags, ["digital art"])
        XCTAssertEqual(parsed.freeText, "sunset")
    }

    @MainActor
    func testDraftAppliesOneBackStepAndResetClearsEveryQueryConstraint() {
        let state = AppState()
        state.sidebarSelection = .platform("twitter")
        let original = LibraryFilterDraft(state)
        var draft = original
        draft.text = "tag:\"digital art\" type:image ext:png"
        draft.platform = "import"
        draft.apply(to: state)
        XCTAssertTrue(state.navigateBack())
        XCTAssertEqual(LibraryFilterDraft(state), original, "One popover edit should be one Back step")

        state.filterText = "word platform:import folder:test recent:7d ratio:portrait tag:none"
        state.dateRangeFilter = Date.distantPast...Date()
        state.starredFilter = false
        state.hasOCRFilter = false
        state.platformFilter = "import"
        state.colorSearchRGB = ColorSearchRGB(r: 10, g: 20, b: 30, tolerance: 10)
        XCTAssertTrue(state.hasLibrarySearchOrFilters)
        state.resetLibrarySearchAndFilters()
        XCTAssertFalse(state.hasLibrarySearchOrFilters)
        XCTAssertEqual(state.sidebarSelection, .platform("twitter"), "Reset is explicitly within the current destination")
    }
}
