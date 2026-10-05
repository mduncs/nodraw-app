import XCTest
@testable import MediaViewer

@MainActor
final class FocusReturnContinuityTests: XCTestCase {
    func testExplicitCloseSelectsAndRevealsItemCurrentAtExit() {
        let appState = AppState()
        let items = makeItems(count: 4)
        appState.setDisplayContext(
            surface: .grid,
            items: items,
            selectedIDs: [items[0].id],
            anchorID: items[0].id
        )

        appState.openSingleFocus(items[0])
        appState.navigateToNextItem()
        appState.navigateToNextItem()
        let generationBeforeClose = appState.libraryScrollRequest.generation

        appState.closeSingleFocus()

        XCTAssertNil(appState.focusedItem)
        XCTAssertEqual(appState.lastFocusedItem?.id, items[2].id)
        XCTAssertEqual(appState.selectedItemID, items[2].id)
        XCTAssertEqual(appState.selectedItemIDs, [items[2].id])
        XCTAssertEqual(appState.mediaSelectionStore.focusedID, items[2].id)
        XCTAssertEqual(appState.activeDisplayContext?.anchorID, items[2].id)
        XCTAssertEqual(appState.libraryScrollRequest.target, .item(items[2].id))
        XCTAssertGreaterThan(appState.libraryScrollRequest.generation, generationBeforeClose)
        XCTAssertFalse(appState.canNavigateBack, "Explicit close must consume its detail entry")
    }

    func testHistoryBackUsesSameCurrentItemReturnContract() {
        let appState = AppState()
        let items = makeItems(count: 3)
        appState.setDisplayContext(surface: .table, items: items)
        appState.openSingleFocus(items[0])
        appState.navigateToNextItem()

        XCTAssertTrue(appState.navigateBack())

        XCTAssertNil(appState.focusedItem)
        XCTAssertEqual(appState.selectedItemID, items[1].id)
        XCTAssertEqual(appState.activeDisplayContext?.surface, .table)
        XCTAssertEqual(appState.activeDisplayContext?.anchorID, items[1].id)
        XCTAssertEqual(appState.libraryScrollRequest.target, .item(items[1].id))
        XCTAssertFalse(appState.canNavigateBack, "History Back must pop, not duplicate, the detail entry")
    }

    func testCurrentItemMissingFromLiveResultsReturnsToNearestFollowingNeighbor() {
        let appState = AppState()
        let items = makeItems(count: 5)
        appState.setDisplayContext(surface: .grid, items: items)
        appState.openSingleFocus(items[1])
        appState.navigateToNextItem() // Current item is index 2.

        // A live filter/reload removes the current item. The session snapshot still knows its
        // former position, while the display context is the authoritative live membership.
        appState.setDisplayContext(
            surface: .grid,
            items: [items[0], items[1], items[3], items[4]],
            selectedIDs: [],
            anchorID: nil
        )
        appState.closeSingleFocus()

        XCTAssertEqual(appState.selectedItemID, items[3].id)
        XCTAssertEqual(appState.activeDisplayContext?.anchorID, items[3].id)
        XCTAssertEqual(appState.libraryScrollRequest.target, .item(items[3].id))
    }

    func testMissingCurrentAtEndFallsBackToPreviousNeighbor() {
        let appState = AppState()
        let items = makeItems(count: 3)
        appState.setDisplayContext(surface: .grid, items: items)
        appState.openSingleFocus(items[2])

        appState.setDisplayContext(
            surface: .grid,
            items: [items[0], items[1]],
            selectedIDs: [],
            anchorID: nil
        )
        appState.closeSingleFocus()

        XCTAssertEqual(appState.selectedItemID, items[1].id)
        XCTAssertEqual(appState.libraryScrollRequest.target, .item(items[1].id))
    }

    func testDeletingFocusedItemContinuesInSameSessionWithoutAnotherHistoryEntry() {
        let appState = AppState()
        let items = makeItems(count: 4)
        appState.setDisplayContext(surface: .grid, items: items)
        appState.openSingleFocus(items[1])

        appState.removeDisplayedItems(ids: [items[1].id])

        XCTAssertEqual(appState.focusedItem?.id, items[2].id, "Delete continues forward when possible")
        XCTAssertEqual(appState.focusSession?.currentID, items[2].id)
        XCTAssertEqual(appState.focusSession?.navigationIDs, [items[0].id, items[2].id, items[3].id])

        appState.closeSingleFocus()

        XCTAssertEqual(appState.selectedItemID, items[2].id)
        XCTAssertEqual(appState.libraryScrollRequest.target, .item(items[2].id))
        XCTAssertFalse(appState.canNavigateBack, "Delete continuation stays inside the original detail entry")
    }

