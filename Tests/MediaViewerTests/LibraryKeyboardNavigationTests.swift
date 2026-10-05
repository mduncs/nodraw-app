import AppKit
import XCTest
@testable import MediaViewer

@MainActor
final class LibraryKeyboardNavigationTests: XCTestCase {
    func testPageMovementKeepsTenPercentContinuityOverlap() {
        XCTAssertEqual(
            LibraryViewportScrollGeometry.continuityOverlap(for: 800),
            80,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LibraryViewportScrollGeometry.targetOffset(
                for: .pageDown,
                currentOffset: 500,
                viewportHeight: 800,
                contentMinY: 0,
                contentMaxY: 5_000
            ),
            1_220,
            accuracy: 0.001
        )
        XCTAssertEqual(
            LibraryViewportScrollGeometry.targetOffset(
                for: .pageUp,
                currentOffset: 1_220,
                viewportHeight: 800,
                contentMinY: 0,
                contentMaxY: 5_000
            ),
            500,
            accuracy: 0.001
        )
    }

    func testPageAndTerminalMovementClampToScrollableRange() {
        XCTAssertEqual(
            LibraryViewportScrollGeometry.targetOffset(
                for: .pageUp,
                currentOffset: 20,
                viewportHeight: 600,
                contentMinY: 0,
                contentMaxY: 2_000
            ),
            0
        )
        XCTAssertEqual(
            LibraryViewportScrollGeometry.targetOffset(
                for: .pageDown,
                currentOffset: 1_300,
                viewportHeight: 600,
                contentMinY: 0,
                contentMaxY: 2_000
            ),
            1_400
        )
        XCTAssertEqual(
            LibraryViewportScrollGeometry.targetOffset(
                for: .first,
                currentOffset: 900,
                viewportHeight: 600,
                contentMinY: 100,
                contentMaxY: 2_000
            ),
            100
        )
        XCTAssertEqual(
            LibraryViewportScrollGeometry.targetOffset(
                for: .last,
                currentOffset: 0,
                viewportHeight: 600,
                contentMinY: 100,
                contentMaxY: 2_000
            ),
            1_400
        )
    }

