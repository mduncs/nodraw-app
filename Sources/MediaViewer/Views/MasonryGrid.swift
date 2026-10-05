import SwiftUI
import AppKit
import Combine
import os.signpost

// MARK: - MasonryGrid

/// Masonry grid with two layout modes:
/// - Column layout (default): Pinterest-style columns, good for mixed content
/// - Hybrid layout: Splits by aspect ratio - columns for tall, rows for wide
struct MasonryGrid: View, Equatable {
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var viewModel: MasonryGridViewModel
    let useHybridLayout: Bool
    let showColorBars: Bool
    /// When true, grid is hidden behind focus view - freeze all layout updates
    let isBackgrounded: Bool
    /// Same-window overlays can suspend viewport input without freezing the grid's layout.
    var allowsViewportInteraction: Bool = true
    let onItemSelected: (MediaItem) -> Void
    let onItemDoubleClicked: (MediaItem) -> Void
    let onShowContextMenu: ((MediaItem, CGPoint) -> Void)?
    let onLoadMore: (() async -> Void)?
    var libraryScrollRequest: LibraryScrollRequest = LibraryScrollRequest()
    /// Callback when a color bar segment is clicked - triggers precision color search
    var onColorClicked: ((ColorSearchRGB) -> Void)? = nil

    // Callbacks read the stable AppState/viewModel references and container state wrappers.
    // Their freshly constructed closure identities must not invalidate the loaded item tree.
    static func == (lhs: MasonryGrid, rhs: MasonryGrid) -> Bool {
        lhs.viewModel === rhs.viewModel &&
        lhs.useHybridLayout == rhs.useHybridLayout &&
        lhs.showColorBars == rhs.showColorBars &&
        lhs.isBackgrounded == rhs.isBackgrounded &&
        lhs.allowsViewportInteraction == rhs.allowsViewportInteraction &&
        lhs.libraryScrollRequest == rhs.libraryScrollRequest
    }

    // Estimated row height for prefetch calculations
    private var estimatedRowHeight: CGFloat { 200 + (viewModel.density * 150) }
    private var estimatedVisibleRows: Int { 10 }

    // Infinite scroll state
    @State private var isLoadingMore = false
    @State private var pendingLibraryScrollRequest: LibraryScrollRequest?

    // Scroll tasks and timestamps stay outside observable state. Only column ranges publish,
    // so display-cadence input does not invalidate the entire grid.
    @State private var scrollRuntime = MasonryGridScrollRuntime()

    // MARK: - Width Change Debouncing
    // Prevents layout thrashing during sidebar animation by COMPLETELY FREEZING
    // the grid at its pre-animation size until the animation completes.
    @State private var pendingWidth: CGFloat?
    @State private var widthDebounceTask: Task<Void, Never>?
    @State private var lastCommittedWidth: CGFloat = 0
    /// Latest GeometryReader width, tracked continuously for focus->library restore.
    @State private var latestMeasuredWidth: CGFloat = 0
    /// Cached column count - used directly in layout to prevent body re-diffing all children.
    /// Updated only when column count actually changes, not on every body call.
    @State private var lastCommittedColumns: Int = 5

    /// True while sidebar is animating - grid layout is completely frozen
    @State private var isAnimating = false
    /// Width to use during animation (frozen at start of animation)
    @State private var frozenWidth: CGFloat?
    /// True when this view has paused Vision queue for animation throttling.
    @State private var visionPausedForAnimation = false

    /// Width captured when entering focus mode - restored on exit to avoid toolbar-induced recalc.
    @State private var preFocusWidth: CGFloat?
    /// True while waiting for first reliable post-focus geometry width.
    @State private var isRestoringFromFocus = false

