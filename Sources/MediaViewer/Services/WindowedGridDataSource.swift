import Foundation
import Combine
import GRDB

// MARK: - WindowedGridDataSource

/// Data source that loads media items in windows for virtualized grid display.
/// Prevents loading all items into memory - only maintains 200-500 items at a time.
/// Uses cursor-based pagination with debounced scroll handling.
@MainActor
final class WindowedGridDataSource: ObservableObject {

    // MARK: - Published State

    /// Currently loaded items within the window
    @Published private(set) var windowedItems: [MediaItem] = []

    /// Whether a fetch is currently in progress
    @Published private(set) var isLoading: Bool = false

    /// Total count of items matching current filter (for scroll indicators)
    @Published private(set) var totalCount: Int = 0

    /// Current window offset (first item index in total set)
    @Published private(set) var windowOffset: Int = 0

    // MARK: - Configuration

    /// Number of items to keep in the window
    let windowSize: Int

    /// Buffer items to load beyond visible area
    let bufferSize: Int

    /// Debounce interval for scroll updates (milliseconds)
    let debounceMs: Int

    // MARK: - Dependencies

    private let mediaStore: MediaStore
    private let heightIndex: MasonryHeightIndex

    // MARK: - Private State

    /// Current filter state
    private var currentFilter: FilterState = .all

    /// In-flight fetch task (cancelled on rapid scroll)
    private var fetchTask: Task<Void, Never>?

    /// Observation cancellable for GRDB changes
    private var observationCancellable: AnyCancellable?

    /// Last scroll offset for change detection
    private var lastScrollOffset: CGFloat = 0

    /// All items for in-memory windowing (when items are pre-loaded)
    private var allItems: [MediaItem] = []

    /// Minimum scroll delta to trigger window update
    private let scrollThreshold: CGFloat = 50

    // MARK: - Initialization

    init(
        mediaStore: MediaStore,
        heightIndex: MasonryHeightIndex,
        windowSize: Int = 500,
        bufferSize: Int = 100,
        debounceMs: Int = 100
    ) {
        self.mediaStore = mediaStore
        self.heightIndex = heightIndex
        self.windowSize = windowSize
        self.bufferSize = bufferSize
        self.debounceMs = debounceMs
    }

    /// Convenience initializer with default dependencies
    convenience init(windowSize: Int = 500, bufferSize: Int = 100, debounceMs: Int = 100) {
        self.init(
            mediaStore: MediaStore(),
            heightIndex: MasonryHeightIndex(),
            windowSize: windowSize,
            bufferSize: bufferSize,
            debounceMs: debounceMs
        )
    }

    // MARK: - Public API

    /// Load from pre-fetched items (in-memory windowing).
    /// Items are stored locally for window slicing; no database fetch needed.
    /// - Parameter items: Full array of pre-loaded items
    func loadInitial(items: [MediaItem]) {
        allItems = items
        totalCount = items.count
        windowOffset = 0
        windowedItems = Array(items.prefix(windowSize))
    }

    /// Slide the in-memory window based on scroll position.
    /// Only used when items were loaded via `loadInitial(items:)`.
    func slideWindow(to estimatedIndex: Int) {
        guard !allItems.isEmpty else { return }

        let center = max(0, min(estimatedIndex, allItems.count - 1))
        let halfWindow = windowSize / 2
        let start = max(0, center - halfWindow)
        let end = min(allItems.count, start + windowSize)

        // Only update if window moved significantly
        guard abs(start - windowOffset) > bufferSize / 2 else { return }

        windowOffset = start
        windowedItems = Array(allItems[start..<end])
    }

    /// Load initial window with given filter.
    /// Resets window to beginning.
    func loadInitial(filter: FilterState = .all) async {
        currentFilter = filter
        windowOffset = 0

        // Cancel any in-flight fetch
        fetchTask?.cancel()

        isLoading = true
        defer { isLoading = false }

        do {
            // Get total count first
            totalCount = try await mediaStore.countItems(filter: filter)

            // Load initial window
            var fetchFilter = filter
            fetchFilter.limit = windowSize
            fetchFilter.offset = 0

            let items = try await mediaStore.fetchItems(filter: fetchFilter)
            windowedItems = items

            // Rebuild height index
            let indexItems = items.map { ($0.id, $0.effectiveAspectRatio) }
            await heightIndex.rebuildAsync(items: indexItems, columnCount: heightIndex.columnCount, columnWidth: heightIndex.columnWidth)

            windowOffset = 0
        } catch {
            logError("WindowedGridDataSource: failed to load initial items: \(error)")
            windowedItems = []
            totalCount = 0
        }
    }

