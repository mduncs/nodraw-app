import AppKit
import XCTest
@testable import MediaViewer

@MainActor
final class LibraryScrollingBridgeTests: XCTestCase {
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    private func fixture() -> (NSWindow, NSScrollView, MiddleMouseAutoScrollView) {
        // Never ordered front or made key: exercises the mounted AppKit sibling hierarchy only.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: window.contentView!.bounds)
        let scroll = NSScrollView(frame: root.bounds)
        scroll.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 600, height: 3000))
        let bridge = MiddleMouseAutoScrollView(frame: root.bounds)
        root.addSubview(scroll)
        root.addSubview(bridge)
        window.contentView = root
        return (window, scroll, bridge)
    }

    private func middle(_ type: CGEventType, in window: NSWindow, at point: CGPoint = CGPoint(x: 100, y: 100)) throws -> NSEvent {
        let eventType: NSEvent.EventType
        switch type {
        case .otherMouseDown: eventType = .otherMouseDown
        case .otherMouseDragged: eventType = .otherMouseDragged
        case .otherMouseUp: eventType = .otherMouseUp
        default: throw NSError(domain: "LibraryScrollingBridgeTests", code: 1)
        }
        // NSEvent.mouseEvent defaults to button zero even for .otherMouseDown. Preserve its
        // local window/coordinates, then set the actual middle button on the CGEvent payload.
        let local = try XCTUnwrap(NSEvent.mouseEvent(with: eventType, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 0))
        let cg = try XCTUnwrap(local.cgEvent)
        cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertTrue(event.window === window)
        XCTAssertEqual(event.locationInWindow.x, point.x, accuracy: 0.01)
        XCTAssertEqual(event.locationInWindow.y, point.y, accuracy: 0.01)
        XCTAssertEqual(event.buttonNumber, 2)
        return event // Direct handler call only; never post into any event queue.
    }

    func testMountedSiblingBridgeConsumesMiddleClickAndCancelsWithoutSelectionInterception() throws {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview() }
        XCTAssertNil(MiddleMouseScrollTargetPolicy.nearestEnclosingScrollView(from: bridge))
        XCTAssertTrue(bridge.resolveLibraryScrollView() === scroll)
        let down = try middle(.otherMouseDown, in: window)
        XCTAssertEqual(down.buttonNumber, 2)
        XCTAssertNil(bridge.handleMonitoredEvent(down))
        XCTAssertNil(bridge.handleMonitoredEvent(try middle(.otherMouseUp, in: window)))
        XCTAssertNotNil(bridge.stateMachine.autoScrollAnchor)
        let left = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0))
        XCTAssertTrue(bridge.handleMonitoredEvent(left) === left)
        XCTAssertTrue(bridge.stateMachine.isIdle)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
    }

    func testAutoscrollStopsOnFocusLossAndDetach() throws {
        let (window, _, bridge) = fixture()
        XCTAssertNil(bridge.handleMonitoredEvent(try middle(.otherMouseDown, in: window)))
        XCTAssertNil(bridge.handleMonitoredEvent(try middle(.otherMouseUp, in: window)))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertTrue(bridge.stateMachine.isIdle)
        XCTAssertNil(bridge.handleMonitoredEvent(try middle(.otherMouseDown, in: window)))
        bridge.removeFromSuperview()
        XCTAssertTrue(bridge.stateMachine.isIdle)
    }

    func testMiddleDragDoesNotLatchAndSecondClickStopsAutoscroll() throws {
        let (window, _, bridge) = fixture()
        defer { bridge.removeFromSuperview() }
        XCTAssertNil(bridge.handleMonitoredEvent(try middle(.otherMouseDown, in: window)))
        XCTAssertNil(bridge.handleMonitoredEvent(try middle(.otherMouseDragged, in: window, at: CGPoint(x: 100, y: 130))))
        XCTAssertNil(bridge.handleMonitoredEvent(try middle(.otherMouseUp, in: window, at: CGPoint(x: 100, y: 130))))
        XCTAssertTrue(bridge.stateMachine.isIdle)
        XCTAssertNil(bridge.handleMonitoredEvent(try middle(.otherMouseDown, in: window)))
        XCTAssertNil(bridge.handleMonitoredEvent(try middle(.otherMouseUp, in: window)))
        XCTAssertNotNil(bridge.stateMachine.autoScrollAnchor)
        XCTAssertNil(bridge.handleMonitoredEvent(try middle(.otherMouseDown, in: window)))
        XCTAssertNil(bridge.handleMonitoredEvent(try middle(.otherMouseUp, in: window)))
        XCTAssertTrue(bridge.stateMachine.isIdle)
    }

    func testPreciseMomentumHorizontalAndModifiedWheelAreNotSmoothed() throws {
        func wheel(precise: Bool = false, horizontal: Int32 = 0, flags: CGEventFlags = [],
                   phase: Int64 = 0, momentum: Int64 = 0) throws -> NSEvent {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                                          wheelCount: 2, wheel1: -3, wheel2: horizontal, wheel3: 0))
            cg.flags = flags
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return try XCTUnwrap(NSEvent(cgEvent: cg))
        }
        XCTAssertTrue(LibrarySmoothScroller.shouldSmooth(try wheel()))
        XCTAssertFalse(LibrarySmoothScroller.shouldSmooth(try wheel(precise: true)))
        XCTAssertFalse(LibrarySmoothScroller.shouldSmooth(try wheel(horizontal: 2)))
        XCTAssertFalse(LibrarySmoothScroller.shouldSmooth(try wheel(flags: .maskShift)))
        XCTAssertFalse(LibrarySmoothScroller.shouldSmooth(try wheel(flags: .maskControl)))
        XCTAssertFalse(LibrarySmoothScroller.shouldSmooth(try wheel(phase: 1)))
        XCTAssertFalse(LibrarySmoothScroller.shouldSmooth(try wheel(momentum: 1)))
    }

    func testDisabledMountedLibraryPassesInputAndCancelsMotionUntilReenabled() throws {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview() }
        let down = try middle(.otherMouseDown, in: window)
        let up = try middle(.otherMouseUp, in: window)
        XCTAssertNil(bridge.handleMonitoredEvent(down))
        XCTAssertNil(bridge.handleMonitoredEvent(up))
        XCTAssertNotNil(bridge.stateMachine.autoScrollAnchor)
        bridge.isEnabled = false
        XCTAssertTrue(bridge.stateMachine.isIdle)
        XCTAssertFalse(bridge.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(bridge.window === window)
        XCTAssertTrue(bridge.handleMonitoredEvent(down) === down)
        XCTAssertTrue(bridge.handleMonitoredEvent(up) === up)

        let cg = try XCTUnwrap(down.cgEvent?.copy())
        cg.type = .scrollWheel
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -3)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        let wheel = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertTrue(wheel.window === window)
        XCTAssertTrue(bridge.handleMonitoredEvent(wheel) === wheel)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)

        bridge.isEnabled = true
        bridge.smoothScroller.reduceMotion = { false }
        XCTAssertTrue(bridge.smoothScroller.scroll(by: 100, in: scroll))
        bridge.isEnabled = false
        XCTAssertFalse(bridge.smoothScroller.isAnimating)
        bridge.smoothScroller.advance(at: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
        bridge.isEnabled = true
        XCTAssertNil(bridge.handleMonitoredEvent(down))
        XCTAssertNil(bridge.handleMonitoredEvent(up))
        XCTAssertNotNil(bridge.stateMachine.autoScrollAnchor)
    }

    func testRealClipViewSmoothingAccumulatesClampsAndYieldsToUserScroll() throws {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        XCTAssertTrue(scroller.scroll(by: 100, in: scroll))
        XCTAssertEqual(scroll.contentView.bounds.minY, 0)
        XCTAssertTrue(scroller.scroll(by: 100, in: scroll))
        scroller.advance(at: ProcessInfo.processInfo.systemUptime + 0.08)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertLessThan(scroll.contentView.bounds.minY, 200)
        scroller.advance(at: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, 200, accuracy: 0.01)
        XCTAssertTrue(scroller.scroll(by: 100, in: scroll))
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0))
        XCTAssertTrue(bridge.handleMonitoredEvent(click) === click)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 350))
        scroller.advance(at: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, 350, accuracy: 0.01)
        XCTAssertFalse(scroller.isAnimating)
        scroller.reduceMotion = { true }
        XCTAssertTrue(scroller.scroll(to: 10000, in: scroll))
        XCTAssertFalse(scroller.isAnimating)
        XCTAssertEqual(scroll.contentView.bounds.maxY, 3000, accuracy: 0.01)
    }

    func testReverseWheelImmediatelyChangesDirectionFromCurrentClipPosition() {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        XCTAssertTrue(scroller.scroll(by: 200, in: scroll))
        scroller.advance(at: ProcessInfo.processInfo.systemUptime + 0.04)
        let reversalOffset = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(reversalOffset, 30)
        XCTAssertLessThan(reversalOffset, 170)
        XCTAssertTrue(scroller.scroll(by: -30, in: scroll))
        scroller.advance(at: ProcessInfo.processInfo.systemUptime + 0.04)
        XCTAssertLessThan(scroll.contentView.bounds.minY, reversalOffset)
        scroller.advance(at: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, max(0, reversalOffset - 30), accuracy: 0.01)
    }

    func testPageDownFinishesWhileDocumentGrowsBetweenFrames() {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        let target = LibraryViewportScrollGeometry.targetOffset(
            for: .pageDown, currentOffset: 0, viewportHeight: scroll.contentView.bounds.height,
            contentMinY: 0, contentMaxY: 3000)
        XCTAssertTrue(scroller.scroll(.pageDown, in: scroll))
        let now = ProcessInfo.processInfo.systemUptime
        scroller.advance(at: now + 1.0 / 144)
        scroll.documentView!.frame.size.height += 400
        scroller.advance(at: now + 0.08)
        XCTAssertTrue(scroller.isAnimating)
        scroller.advance(at: now + 0.2)
        XCTAssertEqual(scroll.contentView.bounds.minY, target, accuracy: 0.01)
    }

    func testPageDownRetainsFullDistanceWhenTheOldBottomGrows() {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 2500))
        XCTAssertTrue(scroller.scroll(.pageDown, in: scroll))
        let now = ProcessInfo.processInfo.systemUptime
        scroller.advance(at: now + 0.04)
        scroll.documentView!.frame.size.height += 400
        scroller.advance(at: now + 0.2)
        XCTAssertEqual(scroll.contentView.bounds.minY, 2860, accuracy: 0.01)
    }

    func testEndFollowsDocumentGrowthAfterReachingTheInitialBottom() {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        XCTAssertTrue(scroller.scroll(.last, in: scroll))
        let now = ProcessInfo.processInfo.systemUptime
        scroller.advance(at: now + 1.0 / 144)
        scroll.documentView!.frame.size.height += 400
        scroller.advance(at: now + 0.17)
        scroll.documentView!.frame.size.height += 300
        scroller.advance(at: now + 0.34)
        scroller.advance(at: now + 1)
        XCTAssertEqual(scroll.contentView.bounds.maxY, 3700, accuracy: 0.01)
        XCTAssertFalse(scroller.isAnimating)
    }

    func testWheelTravelAccumulatesAcrossDocumentGrowth() {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        XCTAssertTrue(scroller.scroll(by: 100, in: scroll))
        let now = ProcessInfo.processInfo.systemUptime
        scroller.advance(at: now + 1.0 / 144)
        scroll.documentView!.frame.size.height += 400
        scroller.advance(at: now + 0.04)
        XCTAssertTrue(scroller.scroll(by: 100, in: scroll))
        scroller.advance(at: now + 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, 200, accuracy: 0.01)
    }

    func testWheelDistanceMatchesNativeAppKitForLineEvents() throws {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        scroll.verticalLineScroll = 10
        let native = NSScrollView(frame: scroll.frame)
        window.contentView!.addSubview(native, positioned: .below, relativeTo: scroll)
        native.hasVerticalScroller = true
        native.verticalLineScroll = scroll.verticalLineScroll
        native.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 600, height: 20000))
        scroll.documentView!.frame.size.height = 20000
        bridge.smoothScroller.reduceMotion = { false }
        let samples: [(ticks: Int32, accelerated: Double?)] = [
            (-1, nil), (-3, nil), (-10, nil), (-1, -1.23), (-1, -1.5), (-1, -3), (-1, -9), (-1, -30)
        ]
        for (ticks, accelerated) in samples {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                          wheelCount: 1, wheel1: ticks, wheel2: 0, wheel3: 0))
            // AppKit uses the fixed-point delta for non-precise acceleration, even when the
            // integer notch count and point payload differ. Include a fractional line delta.
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(ticks * 30))
            let local = try XCTUnwrap(middle(.otherMouseDown, in: window).cgEvent?.copy())
            local.type = .scrollWheel
            for field: CGEventField in [.scrollWheelEventDeltaAxis1,
                                        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventIsContinuous] {
                local.setIntegerValueField(field, value: cg.getIntegerValueField(field))
            }
            // Setting the integer delta also resets the fixed-point field, so set it last.
            local.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1,
                                      value: accelerated ?? cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
            let event = try XCTUnwrap(NSEvent(cgEvent: local))
            XCTAssertTrue(event.window === window)
            XCTAssertEqual(event.scrollingDeltaY, CGFloat(accelerated ?? Double(ticks)), accuracy: 1.0 / 65536)
            native.contentView.scroll(to: CGPoint(x: 0, y: 1000))
            native.reflectScrolledClipView(native.contentView)
            native.scrollWheel(with: event)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            let expected = native.contentView.bounds.minY - 1000
            scroll.contentView.scroll(to: CGPoint(x: 0, y: 1000))
            XCTAssertNil(bridge.handleMonitoredEvent(event))
            bridge.smoothScroller.advance(at: ProcessInfo.processInfo.systemUptime + 0.2)
            XCTAssertFalse(bridge.smoothScroller.isAnimating)
            let actual = scroll.contentView.bounds.minY - 1000
            print("WHEEL_DISTANCE ticks=\(ticks) line=\(event.scrollingDeltaY) point=\(event.cgEvent!.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)) native=\(expected) eased=\(actual)")
            XCTAssertNotEqual(expected, 0)
            // Native wheel animation snaps fractional travel to backing pixels.
            XCTAssertGreaterThanOrEqual(abs(actual) + 0.01, abs(expected))
            XCTAssertEqual(actual, expected, accuracy: 1 / window.backingScaleFactor)
        }
    }

    func testLayoutAnchorRebasesQueuedWheelTravelBeforeTheNextFrame() {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        XCTAssertTrue(scroller.scroll(by: 100, in: scroll))
        let now = ProcessInfo.processInfo.systemUptime
        scroller.advance(at: now + 0.04)
        let current = scroll.contentView.bounds.minY
        scroll.contentView.scroll(to: CGPoint(x: 0, y: current + 50))
        XCTAssertEqual(scroller.destination(in: scroll), 150, accuracy: 0.01)
        XCTAssertTrue(scroller.scroll(by: 100, in: scroll))
        scroller.advance(at: now + 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, 250, accuracy: 0.01)
    }

    func testSynchronousLayoutAnchorAdjustmentPreservesPendingTravel() {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        scroll.contentView.postsBoundsChangedNotifications = true
        var adjusted = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard !adjusted else { return }
                adjusted = true
                scroll.documentView!.frame.size.height += 400
                scroll.contentView.scroll(to: CGPoint(x: 0, y: scroll.contentView.bounds.minY + 50))
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertTrue(scroller.scroll(by: 200, in: scroll))
        let now = ProcessInfo.processInfo.systemUptime
        scroller.advance(at: now + 0.04)
        XCTAssertTrue(adjusted)
        scroller.advance(at: now + 0.2)
        XCTAssertEqual(scroll.contentView.bounds.minY, 250, accuracy: 0.01)
    }

    func testHomeKeepsTheTopTargetThroughGrowthAndAnchorCorrection() {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1000))
        XCTAssertTrue(scroller.scroll(.first, in: scroll))
        let now = ProcessInfo.processInfo.systemUptime
        scroller.advance(at: now + 0.04)
        scroll.documentView!.frame.size.height += 400
        scroll.contentView.scroll(to: CGPoint(x: 0, y: scroll.contentView.bounds.minY + 100))
        scroller.advance(at: now + 0.2)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.01)
        XCTAssertFalse(scroller.isAnimating)
    }

    func testPageUpKeepsItsOverlapAndAnimatesThroughDocumentGrowth() {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 1000))
        XCTAssertTrue(scroller.scroll(.pageUp, in: scroll))
        let now = ProcessInfo.processInfo.systemUptime
        scroller.advance(at: now + 0.04)
        XCTAssertLessThan(scroll.contentView.bounds.minY, 1000)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 640)
        scroll.documentView!.frame.size.height += 400
        scroller.advance(at: now + 0.2)
        XCTAssertEqual(scroll.contentView.bounds.minY, 640, accuracy: 0.01)
    }

    func testShrinkingDocumentReclampsAndCompletesPendingTravel() {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        XCTAssertTrue(scroller.scroll(to: 1800, in: scroll))
        let now = ProcessInfo.processInfo.systemUptime
        scroller.advance(at: now + 0.04)
        scroll.documentView!.frame.size.height = 1200
        scroller.advance(at: now + 0.2)
        XCTAssertEqual(scroll.contentView.bounds.maxY, 1200, accuracy: 0.01)
        XCTAssertFalse(scroller.isAnimating)
    }

    func testEndAtTheOldBottomWaitsForLateGrowthAndHasABoundedLifetime() {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 2600))
        XCTAssertTrue(scroller.scroll(.last, in: scroll))
        let now = ProcessInfo.processInfo.systemUptime
        scroller.advance(at: now + 0.17)
        XCTAssertTrue(scroller.isAnimating)
        scroll.documentView!.frame.size.height += 400
        scroller.advance(at: now + 0.18)
        XCTAssertGreaterThan(scroll.contentView.bounds.maxY, 3000)
        XCTAssertLessThan(scroll.contentView.bounds.maxY, 3400)
        for frame in 27...145 {
            scroll.documentView!.frame.size.height += 2
            scroller.advance(at: now + Double(frame) / 144)
            if !scroller.isAnimating { break }
        }
        XCTAssertFalse(scroller.isAnimating)
        XCTAssertEqual(scroll.contentView.bounds.maxY, scroll.documentView!.bounds.maxY, accuracy: 0.01)
    }

    func testEndSettlesEarlyAndReduceMotionTerminalCommandsJumpImmediately() {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        XCTAssertTrue(scroller.scroll(.last, in: scroll))
        let now = ProcessInfo.processInfo.systemUptime
        scroller.advance(at: now + 0.17)
        XCTAssertTrue(scroller.isAnimating)
        scroller.advance(at: now + 0.4)
        XCTAssertFalse(scroller.isAnimating)
        scroller.reduceMotion = { true }
        XCTAssertTrue(scroller.scroll(.first, in: scroll))
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.01)
        XCTAssertTrue(scroller.scroll(.last, in: scroll))
        XCTAssertEqual(scroll.contentView.bounds.maxY, 3000, accuracy: 0.01)
        XCTAssertFalse(scroller.isAnimating)
    }

    func testAnimationYieldsToResizeAndDetachment() {
        let (window, scroll, bridge) = fixture()
        defer { bridge.removeFromSuperview(); withExtendedLifetime(window) {} }
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        XCTAssertTrue(scroller.scroll(by: 100, in: scroll))
        scroll.frame.size.height = 300
        scroller.advance(at: ProcessInfo.processInfo.systemUptime + 1)
        XCTAssertFalse(scroller.isAnimating)
        XCTAssertTrue(scroller.scroll(by: 100, in: scroll))
        bridge.removeFromSuperview()
        XCTAssertFalse(scroller.isAnimating)
    }
}