    /// Minimum width change (pixels) to detect animation start
    private let animationDetectionThreshold: CGFloat = 20
    /// Delay to wait for animation to complete (350ms > typical 250ms animation)
    private let animationSettleDelay: UInt64 = 350_000_000 // 350ms in nanoseconds
    /// Short settle window when returning from focus mode.
    private let focusReturnSettleDelay: UInt64 = 120_000_000 // 120ms in nanoseconds
    #if DEBUG
    static var bodyEvaluationObserver: (() -> Void)?
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.bodyEvaluationObserver?()
        #endif
        GeometryReader { geometry in
            // During animation OR when backgrounded (focus view showing), use frozen width
            // to prevent ANY layout updates. This avoids expensive relayout when user can't see the grid.
            let effectiveWidth = frozenWidth ?? geometry.size.width

            // USE CACHED COLUMN COUNT - not computed inline
            // This prevents SwiftUI from re-diffing all ForEach children on every body call.
            // lastCommittedColumns is only updated when column count ACTUALLY changes.
            let columns = lastCommittedColumns
            let _ = effectiveWidth  // Silence unused warning; width used implicitly via columns

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id("library-grid-top")

                        // Actual content
                        if useHybridLayout {
                            hybridLayout(columns: columns)
                        } else {
                            columnLayout(columns: columns, viewportHeight: geometry.size.height)
                        }

                        if viewModel.hasMoreItems {
                            Color.clear.frame(height: 1)
                        }

                        // Loading indicator
                        if isLoadingMore {
                            ProgressView()
                                .padding(.vertical, 20)
                        }
                    }
                }
                .overlay(MiddleMouseAutoScroll(
                    isEnabled: !isBackgrounded && allowsViewportInteraction,
                    onViewportInput: {
                        if scrollRuntime.pendingReveal?.preservePendingMotion != true {
                            scrollRuntime.pendingReveal = nil
                        }
                        pendingLibraryScrollRequest = nil
                    },
                    onScrollerResolved: { scrollRuntime.scroller = $0 },
                    onViewportWillChange: { scroll in
                        scrollRuntime.scrollView = scroll
                        if !isBackgrounded && !useHybridLayout {
                            scrollRuntime.updateColumnWindows(viewModel: viewModel,
                                offset: -scroll.contentView.bounds.minY, height: scroll.contentView.bounds.height)
                        }
                    },
                    onViewportChanged: { offset, height, contentBottom in
                        _ = applyPendingReveal()
                        if let request = pendingLibraryScrollRequest {
                            applyLibraryScrollRequest(request, using: scrollProxy)
                        }
                        let scroll = scrollRuntime.scrollView
                        let currentOffset = scroll.map { -$0.contentView.bounds.minY } ?? offset
                        let currentHeight = scroll?.contentView.bounds.height ?? height
                        let currentBottom = scroll?.documentView?.bounds.maxY ?? contentBottom
                        handleScrollOffset(currentOffset, viewportHeight: currentHeight)
                        loadMoreIfNeeded(offset: currentOffset, viewportHeight: currentHeight, contentBottom: currentBottom)
                    }
                ))
                .animation(nil, value: geometry.size.width)  // Disable animation on width changes
                .onAppear {
                    MasonryCell.setGlobalRightClickInterceptionEnabled(!isBackgrounded)
                    // Calculate initial column count and cache it
                    let initialColumns = calculateColumnCount(for: geometry.size.width)
                    latestMeasuredWidth = geometry.size.width
                    lastCommittedWidth = geometry.size.width
                    lastCommittedColumns = initialColumns
                    // CRITICAL: Pass the SAME column count to ViewModel that Layout uses
                    viewModel.setColumnCount(initialColumns)
                    // Subtract padding (applied to Layout) so ViewModel uses same width as Layout
                    viewModel.setContainerWidth(geometry.size.width - 2 * viewModel.spacing)
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    latestMeasuredWidth = newWidth
                    handleWidthChange(newWidth)
                }
                // Scroll to follow selection only for keyboard navigation (not mouse clicks)
                .onChange(of: viewModel.selectedIDs) { _, newIDs in
                    guard viewModel.shouldScrollToSelection else { return }
                    viewModel.shouldScrollToSelection = false
                    if let id = viewModel.selectionAnchor ?? newIDs.first {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            _ = revealItem(id, centered: true, animated: true, using: scrollProxy)
                        }
                    }
                }
                // Scroll to top when filter changes
                .onChange(of: viewModel.shouldScrollToTop) { _, shouldScroll in
                    guard shouldScroll else { return }
                    viewModel.shouldScrollToTop = false
                    if !viewModel.items.isEmpty {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            _ = revealTop(animated: true, using: scrollProxy)
                        }
                    }
                }
                .onChange(of: viewModel.scrollAnchorToRestore) { _, id in
                    guard let id else { return }
                    revealItem(id, centered: false, animated: false, preservePendingMotion: true, using: scrollProxy)
                    viewModel.scrollAnchorToRestore = nil
                }
                // Scroll to selected item when returning from focus view (triggered by Container)
                .onChange(of: viewModel.shouldScrollToSelectionOnFocusReturn) { _, shouldScroll in
                    guard shouldScroll else { return }
                    viewModel.shouldScrollToSelectionOnFocusReturn = false
                    if let selectedId = viewModel.selectedItemID {
                        revealItem(selectedId, centered: true, animated: false, using: scrollProxy)
                    }
                }
                .onChange(of: libraryScrollRequest) { _, request in
                    pendingLibraryScrollRequest = request
                    applyLibraryScrollRequest(request, using: scrollProxy)
                }
                .onChange(of: useHybridLayout) { _, _ in
                    scrollRuntime.pendingReveal = nil
                }
                .onChange(of: gridContentSignature) { _, _ in
                    guard let request = pendingLibraryScrollRequest else { return }
                    applyLibraryScrollRequest(request, using: scrollProxy)
                }
                // Density changed - recalculate column count (no animation)
                .onChange(of: viewModel.density) { _, _ in
                    // Use transaction to disable implicit animations during density change
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        let newColumns = calculateColumnCount(for: lastCommittedWidth)
                        if newColumns != lastCommittedColumns {
                            lastCommittedColumns = newColumns
                            viewModel.setColumnCount(newColumns)
                            viewModel.setContainerWidth(lastCommittedWidth - 2 * viewModel.spacing)
                        }
                    }
                }
                // Freeze layout when backgrounded (focus view showing)
                .onChange(of: isBackgrounded) { _, backgrounded in
                    MasonryCell.setGlobalRightClickInterceptionEnabled(!backgrounded)
                    if backgrounded {
                        // Entering background - capture and freeze current width
                        widthDebounceTask?.cancel()
                        isRestoringFromFocus = false
                        isAnimating = true
                        preFocusWidth = lastCommittedWidth
                        if frozenWidth == nil {
                            frozenWidth = lastCommittedWidth
                        }
                        // If we paused Vision for a pending resize animation, release it now.
                        // Focus view is active, so OCR/vision work should continue.
                        resumeVisionQueueIfNeeded()
                    } else {
                        // Exiting focus - keep frozen until we receive a reliable post-focus width.
                        widthDebounceTask?.cancel()
                        isRestoringFromFocus = true
                        isAnimating = true

                        // Fallback: if no width change arrives quickly, settle using latest measured width.
                        widthDebounceTask = Task { @MainActor in
                            do {
                                try await Task.sleep(nanoseconds: focusReturnSettleDelay)
                                guard !Task.isCancelled, isRestoringFromFocus else { return }
                                let restoredWidth = latestMeasuredWidth > 0
                                    ? latestMeasuredWidth
                                    : (preFocusWidth ?? lastCommittedWidth)
                                let restoredColumns = calculateColumnCount(for: restoredWidth)
                                commitWidthChange(restoredWidth, columns: restoredColumns)
                                isRestoringFromFocus = false
                                isAnimating = false
                                frozenWidth = nil
                                pendingWidth = nil
                                preFocusWidth = nil
                                resumeVisionQueueIfNeeded()
                            } catch {
                                // Cancelled by first real width update.
                            }
                        }
                        resumeVisionQueueIfNeeded()
                    }
                }
                .onDisappear {
                    MasonryCell.setGlobalRightClickInterceptionEnabled(true)
                    scrollRuntime.cancelPendingWork()
                    widthDebounceTask?.cancel()
                    // Safety net: never leave Vision queue paused because this view went away.
                    resumeVisionQueueIfNeeded()
                }
            }
            .transaction { transaction in
                // Disable animations on geometry changes to prevent cascading updates
                transaction.disablesAnimations = true
            }
        }
        // NOTE: Keyboard handling is done via KeyboardShortcutManager (app-wide NSEvent monitor)
        // No per-view keyboard capture needed - this avoids focus conflicts with sidebar
    }

    // MARK: - Scroll Tracking

    private var gridContentSignature: String {
        "\(viewModel.items.count):\(viewModel.items.first?.id.uuidString ?? "none"):" +
            (viewModel.items.last?.id.uuidString ?? "none")
    }

    private func applyLibraryScrollRequest(
        _ request: LibraryScrollRequest,
        using scrollProxy: ScrollViewProxy
    ) {
        switch request.target {
        case .top:
            guard revealTop(animated: false, using: scrollProxy) else { return }
            pendingLibraryScrollRequest = nil
        case .item(let id):
            guard viewModel.containsItem(id) else { return }
            guard revealItem(id, centered: true, animated: false, using: scrollProxy) else { return }
            pendingLibraryScrollRequest = nil
        }
    }

    @discardableResult
    private func revealItem(_ id: UUID, centered: Bool, animated: Bool,
                            preservePendingMotion: Bool = false, using proxy: ScrollViewProxy) -> Bool {
        if useHybridLayout {
            proxy.scrollTo(id, anchor: centered ? .center : .top)
            return true
        }
        scrollRuntime.pendingReveal = MasonryGridRevealRequest(id: id, centered: centered,
            animated: animated, preservePendingMotion: preservePendingMotion)
        return applyPendingReveal()
    }

    @discardableResult
    private func revealTop(animated: Bool, using proxy: ScrollViewProxy) -> Bool {
        if useHybridLayout {
            proxy.scrollTo("library-grid-top", anchor: .top)
            return true
        }
        scrollRuntime.pendingReveal = MasonryGridRevealRequest(id: nil, centered: false,
            animated: animated, preservePendingMotion: false)
        return applyPendingReveal()
    }

    private func applyPendingReveal() -> Bool {
        guard !isBackgrounded, !useHybridLayout,
              let request = scrollRuntime.pendingReveal,
              let scroll = scrollRuntime.scrollView, let document = scroll.documentView else { return false }
        let offset: CGFloat
        if let id = request.id {
            guard viewModel.containsItem(id) else {
                scrollRuntime.pendingReveal = nil
                return false
            }
            // Newly appended items can publish before the native document grows. Keep the
            // request until layout catches up rather than clamping it to the old bottom.
            let contentHeight = (viewModel.columnHeights.max() ?? 0) + 2 * viewModel.spacing
            guard document.bounds.height + 1 >= contentHeight,
                  let target = viewModel.revealOffset(for: id, centered: request.centered,
                    viewportHeight: scroll.contentView.bounds.height) else { return false }
            offset = target
        } else {
            offset = document.bounds.minY
        }
        scrollRuntime.pendingReveal = nil
        scrollRuntime.reveal(offset: offset, animated: request.animated, in: scroll,
            preservePendingMotion: request.preservePendingMotion)
        return true
    }

    private func handleScrollOffset(_ offset: CGFloat, viewportHeight: CGFloat) {
        guard !isBackgrounded else { return }
        viewModel.updateScrollPosition(offset: offset, viewportHeight: viewportHeight)
        scrollRuntime.schedulePrefetch {
            prefetchVisibleItems(scrollOffset: offset, viewportHeight: viewportHeight)
        }
    }

    private func loadMoreIfNeeded(offset: CGFloat, viewportHeight: CGFloat, contentBottom: CGFloat) {
        // Only upward travel permits a retry. A spinner changes the document height too.
        if let attemptedOffset = scrollRuntime.lastPaginationAttemptOffset, offset > attemptedOffset + 1 {
            scrollRuntime.lastPaginationAttempt = nil
        }
        guard !isBackgrounded, viewModel.hasMoreItems, !isLoadingMore,
              let onLoadMore, viewportHeight > 0,
              -offset + viewportHeight >= contentBottom - 1,
              scrollRuntime.lastPaginationAttempt != gridContentSignature else { return }
        scrollRuntime.lastPaginationAttempt = gridContentSignature
        scrollRuntime.lastPaginationAttemptOffset = offset
        isLoadingMore = true
        Task { @MainActor in
            await onLoadMore()
            isLoadingMore = false
        }
    }

    // MARK: - Prefetching

    private func prefetchVisibleItems(scrollOffset: CGFloat, viewportHeight: CGFloat) {
        let previousOffset = scrollRuntime.lastPrefetchScrollOffset
        scrollRuntime.lastPrefetchScrollOffset = scrollOffset
        let items: [MediaItem]
        if useHybridLayout {
            guard let window = MasonryGridPrefetchPolicy.window(
                itemCount: viewModel.items.count, scrollOffset: scrollOffset,
                previousScrollOffset: previousOffset, estimatedRowHeight: estimatedRowHeight,
                estimatedVisibleRows: estimatedVisibleRows, columnCount: viewModel.columnCount
            ) else { return }
            items = Array(viewModel.items[window.prefetchRange])
        } else {
            items = viewModel.thumbnailPrefetchItems(scrollOffset: scrollOffset,
                viewportHeight: viewportHeight, scrollingDown: scrollOffset < previousOffset)
        }
        let width = (viewModel.containerWidth - viewModel.spacing * CGFloat(viewModel.columnCount - 1))
            / CGFloat(max(1, viewModel.columnCount))
        let targets = items.map { item in
            let ratio = max(0.4, min(2.5, MasonryPresentationPolicy.layoutAspectRatio(for: item)))
            return MasonryGridThumbnailPrefetchTarget(item: item,
                displaySize: useHybridLayout ? nil : CGSize(width: width, height: width / ratio),
                displayScale: displayScale)
        }
        let signature = targets.map(\.identity)
        guard signature != scrollRuntime.lastPrefetchSignature else { return }
        scrollRuntime.lastPrefetchSignature = signature
        scrollRuntime.requestPrefetch(targets: targets, activeIDs: Set(items.map(\.id)))
    }

    // MARK: - Width Change Handling

    /// Handle width changes by COMPLETELY FREEZING during animation.
    /// When we detect rapid width changes (sidebar animating), freeze the grid at its
    /// current size and don't update ANYTHING until animation settles.
    private func handleWidthChange(_ newWidth: CGFloat) {
        let widthDelta = abs(newWidth - lastCommittedWidth)
        PerfLog.event("widthChange", category: .layout, context: "delta:\(String(format: "%.0f", widthDelta))px")

        // When backgrounded (focus mode), just track width and defer commits.
        if isBackgrounded {
            pendingWidth = newWidth
            return
        }

        // First width event after closing focus: commit once and unfreeze.
        if isRestoringFromFocus {
            widthDebounceTask?.cancel()
            let restoredColumns = calculateColumnCount(for: newWidth)
            commitWidthChange(newWidth, columns: restoredColumns)
            isRestoringFromFocus = false
            isAnimating = false
            frozenWidth = nil
            pendingWidth = nil
            preFocusWidth = nil
            resumeVisionQueueIfNeeded()
            return
        }

        // Cancel any pending settle task
        widthDebounceTask?.cancel()

        // Detect animation: significant width change indicates sidebar is animating
        if widthDelta > animationDetectionThreshold {
            // Freeze at the start of animation (first detection)
            if frozenWidth == nil {
                frozenWidth = lastCommittedWidth
                // Pause vision processing to reduce CPU competition during animation
                pauseVisionQueueForAnimationIfNeeded()
            }
            isAnimating = true

            // Wait for animation to settle, then snap to final size
            widthDebounceTask = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: animationSettleDelay)
                    // Animation done - unfreeze and commit final width
                    isAnimating = false
                    frozenWidth = nil
                    let finalColumns = calculateColumnCount(for: newWidth)
                    commitWidthChange(newWidth, columns: finalColumns)
                    // Resume vision processing after animation settles
                    resumeVisionQueueIfNeeded()
                } catch {
                    // Task cancelled - animation still ongoing
                }
            }
            return  // DON'T update anything during animation
        }

        // Small change while not animating - could be final adjustment after animation,
        // or just a minor resize. Wait briefly then commit.
        if !isAnimating && frozenWidth == nil {
            pendingWidth = newWidth
            widthDebounceTask = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)  // 100ms for small adjustments
                    if let pending = pendingWidth {
                        let finalColumns = calculateColumnCount(for: pending)
                        commitWidthChange(pending, columns: finalColumns)
                        pendingWidth = nil
                    }
                } catch {
                    // Cancelled
                }
            }
        }
        // If we're animating but width delta is small, just extend the settle timer
        // (already handled by the threshold check above)
    }

    private func pauseVisionQueueForAnimationIfNeeded() {
        guard !visionPausedForAnimation else { return }
        guard let visionQueue = VisionJobQueue.sharedIfConfigured else { return }
        visionPausedForAnimation = true
        Task { await visionQueue.pause() }
    }

    private func resumeVisionQueueIfNeeded() {
        guard visionPausedForAnimation else { return }
        guard let visionQueue = VisionJobQueue.sharedIfConfigured else { return }
        visionPausedForAnimation = false
        Task { await visionQueue.resume() }
    }

    /// Commit a width change to the ViewModel
    private func commitWidthChange(_ width: CGFloat, columns: Int) {
        PerfLog.measure("commitWidthChange", category: .layout, context: "\(viewModel.items.count) items, \(columns) cols") {
            lastCommittedWidth = width
            lastCommittedColumns = columns
            viewModel.setColumnCount(columns)
            viewModel.setContainerWidth(width - 2 * viewModel.spacing)
        }
    }

    // MARK: - Column Layout (Default)

    /// Keep a small viewport window in each column, including tiles crossing either edge.
    /// Large animated jumps must not make SwiftUI's predictive lazy cache mount hundreds of tiles.
    @ViewBuilder
    private func columnLayout(columns: Int, viewportHeight: CGFloat) -> some View {
        let spacing = viewModel.spacing
        let totalSpacing = spacing * CGFloat(columns - 1)
        let columnWidth = (viewModel.containerWidth - totalSpacing) / CGFloat(max(1, columns))

        // Exact total heights preserve the scroll extent while the mounted window changes.
        let pinnedHeights = viewModel.columnHeights.count == columns ? viewModel.columnHeights : []

        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columns, id: \.self) { colIndex in
                MasonryViewportColumn(viewModel: viewModel,
                    viewport: scrollRuntime.columnWindows[colIndex], column: colIndex,
                    columnWidth: columnWidth, initialViewportHeight: viewportHeight) { item in
                    cellView(for: item)
                }
                .frame(width: columnWidth)
                .frame(height: colIndex < pinnedHeights.count ? pinnedHeights[colIndex] : nil, alignment: .top)
            }
        }
        .padding(spacing)
    }

    /// Calculate item height from aspect ratio and column width
    private func itemHeight(for item: MediaItem, columnWidth: CGFloat) -> CGFloat {
        let aspectRatio = max(0.4, min(2.5, MasonryPresentationPolicy.layoutAspectRatio(for: item)))
        return columnWidth / aspectRatio
    }

    // MARK: - Hybrid Layout (Optional)

    @ViewBuilder
    private func hybridLayout(columns: Int) -> some View {
        let density = viewModel.density
        let spacing = viewModel.spacing
        let totalSpacing = spacing * CGFloat(columns - 1)
        let columnWidth = (viewModel.containerWidth - totalSpacing) / CGFloat(max(1, columns))

        // Use memoized filters from ViewModel (computed once per items change, not per render)
        let tallItems = viewModel.tallItems
        let wideItems = viewModel.wideItems
        let veryWideItems = viewModel.veryWideItems

        VStack(spacing: 2) {
            // Tall items: per-column LazyVStacks (virtualized)
            if !tallItems.isEmpty {
                let tallColumns = distributeTallItems(tallItems, columnCount: columns, columnWidth: columnWidth)
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { colIndex in
                        let colItems = colIndex < tallColumns.count ? tallColumns[colIndex] : []
                        LazyVStack(spacing: spacing) {
                            ForEach(colItems) { item in
                                cellView(for: item)
                                    .frame(height: itemHeight(for: item, columnWidth: columnWidth))
                            }
                        }
                        .frame(width: columnWidth)
                    }
                }
            }
            if !wideItems.isEmpty {
                JustifiedRowLayout(spacing: spacing, rowHeight: 90 + density * 50) {
                    ForEach(wideItems) { item in
                        cellView(for: item)
                    }
                }
            }
            if !veryWideItems.isEmpty {
                JustifiedRowLayout(spacing: spacing, rowHeight: 50 + density * 30) {
                    ForEach(veryWideItems) { item in
                        cellView(for: item)
                    }
                }
            }
        }
        .padding(spacing)
    }

    /// Distribute items into columns using shortest-column-first (matches ViewModel logic)
    private func distributeTallItems(_ items: [MediaItem], columnCount: Int, columnWidth: CGFloat) -> [[MediaItem]] {
        guard columnCount > 0 else { return [] }
        var columns: [[MediaItem]] = Array(repeating: [], count: columnCount)
        var heights: [CGFloat] = Array(repeating: 0, count: columnCount)

        for item in items {
            let shortest = heights.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            columns[shortest].append(item)
            let aspectRatio = max(0.4, min(2.5, MasonryPresentationPolicy.layoutAspectRatio(for: item)))
            heights[shortest] += columnWidth / aspectRatio + viewModel.spacing
        }
        return columns
    }

    @ViewBuilder
    private func cellView(for item: MediaItem) -> some View {
        let itemID = item.id
        let mediaFileCount = item.mediaFiles.count
        let columns = max(1, lastCommittedColumns)
        let columnWidth = (viewModel.containerWidth - viewModel.spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let isJustified = useHybridLayout && MasonryPresentationPolicy.layoutAspectRatio(for: item) > 1.4
        MasonryCell(
            item: item,
            tileSize: isJustified ? nil : CGSize(width: columnWidth, height: itemHeight(for: item, columnWidth: columnWidth)),
            isSelected: viewModel.selectedIDs.contains(itemID),
            isMultiSelectMode: viewModel.isMultiSelectMode,
            showColorBar: showColorBars,
            // Render state remains scalar; event-only collection state is read lazily from the
            // stable view model so a selection keypress does not resolve every selected path
            // before a drag has even begun.
            selectedIDs: [],
            selectedIDsProvider: { viewModel.selectedIDs },
            orderedDragItemsProvider: {
                MediaTransferResolver.orderedTargets(items: viewModel.items,
                    selected: viewModel.selectedIDs, clicked: currentItem(for: itemID) ?? item)
            },
            onSelect: {
                viewModel.select(itemID)
                if let currentItem = currentItem(for: itemID) {
                    onItemSelected(currentItem)
                }
            },
            onToggleSelect: {
                viewModel.toggleSelection(itemID)
            },
            onExtendSelect: {
                viewModel.extendSelection(to: itemID)
            },
            onDoubleClick: {
                CrashTelemetry.leave("dblclick id=\(itemID) files=\(mediaFileCount)")
                CrashTelemetry.flushBreadcrumbs()
                if let currentItem = currentItem(for: itemID) {
                    onItemDoubleClicked(currentItem)
                }
            },
            onShowContextMenu: onShowContextMenu.map { handler in
                { position in
                    if let currentItem = currentItem(for: itemID) {
                        handler(currentItem, position)
                    }
                }
            },
            onColorClicked: onColorClicked
        )
        .equatable()
        .id(itemID)
        .masonryLayoutMetadata(id: itemID, aspectRatio: MasonryPresentationPolicy.layoutAspectRatio(for: item))
    }

    private func currentItem(for id: UUID) -> MediaItem? {
        viewModel.item(for: id)
    }

    private func calculateColumnCount(for width: CGFloat) -> Int {
        let targetColumnWidth = 150 + (viewModel.density * 200)
        let count = max(2, Int(width / targetColumnWidth))
        return min(count, 8)
    }
}

