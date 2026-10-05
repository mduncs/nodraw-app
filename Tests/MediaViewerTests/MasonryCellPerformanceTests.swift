import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import MediaViewer

/// Mount real tiles in a window that is never ordered on screen. Timing includes
/// hosting and the first layout on the main thread; settling is measured separately.
@MainActor
final class MasonryCellPerformanceTests: XCTestCase {
    override func tearDown() {
        MasonryCellDiagnostics.onBody = nil
        MasonryCellDiagnostics.onGeometry = nil
        MasonryCellDiagnostics.onHoverHandler = nil
        MasonryCellDiagnostics.onPresentation = nil
        MasonryCell.setGlobalRightClickInterceptionEnabled(true)
        super.tearDown()
    }

    func testMountCostAndStructure() async throws {
        let count = 24
        var samples: [Double] = []
        var evaluations: [Int] = []
        var viewCounts: [Int] = []
        var anchors: [Int] = []
        var monitors: [Int] = []
        var geometrySites = Set<String>()
        for sample in 0..<6 {
            var bodies: [UUID: Int] = [:]
            MasonryCellDiagnostics.onBody = { bodies[$0, default: 0] += 1 }
            MasonryCellDiagnostics.onGeometry = { geometrySites.insert($0) }
            let items = (0..<count).map { _ in item() }
            let start = CACurrentMediaTime()
            let host = NSHostingView(rootView: tileGrid(items))
            let window = window(host, width: 960, height: 1200)
            host.layoutSubtreeIfNeeded()
            let elapsed = (CACurrentMediaTime() - start) * 1000 / Double(count)
            try await settle(host)
            XCTAssertFalse(window.isVisible)
            let views = descendants(host)
            if sample > 0 { // Discard framework cold start, identically before and after.
                samples.append(elapsed)
                evaluations.append(contentsOf: items.map { bodies[$0.id, default: 0] })
                viewCounts.append(views.count)
                anchors.append(views.filter { $0 is RightClickView || $0 is MediaFileDragSource.DragView }.count)
                monitors.append(GridContextClickRouter.shared.eventMonitorCount + MediaFileDragSource.eventMonitorCount)
            }
            window.contentView = nil
            MasonryCellDiagnostics.onBody = nil
            try await Task.sleep(for: .milliseconds(10))
        }
        let sorted = samples.sorted()
        print("TILE_BENCH count=\(count) samples=\(samples.count) mount_ms_per_tile_median=\(sorted[sorted.count / 2]) range=\(sorted.first!)...\(sorted.last!) body_runs=\(Set(evaluations).sorted()) appkit_views_batch=\(viewCounts) anchors_batch=\(anchors) monitors_batch=\(monitors) geometry_sites=\(geometrySites.sorted())")
        XCTAssertEqual(Set(evaluations), [1], "Known tile size must not trigger an appearance state write")
        XCTAssertEqual(Set(anchors), [count], "Drag and context click should share one anchor per cell")
        XCTAssertEqual(Set(monitors), [1], "All mounted cells should share one event monitor")
        XCTAssertTrue(geometrySites.isEmpty, "Known-size tile content needs no GeometryReader")
    }

    func testCarouselReaderStructure() async throws {
        let item = item(files: ["one.jpg", "two.jpg", "three.jpg", "four.jpg"])
        var sites = Set<String>()
        var bodies = 0
        MasonryCellDiagnostics.onGeometry = { sites.insert($0) }
        MasonryCellDiagnostics.onBody = { _ in bodies += 1 }
        let host = NSHostingView(rootView: cell(item).frame(width: 240, height: 200).environment(SettingsStore.shared))
        let window = window(host, width: 240, height: 200)
        try await settle(host)
        print("TILE_CAROUSEL body_runs=\(bodies) owned_geometry_reader_sites=\(sites.count)")
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(bodies, 1)
        XCTAssertTrue(sites.isEmpty)
        window.contentView = nil
    }

    func testJustifiedProposalAndCarouselHoverCoordinates() async throws {
        var item = item(files: ["one.jpg", "two.jpg", "three.jpg", "four.jpg"])
        item.aspectRatio = 2
        var tile = cell(item)
        tile.tileSize = nil
        var bodies = 0
        var renderedSize = CGSize.zero
        var renderedSlot: Int?
        var handler: ((HoverPhase) -> Void)?
        MasonryCellDiagnostics.onBody = { _ in bodies += 1 }
        MasonryCellDiagnostics.onHoverHandler = { _, value in handler = value }
        MasonryCellDiagnostics.onPresentation = { _, size, slot, _ in
            renderedSize = size
            renderedSlot = slot
        }
        let host = NSHostingView(rootView: JustifiedRowLayout(spacing: 0, rowHeight: 100) {
            tile.equatable().masonryLayoutMetadata(id: item.id, aspectRatio: 2)
        }.environment(SettingsStore.shared))
        let window = window(host, width: 400, height: 200)
        try await settle(host)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(renderedSize.width, 400, accuracy: 0.01)
        XCTAssertEqual(renderedSize.height, 200, accuracy: 0.01)
        XCTAssertEqual(bodies, 1, "A layout proposal must not be copied into size state")
        try XCTUnwrap(handler)(.active(CGPoint(x: 300, y: 150)))
        try await settle(host)
        XCTAssertEqual(renderedSlot, 3)
        try XCTUnwrap(handler)(.ended)
        try await settle(host)
        XCTAssertNil(renderedSlot)
        window.contentView = nil
    }

