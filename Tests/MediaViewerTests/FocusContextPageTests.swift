import XCTest
@testable import MediaViewer

/// The context screenshot is the last page of an item's multi-image sequence, not a display mode.
final class FocusContextPageTests: XCTestCase {
    func testPageBuildingForImagesVideoGalleryAndContextOnly() {
        let image = URL(fileURLWithPath: "/fixture/item.png")
        let video = URL(fileURLWithPath: "/fixture/item.mp4")
        let second = URL(fileURLWithPath: "/fixture/item-2.png")
        let third = URL(fileURLWithPath: "/fixture/item-3.png")
        let context = URL(fileURLWithPath: "/fixture/item.context.png")
        for (media, screenshot, expected) in [
            ([image], nil, [image]),
            ([image], context, [image, context]),
            ([video], context, [video, context]),
            ([image, second, third], context, [image, second, third, context]),
            ([], context, [context])
        ] {
            let pages = SingleFocusPagePolicy.pages(mediaFiles: media, contextImage: screenshot)
            XCTAssertEqual(pages, expected)
            XCTAssertEqual(SingleFocusPagePolicy.pageCount(mediaCount: media.count,
                hasContextPage: screenshot != nil), expected.count)
        }
        XCTAssertTrue(SingleFocusPagePolicy.pages(mediaFiles: [], contextImage: nil).isEmpty)
    }

    func testContextPreferenceSelectsTheScreenshotForAllMixedAndContextOnlyCases() {
        for mediaCount in [0, 1, 3] {
            let index = SingleFocusPagePolicy.initialPageIndex(mediaCount: mediaCount,
                hasContextPage: true, prefersContext: true, navigationDirection: .forward)
            XCTAssertEqual(index, mediaCount)
            XCTAssertTrue(SingleFocusPagePolicy.isContextPage(index, mediaCount: mediaCount,
                hasContextPage: true))
        }
    }

    func testContextScreenshotIsTheLastPage() {
        XCTAssertEqual(SingleFocusPagePolicy.pageCount(mediaCount: 3, hasContextPage: true), 4)
        XCTAssertEqual(SingleFocusPagePolicy.pageCount(mediaCount: 1, hasContextPage: true), 2)
        XCTAssertEqual(SingleFocusPagePolicy.pageCount(mediaCount: 3, hasContextPage: false), 3)

        XCTAssertTrue(SingleFocusPagePolicy.isContextPage(3, mediaCount: 3, hasContextPage: true))
        XCTAssertFalse(SingleFocusPagePolicy.isContextPage(2, mediaCount: 3, hasContextPage: true))
        XCTAssertFalse(SingleFocusPagePolicy.isContextPage(3, mediaCount: 3, hasContextPage: false))
    }

    func testArrowsWalkMediaThenContextThenNextItem() {
        let pages = SingleFocusPagePolicy.pageCount(mediaCount: 1, hasContextPage: true)

        XCTAssertEqual(
            SingleFocusNavigationPolicy.action(for: .nextMediaOrItem, selectedMediaIndex: 0, mediaCount: pages),
            .selectMedia(index: 1),
            "A single image with a context screenshot browses to the screenshot like a second image"
        )
        XCTAssertEqual(
            SingleFocusNavigationPolicy.action(for: .nextMediaOrItem, selectedMediaIndex: 1, mediaCount: pages),
            .nextItem
        )
        XCTAssertEqual(
            SingleFocusNavigationPolicy.action(for: .previousMediaOrItem, selectedMediaIndex: 1, mediaCount: pages),
            .selectMedia(index: 0)
        )
    }

    func testStoredContextPreferenceOnlyChoosesTheFirstPage() {
        XCTAssertEqual(
            SingleFocusPagePolicy.initialPageIndex(
                mediaCount: 3, hasContextPage: true, prefersContext: true, navigationDirection: .forward
            ),
            3
        )
        XCTAssertEqual(
            SingleFocusPagePolicy.initialPageIndex(
                mediaCount: 3, hasContextPage: true, prefersContext: false, navigationDirection: .backward
            ),
            0
        )
        XCTAssertEqual(
            SingleFocusPagePolicy.initialPageIndex(
                mediaCount: 0, hasContextPage: false, prefersContext: true, navigationDirection: .forward
            ),
            0,
            "A preference cannot select an absent context page"
        )
    }

    func testRightClickHitTestUsesTheVisibleMediaArea() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let visible = CGRect(x: 0, y: 100, width: 800, height: 500)

        XCTAssertEqual(
            FocusRightClickHitTest.menuPoint(
                forLocalPoint: CGPoint(x: 40, y: 500), bounds: bounds, visibleRect: visible, isFlipped: false
            ),
            CGPoint(x: 40, y: 100)
        )
        XCTAssertEqual(
            FocusRightClickHitTest.menuPoint(
                forLocalPoint: CGPoint(x: 40, y: 500), bounds: bounds, visibleRect: visible, isFlipped: true
            ),
            CGPoint(x: 40, y: 500)
        )
        XCTAssertNil(
            FocusRightClickHitTest.menuPoint(
                forLocalPoint: CGPoint(x: 40, y: 50), bounds: bounds, visibleRect: visible, isFlipped: false
            ),
            "Clicks in a clipped-off part of the media area are not ours"
        )
        XCTAssertNil(
            FocusRightClickHitTest.menuPoint(
                forLocalPoint: CGPoint(x: 900, y: 300), bounds: bounds, visibleRect: visible, isFlipped: false
            ),
            "Clicks outside the media area (inspector, related panel) keep their native menus"
        )
        XCTAssertNil(
            FocusRightClickHitTest.menuPoint(
                forLocalPoint: .zero, bounds: .zero, visibleRect: .zero, isFlipped: false
            ),
            "A zero-sized overlay never claims the whole window"
        )
    }
}