// NOTE: Keyboard event handling has been consolidated into KeyboardShortcutManager
// which uses NSEvent.addLocalMonitorForEvents for app-wide keyboard capture.
// This avoids focus conflicts between sidebar and grid.

/// Only the columns crossing a tile boundary publish during scrolling.
@MainActor
final class MasonryColumnViewport: ObservableObject {
    @Published private(set) var range: Range<Int> = 0..<0
    private(set) var offset: CGFloat = 0
    private(set) var height: CGFloat = 0

    func update(range: Range<Int>, offset: CGFloat, height: CGFloat) {
        self.offset = offset
        self.height = height
        if self.range != range { self.range = range }
    }
}

private struct MasonryViewportColumn<Cell: View>: View {
    @ObservedObject var viewModel: MasonryGridViewModel
    @ObservedObject var viewport: MasonryColumnViewport
    let column: Int
    let columnWidth: CGFloat
    let initialViewportHeight: CGFloat
    @ViewBuilder let cell: (MediaItem) -> Cell

    var body: some View {
        let height = viewport.height > 0 ? viewport.height : max(1, initialViewportHeight)
        let range = viewModel.columnViewportRange(column: column, offset: viewport.offset, height: height)
        VStack(spacing: 0) {
            if !range.isEmpty {
                Color.clear.frame(height: viewModel.columnTop(column: column, row: range.lowerBound))
                VStack(spacing: viewModel.spacing) {
                    ForEach(viewModel.columns[column][range]) { item in
                        let ratio = max(0.4, min(2.5, MasonryPresentationPolicy.layoutAspectRatio(for: item)))
                        cell(item).frame(height: columnWidth / ratio)
                    }
                }
            }
        }
    }
}

struct MasonryGridPrefetchWindow: Equatable {
    let prefetchRange: Range<Int>
    let activeRange: Range<Int>
}

enum MasonryGridPrefetchPolicy {
    /// Convert the approximate row offset into item indices before selecting a window. The old
    /// calculation forgot the column multiplier, so deep-scroll prefetch repeatedly warmed media
    /// several screens behind the cells that were actually coming into view.
    static func window(
        itemCount: Int,
        scrollOffset: CGFloat,
        previousScrollOffset: CGFloat,
        estimatedRowHeight: CGFloat,
        estimatedVisibleRows: Int,
        columnCount: Int
    ) -> MasonryGridPrefetchWindow? {
        guard itemCount > 0,
              scrollOffset.isFinite,
              estimatedRowHeight.isFinite,
              estimatedRowHeight > 0 else { return nil }

        let columns = max(1, columnCount)
        let visibleRows = max(1, estimatedVisibleRows)
        let firstVisibleRow = max(0, Int(-scrollOffset / estimatedRowHeight))
        let visibleStart = min(itemCount, firstVisibleRow * columns)
        let visibleEnd = min(itemCount, visibleStart + visibleRows * columns)
        let scrollingDown = scrollOffset < previousScrollOffset

        // Margins are item counts rather than rows so prefetch remains bounded as density changes.
        let prefetchStart = max(0, visibleStart - (scrollingDown ? 5 : 15))
        let prefetchEnd = min(itemCount, visibleEnd + (scrollingDown ? 25 : 10))
        guard prefetchStart < prefetchEnd else { return nil }

        let activeStart = max(0, visibleStart - 20)
        let activeEnd = min(itemCount, visibleEnd + 20)
        return MasonryGridPrefetchWindow(
            prefetchRange: prefetchStart..<prefetchEnd,
            activeRange: activeStart..<activeEnd
        )
    }
}

struct MasonryGridThumbnailPrefetchTarget {
    let item: MediaItem
    let displaySize: CGSize?
    let displayScale: CGFloat

    private var carouselURLs: [URL] {
        guard !MasonryPresentationPolicy.isPresentingContext(item),
              !item.hasVideo, item.mediaFiles.count > 1 else { return [] }
        return Array(item.mediaFiles.prefix(4))
    }

    var identity: String {
        let urls = carouselURLs
        if !urls.isEmpty { return urls.map { "url|small|\($0.standardizedFileURL.path)" }.joined(separator: "\n") }
        return ImageCache.thumbnailLoadIdentity(for: item,
            displaySize: displaySize, displayScale: displayScale)
    }

    func load() async {
        let urls = carouselURLs
        if !urls.isEmpty {
            for url in urls {
                guard !Task.isCancelled else { return }
                _ = await ImageCache.shared.loadThumbnail(from: url)
            }
        } else if let image = await ImageCache.shared.loadThumbnail(for: item,
            displaySize: displaySize, displayScale: displayScale), !Task.isCancelled {
            let ratio = MasonryPresentationPolicy.layoutAspectRatio(for: item)
            if MasonryPresentationPolicy.isPresentingContext(item) || !(0.5...2).contains(ratio) {
                _ = await ImageCache.shared.loadBlurredThumbnail(for: item, source: image)
            }
        }
    }
}

struct MasonryGridRevealRequest {
    let id: UUID?
    let centered: Bool
    let animated: Bool
    let preservePendingMotion: Bool
}

/// Scroll bookkeeping stays outside observable state. Keep one scheduled delivery and
/// one bounded loading batch, replacing pending work with the latest viewport.
@MainActor
final class MasonryGridScrollRuntime {
    #if DEBUG
    static var prefetchRequestObserver: (() -> Void)?
    #endif
    private struct PrefetchRequest {
        let targets: [MasonryGridThumbnailPrefetchTarget]
        let activeIDs: Set<UUID>
        let generation: Int
    }

    weak var scrollView: NSScrollView?
    let columnWindows = (0..<8).map { _ in MasonryColumnViewport() }
    weak var scroller: LibrarySmoothScroller?
    var pendingReveal: MasonryGridRevealRequest?

    func updateColumnWindows(viewModel: MasonryGridViewModel, offset: CGFloat, height: CGFloat) {
        for column in 0..<min(viewModel.columns.count, columnWindows.count) {
            let range = viewModel.columnViewportRange(column: column, offset: offset, height: height)
            columnWindows[column].update(range: range, offset: offset, height: height)
        }
    }

    func reveal(offset: CGFloat, animated: Bool, in scroll: NSScrollView, preservePendingMotion: Bool = false) {
        if animated {
            scroller?.reveal(to: offset, in: scroll)
        } else {
            if !preservePendingMotion { scroller?.cancel() }
            var bounds = scroll.contentView.bounds
            bounds.origin.y = offset
            scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    var lastPrefetchScrollOffset: CGFloat = 0
    var lastPrefetchSignature: [String] = []
    var lastPaginationAttempt: String?
    var lastPaginationAttemptOffset: CGFloat?
    private let prefetchInterval: TimeInterval
    private var lastPrefetchUptime: TimeInterval = -.infinity
    private var scrollPrefetchTask: Task<Void, Never>?
    private var latestScrollAction: (() -> Void)?
    private var scrollGeneration = 0
    private var pendingPrefetch: PrefetchRequest?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchGeneration = 0
    private var requestGeneration = 0

    init(prefetchInterval: TimeInterval = 0.2) {
        self.prefetchInterval = prefetchInterval
    }

    func schedulePrefetch(_ action: @escaping () -> Void) {
        latestScrollAction = action
        guard scrollPrefetchTask == nil else { return }
        let delay = max(0, prefetchInterval - (ProcessInfo.processInfo.systemUptime - lastPrefetchUptime))
        let generation = scrollGeneration
        scrollPrefetchTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, self.scrollGeneration == generation else { return }
            let action = self.latestScrollAction
            self.latestScrollAction = nil
            self.scrollPrefetchTask = nil
            self.lastPrefetchUptime = ProcessInfo.processInfo.systemUptime
            action?()
        }
    }

    func requestPrefetch(targets: [MasonryGridThumbnailPrefetchTarget], activeIDs: Set<UUID>) {
        #if DEBUG
        Self.prefetchRequestObserver?()
        #endif
        requestGeneration += 1
        pendingPrefetch = PrefetchRequest(targets: Array(targets.prefix(240)),
            activeIDs: activeIDs, generation: requestGeneration)
        startPrefetchIfNeeded()
    }

    private func startPrefetchIfNeeded() {
        guard pendingPrefetch != nil else { return }
        guard prefetchTask == nil else { return }
        prefetchGeneration += 1
        let generation = prefetchGeneration
        prefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let request = self.pendingPrefetch, !Task.isCancelled {
                self.pendingPrefetch = nil
                await ImageCache.shared.hintActiveWindow(itemIds: request.activeIDs)
                guard request.generation == self.requestGeneration else { continue }
                await withTaskGroup(of: Void.self) { group in
                    var iterator = request.targets.makeIterator()
                    @MainActor func addNext() -> Bool {
                        guard !Task.isCancelled, request.generation == self.requestGeneration,
                              let target = iterator.next() else { return false }
                        group.addTask { await target.load() }
                        return true
                    }
                    for _ in 0..<4 { if !addNext() { break } }
                    for await _ in group {
                        if Task.isCancelled || request.generation != self.requestGeneration {
                            group.cancelAll()
                        } else {
                            _ = addNext()
                        }
                    }
                }
            }
            if self.prefetchGeneration == generation {
                self.prefetchTask = nil
                self.startPrefetchIfNeeded()
            }
        }
    }

    func cancelPendingWork() {
        scroller?.cancel()
        pendingReveal = nil
        scrollGeneration += 1
        scrollPrefetchTask?.cancel()
        scrollPrefetchTask = nil
        latestScrollAction = nil
        requestGeneration += 1
        pendingPrefetch = nil
        prefetchTask?.cancel()
        lastPrefetchSignature = []
    }
}

// MARK: - MasonryGridContainer

private enum BatchOperationRequest: Equatable {
    case setStarred(Bool, ids: Set<UUID>)
    case addTag(String, ids: Set<UUID>)
    case removeTag(String, ids: Set<UUID>)

    var statusText: String {
        let count: Int
        let verb: String
        switch self {
        case .setStarred(let starred, let ids):
            count = ids.count
            verb = starred ? "Starring" : "Unstarring"
        case .addTag(_, let ids):
            count = ids.count
            verb = "Adding tag to"
        case .removeTag(_, let ids):
            count = ids.count
            verb = "Removing tag from"
        }
        return "\(verb) \(count) item\(count == 1 ? "" : "s")…"
    }
}

private struct BatchOperationFailure: Identifiable {
    let id = UUID()
    let request: BatchOperationRequest
    var starAction: BatchStarAction? = nil
    var starFailedIDs: Set<UUID> = []
    var starActionIsUndoable = false
    let message: String
}

private struct GridDeleteConfirmationRequest {
    let ids: Set<UUID>
    let deleteFromDisk: Bool

    var message: String { BatchDeleteConfirmationCopy.message(deleteFromDisk: deleteFromDisk) }
}

private struct BatchTagMutationFailure: LocalizedError {
    let failedCount: Int
    let attemptedCount: Int

    var errorDescription: String? {
        "Tag update failed for \(failedCount) of \(attemptedCount) item changes. Successful changes remain applied."
    }
}

/// Container view that owns the ViewModel and integrates with AppState.
/// This is the view you embed in the main app layout.
struct MasonryGridContainer: View {
    @EnvironmentObject var appState: AppState
    @Environment(SettingsStore.self) private var settings
    @StateObject private var viewModel = MasonryGridViewModel()

    // Batch action state
    @State private var showingTagOverlay = false
    @State private var isTagOverlayPinned = false
    @State private var tagOverlayTargetIDs: Set<UUID> = []
    @State private var tagOverlayCurrentTags: [String] = []
    @State private var tagOverlayPosition: CGPoint = .zero  // mouse position for radial menu
    // PERF: NOT @State — writing @State on every mouse move causes full container body re-eval.
    // This is a class ref that MouseTrackingView writes into; we read it lazily in closures only.
    @State private var mousePositionTracker = MousePositionTracker()
    @State private var hoveredTagName: String? = nil  // Currently hovered tag in radial menu (for modifier key release)
    @State private var showingRemoveTagSheet = false
    @State private var existingTags: [String] = []
    @State private var activeBatchOperation: BatchOperationRequest?
    @State private var batchOperationFailure: BatchOperationFailure?
    @ObservedObject private var tagSettings = TagSettings.shared

    // Custom context menu state
    @State private var showingContextMenu = false
    @State private var contextMenuPosition: CGPoint = .zero
    @State private var contextMenuSize = CGSize(width: 220, height: 400)
    @State private var contextMenuActions: MasonryCellContextActions?
    @State private var pendingDeleteConfirmation: GridDeleteConfirmationRequest?

    // Cached CLIP search results for pagination and repeated reloads.
    @State private var cachedClipResultIds: [UUID]?
    @State private var cachedClipQuery: String?
    @State private var thumbnailWarmupTask: Task<Void, Never>?
    @State private var thumbnailWarmupGeneration = 0

    // Export with metadata sheet state

    // Board picker sheet state
    @State private var showingBoardPicker = false
    @State private var boardPickerTargetIDs: [UUID] = []

    // Issue #1: Canvas picker sheet state
    @State private var showingCanvasPicker = false
    @State private var canvasPickerTargetIDs: [UUID] = []
    private let libraryPageSize = MasonryGridViewModel.pageSize

    var body: some View {
        bodyContent
    }

