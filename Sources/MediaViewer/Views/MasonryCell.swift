import SwiftUI
import AppKit
import AVFoundation
import os.signpost

/// Global right-click interception gate used to suspend grid cell handlers
/// while focus mode is visible over the library.
private enum GridRightClickInterceptionGate {
    static var isEnabled = true
}

// MARK: - Grid Input Routing

/// Hit-test contract for grid context clicks. A cell claims a click only inside the
/// part of it that is actually visible: `bounds` also covers the portion a scroll view
/// has clipped under the toolbar/filter chrome, which let a hidden cell steal
/// right-clicks aimed at that chrome.
enum GridContextClickHitTest {
    static func claims(_ pointInView: NSPoint, visibleRect: NSRect) -> Bool {
        !visibleRect.isEmpty && visibleRect.contains(pointInView)
    }
}

/// One local event monitor shared by context-click and drag anchors. Mouse-down
/// resolves one visible cell; drag/up events go only to that captured source.
@MainActor
final class GridContextClickRouter {
    static let shared = GridContextClickRouter()

    private var monitor: Any?
    private let views = NSHashTable<RightClickView>.weakObjects()
    private weak var activeDragView: MediaFileDragSource.DragView?

    func register(_ view: RightClickView) {
        views.add(view)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            MainActor.assumeIsolated { GridContextClickRouter.shared.route(event) }
        }
    }

    func unregister(_ view: RightClickView) {
        views.remove(view)
        if activeDragView === view {
            activeDragView?.cancelDragCapture()
            activeDragView = nil
        }
        guard views.allObjects.isEmpty, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    var registeredViewCount: Int { views.allObjects.count }
    var eventMonitorCount: Int { monitor == nil ? 0 : 1 }

    func route(_ event: NSEvent) -> NSEvent? {
        let isContextClick = event.type == .rightMouseDown ||
            (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        if isContextClick {
            activeDragView?.cancelDragCapture()
            activeDragView = nil
            guard GridRightClickInterceptionGate.isEnabled, let window = event.window else { return event }
            for view in views.allObjects where view.window === window && !view.isHiddenOrHasHiddenAncestor {
                guard let onRightClick = view.onRightClick else { continue }
                let point = view.convert(event.locationInWindow, from: nil)
                guard GridContextClickHitTest.claims(point, visibleRect: view.visibleRect) else { continue }
                // Preserve the AppKit window point for the custom grid menu.
                onRightClick(event.locationInWindow)
                return nil
            }
            return event
        }

        switch event.type {
        case .leftMouseDown:
            activeDragView?.cancelDragCapture()
            activeDragView = nil
            guard let window = event.window else { return event }
            for case let view as MediaFileDragSource.DragView in views.allObjects {
                guard view.window === window, view.isDragEnabled(),
                      !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0 else { continue }
                let point = view.convert(event.locationInWindow, from: nil)
                guard GridContextClickHitTest.claims(point, visibleRect: view.visibleRect) else { continue }
                activeDragView = view
                view.captureMouseDown(event)
                break
            }
        case .leftMouseDragged:
            guard let view = activeDragView else { return event }
            guard view.window != nil, event.window === view.window, view.isDragEnabled(),
                  !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0 else {
                view.cancelDragCapture()
                activeDragView = nil
                return event
            }
            let routed = view.routeDrag(event)
            if routed == nil { activeDragView = nil }
            return routed
        case .leftMouseUp:
            activeDragView?.cancelDragCapture()
            activeDragView = nil
        default: break
        }
        return event
    }
}

/// Transparent anchor for one cell's geometry. Drag sources subclass it so both
/// gestures share the same view and router, without claiming SwiftUI hit tests.
class RightClickView: NSView {
    var onRightClick: ((CGPoint) -> Void)?

    init(onRightClick: ((CGPoint) -> Void)?) {
        self.onRightClick = onRightClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            GridContextClickRouter.shared.register(self)
        } else {
            GridContextClickRouter.shared.unregister(self)
        }
    }

    // NEVER claim hit test - let all events pass through to SwiftUI
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

enum MasonryContextSelectionPolicy {
    /// A context-click on a selected row acts on the current selection; a click
    /// on any other row replaces it with only the clicked row.
    static func targetIDs(clickedID: UUID, selectedIDs: Set<UUID>) -> Set<UUID> {
        guard selectedIDs.contains(clickedID), selectedIDs.count > 1 else { return [clickedID] }
        return selectedIDs
    }
}

// MARK: - Context Menu Actions

/// Actions available in the masonry cell context menu.
/// Passed from the parent view that has access to viewModel and appState.
struct MasonryCellContextActions {
    let selectedCount: Int
    let isStarred: Bool
    let dominantColors: [ColorBucket]  // For "Find Similar Colors" feature
    let onRevealInFinder: () -> Void
    let onCopyPath: () -> Void
    let onCopyFolderPath: () -> Void
    let onCopySourceURL: () -> Void
    let onToggleStar: () -> Void
    let onAddTag: () -> Void
    let onAddToBoard: () -> Void  // Add items to a collection board
    let onAddToCanvas: () -> Void  // Issue #1: Add items to canvas
    let onOpenSource: () -> Void
    let onDelete: () -> Void
    let onFindSimilarColors: () -> Void  // Set color filters to match this item's palette
    let onExportWithMetadata: () -> Void  // Export with EXIF/IPTC metadata injection
    let onAddToRediscover: () -> Void  // Add items to FSRS Rediscover queue
    let onCombineItems: (() -> Void)?  // Merge selected items into the clicked item
    var transferContext: MediaActionContext? = nil
}

// MARK: - Video Hover Preview

enum VideoHoverPreviewBackend: Equatable {
    case avPlayer
    case webKit
}

struct VideoHoverSeekPlan: Equatable {
    let fraction: Double
    let time: Double
}

/// Pure routing and scrubbing decisions shared by the SwiftUI hover previews and tests.
enum VideoHoverPreviewPolicy {
    static func backend(for url: URL) -> VideoHoverPreviewBackend {
        url.pathExtension.lowercased() == "webm" ? .webKit : .avPlayer
    }

    static func seekPlan(
        scrubFraction: Double,
        duration: Double,
        isPlaying: Bool,
        lastSeekedFraction: Double?
    ) -> VideoHoverSeekPlan? {
        guard !isPlaying,
              scrubFraction.isFinite,
              duration.isFinite,
              duration > 0 else { return nil }

        let fraction = min(max(scrubFraction, 0), 1)
        if let lastSeekedFraction,
           lastSeekedFraction.isFinite,
           abs(fraction - lastSeekedFraction) <= 0.005 {
            return nil
        }

        return VideoHoverSeekPlan(
            fraction: fraction,
            time: duration * fraction
        )
    }
}

/// Keeps hover-delay work out of SwiftUI state. Continuous hover can deliver hundreds of moves
/// per second; retaining one cancellable task here avoids both a task backlog and body invalidation
/// from writing timer bookkeeping into every cell.
@MainActor
final class VideoHoverAutoplayCoordinator {
    private var scheduledTask: Task<Void, Never>?

    var hasScheduledTask: Bool { scheduledTask != nil }

    func schedule(after delay: Duration = .milliseconds(800), action: @escaping @MainActor () -> Void) {
        scheduledTask?.cancel()
        scheduledTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.scheduledTask = nil
            action()
        }
    }

    func cancel() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }
}

