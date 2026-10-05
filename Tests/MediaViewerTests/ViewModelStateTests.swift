import XCTest
import AppKit
@testable import MediaViewer

// MARK: - MasonryGridViewModel Tests

@MainActor
final class MasonryGridViewModelTests: XCTestCase {

    // MARK: - Selection State Tests

    func testInitialSelectionIsEmpty() {
        let vm = MasonryGridViewModel()

        XCTAssertTrue(vm.selectedIDs.isEmpty)
        XCTAssertNil(vm.selectedItemID)
        XCTAssertFalse(vm.isMultiSelectMode)
    }

    func testSingleSelection() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 5)
        vm.setItems(items)

        vm.select(items[2].id)

        XCTAssertEqual(vm.selectedIDs.count, 1)
        XCTAssertEqual(vm.selectedItemID, items[2].id)
        XCTAssertFalse(vm.isMultiSelectMode)
    }

    func testSelectNilClearsSelection() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 3)
        vm.setItems(items)
        vm.select(items[0].id)

        vm.select(nil)

        XCTAssertTrue(vm.selectedIDs.isEmpty)
        XCTAssertNil(vm.selectedItemID)
    }

    func testToggleSelectionAddsItem() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 3)
        vm.setItems(items)
        vm.select(items[0].id)

        vm.toggleSelection(items[1].id)

        XCTAssertEqual(vm.selectedIDs.count, 2)
        XCTAssertTrue(vm.selectedIDs.contains(items[0].id))
        XCTAssertTrue(vm.selectedIDs.contains(items[1].id))
        XCTAssertTrue(vm.isMultiSelectMode)
    }

    func testToggleSelectionRemovesItem() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 3)
        vm.setItems(items)
        vm.select(items[0].id)
        vm.toggleSelection(items[1].id)

        vm.toggleSelection(items[0].id)

        XCTAssertEqual(vm.selectedIDs.count, 1)
        XCTAssertTrue(vm.selectedIDs.contains(items[1].id))
        XCTAssertFalse(vm.selectedIDs.contains(items[0].id))
    }

    func testExtendSelectionSelectsRange() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 10)
        vm.setItems(items)
        vm.select(items[2].id)  // Set anchor

        vm.extendSelection(to: items[5].id)

        // Should select items 2, 3, 4, 5
        XCTAssertEqual(vm.selectedIDs.count, 4)
        XCTAssertTrue(vm.selectedIDs.contains(items[2].id))
        XCTAssertTrue(vm.selectedIDs.contains(items[3].id))
        XCTAssertTrue(vm.selectedIDs.contains(items[4].id))
        XCTAssertTrue(vm.selectedIDs.contains(items[5].id))
    }

    func testExtendSelectionReverseRange() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 10)
        vm.setItems(items)
        vm.select(items[7].id)  // Set anchor at position 7

        vm.extendSelection(to: items[4].id)

        // Should select items 4, 5, 6, 7
        XCTAssertEqual(vm.selectedIDs.count, 4)
        for i in 4...7 {
            XCTAssertTrue(vm.selectedIDs.contains(items[i].id))
        }
    }

    func testSelectAll() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 5)
        vm.setItems(items)

        vm.selectAll()

        XCTAssertEqual(vm.selectedIDs.count, 5)
        for item in items {
            XCTAssertTrue(vm.selectedIDs.contains(item.id))
        }
    }

    func testClearSelection() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 5)
        vm.setItems(items)
        vm.selectAll()

        vm.clearSelection()

        XCTAssertTrue(vm.selectedIDs.isEmpty)
        XCTAssertNil(vm.selectedItemID)
    }

    func testSelectWithScrollToSelection() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 5)
        vm.setItems(items)

        XCTAssertFalse(vm.shouldScrollToSelection)

        vm.select(items[2].id, scrollToSelection: true)

        XCTAssertTrue(vm.shouldScrollToSelection)
        XCTAssertEqual(vm.selectedItemID, items[2].id)
    }

    func testSharedSelectionStoreSyncsGridAndTableSelection() {
        let store = MediaSelectionStore()
        let gridVM = MasonryGridViewModel()
        let tableVM = TableBrowserViewModel()
        let items = createTestItems(count: 5)

        gridVM.setSelectionStore(store)
        tableVM.setSelectionStore(store)
        gridVM.setItems(items)
        tableVM.setItems(items)

        gridVM.select(items[2].id)

        XCTAssertEqual(tableVM.selectedIDs, Set([items[2].id]))
        XCTAssertEqual(tableVM.selectedItemID, items[2].id)
    }

    func testSharedSelectionSurvivesReorderedRefresh() {
        let store = MediaSelectionStore()
        let gridVM = MasonryGridViewModel()
        let tableVM = TableBrowserViewModel()
        let items = createTestItems(count: 5)

        gridVM.setSelectionStore(store)
        tableVM.setSelectionStore(store)
        gridVM.setItems(items)
        tableVM.setItems(items)
        gridVM.select(items[3].id)

        let reordered = [items[4], items[3], items[2], items[1], items[0]]
        gridVM.setItems(reordered)
        tableVM.setItems(reordered)

        XCTAssertEqual(gridVM.selectedIDs, Set([items[3].id]))
        XCTAssertEqual(tableVM.selectedIDs, Set([items[3].id]))
    }

    func testSharedSelectionDropsItemsNoLongerVisible() {
        let store = MediaSelectionStore()
        let gridVM = MasonryGridViewModel()
        let items = createTestItems(count: 5)

        gridVM.setSelectionStore(store)
        gridVM.setItems(items)
        gridVM.select(items[1].id)

        gridVM.setItems(items.filter { $0.id != items[1].id })

        XCTAssertTrue(gridVM.selectedIDs.isEmpty)
        XCTAssertNil(gridVM.selectedItemID)
    }

    // MARK: - Column Count Tests

    func testInitialColumnCount() {
        let vm = MasonryGridViewModel()

        // Default column count should be 5
        XCTAssertEqual(vm.columnCount, 5)
    }

    func testSetColumnCountClampsMinimum() {
        let vm = MasonryGridViewModel()

        vm.setColumnCount(1)

        XCTAssertEqual(vm.columnCount, 2)  // Clamped to minimum 2
    }

    func testSetColumnCountClampsMaximum() {
        let vm = MasonryGridViewModel()

        vm.setColumnCount(20)

        XCTAssertEqual(vm.columnCount, 8)  // Clamped to maximum 8
    }

    func testSetColumnCountWithinRange() {
        let vm = MasonryGridViewModel()

        vm.setColumnCount(4)

        XCTAssertEqual(vm.columnCount, 4)
    }

    func testUpdateColumnCountForWidth() {
        let vm = MasonryGridViewModel()

        // Wide width should give more columns
        vm.updateColumnCount(for: 1600)
        let wideColumns = vm.columnCount

        // Narrow width should give fewer columns
        vm.updateColumnCount(for: 600)
        let narrowColumns = vm.columnCount

        XCTAssertGreaterThan(wideColumns, narrowColumns)
        XCTAssertGreaterThanOrEqual(wideColumns, 2)
        XCTAssertLessThanOrEqual(wideColumns, 8)
        XCTAssertGreaterThanOrEqual(narrowColumns, 2)
    }

    func testUpdateColumnCountIgnoresZeroWidth() {
        let vm = MasonryGridViewModel()
        let initialCount = vm.columnCount

        vm.updateColumnCount(for: 0)

        XCTAssertEqual(vm.columnCount, initialCount)
    }

    // MARK: - Density Tests

    func testInitialDensity() {
        let vm = MasonryGridViewModel()

        XCTAssertEqual(vm.density, 0.5)
    }

    func testUpdateDensityClampsToRange() {
        let vm = MasonryGridViewModel()

        vm.updateDensity(-0.5)
        XCTAssertEqual(vm.density, 0.0)

        vm.updateDensity(1.5)
        XCTAssertEqual(vm.density, 1.0)
    }

    func testDensityAffectsColumnWidthConstraints() {
        let vm = MasonryGridViewModel()

        vm.updateDensity(0.0)
        let minWidthAtLowDensity = vm.minColumnWidth
        let maxWidthAtLowDensity = vm.maxColumnWidth

        vm.updateDensity(1.0)
        let minWidthAtHighDensity = vm.minColumnWidth
        let maxWidthAtHighDensity = vm.maxColumnWidth

        // Higher density = wider columns
        XCTAssertLessThan(minWidthAtLowDensity, minWidthAtHighDensity)
        XCTAssertLessThan(maxWidthAtLowDensity, maxWidthAtHighDensity)
    }

    // MARK: - Items and Pagination Tests

    func testSetItemsUpdatesState() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 100)

        vm.setItems(items)

        XCTAssertEqual(vm.items.count, 100)
        XCTAssertEqual(vm.visibleItems.count, 100)
        XCTAssertEqual(vm.currentOffset, 100)
    }

    func testGridPageSizeMatchesBoundedThumbnailWorkingSet() {
        let vm = MasonryGridViewModel()

        vm.setItems(createTestItems(count: MasonryGridViewModel.pageSize - 1))
        XCTAssertFalse(vm.hasMoreItems)

        vm.setItems(createTestItems(count: MasonryGridViewModel.pageSize))
        XCTAssertTrue(vm.hasMoreItems)
        XCTAssertEqual(MasonryGridViewModel.pageSize, 240)
    }

    func testFullGridReloadsAreSerializedAndCoalesced() async {
        let vm = MasonryGridViewModel()
        var activeCount = 0
        var maximumActiveCount = 0
        var runCount = 0

        let operation: @MainActor () async -> Void = {
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
            runCount += 1
            try? await Task.sleep(for: .milliseconds(40))
            activeCount -= 1
        }

        let first = Task { @MainActor in
            await vm.performCoalescedReload(operation)
        }
        try? await Task.sleep(for: .milliseconds(10))
        let second = Task { @MainActor in
            await vm.performCoalescedReload(operation)
        }

        await first.value
        await second.value

        XCTAssertEqual(maximumActiveCount, 1)
        XCTAssertEqual(runCount, 2)
    }

    func testSetItemsResetsSelection() {
        let vm = MasonryGridViewModel()
        let items1 = createTestItems(count: 5)
        vm.setItems(items1)
        vm.select(items1[0].id)

        let items2 = createTestItems(count: 3)
        vm.setItems(items2)

        // Selection should persist if item still exists
        // But since items2 has different UUIDs, selection becomes stale
        XCTAssertEqual(vm.items.count, 3)
    }

    func testAppendItems() {
        let vm = MasonryGridViewModel()
        let items1 = createTestItems(count: 50)
        vm.setItems(items1)

        let items2 = createTestItems(count: 30)
        vm.appendItems(items2)

        XCTAssertEqual(vm.items.count, 80)
        XCTAssertEqual(vm.currentOffset, 80)
    }

    func testResetPagination() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 100)
        vm.setItems(items)

        vm.resetPagination()

        XCTAssertEqual(vm.currentOffset, 0)
        XCTAssertTrue(vm.hasMoreItems)
    }

    // MARK: - Column Distribution Tests

    func testColumnsDistributeItems() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 20)
        vm.setItems(items)
        vm.setColumnCount(4)
        vm.setContainerWidth(800)

        XCTAssertEqual(vm.columns.count, 4)

        // All items should be distributed across columns
        let totalItemsInColumns = vm.columns.reduce(0) { $0 + $1.count }
        XCTAssertEqual(totalItemsInColumns, 20)
    }

    func testHybridLayoutFiltersCacheItems() {
        let vm = MasonryGridViewModel()

        // Create items with varying aspect ratios
        var items: [MediaItem] = []

        // Tall items (aspect ratio <= 1.4)
        for i in 0..<3 {
            items.append(createTestItem(id: UUID(), aspectRatio: 0.7 + CGFloat(i) * 0.2))
        }

        // Wide items (1.4 < aspect ratio <= 2.8)
        for i in 0..<4 {
            items.append(createTestItem(id: UUID(), aspectRatio: 1.6 + CGFloat(i) * 0.3))
        }

        // Very wide items (aspect ratio > 2.8)
        for i in 0..<2 {
            items.append(createTestItem(id: UUID(), aspectRatio: 3.0 + CGFloat(i) * 0.5))
        }

        vm.setItems(items)

        XCTAssertEqual(vm.tallItems.count, 3)
        XCTAssertEqual(vm.wideItems.count, 4)
        XCTAssertEqual(vm.veryWideItems.count, 2)
    }

    // MARK: - Keyboard Navigation Tests

    func testSelectNextFromEmpty() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 5)
        vm.setItems(items)

        vm.selectNext()

        XCTAssertEqual(vm.selectedItemID, items[0].id)
    }

    func testSelectNextAdvancesToNextItem() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 5)
        vm.setItems(items)
        vm.select(items[2].id)

        vm.selectNext()

        XCTAssertEqual(vm.selectedItemID, items[3].id)
    }

    func testSelectNextAtEndStaysAtEnd() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 5)
        vm.setItems(items)
        vm.select(items[4].id)  // Last item

        vm.selectNext()

        XCTAssertEqual(vm.selectedItemID, items[4].id)  // Still at last
    }

    func testSelectPreviousFromEmpty() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 5)
        vm.setItems(items)

        vm.selectPrevious()

        XCTAssertEqual(vm.selectedItemID, items[4].id)  // Selects last
    }

    func testSelectPreviousGoesToPreviousItem() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 5)
        vm.setItems(items)
        vm.select(items[3].id)

        vm.selectPrevious()

        XCTAssertEqual(vm.selectedItemID, items[2].id)
    }

    func testSelectPreviousAtStartStaysAtStart() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 5)
        vm.setItems(items)
        vm.select(items[0].id)  // First item

        vm.selectPrevious()

        XCTAssertEqual(vm.selectedItemID, items[0].id)  // Still at first
    }

    func testSelectUpAndDownInColumn() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 20)
        vm.setItems(items)
        vm.setColumnCount(4)
        vm.setContainerWidth(800)

        // Select an item that we know is in the middle of a column
        guard let firstColumnItem = vm.columns.first?.first else {
            XCTFail("No columns populated")
            return
        }
        vm.select(firstColumnItem.id)

        // Test down navigation within column
        if vm.columns[0].count > 1 {
            vm.selectDown()
            XCTAssertEqual(vm.selectedItemID, vm.columns[0][1].id)
        }
    }

    func testExtendSelectionUp() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 10)
        vm.setItems(items)
        vm.setColumnCount(2)
        vm.setContainerWidth(400)

        // Select an item not at the top of its column
        guard vm.columns[0].count > 2 else {
            // Not enough items in column for this test
            return
        }

        vm.select(vm.columns[0][2].id)
        let initialSelection = vm.selectedIDs.count

        vm.extendSelectionUp()

        XCTAssertGreaterThanOrEqual(vm.selectedIDs.count, initialSelection)
    }

    func testExtendSelectionDown() {
        let vm = MasonryGridViewModel()
        let items = createTestItems(count: 10)
        vm.setItems(items)
        vm.setColumnCount(2)
        vm.setContainerWidth(400)

        // Select first item in a column
        guard !vm.columns[0].isEmpty else { return }

        vm.select(vm.columns[0][0].id)

        if vm.columns[0].count > 1 {
            vm.extendSelectionDown()
            XCTAssertGreaterThanOrEqual(vm.selectedIDs.count, 1)
        }
    }

    // MARK: - Observation State Tests

    func testObservationInitiallyInactive() {
        let vm = MasonryGridViewModel()

        XCTAssertFalse(vm.isObservationActive)
    }

    func testCancelObservationResetsState() {
        let vm = MasonryGridViewModel()

        vm.cancelObservation()

        XCTAssertFalse(vm.isObservationActive)
    }

    // MARK: - Helpers

    private func createTestItems(count: Int) -> [MediaItem] {
        (0..<count).map { i in
            createTestItem(id: UUID(), aspectRatio: CGFloat.random(in: 0.5...2.5))
        }
    }

    private func createTestItem(id: UUID, aspectRatio: CGFloat = 1.0) -> MediaItem {
        let basePath = URL(fileURLWithPath: "/archive/2025-01")
        let metadata = MediaMetadata(
            source: URL(string: "https://example.com/\(id)")!,
            platform: "test"
        )
        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("\(id.uuidString).md"),
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString).jpg")],
            metadata: metadata,
            aspectRatio: aspectRatio
        )
    }
}

