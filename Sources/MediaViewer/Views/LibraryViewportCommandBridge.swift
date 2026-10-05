import SwiftUI
import AppKit

/// The library surface that should receive a viewport command. Including the surface in each
/// request prevents a stale grid/table bridge from reacting while SwiftUI replaces browse modes.
enum LibraryViewportSurface: Equatable {
    case grid
    case table
}

/// Viewport movement commands shared by the keyboard monitor, command palette, and AppKit bridge.
enum LibraryViewportCommand: Equatable {
    case pageUp
    case pageDown
    case first
    case last
}

struct LibraryViewportCommandRequest: Equatable {
    let command: LibraryViewportCommand
    let surface: LibraryViewportSurface
}

/// Single routing authority used by physical shortcuts and command-palette actions.
@MainActor
enum LibraryViewportCommandRouter {
    static func isAvailable(in appState: AppState) -> Bool {
        guard !appState.isShowingSingleFocus,
              appState.activeDisplayContext?.itemIDs.isEmpty == false else {
            return false
        }

        switch appState.sidebarSelection {
        case .allMedia, .folderYear, .folder, .smartFolder, .platform, .tag, .recentlyDeleted:
            return true
        case .board, .canvas, .rediscover, .duplicates, .visualClusters:
            return false
        }
    }

    static func post(_ command: LibraryViewportCommand, appState: AppState) {
        guard isAvailable(in: appState) else { return }
        let surface: LibraryViewportSurface = appState.browseMode == .grid ? .grid : .table
        NotificationCenter.default.post(
            name: .libraryViewportCommand,
            object: LibraryViewportCommandRequest(command: command, surface: surface)
        )
    }
}

/// Pure scroll math kept separate from AppKit so page continuity and terminal behavior are tested.
enum LibraryViewportScrollGeometry {
    /// Retain a small strip of the previous page so the user's visual position is not lost.
    static func continuityOverlap(for viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return 0 }
        let preferred = min(96, max(32, viewportHeight * 0.1))
        return min(preferred, viewportHeight * 0.25)
    }

    static func targetOffset(
        for command: LibraryViewportCommand,
        currentOffset: CGFloat,
        viewportHeight: CGFloat,
        contentMinY: CGFloat,
        contentMaxY: CGFloat
    ) -> CGFloat {
        guard currentOffset.isFinite,
              viewportHeight.isFinite,
              contentMinY.isFinite,
              contentMaxY.isFinite,
              viewportHeight > 0 else {
            return currentOffset
        }

        let lowerBound = contentMinY
        let upperBound = max(lowerBound, contentMaxY - viewportHeight)
        let pageDistance = max(0, viewportHeight - continuityOverlap(for: viewportHeight))

        let proposed: CGFloat
        switch command {
        case .pageUp:
            proposed = currentOffset - pageDistance
        case .pageDown:
            proposed = currentOffset + pageDistance
        case .first:
            proposed = lowerBound
        case .last:
            proposed = upperBound
        }

        return min(upperBound, max(lowerBound, proposed))
    }
}

@MainActor
enum LibraryViewportScroller {
    @discardableResult
    static func apply(_ command: LibraryViewportCommand, to scrollView: NSScrollView) -> Bool {
        let clipView = scrollView.contentView
        guard let documentView = scrollView.documentView else { return false }

        var proposedBounds = clipView.bounds
        proposedBounds.origin.y = LibraryViewportScrollGeometry.targetOffset(
            for: command,
            currentOffset: proposedBounds.origin.y,
            viewportHeight: proposedBounds.height,
            contentMinY: documentView.bounds.minY,
            contentMaxY: documentView.bounds.maxY
        )

        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        guard constrainedBounds.origin != clipView.bounds.origin else { return false }
        clipView.scroll(to: constrainedBounds.origin)
        scrollView.reflectScrolledClipView(clipView)
        return true
    }
}

/// Invisible bridge that knows the exact library rectangle and scrolls its underlying NSScrollView.
/// It does not become first responder or participate in hit testing.
struct LibraryViewportCommandBridge: NSViewRepresentable {
    let surface: LibraryViewportSurface
    var isEnabled: Bool = true

    func makeNSView(context: Context) -> LibraryViewportCommandView {
        let view = LibraryViewportCommandView()
        view.surface = surface
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: LibraryViewportCommandView, context: Context) {
        nsView.surface = surface
        nsView.isEnabled = isEnabled
    }
}