    func testDeletingOnlyFocusedResultClosesAndDoesNotLeaveReopenTarget() {
        let appState = AppState()
        let item = makeItem(index: 0)
        appState.setDisplayContext(surface: .grid, items: [item])
        appState.openSingleFocus(item)

        appState.removeDisplayedItems(ids: [item.id])

        XCTAssertNil(appState.focusedItem)
        XCTAssertNil(appState.focusSession)
        XCTAssertNil(appState.lastFocusedItem)
        XCTAssertNil(appState.selectedItemID)
        XCTAssertTrue(appState.selectedItemIDs.isEmpty)
        XCTAssertEqual(appState.libraryScrollRequest.target, .top)
        XCTAssertFalse(appState.canNavigateBack)
    }

    func testDestinationChangeClosesFirstAndRecordsOnlyDestinationStep() {
        let appState = AppState()
        let items = makeItems(count: 3)
        let previousBrowseMode = appState.browseMode
        defer { appState.browseMode = previousBrowseMode }

        appState.sidebarSelection = .folder("2026-09")
        appState.filterText = "birds"
        appState.searchScope = .notesOnly
        appState.sortOrder = .authorAscending
        appState.browseMode = .table
        appState.setDisplayContext(surface: .table, items: items)
        appState.openSingleFocus(items[0])
        appState.navigateToNextItem()

        appState.commitLibraryDestinationChange(.tag("reference"))

        XCTAssertNil(appState.focusedItem)
        XCTAssertEqual(appState.sidebarSelection, .tag("reference"))
        XCTAssertNil(appState.selectedItemID)
        XCTAssertEqual(appState.browseMode, .table)
        XCTAssertTrue(appState.canNavigateBack)

        XCTAssertTrue(appState.navigateBack())
        XCTAssertEqual(appState.sidebarSelection, .folder("2026-09"))
        XCTAssertEqual(appState.filterText, "birds")
        XCTAssertEqual(appState.searchScope, .notesOnly)
        XCTAssertEqual(appState.sortOrder, .authorAscending)
        XCTAssertEqual(appState.browseMode, .table)
        XCTAssertEqual(appState.selectedItemID, items[1].id)
        XCTAssertEqual(appState.libraryScrollRequest.target, .item(items[1].id))
        XCTAssertFalse(appState.canNavigateBack, "The consumed detail step must not remain below destination")
    }

    func testPresentationSourceMutationDoesNotChangeParentReturnIdentity() {
        let appState = AppState()
        var item = makeItem(index: 0)
        item.contextImage = item.basePath.appendingPathComponent("context.png")
        appState.setDisplayContext(surface: .grid, items: [item])
        appState.openSingleFocus(item)

        item.prefersContextImage = true
        appState.replaceCachedItemIfPresent(item)
        appState.closeSingleFocus()

        XCTAssertEqual(appState.lastFocusedItem?.id, item.id)
        XCTAssertEqual(appState.lastFocusedItem?.prefersContextImage, true)
        XCTAssertEqual(appState.selectedItemID, item.id)
        XCTAssertEqual(appState.libraryScrollRequest.target, .item(item.id))
    }

    func testRetargetingOpenFocusDoesNotCreateNestedDetailHistory() {
        let appState = AppState()
        let items = makeItems(count: 3)
        appState.setDisplayContext(surface: .grid, items: items)
        appState.openSingleFocus(items[0])

        // Folder position and tagging-queue controls historically called openSingleFocus again.
        appState.openSingleFocus(items[2])
        appState.closeSingleFocus()

        XCTAssertEqual(appState.selectedItemID, items[2].id)
        XCTAssertEqual(appState.libraryScrollRequest.target, .item(items[2].id))
        XCTAssertFalse(appState.canNavigateBack)
    }

    private func makeItems(count: Int) -> [MediaItem] {
        (0..<count).map(makeItem(index:))
    }

    private func makeItem(index: Int) -> MediaItem {
        let id = UUID()
        let basePath = URL(fileURLWithPath: "/tmp/nodraw-focus-return-tests")
        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("\(id.uuidString).md"),
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString)-\(index).jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/\(id.uuidString)")!,
                platform: "web",
                author: "Author \(index)",
                archivedDate: Date(timeIntervalSince1970: TimeInterval(index)),
                notes: "Item \(index)"
            )
        )
    }
}