/// AVPlayerLayer wrapper for hover scrub + autoplay.
/// Scrub: seeks player to fraction, paused, showing that frame.
/// Play: plays from current position (where scrub left off).
/// Player is disconnected from layer until first seek lands (no frame 0 flash).
struct VideoHoverPreview: NSViewRepresentable {
    let url: URL
    /// 0-1 scrub position. Changes trigger seek (paused).
    var scrubFraction: Double = 0
    /// When true, plays from current position instead of scrubbing.
    var isPlaying: Bool = false
    var onReady: (() -> Void)?

    func makeNSView(context: Context) -> VideoHoverNSView {
        let view = VideoHoverNSView()
        context.coordinator.hostView = view
        return view
    }

    func updateNSView(_ nsView: VideoHoverNSView, context: Context) {
        let coord = context.coordinator
        coord.onReady = onReady

        // Create player once
        if coord.player == nil {
            let player = AVPlayer(url: url)
            player.isMuted = true
            player.actionAtItemEnd = .none
            NotificationCenter.default.addObserver(
                coord,
                selector: #selector(Coordinator.playerDidFinish(_:)),
                name: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem
            )
            coord.player = player
            // playerLayer.player stays nil until first seek lands
        }

        if isPlaying {
            if !coord.isCurrentlyPlaying {
                // Play from wherever scrub left us
                coord.isCurrentlyPlaying = true
                if !coord.isConnected {
                    nsView.playerLayer.player = coord.player
                    coord.isConnected = true
                    onReady?()
                }
                coord.player?.play()
            }
        } else {
            // Scrub mode: pause and seek to fraction
            if coord.isCurrentlyPlaying {
                coord.player?.pause()
                coord.isCurrentlyPlaying = false
            }
            coord.seekTo(fraction: scrubFraction)
        }
    }

    static func dismantleNSView(_ nsView: VideoHoverNSView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class VideoHoverNSView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }

    class Coordinator: NSObject {
        var player: AVPlayer?
        weak var hostView: VideoHoverNSView?
        var isCurrentlyPlaying = false
        var isConnected = false  // player assigned to layer
        var onReady: (() -> Void)?
        private var lastRequestedFraction: Double = -1
        private var lastPerformedFraction: Double = -1
        private var pendingSeekFraction: Double?
        private var cachedDuration: Double?
        private var durationLoadTask: Task<Void, Never>?

        func seekTo(fraction: Double) {
            let clampedFraction = min(max(fraction, 0), 1)
            guard abs(clampedFraction - lastRequestedFraction) > 0.005 else { return }
            lastRequestedFraction = clampedFraction
            pendingSeekFraction = clampedFraction

            guard let player = player, let item = player.currentItem else { return }

            if let dur = cachedDuration, dur > 0 {
                performSeek(fraction: clampedFraction, duration: dur)
                return
            }

            // Coalesce all pointer movement while duration is loading into the latest fraction.
            guard durationLoadTask == nil else { return }
            durationLoadTask = Task { [weak self, item] in
                do {
                    let duration = try await item.asset.load(.duration)
                    if duration.seconds > 0,
                       duration.seconds.isFinite,
                       !Task.isCancelled {
                        await self?.cacheDurationAndSeek(duration.seconds)
                    }
                } catch {
                    // Hover preview can fail for corrupt or unsupported video files; keep the cell inert.
                }
                await self?.clearDurationLoadTask()
            }
        }

        @MainActor
        private func cacheDurationAndSeek(_ duration: Double) {
            cachedDuration = duration
            if let pendingSeekFraction {
                performSeek(fraction: pendingSeekFraction, duration: duration)
            }
        }

        @MainActor
        private func clearDurationLoadTask() {
            durationLoadTask = nil
        }

        private func performSeek(fraction: Double, duration: Double) {
            guard abs(fraction - lastPerformedFraction) > 0.005,
                  let player else { return }
            lastPerformedFraction = fraction
            pendingSeekFraction = nil

            // A continuous hover should have one useful pending seek, not a queue of stale frames.
            player.currentItem?.cancelPendingSeeks()
            let seekTime = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                DispatchQueue.main.async {
                    guard finished, let self, self.player != nil else { return }
                    if !self.isConnected {
                        self.hostView?.playerLayer.player = self.player
                        self.isConnected = true
                        self.onReady?()
                    }
                }
            }
        }

        @objc func playerDidFinish(_ notification: Notification) {
            player?.seek(to: .zero)
            player?.play()
        }

