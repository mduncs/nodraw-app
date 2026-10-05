import AppKit
import SwiftUI
import XCTest
@testable import MediaViewer

/// Bug report, 2026-10-04: Delete in the library left both deleted tiles drawn in their old
/// places. The Delete key goes through AppState.deleteItems and the store notification, not
/// the grid's own delete, so this hosts the whole container against an isolated database.
@MainActor
final class GridDeleteRouteTests: XCTestCase {
    @MainActor private final class Host {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let state: AppState
        init(store: MediaStore) {
            state = AppState(mediaStore: store)
            host = NSHostingView(rootView: AnyView(MasonryGridContainer()
                .environmentObject(state).environment(SettingsStore.shared)))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_440, height: 900),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
        }
        func close() { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        func settle(_ rounds: Int = 60) async throws {
            for _ in 0..<rounds {
                _ = RunLoop.main.run(mode: .default, before: Date())
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func drawn() -> [String] {
            guard let scroll = descendants(host).compactMap({ $0 as? MiddleMouseAutoScrollView }).first?
                    .resolveLibraryScrollView(), let document = scroll.documentView else { return [] }
            return descendants(host).compactMap { $0 as? RightClickView }
                .map { $0.convert($0.bounds, to: document) }
                .filter { $0.width > 1 && $0.height > 1 }
                .map { "\(Int($0.minX.rounded())),\(Int($0.minY.rounded())) \(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
                .sorted()
        }
    }

    func testDeleteKeyRouteRedrawsLikeAFreshGrid() async throws {
        let env = ProcessInfo.processInfo.environment
        let support = try XCTUnwrap(env["NODRAW_APP_SUPPORT_DIR"])
        let archive = try XCTUnwrap(env["NODRAW_ARCHIVE_PATH"])
        guard support.hasPrefix(NSTemporaryDirectory()) else {
            throw XCTSkip("needs an isolated NODRAW_APP_SUPPORT_DIR")
        }
        try await DatabaseManager.shared.initialize()
        let store = MediaStore(database: DatabaseManager.shared)
        let root = URL(fileURLWithPath: archive).appendingPathComponent("delete-route-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ratios: [CGFloat] = [0.4, 0.6, 1, 1.4, 1.8, 2.5]
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let items = try (0..<300).map { index -> MediaItem in
            let sidecar = root.appendingPathComponent("\(index).md")
            try "---\nplatform: test\nsource: https://example.com/\(index)\n---\n"
                .write(to: sidecar, atomically: true, encoding: .utf8)
            return MediaItem(id: UUID(), basePath: root, metadataFile: sidecar,
                mediaFiles: [root.appendingPathComponent("\(index).jpg")],
                metadata: MediaMetadata(source: URL(string: "https://example.com/\(index)")!, platform: "test",
                    archivedDate: start.addingTimeInterval(Double(-index * 60))),
                aspectRatio: ratios[index % ratios.count])
        }
        try await store.insertItemsBatch(items)

        let grid = Host(store: store)
        defer { grid.close() }
        try await grid.settle()
        let before = grid.drawn()
        XCTAssertGreaterThan(before.count, 10, "grid never drew")

        // Two first-screen items in different columns, deleted one at a time as reported.
        let order = grid.state.mediaSelectionStore.items.map(\.id)
        XCTAssertGreaterThan(order.count, 6, "grid published no display order")
        let doomed = [order[1], order[6]]
        for id in doomed {
            grid.state.selectedItemIDs = [id]
            grid.state.selectedItemID = id
            try await grid.settle(5)
            grid.state.deleteItems([id], deleteFromDisk: false)
            try await grid.settle()
        }
        let after = grid.drawn()
        var all = FilterState()
        all.limit = 400
        let live = try await store.fetchItems(filter: all)
        XCTAssertFalse(live.contains { doomed.contains($0.id) },
            "store still lists a deleted item")

        let fresh = Host(store: store)
        defer { fresh.close() }
        try await fresh.settle()
        let expected = fresh.drawn()
        XCTAssertNotEqual(after, before, "grid still draws the pre-delete layout")
        let stale = Set(after).subtracting(expected)
        let missing = Set(expected).subtracting(after)
        XCTAssertTrue(stale.isEmpty && missing.isEmpty,
            "after delete: \(after.count) drawn vs \(expected.count) fresh; stale \(stale.sorted().prefix(4)), missing \(missing.sorted().prefix(4))")
        XCTAssertFalse(grid.window.isVisible)
    }
}