class LibraryViewportCommandView: NSView {
    var surface: LibraryViewportSurface = .grid
    var isEnabled = true {
        didSet {
            guard !isEnabled else { return }
            smoothScroller.cancel()
            prepareForViewportCommand()
        }
    }
    let smoothScroller = LibrarySmoothScroller()
    private var inputMonitor: Any?
    private weak var cachedScrollView: NSScrollView?
    private(set) var fullHierarchySearchCount = 0
    var onViewportChanged: ((CGFloat, CGFloat, CGFloat) -> Void)?
    var onViewportWillChange: ((NSScrollView) -> Void)?
    var onViewportInput: (() -> Void)?
    private weak var observedClipView: NSClipView?
    private weak var observedDocumentView: NSView?
    private var viewportObservers: [NSObjectProtocol] = []
    private var viewportDeliveryScheduled = false

    private static let excludedInteractiveViewClassMarkers = [
        "WK", "WebKit", "AVPlayer", "PDFView", "QuickLook"
    ]

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleViewportCommand(_:)),
            name: .libraryViewportCommand,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleViewportCommand(_:)),
            name: .libraryViewportCommand,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        for observer in viewportObservers { NotificationCenter.default.removeObserver(observer) }
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        smoothScroller.cancel()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
        if cachedScrollView?.window !== window {
            cachedScrollView = nil
        }
        removeViewportObservers()
        guard window != nil else { return }
        refreshViewportObservation()
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .scrollWheel, .otherMouseDown, .otherMouseDragged, .otherMouseUp,
            .leftMouseDown, .rightMouseDown, .keyDown
        ]) { [weak self] event in
            guard let self else { return event }
            // A nil result means consumed. Optional coalescing here would re-deliver it.
            return self.handleMonitoredEvent(event)
        }
    }

    override func layout() {
        super.layout()
        refreshViewportObservation()
    }

    /// Track native bounds without making SwiftUI measure the full grid at every scroll step.
    /// Deliver after layout so returning to the top can safely publish pending insertions.
    func refreshViewportObservation() {
        guard onViewportChanged != nil, window != nil,
              let scrollView = resolveLibraryScrollView(),
              let document = scrollView.documentView else {
            removeViewportObservers()
            return
        }
        let clip = scrollView.contentView
        if observedClipView !== clip || observedDocumentView !== document {
            removeViewportObservers()
            observedClipView = clip
            observedDocumentView = document
            clip.postsBoundsChangedNotifications = true
            document.postsFrameChangedNotifications = true
            document.postsBoundsChangedNotifications = true
            for (name, object) in [
                (NSView.boundsDidChangeNotification, clip),
                (NSView.frameDidChangeNotification, document),
                (NSView.boundsDidChangeNotification, document)
            ] {
                let updatesWindow = object === clip
                viewportObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: object, queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    if updatesWindow { self.updateViewportWindow() }
                    self.scheduleViewportDelivery()
                })
            }
        }
        scheduleViewportDelivery()
    }

    private func scheduleViewportDelivery() {
        guard !viewportDeliveryScheduled else { return }
        viewportDeliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportDeliveryScheduled = false
            guard self.window != nil, let clip = self.observedClipView,
                  let document = self.observedDocumentView,
                  clip.window === self.window, document.window === self.window,
                  let scroll = self.resolveLibraryScrollView(),
                  scroll.contentView === clip, scroll.documentView === document else { return }
            self.onViewportWillChange?(scroll)
            self.onViewportChanged?(-clip.bounds.minY, clip.bounds.height, document.bounds.maxY)
        }
    }

    private func updateViewportWindow() {
        guard window != nil, let scroll = resolveLibraryScrollView(),
              scroll.contentView === observedClipView else { return }
        onViewportWillChange?(scroll)
    }

    private func removeViewportObservers() {
        for observer in viewportObservers { NotificationCenter.default.removeObserver(observer) }
        viewportObservers.removeAll()
        observedClipView = nil
        observedDocumentView = nil
    }

    func handleInteractionEvent(_ event: NSEvent) -> NSEvent? { event }
    func prepareForViewportCommand() {}

    func handleMonitoredEvent(_ event: NSEvent) -> NSEvent? {
        guard isEnabled, window != nil, event.window === window, !isHiddenOrHasHiddenAncestor else { return event }
        if [.otherMouseDown, .leftMouseDown, .rightMouseDown].contains(event.type),
           visibleRect.contains(convert(event.locationInWindow, from: nil)) {
            onViewportInput?()
        }
        guard let event = handleInteractionEvent(event) else { return nil }
        guard event.type == .scrollWheel else {
            if event.type != .keyDown || ![115, 116, 119, 121].contains(Int(event.keyCode)) {
                smoothScroller.cancel()
            }
            return event
        }
        guard visibleRect.contains(convert(event.locationInWindow, from: nil)),
              let scrollView = resolveLibraryScrollView() else { return event }
        onViewportInput?()
        guard LibrarySmoothScroller.shouldSmooth(event),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            smoothScroller.cancel()
            return event
        }
        // Non-precise scrollingDeltaY includes AppKit's fixed-point wheel acceleration.
        let distance = -event.scrollingDeltaY * scrollView.verticalLineScroll
        return smoothScroller.scroll(by: distance, in: scrollView) ? nil : event
    }

    @objc private func handleViewportCommand(_ notification: Notification) {
        guard isEnabled, let request = notification.object as? LibraryViewportCommandRequest,
              request.surface == surface,
              window === NSApp.keyWindow,
              let scrollView = resolveLibraryScrollView() else {
            return
        }
        onViewportInput?()
        prepareForViewportCommand()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            smoothScroller.cancel()
            LibraryViewportScroller.apply(request.command, to: scrollView)
        } else {
            smoothScroller.scroll(request.command, in: scrollView)
        }
    }

    func resolveLibraryScrollView() -> NSScrollView? {
        if let cachedScrollView, isUsableCachedScrollView(cachedScrollView) {
            return cachedScrollView
        }
        cachedScrollView = nil

        if let enclosing = nearestEnclosingScrollView(), !isExcludedInteractiveScrollView(enclosing) {
            cachedScrollView = enclosing
            return enclosing
        }

        guard let root = window?.contentView else { return nil }
        let bridgeRect = convert(bounds, to: nil)
        guard bridgeRect.width > 0, bridgeRect.height > 0 else { return nil }
        fullHierarchySearchCount += 1

        var bestCandidate: NSScrollView?
        var bestIntersectionArea: CGFloat = 0
        var pending = root.subviews
        while let view = pending.popLast() {
            if let candidate = view as? NSScrollView,
               candidate.window === window,
               !candidate.isHidden,
               candidate.alphaValue > 0,
               !isExcludedInteractiveScrollView(candidate) {
                let candidateRect = candidate.convert(candidate.bounds, to: nil)
                let intersection = bridgeRect.intersection(candidateRect)
                if !intersection.isNull {
                    let area = intersection.width * intersection.height
                    if area > bestIntersectionArea {
                        bestIntersectionArea = area
                        bestCandidate = candidate
                    }
                }
            }
            pending.append(contentsOf: view.subviews)
        }

        cachedScrollView = bestCandidate
        return bestCandidate
    }

    private func nearestEnclosingScrollView() -> NSScrollView? {
        var candidate = superview
        while let current = candidate {
            if let scrollView = current as? NSScrollView { return scrollView }
            candidate = current.superview
        }
        return nil
    }

    private func isUsableCachedScrollView(_ scrollView: NSScrollView) -> Bool {
        guard scrollView.window === window,
              !scrollView.isHidden,
              scrollView.alphaValue > 0,
              !isExcludedInteractiveScrollView(scrollView) else {
            return false
        }

        // An enclosing scroll view is intrinsically associated with this bridge. A sibling found
        // by overlap must still intersect after a lens/layout transition.
        var ancestor = superview
        while let current = ancestor {
            if current === scrollView { return true }
            ancestor = current.superview
        }

        let bridgeRect = convert(bounds, to: nil)
        let candidateRect = scrollView.convert(scrollView.bounds, to: nil)
        let intersection = bridgeRect.intersection(candidateRect)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }

    /// Page keys belong to an explicitly focused embedded viewer, not the surrounding library.
    private func isExcludedInteractiveScrollView(_ scrollView: NSScrollView) -> Bool {
        var candidate: NSView? = scrollView
        while let current = candidate {
            if Self.excludedInteractiveViewClassMarkers.contains(where: { current.className.contains($0) }) {
                return true
            }
            candidate = current.superview
        }

        if let documentView = scrollView.documentView,
           Self.excludedInteractiveViewClassMarkers.contains(where: { documentView.className.contains($0) }) {
            return true
        }
        return false
    }
}

