import AppKit
import Combine
import QuartzCore
import SwiftUI
import XCTest
@testable import MediaViewer

@MainActor
final class GridScrollingPerformanceTests: XCTestCase {
    private func items(_ count: Int) -> [MediaItem] {
        let root = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("grid-scroll-fixture-\(UUID())")
        let ratios: [CGFloat] = [0.4, 0.6, 1, 1.4, 1.8, 2.5]
        return (0..<count).map { index in
            MediaItem(id: UUID(), basePath: root,
                metadataFile: root.appendingPathComponent("\(index).md"),
                mediaFiles: [root.appendingPathComponent("\(index).jpg")],
                metadata: MediaMetadata(source: URL(string: "https://example.com/\(index)")!, platform: "test"),
                aspectRatio: ratios[index % ratios.count])
        }
    }

    func testDeepPrefetchContainsEveryVisibleTileWithoutScanningLibrary() {
        let vm = MasonryGridViewModel()
        vm.setColumnCount(8)
        vm.setContainerWidth(1_424)
        vm.setItems(items(7_600))
        let width = (vm.containerWidth - vm.spacing * 7) / 8
        for offset: CGFloat in [0, 10_000, 70_000, 140_000] {
            var visible = Set<UUID>()
            // Independent full scan is the oracle; production must only probe nearby tiles.
            for column in vm.columns {
                var y: CGFloat = vm.spacing
                for item in column {
                    let height = width / item.aspectRatio!
                    if y + height >= offset && y <= offset + 900 { visible.insert(item.id) }
                    y += height + vm.spacing
                }
            }
            for down in [true, false] {
                let prefetched = vm.thumbnailPrefetchItems(scrollOffset: -offset,
                    viewportHeight: 900, scrollingDown: down)
                XCTAssertTrue(visible.isSubset(of: Set(prefetched.map(\.id))))
                XCTAssertLessThanOrEqual(prefetched.count, 240)
                XCTAssertLessThan(vm.lastPrefetchProbeCount, 320)
                XCTAssertEqual(prefetched.count, Set(prefetched.map(\.id)).count)
            }
        }
        XCTAssertTrue(vm.thumbnailPrefetchItems(scrollOffset: .nan,
            viewportHeight: 900, scrollingDown: true).isEmpty)
    }

    func testPositionUpdatesDoNotPublishGridChanges() {
        let vm = MasonryGridViewModel()
        vm.setItems(items(100))
        var changes = 0
        let subscription = vm.objectWillChange.sink { changes += 1 }
        for offset in 0..<1_000 {
            vm.updateScrollPosition(offset: -CGFloat(offset), viewportHeight: 900)
        }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(vm.currentScrollOffset, -999)
        withExtendedLifetime(subscription) {}
    }

    func testColumnWindowsAndRevealGeometryMatchFullLayout() throws {
        let vm = MasonryGridViewModel()
        vm.setColumnCount(8)
        vm.setContainerWidth(1_424)
        vm.setItems(items(7_600))
        let width = (vm.containerWidth - vm.spacing * 7) / 8
        for offset: CGFloat in [0, 10_000, 70_000, 140_000] {
            var mounted = 0
            for column in vm.columns.indices {
                let range = vm.columnViewportRange(column: column, offset: -offset, height: 900)
                mounted += range.count
                var y: CGFloat = 0
                for (row, item) in vm.columns[column].enumerated() {
                    let height = width / item.aspectRatio!
                    if y + vm.spacing + height >= offset && y + vm.spacing <= offset + 900 {
                        XCTAssertTrue(range.contains(row))
                    }
                    XCTAssertEqual(vm.revealOffset(for: item.id, centered: false, viewportHeight: 900)!,
                        y + vm.spacing, accuracy: 0.001)
                    XCTAssertEqual(vm.revealOffset(for: item.id, centered: true, viewportHeight: 900)!,
                        y + vm.spacing + height / 2 - 450, accuracy: 0.001)
                    y += height + vm.spacing
                }
            }
            XCTAssertLessThan(mounted, 120)
        }
        let viewport = MasonryColumnViewport()
        var publishes = 0
        let subscription = viewport.objectWillChange.sink { publishes += 1 }
        viewport.update(range: 10..<20, offset: -1_000, height: 900)
        viewport.update(range: 10..<20, offset: -1_010, height: 900)
        XCTAssertEqual(publishes, 1)
        withExtendedLifetime(subscription) {}
    }

    func testRevealUsesExistingEaseInOutCurve() {
        XCTAssertEqual(LibrarySmoothScroller.revealProgress(0), 0)
        XCTAssertEqual(LibrarySmoothScroller.revealProgress(1), 1)
        XCTAssertEqual(LibrarySmoothScroller.revealProgress(0.5), 0.5, accuracy: 0.00001)
        XCTAssertEqual(LibrarySmoothScroller.revealProgress(0.25), 0.12916, accuracy: 0.0001)
        XCTAssertEqual(LibrarySmoothScroller.revealProgress(0.75), 0.87084, accuracy: 0.0001)
    }