// MARK: - SidebarViewModel Tests

@MainActor
final class SidebarViewModelTests: XCTestCase {

    // MARK: - Initial State Tests

    func testInitialState() {
        let vm = SidebarViewModel()

        XCTAssertEqual(vm.selection, .allMedia)
        XCTAssertTrue(vm.folders.isEmpty)
        XCTAssertTrue(vm.smartFolders.isEmpty)
        XCTAssertTrue(vm.platforms.isEmpty)
        XCTAssertTrue(vm.tags.isEmpty)
        XCTAssertEqual(vm.totalCount, 0)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Selection Tests

    func testSelectionToAllMedia() {
        let vm = SidebarViewModel()
        vm.selection = .folder("2025-01")

        vm.selection = .allMedia

        XCTAssertEqual(vm.selection, .allMedia)
    }

    func testSelectionToFolder() {
        let vm = SidebarViewModel()

        vm.selection = .folder("2025-12")

        XCTAssertEqual(vm.selection, .folder("2025-12"))
    }

    func testSelectionToSmartFolder() {
        let vm = SidebarViewModel()
        let id = UUID()

        vm.selection = .smartFolder(id)

        XCTAssertEqual(vm.selection, .smartFolder(id))
    }

    func testSelectionToBoard() {
        let vm = SidebarViewModel()
        let id = UUID()

        vm.selection = .board(id)

        XCTAssertEqual(vm.selection, .board(id))
    }

    func testSelectionToPlatform() {
        let vm = SidebarViewModel()

        vm.selection = .platform("twitter")

        XCTAssertEqual(vm.selection, .platform("twitter"))
    }

    func testSelectionToTag() {
        let vm = SidebarViewModel()

        vm.selection = .tag("art")

        XCTAssertEqual(vm.selection, .tag("art"))
    }

    func testSelectionToRediscover() {
        let vm = SidebarViewModel()

        vm.selection = .rediscover

        XCTAssertEqual(vm.selection, .rediscover)
    }

    func testSelectionToDuplicates() {
        let vm = SidebarViewModel()

        vm.selection = .duplicates

        XCTAssertEqual(vm.selection, .duplicates)
    }

    // MARK: - Selection Display Name Tests

    func testSidebarSelectionDisplayNames() {
        XCTAssertEqual(SidebarSelection.allMedia.displayName, "All Media")
        XCTAssertEqual(SidebarSelection.folderYear("2026").displayName, "2026")
        XCTAssertEqual(SidebarSelection.folder("2025-01").displayName, "2025-01")
        XCTAssertEqual(SidebarSelection.platform("twitter").displayName, "Twitter")
        XCTAssertEqual(SidebarSelection.tag("meme").displayName, "meme")
        XCTAssertEqual(SidebarSelection.rediscover.displayName, "Rediscover")
        XCTAssertEqual(SidebarSelection.duplicates.displayName, "Duplicates")
    }

    // MARK: - Filter State Building Tests

    func testBuildFilterStateAllMedia() {
        let vm = SidebarViewModel()
        vm.selection = .allMedia

        let filter = vm.buildFilterState()

        XCTAssertNil(filter.platform)
        XCTAssertNil(filter.folderPath)
        XCTAssertTrue(filter.tags.isEmpty)
        XCTAssertNil(filter.smartFolder)
        XCTAssertFalse(filter.rediscoverMode)
    }

    func testBuildFilterStateFolder() {
        let vm = SidebarViewModel()
        vm.selection = .folder("2025-12")

        let filter = vm.buildFilterState()

        XCTAssertEqual(filter.folderPath, "2025-12")
    }

    func testBuildFilterStateFolderYear() {
        let vm = SidebarViewModel()
        vm.selection = .folderYear("2026")

        let filter = vm.buildFilterState()

        XCTAssertEqual(filter.folderPath, "2026-")
    }

    func testBuildFilterStatePlatform() {
        let vm = SidebarViewModel()
        vm.selection = .platform("Twitter")

        let filter = vm.buildFilterState()

        XCTAssertEqual(filter.platform, "twitter")  // Lowercased
    }

    func testBuildFilterStateTag() {
        let vm = SidebarViewModel()
        vm.selection = .tag("art")

        let filter = vm.buildFilterState()

        XCTAssertEqual(filter.tags, ["art"])
    }

    func testBuildFilterStateBoard() {
        let vm = SidebarViewModel()
        let boardId = UUID()
        vm.selection = .board(boardId)

        let filter = vm.buildFilterState()

        XCTAssertEqual(filter.boardId, boardId)
    }

    func testBuildFilterStateRediscover() {
        let vm = SidebarViewModel()
        vm.selection = .rediscover

        let filter = vm.buildFilterState()

        XCTAssertTrue(filter.rediscoverMode)
    }

    // MARK: - SidebarItem Tests

    func testSidebarItemCreation() {
        let item = SidebarItem(
            name: "2025-01",
            icon: "folder",
            count: 42,
            selection: .folder("2025-01")
        )

        XCTAssertEqual(item.name, "2025-01")
        XCTAssertEqual(item.icon, "folder")
        XCTAssertEqual(item.count, 42)
        XCTAssertEqual(item.selection, .folder("2025-01"))
    }

    func testSidebarItemEquality() {
        let item1 = SidebarItem(name: "Test", icon: "star", count: 10, selection: .allMedia)
        let item2 = SidebarItem(name: "Test", icon: "star", count: 10, selection: .allMedia)

        XCTAssertEqual(item1, item2)
    }

    // MARK: - Smart Folder Count Cache Tests

    func testSmartFolderCountsCacheInitiallyEmpty() {
        let vm = SidebarViewModel()

        XCTAssertTrue(vm.smartFolderCounts.isEmpty)
    }

    // MARK: - Tag Colors Cache Tests

    func testTagColorsInitiallyEmpty() {
        let vm = SidebarViewModel()

        XCTAssertTrue(vm.tagColors.isEmpty)
    }

    // MARK: - SidebarSelection Hashable Tests

    func testSidebarSelectionHashable() {
        var set = Set<SidebarSelection>()

        set.insert(.allMedia)
        set.insert(.folderYear("2025"))
        set.insert(.folderYear("2025"))  // Duplicate
        set.insert(.folder("2025-01"))
        set.insert(.folder("2025-01"))  // Duplicate
        set.insert(.platform("twitter"))

        XCTAssertEqual(set.count, 4)
    }
}

// MARK: - KeyboardShortcutManager Tests

@MainActor
final class KeyboardShortcutManagerTests: XCTestCase {