// MARK: - Native Table Focus-Return Reveal

struct TableLibraryItemRevealRequest: Equatable {
    let generation: Int
    let itemID: UUID
}

@MainActor
enum TableSelectionRevealScroller {
    /// Reveal and center the native selected row. Reading `selectedRow` lets SwiftUI's UUID
    /// selection binding remain the identity authority, including when grouped rows add headers.
    @discardableResult
    static func revealSelection(in tableView: NSTableView) -> Bool {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < tableView.numberOfRows else { return false }

        tableView.scrollRowToVisible(selectedRow)
        guard let scrollView = tableView.enclosingScrollView else { return true }

        let clipView = scrollView.contentView
        var proposedBounds = clipView.bounds
        proposedBounds.origin.y = tableView.rect(ofRow: selectedRow).midY - proposedBounds.height / 2
        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        if constrainedBounds.origin != clipView.bounds.origin {
            clipView.scroll(to: constrainedBounds.origin)
            scrollView.reflectScrolledClipView(clipView)
        }
        return true
    }
}

/// Invisible AppKit bridge used only for generation-stamped focus-return requests. It caches the
/// native table after the first hierarchy lookup and waits for SwiftUI's selection binding before
/// revealing, avoiding polling or per-row scans.
struct TableSelectionRevealBridge: NSViewRepresentable {
    let request: TableLibraryItemRevealRequest?
    var contextSelectionEnabled: () -> Bool = { false }