        func cleanup() {
            durationLoadTask?.cancel()
            durationLoadTask = nil
            player?.currentItem?.cancelPendingSeeks()
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            hostView?.playerLayer.player = nil
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
            player = nil
            isCurrentlyPlaying = false
            isConnected = false
            pendingSeekFraction = nil
        }
    }
}

/// Routes formats AVFoundation cannot reliably decode through the app's built-in WebKit player.
private struct MasonryVideoHoverPreview: View {
    let url: URL
    let scrubFraction: Double
    @Binding var isPlaying: Bool
    var onReady: (() -> Void)?

    @ViewBuilder
    var body: some View {
        switch VideoHoverPreviewPolicy.backend(for: url) {
        case .avPlayer:
            VideoHoverPreview(
                url: url,
                scrubFraction: scrubFraction,
                isPlaying: isPlaying,
                onReady: onReady
            )
        case .webKit:
            WebMVideoHoverPreview(
                url: url,
                scrubFraction: scrubFraction,
                isPlaying: $isPlaying,
                onReady: onReady
            )
        }
    }
}

/// Adapts the full WebM transport to the grid's fraction-based, always-muted hover behavior.
private struct WebMVideoHoverPreview: View {
    let url: URL
    let scrubFraction: Double
    @Binding var isPlaying: Bool
    var onReady: (() -> Void)?

    @State private var playbackRate: Float = 1
    @State private var isMuted = true
    @State private var volume: Float = 0
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var seekRequest: VideoSeekRequest?
    @State private var lastSeekedFraction: Double?
    @State private var isReady = false

    var body: some View {
        WebMVideoPlayerView(
            url: url,
            isPlaying: $isPlaying,
            playbackRate: $playbackRate,
            isMuted: $isMuted,
            volume: $volume,
            currentTime: $currentTime,
            duration: $duration,
            seekRequest: $seekRequest,
            showsNativeControls: false,
            autoplayOverride: false,
            loopOverride: true,
            scaleMode: .fill
        )
        .opacity(isReady ? 1 : 0)
        .onAppear {
            updateScrubPosition()
            signalReadyIfPossible()
        }
        .onChange(of: scrubFraction) { _, _ in
            updateScrubPosition()
        }
        .onChange(of: isPlaying) { _, playing in
            if !playing {
                updateScrubPosition()
            }
        }
        .onChange(of: duration) { _, _ in
            updateScrubPosition()
            signalReadyIfPossible()
        }
    }

    private func updateScrubPosition() {
        guard let plan = VideoHoverPreviewPolicy.seekPlan(
            scrubFraction: scrubFraction,
            duration: duration,
            isPlaying: isPlaying,
            lastSeekedFraction: lastSeekedFraction
        ) else { return }

        lastSeekedFraction = plan.fraction
        seekRequest = VideoSeekRequest(sourceURL: url, time: plan.time)
    }

    private func signalReadyIfPossible() {
        guard !isReady, duration.isFinite, duration > 0 else { return }
        isReady = true
        onReady?()
    }
}

// MARK: - MasonryCell

#if DEBUG
@MainActor
enum MasonryCellDiagnostics {
    static var onBody: ((UUID) -> Void)?
    static var onGeometry: ((String) -> Void)?
    static var onPresentation: ((UUID, CGSize, Int?, CGFloat) -> Void)?
    static var onHoverHandler: ((UUID, @escaping (HoverPhase) -> Void) -> Void)?
}
#endif

enum MasonryPresentationPolicy {
    static func isPresentingContext(_ item: MediaItem) -> Bool {
        item.effectiveDisplaySource == .context
    }

    /// Mixed-role records store the media file's aspect ratio. Reading context
    /// dimensions in `body` would put synchronous ImageIO on the scroll path, so
    /// use a neutral tile and fit the entire context screenshot within it.
    static func layoutAspectRatio(for item: MediaItem) -> CGFloat {
        if isPresentingContext(item), !item.mediaFiles.isEmpty { return 1 }
        return item.effectiveAspectRatio
    }
}

/// Individual cell in the masonry grid displaying a media thumbnail
/// with selection state, star indicator, multi-media badge, and optional color bar.
/// Conforms to Equatable to prevent O(n) view diffing when selection changes.
struct MasonryCell: View, Equatable {
    @Environment(SettingsStore.self) private var settings

    let item: MediaItem
    // Column size comes from the grid; justified rows use their layout proposal.
    var tileSize: CGSize? = nil
    let isSelected: Bool
    let isMultiSelectMode: Bool
    let showColorBar: Bool  // Toggle for color bar display
    let selectedIDs: Set<UUID>  // Snapshot fallback for previews and isolated callers
    var selectedIDsProvider: (() -> Set<UUID>)? = nil
    var orderedDragItemsProvider: (() -> [MediaItem])? = nil
    let onSelect: () -> Void
    let onToggleSelect: () -> Void  // Cmd+click
    let onExtendSelect: () -> Void  // Shift+click
    let onDoubleClick: () -> Void
    let onShowContextMenu: ((CGPoint) -> Void)?
    /// Callback when a color bar segment is clicked - triggers precision color search
    var onColorClicked: ((ColorSearchRGB) -> Void)? = nil

    // Hover state for visual feedback
    @State private var isHovered: Bool = false

    // Video hover: real-time scrub via AVPlayer seek, autoplay on mouse stop
    @State private var scrubFraction: CGFloat = 0
    @State private var isPlayingVideo: Bool = false
    @State private var videoLayerReady: Bool = false
    @State private var hoverAutoplay = VideoHoverAutoplayCoordinator()
    @State private var activeCarouselSlot: Int? = nil

    // Selection border width
    private let selectionBorderWidth: CGFloat = 3

    // Color bar height
    private let colorBarHeight: CGFloat = 4

    // MARK: - Accessibility