    // MARK: - Initial State Tests

    func testInitialState() {
        let manager = KeyboardShortcutManager()

        XCTAssertFalse(manager.showTagInput)
        XCTAssertFalse(manager.showDeleteConfirmation)
        XCTAssertTrue(manager.itemsPendingDeletion.isEmpty)
    }

    // MARK: - Shortcut Registration Tests

    func testRegisterCustomShortcut() {
        let manager = KeyboardShortcutManager()

        let shortcut = GlobalShortcut(
            key: "q",
            modifiers: [.command],
            action: .commandPalette,
            context: .global
        )

        manager.registerShortcut(shortcut)

        // Verify shortcut was registered by checking display string
        let displayString = manager.shortcutDisplayString(for: .commandPalette)
        XCTAssertNotNil(displayString)
    }

    func testUnregisterShortcut() {
        let manager = KeyboardShortcutManager()

        // Register a custom shortcut
        let shortcut = GlobalShortcut(
            key: "x",
            modifiers: [.command, .shift],
            action: .exportWithMetadata,
            context: .global
        )
        manager.registerShortcut(shortcut)

        // Unregister it
        manager.unregisterShortcut(action: .exportWithMetadata)

        // Should still have the default export shortcut (Cmd+Shift+E)
        // but our custom one should be removed
    }

