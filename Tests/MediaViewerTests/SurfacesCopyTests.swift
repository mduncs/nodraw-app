import XCTest
@testable import MediaViewer

@MainActor
final class SurfacesCopyTests: XCTestCase {
    func testDownloadServerRelativeAgeBuckets() {
        XCTAssertEqual(DownloadsSettingsTab.relativeAge(-3), "just now")
        XCTAssertEqual(DownloadsSettingsTab.relativeAge(4.9), "just now")
        XCTAssertEqual(DownloadsSettingsTab.relativeAge(42), "42s ago")
        XCTAssertEqual(DownloadsSettingsTab.relativeAge(125), "2m ago")
        XCTAssertEqual(DownloadsSettingsTab.relativeAge(7_300), "2h ago")
        XCTAssertEqual(DownloadsSettingsTab.relativeAge(200_000), "2d ago")
    }

    func testDuplicateCountsPluralize() {
        XCTAssertEqual(DuplicateTriageViewModel.counted(1, "group"), "1 group")
        XCTAssertEqual(DuplicateTriageViewModel.counted(0, "group"), "0 groups")
        XCTAssertEqual(DuplicateTriageViewModel.counted(2, "whole item"), "2 whole items")
    }
}
