import AppKit
import Combine
import XCTest
@testable import MediaViewer

@MainActor
final class LibraryInteractionPerformanceTests: XCTestCase {
    func testMasonryArrowNavigationUsesBoundedIndexedProbes() throws {
        let viewModel = MasonryGridViewModel()
        viewModel.setColumnCount(8)
        viewModel.setContainerWidth(1_600)
        viewModel.setItems(makeItems(count: 4_096))

        let source = try XCTUnwrap(viewModel.columns[3].dropFirst(400).first)
        viewModel.select(source.id)
        viewModel.selectRight()

        XCTAssertNotEqual(viewModel.selectedItemID, source.id)
        XCTAssertLessThanOrEqual(viewModel.lastNavigationProbeCount, 20)
    }

    func testPaginationVisitsOnlyNewLayoutItemsAndMatchesFullDistribution() {
        let firstPage = makeItems(count: 240, startingAt: 0)
        let secondPage = makeItems(count: 240, startingAt: 240)

        let incremental = MasonryGridViewModel()
        incremental.setColumnCount(6)
        incremental.setContainerWidth(1_200)
        incremental.setItems(firstPage)
        incremental.appendItems(secondPage)

        let full = MasonryGridViewModel()
        full.setColumnCount(6)
        full.setContainerWidth(1_200)
        full.setItems(firstPage + secondPage)

        XCTAssertEqual(incremental.lastColumnLayoutItemVisitCount, secondPage.count)
        XCTAssertEqual(full.lastColumnLayoutItemVisitCount, firstPage.count + secondPage.count)
        XCTAssertEqual(incremental.columns.map { $0.map(\.id) }, full.columns.map { $0.map(\.id) })
        XCTAssertEqual(incremental.columnHeights.count, full.columnHeights.count)
        for (incrementalHeight, fullHeight) in zip(incremental.columnHeights, full.columnHeights) {
            XCTAssertEqual(incrementalHeight, fullHeight, accuracy: 0.001)
        }
    }

    func testTableSkipsIdenticalSnapshotReplacementAndMaintainsUUIDIndex() throws {
        let items = makeItems(count: 2_000)
        let viewModel = TableBrowserViewModel()

        viewModel.setItems(items)
        XCTAssertEqual(viewModel.collectionReplacementCount, 1)
        XCTAssertEqual(viewModel.lastCollectionIndexBuildItemCount, items.count)
        XCTAssertEqual(viewModel.item(for: items.last!.id), items.last)

        viewModel.setItems(items)
        XCTAssertEqual(viewModel.collectionReplacementCount, 1)
        XCTAssertEqual(viewModel.lastCollectionIndexBuildItemCount, 0)
        XCTAssertTrue(viewModel.containsItem(items[1_500].id))
    }

    func testTableCopyUsesOneNamedFixedSchemaForOneOrManyRows() {
        let items = makeItems(count: 2)
        let single = TableCopyPolicy.tsv(items: [items[0]]).components(separatedBy: "\n")
        let multiple = TableCopyPolicy.tsv(items: items).components(separatedBy: "\n")

        XCTAssertEqual(single.count, 2, "Header and one row")
        XCTAssertEqual(multiple.count, 3, "Header and both selected rows")
        XCTAssertEqual(single[0], TableCopyPolicy.headers.joined(separator: "\t"))
        XCTAssertEqual(multiple[0], single[0])
        XCTAssertEqual(single[1].split(separator: "\t", omittingEmptySubsequences: false).count, TableCopyPolicy.headers.count)
        XCTAssertEqual(multiple[1].split(separator: "\t", omittingEmptySubsequences: false).count, TableCopyPolicy.headers.count)
        XCTAssertEqual(multiple[2].split(separator: "\t", omittingEmptySubsequences: false).count, TableCopyPolicy.headers.count)
    }

    func testRightClickingSelectedGridItemPreservesSelectionAndOtherClicksReplaceIt() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let selection: Set<UUID> = [first, second]

