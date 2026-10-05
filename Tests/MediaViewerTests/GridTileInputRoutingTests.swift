import AppKit
import XCTest
@testable import MediaViewer

@MainActor
final class GridTileInputRoutingTests: XCTestCase {
    private let router = GridContextClickRouter.shared

    override func tearDown() {
        MasonryCell.setGlobalRightClickInterceptionEnabled(true)
        super.tearDown()
    }

    func testOneMonitorAndTransparentAnchorLifecycle() {
        let baseline = router.registeredViewCount
        let window = makeWindow()
        let anchors = (0..<24).map { _ in TestDragView(onRightClick: nil) }
        anchors.forEach { window.contentView!.addSubview($0) }
        XCTAssertEqual(router.registeredViewCount, baseline + 24)
        XCTAssertEqual(router.eventMonitorCount, 1)
        XCTAssertNil(anchors[0].hitTest(.zero))
        anchors.forEach { $0.removeFromSuperview() }
        XCTAssertEqual(router.registeredViewCount, baseline)
        if baseline == 0 { XCTAssertEqual(router.eventMonitorCount, 0) }
    }

    func testOnlyHitTileResolvesAndDragKeepsOrderedMouseDownSnapshotAtFivePoints() throws {
        let window = makeWindow()
        let first = attach(to: window, x: 0)
        let second = attach(to: window, x: 100)
        let items = [item("second.jpg"), item("first.jpg")]
        var ordered = items
        var firstResolutions = 0
        var secondResolutions = 0
        first.resolve = {
            firstResolutions += 1
            return try MediaTransferResolver.resolve(items: ordered, isReadable: { _ in true })
        }
        second.resolve = {
            secondResolutions += 1
            return try MediaTransferResolver.resolve(items: [], isReadable: { _ in true })
        }
        let down = event(.leftMouseDown, x: 20, in: window)
        XCTAssertTrue(router.route(down) === down)
        ordered = [items[1]] // Selection can change after the click reaches SwiftUI.
        let short = event(.leftMouseDragged, x: 24.99, in: window)
        XCTAssertTrue(router.route(short) === short)
        XCTAssertNil(router.route(event(.leftMouseDragged, x: 25, in: window)))
        XCTAssertEqual(firstResolutions, 1)
        XCTAssertEqual(secondResolutions, 0)
        XCTAssertEqual(first.begunPlans.map(\.itemIDs), [items.map(\.id)])
        XCTAssertEqual(first.begunPlans.first?.files.map(\.url), items.flatMap(\.mediaFiles))
        let consumed = event(.leftMouseDragged, x: 30, in: window)
        XCTAssertTrue(router.route(consumed) === consumed)
        first.removeFromSuperview()
        second.removeFromSuperview()
    }

    func testControlAndRightClickSelectBeforeMenuAndPreserveSelectedBatch() {
        let window = makeWindow()
        let view = attach(to: window, x: 0)
        let clicked = UUID(), other = UUID()
        var selected: Set<UUID> = [other]
        var calls: [String] = []
        view.onRightClick = { _ in
            let target = MasonryContextSelectionPolicy.targetIDs(clickedID: clicked, selectedIDs: selected)
            if target != selected { selected = target; calls.append("select") }
            calls.append("menu")
        }
        view.resolve = { XCTFail("Context click must not resolve a drag"); throw MediaTransferError.empty }
        XCTAssertNil(router.route(event(.rightMouseDown, x: 20, in: window)))
        XCTAssertEqual(calls, ["select", "menu"])
        XCTAssertEqual(selected, [clicked])
        calls = []
        selected = [clicked, other]
        XCTAssertNil(router.route(event(.leftMouseDown, x: 20, flags: [.control], in: window)))
        XCTAssertEqual(calls, ["menu"])
        XCTAssertEqual(selected, [clicked, other])
        view.removeFromSuperview()
    }

