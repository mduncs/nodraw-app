import Combine
import XCTest
@testable import MediaViewer

@MainActor
final class AppStateDisplayCacheTests: XCTestCase {
    func testRecordRefreshesPreserveFolderCacheWhenFolderIsUnchanged() {
        let appState = AppState()
        let item = makeItem(notes: "old")
        appState.setDisplayedItems([item])
        let rebuilds = appState.folderCacheRebuildCount

        var updated = item
        updated.metadata.notes = "new"
        appState.replaceDisplayedItemIfPresent(updated)
        updated.metadata.starred = true
        appState.replaceCachedItemIfPresent(updated)

        XCTAssertEqual(appState.folderCacheRebuildCount, rebuilds)
        XCTAssertEqual(appState.displayedItem(for: item.id)?.metadata.notes, "new")
        XCTAssertEqual(appState.displayedItem(for: item.id)?.metadata.starred, true)
        XCTAssertEqual(appState.folderPositionOfItem(id: item.id)?.index, 1)
    }

    func testRecordRefreshRebuildsFolderCacheWhenFolderChanges() {
        let appState = AppState()
        let item = makeItem(notes: "old")
        let sibling = makeItem(notes: "sibling")
        appState.setDisplayedItems([item, sibling])
        let rebuilds = appState.folderCacheRebuildCount
        let updated = relocating(item, to: "other-folder")

        appState.replaceDisplayedItemIfPresent(updated)

        XCTAssertEqual(appState.folderCacheRebuildCount, rebuilds + 1)
        XCTAssertEqual(appState.folderPositionOfItem(id: item.id)?.total, 1)
        XCTAssertEqual(appState.folderPositionOfItem(id: sibling.id)?.total, 1)

        appState.replaceCachedItemIfPresent(relocating(updated, to: item.folderName))

        XCTAssertEqual(appState.folderCacheRebuildCount, rebuilds + 2)
        XCTAssertEqual(appState.folderPositionOfItem(id: item.id)?.total, 2)
    }

    func testDisplaySettersRebuildFolderCacheOnlyForFolderOrOrderChanges() {
        let appState = AppState()
        let first = makeItem(notes: "first")
        let second = makeItem(notes: "second")
        appState.setDisplayContext(surface: .grid, items: [first, second])
        let rebuilds = appState.folderCacheRebuildCount
        var updated = first
        updated.metadata.notes = "updated"

        appState.setDisplayContext(surface: .grid, items: [updated, second])
        appState.setDisplayedItems([updated, second])

        XCTAssertEqual(appState.folderCacheRebuildCount, rebuilds)

        appState.setDisplayContext(surface: .table, items: [second, updated])

        XCTAssertEqual(appState.folderCacheRebuildCount, rebuilds + 1)
        XCTAssertEqual(appState.folderPositionOfItem(id: first.id)?.index, 2)

        appState.setDisplayedItems([second, relocating(updated, to: "other-folder")])

        XCTAssertEqual(appState.folderCacheRebuildCount, rebuilds + 2)
        XCTAssertEqual(appState.folderPositionOfItem(id: first.id)?.total, 1)
    }

    func testOffDisplayCachedRefreshPreservesFolderCache() {
        let appState = AppState()
        let visible = makeItem(notes: "visible")
        let retained = makeItem(notes: "retained")
        appState.setDisplayedItems([visible])
        appState.lastFocusedItem = retained
        let rebuilds = appState.folderCacheRebuildCount

        appState.replaceCachedItemIfPresent(relocating(retained, to: "other-folder"))

        XCTAssertEqual(appState.folderCacheRebuildCount, rebuilds)
        XCTAssertEqual(appState.lastFocusedItem?.folderName, "other-folder")
    }

