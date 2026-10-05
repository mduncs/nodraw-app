import Combine
import XCTest
@testable import MediaViewer

/// The grid mirrors `$focusedID` back into its selection (GridDataModifier). Choosing a tag in
/// the sidebar from detail leaves the open item outside the new display order; selecting it
/// there must settle instead of ping-ponging between clear() and select() at 100% CPU.
@MainActor
final class SelectionFocusSettleTests: XCTestCase {
    private func item(_ name: String) -> MediaItem {
        MediaItem(id: UUID(), basePath: URL(fileURLWithPath: "/tmp/focus-settle"),
                  metadataFile: URL(fileURLWithPath: "/tmp/focus-settle/\(name).md"),
                  mediaFiles: [URL(fileURLWithPath: "/tmp/focus-settle/\(name).jpg")],
                  metadata: MediaMetadata(source: URL(string: "https://example.com/\(name)")!, platform: "test"))
    }

    func testSelectingAnItemOutsideTheDisplayOrderNeverPublishesATransientNilFocus() {
        let store = MediaSelectionStore()
        let shown = [item("a"), item("b")]
        store.replaceItems(shown)
        store.select(shown[0].id)
        let offscreen = item("detail")
        var emitted: [UUID?] = []
        let subscription = store.$focusedID.dropFirst().sink { emitted.append($0) }
        defer { subscription.cancel() }

        store.select(offscreen.id)
        XCTAssertFalse(emitted.contains(nil), "focus emitted \(emitted)")
        XCTAssertEqual(store.focusedID, offscreen.id)
        XCTAssertEqual(store.selectedIDs, [offscreen.id])
    }

    func testGridFocusMirrorSettlesWhenFocusedItemIsNotDisplayed() async throws {
        let app = AppState()
        let grid = MasonryGridViewModel()
        grid.setSelectionStore(app.mediaSelectionStore)
        let shown = [item("a"), item("b"), item("c")]
        app.setDisplayContext(surface: .grid, items: shown)
        grid.select(shown[1].id)

        // GridDataModifier's `$focusedID` receiver, delivered after the change.
        var deliveries = 0
        let mirror = app.mediaSelectionStore.$focusedID
            .receive(on: DispatchQueue.main)
            .sink { newID in
                deliveries += 1
                grid.followFocus(newID)
            }
        defer { mirror.cancel() }

        let detail = item("detail")
        app.mediaSelectionStore.select(detail.id)
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 2_000_000) }

        XCTAssertLessThan(deliveries, 8, "focus mirror kept re-selecting (\(deliveries) deliveries)")
        XCTAssertEqual(app.mediaSelectionStore.focusedID, detail.id)
        XCTAssertEqual(app.mediaSelectionStore.selectedIDs, [detail.id])
    }
}