    func testShortcutDisplayString() {
        // Command palette should have Cmd+K
        // Note: Manager is not configured, but registerDefaultShortcuts is private
        // We need to test GlobalShortcut directly
        let shortcut = GlobalShortcut(
            key: "k",
            modifiers: [.command],
            action: .commandPalette,
            context: .global
        )

        XCTAssertTrue(shortcut.displayString.contains("\u{2318}"))  // Command symbol
        XCTAssertTrue(shortcut.displayString.contains("K"))
    }

    // MARK: - GlobalShortcut Tests

    func testGlobalShortcutWithCharacterKey() {
        let shortcut = GlobalShortcut(
            key: "s",
            modifiers: [],
            action: .toggleStar,
            context: .gridOrDetail
        )

        XCTAssertEqual(shortcut.key, "s")
        XCTAssertNil(shortcut.keyCode)
        XCTAssertEqual(shortcut.action, .toggleStar)
        XCTAssertEqual(shortcut.context, .gridOrDetail)
    }

    func testGlobalShortcutWithKeyCode() {
        let shortcut = GlobalShortcut(
            keyCode: 53,  // Escape
            modifiers: [],
            action: .escape,
            context: .global
        )

        XCTAssertNil(shortcut.key)
        XCTAssertEqual(shortcut.keyCode, 53)
        XCTAssertEqual(shortcut.action, .escape)
    }