    func testDisplayContextDetectsFolderChangesAlreadyAppliedToCanonicalStore() {
        let appState = AppState()
        let item = makeItem(notes: "item")
        let sibling = makeItem(notes: "sibling")
        appState.setDisplayContext(surface: .grid, items: [item, sibling])
        let rebuilds = appState.folderCacheRebuildCount
        let moved = relocating(item, to: "other-folder")
        appState.mediaSelectionStore.replaceRecord(moved)

        appState.setDisplayContext(surface: .grid, items: [moved, sibling])

        XCTAssertEqual(appState.folderCacheRebuildCount, rebuilds + 1)
        XCTAssertEqual(appState.folderPositionOfItem(id: item.id)?.total, 1)
        XCTAssertEqual(appState.folderPositionOfItem(id: sibling.id)?.total, 1)
    }

    func testBatchDisplayedRefreshPublishesOnceAndRebuildsFoldersOnce() {
        let appState = AppState()
        let first = makeItem(notes: "first")
        let second = makeItem(notes: "second")
        let absent = makeItem(notes: "absent")
        appState.setDisplayedItems([first, second])
        let rebuilds = appState.folderCacheRebuildCount
        var batches: [[MediaItem]] = []
        var itemPublishes = 0
        let subscription = appState.mediaSelectionStore.recordsChanges.sink { batches.append($0) }
        let itemsSubscription = appState.mediaSelectionStore.$items.dropFirst().sink { _ in itemPublishes += 1 }

        appState.replaceDisplayedItemsIfPresent([
            relocating(first, to: "moved"), relocating(second, to: "moved"), absent
        ])

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(itemPublishes, 1)
        XCTAssertEqual(batches.first?.map(\.id), [first.id, second.id])
        XCTAssertEqual(appState.folderCacheRebuildCount, rebuilds + 1)
        XCTAssertEqual(appState.folderPositionOfItem(id: first.id)?.index, 1)
        XCTAssertEqual(appState.folderPositionOfItem(id: second.id)?.index, 2)
        XCTAssertNil(appState.mediaSelectionStore.item(for: absent.id))
        withExtendedLifetime(subscription) {}
        withExtendedLifetime(itemsSubscription) {}
    }

    func testGridDeletionRebuildsFolderCacheAfterSharedCorpusAlreadyChanged() {
        let appState = AppState()
        let first = makeItem(notes: "first")
        let second = makeItem(notes: "second")
        let third = makeItem(notes: "third")
        appState.setDisplayContext(surface: .grid, items: [first, second, third])
        let viewModel = MasonryGridViewModel()
        viewModel.setSelectionStore(appState.mediaSelectionStore)
        let rebuilds = appState.folderCacheRebuildCount

        viewModel.removeItems([first.id])
        appState.removeDisplayedItems(ids: [first.id])

        XCTAssertEqual(appState.folderCacheRebuildCount, rebuilds + 1)
        XCTAssertNil(appState.folderPositionOfItem(id: first.id))
        XCTAssertEqual(appState.folderPositionOfItem(id: second.id)?.index, 1)
        XCTAssertEqual(appState.folderPositionOfItem(id: second.id)?.total, 2)
        XCTAssertNil(appState.prevItemInFolder(currentId: second.id))
        XCTAssertEqual(appState.nextItemInFolder(currentId: second.id)?.id, third.id)
        XCTAssertEqual(appState.activeDisplayContext?.itemIDs, [second.id, third.id])
    }

    func testReplaceDisplayedItemUpdatesLookupByID() {
        let appState = AppState()
        let first = makeItem(notes: "first")
        let second = makeItem(notes: "second")

        appState.setDisplayedItems([first, second])

        var updatedSecond = second
        updatedSecond.metadata.notes = "updated"
        appState.replaceDisplayedItemIfPresent(updatedSecond)

        XCTAssertEqual(appState.displayedItem(for: second.id)?.metadata.notes, "updated")
        XCTAssertEqual(appState.displayedItem(for: first.id)?.metadata.notes, "first")
    }