    func testScrollerMovesActualClipViewByComputedPage() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.documentView = FlippedNavigationTestView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 3_000)
        )
        scrollView.layoutSubtreeIfNeeded()
        let clipView = scrollView.contentView
        let expected = LibraryViewportScrollGeometry.targetOffset(
            for: .pageDown,
            currentOffset: clipView.bounds.origin.y,
            viewportHeight: clipView.bounds.height,
            contentMinY: scrollView.documentView!.bounds.minY,
            contentMaxY: scrollView.documentView!.bounds.maxY
        )

        XCTAssertTrue(LibraryViewportScroller.apply(.pageDown, to: scrollView))

        XCTAssertEqual(clipView.bounds.origin.y, expected, accuracy: 0.001)
    }

    func testSpecialKeyShortcutLabelsAreTruthful() {
        XCTAssertEqual(
            GlobalShortcut(keyCode: 116, modifiers: [], action: .pageUp, context: .grid).displayString,
            "Page Up"
        )
        XCTAssertEqual(
            GlobalShortcut(keyCode: 121, modifiers: [], action: .pageDown, context: .grid).displayString,
            "Page Down"
        )
        XCTAssertEqual(
            GlobalShortcut(keyCode: 115, modifiers: [], action: .firstItem, context: .grid).displayString,
            "Home"
        )
        XCTAssertEqual(
            GlobalShortcut(keyCode: 119, modifiers: [], action: .lastItem, context: .grid).displayString,
            "End"
        )
    }

    func testPageAndShiftArrowMatchingIgnoresOnlySystemFunctionFlags() throws {
        let pageDown = GlobalShortcut(
            keyCode: 121,
            modifiers: [],
            action: .pageDown,
            context: .grid
        )
        let pageEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.function],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 121
            )
        )
        XCTAssertTrue(pageDown.matches(event: pageEvent, currentContext: .grid))

        let shiftRight = GlobalShortcut(
            keyCode: 124,
            modifiers: [.shift],
            action: .extendSelectionRight,
            context: .grid
        )
        let shiftRightEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.shift, .numericPad],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 124
            )
        )
        XCTAssertTrue(shiftRight.matches(event: shiftRightEvent, currentContext: .grid))
    }

    func testHorizontalNavigationStopsAtSpatialEdgesInsteadOfFollowingDisplayOrder() {
        let viewModel = configuredViewModel(
            aspectRatios: [0.4, 0.4, 0.4, 0.4, 0.4],
            columnCount: 3
        )
        let items = viewModel.items
        XCTAssertEqual(viewModel.columns.map { $0.map(\.id) }, [
            [items[0].id, items[3].id],
            [items[1].id, items[4].id],
            [items[2].id],
        ])

        viewModel.select(items[2].id)
        viewModel.selectRight()
        XCTAssertEqual(viewModel.selectedItemID, items[2].id)
        XCTAssertFalse(viewModel.shouldScrollToSelection)

        viewModel.select(items[3].id)
        viewModel.selectLeft()
        XCTAssertEqual(viewModel.selectedItemID, items[3].id)
        XCTAssertFalse(viewModel.shouldScrollToSelection)
    }

    func testHorizontalNavigationUsesClosestAdjacentItemRegardlessOfDisplayOrder() {
        let viewModel = configuredViewModel(
            aspectRatios: [0.4, 0.6, 0.4, 0.4, 0.6],
            columnCount: 3
        )
        let items = viewModel.items
        XCTAssertEqual(viewModel.columns.map { $0.map(\.id) }, [
            [items[0].id, items[4].id],
            [items[1].id, items[3].id],
            [items[2].id],
        ])

        viewModel.select(items[4].id)
        viewModel.selectRight()
        XCTAssertEqual(viewModel.selectedItemID, items[3].id)
        XCTAssertTrue(viewModel.shouldScrollToSelection)

        viewModel.select(items[3].id)
        viewModel.selectLeft()
        XCTAssertEqual(viewModel.selectedItemID, items[4].id)
        XCTAssertTrue(viewModel.shouldScrollToSelection)
    }

    func testShiftHorizontalStopsAtSpatialEdgesWithoutExtendingSelection() {
        let viewModel = configuredViewModel(
            aspectRatios: [0.4, 0.4, 0.4, 0.4, 0.4],
            columnCount: 3
        )
        let items = viewModel.items

        viewModel.select(items[2].id)
        viewModel.extendSelectionRight()
        XCTAssertEqual(viewModel.selectedIDs, [items[2].id])
        XCTAssertEqual(viewModel.selectionAnchor, items[2].id)
        XCTAssertFalse(viewModel.shouldScrollToSelection)

        viewModel.select(items[3].id)
        viewModel.extendSelectionLeft()
        XCTAssertEqual(viewModel.selectedIDs, [items[3].id])
        XCTAssertEqual(viewModel.selectionAnchor, items[3].id)
        XCTAssertFalse(viewModel.shouldScrollToSelection)
    }

    func testShiftHorizontalUsesSameClosestAdjacentItemRegardlessOfDisplayOrder() {
        let viewModel = configuredViewModel(
            aspectRatios: [0.4, 0.6, 0.4, 0.4, 0.6],
            columnCount: 3
        )
        let items = viewModel.items

        viewModel.select(items[4].id)
        viewModel.extendSelectionRight()
        XCTAssertEqual(viewModel.selectedIDs, Set([items[4].id, items[3].id]))
        XCTAssertEqual(viewModel.selectionAnchor, items[3].id)
        XCTAssertTrue(viewModel.shouldScrollToSelection)

        viewModel.select(items[3].id)
        viewModel.extendSelectionLeft()
        XCTAssertEqual(viewModel.selectedIDs, Set([items[3].id, items[4].id]))
        XCTAssertEqual(viewModel.selectionAnchor, items[4].id)
        XCTAssertTrue(viewModel.shouldScrollToSelection)
    }

    func testTableSelectAllUsesVisibleDisplayOrder() {
        let viewModel = TableBrowserViewModel()
        let items = makeItems(count: 4)
        viewModel.setItems(items)

        viewModel.selectAll()

        XCTAssertEqual(viewModel.selectedIDs, Set(items.map(\.id)))
    }

    func testPaletteDoesNotAdvertiseUnwiredShortcutsOrNoOpSidebarFocus() {
        let registry = CommandRegistry.shared
        registry.clearAll()
        defer { registry.clearAll() }
        let appState = AppState()

        registry.registerDefaultCommands(appState: appState)

        XCTAssertNil(registry.command(id: "nav.sidebar"))
        XCTAssertNil(registry.command(id: "action.revealFinder")?.shortcut)
        XCTAssertNil(registry.command(id: "filter.all")?.shortcut)
        XCTAssertNil(registry.command(id: "filter.hasOCR")?.shortcut)
        XCTAssertEqual(registry.command(id: "nav.pageUp")?.shortcut?.displayString, "Page Up")
        XCTAssertEqual(registry.command(id: "nav.pageDown")?.shortcut?.displayString, "Page Down")
        XCTAssertFalse(registry.command(id: "nav.pageDown")?.isEnabled(appState) ?? true)
    }

    func testViewportCommandsAreAvailableOnlyOnPrimaryPopulatedLibrarySurfaces() {
        let appState = AppState()
        let items = makeItems(count: 2)
        appState.setDisplayContext(surface: .grid, items: items)

        XCTAssertTrue(LibraryViewportCommandRouter.isAvailable(in: appState))

        appState.sidebarSelection = .board(UUID())
        XCTAssertFalse(LibraryViewportCommandRouter.isAvailable(in: appState))
    }

    private func configuredViewModel(
        aspectRatios: [CGFloat],
        columnCount: Int
    ) -> MasonryGridViewModel {
        let viewModel = MasonryGridViewModel()
        viewModel.setColumnCount(columnCount)
        viewModel.setContainerWidth(900)
        viewModel.setItems(makeItems(aspectRatios: aspectRatios))
        return viewModel
    }

    private func makeItems(count: Int) -> [MediaItem] {
        makeItems(aspectRatios: Array(repeating: 1, count: count))
    }

    private func makeItems(aspectRatios: [CGFloat]) -> [MediaItem] {
        aspectRatios.enumerated().map { index, aspectRatio in
            let id = UUID()
            let basePath = URL(fileURLWithPath: "/archive/2026-01")
            return MediaItem(
                id: id,
                basePath: basePath,
                metadataFile: basePath.appendingPathComponent("item-\(index).md"),
                mediaFiles: [basePath.appendingPathComponent("item-\(index).jpg")],
                metadata: MediaMetadata(
                    source: URL(string: "https://example.com/\(index)")!,
                    platform: "test"
                ),
                aspectRatio: aspectRatio
            )
        }
    }
}

private final class FlippedNavigationTestView: NSView {
    override var isFlipped: Bool { true }
}