    /// Generates a descriptive label for VoiceOver
    private var accessibilityLabel: String {
        var parts: [String] = []

        // Platform and author
        let platform = LibraryFilterPresentation.platformName(item.metadata.platform)
        if let author = item.metadata.author {
            parts.append("\(platform) post by \(author)")
        } else {
            parts.append("\(platform) media")
        }

        // Star status
        if item.metadata.starred {
            parts.append("starred")
        }

        // Multi-media indicator
        if item.mediaFiles.count > 1 {
            parts.append("\(item.mediaFiles.count) images")
        }

        if item.hasSwappablePresentationSources {
            let source = item.effectiveDisplaySource == .context ? "context image" : "downloaded image"
            parts.append("showing \(source)")
        }

        // Selection state in multi-select mode
        if isMultiSelectMode {
            if isSelected {
                parts.append("selected")
            } else {
                parts.append("not selected")
            }
        }

        return parts.joined(separator: ", ")
    }

    // MARK: - Equatable (compare only render-affecting state, not closures)
    //
    // PERF NOTE: This == is called O(n) times on EVERY selection change.
    // We MUST NOT compare selectedIDs here - it changes on every selection
    // and would invalidate ALL cells. Instead, we only check isSelected
    // which is derived from selectedIDs for THIS specific cell.

    static func == (lhs: MasonryCell, rhs: MasonryCell) -> Bool {
        // PERF: selectedIDs removed from comparison - it was causing O(n) rebuilds
        // The cell only needs to know if IT is selected, not all selected IDs
        lhs.item.id == rhs.item.id &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isMultiSelectMode == rhs.isMultiSelectMode &&
        lhs.showColorBar == rhs.showColorBar &&
        lhs.tileSize == rhs.tileSize &&
        lhs.item.metadata.starred == rhs.item.metadata.starred &&
        lhs.item.mediaFiles == rhs.item.mediaFiles &&
        lhs.item.contextImage == rhs.item.contextImage &&
        MasonryPresentationPolicy.layoutAspectRatio(for: lhs.item) == MasonryPresentationPolicy.layoutAspectRatio(for: rhs.item) &&
        lhs.item.metadata.platform == rhs.item.metadata.platform &&
        lhs.item.metadata.author == rhs.item.metadata.author &&
        lhs.item.indexedContent?.dominantColors == rhs.item.indexedContent?.dominantColors &&
        lhs.item.effectiveDisplaySource == rhs.item.effectiveDisplaySource &&
        lhs.item.thumbnailSource?.standardizedFileURL.path == rhs.item.thumbnailSource?.standardizedFileURL.path
    }

    // MARK: - Performance Logging
    private static let cellLog = OSLog(subsystem: "com.nodraw.app", category: "CellRebuild")

    static func setGlobalRightClickInterceptionEnabled(_ enabled: Bool) {
        GridRightClickInterceptionGate.isEnabled = enabled
    }

    @ViewBuilder
    var body: some View {
        #if DEBUG
        let _ = MasonryCellDiagnostics.onBody?(item.id)
        #endif
        // PERF: Log cell body evaluations to detect excessive rebuilds
        // In Instruments, look for "CellRebuild" category
        let _ = os_signpost(.event, log: Self.cellLog, name: "CellBody", "%{public}s", item.id.uuidString.prefix(8).description)

        if let tileSize {
            tileBody(size: tileSize)
        } else {
            // Justified rows receive their size from Layout's proposal. Read it
            // directly, without an appearance-time state write or a second body.
            GeometryReader { geometry in
                #if DEBUG
                let _ = MasonryCellDiagnostics.onGeometry?("layout-proposal")
                #endif
                tileBody(size: geometry.size)
            }
        }
    }

    private func tileBody(size cellSize: CGSize) -> some View {
        #if DEBUG
        let _ = MasonryCellDiagnostics.onPresentation?(item.id, cellSize, activeCarouselSlot, scrubFraction)
        #endif
        // Two ranges for aspect ratio handling:
        // - Layout clamp (cell shape): 0.4-2.5 - what the cell actually becomes
        // - Normal range (no blur needed): 0.5-2.0 - images here use .fill
        // Images outside normal range get blur-fill to preserve content
        let layoutClamp: ClosedRange<CGFloat> = 0.4...2.5
        let normalRange: ClosedRange<CGFloat> = 0.5...2.0

        let rawRatio = MasonryPresentationPolicy.layoutAspectRatio(for: item)
        let clampedAspectRatio = min(max(rawRatio, layoutClamp.lowerBound), layoutClamp.upperBound)
        let needsBlurFill = !normalRange.contains(rawRatio)

        // Context-only items (Twitter screenshots without media) should always show
        // full content so text is readable - force blur-fill mode
        let isContextPresentation = isPresentingContext

        // Split into intermediate `let` to help the type-checker
        let base = cellContent(
            clampedAspectRatio: clampedAspectRatio,
            needsBlurFill: needsBlurFill,
            isContextPresentation: isContextPresentation,
            cellSize: cellSize
        )
        // CRITICAL: Communicate ideal size to DensePackingLayout
        .frame(idealWidth: 100 * clampedAspectRatio, idealHeight: 100)
        .onAppear {
            if cellSize.width > 0 && cellSize.height > 0 { StartupMetrics.mark("first_viewport_cell") }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.clear,
                    lineWidth: selectionBorderWidth
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(isHovered && !isSelected ? 0.08 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(isSelected && isMultiSelectMode ? 0.15 : 0))
        )
        .contentShape(Rectangle())

        let hoverModifier = CellHoverModifier(
            hasVideo: item.hasVideo && !isContextPresentation,
            videoHoverPreviewEnabled: settings.videoHoverPreview,
            hasCarouselPreview: supportsCarouselTilePreview,
            carouselSlotCount: carouselPreviewURLs.count,
            isHovered: $isHovered,
            isPlayingVideo: $isPlayingVideo,
            videoLayerReady: $videoLayerReady,
            scrubFraction: $scrubFraction,
            hoverAutoplay: hoverAutoplay,
            cellWidth: cellSize.width,
            activeCarouselSlot: $activeCarouselSlot,
            cellSize: cellSize
        )
        #if DEBUG
        let _ = MasonryCellDiagnostics.onHoverHandler?(item.id, hoverModifier.handleHover)
        #endif

        return base
            .modifier(hoverModifier)
            .onDisappear {
                hoverAutoplay.cancel()
                isHovered = false
                isPlayingVideo = false
                videoLayerReady = false
                activeCarouselSlot = nil
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("grid-item-\(item.id.uuidString)")
            .accessibilityHint("Double-click to view full size. Right-click for options.")
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
            // The button trait promises an action: pressing opens the item like a double-click.
            .accessibilityAction { onDoubleClick() }
            .accessibilityAction(named: "Select") { onSelect() }
            .mediaFileDrag(enabled: { GridRightClickInterceptionGate.isEnabled }, onRightClick: { position in
                let liveSelection = currentSelectedIDs
                if MasonryContextSelectionPolicy.targetIDs(clickedID: item.id, selectedIDs: liveSelection) != liveSelection {
                    onSelect()
                }
                onShowContextMenu?(position)
            }) {
                let targets = orderedDragItemsProvider?() ?? [item]
                return try MediaTransferResolver.resolve(items: targets)
            }
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded { _ in onDoubleClick() }
            )
            .simultaneousGesture(
                TapGesture(count: 1)
                    .onEnded { _ in
                        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                        if flags.contains(.command) {
                            onToggleSelect()
                        } else if flags.contains(.shift) {
                            onExtendSelect()
                        } else {
                            onSelect()
                        }
                    }
            )
    }