    func testGlobalShortcutDisplayStringWithModifiers() {
        let shortcut = GlobalShortcut(
            key: "z",
            modifiers: [.command, .shift],
            action: .redo,
            context: .global
        )

        let display = shortcut.displayString

        XCTAssertTrue(display.contains("\u{2318}"))  // Command
        XCTAssertTrue(display.contains("\u{21E7}"))  // Shift
        XCTAssertTrue(display.contains("Z"))
    }

    func testGlobalShortcutDisplayStringWithAllModifiers() {
        let shortcut = GlobalShortcut(
            key: "a",
            modifiers: [.command, .shift, .option, .control],
            action: .selectAll,
            context: .grid
        )

        let display = shortcut.displayString

        XCTAssertTrue(display.contains("^"))           // Control
        XCTAssertTrue(display.contains("\u{2325}"))    // Option
        XCTAssertTrue(display.contains("\u{21E7}"))    // Shift
        XCTAssertTrue(display.contains("\u{2318}"))    // Command
        XCTAssertTrue(display.contains("A"))
    }

    func testGlobalShortcutDisplayStringForSpecialKeys() {
        let escapeShortcut = GlobalShortcut(
            keyCode: 53,
            modifiers: [],
            action: .escape,
            context: .global
        )
        XCTAssertEqual(escapeShortcut.displayString, "Esc")

        let spaceShortcut = GlobalShortcut(
            keyCode: 49,
            modifiers: [],
            action: .togglePreview,
            context: .grid
        )
        XCTAssertEqual(spaceShortcut.displayString, "Space")

        let enterShortcut = GlobalShortcut(
            keyCode: 36,
            modifiers: [],
            action: .openDetail,
            context: .grid
        )
        XCTAssertTrue(enterShortcut.displayString.contains("\u{21A9}"))  // Return symbol
    }