    func testGateAndDisabledSourceCancelPendingDrag() {
        let window = makeWindow()
        let view = attach(to: window, x: 0)
        var enabled = true
        view.isDragEnabled = { enabled }
        view.resolve = { try MediaTransferResolver.resolve(items: [self.item("one.jpg")], isReadable: { _ in true }) }
        view.onRightClick = { _ in XCTFail("The disabled context gate must pass through") }
        _ = router.route(event(.leftMouseDown, x: 20, in: window))
        enabled = false
        MasonryCell.setGlobalRightClickInterceptionEnabled(false)
        let drag = event(.leftMouseDragged, x: 30, in: window)
        XCTAssertTrue(router.route(drag) === drag)
        let context = event(.rightMouseDown, x: 20, in: window)
        XCTAssertTrue(router.route(context) === context)
        enabled = true
        XCTAssertTrue(router.route(drag) === drag)
        XCTAssertTrue(view.begunPlans.isEmpty)
        view.removeFromSuperview()
    }

    func testDragOnlyAnchorStillWorksWhenGridContextGateIsDisabled() {
        let window = makeWindow()
        let view = attach(to: window, x: 0)
        view.resolve = { try MediaTransferResolver.resolve(items: [self.item("one.jpg")], isReadable: { _ in true }) }
        MasonryCell.setGlobalRightClickInterceptionEnabled(false)
        _ = router.route(event(.leftMouseDown, x: 20, in: window))
        XCTAssertNil(router.route(event(.leftMouseDragged, x: 25, in: window)))
        XCTAssertEqual(view.begunPlans.count, 1)
        view.removeFromSuperview()
    }

    func testMouseUpDetachAndOtherWindowCancelCapture() {
        let window = makeWindow()
        let other = makeWindow()
        let view = attach(to: window, x: 0)
        view.resolve = { try MediaTransferResolver.resolve(items: [self.item("one.jpg")], isReadable: { _ in true }) }
        _ = router.route(event(.leftMouseDown, x: 20, in: window))
        _ = router.route(event(.leftMouseUp, x: 20, in: window))
        _ = router.route(event(.leftMouseDragged, x: 30, in: window))
        _ = router.route(event(.leftMouseDown, x: 20, in: window))
        _ = router.route(event(.leftMouseDragged, x: 30, in: other))
        _ = router.route(event(.leftMouseDragged, x: 30, in: window))
        _ = router.route(event(.leftMouseDown, x: 20, in: window))
        view.removeFromSuperview()
        window.contentView!.addSubview(view)
        _ = router.route(event(.leftMouseDragged, x: 30, in: window))
        XCTAssertTrue(view.begunPlans.isEmpty)
        view.removeFromSuperview()
    }

    func testResolutionFailuresStaySilentUntilThreshold() {
        let window = makeWindow()
        let view = attach(to: window, x: 0)
        var failures = 0
        view.resolve = { throw MediaTransferError.empty }
        view.onFailure = { _ in failures += 1 }
        _ = router.route(event(.leftMouseDown, x: 20, in: window))
        XCTAssertEqual(failures, 0)
        _ = router.route(event(.leftMouseDragged, x: 24, in: window))
        XCTAssertEqual(failures, 0)
        XCTAssertNil(router.route(event(.leftMouseDragged, x: 25, in: window)))
        XCTAssertEqual(failures, 1)
        view.removeFromSuperview()
    }

    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                 styleMask: [.borderless], backing: .buffered, defer: false)
    }

    private func attach(to window: NSWindow, x: CGFloat) -> TestDragView {
        let view = TestDragView(onRightClick: nil)
        view.frame = NSRect(x: x, y: 0, width: 100, height: 100)
        window.contentView!.addSubview(view)
        return view
    }

    private func event(_ type: NSEvent.EventType, x: CGFloat, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 20), modifierFlags: flags,
                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func item(_ file: String) -> MediaItem {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("routing-\(UUID())")
        return MediaItem(id: UUID(), basePath: base, metadataFile: base.appendingPathComponent("item.md"),
                         mediaFiles: [base.appendingPathComponent(file)],
                         metadata: MediaMetadata(source: URL(string: "https://example.com")!, platform: "test"))
    }
}

/// AppKit reports an empty visibleRect in never-ordered windows. Spell out the
/// visible region, as GridContextClickRoutingTests does, and intercept drag start
/// so no native drag session or mouse/audio device is used.
@MainActor
private final class TestDragView: MediaFileDragSource.DragView {
    var begunPlans: [MediaTransferPlan] = []
    override var visibleRect: NSRect { bounds }
    override func begin(_ plan: MediaTransferPlan, event: NSEvent, point: NSPoint) throws {
        begunPlans.append(plan)
    }
}
