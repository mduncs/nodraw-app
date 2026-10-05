import AppKit
import SwiftUI
import XCTest
@testable import MediaViewer

/// Bug report, 2026-10-04: after Delete the two tiles stayed on screen and arrow keys moved
/// through a layout that no longer matched what was drawn. The grid after a delete must draw
/// exactly what a fresh grid of the remaining items draws at the same scroll position.
@MainActor
final class GridDeleteRefreshTests: XCTestCase {
    private func items(_ count: Int) -> [MediaItem] {
        let root = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("grid-delete-fixture-\(UUID())")
        let ratios: [CGFloat] = [0.4, 0.6, 1, 1.4, 1.8, 2.5]
        return (0..<count).map { index in
            MediaItem(id: UUID(), basePath: root,
                metadataFile: root.appendingPathComponent("\(index).md"),
                mediaFiles: [root.appendingPathComponent("\(index).jpg")],
                metadata: MediaMetadata(source: URL(string: "https://example.com/\(index)")!, platform: "test"),
                aspectRatio: ratios[index % ratios.count])
        }
    }

    private final class Harness {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        init(_ vm: MasonryGridViewModel) {
            host = NSHostingView(rootView: AnyView(MasonryGrid(viewModel: vm, useHybridLayout: false,
                showColorBars: false, isBackgrounded: false, onItemSelected: { _ in },
                onItemDoubleClicked: { _ in }, onShowContextMenu: nil, onLoadMore: nil,
                libraryScrollRequest: LibraryScrollRequest()).environment(SettingsStore.shared)))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_440, height: 900),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
        }
        func close() { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        var scroll: NSScrollView? {
            descendants(host).compactMap { $0 as? MiddleMouseAutoScrollView }.first?.resolveLibraryScrollView()
        }
        @MainActor func settle() async throws {
            for _ in 0..<40 {
                _ = RunLoop.main.run(mode: .default, before: Date())
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                CATransaction.flush()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func scroll(to y: CGFloat) {
            guard let scroll else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        /// Tile anchors in document coordinates, rounded to whole points.
        func drawn() -> [String] {
            guard let document = scroll?.documentView else { return [] }
            return descendants(host).compactMap { $0 as? RightClickView }
                .map { $0.convert($0.bounds, to: document) }
                .filter { $0.width > 1 && $0.height > 1 }
                .map { "\(Int($0.minX.rounded())),\(Int($0.minY.rounded())) \(Int($0.width.rounded()))x\(Int($0.height.rounded()))" }
                .sorted()
        }
    }

    private func run(scrolledTo offset: CGFloat, animated: Bool) async throws {
        let vm = MasonryGridViewModel()
        vm.density = 0
        vm.setItems(items(400))
        let grid = Harness(vm)
        defer { grid.close() }
        try await grid.settle()
        grid.scroll(to: offset)
        try await grid.settle()
        let before = grid.drawn()
        XCTAssertFalse(before.isEmpty, "no tile anchors found")

        // Two tiles on screen, in different columns, like the reported two deletes.
        let top = grid.scroll?.contentView.bounds.minY ?? 0
        let doomed = Set((0..<2).compactMap { column -> UUID? in
            let range = vm.columnViewportRange(column: column, offset: -top, height: 900)
            return range.isEmpty ? nil : vm.columns[column][range.lowerBound + range.count / 2].id
        })
        XCTAssertEqual(doomed.count, 2)
        vm.select(doomed.first)
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { _ = vm.removeItems(doomed, selectingSurvivor: true) }
        } else {
            _ = vm.removeItems(doomed, selectingSurvivor: true)
        }
        try await grid.settle()
        let afterOffset = grid.scroll?.contentView.bounds.minY ?? 0
        let after = grid.drawn()

        let freshModel = MasonryGridViewModel()
        freshModel.density = 0
        freshModel.setItems(vm.items)
        let fresh = Harness(freshModel)
        defer { fresh.close() }
        try await fresh.settle()
        fresh.scroll(to: afterOffset)
        try await fresh.settle()
        XCTAssertEqual(fresh.scroll?.contentView.bounds.minY ?? -1, afterOffset, accuracy: 1)
        let expected = fresh.drawn()

        XCTAssertFalse(after.isEmpty, "grid blank after delete")
        let stale = Set(after).subtracting(expected)
        let missing = Set(expected).subtracting(after)
        XCTAssertTrue(stale.isEmpty && missing.isEmpty,
            "after delete: \(after.count) tiles drawn vs \(expected.count) fresh; stale \(stale.sorted().prefix(4)), missing \(missing.sorted().prefix(4))")
        XCTAssertFalse(grid.window.isVisible)
    }

    func testDeleteAtTopRedrawsLikeAFreshGrid() async throws {
        try await run(scrolledTo: 0, animated: false)
    }

    func testAnimatedDeleteAtTopRedrawsLikeAFreshGrid() async throws {
        try await run(scrolledTo: 0, animated: true)
    }

    func testAnimatedDeleteWhileScrolledRedrawsLikeAFreshGrid() async throws {
        try await run(scrolledTo: 3_000, animated: true)
    }
}
