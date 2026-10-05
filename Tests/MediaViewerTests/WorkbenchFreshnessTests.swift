import Combine
import XCTest
@testable import MediaViewer

/// Opus UI pass 02: surfaces that loaded once at launch must follow the archive,
/// and the empty-results escape hatch must be a single Back step.
@MainActor
final class WorkbenchFreshnessTests: XCTestCase {
    private final class DateBox { var dates: [Date] = [] }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testTimelineThatStartedEmptyPicksUpFirstArchivedDatesAndKeepsLaterZoom() async throws {
        let box = DateBox()
        let model = TimelineViewModel(dateLoader: { box.dates })
        let changes = PassthroughSubject<Void, Never>()
        model.observeArchiveChanges(changes.eraseToAnyPublisher(), debounce: .milliseconds(10))

        await model.loadTimelineData()
        XCTAssertNil(model.dataRange, "Empty archive at launch")
        XCTAssertTrue(model.buckets.isEmpty)

        let first = Date(timeIntervalSince1970: 1_780_000_000)
        let second = first.addingTimeInterval(3 * 86_400)
        box.dates = [second, first]
        changes.send(())
        try await waitUntil { model.dataRange != nil }

        XCTAssertEqual(model.dataRange, first...second, "First scan/import must replace 'No data' without relaunch")
        XCTAssertEqual(model.buckets.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(model.granularity, .day, "Data arriving after an empty start gets the automatic zoom")

        model.zoomOut()
        let chosen = model.granularity
        let third = second.addingTimeInterval(86_400)
        box.dates.append(third)
        changes.send(())
        try await waitUntil { model.dataRange?.upperBound == third }

        XCTAssertEqual(model.dataRange, first...third)
        XCTAssertEqual(model.buckets.reduce(0) { $0 + $1.count }, 3)
        XCTAssertEqual(model.granularity, chosen, "A later archive change must not override the user's zoom")
    }

    func testSidebarPlatformsAppearWhenArchiveGainsFirstItemsFromAPlatform() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkbenchFreshness-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        let store = MediaStore(database: database)

        let sidebar = SidebarViewModel()
        sidebar.configure(mediaStore: store, archivePath: directory)
        await sidebar.refreshCounts()
        XCTAssertTrue(sidebar.platforms.isEmpty)

        let base = directory.appendingPathComponent("2026")
        let items = ["reddit", "youtube", "youtube"].enumerated().map { index, platform in
            SampleData.createMediaItem(basePath: base,
                metadataFile: base.appendingPathComponent("\(index).md"),
                mediaFiles: [base.appendingPathComponent("\(index).jpg")],
                source: "https://example.com/\(index)", platform: platform,
                author: "author\(index)", archivedDate: Date(), tags: [])
        }
        try await store.insertItemsBatch(items)
        await sidebar.refreshCounts()

        let byName = Dictionary(uniqueKeysWithValues: sidebar.platforms.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["Reddit", "YouTube"], "Refresh, not relaunch, must add platform rows")
        XCTAssertEqual(byName["YouTube"]?.selection, .platform("youtube"), "Display casing must not leak into the query value")
        XCTAssertEqual(byName["YouTube"]?.count, 2)
        XCTAssertEqual(byName["Reddit"]?.count, 1)
    }

    func testBrowseAllMediaClearsQueryAndFiltersAsOneBackStep() {
        let appState = AppState()
        let range = Date(timeIntervalSince1970: 1_000)...Date(timeIntervalSince1970: 9_000)
        appState.sidebarSelection = .platform("twitter")
        appState.filterText = "birds tag:reference"
        appState.starredFilter = true
        appState.hasOCRFilter = true
        appState.platformFilter = "import"
        appState.dateRangeFilter = range

        appState.commitLibraryDestinationChange(.allMedia, clearingQuery: true)

        XCTAssertEqual(appState.sidebarSelection, .allMedia)
        XCTAssertEqual(appState.filterText, "")
        XCTAssertNil(appState.starredFilter)
        XCTAssertNil(appState.hasOCRFilter)
        XCTAssertNil(appState.platformFilter)
        XCTAssertNil(appState.dateRangeFilter)
        XCTAssertTrue(appState.canNavigateBack)

        XCTAssertTrue(appState.navigateBack())
        XCTAssertEqual(appState.sidebarSelection, .platform("twitter"))
        XCTAssertEqual(appState.filterText, "birds tag:reference")
        XCTAssertEqual(appState.starredFilter, true)
        XCTAssertEqual(appState.hasOCRFilter, true)
        XCTAssertEqual(appState.platformFilter, "import")
        XCTAssertEqual(appState.dateRangeFilter, range)
        XCTAssertFalse(appState.canNavigateBack, "Clearing and leaving must not leave a second, half-cleared step")
    }

    func testPlatformDisplayNamesAreBrandCasedAndCanonical() {
        XCTAssertEqual(LibraryFilterPresentation.platformName("youtube"), "YouTube")
        XCTAssertEqual(LibraryFilterPresentation.platformName(" TikTok "), "TikTok")
        XCTAssertEqual(LibraryFilterPresentation.platformName("bsky"), "Bluesky", "Aliases share one label")
        XCTAssertEqual(LibraryFilterPresentation.platformName("reddit"), "Reddit")
        XCTAssertEqual(LibraryFilterPresentation.platformName("somesite"), "Somesite")
    }
}