    @ViewBuilder
    private var bodyContent: some View {
        ZStack(alignment: .bottom) {
            mainContentView
            batchActionBarView
        }
        .modifier(GridDataModifier(appState: appState, viewModel: viewModel, loadItems: loadItems))
        .modifier(GridNavigationModifier(appState: appState, viewModel: viewModel))
        .confirmationDialog(
            "Delete \(pendingDeleteConfirmation?.ids.count ?? 0) items?",
            isPresented: Binding(
                get: { pendingDeleteConfirmation != nil },
                set: { if !$0 { pendingDeleteConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let confirmation = pendingDeleteConfirmation else { return }
                pendingDeleteConfirmation = nil
                performBatchDelete(ids: confirmation.ids, deleteFromDisk: confirmation.deleteFromDisk)
            }
            Button("Cancel", role: .cancel) { pendingDeleteConfirmation = nil }
        } message: {
            Text(pendingDeleteConfirmation?.message ?? "")
        }
        .onAppear {
            viewModel.setSelectionStore(appState.mediaSelectionStore)
            appState.mediaSelectionStore.activate(.grid)
        }
        .onDisappear {
            appState.mediaSelectionStore.invalidateQueries(from: .grid)
            thumbnailWarmupTask?.cancel()
            thumbnailWarmupTask = nil
            thumbnailWarmupGeneration += 1
        }
        // Sync multi-selection to appState for inspector panel
        .onChange(of: viewModel.selectedIDs) { _, newIDs in
            appState.selectedItemIDs = newIDs
            if newIDs.isEmpty {
                appState.selectedItemID = nil
            } else if let anchor = viewModel.selectionAnchor, newIDs.contains(anchor) {
                appState.selectedItemID = anchor
            } else {
                appState.selectedItemID = appState.orderedItemIDs(in: newIDs).first
            }
            appState.updateDisplayContextSelection(
                surface: .grid,
                selectedIDs: newIDs,
                anchorID: viewModel.selectionAnchor
            )
        }
        // FIX: Scroll to selected item when returning from focus view
        .onChange(of: appState.focusedItem) { _, newValue in
            if newValue == nil && !viewModel.selectedIDs.isEmpty {
                viewModel.shouldScrollToSelectionOnFocusReturn = true
            }
        }
        .background(
            GridModifierKeyHandler(
                hasSelection: !viewModel.selectedIDs.isEmpty,
                onModifierChanged: handleModifierKeyChanged,
                modifierKey: tagSettings.modifierKey
            )
        )
        .overlay { mouseTrackingOverlay }
        .overlay { tagOverlayView }
        .overlay { contextMenuOverlayView }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            closeTagOverlay()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            closeTagOverlayIfModifierIsUp()
        }
        .sheet(isPresented: $showingRemoveTagSheet) {
            removeTagSheet
        }
        .sheet(isPresented: $showingBoardPicker) {
            BoardPickerSheet(
                itemIds: boardPickerTargetIDs,
                onDismiss: { showingBoardPicker = false }
            )
        }
        // Issue #1: Canvas picker sheet
        .sheet(isPresented: $showingCanvasPicker) {
            CanvasPickerSheet(
                itemIds: canvasPickerTargetIDs,
                onDismiss: { showingCanvasPicker = false }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .addToRediscover)) { _ in
            // Handle R keyboard shortcut for adding to rediscover queue
            handleAddToRediscoverShortcut()
        }
        .onReceive(NotificationCenter.default.publisher(for: .addToBoard)) { _ in
            // Handle B keyboard shortcut for adding to board
            guard FeatureFlags.boards else { return }
            handleAddToBoardShortcut()
        }
        .alert(item: $batchOperationFailure) { failure in
            Alert(
                title: Text("Batch Action Failed"),
                message: Text(failure.message),
                primaryButton: .default(Text("Retry")) {
                    retryBatchOperation(failure)
                },
                secondaryButton: .cancel()
            )
        }
    }

    @ViewBuilder
    private var removeTagSheet: some View {
        BatchTagInputSheet(
            title: "Remove Tag from \(viewModel.selectedIDs.count) Items",
            existingTags: existingTags,
            onSubmit: { tag in
                performBatchRemoveTag(tag)
                showingRemoveTagSheet = false
            },
            onCancel: { showingRemoveTagSheet = false }
        )
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContentView: some View {
        ZStack {
            if viewModel.items.isEmpty && !viewModel.isLoading {
                emptyStateView
            } else {
                MasonryGrid(
                    viewModel: viewModel,
                    useHybridLayout: appState.useHybridLayout,
                    showColorBars: appState.showColorBars,
                    isBackgrounded: appState.isShowingSingleFocus,
                    allowsViewportInteraction: !appState.showCommandPalette,
                    onItemSelected: { item in
                        PerformanceLog.begin("cellSelect", log: PerformanceLog.interactionLog)
                        appState.selectedItemIDs = [item.id]
                        appState.selectedItemID = item.id
                        PerformanceLog.end("cellSelect", log: PerformanceLog.interactionLog)
                    },
                    onItemDoubleClicked: { item in
                        PerformanceLog.begin("cellDoubleClick", log: PerformanceLog.interactionLog)
                        viewModel.select(item.id)
                        appState.selectedItemIDs = [item.id]
                        appState.selectedItemID = item.id
                        appState.openSingleFocus(item)
                        PerformanceLog.end("cellDoubleClick", log: PerformanceLog.interactionLog)
                    },
                    onShowContextMenu: { item, windowPosition in
                        PerformanceLog.event("contextMenuOpen", log: PerformanceLog.interactionLog, item.id.uuidString)
                        let actions = makeContextActions(for: item)
                        contextMenuPosition = mousePositionTracker.position(fromWindowPoint: windowPosition)
                        contextMenuActions = actions
                        showingContextMenu = true
                    },
                    onLoadMore: {
                        await loadMoreItems()
                    },
                    libraryScrollRequest: appState.libraryScrollRequest,
                    onColorClicked: { colorSearch in
                        // Trigger precision color search from clicked color bar segment
                        appState.commitLibraryFilterChange {
                            appState.colorSearchRGB = colorSearch
                        }
                    }
                )
                .equatable()
                .contextMenu {
                    gridBackgroundContextMenu
                }
            }

            if viewModel.isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            NSApp.keyWindow?.makeFirstResponder(nil)
        })
    }

    @ViewBuilder
    private var gridBackgroundContextMenu: some View {
        Button("Select All \(viewModel.items.count) Loaded Items") {
            viewModel.selectAll()
        }
        .disabled(viewModel.items.isEmpty)

        Button("Deselect All") {
            viewModel.clearSelection()
        }
        .disabled(viewModel.selectedIDs.isEmpty)

        Divider()

        Menu("Sort") {
            ForEach(SortOrder.allCases, id: \.self) { order in
                Button(order.displayName) {
                    appState.commitLibraryFilterChange {
                        appState.sortOrder = order
                    }
                }
            }
        }

        Button(appState.isShuffleActive ? "Turn Shuffle Off" : "Turn Shuffle On") {
            appState.toggleShuffle()
        }

        Button("Reshuffle") {
            appState.reshuffle()
        }
        .disabled(!appState.isShuffleActive)

        Divider()

        if FeatureFlags.tableBrowser {
            Button("Switch to \(appState.browseMode == .grid ? "Table" : "Grid") View") {
                appState.browseMode = appState.browseMode == .grid ? .table : .grid
            }
        }

        Toggle("Group Similar Aspect Ratios", isOn: $appState.useHybridLayout)
            .disabled(appState.browseMode == .table)

        Toggle("Show Color Bars", isOn: $appState.showColorBars)
            .disabled(appState.browseMode == .table)
    }

    // MARK: - Batch Action Bar

    @ViewBuilder
    private var batchActionBarView: some View {
        if viewModel.selectedIDs.count > 1 {
            BatchActionBar(
                selectedCount: viewModel.selectedIDs.count,
                statusText: activeBatchOperation?.statusText,
                onStarAll: { performBatchStar(starred: true) },
                onUnstarAll: { performBatchStar(starred: false) },
                onAddTag: {
                    let targetItems = viewModel.items.filter { viewModel.selectedIDs.contains($0.id) }
                    tagOverlayTargetIDs = viewModel.selectedIDs
                    tagOverlayCurrentTags = Array(Set(targetItems.flatMap { $0.metadata.tags })).sorted()
                    tagOverlayPosition = mousePositionTracker.position
                    showingTagOverlay = true
                },
                onRemoveTag: {
                    Task { await loadExistingTags() }
                    showingRemoveTagSheet = true
                },
                onDelete: { performBatchDelete() },
                onClearSelection: { viewModel.clearSelection() }
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 60)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.selectedIDs.count > 1)
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var mouseTrackingOverlay: some View {
        MouseTrackingView(tracker: mousePositionTracker)
    }

    @ViewBuilder
    private var tagOverlayView: some View {
        if showingTagOverlay {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture { closeTagOverlay() }

                    TagOverlay(
                        currentTags: tagOverlayCurrentTags,
                        onTagsChanged: { newTags in
                            applyTagsToTargets(newTags)
                        },
                        onDismiss: { closeTagOverlay() },
                        position: tagOverlayPosition,
                        hoveredTagName: $hoveredTagName,
                        onBeginTextEntry: { isTagOverlayPinned = true }
                    )
                    .position(
                        x: min(max(tagOverlayPosition.x, 180), geo.size.width - 180),
                        y: min(max(tagOverlayPosition.y, 180), geo.size.height - 180)
                    )
                }
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.05)))  // FIX: Faster animation for snappier feel
        }
    }

    @ViewBuilder
    private var contextMenuOverlayView: some View {
        if showingContextMenu, let actions = contextMenuActions {
            GeometryReader { geo in
                let viewport = ContextMenuPlacement.viewportSize(menuSize: contextMenuSize, containerSize: geo.size)
                let origin = ContextMenuPlacement.origin(for: contextMenuPosition, menuSize: viewport, containerSize: geo.size)
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showingContextMenu = false }

                    ScrollView([.horizontal, .vertical]) {
                        CustomContextMenu(actions: actions, onDismiss: { showingContextMenu = false })
                            .fixedSize(horizontal: true, vertical: true)
                            .background {
                                GeometryReader { menuGeometry in
                                    Color.clear.preference(key: ContextMenuSizeKey.self, value: menuGeometry.size)
                                }
                            }
                    }
                    .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
                    .offset(x: origin.x, y: origin.y)
                }
                .onPreferenceChange(ContextMenuSizeKey.self) { contextMenuSize = $0 }
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.1)))
            .onExitCommand { showingContextMenu = false }
        }
    }

    // MARK: - Modifier Key Handling

    /// Handle modifier key press/release for quick tagging
    private func handleModifierKeyChanged(_ isPressed: Bool) {
        // Once text entry starts, this becomes a normal picker until dismissed.
        guard !isTagOverlayPinned else { return }
        if isPressed {
            guard !viewModel.selectedIDs.isEmpty else { return }

            // Modifier pressed - show overlay at current mouse position
            // FIX: Use dictionary lookup instead of O(n) filter for better performance
            let selectedIDs = viewModel.selectedIDs
            var allTags = Set<String>()
            for item in viewModel.items where selectedIDs.contains(item.id) {
                allTags.formUnion(item.metadata.tags)
            }
            tagOverlayTargetIDs = selectedIDs
            tagOverlayCurrentTags = allTags.sorted()
            tagOverlayPosition = mousePositionTracker.position
            hoveredTagName = nil
            showingTagOverlay = true
        } else {
            // Modifier released - apply hovered tag if any
            if showingTagOverlay,
               !NSEvent.modifierFlags.contains(tagSettings.modifierKey.eventFlag),
               let tagName = hoveredTagName {
                applyTagToggle(tagName)
            }
            closeTagOverlay()
        }
    }

    private func closeTagOverlay() {
        isTagOverlayPinned = false
        hoveredTagName = nil
        showingTagOverlay = false
    }

    private func closeTagOverlayIfModifierIsUp() {
        if !isTagOverlayPinned && !NSEvent.modifierFlags.contains(tagSettings.modifierKey.eventFlag) {
            closeTagOverlay()
        }
    }

    /// Toggle a single tag on all target items (add if missing, remove if all have it)
    private func applyTagToggle(_ tagName: String) {
        let targetItems = viewModel.items.filter { tagOverlayTargetIDs.contains($0.id) }
        guard !targetItems.isEmpty else { return }
        let allHaveTag = targetItems.allSatisfy { TagOverlaySelection.contains(tagName, in: $0.metadata.tags) }
        if allHaveTag {
            performBatchRemoveTag(tagName, ids: tagOverlayTargetIDs)
        } else {
            performBatchAddTag(tagName, ids: tagOverlayTargetIDs)
        }
    }

    // MARK: - Context Menu Actions

    /// Create context actions for a cell. Uses selected items if multiple selected,
    /// otherwise uses just the right-clicked item.
    private func makeContextActions(for item: MediaItem) -> MasonryCellContextActions {
        // If this item is selected and multiple items are selected, operate on all selected
        // Otherwise, operate on just this item
        let targetIDs = MasonryContextSelectionPolicy.targetIDs(clickedID: item.id, selectedIDs: viewModel.selectedIDs)
        // Resolve from the mounted grid's own loaded corpus. AppState may still
        // hold another surface's display projection during a view handoff.
        let targetItems = viewModel.items.filter { targetIDs.contains($0.id) }

        // Get dominant colors from the right-clicked item for "Find Similar Colors" feature
        let dominantColors = item.indexedContent?.dominantColors ?? []

        return MasonryCellContextActions(
            selectedCount: targetItems.count,
            isStarred: item.metadata.starred,
            dominantColors: dominantColors,
            onRevealInFinder: { [targetItems] in
                revealInFinder(items: targetItems)
            },
            onCopyPath: { [targetItems] in
                copyPaths(items: targetItems)
            },
            onCopyFolderPath: { [targetItems] in
                MediaActionContext(items: targetItems).copyFolderPaths()
            },
            onCopySourceURL: { [targetItems] in
                copySourceURLs(items: targetItems)
            },
            onToggleStar: { [targetItems, targetIDs] in
                if targetItems.count > 1 {
                    // Batch: always star all
                    performBatchStar(starred: true, ids: targetIDs)
                } else if let singleItem = targetItems.first {
                    // Single: toggle
                    performBatchStar(starred: !singleItem.metadata.starred, ids: targetIDs)
                }
            },
            onAddTag: { [targetIDs, targetItems] in
                // Capture targets at click time - don't rely on selection state
                tagOverlayTargetIDs = targetIDs
                // Get union of all current tags from target items
                tagOverlayCurrentTags = Array(Set(targetItems.flatMap { $0.metadata.tags })).sorted()
                // Use mouse position tracked by onContinuousHover
                tagOverlayPosition = mousePositionTracker.position
                // Close context menu first, then show tag overlay
                showingContextMenu = false
                showingTagOverlay = true
            },
            onAddToBoard: { [targetIDs] in
                // Close context menu first, then show board picker
                showingContextMenu = false
                boardPickerTargetIDs = Array(targetIDs)
                showingBoardPicker = true
            },
            // Issue #1: Add to Canvas
            onAddToCanvas: { [targetIDs] in
                showingContextMenu = false
                canvasPickerTargetIDs = Array(targetIDs)
                showingCanvasPicker = true
            },
            onOpenSource: { [targetItems] in
                openSources(items: targetItems)
            },
            onDelete: { [targetIDs] in
                requestDeleteConfirmation(ids: targetIDs)
            },
            onFindSimilarColors: { [dominantColors] in
                // Set color filters to match this item's dominant colors
                appState.commitLibraryFilterChange {
                    appState.colorFilters = Set(dominantColors)
                }
            },
            onExportWithMetadata: { [targetItems] in
                showingContextMenu = false
                MediaFileAction.exportMetadata.perform(context: MediaActionContext(items: targetItems), source: .downloaded, appState: appState)
            },
            onAddToRediscover: { [targetIDs] in
                // Initialize items in FSRS for Rediscover feature
                addToRediscover(ids: Array(targetIDs))
            },
            onCombineItems: targetItems.count > 1 ? { [targetIDs, primaryID = item.id] in
                combineSelectedItems(primaryID: primaryID, secondaryIDs: Array(targetIDs.subtracting([primaryID])))
            }
            : nil,
            transferContext: MediaActionContext(items: targetItems)
        )
    }

    private func revealInFinder(items: [MediaItem]) {
        MediaFileAction.reveal.perform(context: MediaActionContext(items: items), appState: appState)
    }

    private func copyPaths(items: [MediaItem]) {
        MediaFileAction.copyPaths.perform(context: MediaActionContext(items: items), appState: appState)
    }

    private func copySourceURLs(items: [MediaItem]) {
        let urls = items.map { $0.metadata.source.absoluteString }
        let urlString = urls.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
    }

    private func openSources(items: [MediaItem]) {
        // Open up to 5 URLs to avoid overwhelming the browser
        let urlsToOpen = items.prefix(5).map { $0.metadata.source }
        for url in urlsToOpen {
            NSWorkspace.shared.open(url)
        }
    }

    private func performSingleStar(item: MediaItem, starred: Bool) {
        guard let store = appState.mediaStore else { return }

        let registeredLocalMutation = viewModel.beginLocalStarMutation(for: item.id)

        Task { @MainActor in
            do {
                try await store.setStar(id: item.id, starred: starred)

                guard registeredLocalMutation else { return }

                let applyMutation = {
                    switch viewModel.applyLocalStarMutation(
                        id: item.id,
                        starred: starred,
                        activeStarredFilter: appState.starredFilter
                    ) {
                    case .updated(let updatedItem):
                        appState.replaceCachedItemIfPresent(updatedItem)
                    case .removed:
                        appState.removeDisplayedItems(ids: [item.id])
                    case .notPresent:
                        break
                    }
                }

                if appState.starredFilter != nil && appState.starredFilter != starred {
                    withAnimation(.easeOut(duration: 0.15)) {
                        applyMutation()
                    }
                } else {
                    applyMutation()
                }
            } catch {
                if registeredLocalMutation {
                    viewModel.cancelLocalStarMutation()
                }
                logError("Star update failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Batch Actions

    private func performBatchStar(starred: Bool) {
        performBatchStar(starred: starred, ids: viewModel.selectedIDs)
    }

    private func performBatchStar(starred: Bool, ids: Set<UUID>) {
        let request = BatchOperationRequest.setStarred(starred, ids: ids)
        guard !ids.isEmpty,
              activeBatchOperation == nil else { return }
        guard let store = appState.mediaStore else {
            batchOperationFailure = BatchOperationFailure(
                request: request,
                message: "The library service is not available yet."
            )
            return
        }

        let service = BatchOperationsService(mediaStore: store)
        activeBatchOperation = request
        batchOperationFailure = nil

        Task {
            PerformanceLog.begin("batchStar", log: PerformanceLog.interactionLog)
            defer {
                activeBatchOperation = nil
                PerformanceLog.end("batchStar", log: PerformanceLog.interactionLog)
            }
            var action: BatchStarAction?
            do {
                // GAP #12 fix: Now async to capture pre-state
                let createdAction = starred
                    ? try await service.makeStarAllAction(ids: ids)
                    : try await service.makeUnstarAllAction(ids: ids)
                action = createdAction
                try await appState.undoStack.performAction(createdAction)
                await loadItems() // Refresh to show changes
            } catch let partial as BatchStarPartialFailure {
                batchOperationFailure = BatchOperationFailure(
                    request: request,
                    starAction: action,
                    starFailedIDs: partial.failedIDs,
                    starActionIsUndoable: !partial.succeededIDs.isEmpty,
                    message: partial.localizedDescription
                )
            } catch {
                logError("Batch star failed: \(error.localizedDescription)")
                batchOperationFailure = BatchOperationFailure(
                    request: request,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func performBatchAddTag(_ tag: String) {
        performBatchAddTag(tag, ids: viewModel.selectedIDs)
    }

    private func performBatchAddTag(_ tag: String, ids: Set<UUID>) {
        let request = BatchOperationRequest.addTag(tag, ids: ids)
        guard !ids.isEmpty,
              activeBatchOperation == nil else { return }
        guard let store = appState.mediaStore else {
            batchOperationFailure = BatchOperationFailure(
                request: request,
                message: "The library service is not available yet."
            )
            return
        }

        let service = BatchOperationsService(mediaStore: store)
        activeBatchOperation = request
        batchOperationFailure = nil

        Task {
            PerformanceLog.begin("batchAddTag", log: PerformanceLog.interactionLog)
            defer {
                activeBatchOperation = nil
                PerformanceLog.end("batchAddTag", log: PerformanceLog.interactionLog)
            }
            do {
                // GAP #12 fix: Now async to capture pre-state
                let action = try await service.makeAddTagAction(tag: tag, to: ids)
                try await appState.undoStack.performAction(action)
                await loadItems()
            } catch {
                logError("Batch add tag failed: \(error.localizedDescription)")
                batchOperationFailure = BatchOperationFailure(
                    request: request,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func performBatchRemoveTag(_ tag: String) {
        performBatchRemoveTag(tag, ids: viewModel.selectedIDs)
    }

    private func performBatchRemoveTag(_ tag: String, ids: Set<UUID>) {
        let request = BatchOperationRequest.removeTag(tag, ids: ids)
        guard !ids.isEmpty,
              activeBatchOperation == nil else { return }
        guard let store = appState.mediaStore else {
            batchOperationFailure = BatchOperationFailure(
                request: request,
                message: "The library service is not available yet."
            )
            return
        }

        let service = BatchOperationsService(mediaStore: store)
        activeBatchOperation = request
        batchOperationFailure = nil

        Task {
            PerformanceLog.begin("batchRemoveTag", log: PerformanceLog.interactionLog)
            defer {
                activeBatchOperation = nil
                PerformanceLog.end("batchRemoveTag", log: PerformanceLog.interactionLog)
            }
            do {
                // GAP #12 fix: Now async to capture pre-state
                let action = try await service.makeRemoveTagAction(tag: tag, from: ids)
                try await appState.undoStack.performAction(action)
                await loadItems()
            } catch {
                logError("Batch remove tag failed: \(error.localizedDescription)")
                batchOperationFailure = BatchOperationFailure(
                    request: request,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func retryBatchOperation(_ request: BatchOperationRequest) {
        switch request {
        case .setStarred(let starred, let ids):
            performBatchStar(starred: starred, ids: ids)
        case .addTag(let tag, let ids):
            performBatchAddTag(tag, ids: ids)
        case .removeTag(let tag, let ids):
            performBatchRemoveTag(tag, ids: ids)
        }
    }

    private func retryBatchOperation(_ failure: BatchOperationFailure) {
        guard case .setStarred(let starred, let ids) = failure.request,
              let action = failure.starAction else {
            retryBatchOperation(failure.request)
            return
        }
        guard activeBatchOperation == nil else { return }
        activeBatchOperation = .setStarred(starred, ids: failure.starFailedIDs)
        batchOperationFailure = nil
        Task {
            defer { activeBatchOperation = nil }
            do {
                try await appState.undoStack.retryBatchStar(
                    action,
                    failedIDs: failure.starFailedIDs,
                    alreadyUndoable: failure.starActionIsUndoable
                )
                await loadItems()
            } catch let partial as BatchStarRetryFailure {
                batchOperationFailure = BatchOperationFailure(
                    request: .setStarred(starred, ids: ids),
                    starAction: action,
                    starFailedIDs: partial.failedIDs,
                    starActionIsUndoable: partial.isUndoable,
                    message: partial.localizedDescription
                )
            } catch {
                batchOperationFailure = BatchOperationFailure(
                    request: .setStarred(starred, ids: ids),
                    starAction: action,
                    starFailedIDs: failure.starFailedIDs,
                    starActionIsUndoable: failure.starActionIsUndoable,
                    message: error.localizedDescription
                )
            }
        }
    }

    /// Apply tag changes from TagOverlay to target items
    private func applyTagsToTargets(_ newTags: [String]) {
        guard let store = appState.mediaStore else { return }

        let changes = TagOverlaySelection.changes(from: tagOverlayCurrentTags, to: newTags)
        let tagsToAdd = changes.added
        let tagsToRemove = changes.removed
        let targetIDs = tagOverlayTargetIDs

        Task {
            let failures = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                // Add new tags in parallel
                for tag in tagsToAdd {
                    for itemId in targetIDs {
                        group.addTask {
                            do {
                                try await store.addTag(id: itemId, tag: tag)
                                return true
                            } catch {
                                return false
                            }
                        }
                    }
                }
                // Remove old tags in parallel
                for tag in tagsToRemove {
                    for itemId in targetIDs {
                        group.addTask {
                            do {
                                try await store.removeTag(id: itemId, tag: tag)
                                return true
                            } catch {
                                return false
                            }
                        }
                    }
                }
                var failureCount = 0
                for await succeeded in group where !succeeded { failureCount += 1 }
                return failureCount
            }

            // Refresh grid
            await loadItems()
            let refreshedTargetItems = viewModel.items.filter { targetIDs.contains($0.id) }
            await MainActor.run {
                tagOverlayCurrentTags = Array(Set(refreshedTargetItems.flatMap { $0.metadata.tags })).sorted()
                if failures > 0 {
                    MediaTransferFeedback.shared.report(BatchTagMutationFailure(
                        failedCount: failures,
                        attemptedCount: tagsToAdd.count * targetIDs.count + tagsToRemove.count * targetIDs.count
                    ))
                }
            }
        }
    }

    private func performBatchDelete() {
        requestDeleteConfirmation(ids: viewModel.selectedIDs)
    }

    private func requestDeleteConfirmation(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingDeleteConfirmation = GridDeleteConfirmationRequest(
            ids: ids,
            deleteFromDisk: settings.deleteFilesFromDisk
        )
    }

    private func performBatchDelete(ids: Set<UUID>, deleteFromDisk: Bool? = nil) {
        guard !ids.isEmpty else { return }

        Task {
            PerformanceLog.begin("batchDelete", log: PerformanceLog.interactionLog)
            var survivor: UUID?
            withAnimation(.easeOut(duration: 0.15)) {
                survivor = viewModel.removeItems(ids, selectingSurvivor: true)
            }
            // AppState captures selection for rollback/undo. Synchronize the chosen survivor before
            // starting deletion instead of waiting for SwiftUI's onChange delivery.
            appState.selectedItemIDs = survivor.map { Set([$0]) } ?? []
            appState.selectedItemID = survivor
            appState.deleteItems(Array(ids), deleteFromDisk: deleteFromDisk)
            PerformanceLog.end("batchDelete", log: PerformanceLog.interactionLog)
        }
    }

    private func combineSelectedItems(primaryID: UUID, secondaryIDs: [UUID]) {
        guard !secondaryIDs.isEmpty, let store = appState.mediaStore else { return }

        Task {
            do {
                let result = try await store.combineItems(primaryID: primaryID, secondaryIDs: secondaryIDs)
                let service = DeleteService(mediaStore: store)
                let cleanup = await service.trashCombineOrphansResult(result.orphanedFileURLs)
                if cleanup.hasFileErrors {
                    MediaTransferFeedback.shared.reportFileFailures(cleanup.fileErrors,
                        urls: cleanup.failedFileURLs, retryTargets: cleanup.retryTargets, service: service)
                }
                await MainActor.run {
                    showingContextMenu = false
                    viewModel.select(result.primaryID)
                    appState.selectedItemID = result.primaryID
                    appState.selectedItemIDs = [result.primaryID]
                }
                await loadItems()
            } catch {
                logError("Combine items failed: \(error.localizedDescription)")
                MediaTransferFeedback.shared.report(error)
            }
        }
    }

    private func loadExistingTags() async {
        guard let store = appState.mediaStore else { return }
        do {
            existingTags = try await store.fetchAllTags()
        } catch {
            existingTags = []
        }
    }

    /// Add items to FSRS Rediscover queue
    private func addToRediscover(ids: [UUID]) {
        let scheduler = ReviewScheduler()
        Task {
            do {
                try await scheduler.initializeForItems(ids)
                logInfo("Added \(ids.count) items to Rediscover queue")
            } catch {
                logError("Failed to add items to Rediscover: \(error.localizedDescription)")
            }
        }
    }

    /// Handle R keyboard shortcut - add selected/focused items to Rediscover
    private func handleAddToRediscoverShortcut() {
        var targetIDs: [UUID] = []

        if !viewModel.selectedIDs.isEmpty {
            targetIDs = Array(viewModel.selectedIDs)
        } else if let focusedItem = appState.focusedItem {
            targetIDs = [focusedItem.id]
        } else if let selectedID = appState.selectedItemID {
            targetIDs = [selectedID]
        }

        guard !targetIDs.isEmpty else { return }
        addToRediscover(ids: targetIDs)
    }

    /// Handle B keyboard shortcut - show board picker sheet
    private func handleAddToBoardShortcut() {
        var targetIDs: Set<UUID> = []

        if !viewModel.selectedIDs.isEmpty {
            targetIDs = viewModel.selectedIDs
        } else if let focusedItem = appState.focusedItem {
            targetIDs = [focusedItem.id]
        } else if let selectedID = appState.selectedItemID {
            targetIDs = [selectedID]
        }

        guard !targetIDs.isEmpty else { return }

        // Show board picker sheet
        boardPickerTargetIDs = Array(targetIDs)
        showingBoardPicker = true
    }

    private var emptyStateView: some View {
        LibraryEmptyResultsView()
    }

    private func loadItems() async {
        viewModel.setSelectionStore(appState.mediaSelectionStore)
        guard let queryToken = appState.mediaSelectionStore.beginQuery(from: .grid) else { return }
        let resetToTop = viewModel.reloadStartsAtTop
        let reloadLimit = viewModel.reloadLimit
        // Build context string for PerfLog
        let filterContext = buildFilterContext()
        CrashTelemetry.leave("loadItems-start filter=\(appState.filterText.isEmpty ? "(empty)" : appState.filterText.prefix(20).description)")
        let token = PerfLog.begin("loadItems", category: .data, context: filterContext)
        defer { PerfLog.end(token) }

        guard let store = appState.mediaStore else {
            // Fall back to preview data if no store yet
            #if DEBUG
            if appState.initPhase == .notStarted {
                viewModel.setItems(generatePreviewItems())
            }
            #endif
            return
        }

        do {
            guard var filter = MediaFilterBuilder.makeBaseFilter(
                sidebarSelection: appState.sidebarSelection,
                activeSmartFolder: appState.activeSmartFolder,
                unsupportedSelectionBehavior: .keepUnfiltered
            ) else {
                return
            }

            MediaFilterBuilder.applyCommonFilters(
                to: &filter,
                dateRangeFilter: appState.dateRangeFilter,
                colorFilters: appState.colorFilters,
                colorSearchRGB: appState.colorSearchRGB,
                starredFilter: appState.starredFilter,
                hasOCRFilter: appState.hasOCRFilter,
                platformFilter: appState.platformFilter,
                attributeFilters: appState.pipelineAttributeFilters,
                hideJunk: settings.hideJunkItems,
                hideSafetyFlagged: settings.hideSafetyFlagged
            )

            // Store refreshes refetch the loaded range; query changes start with one page.
            filter.sortOrder = appState.sortOrder
            filter.shuffleSeed = appState.shuffleSeed
            filter.limit = reloadLimit

            let clipQueryText = MediaFilterBuilder.searchQueryText(from: appState.filterText)
            let reusableClipResults: [UUID]? = {
                guard appState.searchScope == .visual,
                      !clipQueryText.isEmpty,
                      cachedClipQuery == clipQueryText else {
                    return nil
                }
                return cachedClipResultIds
            }()

            let clipResultIds = try await MediaFilterBuilder.applySearch(
                to: &filter,
                filterText: appState.filterText,
                searchScope: appState.searchScope,
                visualResultIds: reusableClipResults,
                allowVisualSearch: true
            )
            guard !Task.isCancelled, appState.mediaSelectionStore.accepts(queryToken) else { return }
            cachedClipResultIds = clipResultIds
            cachedClipQuery = clipResultIds == nil ? nil : clipQueryText
            appState.resolvedLibraryQuery.send(filter)

            let items: [MediaItem]
            let queryStarted = StartupMetrics.begin()
            if appState.mediaSelectionStore.canReuseLoadedResults(for: filter, switchingTo: .grid) {
                items = appState.mediaSelectionStore.items
            } else {
                items = try await store.fetchItems(
                filter: filter,
                includeMLAttributes: false,
                includePerFileOCR: false,
                includeVideoSegments: false,
                includeTranscriptSegments: false
            )
            }
            CrashTelemetry.leave("loadItems-fetched n=\(items.count)")
            guard !Task.isCancelled, appState.mediaSelectionStore.accepts(queryToken) else { return }
            StartupMetrics.end("initial_grid_query", since: queryStarted, once: true, count: items.count)
            appState.mediaSelectionStore.rememberFilter(filter)
            viewModel.applyReload(items, resetToTop: resetToTop)
            CrashTelemetry.leave("loadItems-setItems done")
            appState.setDisplayContext(
                surface: .grid,
                items: viewModel.items,
                selectedIDs: viewModel.selectedIDs,
                anchorID: viewModel.selectionAnchor
            )

            // Warm cached thumbnails independently. A stale 240-item disk pass must
            // never keep a newer sidebar/filter query inside the reload gate.
            scheduleThumbnailWarmup(items: items)

            // Video hover now seeks its live AVPlayer/WebKit transport directly. The legacy disk
            // preview-frame cache has no grid consumer, so warming up to 24 videos after every
            // query was pure boot/browse CPU and I/O. Keep thumbnail warming above; generate hover
            // frames only if a future consumer explicitly requests them.
        } catch {
            logError("Failed to load items: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func scheduleThumbnailWarmup(items: [MediaItem]) {
        thumbnailWarmupTask?.cancel()
        thumbnailWarmupGeneration += 1
        let generation = thumbnailWarmupGeneration
        thumbnailWarmupTask = Task {
            await ImageCache.shared.preloadFromDisk(items: items)
            guard !Task.isCancelled, generation == thumbnailWarmupGeneration else { return }
            thumbnailWarmupTask = nil
        }
    }

    /// Build filter context string for performance logging
    private func buildFilterContext() -> String {
        var parts: [String] = []

        // Sidebar selection
        switch appState.sidebarSelection {
        case .allMedia: parts.append("all")
        case .recentlyDeleted: parts.append("deleted")
        case .folderYear(let year): parts.append("folder:\(year)-")
        case .folder(let name): parts.append("folder:\(name)")
        case .smartFolder: parts.append("smart")
        case .board: parts.append("board")
        case .platform(let name): parts.append("platform:\(name)")
        case .tag(let name): parts.append("tag:\(name)")
        case .rediscover: parts.append("rediscover")
        case .duplicates: parts.append("duplicates")
        case .canvas: parts.append("canvas")
        case .visualClusters: parts.append("clusters")
        }

        // Search text (truncated)
        if !appState.filterText.isEmpty {
            let truncated = String(appState.filterText.prefix(20))
            parts.append("search:\(truncated)")
        }

        // Additional filters
        if appState.starredFilter == true { parts.append("starred") }
        if appState.hasOCRFilter == true { parts.append("hasOCR") }
        if !appState.colorFilters.isEmpty { parts.append("colors:\(appState.colorFilters.count)") }
        if !appState.pipelineAttributeFilters.isEmpty { parts.append("attrs:\(appState.pipelineAttributeFilters.count)") }
        if appState.dateRangeFilter != nil { parts.append("dateRange") }
        if appState.isShuffleActive { parts.append("shuffle") }
        parts.append("sort:\(appState.sortOrder.rawValue)")

        return parts.joined(separator: ", ")
    }

    /// Load more items for pagination (appends to existing items)
    private func loadMoreItems() async {
        guard let queryToken = appState.mediaSelectionStore.currentQueryToken(from: .grid)
            ?? appState.mediaSelectionStore.beginQuery(from: .grid) else { return }
        let startingOffset = viewModel.paginationOffset
        let token = PerfLog.begin("loadMoreItems", category: .data, context: "offset:\(viewModel.currentOffset)")
        defer { PerfLog.end(token) }

        guard let store = appState.mediaStore else { return }

        do {
            guard var filter = MediaFilterBuilder.makeBaseFilter(
                sidebarSelection: appState.sidebarSelection,
                activeSmartFolder: appState.activeSmartFolder,
                unsupportedSelectionBehavior: .keepUnfiltered
            ) else {
                return
            }

            MediaFilterBuilder.applyCommonFilters(
                to: &filter,
                dateRangeFilter: appState.dateRangeFilter,
                colorFilters: appState.colorFilters,
                colorSearchRGB: appState.colorSearchRGB,
                starredFilter: appState.starredFilter,
                hasOCRFilter: appState.hasOCRFilter,
                platformFilter: appState.platformFilter,
                attributeFilters: appState.pipelineAttributeFilters,
                hideJunk: settings.hideJunkItems,
                hideSafetyFlagged: settings.hideSafetyFlagged
            )

            // Set offset for pagination
            filter.sortOrder = appState.sortOrder
            filter.shuffleSeed = appState.shuffleSeed
            filter.offset = startingOffset
            filter.limit = libraryPageSize

            let clipQueryText = MediaFilterBuilder.searchQueryText(from: appState.filterText)
            let reusableClipResults: [UUID]? = {
                guard appState.searchScope == .visual,
                      !clipQueryText.isEmpty,
                      cachedClipQuery == clipQueryText else {
                    return nil
                }
                return cachedClipResultIds
            }()

            _ = try await MediaFilterBuilder.applySearch(
                to: &filter,
                filterText: appState.filterText,
                searchScope: appState.searchScope,
                visualResultIds: reusableClipResults,
                allowVisualSearch: false
            )
            guard !Task.isCancelled, appState.mediaSelectionStore.accepts(queryToken) else { return }

            let newItems = try await store.fetchItems(
                filter: filter,
                includeMLAttributes: false,
                includePerFileOCR: false,
                includeVideoSegments: false,
                includeTranscriptSegments: false
            )
            guard !Task.isCancelled, appState.mediaSelectionStore.accepts(queryToken),
                  viewModel.paginationOffset == startingOffset else { return }
            viewModel.appendItems(newItems)
            appState.setDisplayContext(
                surface: .grid,
                items: viewModel.items,
                selectedIDs: viewModel.selectedIDs,
                anchorID: viewModel.selectionAnchor
            )
        } catch {
            logError("Failed to load more items: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    private func generatePreviewItems() -> [MediaItem] {
        // Generate varied aspect ratios for visual testing
        let aspectRatios: [CGFloat] = [
            0.5, 0.67, 0.75, 1.0, 1.0, 1.33, 1.5, 1.78, 2.0,
            0.56, 0.8, 1.2, 1.6, 0.7, 1.1, 0.9, 1.4
        ]

        return (0..<50).map { index in
            let aspectRatio = aspectRatios[index % aspectRatios.count]
            let isStarred = index % 7 == 0
            let mediaCount = index % 5 == 0 ? Int.random(in: 2...4) : 1

            return MediaItem(
                id: UUID(),
                basePath: URL(fileURLWithPath: "/tmp/\(index)"),
                metadataFile: URL(fileURLWithPath: "/tmp/\(index)/meta.md"),
                mediaFiles: (0..<mediaCount).map { i in
                    URL(fileURLWithPath: "/tmp/\(index)/media\(i).jpg")
                },
                contextImage: nil,
                metadata: MediaMetadata(
                    source: URL(string: "https://twitter.com/user/\(index)")!,
                    platform: "twitter",
                    author: "@user\(index % 10)",
                    starred: isStarred
                ),
                indexedContent: nil,
                aspectRatio: aspectRatio
            )
        }
    }
    #endif
}

// NOTE: Enter key handler has been consolidated into KeyboardShortcutManager (openDetail action)

// MARK: - Mouse Position Tracking

/// PERF: Class ref for mouse position — NOT @State / @Binding.
/// Writing @State on every mouse move causes the entire container body
/// to re-evaluate. This class stores position silently; callers read
/// it lazily in event closures (context menu, tag overlay).
final class MousePositionTracker {
    var position: CGPoint = .zero
    weak var trackingView: NSView?

    func position(fromWindowPoint point: CGPoint) -> CGPoint {
        guard let trackingView else { return position }
        let localPoint = trackingView.convert(NSPoint(x: point.x, y: point.y), from: nil)
        return CGPoint(x: localPoint.x, y: trackingView.bounds.height - localPoint.y)
    }
}

/// NSViewRepresentable that tracks mouse position without blocking clicks.
/// Writes to MousePositionTracker (class ref) to avoid @State churn.
struct MouseTrackingView: NSViewRepresentable {
    let tracker: MousePositionTracker

    func makeNSView(context: Context) -> MouseTrackingNSView {
        let view = MouseTrackingNSView()
        view.tracker = tracker
        tracker.trackingView = view
        return view
    }

    func updateNSView(_ nsView: MouseTrackingNSView, context: Context) {}
}

class MouseTrackingNSView: NSView {
    weak var tracker: MousePositionTracker?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)
        // Flip Y for SwiftUI coordinates
        let flippedY = bounds.height - locationInView.y
        tracker?.position = CGPoint(x: locationInView.x, y: flippedY)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil  // Pass through all clicks
    }
}

// MARK: - View Modifiers (extracted to help compiler)

/// Handles data loading and filter subscriptions
private struct GridDataModifier: ViewModifier {
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: MasonryGridViewModel
    let loadItems: () async -> Void
    @State private var pendingLoadTask: Task<Void, Never>?

    // Extract complex publisher to help Swift type checker
    private var filterPublisher: some Publisher<Void, Never> {
        Publishers.CombineLatest4(
            appState.$filterText.debounce(for: .milliseconds(300), scheduler: RunLoop.main),
            appState.$dateRangeFilter,
            appState.$sidebarSelection,
            appState.$activeSmartFolder
        )
        .removeDuplicates { old, new in
            old.0 == new.0 && old.1 == new.1 && old.2 == new.2 && old.3 == new.3
        }
        .dropFirst()
        .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
        .map { _ in () }  // Erase the tuple type
    }

    @MainActor
    private func requestLoad(
        debounceNanoseconds: UInt64 = 0,
        shouldScrollToTop: Bool = false
    ) {
        appState.mediaSelectionStore.invalidateQueries(from: .grid)
        viewModel.prepareReload(resetToTop: shouldScrollToTop)

        pendingLoadTask?.cancel()
        pendingLoadTask = Task { @MainActor in
            if debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }
            }

            // This task's cancel handle is only for pending debounce. Once the
            // request is admitted, later invalidations must enqueue a trailing
            // reload instead of cancelling the active fetch's task context.
            guard !Task.isCancelled else { return }
            pendingLoadTask = nil
            await viewModel.performCoalescedReload(loadItems)
        }
    }

    private func refreshVisibleItems(_ itemIDs: Set<UUID>) {
        guard let queryToken = appState.mediaSelectionStore.currentQueryToken(from: .grid),
              let store = appState.mediaStore else { return }
        viewModel.enqueueItemRefresh(itemIDs, fetch: { ids in
            guard var filter = appState.mediaSelectionStore.committedFilter else {
                return try await store.fetchItems(ids: Array(ids))
            }
            // Reuse the committed predicates so a tag/star/folder edit can leave the result.
            let scopedIDs = filter.clipResultIds.map { ids.intersection($0) } ?? ids
            guard !scopedIDs.isEmpty else { return [] }
            filter.clipResultIds = Array(scopedIDs)
            filter.offset = 0
            filter.limit = scopedIDs.count
            return try await store.fetchItems(
                filter: filter,
                includeMLAttributes: false,
                includePerFileOCR: false,
                includeVideoSegments: false,
                includeTranscriptSegments: false
            )
        }, apply: { refreshed, missingIDs in
            guard appState.mediaSelectionStore.accepts(queryToken) else { return }
            appState.replaceDisplayedItemsIfPresent(refreshed)
            viewModel.replacePendingItems(refreshed)
            if !missingIDs.isEmpty {
                viewModel.removeItems(missingIDs)
                appState.removeDisplayedItems(ids: missingIDs)
            }
        }, onFailure: {
            guard appState.mediaSelectionStore.accepts(queryToken) else { return }
            requestLoad()
        })
    }

    func body(content: Content) -> some View {
        content
            .task {
                await MainActor.run {
                    requestLoad()
                }
            }
            .overlay(alignment: .top) {
                if viewModel.pendingNewItemCount > 0 {
                    Button {
                        viewModel.applyPendingInsertions()
                    } label: {
                        Text("\(viewModel.pendingNewItemCount) new")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderless)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .accessibilityLabel("Show \(viewModel.pendingNewItemCount) new items")
                }
            }
            .onChange(of: viewModel.pendingNewItemCount) { oldCount, newCount in
                guard oldCount > 0, newCount == 0 else { return }
                appState.setDisplayContext(
                    surface: .grid,
                    items: viewModel.items,
                    selectedIDs: viewModel.selectedIDs,
                    anchorID: viewModel.selectionAnchor
                )
            }
            .onReceive(appState.mediaSelectionStore.$focusedID) { newID in
                // Follow focus set elsewhere; no-op for the click handler's own change or stale values.
                viewModel.followFocus(newID)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: Notification.Name.mediaStoreDidChange)
            ) { notification in
                if let deletedItemIds = notification.userInfo?["deletedItemIds"] as? [UUID],
                   !deletedItemIds.isEmpty {
                    withAnimation(.easeOut(duration: 0.15)) {
                        viewModel.removeItems(Set(deletedItemIds))
                        appState.removeDisplayedItems(ids: Set(deletedItemIds))
                    }
                    return
                }

                if let changedID = notification.userInfo?["itemId"] as? UUID {
                    refreshVisibleItems([changedID])
                    return
                }

                requestLoad()
            }
            .onReceive(
                appState.mediaStore?.detailedChanges ?? Empty().eraseToAnyPublisher()
            ) { change in
                switch change {
                case .items(let ids):
                    refreshVisibleItems(ids)
                    // An edit outside the loaded range may bring an item into the filter.
                    if !ids.isSubset(of: viewModel.loadedItemIDs) {
                        requestLoad(debounceNanoseconds: 300_000_000)
                    }
                case .deleted(let ids):
                    if appState.sidebarSelection == .recentlyDeleted {
                        requestLoad(debounceNanoseconds: 300_000_000)
                    } else {
                        viewModel.removeItems(ids)
                        appState.removeDisplayedItems(ids: ids)
                    }
                case .reload:
                    requestLoad(debounceNanoseconds: 300_000_000)
                }
            }
            .onReceive(filterPublisher) { _ in
                CrashTelemetry.leave("filter-changed text=\(appState.filterText.isEmpty ? "(empty)" : appState.filterText.prefix(20).description)")
                PerfLog.event("filterPublisher", category: .data, context: "filter changed")
                requestLoad(shouldScrollToTop: true)
            }
            .onReceive(appState.$colorFilters.dropFirst()) { _ in
                requestLoad(shouldScrollToTop: true)
            }
            .onReceive(appState.$colorSearchRGB.dropFirst()) { _ in
                requestLoad(shouldScrollToTop: true)
            }
            .onReceive(appState.$starredFilter.dropFirst()) { _ in
                requestLoad(shouldScrollToTop: true)
            }
            .onReceive(appState.$hasOCRFilter.dropFirst()) { _ in
                requestLoad(shouldScrollToTop: true)
            }
            .onReceive(appState.$platformFilter.dropFirst()) { _ in
                requestLoad(shouldScrollToTop: true)
            }
            .onReceive(appState.$pipelineAttributeFilters.dropFirst()) { _ in
                requestLoad(shouldScrollToTop: true)
            }
            .onReceive(appState.$searchScope.dropFirst()) { _ in
                requestLoad(shouldScrollToTop: true)
            }
            .onReceive(appState.$sortOrder.dropFirst()) { _ in
                requestLoad(shouldScrollToTop: true)
            }
            .onReceive(appState.$shuffleSeed.dropFirst()) { _ in
                requestLoad(shouldScrollToTop: true)
            }
            .onReceive(appState.$useHybridLayout) { grouped in
                viewModel.groupsSimilarAspectRatios = grouped
            }
            .onReceive(appState.$gridDensity) { newDensity in
                viewModel.updateDensity(newDensity)
            }
            .onDisappear {
                pendingLoadTask?.cancel()
                pendingLoadTask = nil
                viewModel.clearPendingLocalStoreChanges()
                viewModel.cancelItemRefreshes()
            }
    }
}

private extension AttributeFilter {
    var activeChipID: String {
        "\(module.rawValue).\(key).\(minValue).\(maxValue ?? -1)"
    }

    var activeChipLabel: String {
        switch module {
        case .scene:
            return "scene: \(key)"
        case .object:
            return "object: \(key)"
        case .bodyPose:
            return "subjects"
        case .face:
            return "faces"
        default:
            return "\(module.rawValue): \(key)"
        }
    }
}

/// Handles keyboard navigation subscriptions
private struct GridNavigationModifier: ViewModifier {
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: MasonryGridViewModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .gridNavigateDown)) { _ in
                viewModel.selectDown()
            }
            .onReceive(NotificationCenter.default.publisher(for: .gridNavigateUp)) { _ in
                viewModel.selectUp()
            }
            .onReceive(NotificationCenter.default.publisher(for: .gridNavigateLeft)) { _ in
                viewModel.selectLeft()
            }
            .onReceive(NotificationCenter.default.publisher(for: .gridNavigateRight)) { _ in
                viewModel.selectRight()
            }
            .onReceive(NotificationCenter.default.publisher(for: .gridExtendSelectionDown)) { _ in
                viewModel.extendSelectionDown()
            }
            .onReceive(NotificationCenter.default.publisher(for: .gridExtendSelectionUp)) { _ in
                viewModel.extendSelectionUp()
            }
            .onReceive(NotificationCenter.default.publisher(for: .gridExtendSelectionLeft)) { _ in
                viewModel.extendSelectionLeft()
            }
            .onReceive(NotificationCenter.default.publisher(for: .gridExtendSelectionRight)) { _ in
                viewModel.extendSelectionRight()
            }
            .onReceive(NotificationCenter.default.publisher(for: .selectAll)) { _ in
                viewModel.selectAll()
            }
            .onReceive(NotificationCenter.default.publisher(for: .deselectAll)) { _ in
                viewModel.clearSelection()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openDetail)) { _ in
                if let selectedID = viewModel.selectedItemID,
                   let item = viewModel.item(for: selectedID) {
                    appState.openSingleFocus(item)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .togglePreview)) { _ in
                if let selectedID = viewModel.selectedItemID,
                   let item = viewModel.item(for: selectedID) {
                    appState.openSingleFocus(item)
                }
            }
    }
}

// MARK: - Middle-Mouse Scrolling

enum MiddleMouseScrollPhase: Equatable {
    case idle
    case pressed(anchor: CGPoint)
    case dragging(anchor: CGPoint, lastLocation: CGPoint)
    case autoScrolling(anchor: CGPoint)
}

enum MiddleMouseScrollAction: Equatable {
    case none
    case pan(deltaX: CGFloat, deltaY: CGFloat)
    case startAutoScroll(anchor: CGPoint)
    case stopAutoScroll
    case endDrag
}

/// Pure click-versus-drag state used by the AppKit event bridge and focused tests.
struct MiddleMouseScrollStateMachine: Equatable {
    var dragThreshold: CGFloat = 6
    private(set) var phase: MiddleMouseScrollPhase = .idle

    var isIdle: Bool { phase == .idle }

    var autoScrollAnchor: CGPoint? {
        guard case .autoScrolling(let anchor) = phase else { return nil }
        return anchor
    }

    mutating func middleButtonDown(at location: CGPoint) -> MiddleMouseScrollAction {
        if case .autoScrolling = phase {
            phase = .idle
            return .stopAutoScroll
        }

        phase = .pressed(anchor: location)
        return .none
    }

    mutating func middleButtonDragged(
        to location: CGPoint,
        eventDeltaX: CGFloat,
        eventDeltaY: CGFloat
    ) -> MiddleMouseScrollAction {
        let anchor: CGPoint
        switch phase {
        case .pressed(let pressedAnchor):
            anchor = pressedAnchor
            let distance = hypot(location.x - anchor.x, location.y - anchor.y)
            guard distance >= dragThreshold else { return .none }
        case .dragging(let dragAnchor, _):
            anchor = dragAnchor
        case .idle, .autoScrolling:
            return .none
        }

        phase = .dragging(anchor: anchor, lastLocation: location)
        // Preserve the existing grab-and-drag direction: pulling down reveals earlier content.
        return .pan(deltaX: -eventDeltaX, deltaY: -eventDeltaY)
    }

    mutating func middleButtonUp(at location: CGPoint) -> MiddleMouseScrollAction {
        switch phase {
        case .pressed(let anchor):
            let distance = hypot(location.x - anchor.x, location.y - anchor.y)
            guard distance < dragThreshold else {
                phase = .idle
                return .endDrag
            }
            phase = .autoScrolling(anchor: anchor)
            return .startAutoScroll(anchor: anchor)
        case .dragging:
            phase = .idle
            return .endDrag
        case .idle, .autoScrolling:
            return .none
        }
    }

    mutating func cancel() -> MiddleMouseScrollAction {
        let wasAutoScrolling = autoScrollAnchor != nil
        phase = .idle
        return wasAutoScrolling ? .stopAutoScroll : .endDrag
    }
}

/// Browser-style velocity curve. The dead zone makes small pointer movements inert, then speed
/// rises smoothly with distance and remains capped so a stray cursor cannot fling the library.
enum MiddleMouseAutoScrollPhysics {
    static let deadZone: CGFloat = 12
    static let pointsPerSecondPerPoint: CGFloat = 7
    static let maximumPointsPerSecond: CGFloat = 1_800

    static func verticalVelocity(for displacement: CGFloat) -> CGFloat {
        guard displacement.isFinite else { return 0 }
        let magnitude = abs(displacement) - deadZone
        guard magnitude > 0 else { return 0 }

        let speed = min(maximumPointsPerSecond, magnitude * pointsPerSecondPerPoint)
        // AppKit view coordinates grow upward, while clip-view origins grow as content scrolls down.
        return displacement < 0 ? speed : -speed
    }

    static func contentDelta(verticalDisplacement: CGFloat, elapsed: TimeInterval) -> CGFloat {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return verticalVelocity(for: verticalDisplacement) * CGFloat(min(elapsed, 0.05))
    }
}

enum MiddleMouseScrollTargetPolicy {
    static func nearestEnclosingScrollView(from view: NSView) -> NSScrollView? {
        var candidate = view.superview
        while let current = candidate {
            if let scrollView = current as? NSScrollView { return scrollView }
            candidate = current.superview
        }
        return nil
    }
}

/// Transparent overlay that implements both middle-button drag-pan and click-to-autoscroll.
/// It never participates in hit testing; a local event monitor handles only button 2 and leaves
/// back/forward or other auxiliary buttons to the app-wide shortcut manager.
private struct MiddleMouseAutoScroll: NSViewRepresentable {
    var isEnabled: Bool = true
    var onViewportInput: () -> Void
    var onScrollerResolved: (LibrarySmoothScroller) -> Void
    var onViewportWillChange: (NSScrollView) -> Void
    var onViewportChanged: (CGFloat, CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> MiddleMouseAutoScrollView {
        let view = MiddleMouseAutoScrollView()
        view.isEnabled = isEnabled
        view.onViewportInput = onViewportInput
        onScrollerResolved(view.smoothScroller)
        view.onViewportWillChange = onViewportWillChange
        view.onViewportChanged = onViewportChanged
        return view
    }

    func updateNSView(_ nsView: MiddleMouseAutoScrollView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onViewportInput = onViewportInput
        onScrollerResolved(nsView.smoothScroller)
        nsView.onViewportWillChange = onViewportWillChange
        nsView.onViewportChanged = onViewportChanged
        nsView.refreshViewportObservation()
    }
}

final class MiddleMouseAutoScrollView: LibraryViewportCommandView {
    private var notificationObservers: [NSObjectProtocol] = []
    private lazy var autoScrollTicker = DisplayFrameTicker { [weak self] now in
        guard let self else { return false }
        self.autoScrollTick(at: now)
        return true
    }
    private var lastTickUptime: TimeInterval = 0
    private(set) var stateMachine = MiddleMouseScrollStateMachine()
    private var consumeMiddleSequence = false
    private weak var targetScrollView: NSScrollView?
    private var visibleAnchor: CGPoint?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tearDownMonitoring()
        guard let window else { return }

        let center = NotificationCenter.default
        for name in [
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification
        ] {
            notificationObservers.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.cancelInteraction()
                }
            )
        }
        notificationObservers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.cancelInteraction()
            }
        )
    }

    deinit {
        tearDownMonitoring()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let anchor = visibleAnchor else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let markerRect = NSRect(x: anchor.x - 14, y: anchor.y - 14, width: 28, height: 28)
        let marker = NSBezierPath(ovalIn: markerRect)
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        marker.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        marker.lineWidth = 2
        marker.stroke()

        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: anchor.x, y: anchor.y - 7))
        stem.line(to: NSPoint(x: anchor.x, y: anchor.y + 7))
        stem.lineWidth = 1.8
        NSColor.labelColor.setStroke()
        stem.stroke()

        let arrows = NSBezierPath()
        arrows.move(to: NSPoint(x: anchor.x - 3.5, y: anchor.y + 4))
        arrows.line(to: NSPoint(x: anchor.x, y: anchor.y + 8))
        arrows.line(to: NSPoint(x: anchor.x + 3.5, y: anchor.y + 4))
        arrows.move(to: NSPoint(x: anchor.x - 3.5, y: anchor.y - 4))
        arrows.line(to: NSPoint(x: anchor.x, y: anchor.y - 8))
        arrows.line(to: NSPoint(x: anchor.x + 3.5, y: anchor.y - 4))
        arrows.lineWidth = 1.8
        arrows.stroke()
    }

    override func handleInteractionEvent(_ event: NSEvent) -> NSEvent? {
        guard isEnabled, window != nil, event.window === window, !isHiddenOrHasHiddenAncestor else { return event }

        if event.type == .keyDown {
            guard event.keyCode == 53, !stateMachine.isIdle else { return event }
            cancelInteraction()
            return nil
        }

        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .scrollWheel {
            if !stateMachine.isIdle {
                cancelInteraction()
            }
            return event
        }

        // Do not consume mouse back/forward or manufacturer-specific auxiliary buttons.
        guard event.buttonNumber == 2 else { return event }

        let location = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .otherMouseDown:
            if stateMachine.autoScrollAnchor != nil {
                consumeMiddleSequence = true
                execute(stateMachine.middleButtonDown(at: location))
                return nil
            }

            guard visibleRect.contains(location),
                  let scrollView = scrollView(at: event.locationInWindow) else {
                return event
            }
            targetScrollView = scrollView
            smoothScroller.cancel()
            consumeMiddleSequence = true
            execute(stateMachine.middleButtonDown(at: location))
            return nil

        case .otherMouseDragged:
            guard consumeMiddleSequence else { return event }
            execute(
                stateMachine.middleButtonDragged(
                    to: location,
                    eventDeltaX: event.deltaX,
                    eventDeltaY: event.deltaY
                )
            )
            return nil

        case .otherMouseUp:
            guard consumeMiddleSequence else { return event }
            execute(stateMachine.middleButtonUp(at: location))
            consumeMiddleSequence = false
            return nil

        default:
            return event
        }
    }

    override func prepareForViewportCommand() {
        cancelInteraction()
    }

    private func execute(_ action: MiddleMouseScrollAction) {
        switch action {
        case .none:
            break
        case .pan(let deltaX, let deltaY):
            panContent(deltaX: deltaX, deltaY: deltaY)
        case .startAutoScroll(let anchor):
            visibleAnchor = anchor
            needsDisplay = true
            startAutoScrollTicker()
            PerfLog.event("middleAutoScrollStarted", category: .scroll)
        case .stopAutoScroll, .endDrag:
            stopAutoScroll(clearTarget: true)
        }
    }

    private func startAutoScrollTicker() {
        lastTickUptime = ProcessInfo.processInfo.systemUptime
        autoScrollTicker.start(on: self)
    }

    private func autoScrollTick(at now: TimeInterval) {
        guard let window else { return }
        autoScrollTick(at: now, pointer: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    func autoScrollTick(at now: TimeInterval, pointer: CGPoint) {
        guard isEnabled, let window,
              let anchor = stateMachine.autoScrollAnchor,
              let targetScrollView, targetScrollView.window === window,
              !isHiddenOrHasHiddenAncestor else {
            cancelInteraction()
            return
        }

        defer { lastTickUptime = now }
        let delta = MiddleMouseAutoScrollPhysics.contentDelta(
            verticalDisplacement: pointer.y - anchor.y,
            elapsed: now - lastTickUptime
        )
        guard delta != 0 else { return }
        panContent(deltaX: 0, deltaY: delta)
    }

    #if DEBUG
    func pauseAutoScrollTickerForBenchmark() {
        autoScrollTicker.stop()
    }
    #endif

    private func panContent(deltaX: CGFloat, deltaY: CGFloat) {
        guard let scrollView = targetScrollView else { return }
        let clipView = scrollView.contentView
        var proposedBounds = clipView.bounds
        proposedBounds.origin.x += deltaX
        proposedBounds.origin.y += deltaY
        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        guard constrainedBounds.origin != clipView.bounds.origin else { return }
        clipView.scroll(to: constrainedBounds.origin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func scrollView(at locationInWindow: NSPoint) -> NSScrollView? {
        guard let scrollView = resolveLibraryScrollView() else { return nil }
        let point = scrollView.convert(locationInWindow, from: nil)
        return scrollView.bounds.contains(point) ? scrollView : nil
    }

    private func cancelInteraction() {
        execute(stateMachine.cancel())
        consumeMiddleSequence = false
    }

    private func stopAutoScroll(clearTarget: Bool) {
        autoScrollTicker.stop()
        visibleAnchor = nil
        needsDisplay = true
        if clearTarget {
            targetScrollView = nil
        }
    }

    private func tearDownMonitoring() {
        cancelInteraction()
        let center = NotificationCenter.default
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }
}

// MARK: - Grid Modifier Key Handler

/// NSViewRepresentable for detecting modifier key (Option/Alt) presses in the grid.
/// When the modifier is held and items are selected, triggers the tag overlay.
private struct GridModifierKeyHandler: NSViewRepresentable {
    let hasSelection: Bool
    let onModifierChanged: (Bool) -> Void
    var modifierKey: TagSettings.ModifierKey = .option

    func makeNSView(context: Context) -> GridModifierKeyView {
        let view = GridModifierKeyView()
        view.modifierFlag = modifierKey.eventFlag
        view.onModifierChanged = onModifierChanged
        view.hasSelection = hasSelection
        return view
    }

    func updateNSView(_ nsView: GridModifierKeyView, context: Context) {
        nsView.modifierFlag = modifierKey.eventFlag
        nsView.onModifierChanged = onModifierChanged
        nsView.hasSelection = hasSelection
    }
}

private class GridModifierKeyView: NSView {
    var hasSelection: Bool = false {
        didSet { modifierHoldGate.refresh(enabled: hasSelection) }
    }
    var onModifierChanged: ((Bool) -> Void)? {
        didSet { modifierHoldGate.onStateChanged = onModifierChanged }
    }
    var modifierFlag: NSEvent.ModifierFlags = .option {
        didSet { modifierHoldGate.modifierFlag = modifierFlag }
    }
    private let modifierHoldGate = TagOverlayModifierHoldGate()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupFlagsMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupFlagsMonitor()
    }

    private var flagsMonitor: Any?
    private var refreshTimer: Timer?

    private func setupFlagsMonitor() {
        // Use local event monitor for modifier flags
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard window != nil else {
            modifierHoldGate.close(sendRelease: true)
            return
        }
        // Self-heal: flagsChanged is missed when Option is released while another
        // app/window has focus. Re-check global modifier state periodically,
        // mirroring SingleFocusKeyView.responderTimer.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.modifierHoldGate.refresh(enabled: self.hasSelection)
        }
    }

    deinit {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
        }
        refreshTimer?.invalidate()
        modifierHoldGate.close(sendRelease: true)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        modifierHoldGate.handle(modifierFlags: event.modifierFlags, enabled: hasSelection)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil  // Pass through all clicks
    }
}

// MARK: - Custom Context Menu

/// Custom-styled context menu that replaces native NSMenu.
/// Matches the app's dark theme with rounded corners and subtle shadow.
private struct CustomContextMenu: View {
    @EnvironmentObject private var appState: AppState
    let actions: MasonryCellContextActions
    let onDismiss: () -> Void

    @State private var hoveredItem: String? = nil

    private var isBatch: Bool { actions.selectedCount > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File operations group
            menuItem(
                id: "reveal",
                label: isBatch ? "Reveal All in Finder" : "Reveal in Finder",
                icon: "folder",
                action: actions.onRevealInFinder
            )
            .disabled(actions.transferContext?.isEnabled(.reveal, source: .displayed) != true)
            menuItem(
                id: "copyPath",
                label: isBatch ? "Copy All File Paths" : "Copy File Path",
                icon: "doc.on.doc",
                action: actions.onCopyPath
            )
            .disabled(actions.transferContext?.isEnabled(.copyPaths, source: .displayed) != true)
            if let context = actions.transferContext {
                menuItem(id: "transfer", label: "Transfer Source…", icon: "arrow.up.doc") {
                    MediaTransferMenuPresenter.present(context: context, appState: appState)
                }
                .disabled(MediaTransferSource.allCases.allSatisfy { (try? context.resolve($0)) == nil })
            }
            menuItem(
                id: "copyFolderPath",
                label: isBatch ? "Copy Parent Folders" : "Copy Parent Folder",
                icon: "folder",
                action: actions.onCopyFolderPath
            )
            menuItem(
                id: "copyURL",
                label: isBatch ? "Copy All Source URLs" : "Copy Source URL",
                icon: "link",
                action: actions.onCopySourceURL
            )

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 4)

            // Metadata group
            menuItem(
                id: "star",
                label: isBatch ? "Star All" : (actions.isStarred ? "Unstar" : "Star"),
                icon: isBatch ? "star.fill" : (actions.isStarred ? "star.slash" : "star.fill"),
                action: actions.onToggleStar
            )
            menuItem(
                id: "tag",
                label: "Add Tag...",
                icon: "tag",
                action: actions.onAddTag
            )
            if isBatch, let onCombineItems = actions.onCombineItems {
                menuItem(
                    id: "combine",
                    label: "Combine \(actions.selectedCount) Items",
                    icon: "square.stack.3d.down.forward",
                    action: onCombineItems
                )
            }
            if FeatureFlags.boards {
                menuItem(
                    id: "board",
                    label: isBatch ? "Add \(actions.selectedCount) to Board..." : "Add to Board...",
                    icon: "rectangle.stack",
                    action: actions.onAddToBoard
                )
            }
            // Issue #1: Add to Canvas option
            if FeatureFlags.canvas {
                menuItem(
                    id: "canvas",
                    label: isBatch ? "Add \(actions.selectedCount) to Canvas..." : "Add to Canvas...",
                    icon: "square.grid.3x3",
                    action: actions.onAddToCanvas
                )
            }

            // Find Similar Colors - only show if item has color data
            if !actions.dominantColors.isEmpty && !isBatch {
                menuItem(
                    id: "findColors",
                    label: "Find Similar Colors",
                    icon: "paintpalette",
                    action: actions.onFindSimilarColors
                )
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 4)

            // Export group
            menuItem(
                id: "export",
                label: isBatch ? "Export \(actions.selectedCount) with Metadata..." : "Export with Metadata...",
                icon: "square.and.arrow.up",
                action: actions.onExportWithMetadata
            )
            .disabled(actions.transferContext?.isEnabled(.exportMetadata, source: .downloaded) != true)

            // Rediscover (FSRS) action
            if FeatureFlags.rediscover {
                menuItem(
                    id: "rediscover",
                    label: isBatch ? "Add \(actions.selectedCount) to Rediscover" : "Add to Rediscover",
                    icon: "arrow.clockwise.circle",
                    action: actions.onAddToRediscover
                )
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 4)

            // External actions group
            menuItem(
                id: "openSource",
                label: isBatch ? "Open All Sources" : "Open Source",
                icon: "safari",
                action: actions.onOpenSource
            )
            menuItem(
                id: "delete",
                label: isBatch ? "Delete \(actions.selectedCount) Items" : "Delete",
                icon: "trash",
                isDestructive: true,
                action: actions.onDelete
            )
        }
        .padding(.vertical, 6)
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: 0x1a1a1a).opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 6)
        .keyboardMenu(selected: $hoveredItem, dismiss: onDismiss)
    }

    @ViewBuilder
    private func menuItem(
        id: String,
        label: String,
        icon: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            KeyboardMenuFocus.release()
            onDismiss()
            DispatchQueue.main.async { action() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 16)
                    .foregroundStyle(
                        isDestructive ? Color.red : (hoveredItem == id ? .white : Color.white.opacity(0.85))
                    )

                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(
                        isDestructive ? Color.red : (hoveredItem == id ? .white : Color.white.opacity(0.85))
                    )

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(hoveredItem == id ? Color.white.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            if isHovered { hoveredItem = id }
        }
        .keyboardMenuItem(id) {
            onDismiss()
            DispatchQueue.main.async { action() }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct MasonryGrid_Previews: PreviewProvider {
    static var previews: some View {
        MasonryGridContainer()
            .environmentObject(AppState())
            .frame(width: 1200, height: 800)
            .background(Color(hex: 0x1a1a1a))
    }
}
#endif