    func testContinuousUpdatesDeliverDuringScrollingAndKeepLatestViewport() async throws {
        let runtime = MasonryGridScrollRuntime(prefetchInterval: 0.04)
        defer { runtime.cancelPendingWork() }
        var deliveries: [Int] = []
        let started = ProcessInfo.processInfo.systemUptime
        for position in 0..<30 {
            runtime.schedulePrefetch { deliveries.append(position) }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(deliveries.count, 3)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThanOrEqual(deliveries.count, Int(ceil(elapsed / 0.04)) + 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(deliveries.last, 29)
        runtime.schedulePrefetch { XCTFail("Cancelled viewport was delivered") }
        runtime.cancelPendingWork()
        try await Task.sleep(for: .milliseconds(60))
    }

    func testPrefetchIdentityMatchesTileSizeScaleAndSource() throws {
        var item = try XCTUnwrap(items(1).first)
        let size = CGSize(width: 180, height: 300)
        func target(_ item: MediaItem, _ scale: CGFloat) -> MasonryGridThumbnailPrefetchTarget {
            MasonryGridThumbnailPrefetchTarget(item: item, displaySize: size, displayScale: scale)
        }
        XCTAssertEqual(target(item, 2).identity,
            ImageCache.thumbnailLoadIdentity(for: item, displaySize: size, displayScale: 2))
        XCTAssertNotEqual(target(item, 1).identity, target(item, 2).identity)
        let previous = target(item, 2).identity
        item.mediaFiles = [item.basePath.appendingPathComponent("replacement.jpg")]
        XCTAssertNotEqual(target(item, 2).identity, previous)
        item.mediaFiles += [item.basePath.appendingPathComponent("carousel.jpg")]
        XCTAssertTrue(target(item, 2).identity.contains("carousel.jpg"))
    }

    func testNativeTrackingContinuesWithInputDisabledAndStopsOnDetach() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentView!.bounds)
        let scroll = NSScrollView(frame: root.bounds)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 3_000))
        scroll.documentView = document
        let bridge = LibraryViewportCommandView(frame: root.bounds)
        bridge.isEnabled = false
        var offsets: [CGFloat] = []
        var contentBottom: CGFloat = 0
        bridge.onViewportChanged = { offset, _, bottom in
            offsets.append(offset)
            contentBottom = bottom
        }
        root.addSubview(scroll)
        root.addSubview(bridge)
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        bridge.refreshViewportObservation()
        try await Task.sleep(for: .milliseconds(20))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_000))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(offsets.last, -1_000)
        document.setFrameSize(NSSize(width: 600, height: 4_000))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(contentBottom, 4_000)
        XCTAssertLessThanOrEqual(bridge.fullHierarchySearchCount, 1)
        let replacement = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 4_500))
        scroll.documentView = replacement
        bridge.refreshViewportObservation()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(contentBottom, 4_500)
        let reboundCount = offsets.count
        document.setFrameSize(NSSize(width: 600, height: 5_000))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(offsets.count, reboundCount)
        bridge.removeFromSuperview()
        let count = offsets.count
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_200))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(offsets.count, count)
        XCTAssertFalse(window.isVisible)
    }

    #if DEBUG
    func testLargeEndKeepsBoundedTilesAndOffscreenRevealsWork() async throws {
        let vm = MasonryGridViewModel()
        vm.density = 0
        let loaded = items(7_600)
        vm.setItems(loaded)
        var request = LibraryScrollRequest()
        func grid() -> AnyView {
            AnyView(MasonryGrid(viewModel: vm, useHybridLayout: false, showColorBars: false,
                isBackgrounded: false, onItemSelected: { _ in }, onItemDoubleClicked: { _ in },
                onShowContextMenu: nil, onLoadMore: nil, libraryScrollRequest: request)
                .environment(SettingsStore.shared))
        }
        let host = NSHostingView(rootView: grid())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_440, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        func process() {
            _ = RunLoop.main.run(mode: .default, before: Date())
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
        }
        var animationDriver: LibrarySmoothScroller?
        func settle(advanceAnimation: Bool = false) async throws {
            for _ in 0..<30 {
                process()
                if advanceAnimation, let animationDriver, animationDriver.isAnimating {
                    animationDriver.advance(at: ProcessInfo.processInfo.systemUptime + 0.25)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await settle()
        let bridge = try XCTUnwrap(descendants(host).compactMap { $0 as? MiddleMouseAutoScrollView }.first)
        let scroll = try XCTUnwrap(bridge.resolveLibraryScrollView())
        let scroller = bridge.smoothScroller
        animationDriver = scroller
        scroller.reduceMotion = { false }
        let start = ProcessInfo.processInfo.systemUptime
        scroller.benchmarkTime = start
        XCTAssertTrue(scroller.scroll(.last, in: scroll))
        scroller.pauseFrameTickerForBenchmark()
        for frame in 1...60 {
            scroller.advance(at: start + Double(frame) / 144)
            process()
            let anchors = descendants(host).compactMap { $0 as? RightClickView }
            XCTAssertFalse(anchors.allSatisfy { $0.visibleRect.isEmpty }, "Blank End frame \(frame)")
            XCTAssertLessThan(anchors.count, 160)
            try await Task.sleep(for: .milliseconds(1))
        }
        scroller.benchmarkTime = nil
        let bottom = (vm.columnHeights.max() ?? 0) + 2 * vm.spacing + 1 - 900
        XCTAssertEqual(scroll.contentView.bounds.minY, bottom, accuracy: 1)
        let target = loaded[3_000].id
        vm.select(target, scrollToSelection: true)
        try await settle(advanceAnimation: true)
        let centered = try XCTUnwrap(vm.revealOffset(for: target, centered: true, viewportHeight: 900))
        XCTAssertEqual(scroll.contentView.bounds.minY, centered, accuracy: 1)
        let motionStarted = ProcessInfo.processInfo.systemUptime
        scroller.benchmarkTime = motionStarted
        XCTAssertTrue(scroller.scroll(by: 300, in: scroll))
        scroller.pauseFrameTickerForBenchmark()
        scroller.advance(at: motionStarted + 0.04)
        let pendingDistance = scroller.destination(in: scroll) - scroll.contentView.bounds.minY
        vm.scrollAnchorToRestore = loaded[1_000].id
        try await settle()
        XCTAssertTrue(scroller.isAnimating, "Live anchor restoration must preserve queued motion")
        let top = try XCTUnwrap(vm.revealOffset(for: loaded[1_000].id, centered: false, viewportHeight: 900))
        XCTAssertEqual(scroll.contentView.bounds.minY, top, accuracy: 1)
        scroller.advance(at: motionStarted + 0.3)
        XCTAssertEqual(scroll.contentView.bounds.minY, top + pendingDistance, accuracy: 1)
        scroller.benchmarkTime = nil
        vm.shouldScrollToSelectionOnFocusReturn = true
        try await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, centered, accuracy: 1)
        request.issue(.item(loaded[6_000].id))
        host.rootView = grid()
        try await settle()
        let requested = try XCTUnwrap(vm.revealOffset(for: loaded[6_000].id, centered: true, viewportHeight: 900))
        XCTAssertEqual(scroll.contentView.bounds.minY, requested, accuracy: 1)
        let appended = items(500)
        let awaited = appended.last!.id
        request.issue(.item(awaited))
        host.rootView = grid()
        try await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, requested, accuracy: 1)
        vm.appendItems(appended)
        try await settle()
        var expected = scroll.contentView.bounds
        expected.origin.y = try XCTUnwrap(vm.revealOffset(for: awaited, centered: true, viewportHeight: 900))
        XCTAssertEqual(scroll.contentView.bounds.minY,
            scroll.contentView.constrainBoundsRect(expected).minY, accuracy: 1)
        let superseded = items(1).first!
        request.issue(.item(superseded.id))
        host.rootView = grid()
        try await settle()
        let mouse = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        XCTAssertTrue(bridge.handleMonitoredEvent(mouse) === mouse)
        let beforeAppend = scroll.contentView.bounds.minY
        vm.appendItems([superseded])
        try await settle()
        XCTAssertEqual(scroll.contentView.bounds.minY, beforeAppend, accuracy: 1)
        vm.shouldScrollToTop = true
        try await settle(advanceAnimation: true)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        XCTAssertFalse(window.isVisible)
    }

    #endif

    func testEagerGridWrapperDoesNotLoadOffscreenPages() async throws {
        let vm = MasonryGridViewModel()
        vm.density = 0
        vm.setItems(items(500))
        var loads = 0
        let grid = MasonryGrid(viewModel: vm, useHybridLayout: false, showColorBars: false,
            isBackgrounded: false, onItemSelected: { _ in }, onItemDoubleClicked: { _ in },
            onShowContextMenu: nil, onLoadMore: {
                loads += 1
                try? await Task.sleep(for: .milliseconds(50))
                if loads == 2 { vm.appendItems([]) }
            })
        let host = NSHostingView(rootView: grid.environment(SettingsStore.shared))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_440, height: 1_600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(loads, 0)
        var pending = host.subviews
        var scroll: NSScrollView?
        while let view = pending.popLast() {
            if let found = view as? NSScrollView { scroll = found; break }
            pending.append(contentsOf: view.subviews)
        }
        let found = try XCTUnwrap(scroll)
        XCTAssertGreaterThan(found.documentView!.bounds.height, 1_600)
        LibraryViewportScroller.apply(.last, to: found)
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(vm.hasMoreItems)
        // A failed/no-op load must not loop. Leaving and revisiting the boundary retries it.
        LibraryViewportScroller.apply(.first, to: found)
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        LibraryViewportScroller.apply(.last, to: found)
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(loads, 2)
        XCTAssertFalse(vm.hasMoreItems)
        XCTAssertFalse(window.isVisible)
    }
}