    // MARK: - Cell Content (extracted for type-checker performance)

    @ViewBuilder
    private func cellContent(
        clampedAspectRatio: CGFloat,
        needsBlurFill: Bool,
        isContextPresentation: Bool,
        cellSize: CGSize
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            // Thumbnail with conditional blur background for extreme ratios or context-only
            if supportsCarouselTilePreview && !isContextPresentation {
                carouselThumbnailView(cellSize: cellSize)
                    .aspectRatio(clampedAspectRatio, contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else if needsBlurFill || isContextPresentation {
                BlurFillImageView(item: item, size: .small, displaySize: cellSize)
                    .aspectRatio(clampedAspectRatio, contentMode: .fit)
            } else {
                thumbnailView(cellSize: cellSize)
                    .aspectRatio(clampedAspectRatio, contentMode: .fill)
            }

            if supportsCarouselTilePreview && isHovered {
                CarouselQuadrantGuide(
                    activeSlot: activeCarouselSlot,
                    slotCount: carouselPreviewURLs.count,
                    tileSize: cellSize
                )
                    .allowsHitTesting(false)
            }

            // Overlay badges
            VStack(alignment: .trailing, spacing: 4) {
                if item.metadata.starred {
                    starBadge
                }
                if let ext = fileExtensionBadge {
                    Text(ext)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(3)
                }
                Spacer()
                if item.mediaFiles.count > 1 {
                    multiMediaBadge
                }
            }
            .padding(6)

            // Video hover: real-time scrub through the format-appropriate player.
            if item.hasVideo && !isContextPresentation && isHovered && settings.videoHoverPreview,
               let primaryMedia = item.primaryVideoMedia {
                MasonryVideoHoverPreview(
                    url: primaryMedia,
                    scrubFraction: scrubFraction,
                    isPlaying: $isPlayingVideo,
                    onReady: { videoLayerReady = true }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .allowsHitTesting(false)

                if videoLayerReady && !isPlayingVideo {
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.black.opacity(0.3))
                                .frame(height: 3)
                            Rectangle()
                                .fill(Color.white.opacity(0.8))
                                .frame(width: cellSize.width * scrubFraction, height: 3)
                        }
                    }
                }
            }

            if isMultiSelectMode {
                checkboxOverlay
            }

            if showColorBar, let colors = item.indexedContent?.dominantColors, !colors.isEmpty {
                VStack {
                    Spacer()
                    ColorBar(colors: colors, height: colorBarHeight, onColorClicked: onColorClicked)
                }
            }
        }
    }

    // MARK: - Drag Support

    /// Event handlers read the stable selection store lazily. This keeps `.equatable()` cells
    /// correct without passing a changing O(n)-fanout Set through every cell construction.
    private var currentSelectedIDs: Set<UUID> {
        selectedIDsProvider?() ?? selectedIDs
    }

    /// Preview shown during drag
    @ViewBuilder
    private var dragPreview: some View {
        let liveSelectedIDs = currentSelectedIDs
        if isSelected && liveSelectedIDs.count > 1 {
            // Multi-select preview with count badge
            ZStack(alignment: .topTrailing) {
                thumbnailPreview
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("\(liveSelectedIDs.count)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .offset(x: 8, y: -8)
            }
        } else {
            // Single item preview
            thumbnailPreview
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Simple thumbnail for drag preview
    @ViewBuilder
    private var thumbnailPreview: some View {
        if item.thumbnailSource != nil {
            CachedImageView(item: item, size: .small, contentMode: .fill)
        } else {
            Rectangle()
                .fill(Color(hex: 0x333333))
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                )
        }
    }

    // MARK: - Checkbox Overlay

    private var checkboxOverlay: some View {
        VStack {
            HStack {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.accentColor : Color.black.opacity(0.5))
                        .frame(width: 22, height: 22)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.6), lineWidth: 2)
                            .frame(width: 18, height: 18)
                    }
                }
                .padding(8)

                Spacer()
            }
            Spacer()
        }
        .accessibilityHidden(true) // Selection state is in cell's main label
    }

    // MARK: - Subviews

    private var supportsCarouselTilePreview: Bool {
        !isPresentingContext && !item.hasVideo && item.mediaFiles.count > 1
    }

    private var isPresentingContext: Bool {
        MasonryPresentationPolicy.isPresentingContext(item)
    }

    private var carouselPreviewURLs: [URL] {
        Array(item.mediaFiles.prefix(4))
    }

    private var activeCarouselURL: URL? {
        guard let slot = activeCarouselSlot,
              !carouselPreviewURLs.isEmpty else { return nil }
        let clampedSlot = min(max(0, slot), carouselPreviewURLs.count - 1)
        return carouselPreviewURLs[clampedSlot]
    }

    @ViewBuilder
    private func carouselThumbnailView(cellSize: CGSize) -> some View {
        if let activeURL = activeCarouselURL {
            URLThumbnailView(url: activeURL, size: .small, tileSize: cellSize, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            CarouselMosaicPreview(urls: carouselPreviewURLs, tileSize: cellSize)
        }
    }

    @ViewBuilder
    private func thumbnailView(cellSize: CGSize) -> some View {
        if item.thumbnailSource != nil {
            // Use .fill - cell is already sized correctly by DensePackingLayout based on aspect ratio
            CachedImageView(item: item, size: .small, contentMode: .fill, displaySize: cellSize)
        } else {
            // Placeholder for items without media or context image
            Rectangle()
                .fill(Color(hex: 0x333333))
                .overlay(
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.secondary)
                )
        }
    }

    private var starBadge: some View {
        Image(systemName: "star.fill")
            .font(.caption)
            .foregroundStyle(Color.accentOrange)
            .padding(4)
            .background(
                Circle()
                    .fill(Color.black.opacity(0.6))
            )
            .accessibilityHidden(true) // Info included in cell's main label
    }

    /// File extension badge — show for all files
    private var fileExtensionBadge: String? {
        guard let displaySource = item.thumbnailSource else { return nil }
        let ext = displaySource.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return ext.uppercased()
    }

    private var multiMediaBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.caption2)
            Text("\(item.mediaFiles.count)")
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.6))
        )
        .accessibilityHidden(true) // Info included in cell's main label
    }
}