        XCTAssertEqual(
            MasonryContextSelectionPolicy.targetIDs(clickedID: second, selectedIDs: selection),
            selection
        )
        XCTAssertEqual(
            MasonryContextSelectionPolicy.targetIDs(clickedID: third, selectedIDs: selection),
            [third]
        )
    }

    func testBatchDeleteConfirmationNamesTheCapturedDiskBehavior() {
        XCTAssertEqual(
            BatchDeleteConfirmationCopy.message(deleteFromDisk: false),
            "This will remove the items from the library. Files on disk will not be deleted."
        )
        XCTAssertEqual(
            BatchDeleteConfirmationCopy.message(deleteFromDisk: true),
            "This will remove the items from the library and move their files to Trash."
        )
    }

    func testViewportBridgeScansHierarchyOnlyOnceAfterBinding() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentView!.bounds)
        let scrollView = NSScrollView(frame: root.bounds)
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 2_000))
        let bridge = LibraryViewportCommandView(frame: root.bounds)
        root.addSubview(scrollView)
        root.addSubview(bridge)
        window.contentView = root

        XCTAssertTrue(try XCTUnwrap(bridge.resolveLibraryScrollView()) === scrollView)
        XCTAssertEqual(bridge.fullHierarchySearchCount, 1)
        XCTAssertTrue(try XCTUnwrap(bridge.resolveLibraryScrollView()) === scrollView)
        XCTAssertEqual(bridge.fullHierarchySearchCount, 1)
    }

    func testNativeTableRevealCentersSelectedRowWithoutRowIdentityScan() {
        let dataSource = PerformanceTableDataSource(rowCount: 200)
        let tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 4_000))
        tableView.rowHeight = 20
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value")))
        tableView.dataSource = dataSource
        tableView.reloadData()

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = tableView
        tableView.selectRowIndexes(IndexSet(integer: 160), byExtendingSelection: false)

        XCTAssertTrue(TableSelectionRevealScroller.revealSelection(in: tableView))
        XCTAssertTrue(tableView.visibleRect.intersects(tableView.rect(ofRow: 160)))
        XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 0)
    }

    func testFiftyJobCompletionRefreshMeasurement() {
        let appState = AppState()
        let vm = MasonryGridViewModel()
        vm.setSelectionStore(appState.mediaSelectionStore)
        let items = makeItems(count: 2_000)
        vm.setItems(items)
        appState.setDisplayContext(surface: .grid, items: items)
        var selectionPublishes = 0
        let selectionSubscription = appState.mediaSelectionStore.$items.dropFirst().sink { _ in selectionPublishes += 1 }
        var publishes = 0
        let subscription = vm.$columns.dropFirst().sink { _ in publishes += 1 }
        let updates = items.prefix(50).map { item in
            var updated = item
            updated.metadata.starred = true
            return updated
        }
        let start = CFAbsoluteTimeGetCurrent()
        appState.replaceDisplayedItemsIfPresent(updates)
        let milliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1_000
        print("GRID_JOB_REFRESH mode=batch jobs=50 loaded=2000 columns=\(publishes) main_ms=\(milliseconds)")
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(selectionPublishes, 1)
        withExtendedLifetime(selectionSubscription) {}
        withExtendedLifetime(subscription) {}
    }

    private func makeItems(count: Int, startingAt start: Int = 0) -> [MediaItem] {
        (start..<(start + count)).map { index in
            let basePath = URL(fileURLWithPath: "/archive/perf")
            return MediaItem(
                id: UUID(),
                basePath: basePath,
                metadataFile: basePath.appendingPathComponent("item-\(index).md"),
                mediaFiles: [basePath.appendingPathComponent("item-\(index).jpg")],
                metadata: MediaMetadata(
                    source: URL(string: "https://example.com/\(index)")!,
                    platform: "test"
                ),
                aspectRatio: CGFloat((index % 7) + 4) / 7
            )
        }
    }
}

private final class PerformanceTableDataSource: NSObject, NSTableViewDataSource {
    let rowCount: Int

    init(rowCount: Int) {
        self.rowCount = rowCount
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rowCount
    }
}