    func testRemoveDisplayedItemsClearsDeletedSelection() {
        let appState = AppState()
        let first = makeItem(notes: "first")
        let second = makeItem(notes: "second")

        appState.setDisplayedItems([first, second])
        appState.selectedItemID = first.id
        appState.selectedItemIDs = [first.id, second.id]

        appState.removeDisplayedItems(ids: [first.id])

        XCTAssertNil(appState.displayedItem(for: first.id))
        XCTAssertEqual(appState.selectedItemID, second.id)
        XCTAssertEqual(appState.selectedItemIDs, [second.id])
    }

    func testOpenSingleFocusSelectsFocusedItem() {
        let appState = AppState()
        let first = makeItem(notes: "first")
        let second = makeItem(notes: "second")

        appState.setDisplayContext(surface: .grid, items: [first, second])
        appState.selectedItemID = first.id
        appState.selectedItemIDs = [first.id]

        appState.openSingleFocus(second)

        XCTAssertEqual(appState.focusedItem?.id, second.id)
        XCTAssertEqual(appState.selectedItemID, second.id)
        XCTAssertEqual(appState.selectedItemIDs, [second.id])
        XCTAssertEqual(appState.focusSession?.origin.surface, .grid)
    }

    func testOpenSingleFocusPreservesReturnAnchorAndSourceSurface() {
        let appState = AppState()
        let anchor = makeItem(notes: "anchor")
        let focused = makeItem(notes: "focused")
        let third = makeItem(notes: "third")

        appState.setDisplayContext(
            surface: .table,
            items: [anchor, focused, third],
            selectedIDs: [anchor.id],
            anchorID: anchor.id
        )

        appState.openSingleFocus(focused)

        XCTAssertEqual(appState.focusSession?.origin.surface, .table)
        XCTAssertEqual(appState.focusSession?.origin.itemIDs, [anchor.id, focused.id, third.id])
        XCTAssertEqual(appState.focusSession?.origin.anchorID, anchor.id)
        XCTAssertEqual(appState.focusSession?.returnAnchorID, focused.id)
        XCTAssertEqual(appState.focusedItem?.id, focused.id)
    }

    func testNavigateNextKeepsSelectionSetAlignedWithFocus() {
        let appState = AppState()
        let first = makeItem(notes: "first")
        let second = makeItem(notes: "second")

        appState.setDisplayContext(surface: .grid, items: [first, second])
        appState.openSingleFocus(first)

        appState.navigateToNextItem()

        XCTAssertEqual(appState.focusedItem?.id, second.id)
        XCTAssertEqual(appState.selectedItemID, second.id)
        XCTAssertEqual(appState.selectedItemIDs, [second.id])
    }

    func testFocusNavigationUsesSessionSnapshotAfterDisplayContextChanges() {
        let appState = AppState()
        let first = makeItem(notes: "first")
        let second = makeItem(notes: "second")
        let third = makeItem(notes: "third")
        let unrelated = makeItem(notes: "unrelated")

        appState.setDisplayContext(surface: .grid, items: [first, second, third])
        appState.openSingleFocus(second)

        appState.setDisplayContext(surface: .table, items: [unrelated])
        appState.navigateToNextItem()

        XCTAssertEqual(appState.focusedItem?.id, third.id)
        XCTAssertEqual(appState.focusSession?.origin.surface, .grid)
    }

    func testSetDisplayContextTracksSurfaceOrderAndSelection() {
        let appState = AppState()
        let first = makeItem(notes: "first")
        let second = makeItem(notes: "second")

        appState.setDisplayContext(
            surface: .table,
            items: [second, first],
            selectedIDs: [first.id],
            anchorID: first.id
        )

        XCTAssertEqual(appState.activeDisplayContext?.surface, .table)
        XCTAssertEqual(appState.activeDisplayContext?.itemIDs, [second.id, first.id])
        XCTAssertEqual(appState.activeDisplayContext?.selectedIDs, [first.id])
        XCTAssertEqual(appState.activeDisplayContext?.anchorID, first.id)
    }