// MARK: - Carousel Tile Preview

/// Lightweight URL-based thumbnail view for per-slot carousel previews.
/// Uses the app-wide bounded/coalescing loader so a mosaic cannot create an
/// unbounded detached decode task for every slot while scrolling.
private struct URLThumbnailView: View {
    let url: URL
    let size: ThumbnailGenerator.Size
    let tileSize: CGSize
    var contentMode: ContentMode = .fill

    /// When fill would crop too much due to aspect mismatch, fall back to fit.
    private static let severeAspectMismatchThreshold: CGFloat = 1.55

    @State private var image: NSImage?
    @State private var hasFailed = false
    @State private var releaseTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let image = image {
                let resolvedMode = resolvedContentMode(
                    imageSize: image.size,
                    containerSize: tileSize
                )

                if contentMode == .fill && resolvedMode == .fit {
                    // Keep tile continuity with a subtle background fill, but
                    // render the foreground image uncropped when mismatch is severe.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .saturation(0.55)
                        .brightness(-0.25)

                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: resolvedMode)
                }
            } else if hasFailed {
                Rectangle()
                    .fill(Color.gray.opacity(0.12))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    )
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
            }
        }
        .frame(width: tileSize.width, height: tileSize.height)
        .clipped()
        .task(id: "\(url.path)#\(size.rawValue)") {
            cancelScheduledRelease()
            await loadThumbnail()
        }
        .onAppear {
            cancelScheduledRelease()
        }
        .onDisappear {
            scheduleImageRelease()
        }
    }

    private func resolvedContentMode(imageSize: CGSize, containerSize: CGSize) -> ContentMode {
        guard contentMode == .fill else { return contentMode }
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return contentMode
        }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height
        let mismatch = max(imageAspect / containerAspect, containerAspect / imageAspect)

        return mismatch >= Self.severeAspectMismatchThreshold ? .fit : .fill
    }

    private func loadThumbnail() async {
        image = nil
        hasFailed = false
        let generated = await ImageCache.shared.loadThumbnail(from: url, size: size)

        guard !Task.isCancelled else { return }

        if let generated = generated {
            image = generated
            hasFailed = false
        } else {
            hasFailed = true
        }
    }

    private func cancelScheduledRelease() {
        releaseTask?.cancel()
        releaseTask = nil
    }

    private func scheduleImageRelease() {
        releaseTask?.cancel()
        releaseTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            image = nil
            hasFailed = false
            releaseTask = nil
        }
    }

}

/// Compact 2x2 preview mosaic for carousel posts in the library grid.
private struct CarouselMosaicPreview: View {
    let urls: [URL]
    let tileSize: CGSize
    private let slotSpacing: CGFloat = 1

