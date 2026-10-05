import XCTest
@testable import MediaViewer

final class TagOverlayIdentityTests: XCTestCase {
    func testHoldReleaseRemovesCaseAndUnicodeVariantsInsteadOfAdding() {
        let tags = ["CAFE\u{301}", "Café", "Keep"]
        XCTAssertTrue(TagOverlaySelection.contains("café", in: tags))
        XCTAssertEqual(TagOverlaySelection.toggled("café", in: tags), ["Keep"])
    }

    func testPickerDiffDoesNotScheduleAddAndRemoveForSameCanonicalTag() {
        let changes = TagOverlaySelection.changes(from: ["CAFE\u{301}", "Old"], to: ["Café", "New", "NEW"])
        XCTAssertEqual(changes.added, ["New"])
        XCTAssertEqual(changes.removed, ["Old"])
    }

    func testNewTagPreservesDisplaySpellingAndBlankToggleDoesNothing() {
        XCTAssertEqual(TagOverlaySelection.toggled(" New Tag ", in: ["Keep"]), ["Keep", "New Tag"])
        XCTAssertEqual(TagOverlaySelection.toggled(" ", in: ["Keep"]), ["Keep"])
    }
}