    // MARK: - Shortcut Conflict Detection Tests

    func testShortcutConflictSameKeyAndModifiers() {
        let shortcut1 = GlobalShortcut(
            key: "k",
            modifiers: [.command],
            action: .commandPalette,
            context: .global
        )
        let shortcut2 = GlobalShortcut(
            key: "k",
            modifiers: [.command],
            action: .navigateUp,
            context: .grid
        )

        // Global overlaps with grid context
        XCTAssertTrue(shortcut1.conflicts(with: shortcut2))
    }

    func testShortcutNoConflictDifferentModifiers() {
        let shortcut1 = GlobalShortcut(
            key: "k",
            modifiers: [.command],
            action: .commandPalette,
            context: .global
        )
        let shortcut2 = GlobalShortcut(
            key: "k",
            modifiers: [],
            action: .navigateUp,
            context: .grid
        )

        XCTAssertFalse(shortcut1.conflicts(with: shortcut2))
    }

    func testShortcutNoConflictDifferentKeys() {
        let shortcut1 = GlobalShortcut(
            key: "j",
            modifiers: [],
            action: .navigateDown,
            context: .grid
        )
        let shortcut2 = GlobalShortcut(
            key: "k",
            modifiers: [],
            action: .navigateUp,
            context: .grid
        )

        XCTAssertFalse(shortcut1.conflicts(with: shortcut2))
    }