    var body: some View {
        Group {
            switch urls.count {
            case 0:
                Color.black.opacity(0.25)
            case 1:
                slotView(0, width: tileSize.width, height: tileSize.height)
            case 2:
                let slotWidth = max(0, (tileSize.width - slotSpacing) / 2)
                HStack(spacing: slotSpacing) {
                    slotView(0, width: slotWidth, height: tileSize.height)
                    slotView(1, width: slotWidth, height: tileSize.height)
                }
            case 3:
                let slotWidth = max(0, (tileSize.width - slotSpacing) / 2)
                let slotHeight = max(0, (tileSize.height - slotSpacing) / 2)
                VStack(spacing: slotSpacing) {
                    HStack(spacing: slotSpacing) {
                        slotView(0, width: slotWidth, height: slotHeight)
                        slotView(1, width: slotWidth, height: slotHeight)
                    }
                    slotView(2, width: tileSize.width, height: slotHeight)
                }
            default:
                let slotWidth = max(0, (tileSize.width - slotSpacing) / 2)
                let slotHeight = max(0, (tileSize.height - slotSpacing) / 2)
                VStack(spacing: slotSpacing) {
                    HStack(spacing: slotSpacing) {
                        slotView(0, width: slotWidth, height: slotHeight)
                        slotView(1, width: slotWidth, height: slotHeight)
                    }
                    HStack(spacing: slotSpacing) {
                        slotView(2, width: slotWidth, height: slotHeight)
                        slotView(3, width: slotWidth, height: slotHeight)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func slotView(_ index: Int, width: CGFloat, height: CGFloat) -> some View {
        if index < urls.count {
            URLThumbnailView(url: urls[index], size: .small, tileSize: CGSize(width: width, height: height), contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()
        } else {
            Rectangle()
                .fill(Color.black.opacity(0.25))
                .frame(width: width, height: height)
        }
    }
}

/// Hover guide showing the 2x2 slot map used for carousel in-place preview.
private struct CarouselQuadrantGuide: View {
    let activeSlot: Int?
    let slotCount: Int
    let tileSize: CGSize

    var body: some View {
        ZStack {
            if slotCount <= 1 {
                if activeSlot != nil {
                    Rectangle()
                        .fill(Color.white.opacity(0.09))
                }
            } else if slotCount == 2 {
                let halfWidth = tileSize.width / 2
                if let activeSlot = activeSlot {
                    Rectangle()
                        .fill(Color.white.opacity(0.09))
                        .frame(width: halfWidth, height: tileSize.height)
                        .offset(x: activeSlot == 0 ? -halfWidth / 2 : halfWidth / 2)
                }

                Path { path in
                    let midX = tileSize.width / 2
                    path.move(to: CGPoint(x: midX, y: 0))
                    path.addLine(to: CGPoint(x: midX, y: tileSize.height))
                }
                .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
            } else if slotCount == 3 {
                let halfWidth = tileSize.width / 2
                let halfHeight = tileSize.height / 2
                if let activeSlot = activeSlot {
                    switch activeSlot {
                    case 0:
                        Rectangle()
                            .fill(Color.white.opacity(0.09))
                            .frame(width: halfWidth, height: halfHeight)
                            .offset(x: -halfWidth / 2, y: -halfHeight / 2)
                    case 1:
                        Rectangle()
                            .fill(Color.white.opacity(0.09))
                            .frame(width: halfWidth, height: halfHeight)
                            .offset(x: halfWidth / 2, y: -halfHeight / 2)
                    default:
                        Rectangle()
                            .fill(Color.white.opacity(0.09))
                            .frame(width: tileSize.width, height: halfHeight)
                            .offset(y: halfHeight / 2)
                    }
                }

                Path { path in
                    let midX = tileSize.width / 2
                    let midY = tileSize.height / 2
                    path.move(to: CGPoint(x: midX, y: 0))
                    path.addLine(to: CGPoint(x: midX, y: midY))
                    path.move(to: CGPoint(x: 0, y: midY))
                    path.addLine(to: CGPoint(x: tileSize.width, y: midY))
                }
                .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
            } else {
                let halfWidth = tileSize.width / 2
                let halfHeight = tileSize.height / 2
                if let activeSlot = activeSlot {
                    Rectangle()
                        .fill(Color.white.opacity(0.09))
                        .frame(width: halfWidth, height: halfHeight)
                        .offset(
                            x: activeSlot % 2 == 0 ? -halfWidth / 2 : halfWidth / 2,
                            y: activeSlot / 2 == 0 ? -halfHeight / 2 : halfHeight / 2
                        )
                }

                Path { path in
                    let midX = tileSize.width / 2
                    let midY = tileSize.height / 2
                    path.move(to: CGPoint(x: midX, y: 0))
                    path.addLine(to: CGPoint(x: midX, y: tileSize.height))
                    path.move(to: CGPoint(x: 0, y: midY))
                    path.addLine(to: CGPoint(x: tileSize.width, y: midY))
                }
                .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
            }
        }
    }
}

// MARK: - ColorBar

/// A small horizontal bar showing dominant colors from Vision processing.
/// Colors are displayed proportionally (equal segments since we don't track percentages,
/// but ordered by dominance - first color is most dominant).
/// Uses muted ColorBucket.uiColor palette for subtle appearance.
/// Segments are clickable to trigger precision color search.
struct ColorBar: View {
    let colors: [ColorBucket]
    let height: CGFloat
    /// Callback when a color segment is clicked - passes the bucket's RGB as ColorSearchRGB
    var onColorClicked: ((ColorSearchRGB) -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, bucket in
                let rgb = bucket.uiColor
                let color = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
                Rectangle()
                    .fill(color)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Convert bucket's muted UI color to 0-255 RGB for precision search
                        let colorSearch = ColorSearchRGB(
                            r: Int(rgb.red * 255),
                            g: Int(rgb.green * 255),
                            b: Int(rgb.blue * 255),
                            tolerance: 30  // Slightly wider tolerance for bucket colors
                        )
                        onColorClicked?(colorSearch)
                    }
            }
        }
        .frame(height: height)
        .background(Color.black.opacity(0.3))
        // Rounded bottom corners only to match cell shape
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: 4,
                topTrailingRadius: 0
            )
        )
    }
}

// MARK: - Hover Modifier (extracted for type-checker)

/// Extracted from MasonryCell.body to reduce type-checker complexity.
/// PERF: Takes scalars (hasVideo, videoHoverPreviewEnabled) instead of
/// SettingsStore reference. Holding @Observable in a modifier bypasses
/// the parent's .equatable() guard — any settings mutation would fan out
/// to O(n) modifier body re-evals across all visible cells.
private struct CellHoverModifier: ViewModifier {
    let hasVideo: Bool
    let videoHoverPreviewEnabled: Bool
    let hasCarouselPreview: Bool
    let carouselSlotCount: Int
    @Binding var isHovered: Bool
    @Binding var isPlayingVideo: Bool
    @Binding var videoLayerReady: Bool
    @Binding var scrubFraction: CGFloat
    let hoverAutoplay: VideoHoverAutoplayCoordinator
    let cellWidth: CGFloat
    @Binding var activeCarouselSlot: Int?
    let cellSize: CGSize