    func testEqualityIncludesEveryRenderedItemInput() {
        let original = item(files: ["one.jpg", "two.jpg"])
        func differs(_ changed: MediaItem) { XCTAssertNotEqual(cell(original), cell(changed)) }
        var changed = original
        changed.aspectRatio = 1.7
        differs(changed)
        changed = original
        changed.mediaFiles[1] = changed.basePath.appendingPathComponent("replacement.png")
        differs(changed)
        changed = original
        changed.indexedContent = IndexedContent(dominantColors: [.blue])
        differs(changed)
        changed = original
        changed.contextImage = changed.basePath.appendingPathComponent("context.png")
        differs(changed)
        changed = original
        changed.metadata = MediaMetadata(source: original.metadata.source, platform: "twitter", author: "another")
        differs(changed)
        var sized = cell(original)
        sized.tileSize = CGSize(width: 300, height: 200)
        XCTAssertNotEqual(cell(original), sized)
        XCTAssertEqual(cell(original), cell(original, selectedIDs: [UUID()]), "Other tiles' selection is event-only state")
    }

    func testHoverOnlyRendersTheTargetAndMountsItsPlayer() async throws {
        for ext in ["mp4", "webm"] {
            let items = [item(files: ["one.\(ext)"]), item(files: ["two.\(ext)"]), item()]
            var bodies: [UUID: Int] = [:]
            var handlers: [UUID: (HoverPhase) -> Void] = [:]
            MasonryCellDiagnostics.onBody = { bodies[$0, default: 0] += 1 }
            MasonryCellDiagnostics.onHoverHandler = { handlers[$0] = $1 }
            let host = NSHostingView(rootView: HStack(spacing: 0) {
                ForEach(items) { item in
                    self.cell(item).equatable().frame(width: 240, height: 200)
                }
            }.environment(SettingsStore.shared))
            let window = window(host, width: 720, height: 200)
            try await settle(host)
            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(playerViews(host).count, 0)
            let before = bodies
            print("TILE_HOVER backend=\(ext) body_runs=\(bodies.values.sorted()) handler_count=\(handlers.count)")
            try XCTUnwrap(handlers[items[0].id])(.active(CGPoint(x: 120, y: 50)))
            try await settle(host)
            XCTAssertGreaterThan(bodies[items[0].id, default: 0], before[items[0].id, default: 0])
            XCTAssertEqual(bodies[items[1].id], before[items[1].id])
            XCTAssertEqual(bodies[items[2].id], before[items[2].id])
            XCTAssertEqual(playerViews(host).count, 1, "Only the hovered tile mounts a \(ext) player")
            try XCTUnwrap(handlers[items[0].id])(.ended)
            try await settle(host)
            XCTAssertEqual(playerViews(host).count, 0, "Leaving hover dismantles the player")
            window.contentView = nil
            MasonryCellDiagnostics.onHoverHandler = nil
        }
    }

    private func item(files: [String] = []) -> MediaItem {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tile-fixture-\(UUID())")
        return MediaItem(id: UUID(), basePath: base, metadataFile: base.appendingPathComponent("item.md"),
                         mediaFiles: files.map { base.appendingPathComponent($0) },
                         metadata: MediaMetadata(source: URL(string: "https://example.com")!, platform: "test"),
                         indexedContent: IndexedContent(dominantColors: [.red, .green]), aspectRatio: 1.2)
    }

    private func cell(_ item: MediaItem, selectedIDs: Set<UUID> = []) -> MasonryCell {
        MasonryCell(item: item, tileSize: CGSize(width: 240, height: 200), isSelected: false,
                    isMultiSelectMode: false, showColorBar: true, selectedIDs: selectedIDs,
                    onSelect: {}, onToggleSelect: {}, onExtendSelect: {}, onDoubleClick: {}, onShowContextMenu: nil)
    }

    private func tileGrid(_ items: [MediaItem]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(240), spacing: 0), count: 4), spacing: 0) {
            ForEach(items) { item in
                self.cell(item).equatable().frame(width: 240, height: 200)
            }
        }
        .environment(SettingsStore.shared)
    }

    private func window<V: View>(_ host: NSHostingView<V>, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return window
    }

    private func settle<V: View>(_ host: NSHostingView<V>) async throws {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func playerViews(_ view: NSView) -> [NSView] {
        descendants(view).filter { $0 is VideoHoverPreview.VideoHoverNSView || $0 is WKWebView }
    }
}
