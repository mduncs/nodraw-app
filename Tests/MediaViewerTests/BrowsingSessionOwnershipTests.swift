import XCTest
@testable import MediaViewer

@MainActor
final class BrowsingSessionOwnershipTests: XCTestCase {
    private func items(_ count: Int) -> [MediaItem] {
        (0..<count).map { index in
            let id = UUID()
            return MediaItem(id: id, basePath: URL(fileURLWithPath: "/tmp/session-fixture"),
                             metadataFile: URL(fileURLWithPath: "/tmp/session-fixture/\(id).md"),
                             mediaFiles: [URL(fileURLWithPath: "/tmp/session-fixture/\(id).jpg")],
                             metadata: MediaMetadata(source: URL(string: "https://example.com/\(index)")!,
                                                     platform: "test", archivedDate: Date()))
        }
    }

    func testGridTableAndShellShareRecordsSelectionAndDeterministicAnchor() {
        let app = AppState()
        let grid = MasonryGridViewModel()
        let table = TableBrowserViewModel()
        let records = items(5)
        grid.setSelectionStore(app.mediaSelectionStore)
        grid.setItems(records)
        app.setDisplayContext(surface: .grid, items: records)
        grid.select(records[3].id)
        grid.toggleSelection(records[1].id)
        XCTAssertEqual(app.orderedSelectedItemIDs, [records[1].id, records[3].id])
        table.setSelectionStore(app.mediaSelectionStore)
        XCTAssertEqual(table.items, records)
        XCTAssertEqual(table.selectedItemID, records[1].id)
        table.toggleSelection(records[1].id)
        XCTAssertEqual(app.selectedItemID, records[3].id)
        XCTAssertEqual(grid.selectedItemID, records[3].id)

        var updated = records[3]
        updated.metadata.notes = "one canonical value"
        app.replaceCachedItemIfPresent(updated)
        XCTAssertEqual(grid.item(for: updated.id)?.metadata.notes, updated.metadata.notes)
        XCTAssertEqual(table.item(for: updated.id)?.metadata.notes, updated.metadata.notes)
    }

    func testSurfaceAndQueryTokensRejectHiddenAndOlderResultsIncludingABA() throws {
        let session = MediaSelectionStore()
        session.activate(.grid)
        let oldGrid = try XCTUnwrap(session.beginQuery(from: .grid))
        session.invalidateQueries(from: .grid)
        let newerGrid = try XCTUnwrap(session.beginQuery(from: .grid))
        XCTAssertFalse(session.accepts(oldGrid))
        XCTAssertTrue(session.accepts(newerGrid))
        session.activate(.table)
        let table = try XCTUnwrap(session.beginQuery(from: .table))
        XCTAssertFalse(session.accepts(newerGrid))
        XCTAssertNil(session.beginQuery(from: .grid), "Hidden grid cannot acquire publication authority")
        session.activate(.grid)
        XCTAssertFalse(session.accepts(oldGrid))
        XCTAssertFalse(session.accepts(table))
    }

    func testLensSwitchReusesLoadedScopeButChangedFilterRequiresQuery() {
        let app = AppState()
        let records = items(500)
        var filter = FilterState()
        filter.limit = 5000
        app.setDisplayContext(surface: .table, items: records)
        app.mediaSelectionStore.rememberFilter(filter)
        filter.limit = 240
        XCTAssertTrue(app.mediaSelectionStore.canReuseLoadedResults(for: filter, switchingTo: .grid))
        app.selectedItemIDs = [records[499].id]
        app.selectedItemID = records[499].id
        let grid = MasonryGridViewModel()
        grid.setSelectionStore(app.mediaSelectionStore)
        XCTAssertEqual(grid.items.count, 500)
        XCTAssertEqual(grid.selectedItemID, records[499].id)
        filter.platform = "other"
        XCTAssertFalse(app.mediaSelectionStore.canReuseLoadedResults(for: filter, switchingTo: .grid))
    }

    func testDetailOrderUsesIDsAndResolvesUpdatesAfterResultReplacement() {
        let app = AppState()
        let records = items(4)
        app.setDisplayContext(surface: .grid, items: records)
        app.openSingleFocus(records[1])
        app.setDisplayContext(surface: .grid, items: [records[0], records[3]])
        var updated = records[2]
        updated.metadata.notes = "updated while outside loaded results"
        app.replaceCachedItemIfPresent(updated)
        app.navigateToNextItem()
        XCTAssertEqual(app.focusedItem?.id, updated.id)
        XCTAssertEqual(app.focusedItem?.metadata.notes, updated.metadata.notes)
        app.closeSingleFocus()
        XCTAssertEqual(app.selectedItemID, records[3].id)
        XCTAssertEqual(app.libraryScrollRequest.target, .item(records[3].id))
    }

    func testGenericStoreChangeRefreshesCanonicalFocusAfterExternalResolution() async throws {
        let records = items(2)
        var latest = records[0]
        var fetchCount = 0
        let app = AppState(focusedItemLoader: { _ in fetchCount += 1; return latest })
        let grid = MasonryGridViewModel()
        grid.setSelectionStore(app.mediaSelectionStore)
        grid.setItems(records)
        app.setDisplayContext(surface: .grid, items: records)
        app.openSingleFocus(records[0])
        try await waitUntil { fetchCount > 0 }
        latest.metadata.notes = "accepted file value"
        latest.metadata.tags = ["external"]
        NotificationCenter.default.post(name: .mediaStoreDidChange, object: nil)
        try await waitUntil { app.focusedItem?.metadata.notes == "accepted file value" }
        XCTAssertEqual(app.displayedItem(for: latest.id)?.metadata.tags, ["external"])
        XCTAssertEqual(grid.item(for: latest.id)?.metadata.notes, "accepted file value")
        XCTAssertEqual(app.focusSession?.navigationItems(in: app.mediaSelectionStore).first?.metadata.tags, ["external"])
    }

    func testLateFocusedHydrationCannotOverwriteNewerMetadataRefresh() async throws {
        let app = AppState()
        let record = items(1)[0]
        app.setDisplayContext(surface: .grid, items: [record])
        app.openSingleFocus(record)
        var suspended: CheckedContinuation<MediaItem?, Never>?
        let oldRefresh = Task {
            await app.refreshFocusedRecord { _ in
                await withCheckedContinuation { suspended = $0 }
            }
        }
        try await waitUntil { suspended != nil }
        var updated = record
        updated.metadata.notes = "newest"
        await app.refreshFocusedRecord { _ in updated }
        suspended?.resume(returning: record)
        await oldRefresh.value
        XCTAssertEqual(app.focusedItem?.metadata.notes, "newest")
        XCTAssertEqual(app.displayedItem(for: record.id)?.metadata.notes, "newest")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for session state")
    }
}