    func body(content: Content) -> some View {
        content.onContinuousHover(perform: handleHover)
    }

    fileprivate func handleHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            if !isHovered { isHovered = true }
            if hasCarouselPreview {
                let slot = hoveredCarouselSlot(for: location)
                if activeCarouselSlot != slot {
                    activeCarouselSlot = slot
                }
            }
            if hasVideo && videoHoverPreviewEnabled {
                let width = max(1, cellWidth)
                let relativeX = max(0, min(1, location.x / width))
                if isPlayingVideo {
                    if abs(scrubFraction - relativeX) > 0.05 {
                        isPlayingVideo = false
                    }
                }
                if !isPlayingVideo {
                    // Only write state if the fraction actually changed enough
                    // to avoid per-frame SwiftUI body re-evals on hover
                    if abs(scrubFraction - relativeX) > 0.005 {
                        scrubFraction = relativeX
                    }
                }
                if !isPlayingVideo {
                    hoverAutoplay.schedule {
                        if isHovered, !isPlayingVideo {
                            isPlayingVideo = true
                        }
                    }
                }
            }
        case .ended:
            hoverAutoplay.cancel()
            isHovered = false
            isPlayingVideo = false
            videoLayerReady = false
            scrubFraction = 0
            activeCarouselSlot = nil
        }
    }


    private func hoveredCarouselSlot(for location: CGPoint) -> Int? {
        guard hasCarouselPreview, carouselSlotCount > 0 else { return nil }

        let width = max(1, cellSize.width)
        let height = max(1, cellSize.height)

        if carouselSlotCount == 1 {
            return 0
        }

        if carouselSlotCount == 2 {
            return location.x < width / 2 ? 0 : 1
        }

        if carouselSlotCount == 3 {
            if location.y < height / 2 {
                return location.x < width / 2 ? 0 : 1
            }
            return 2
        }

        let col = min(1, max(0, Int((location.x / width) * 2.0)))
        let row = min(1, max(0, Int((location.y / height) * 2.0)))
        return min(row * 2 + col, carouselSlotCount - 1)
    }
}

// MARK: - Preview

#if DEBUG
struct MasonryCell_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 8) {
            // Normal cell without color bar
            MasonryCell(
                item: .preview,
                isSelected: false,
                isMultiSelectMode: false,
                showColorBar: false,
                selectedIDs: [],
                onSelect: {},
                onToggleSelect: {},
                onExtendSelect: {},
                onDoubleClick: {},
                onShowContextMenu: { _ in }
            )
            .frame(width: 200)

            // Cell with color bar
            MasonryCell(
                item: .previewWithColors,
                isSelected: false,
                isMultiSelectMode: false,
                showColorBar: true,
                selectedIDs: [],
                onSelect: {},
                onToggleSelect: {},
                onExtendSelect: {},
                onDoubleClick: {},
                onShowContextMenu: { _ in }
            )
            .frame(width: 200)

            // Selected cell with color bar
            MasonryCell(
                item: .previewWithColors,
                isSelected: true,
                isMultiSelectMode: false,
                showColorBar: true,
                selectedIDs: [MediaItem.previewWithColors.id],
                onSelect: {},
                onToggleSelect: {},
                onExtendSelect: {},
                onDoubleClick: {},
                onShowContextMenu: { _ in }
            )
            .frame(width: 200)

            // Multi-select mode with color bar
            MasonryCell(
                item: .previewStarredMulti,
                isSelected: true,
                isMultiSelectMode: true,
                showColorBar: true,
                selectedIDs: [MediaItem.previewStarredMulti.id, UUID(), UUID()],
                onSelect: {},
                onToggleSelect: {},
                onExtendSelect: {},
                onDoubleClick: {},
                onShowContextMenu: { _ in }
            )
            .frame(width: 200)
        }
        .padding()
        .background(Color(hex: 0x1a1a1a))
    }
}

extension MediaItem {
    static var preview: MediaItem {
        MediaItem(
            id: UUID(),
            basePath: URL(fileURLWithPath: "/tmp"),
            metadataFile: URL(fileURLWithPath: "/tmp/test.md"),
            mediaFiles: [URL(fileURLWithPath: "/tmp/test.jpg")],
            contextImage: nil,
            metadata: MediaMetadata(
                source: URL(string: "https://twitter.com/test")!,
                platform: "twitter",
                author: "@test"
            ),
            indexedContent: nil,
            aspectRatio: 1.5
        )
    }

    static var previewWithColors: MediaItem {
        MediaItem(
            id: UUID(),
            basePath: URL(fileURLWithPath: "/tmp"),
            metadataFile: URL(fileURLWithPath: "/tmp/test-colors.md"),
            mediaFiles: [URL(fileURLWithPath: "/tmp/test-colors.jpg")],
            contextImage: nil,
            metadata: MediaMetadata(
                source: URL(string: "https://twitter.com/test")!,
                platform: "twitter",
                author: "@test"
            ),
            indexedContent: IndexedContent(
                dominantColors: [.blue, .cyan, .white]
            ),
            aspectRatio: 1.5
        )
    }

    static var previewStarredMulti: MediaItem {
        MediaItem(
            id: UUID(),
            basePath: URL(fileURLWithPath: "/tmp"),
            metadataFile: URL(fileURLWithPath: "/tmp/test2.md"),
            mediaFiles: [
                URL(fileURLWithPath: "/tmp/test1.jpg"),
                URL(fileURLWithPath: "/tmp/test2.jpg"),
                URL(fileURLWithPath: "/tmp/test3.jpg")
            ],
            contextImage: nil,
            metadata: MediaMetadata(
                source: URL(string: "https://twitter.com/test")!,
                platform: "twitter",
                author: "@test",
                starred: true
            ),
            indexedContent: IndexedContent(
                dominantColors: [.red, .orange, .yellow]
            ),
            aspectRatio: 0.75
        )
    }
}
#endif
