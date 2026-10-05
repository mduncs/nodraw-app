import XCTest
@testable import MediaViewer

final class FocusDetailScopeTests: XCTestCase {
    func testToolbarDeleteScopeMatchesTheActualSingleFocusAction() {
        XCTAssertEqual(FocusDeleteScopePolicy.toolbarScope(fileCount: 0), .wholeItem)
        XCTAssertEqual(FocusDeleteScopePolicy.toolbarScope(fileCount: 1), .wholeItem)
        XCTAssertEqual(FocusDeleteScopePolicy.toolbarScope(fileCount: 3), .currentFile)
    }

    func testCurrentFileConfirmationNeverClaimsAssociatedFilesAreBeingDeleted() {
        XCTAssertEqual(
            DeleteConfirmationCopy.title(scope: .currentFile, itemCount: 1, fileCount: 3, contextFileCount: 1),
            "Delete this file?"
        )
        XCTAssertEqual(
            DeleteConfirmationCopy.detail(scope: .currentFile, fileCount: 3, contextFileCount: 1),
            "Current file of 3 · context screenshot retained"
        )
    }

    func testWholeItemConfirmationIncludesMediaAndContextFiles() {
        XCTAssertEqual(
            DeleteConfirmationCopy.title(scope: .wholeItem, itemCount: 1, fileCount: 3, contextFileCount: 1),
            "Delete item and 3 associated files?"
        )
        XCTAssertEqual(
            DeleteConfirmationCopy.detail(scope: .wholeItem, fileCount: 3, contextFileCount: 1),
            "3 files + 1 context screenshot"
        )
    }

    func testWholeItemConfirmationHandlesContextOnlyItems() {
        XCTAssertEqual(
            DeleteConfirmationCopy.title(scope: .wholeItem, itemCount: 1, fileCount: 0, contextFileCount: 1),
            "Delete item and 1 context screenshot?"
        )
        XCTAssertEqual(
            DeleteConfirmationCopy.detail(scope: .wholeItem, fileCount: 0, contextFileCount: 1),
            "1 context screenshot"
        )
    }

    func testContextMenuPlacementClampsFullMenuToVisibleBounds() {
        XCTAssertEqual(
            ContextMenuPlacement.origin(
                for: CGPoint(x: 780, y: 580),
                menuSize: CGSize(width: 220, height: 340),
                containerSize: CGSize(width: 800, height: 600)
            ),
            CGPoint(x: 572, y: 252)
        )
        XCTAssertEqual(
            ContextMenuPlacement.origin(
                for: CGPoint(x: 400, y: 300),
                menuSize: CGSize(width: 220, height: 340),
                containerSize: CGSize(width: 800, height: 600)
            ),
            CGPoint(x: 400, y: 252),
            "The menu's click-relative origin must clamp the full menu inside the viewport"
        )
    }

    func testContextMenuViewportKeepsAnOversizedMenuScrollableInsideSmallMediaArea() {
        let viewport = ContextMenuPlacement.viewportSize(
            menuSize: CGSize(width: 220, height: 340),
            containerSize: CGSize(width: 180, height: 140)
        )
        let origin = ContextMenuPlacement.origin(
            for: CGPoint(x: 160, y: 120),
            menuSize: CGSize(width: 220, height: 340),
            containerSize: CGSize(width: 180, height: 140)
        )

        XCTAssertEqual(viewport, CGSize(width: 164, height: 124))
        XCTAssertEqual(origin, CGPoint(x: 8, y: 8))
        XCTAssertLessThanOrEqual(origin.x + viewport.width, 172)
        XCTAssertLessThanOrEqual(origin.y + viewport.height, 132)
    }
}