    func testRediscoverFocusSessionKeepsRediscoverSnapshotAfterContextChanges() {
        let appState = AppState()
        let first = makeItem(notes: "first")
        let second = makeItem(notes: "second")
        let third = makeItem(notes: "third")
        let unrelated = makeItem(notes: "unrelated")

        appState.setDisplayContext(
            surface: .rediscover,
            items: [first, second, third],
            selectedIDs: [second.id],
            anchorID: second.id
        )

        appState.openSingleFocus(second, navigationItems: [first, second, third])
        appState.setDisplayContext(surface: .table, items: [unrelated])
        appState.navigateToNextItem()

        XCTAssertEqual(appState.focusSession?.origin.surface, .rediscover)
        XCTAssertEqual(appState.focusSession?.returnAnchorID, third.id)
        XCTAssertEqual(appState.focusedItem?.id, third.id)
    }

    func testDuplicateReviewFocusSessionKeepsDuplicateSnapshotAfterContextChanges() {
        let appState = AppState()
        let first = makeItem(notes: "first")
        let second = makeItem(notes: "second")
        let unrelated = makeItem(notes: "unrelated")

        appState.setDisplayContext(
            surface: .duplicateReview,
            items: [first, second],
            selectedIDs: [first.id],
            anchorID: first.id
        )

        appState.openSingleFocus(first, navigationItems: [first, second])
        appState.setDisplayContext(surface: .grid, items: [unrelated])
        appState.navigateToNextItem()

        XCTAssertEqual(appState.focusSession?.origin.surface, .duplicateReview)
        XCTAssertEqual(appState.focusedItem?.id, second.id)
    }

    func testCanvasFocusSessionKeepsCanvasSnapshotAfterContextChanges() {
        let appState = AppState()
        let back = makeItem(notes: "back")
        let front = makeItem(notes: "front")
        let unrelated = makeItem(notes: "unrelated")

        appState.setDisplayContext(
            surface: .canvas,
            items: [back, front],
            selectedIDs: [front.id],
            anchorID: front.id
        )

        appState.openSingleFocus(front, navigationItems: [back, front])
        appState.setDisplayContext(surface: .visualClusters, items: [unrelated])
        appState.navigateToPrevItem()

        XCTAssertEqual(appState.focusSession?.origin.surface, .canvas)
        XCTAssertEqual(appState.focusedItem?.id, back.id)
    }

    func testUpdateCachedNotesUpdatesDisplayedFocusedAndLastFocusedSnapshots() {
        let appState = AppState()
        let previous = makeItem(notes: "previous")
        let item = makeItem(notes: "old")

        appState.setDisplayContext(surface: .grid, items: [previous, item])
        appState.openSingleFocus(item, navigationItems: [previous, item])
        appState.lastFocusedItem = item

        appState.updateCachedNotes(for: item.id, notes: "new")

        XCTAssertEqual(appState.displayedItem(for: item.id)?.metadata.notes, "new")
        XCTAssertEqual(appState.focusedItem?.metadata.notes, "new")
        XCTAssertEqual(appState.lastFocusedItem?.metadata.notes, "new")
        XCTAssertEqual(appState.focusSession?.navigationItems(in: appState.mediaSelectionStore).last?.metadata.notes, "new")
        XCTAssertEqual(appState.focusSession?.navigationItems(in: appState.mediaSelectionStore).first?.metadata.notes, "previous")
        XCTAssertEqual(appState.focusSession?.currentID, item.id)
    }

