import AppKit

/// Calls `onFrame` once per refresh of the view's display with the time the frame will appear,
/// so scrolling moves exactly once per frame (a fixed-rate timer drifts against 144 Hz and
/// judders). Stops when `onFrame` returns false or on `stop()`.
@MainActor
final class DisplayFrameTicker: NSObject {
    private var link: CADisplayLink?
    private let onFrame: (TimeInterval) -> Bool

    init(onFrame: @escaping (TimeInterval) -> Bool) {
        self.onFrame = onFrame
    }

    func start(on view: NSView) {
        stop()
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        if !onFrame(link.targetTimestamp) { stop() }
    }
}

/// One bounded animation owner for the library viewport. Precise devices retain AppKit's
/// acceleration, rubber banding, and momentum; only unphased vertical wheel steps are eased.
@MainActor
final class LibrarySmoothScroller {
    private weak var scrollView: NSScrollView?
    private lazy var ticker = DisplayFrameTicker { [weak self] now in
        guard let self else { return false }
        self.advance(at: now)
        return self.isAnimating
    }
    private var targetY: CGFloat = 0
    private var startY: CGFloat = 0
    private var startedAt: TimeInterval = 0
    private var beganAt: TimeInterval = 0
    private var lastAdvancedAt: TimeInterval = 0
    private var settledAt: TimeInterval?
    private var terminalCommand: LibraryViewportCommand?
    private weak var documentView: NSView?
    private var lastBounds: NSRect = .zero
    private var documentBounds: NSRect = .zero
    private var observers: [NSObjectProtocol] = []
    private var usesRevealTiming = false
    private(set) var isAnimating = false
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    #if DEBUG
    var benchmarkTime: TimeInterval?
    #endif

