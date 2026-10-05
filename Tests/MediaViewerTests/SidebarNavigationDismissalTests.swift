import XCTest
@testable import MediaViewer

final class SidebarNavigationDismissalTests: XCTestCase {
    func testSidebarSelectionDismissesEveryDestinationSynchronously() {
        let selections: [SidebarSelection] = [
            .allMedia,
            .folderYear("2026"),
            .folder("2026-08"),
            .smartFolder(UUID()),
            .board(UUID()),
            .canvas(UUID()),
            .platform("web"),
            .tag("favorite"),
            .rediscover,
            .duplicates,
            .visualClusters
        ]

        for selection in selections {
            var dismissCount = 0

            SingleFocusSidebarNavigationPolicy.handleSelectionChange(selection) {
                dismissCount += 1
            }

            XCTAssertEqual(dismissCount, 1, "Expected \(selection) to dismiss detail immediately")
        }
    }
}