    func testReplaceCachedItemUpdatesDisplayedFocusAndSessionSnapshots() {
        let appState = AppState()
        let item = makeItem(notes: "old")

        appState.setDisplayContext(surface: .grid, items: [item])
        appState.openSingleFocus(item)
        appState.lastFocusedItem = item

        var updated = item
        updated.metadata.notes = "new"
        updated.metadata.starred = true
        updated.metadata.tags = ["updated"]
        appState.replaceCachedItemIfPresent(updated)

        XCTAssertEqual(appState.displayedItem(for: item.id)?.metadata.tags, ["updated"])
        XCTAssertEqual(appState.focusedItem?.metadata.tags, ["updated"])
        XCTAssertEqual(appState.lastFocusedItem?.metadata.tags, ["updated"])
        XCTAssertEqual(appState.focusSession?.navigationItems(in: appState.mediaSelectionStore).first?.metadata.tags, ["updated"])
        XCTAssertEqual(appState.focusSession?.navigationItems(in: appState.mediaSelectionStore).first?.metadata.starred, true)
    }

    func testCloseSingleFocusReturnsToCurrentItemAfterDetailNavigation() {
        let appState = AppState()
        let first = makeItem(notes: "first")
        let second = makeItem(notes: "second")
        let third = makeItem(notes: "third")

        appState.setDisplayContext(
            surface: .grid,
            items: [first, second, third],
            selectedIDs: [first.id],
            anchorID: first.id
        )
        appState.openSingleFocus(first)

        appState.navigateToNextItem()
        appState.closeSingleFocus()

        XCTAssertNil(appState.focusedItem)
        XCTAssertEqual(appState.lastFocusedItem?.id, second.id)
        XCTAssertEqual(appState.selectedItemID, second.id)
        XCTAssertEqual(appState.selectedItemIDs, [second.id])
        XCTAssertEqual(appState.activeDisplayContext?.surface, .grid)
        XCTAssertEqual(appState.activeDisplayContext?.anchorID, second.id)
        XCTAssertEqual(appState.activeDisplayContext?.selectedIDs, [second.id])
        XCTAssertEqual(appState.libraryScrollRequest.target, .item(second.id))
    }

    func testCloseSingleFocusFallsBackWhenReturnAnchorIsNoLongerDisplayed() {
        let appState = AppState()
        let first = makeItem(notes: "first")
        let second = makeItem(notes: "second")

        appState.setDisplayContext(
            surface: .grid,
            items: [first, second],
            selectedIDs: [first.id],
            anchorID: first.id
        )
        appState.openSingleFocus(first)
        appState.navigateToNextItem()
        appState.removeDisplayedItems(ids: [first.id])

        appState.closeSingleFocus()

        XCTAssertEqual(appState.selectedItemID, second.id)
        XCTAssertEqual(appState.selectedItemIDs, [second.id])
        XCTAssertEqual(appState.activeDisplayContext?.anchorID, second.id)
        XCTAssertEqual(appState.activeDisplayContext?.selectedIDs, [second.id])
    }

    func testTableBrowserVisibleOrderFollowsSortAndGrouping() {
        let viewModel = TableBrowserViewModel()
        let bItem = makeItem(notes: "b", author: "z")
        let aItem = makeItem(notes: "a", author: "a")

        viewModel.tableSortOrder = [KeyPathComparator(\MediaItem.sortNotes)]
        viewModel.setItems([bItem, aItem])

        XCTAssertEqual(viewModel.visibleItemsInDisplayOrder.map(\.id), [aItem.id, bItem.id])

        viewModel.groupBy = .author

        XCTAssertEqual(viewModel.visibleItemsInDisplayOrder.map(\.id), [aItem.id, bItem.id])
    }

    private func makeItem(notes: String, author: String? = nil) -> MediaItem {
        let id = UUID()
        let basePath = URL(fileURLWithPath: "/tmp/nodraw-tests")
        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("\(id.uuidString).md"),
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString).jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/\(id.uuidString)")!,
                platform: "web",
                author: author,
                archivedDate: Date(),
                notes: notes
            )
        )
    }

    private func relocating(_ item: MediaItem, to folder: String) -> MediaItem {
        let basePath = URL(fileURLWithPath: "/tmp").appendingPathComponent(folder)
        return MediaItem(
            id: item.id,
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent(item.metadataFile.lastPathComponent),
            mediaFiles: item.mediaFiles,
            metadata: item.metadata
        )
    }
}