    init() {
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                if name == NSApplication.didResignActiveNotification || notification.object as? NSWindow === self.scrollView?.window {
                    self.cancel()
                }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    static func shouldSmooth(_ event: NSEvent) -> Bool {
        event.type == .scrollWheel && !event.hasPreciseScrollingDeltas &&
        event.phase.isEmpty && event.momentumPhase.isEmpty &&
        event.scrollingDeltaX == 0 && event.scrollingDeltaY != 0 &&
        event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
    }

    func destination(in view: NSScrollView) -> CGFloat {
        guard isAnimating, scrollView === view, reconcileLayout(in: view) else {
            return view.contentView.bounds.minY
        }
        return targetY
    }

    @discardableResult
    func scroll(by delta: CGFloat, in view: NSScrollView) -> Bool {
        let current = view.contentView.bounds.minY
        let destination = destination(in: view)
        let remaining = destination - current
        // A reverse wheel tick expresses a new direction, not a reduction of queued travel.
        // Retain accumulation only while the input agrees with the pending movement.
        let reversesDirection = (delta < 0 && remaining > 0) || (delta > 0 && remaining < 0)
        return scroll(to: (reversesDirection ? current : destination) + delta, in: view)
    }

    @discardableResult
    func scroll(_ command: LibraryViewportCommand, in view: NSScrollView) -> Bool {
        guard let document = view.documentView else { return false }
        if command == .pageUp || command == .pageDown {
            let height = view.contentView.bounds.height
            let distance = max(0, height - LibraryViewportScrollGeometry.continuityOverlap(for: height))
            return scroll(by: command == .pageUp ? -distance : distance, in: view)
        }
        let target = LibraryViewportScrollGeometry.targetOffset(
            for: command, currentOffset: destination(in: view),
            viewportHeight: view.contentView.bounds.height,
            contentMinY: document.bounds.minY, contentMaxY: document.bounds.maxY)
        return scroll(to: target, in: view, terminal: command)
    }

    @discardableResult
    func scroll(to offset: CGFloat, in view: NSScrollView) -> Bool {
        scroll(to: offset, in: view, terminal: nil)
    }

    @discardableResult
    func reveal(to offset: CGFloat, in view: NSScrollView) -> Bool {
        let moved = scroll(to: offset, in: view)
        if isAnimating { usesRevealTiming = true }
        return moved
    }

    /// Match the grid's existing 0.2-second ease-in-out item reveal.
    static func revealProgress(_ progress: Double) -> Double {
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<20 {
            let t = (lower + upper) / 2
            let x = 3 * (1 - t) * (1 - t) * t * 0.42 + 3 * (1 - t) * t * t * 0.58 + t * t * t
            if x < progress { lower = t } else { upper = t }
        }
        let t = (lower + upper) / 2
        return 3 * (1 - t) * t * t + t * t * t
    }

    private func scroll(to offset: CGFloat, in view: NSScrollView, terminal: LibraryViewportCommand?) -> Bool {
        guard offset.isFinite, let document = view.documentView else { return false }
        var proposed = view.contentView.bounds
        proposed.origin.y = offset
        let constrained = view.contentView.constrainBoundsRect(proposed)
        cancel()
        let jumps = reduceMotion()
        guard constrained.origin != view.contentView.bounds.origin || (terminal == .last && !jumps) else { return false }
        if jumps {
            view.contentView.scroll(to: constrained.origin)
            view.reflectScrolledClipView(view.contentView)
            return true
        }
        scrollView = view
        startY = view.contentView.bounds.minY
        targetY = offset
        terminalCommand = terminal
        documentView = document
        lastBounds = view.contentView.bounds
        documentBounds = document.bounds
        startedAt = ProcessInfo.processInfo.systemUptime
        #if DEBUG
        startedAt = benchmarkTime ?? startedAt
        #endif
        beganAt = startedAt
        lastAdvancedAt = startedAt
        settledAt = nil
        isAnimating = true
        ticker.start(on: view)
        return true
    }

    private func reconcileLayout(in view: NSScrollView) -> Bool {
        guard let documentView, view.documentView === documentView,
              view.contentView.bounds.size == lastBounds.size,
              view.contentView.bounds.minX == lastBounds.minX else {
            cancel()
            return false
        }
        // The input monitor cancels for trackpads, scroll bar clicks, and other user input
        // before AppKit moves the clip. A remaining vertical shift is a layout/anchor correction:
        // carry the pending travel with it, excluding any automatic clamp after a shrink.
        let clampedPrevious = view.contentView.constrainBoundsRect(lastBounds)
        let shift = view.contentView.bounds.minY - clampedPrevious.minY
        startY += shift
        if terminalCommand == nil { targetY += shift }
        if view.documentView?.bounds != documentBounds {
            settledAt = nil
            documentBounds = view.documentView?.bounds ?? .zero
        }
        lastBounds = view.contentView.bounds
        return true
    }

    /// Also used by offscreen tests to advance the real clip view without waiting on timers.
    func advance(at now: TimeInterval) {
        guard isAnimating, let view = scrollView, view.window != nil,
              !view.isHiddenOrHasHiddenAncestor, reconcileLayout(in: view) else {
            cancel()
            return
        }
        if let terminalCommand, let document = view.documentView {
            let edge = LibraryViewportScrollGeometry.targetOffset(
                for: terminalCommand, currentOffset: view.contentView.bounds.minY,
                viewportHeight: view.contentView.bounds.height,
                contentMinY: document.bounds.minY, contentMaxY: document.bounds.maxY)
            if edge != targetY {
                startY = view.contentView.bounds.minY
                targetY = edge
                startedAt = lastAdvancedAt
                settledAt = nil
            }
        }
        let jumps = reduceMotion()
        // End follows lazy measurement and pagination until the bottom has settled for 0.2 s.
        // A one-second limit also bounds any animation with repeated layout corrections.
        let reachedDeadline = now - beganAt >= 1
        let duration = usesRevealTiming ? 0.2 : 0.16
        let progress = jumps || reachedDeadline ? 1 : min(1, max(0, (now - startedAt) / duration))
        let eased = usesRevealTiming ? Self.revealProgress(progress) : 1 - pow(1 - progress, 3)
        var proposed = view.contentView.bounds
        proposed.origin.y = targetY
        let destination = view.contentView.constrainBoundsRect(proposed).minY
        proposed.origin.y = startY + (destination - startY) * eased
        let constrained = view.contentView.constrainBoundsRect(proposed)
        // Keep the bounds we asked for, so a synchronous layout correction during scrolling
        // is still recognized as an anchor shift on the next frame.
        lastBounds = constrained
        view.contentView.scroll(to: constrained.origin)
        view.reflectScrolledClipView(view.contentView)
        lastAdvancedAt = now
        if !reachedDeadline && !jumps {
            if view.contentView.bounds != lastBounds { return }
            if view.documentView?.bounds != documentBounds {
                proposed.origin.y = targetY
                let latestDestination = view.contentView.constrainBoundsRect(proposed).minY
                if terminalCommand != nil || latestDestination != view.contentView.bounds.minY { return }
            }
        }
        if progress >= 1 {
            if terminalCommand == .last && !jumps && !reachedDeadline {
                if settledAt == nil { settledAt = now }
                if now - (settledAt ?? now) < 0.2 { return }
            }
            cancel()
        }
    }

    func cancel() {
        ticker.stop()
        isAnimating = false
        scrollView = nil
        documentView = nil
        terminalCommand = nil
        usesRevealTiming = false
        settledAt = nil
    }

    #if DEBUG
    /// Hidden-window benchmarks advance the same animation at a controlled refresh rate.
    func pauseFrameTickerForBenchmark() {
        ticker.stop()
    }
    #endif
}