    func makeNSView(context: Context) -> TableSelectionRevealView {
        let view = TableSelectionRevealView()
        view.contextSelectionEnabled = contextSelectionEnabled
        view.requestReveal(request)
        return view
    }

    func updateNSView(_ nsView: TableSelectionRevealView, context: Context) {
        nsView.contextSelectionEnabled = contextSelectionEnabled
        nsView.requestReveal(request)
    }
}

final class TableSelectionRevealView: NSView {
    var contextSelectionEnabled: () -> Bool = { false }
    private var contextMonitor: Any?
    private weak var cachedTableView: NSTableView?
    private var pendingRequest: TableLibraryItemRevealRequest?
    private var lastRevealedGeneration: Int?
    private var scheduledGeneration: Int?
    private(set) var fullHierarchySearchCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTableSelectionChange(_:)),
            name: NSTableView.selectionDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTableSelectionChange(_:)),
            name: NSTableView.selectionDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let contextMonitor { NSEvent.removeMonitor(contextMonitor) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if cachedTableView?.window !== window {
            cachedTableView = nil
        }
        scheduleRevealIfNeeded()
        if let contextMonitor { NSEvent.removeMonitor(contextMonitor); self.contextMonitor = nil }
        guard window != nil else { return }
        contextMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, self.contextSelectionEnabled(), event.window === self.window,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)),
                  let table = self.resolveTableView() else { return event }
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            if row >= 0, !table.selectedRowIndexes.contains(row),
               table.delegate?.tableView?(table, shouldSelectRow: row) != false {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            return event
        }
    }

    func requestReveal(_ request: TableLibraryItemRevealRequest?) {
        guard let request,
              request.generation != lastRevealedGeneration,
              request != pendingRequest else {
            return
        }
        pendingRequest = request
        scheduleRevealIfNeeded()
    }

    @objc private func handleTableSelectionChange(_ notification: Notification) {
        guard pendingRequest != nil,
              let changedTable = notification.object as? NSTableView,
              changedTable === resolveTableView() else {
            return
        }
        attemptReveal()
    }

    private func scheduleRevealIfNeeded() {
        guard let generation = pendingRequest?.generation,
              generation != scheduledGeneration else {
            return
        }
        scheduledGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.scheduledGeneration == generation {
                self.scheduledGeneration = nil
            }
            self.attemptReveal()
        }
    }

    private func attemptReveal() {
        guard let request = pendingRequest,
              window != nil,
              let tableView = resolveTableView(),
              TableSelectionRevealScroller.revealSelection(in: tableView) else {
            return
        }
        lastRevealedGeneration = request.generation
        pendingRequest = nil
    }

    func resolveTableView() -> NSTableView? {
        if let cachedTableView,
           cachedTableView.window === window,
           !cachedTableView.isHidden,
           cachedTableView.alphaValue > 0 {
            return cachedTableView
        }
        cachedTableView = nil

        var ancestor = superview
        while let current = ancestor {
            if let tableView = current as? NSTableView {
                cachedTableView = tableView
                return tableView
            }
            ancestor = current.superview
        }

        guard let root = window?.contentView else { return nil }
        let bridgeRect = convert(bounds, to: nil)
        guard bridgeRect.width > 0, bridgeRect.height > 0 else { return nil }
        fullHierarchySearchCount += 1

        var bestCandidate: NSTableView?
        var bestIntersectionArea: CGFloat = 0
        var pending = root.subviews
        while let view = pending.popLast() {
            if let candidate = view as? NSTableView,
               candidate.window === window,
               !candidate.isHidden,
               candidate.alphaValue > 0 {
                let candidateRect = candidate.convert(candidate.bounds, to: nil)
                let intersection = bridgeRect.intersection(candidateRect)
                if !intersection.isNull {
                    let area = intersection.width * intersection.height
                    if area > bestIntersectionArea {
                        bestIntersectionArea = area
                        bestCandidate = candidate
                    }
                }
            }
            pending.append(contentsOf: view.subviews)
        }

        cachedTableView = bestCandidate
        return bestCandidate
    }
}