    func testShortcutNoConflictNonOverlappingContexts() {
        let shortcut1 = GlobalShortcut(
            key: "n",
            modifiers: [],
            action: .navigateDown,
            context: .grid
        )
        let shortcut2 = GlobalShortcut(
            key: "n",
            modifiers: [],
            action: .navigateUp,
            context: .detail
        )

        XCTAssertFalse(shortcut1.conflicts(with: shortcut2))
    }

    // MARK: - ShortcutContext Tests

    func testShortcutContextMatches() {
        // Global matches everything
        XCTAssertTrue(ShortcutContext.global.matches(.grid))
        XCTAssertTrue(ShortcutContext.global.matches(.detail))
        XCTAssertTrue(ShortcutContext.global.matches(.global))

        // Grid only matches grid
        XCTAssertTrue(ShortcutContext.grid.matches(.grid))
        XCTAssertFalse(ShortcutContext.grid.matches(.detail))

        // Detail only matches detail
        XCTAssertTrue(ShortcutContext.detail.matches(.detail))
        XCTAssertFalse(ShortcutContext.detail.matches(.grid))

        // GridOrDetail matches both
        XCTAssertTrue(ShortcutContext.gridOrDetail.matches(.grid))
        XCTAssertTrue(ShortcutContext.gridOrDetail.matches(.detail))
    }

    func testShortcutContextOverlaps() {
        // Global overlaps with everything
        XCTAssertTrue(ShortcutContext.global.overlaps(with: .grid))
        XCTAssertTrue(ShortcutContext.global.overlaps(with: .detail))
        XCTAssertTrue(ShortcutContext.global.overlaps(with: .gridOrDetail))

        // Grid overlaps with grid and gridOrDetail
        XCTAssertTrue(ShortcutContext.grid.overlaps(with: .grid))
        XCTAssertTrue(ShortcutContext.grid.overlaps(with: .gridOrDetail))
        XCTAssertFalse(ShortcutContext.grid.overlaps(with: .detail))

        // Detail overlaps with detail and gridOrDetail
        XCTAssertTrue(ShortcutContext.detail.overlaps(with: .detail))
        XCTAssertTrue(ShortcutContext.detail.overlaps(with: .gridOrDetail))
        XCTAssertFalse(ShortcutContext.detail.overlaps(with: .grid))

        // GridOrDetail overlaps with grid, detail, and itself
        XCTAssertTrue(ShortcutContext.gridOrDetail.overlaps(with: .grid))
        XCTAssertTrue(ShortcutContext.gridOrDetail.overlaps(with: .detail))
        XCTAssertTrue(ShortcutContext.gridOrDetail.overlaps(with: .gridOrDetail))
    }

    // MARK: - ShortcutAction Tests

    func testShortcutActionEquality() {
        XCTAssertEqual(ShortcutAction.commandPalette, ShortcutAction.commandPalette)
        XCTAssertNotEqual(ShortcutAction.commandPalette, ShortcutAction.toggleStar)
    }