    /// Handle scroll offset changes.
    /// Debounces rapid scrolling and loads new windows as needed.
    func onScroll(offset: CGFloat, viewportHeight: CGFloat) {
        // Skip small movements
        guard abs(offset - lastScrollOffset) > scrollThreshold else { return }
        lastScrollOffset = offset

        // Cancel previous fetch
        fetchTask?.cancel()

        // Schedule new fetch with debounce
        fetchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(debounceMs))
            } catch {
                return  // Cancelled
            }

            guard !Task.isCancelled else { return }

            await updateWindow(scrollOffset: offset, viewportHeight: viewportHeight)
        }
    }

    /// Load a specific window range.
    /// - Parameters:
    ///   - from: Starting index
    ///   - to: Ending index (exclusive)
    func loadWindow(from: Int, to: Int) async {
        let clampedFrom = max(0, from)
        let clampedTo = min(to, totalCount)

        guard clampedFrom < clampedTo else { return }

        // Calculate if we need to load more
        let currentEnd = windowOffset + windowedItems.count
        let needsNewWindow = clampedFrom < windowOffset ||
                            clampedTo > currentEnd ||
                            clampedFrom > windowOffset + bufferSize

        guard needsNewWindow else { return }

        isLoading = true
        defer { isLoading = false }

        // Calculate new window centered on requested range
        let requestedCenter = (clampedFrom + clampedTo) / 2
        let newOffset = max(0, requestedCenter - windowSize / 2)

        var fetchFilter = currentFilter
        fetchFilter.limit = windowSize
        fetchFilter.offset = newOffset

        do {
            let items = try await mediaStore.fetchItems(filter: fetchFilter)

            // Only update if not cancelled
            guard !Task.isCancelled else { return }

            let previousOffset = windowOffset
            windowedItems = items
            windowOffset = newOffset

            // Update height index if needed
            // Only rebuild if offset changed significantly
            if abs(newOffset - previousOffset) > bufferSize {
                let indexItems = items.map { ($0.id, $0.effectiveAspectRatio) }
                await heightIndex.rebuildAsync(items: indexItems, columnCount: heightIndex.columnCount, columnWidth: heightIndex.columnWidth)
            }
        } catch {
            logError("WindowedGridDataSource: failed to load window: \(error)")
        }
    }

    /// Update filter and reload.
    func updateFilter(_ filter: FilterState) async {
        await loadInitial(filter: filter)
    }

    /// Refresh current window (e.g., after database change notification).
    func refresh() async {
        await loadInitial(filter: currentFilter)
    }

    /// Update height index configuration when layout changes.
    func updateLayoutConfiguration(columnCount: Int, columnWidth: CGFloat) async {
        heightIndex.updateConfiguration(columnCount: columnCount, columnWidth: columnWidth)

        // Rebuild index with current items
        let indexItems = windowedItems.map { ($0.id, $0.effectiveAspectRatio) }
        await heightIndex.rebuildAsync(items: indexItems, columnCount: columnCount, columnWidth: columnWidth)
    }

    // MARK: - GRDB Observation

    /// Start observing database changes for current filter.
    /// Automatically refreshes window when underlying data changes.
    func startObserving() async {
        // Cancel existing observation
        observationCancellable?.cancel()

        do {
            let publisher = try await mediaStore.observeCount(filter: currentFilter)
            observationCancellable = publisher
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            logError("WindowedGridDataSource: observation error: \(error)")
                        }
                    },
                    receiveValue: { [weak self] count in
                        Task { @MainActor in
                            self?.handleObservationCountUpdate(count)
                        }
                    }
                )
        } catch {
            logError("WindowedGridDataSource: failed to start observation: \(error)")
        }
    }

    /// Stop observing database changes.
    func stopObserving() {
        observationCancellable?.cancel()
        observationCancellable = nil
    }

    // MARK: - Private

    private func updateWindow(scrollOffset: CGFloat, viewportHeight: CGFloat) async {
        // Use height index to find visible range
        guard let firstVisible = heightIndex.firstVisibleItem(forScrollOffset: abs(scrollOffset)) else {
            return
        }

        // Estimate item index from column position
        // This is approximate since items are distributed across columns
        let estimatedIndex = firstVisible.index * heightIndex.columnCount + firstVisible.column

        // Calculate range with buffer
        let visibleItemCount = Int(viewportHeight / 200) * heightIndex.columnCount  // Rough estimate
        let rangeStart = max(0, estimatedIndex - bufferSize)
        let rangeEnd = min(totalCount, estimatedIndex + visibleItemCount + bufferSize)

        await loadWindow(from: rangeStart, to: rangeEnd)
    }

    private func handleObservationCountUpdate(_ newCount: Int) {
        if newCount != totalCount {
            totalCount = newCount
            // Refresh current window when count changes.
            Task {
                await loadWindow(from: windowOffset, to: windowOffset + windowSize)
            }
        }
    }
}

// MARK: - Convenience

extension WindowedGridDataSource {

    /// Check if an index is within the current window.
    func isInWindow(_ index: Int) -> Bool {
        index >= windowOffset && index < windowOffset + windowedItems.count
    }

    /// Get item at global index, if in window.
    func item(at globalIndex: Int) -> MediaItem? {
        guard isInWindow(globalIndex) else { return nil }
        let localIndex = globalIndex - windowOffset
        guard localIndex >= 0, localIndex < windowedItems.count else { return nil }
        return windowedItems[localIndex]
    }

    /// Convert global index to window-local index.
    func localIndex(for globalIndex: Int) -> Int? {
        guard isInWindow(globalIndex) else { return nil }
        return globalIndex - windowOffset
    }

    /// Get the height index for layout calculations.
    var masonry: MasonryHeightIndex {
        heightIndex
    }
}