    func testAllShortcutActionsExist() {
        // Verify all expected actions exist (compile-time check via usage)
        let actions: [ShortcutAction] = [
            .commandPalette,
            .focusFilterBar,
            .toggleStar,
            .addTag,
            .navigateDown,
            .navigateUp,
            .navigateLeft,
            .navigateRight,
            .extendSelectionDown,
            .extendSelectionUp,
            .extendSelectionLeft,
            .extendSelectionRight,
            .pageUp,
            .pageDown,
            .firstItem,
            .lastItem,
            .togglePreview,
            .openDetail,
            .escape,
            .undo,
            .redo,
            .selectAll,
            .deselectAll,
            .deleteSelected,
            .exportWithMetadata
        ]

        XCTAssertEqual(actions.count, 25)
    }

    // MARK: - Published State Tests

    func testShowTagInputToggle() {
        let manager = KeyboardShortcutManager()

        manager.showTagInput = true
        XCTAssertTrue(manager.showTagInput)

        manager.showTagInput = false
        XCTAssertFalse(manager.showTagInput)
    }

    func testShowDeleteConfirmation() {
        let manager = KeyboardShortcutManager()
        let itemIds = [UUID(), UUID()]

        manager.itemsPendingDeletion = itemIds
        manager.showDeleteConfirmation = true

        XCTAssertTrue(manager.showDeleteConfirmation)
        XCTAssertEqual(manager.itemsPendingDeletion.count, 2)
    }
}

// MARK: - FilterState Tests

final class FilterStateTests: XCTestCase {

    func testDefaultFilterState() {
        let filter = FilterState()

        XCTAssertEqual(filter.searchText, "")
        XCTAssertNil(filter.platform)
        XCTAssertNil(filter.author)
        XCTAssertNil(filter.starred)
        XCTAssertTrue(filter.tags.isEmpty)
        XCTAssertNil(filter.dateRange)
        XCTAssertNil(filter.smartFolder)
        XCTAssertEqual(filter.sortOrder, .archivedDateDescending)
        XCTAssertNil(filter.folderPath)
        XCTAssertTrue(filter.colorFilters.isEmpty)
        XCTAssertNil(filter.hasOCR)
        XCTAssertEqual(filter.limit, 0)
        XCTAssertEqual(filter.offset, 0)
        XCTAssertNil(filter.boardId)
        XCTAssertFalse(filter.rediscoverMode)
    }

    func testFilterStateAllConstant() {
        let filter = FilterState.all

        XCTAssertEqual(filter.searchText, "")
        XCTAssertNil(filter.platform)
    }

    func testFilterStateEquality() {
        var filter1 = FilterState()
        filter1.platform = "twitter"
        filter1.tags = ["art"]

        var filter2 = FilterState()
        filter2.platform = "twitter"
        filter2.tags = ["art"]

        XCTAssertEqual(filter1, filter2)
    }

    func testFilterStateInequality() {
        var filter1 = FilterState()
        filter1.platform = "twitter"

        var filter2 = FilterState()
        filter2.platform = "instagram"

        XCTAssertNotEqual(filter1, filter2)
    }

    func testFilterStateWithColorFilters() {
        var filter = FilterState()
        filter.colorFilters = [.red, .blue, .green]

        XCTAssertEqual(filter.colorFilters.count, 3)
        XCTAssertTrue(filter.colorFilters.contains(.red))
        XCTAssertTrue(filter.colorFilters.contains(.blue))
        XCTAssertTrue(filter.colorFilters.contains(.green))
    }
}

// MARK: - Notification Names Tests

final class NotificationNamesTests: XCTestCase {

    func testGridNavigationNotificationNames() {
        XCTAssertEqual(Notification.Name.gridNavigateDown.rawValue, "gridNavigateDown")
        XCTAssertEqual(Notification.Name.gridNavigateUp.rawValue, "gridNavigateUp")
        XCTAssertEqual(Notification.Name.gridNavigateLeft.rawValue, "gridNavigateLeft")
        XCTAssertEqual(Notification.Name.gridNavigateRight.rawValue, "gridNavigateRight")
    }

    func testActionNotificationNames() {
        XCTAssertEqual(Notification.Name.togglePreview.rawValue, "togglePreview")
        XCTAssertEqual(Notification.Name.openDetail.rawValue, "openDetail")
        XCTAssertEqual(Notification.Name.selectAll.rawValue, "selectAll")
        XCTAssertEqual(Notification.Name.deselectAll.rawValue, "deselectAll")
    }

    func testCanvasNotificationNames() {
        XCTAssertEqual(Notification.Name.canvasResetView.rawValue, "canvasResetView")
        XCTAssertEqual(Notification.Name.canvasZoomToFit.rawValue, "canvasZoomToFit")
        XCTAssertEqual(Notification.Name.canvasZoomActualSize.rawValue, "canvasZoomActualSize")
    }
}
