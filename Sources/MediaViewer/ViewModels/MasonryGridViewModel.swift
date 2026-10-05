import Foundation
import SwiftUI
import Combine
import os.signpost

enum MasonryGridLocalStarMutationOutcome {
    case updated(MediaItem)
    case removed
    case notPresent
}

typealias MasonryGridWindowObservationProvider = @MainActor (
    _ offset: Int,
    _ limit: Int,
    _ filter: FilterState
) async throws -> AnyPublisher<[MediaItem], Error>

// MARK: - MasonryGridViewModel

/// Observable state manager for the masonry grid view.
/// Handles item loading, column distribution, selection, and keyboard navigation.
/// Supports GRDB ValueObservation for live UI updates when database changes.
@MainActor
final class MasonryGridViewModel: ObservableObject {
    /// Keep the first render bounded to the same working set that ImageCache warms.
    /// Additional items continue to arrive through the existing infinite-scroll path.
    static let pageSize = 240

    // MARK: - Published State

    /// All items to display
    private(set) var items: [MediaItem] {
        get { selectionStore.items }
        set { selectionStore.replaceItems(newValue) }
    }

    /// Items available to the grid's viewport layout.
    var visibleItems: [MediaItem] { items }

    /// Items from windowed observation (when observation is active)
    private(set) var windowedItems: [MediaItem] = []

    /// Items distributed into columns for layout
    @Published private(set) var columns: [[MediaItem]] = []

    /// Exact column heights from the same shortest-column pass that distributes the items.
    /// Pinning the viewport columns to these heights keeps the scroll extent stable as tiles mount.
    @Published private(set) var columnHeights: [CGFloat] = []

    /// Deterministic diagnostics used by focused performance tests. These count logical item
    /// visits/probes, not wall-clock time, so regressions are stable across CI machines.
    private(set) var lastColumnLayoutItemVisitCount = 0
    private(set) var lastNavigationProbeCount = 0
    private(set) var lastPrefetchProbeCount = 0

    // MARK: - Windowed Observation State

    /// Cancellable for the current window observation
    private var observationCancellable: AnyCancellable?

    /// Own the asynchronous publisher-construction phase as well as the installed subscription.
    /// Cancelling only the subscription left an older `observeWindow` task free to finish later and
    /// overwrite the newer subscription.
    private var observedRefreshTask: Task<Void, Never>?
    private var latestObservedWindow: [MediaItem] = []
    private var observationInstallationTask: Task<Void, Never>?

    /// Every replacement/cancellation advances this token. Both publisher installation and values
    /// are accepted only by the generation that requested them.
    private var observationGeneration: UInt64 = 0

    /// Current observed window offset
    private var observedOffset: Int = 0

    /// Current observed window size
    private let observationWindowSize: Int = 500

    /// Threshold for recreating observation (items scrolled beyond this triggers new observation)
    private let observationRecreationThreshold: Int = 20

    /// Current filter being observed
    private var observedFilter: FilterState?

    /// Reference to MediaStore for observations (weak to avoid retain cycle)
    private weak var mediaStore: MediaStore?

    /// Narrow injection seam for deterministic observation-race tests. Production uses MediaStore.
    private var observationProvider: MasonryGridWindowObservationProvider?

    /// MediaStore.changes has no item identity. A local star action registers the one
    /// matching publisher event so the grid can skip its redundant full reload.
    private var pendingLocalStoreChangeCount = 0


    // MARK: - Memoized Hybrid Layout Filters (computed once per items change)

    /// Items with aspect ratio <= 1.4 (portrait/square) - for column layout
    private(set) var tallItems: [MediaItem] = []

    /// Items with aspect ratio > 1.4 and <= 2.8 (landscape) - for row layout
    private(set) var wideItems: [MediaItem] = []

    /// Items with aspect ratio > 2.8 (panoramic) - for thin row layout
    private(set) var veryWideItems: [MediaItem] = []

    /// Rebuild hybrid layout filter caches with single O(n) pass
    private func rebuildHybridLayoutCache() {
        var tall: [MediaItem] = []
        var wide: [MediaItem] = []
        var veryWide: [MediaItem] = []

        for item in visibleItems {
            let ar = MasonryPresentationPolicy.layoutAspectRatio(for: item)
            if ar > 2.8 {
                veryWide.append(item)
            } else if ar > 1.4 {
                wide.append(item)
            } else {
                tall.append(item)
            }
        }

        tallItems = tall
        wideItems = wide
        veryWideItems = veryWide
    }

    /// Pagination preserves the existing hybrid buckets and classifies only the appended page.
    private func appendHybridLayoutCache(_ newItems: [MediaItem]) {
        for item in newItems {
            let aspectRatio = MasonryPresentationPolicy.layoutAspectRatio(for: item)
            if aspectRatio > 2.8 {
                veryWideItems.append(item)
            } else if aspectRatio > 1.4 {
                wideItems.append(item)
            } else {
                tallItems.append(item)
            }
        }
    }

    private var selectionStore = MediaSelectionStore()
    private var selectionStoreCancellable: AnyCancellable?
    private var recordChangeCancellable: AnyCancellable?
    private var projectedCorpusGeneration = -1

    /// Stable O(1) lookup tables rebuilt only when the loaded collection changes.
    private var itemIndexByID: [UUID: Int] = [:]
    private(set) var loadedItemIDs: Set<UUID> = []

    /// Currently selected item IDs (multi-select support)
    var selectedIDs: Set<UUID> {
        get { selectionStore.selectedIDs }
        set { selectionStore.selectedIDs = newValue }
    }

    /// Number of columns (derived from window width)
    @Published private(set) var columnCount: Int = 5

    /// Whether items are currently loading
    @Published private(set) var isLoading: Bool = false

    /// Whether there are more items to load (pagination)
    @Published private(set) var hasMoreItems: Bool = true

    /// Current offset for pagination
    @Published private(set) var currentOffset: Int = 0

    /// Full-grid reload state lives on this stable StateObject rather than a SwiftUI
    /// modifier value, whose reconstruction could otherwise admit overlapping fetches.
    private var isReloadInProgress = false
    private var isReloadPending = false

    /// Whether multi-select mode is active (more than 1 item selected)
    var isMultiSelectMode: Bool {
        selectedIDs.count > 1
    }

    /// Single selected item ID for compatibility (returns last selected if multiple)
    var selectedItemID: UUID? {
        get { selectionAnchor ?? selectionStore.orderedSelectedIDs.first }
        set {
            if let id = newValue {
                selectedIDs = [id]
                selectionAnchor = id
            } else {
                selectedIDs = []
                selectionAnchor = nil
            }
        }
    }

    // MARK: - Configuration

    /// Spacing between grid items
    let spacing: CGFloat = 8

    /// Base column width constraints (adjusted by density)
    private let baseMinColumnWidth: CGFloat = 150
    private let baseMaxColumnWidth: CGFloat = 400

    /// Grid density: 0.0 = compact (more columns), 1.0 = spacious (fewer columns)
    @Published var density: CGFloat = 0.5

    /// Computed min column width based on density
    var minColumnWidth: CGFloat {
        baseMinColumnWidth + (density * 100)  // 150-250
    }

    /// Computed max column width based on density
    var maxColumnWidth: CGFloat {
        baseMaxColumnWidth + (density * 150)  // 400-550
    }

    // MARK: - Private State

    /// Container width from GeometryReader - needed for accurate column distribution
    @Published private(set) var containerWidth: CGFloat = 800

    /// The rendered columns themselves are the cache. The old cache duplicated those arrays and
    /// still allocated/compared every item ID before each lookup, even though every real mutation
    /// explicitly invalidates layout.
    private var isColumnLayoutValid = false

    private struct NavigationPosition {
        let column: Int
        let row: Int
    }

    /// Navigation metadata is computed alongside column distribution. Arrow keys therefore avoid
    /// rescanning all columns and recomputing every preceding cell height on each press.
    private var navigationPositionByID: [UUID: NavigationPosition] = [:]
    private var columnItemCenterYs: [[CGFloat]] = []

    /// Anchor point for shift-click range selection
    private(set) var selectionAnchor: UUID? {
        get { selectionStore.focusedID }
        set { selectionStore.focusedID = newValue }
    }

    /// Goal Y position for sticky vertical position during horizontal navigation.
    /// When navigating left/right between columns, this remembers the Y position
    /// to find the visually closest item in adjacent columns.
    private var goalYPosition: CGFloat?

    // MARK: - Initialization

    init() {}

    /// Initialize with a MediaStore reference for observations
    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
    }

    init(observationProvider: @escaping MasonryGridWindowObservationProvider) {
        self.observationProvider = observationProvider
    }

    func setSelectionStore(_ store: MediaSelectionStore) {
        if selectionStore === store {
            if projectedCorpusGeneration != store.corpusGeneration {
                rebuildItemIndex()
                rebuildHybridLayoutCache()
                invalidateColumnCache()
                recalculateColumns()
            }
            return
        }
        selectionStore = store
        selectionStoreCancellable = store.objectWillChange.sink { [weak self, weak store] _ in
            guard store?.isUpdatingRecords != true else { return }
            self?.objectWillChange.send()
        }
        recordChangeCancellable = store.recordsChanges.sink { [weak self, weak store] records in
            guard store?.acceptsSurface(.grid) == true else { return }
            self?.replaceItemsIfPresent(records)
        }
        rebuildItemIndex()
        rebuildHybridLayoutCache()
        invalidateColumnCache()
        recalculateColumns()
        objectWillChange.send()
    }

    deinit {
        itemRefreshTask?.cancel()
        observedRefreshTask?.cancel()
        observationInstallationTask?.cancel()
        observationInstallationTask = nil
        observationCancellable?.cancel()
        observationCancellable = nil
    }

    // MARK: - Windowed Observation

    /// Start observing a window of items from the database.
    /// The observation automatically updates windowedItems when the database changes.
    ///
    /// - Parameters:
    ///   - store: MediaStore to observe from
    ///   - filter: Filter state to apply
    ///   - offset: Starting offset for the window
    func startObservation(store: MediaStore, filter: FilterState, offset: Int = 0) {
        self.mediaStore = store
        updateObservation(newOffset: offset, filter: filter, force: true)
    }

    /// Update observation when window changes significantly.
    /// Recreates the observation if the offset has moved beyond the threshold.
    ///
    /// - Parameters:
    ///   - newOffset: New offset position
    ///   - filter: Optional new filter (if nil, uses existing filter)
    ///   - force: Force recreation even if offset hasn't changed much
    func updateObservation(newOffset: Int, filter: FilterState? = nil, force: Bool = false) {
        let newOffset = max(0, newOffset)
        let effectiveFilter = filter ?? observedFilter ?? .all

        // Check if we need to recreate the observation
        let offsetDelta = abs(newOffset - observedOffset)
        let filterChanged = filter != nil && filter != observedFilter

        guard force || filterChanged || offsetDelta > observationRecreationThreshold else {
            return
        }

        // Invalidate callbacks before cancelling. A publisher already queued on DispatchQueue.main
        // may otherwise deliver once more after cancellation.
        observedRefreshTask?.cancel()
        observedRefreshTask = nil
        observationGeneration &+= 1
        let generation = observationGeneration
        observationInstallationTask?.cancel()
        observationInstallationTask = nil
        observationCancellable?.cancel()
        observationCancellable = nil

        // Update state
        observedOffset = newOffset
        observedFilter = effectiveFilter

        let makePublisher: MasonryGridWindowObservationProvider
        if let observationProvider {
            makePublisher = observationProvider
        } else if let store = mediaStore {
            makePublisher = { [weak store] offset, limit, filter in
                guard let store else { throw CancellationError() }
                return try await store.observeWindow(offset: offset, limit: limit, filter: filter)
            }
        } else {
            logWarning("Cannot update observation: MediaStore not available")
            return
        }

        let windowSize = observationWindowSize
        observationInstallationTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.observationGeneration == generation {
                    self.observationInstallationTask = nil
                }
            }
            do {
                let publisher = try await makePublisher(newOffset, windowSize, effectiveFilter)
                try Task.checkCancellation()
                guard let self, self.observationGeneration == generation else { return }

                let cancellable = publisher
                    .receive(on: DispatchQueue.main)
                    .sink(
                        receiveCompletion: { [weak self] completion in
                            guard let self, self.observationGeneration == generation else { return }
                            if case .failure(let error) = completion {
                                logError("Window observation failed: \(error)")
                            }
                        },
                        receiveValue: { [weak self] items in
                            guard let self, self.observationGeneration == generation else { return }
                            // Throttle rather than debounce, so steady background writes still land.
                            self.latestObservedWindow = items
                            guard self.observedRefreshTask == nil else { return }
                            self.observedRefreshTask = Task { @MainActor [weak self] in
                                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                                guard let self, self.observationGeneration == generation else { return }
                                self.observedRefreshTask = nil
                                let latest = self.latestObservedWindow
                                self.latestObservedWindow = []
                                self.handleWindowedItemsUpdate(latest, offset: newOffset)
                            }
                        }
                    )
                guard self.observationGeneration == generation, !Task.isCancelled else {
                    cancellable.cancel()
                    return
                }
                self.observationCancellable = cancellable
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.observationGeneration == generation else { return }
                logError("Failed to create window observation: \(error)")
            }
        }
    }

    /// Cancel the current observation (e.g., when filter changes or view disappears)
    func cancelObservation() {
        observedRefreshTask?.cancel()
        observedRefreshTask = nil
        observationGeneration &+= 1
        observationInstallationTask?.cancel()
        observationInstallationTask = nil
        observationCancellable?.cancel()
        observationCancellable = nil
        observedFilter = nil
    }

    /// Handle updates from the windowed observation
    private func handleWindowedItemsUpdate(_ newItems: [MediaItem], offset: Int) {
        guard selectionStore.acceptsSurface(.grid) else { return }
        windowedItems = newItems

        if items.isEmpty {
            // A nonzero window cannot establish the missing prefix. Keep it available to the
            // window consumer without pretending it is the complete loaded library.
            guard offset == 0 else { return }
            setItems(newItems)
            return
        }

        // Structural changes are handled by the loaded-range query. Splicing an SQL window
        // here would shift tiles above the viewport before the new-items control can hold them.
        replaceItemsIfPresent(newItems)
    }

    /// Merge only the range proven by an observed window. Partial windows never delete an
    /// unobserved suffix, and windows beyond the loaded boundary fall back to identity-only
    /// updates. If ordering drift would duplicate an ID across a splice boundary, identity-only
    /// replacement is likewise safer than corrupting the loaded sequence.
    static func mergingObservedWindow(
        _ window: [MediaItem],
        at offset: Int,
        into loaded: [MediaItem]
    ) -> [MediaItem] {
        guard !loaded.isEmpty, !window.isEmpty else { return loaded }
        guard offset >= 0, offset <= loaded.count else {
            return mergingObservedItemsByIdentity(window, into: loaded)
        }

        let replaceCount = min(window.count, loaded.count - offset)
        let replaceRange = offset..<(offset + replaceCount)
        let windowIDs = window.map(\.id)
        let uniqueWindowIDs = Set(windowIDs)

        guard uniqueWindowIDs.count == windowIDs.count else {
            return mergingObservedItemsByIdentity(window, into: loaded)
        }

        var preservedIDs = Set<UUID>()
        preservedIDs.reserveCapacity(loaded.count - replaceCount)
        for index in loaded.indices where !replaceRange.contains(index) {
            preservedIDs.insert(loaded[index].id)
        }
        guard preservedIDs.isDisjoint(with: uniqueWindowIDs) else {
            return mergingObservedItemsByIdentity(window, into: loaded)
        }

        var merged = loaded
        merged.replaceSubrange(replaceRange, with: window)
        return merged
    }

    private static func mergingObservedItemsByIdentity(
        _ window: [MediaItem],
        into loaded: [MediaItem]
    ) -> [MediaItem] {
        let replacements = Dictionary(window.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        return loaded.map { replacements[$0.id] ?? $0 }
    }

    /// Check if observation is currently active
    var isObservationActive: Bool {
        observationInstallationTask != nil || observationCancellable != nil
    }

    // MARK: - Public Methods

    /// Serialize full-grid reloads while retaining one trailing refresh when data changes
    /// during a fetch. Actor reentrancy lets another request mark the trailing refresh,
    /// but the operation itself is never run concurrently.
    func performCoalescedReload(_ operation: @escaping @MainActor () async -> Void) async {
        isReloadPending = true
        guard !isReloadInProgress else { return }

        isReloadInProgress = true
        defer { isReloadInProgress = false }

        while isReloadPending {
            isReloadPending = false
            // The caller owns debounce scheduling and can be superseded by a
            // later request. Keep an admitted fetch in an unstructured task so
            // cancellation of that caller cannot poison this operation or the
            // coalesced trailing refresh with Task.isCancelled.
            let reloadTask = Task { @MainActor in
                await operation()
            }
            await reloadTask.value
        }
    }

    /// Register a visible single-item star mutation before calling MediaStore.
    /// Returns false when the item is no longer in this grid, so the caller can
    /// leave the generic store-change reload path authoritative.
    @discardableResult
    func beginLocalStarMutation(for itemID: UUID) -> Bool {
        guard items.contains(where: { $0.id == itemID }) else { return false }
        pendingLocalStoreChangeCount += 1
        return true
    }

    /// Cancel a local mutation expectation when the store write fails.
    func cancelLocalStarMutation() {
        pendingLocalStoreChangeCount = max(0, pendingLocalStoreChangeCount - 1)
    }

    /// Consume only the matching local store event. Once the count reaches zero,
    /// subsequent events are treated as external and must reload normally.
    @discardableResult
    func consumePendingLocalStoreChange() -> Bool {
        guard pendingLocalStoreChangeCount > 0 else { return false }
        pendingLocalStoreChangeCount -= 1
        return true
    }

    /// Do not carry a local expectation across the grid leaving the hierarchy.
    func clearPendingLocalStoreChanges() {
        pendingLocalStoreChangeCount = 0
    }

    /// Update items from database query (replaces all items, resets pagination)
    func setItems(_ newItems: [MediaItem]) {
        // A full authoritative result replaces any local-event expectation. If the
        // matching store event arrives afterward, it must be allowed to reload.
        pendingLocalStoreChangeCount = 0
        CrashTelemetry.leave("vm-setItems n=\(newItems.count) cols=\(columnCount)")
        PerfLog.measure("setItems", category: .data, context: "\(newItems.count) items") {
            resetPagination()
            items = newItems
            currentOffset = newItems.count
            hasMoreItems = newItems.count >= Self.pageSize
            rebuildItemIndex()
            selectionStore.preserveVisibleIDs(loadedItemIDs)
            rebuildHybridLayoutCache()
            invalidateColumnCache()
            recalculateColumns()
        }
        CrashTelemetry.leave("vm-setItems-done")
        CrashTelemetry.flushBreadcrumbs()
    }

    /// Append more items (for pagination "Load More")
    func appendItems(_ newItems: [MediaItem]) {
        guard !newItems.isEmpty else {
            hasMoreItems = false
            return
        }

        let previousCount = items.count
        pendingReloadItems?.append(contentsOf: newItems)
        selectionStore.appendItems(newItems)
        currentOffset += newItems.count
        hasMoreItems = newItems.count >= Self.pageSize
        appendToItemIndex(newItems, startingAt: previousCount)
        appendHybridLayoutCache(newItems)

        if isColumnLayoutValid {
            appendToColumnLayout(newItems)
        } else {
            recalculateColumns()
        }
    }

    /// Optimistically remove deleted items from the currently rendered dataset.
    /// Keeps selection/caches in sync until the next authoritative reload.
    ///
    /// Batch deletion can request continuity. In that case the visual item after the selection
    /// anchor becomes the new selection, falling back to the preceding survivor at the end of the
    /// collection. This mirrors native list deletion without wrapping across terminal boundaries.
    @discardableResult
    func removeItems(_ ids: Set<UUID>, selectingSurvivor: Bool = false) -> UUID? {
        guard !ids.isEmpty else { return selectedItemID }

        let survivor = selectingSurvivor
            ? Self.selectionSurvivor(
                in: items,
                removing: ids,
                anchorID: selectionAnchor
            )
            : nil

        let anchor = topVisibleItemID
        let oldTop = anchor.flatMap { navigationPositionByID[$0] }.map {
            cellTop(column: $0.column, row: $0.row)
        }
        pendingReloadItems?.removeAll { ids.contains($0.id) }
        if let pendingReloadItems {
            pendingNewItemCount = pendingReloadItems.filter { !loadedItemIDs.contains($0.id) }.count
            if pendingNewItemCount == 0 { self.pendingReloadItems = nil }
        }
        let beforeCount = items.count
        items.removeAll { ids.contains($0.id) }
        // `items` is the shared selection store, which AppState.deleteItems has already
        // filtered on the Delete key path; the columns still hold the tiles until rebuilt here.
        let layoutHoldsRemoved = ids.contains { navigationPositionByID[$0] != nil }
        guard items.count != beforeCount || layoutHoldsRemoved else { return selectedItemID }

        windowedItems.removeAll { ids.contains($0.id) }
        selectionStore.remove(ids)
        if selectingSurvivor,
           selectionStore.selectedIDs.isEmpty,
           let survivor {
            selectionStore.select(survivor)
        }

        currentOffset = items.count
        rebuildItemIndex()
        rebuildHybridLayoutCache()
        invalidateColumnCache()
        recalculateColumns()
        if !isAtTop, !groupsSimilarAspectRatios, let anchor, let oldTop,
           let position = navigationPositionByID[anchor],
           abs(cellTop(column: position.column, row: position.row) - oldTop) > 0.5 {
            scrollAnchorToRestore = anchor
        }
        return selectedItemID
    }

    /// Stable next-then-previous deletion policy, separated for deterministic regression tests.
    static func selectionSurvivor(
        in items: [MediaItem],
        removing ids: Set<UUID>,
        anchorID: UUID?
    ) -> UUID? {
        guard !items.isEmpty, !ids.isEmpty else { return nil }

        let removedIndices = items.indices.filter { ids.contains(items[$0].id) }
        guard !removedIndices.isEmpty else { return nil }

        let anchorIndex = anchorID.flatMap { anchor in
            items.firstIndex { $0.id == anchor && ids.contains($0.id) }
        }
        let pivot = anchorIndex ?? removedIndices[0]

        for index in pivot..<items.endIndex where !ids.contains(items[index].id) {
            return items[index].id
        }

        guard pivot > items.startIndex else { return nil }
        for index in stride(from: pivot - 1, through: items.startIndex, by: -1)
        where !ids.contains(items[index].id) {
            return items[index].id
        }
        return nil
    }

    /// Apply the known result of a successful local star mutation without refetching
    /// or rebuilding the complete result set. Items that no longer satisfy the active
    /// starred filter are removed through the existing local removal path.
    @discardableResult
    func applyLocalStarMutation(
        id: UUID,
        starred: Bool,
        activeStarredFilter: Bool?
    ) -> MasonryGridLocalStarMutationOutcome {
        guard let currentItem = item(for: id) else {
            return .notPresent
        }

        if let activeStarredFilter, activeStarredFilter != starred {
            removeItems([id])
            return .removed
        }

        var updatedItem = currentItem
        updatedItem.metadata.starred = starred
        replaceItemIfPresent(updatedItem)
        return .updated(updatedItem)
    }

    /// Replace one item in-place when external processing updates a visible record.
    /// Avoids full dataset refetch/re-layout for metadata-only changes.
    func replaceItemIfPresent(_ updated: MediaItem) {
        replaceItemsIfPresent([updated])
    }

    func replaceItemsIfPresent(_ updates: [MediaItem]) {
        let known = updates.filter { itemIndexByID[$0.id] != nil }
        guard !known.isEmpty else { return }
        var updatedColumns = columns
        var changedTiles: [MediaItem] = []
        var layoutChanged = false
        for updated in known {
            guard let position = navigationPositionByID[updated.id],
                  updatedColumns.indices.contains(position.column),
                  updatedColumns[position.column].indices.contains(position.row) else { continue }
            let old = updatedColumns[position.column][position.row]
            guard !Self.sameTileContent(old, updated) else { continue }
            changedTiles.append(updated)
            layoutChanged = layoutChanged || abs(
                MasonryPresentationPolicy.layoutAspectRatio(for: old)
                    - MasonryPresentationPolicy.layoutAspectRatio(for: updated)
            ) > 0.001
            updatedColumns[position.column][position.row] = updated
        }
        selectionStore.retain(known)
        replacePendingItems(updates)
        guard !changedTiles.isEmpty else { return }
        if layoutChanged {
            let anchor = topVisibleItemID
            rebuildHybridLayoutCache()
            invalidateColumnCache()
            recalculateColumns()
            if !isAtTop && !groupsSimilarAspectRatios { scrollAnchorToRestore = anchor }
        } else {
            replaceInHybridLayoutCache(changedTiles)
            lastColumnLayoutItemVisitCount = 0
            columns = updatedColumns
        }
    }

    /// A same-shape update keeps its bucket; patch it there instead of re-sorting every loaded item.
    private func replaceInHybridLayoutCache(_ updates: [MediaItem]) {
        for item in updates {
            if let index = tallItems.firstIndex(where: { $0.id == item.id }) {
                tallItems[index] = item
            } else if let index = wideItems.firstIndex(where: { $0.id == item.id }) {
                wideItems[index] = item
            } else if let index = veryWideItems.firstIndex(where: { $0.id == item.id }) {
                veryWideItems[index] = item
            }
        }
    }

    func replacePendingItems(_ updates: [MediaItem]) {
        guard var pending = pendingReloadItems else { return }
        let byID = Dictionary(updates.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for index in pending.indices {
            if let updated = byID[pending[index].id] { pending[index] = updated }
        }
        pendingReloadItems = pending
    }

    /// Analysis payloads belong to detail; they do not invalidate a grid tile.
    static func sameTileContent(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        lhs.mediaFiles == rhs.mediaFiles && lhs.contextImage == rhs.contextImage &&
        lhs.assets == rhs.assets && lhs.prefersContextImage == rhs.prefersContextImage &&
        lhs.aspectRatio == rhs.aspectRatio && lhs.metadata.starred == rhs.metadata.starred &&
        lhs.metadata.source == rhs.metadata.source && lhs.metadata.platform == rhs.metadata.platform &&
        lhs.metadata.author == rhs.metadata.author &&
        (lhs.indexedContent?.dominantColors ?? []) == (rhs.indexedContent?.dominantColors ?? [])
    }

    var groupsSimilarAspectRatios = false
    private(set) var reloadStartsAtTop = true
    var reloadLimit: Int { reloadStartsAtTop ? Self.pageSize : max(Self.pageSize, items.count + pendingNewItemCount) }
    var paginationOffset: Int { currentOffset + pendingNewItemCount }
    @Published private(set) var pendingNewItemCount = 0
    private var pendingReloadItems: [MediaItem]?
    @Published var scrollAnchorToRestore: UUID?
    var isAtTop: Bool { currentScrollOffset >= -spacing }

    /// The keyboard layout cache shares the rendered column geometry.
    var visibleItemIDs: [UUID] {
        let top = max(0, -currentScrollOffset - spacing)
        let bottom = top + max(1, currentViewportHeight)
        var visible: [(id: UUID, top: CGFloat)] = []
        for column in columns.indices {
            guard columnItemCenterYs.indices.contains(column) else { continue }
            let centers = columnItemCenterYs[column]
            var lower = 0
            var upper = centers.count
            while lower < upper {
                let mid = (lower + upper) / 2
                let previous = mid == 0 ? CGFloat(0) : centers[mid - 1]
                // Candidate cells may straddle the top edge; begin one cell earlier.
                if previous < top { lower = mid + 1 } else { upper = mid }
            }
            var row = max(0, lower - 1)
            while row < centers.count {
                let start = cellTop(column: column, row: row)
                let height = 2 * (centers[row] - start)
                if start > bottom { break }
                if start + height >= top { visible.append((columns[column][row].id, start)) }
                row += 1
            }
        }
        return visible.sorted { $0.top < $1.top }.map(\.id)
    }

    private func cellTop(column: Int, row: Int) -> CGFloat {
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let width = (containerWidth - totalSpacing) / CGFloat(max(1, columnCount))
        let ratio = max(0.4, min(2.5, MasonryPresentationPolicy.layoutAspectRatio(for: columns[column][row])))
        return columnItemCenterYs[column][row] - width / ratio / 2
    }

    func columnViewportRange(column: Int, offset: CGFloat, height: CGFloat) -> Range<Int> {
        guard columns.indices.contains(column), columnItemCenterYs.indices.contains(column),
              offset.isFinite, height.isFinite, height > 0 else { return 0..<0 }
        let centers = columnItemCenterYs[column]
        guard centers.count == columns[column].count else { return 0..<0 }
        let top = max(0, -offset - spacing - height * 0.25)
        let bottom = max(0, -offset - spacing) + height * 1.25
        var lower = 0
        var upper = centers.count
        while lower < upper {
            let mid = (lower + upper) / 2
            let end = 2 * centers[mid] - cellTop(column: column, row: mid)
            if end < top { lower = mid + 1 } else { upper = mid }
        }
        let start = lower
        upper = centers.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if cellTop(column: column, row: mid) <= bottom { lower = mid + 1 } else { upper = mid }
        }
        return start..<lower
    }

    func columnTop(column: Int, row: Int) -> CGFloat {
        guard columns.indices.contains(column), columns[column].indices.contains(row) else { return 0 }
        return cellTop(column: column, row: row)
    }

    func revealOffset(for id: UUID, centered: Bool, viewportHeight: CGFloat) -> CGFloat? {
        guard let position = navigationPositionByID[id],
              columns.indices.contains(position.column),
              columns[position.column].indices.contains(position.row) else { return nil }
        if centered {
            return spacing + columnItemCenterYs[position.column][position.row] - viewportHeight / 2
        }
        return spacing + cellTop(column: position.column, row: position.row)
    }

    /// Search the cached column geometry, so mixed aspects and deep offsets stay aligned
    /// with the tiles about to appear rather than an estimated average row height.
    func thumbnailPrefetchItems(
        scrollOffset: CGFloat,
        viewportHeight: CGFloat,
        scrollingDown: Bool,
        limit: Int = 240
    ) -> [MediaItem] {
        lastPrefetchProbeCount = 0
        guard scrollOffset.isFinite, viewportHeight.isFinite, viewportHeight > 0,
              containerWidth.isFinite, containerWidth > spacing * CGFloat(columnCount - 1),
              columns.count == columnItemCenterYs.count, limit > 0 else { return [] }
        let top = max(0, -scrollOffset - spacing)
        let bottom = top + viewportHeight
        let lowerY = max(0, top - viewportHeight * (scrollingDown ? 0.25 : 0.75))
        let upperY = bottom + viewportHeight * (scrollingDown ? 0.75 : 0.25)
        var candidates: [(item: MediaItem, priority: Int, distance: CGFloat)] = []
        for column in columns.indices {
            let centers = columnItemCenterYs[column]
            guard centers.count == columns[column].count else { return [] }
            var lower = 0
            var upper = centers.count
            while lower < upper {
                lastPrefetchProbeCount += 1
                let mid = (lower + upper) / 2
                let end = 2 * centers[mid] - cellTop(column: column, row: mid)
                if end < lowerY { lower = mid + 1 } else { upper = mid }
            }
            var row = lower
            while row < centers.count {
                lastPrefetchProbeCount += 1
                let start = cellTop(column: column, row: row)
                if start > upperY { break }
                let end = 2 * centers[row] - start
                let isVisible = end >= top && start <= bottom
                let isAhead = scrollingDown ? start > bottom : end < top
                candidates.append((columns[column][row], isVisible ? 0 : (isAhead ? 1 : 2),
                    abs(centers[row] - (top + bottom) / 2)))
                row += 1
            }
        }
        return candidates.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.distance < $1.distance
        }.prefix(min(240, limit)).map(\.item)
    }

    var topVisibleItemID: UUID? { visibleItemIDs.first }

    func prepareReload(resetToTop: Bool) {
        if resetToTop {
            reloadStartsAtTop = true
            pendingReloadItems = nil
            pendingNewItemCount = 0
        }
        cancelItemRefreshes()
    }

    func applyReload(_ fetched: [MediaItem], resetToTop: Bool = false) {
        let requestedLimit = resetToTop ? Self.pageSize : max(Self.pageSize, items.count + pendingNewItemCount)
        let wasMore = hasMoreItems
        reloadStartsAtTop = false
        if resetToTop || items.isEmpty {
            pendingReloadItems = nil
            pendingNewItemCount = 0
            setItems(fetched)
            shouldScrollToTop = resetToTop
            return
        }
        let incomingIDs = Set(fetched.map(\.id))
        let inserted = fetched.filter { !loadedItemIDs.contains($0.id) }
        // A bounded prefix with insertions evicts the same number of loaded tail records.
        // Retain that proven suffix so live captures cannot shorten the loaded range.
        let evictedTail = items.suffix(inserted.count).filter { !incomingIDs.contains($0.id) }
        let refreshed = fetched + evictedTail
        let lastVisible = visibleItemIDs.compactMap { itemIndexByID[$0] }.max() ?? 0
        let lastVisibleID = items.indices.contains(lastVisible) ? items[lastVisible].id : nil
        let boundary = lastVisibleID.flatMap { id in refreshed.firstIndex { $0.id == id } } ?? 0
        let insertsBeforeViewportEnd = refreshed.prefix(boundary + 1).contains { !loadedItemIDs.contains($0.id) }
        // Grouped rows have separate layout geometry; hold their insertions until requested.
        if !isAtTop && !inserted.isEmpty && (groupsSimilarAspectRatios || insertsBeforeViewportEnd) {
            pendingReloadItems = refreshed
            pendingNewItemCount = inserted.count
            replaceItemsIfPresent(refreshed)
            return
        }
        pendingReloadItems = nil
        pendingNewItemCount = 0
        applyLoadedRange(refreshed)
        hasMoreItems = fetched.count >= requestedLimit && wasMore
    }

    private func applyLoadedRange(_ refreshed: [MediaItem]) {
        if refreshed.map(\.id) == items.map(\.id) {
            replaceItemsIfPresent(refreshed)
            return
        }
        let anchor = topVisibleItemID
        let oldTop = anchor.flatMap { navigationPositionByID[$0] }.map {
            cellTop(column: $0.column, row: $0.row)
        }
        items = refreshed
        currentOffset = refreshed.count
        rebuildItemIndex()
        selectionStore.preserveVisibleIDs(loadedItemIDs)
        rebuildHybridLayoutCache()
        invalidateColumnCache()
        recalculateColumns()
        if !isAtTop, !groupsSimilarAspectRatios, let anchor, let oldTop,
           let position = navigationPositionByID[anchor],
           abs(cellTop(column: position.column, row: position.row) - oldTop) > 0.5 {
            scrollAnchorToRestore = anchor
        }
    }

    func applyPendingInsertions() {
        guard let pendingReloadItems else { return }
        self.pendingReloadItems = nil
        pendingNewItemCount = 0
        applyLoadedRange(pendingReloadItems)
        scrollAnchorToRestore = nil
        shouldScrollToTop = true
    }

    private var pendingRefreshIDs: Set<UUID> = []
    private var itemRefreshTask: Task<Void, Never>?
    private var itemRefreshGeneration = 0

    func enqueueItemRefresh(
        _ ids: Set<UUID>,
        fetch: @escaping @MainActor (Set<UUID>) async throws -> [MediaItem],
        apply: @escaping @MainActor ([MediaItem], Set<UUID>) -> Void,
        onFailure: @escaping @MainActor () -> Void
    ) {
        let refreshableIDs = loadedItemIDs.union(pendingReloadItems?.map(\.id) ?? [])
        pendingRefreshIDs.formUnion(ids.intersection(refreshableIDs))
        guard !pendingRefreshIDs.isEmpty, itemRefreshTask == nil else { return }
        let generation = itemRefreshGeneration
        itemRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                guard let self, generation == self.itemRefreshGeneration else { return }
                let ids = self.pendingRefreshIDs
                self.pendingRefreshIDs = []
                self.itemRefreshTask = nil
                let refreshed = try await fetch(ids)
                guard generation == self.itemRefreshGeneration else { return }
                apply(refreshed, ids.subtracting(refreshed.map(\.id)))
            } catch {
                guard !Task.isCancelled, self?.itemRefreshGeneration == generation else { return }
                self?.itemRefreshTask = nil
                onFailure()
            }
        }
    }

    func cancelItemRefreshes() {
        itemRefreshGeneration += 1
        itemRefreshTask?.cancel()
        itemRefreshTask = nil
        pendingRefreshIDs = []
    }

    func containsItem(_ id: UUID) -> Bool {
        itemIndexByID[id] != nil
    }

    func item(for id: UUID) -> MediaItem? {
        guard let index = itemIndexByID[id], items.indices.contains(index) else { return nil }
        return items[index]
    }

    private func rebuildItemIndex() {
        projectedCorpusGeneration = selectionStore.corpusGeneration
        var indexByID: [UUID: Int] = [:]
        var ids = Set<UUID>()
        indexByID.reserveCapacity(items.count)
        ids.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            indexByID[item.id] = index
            ids.insert(item.id)
        }
        itemIndexByID = indexByID
        loadedItemIDs = ids
    }

    private func appendToItemIndex(_ newItems: [MediaItem], startingAt startIndex: Int) {
        itemIndexByID.reserveCapacity(startIndex + newItems.count)
        loadedItemIDs.reserveCapacity(startIndex + newItems.count)
        for (offset, item) in newItems.enumerated() {
            itemIndexByID[item.id] = startIndex + offset
            loadedItemIDs.insert(item.id)
        }
    }

    /// Reset pagination state (call when filters change)
    func resetPagination() {
        currentOffset = 0
        hasMoreItems = true
    }

    /// Set container width from GeometryReader for accurate position calculations
    /// This is the single point where column recalculation happens after width/column changes.
    /// Called after setColumnCount in commitWidthChange pattern.
    func setContainerWidth(_ width: CGFloat) {
        let widthChanged = abs(width - containerWidth) > 1
        let cacheInvalid = !isColumnLayoutValid

        if widthChanged {
            containerWidth = width
            invalidateColumnCache()
        }

        // Recalculate if width changed OR if cache was already invalidated (by setColumnCount)
        if widthChanged || cacheInvalid {
            recalculateColumns()
        }
    }

    /// Update column count based on available width
    /// Set column count directly (must match the visual layout's column count)
    /// Use this instead of updateColumnCount to ensure ViewModel matches Layout exactly
    /// NOTE: This only invalidates cache - recalculation happens in setContainerWidth
    /// to avoid double recalc when both are called together (commitWidthChange pattern)
    func setColumnCount(_ count: Int) {
        let newCount = max(2, min(count, 8))
        if newCount != columnCount {
            columnCount = newCount
            invalidateColumnCache()
            // Don't recalculate here - setContainerWidth will do it
            // This prevents double recalculation in commitWidthChange()
        }
    }

    func updateColumnCount(for width: CGFloat) {
        guard width > 0 else { return }
        lastKnownWidth = width

        // Calculate optimal column count based on width constraints
        let idealCount = max(1, Int(width / ((minColumnWidth + maxColumnWidth) / 2)))
        let newCount = max(2, min(idealCount, 8)) // Clamp between 2-8 columns

        if newCount != columnCount {
            columnCount = newCount
            invalidateColumnCache()
            recalculateColumns()
        }
    }

    /// Last known width for recalculating on density change
    private var lastKnownWidth: CGFloat = 0

    /// Update grid density. DensePackingLayout handles visual layout;
    /// columns are only used for keyboard navigation and don't change with density.
    func updateDensity(_ newDensity: CGFloat) {
        density = max(0, min(1, newDensity))
        // Note: Don't recalculate columns here - DensePackingLayout handles visual layout,
        // and keyboard navigation columns only depend on items, not density.
    }

    /// Current scroll position (updated from MasonryGrid scroll tracking)
    private(set) var currentScrollOffset: CGFloat = 0
    private(set) var currentViewportHeight: CGFloat = 0

    /// Update scroll position from view layer.
    /// Used for prefetch coordination and future windowing.
    func updateScrollPosition(offset: CGFloat, viewportHeight: CGFloat) {
        currentScrollOffset = offset
        currentViewportHeight = viewportHeight
        if isAtTop { applyPendingInsertions() }
    }

    /// Tracks whether the last selection change should trigger scroll-to-selection.
    /// Set to true for keyboard navigation, false for mouse clicks.
    @Published var shouldScrollToSelection: Bool = false

    /// Tracks whether the grid should scroll to top (e.g., after filter change).
    /// Set to true when filter changes, consumed by ScrollViewReader.
    @Published var shouldScrollToTop: Bool = false

    /// FIX: Tracks whether grid should scroll to selection when returning from focus view.
    /// Set by MasonryGridContainer when focusedItem becomes nil.
    @Published var shouldScrollToSelectionOnFocusReturn: Bool = false

    /// Select an item by ID (simple click - replaces selection)
    /// - Parameters:
    ///   - itemID: Item to select, or nil to clear selection
    ///   - preserveGoalY: If true, keeps goalYPosition for horizontal navigation continuity
    ///   - scrollToSelection: If true, triggers scroll-to-selection animation
    func select(_ itemID: UUID?, preserveGoalY: Bool = false, scrollToSelection: Bool = false) {
        // Clear goal Y on explicit selection (click or direct select)
        // unless we're in the middle of horizontal navigation
        if !preserveGoalY {
            goalYPosition = nil
        }
        shouldScrollToSelection = scrollToSelection
        if let id = itemID {
            selectionStore.select(id)
        } else {
            selectionStore.clear()
        }
    }

    /// Mirrors a delivered `$focusedID` value into the grid selection. Deliveries arrive after the
    /// change, so a value the store has already moved past is stale; re-applying it re-emits the
    /// older focus and two queued values select each other forever (100% CPU after choosing a tag
    /// from detail).
    func followFocus(_ newID: UUID?) {
        guard newID == selectionStore.focusedID, selectedItemID != newID else { return }
        select(newID)
    }

    /// Toggle selection for an item (Cmd+click)
    func toggleSelection(_ itemID: UUID) {
        if selectedIDs.contains(itemID) {
            selectionStore.toggle(itemID)
        } else {
            selectionStore.toggle(itemID)
        }
    }

    /// Extend selection to an item (Shift+click) - selects range from anchor
    func extendSelection(to itemID: UUID) {
        guard let anchorID = selectionAnchor else {
            // No anchor, just select this item
            select(itemID)
            return
        }

        // The loaded collection owns a UUID index, so even a shift-click near the end of a large
        // page does not scan the full array twice before constructing the selected range.
        guard let anchorIndex = itemIndexByID[anchorID],
              let targetIndex = itemIndexByID[itemID] else {
            return
        }

        // Select all items in range
        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        let rangeIDs = items[range].map(\.id)
        selectedIDs.formUnion(rangeIDs)
    }

    /// Select all visible items (Cmd+A)
    func selectAll() {
        selectionStore.selectAll(items.map(\.id))
    }

    /// Clear all selections (Escape)
    func clearSelection() {
        selectionStore.clear()
    }

    // MARK: - Keyboard Navigation

    /// Navigate to next item (down/j)
    func selectNext() {
        lastNavigationProbeCount = 0
        guard !items.isEmpty else { return }

        if let currentID = selectedItemID,
           let currentIndex = navigationItemIndex(for: currentID) {
            let nextIndex = min(currentIndex + 1, items.count - 1)
            select(items[nextIndex].id)
        } else {
            select(items.first?.id)
        }
    }

    /// Navigate to previous item (up/k)
    func selectPrevious() {
        lastNavigationProbeCount = 0
        guard !items.isEmpty else { return }

        if let currentID = selectedItemID,
           let currentIndex = navigationItemIndex(for: currentID) {
            let prevIndex = max(currentIndex - 1, 0)
            select(items[prevIndex].id)
        } else {
            select(items.last?.id)
        }
    }

    // MARK: - Position Helpers

    private func navigationItemIndex(for id: UUID) -> Int? {
        lastNavigationProbeCount += 1
        return itemIndexByID[id]
    }

    private func navigationPosition(for id: UUID) -> NavigationPosition? {
        lastNavigationProbeCount += 1
        return navigationPositionByID[id]
    }

    private func navigationCenterY(at position: NavigationPosition) -> CGFloat? {
        lastNavigationProbeCount += 1
        guard columnItemCenterYs.indices.contains(position.column),
              columnItemCenterYs[position.column].indices.contains(position.row) else {
            return nil
        }
        return columnItemCenterYs[position.column][position.row]
    }

    /// Find the closest cached center with a binary search. Centers are strictly increasing in
    /// each column, reducing this portion of horizontal navigation from O(rows) to O(log rows).
    private func findClosestRowByY(inColumn columnIndex: Int, toY targetY: CGFloat) -> Int {
        lastNavigationProbeCount += 1
        guard columnItemCenterYs.indices.contains(columnIndex) else { return 0 }
        let centers = columnItemCenterYs[columnIndex]
        guard !centers.isEmpty else { return 0 }

        var lowerBound = 0
        var upperBound = centers.count
        while lowerBound < upperBound {
            lastNavigationProbeCount += 1
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if centers[midpoint] < targetY {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        guard lowerBound > 0 else { return 0 }
        guard lowerBound < centers.count else { return centers.count - 1 }
        let previous = lowerBound - 1
        return abs(centers[previous] - targetY) <= abs(centers[lowerBound] - targetY)
            ? previous
            : lowerBound
    }

    /// Resolve one purely spatial horizontal step. Backing-array order is intentionally ignored:
    /// masonry placement can put a later result to the left or an earlier result to the right.
    private func horizontalNavigationTarget(
        from currentID: UUID,
        columnOffset: Int
    ) -> (id: UUID, sourceCenterY: CGFloat)? {
        guard abs(columnOffset) == 1,
              let position = navigationPosition(for: currentID),
              let currentCenterY = navigationCenterY(at: position) else {
            return nil
        }

        let targetColumnIndex = position.column + columnOffset
        guard columns.indices.contains(targetColumnIndex),
              !columns[targetColumnIndex].isEmpty else {
            return nil
        }

        let targetY = goalYPosition ?? currentCenterY
        let targetRow = findClosestRowByY(inColumn: targetColumnIndex, toY: targetY)
        guard columns[targetColumnIndex].indices.contains(targetRow) else { return nil }
        return (columns[targetColumnIndex][targetRow].id, currentCenterY)
    }

    private func selectHorizontally(columnOffset: Int) {
        lastNavigationProbeCount = 0
        guard !items.isEmpty else { return }
        guard let currentID = selectedItemID else {
            select(items.first?.id, scrollToSelection: true)
            return
        }
        guard let target = horizontalNavigationTarget(
            from: currentID,
            columnOffset: columnOffset
        ) else { return }

        select(target.id, preserveGoalY: true, scrollToSelection: true)
        if goalYPosition == nil {
            goalYPosition = target.sourceCenterY
        }
    }

    /// Navigate left to the closest-Y item in the adjacent spatial column.
    func selectLeft() {
        selectHorizontally(columnOffset: -1)
    }

    /// Navigate right to the closest-Y item in the adjacent spatial column.
    func selectRight() {
        selectHorizontally(columnOffset: 1)
    }

    /// Navigate up in current column
    func selectUp() {
        lastNavigationProbeCount = 0
        guard let currentID = selectedItemID,
              let pos = navigationPosition(for: currentID) else {
            select(items.first?.id, scrollToSelection: true)
            return
        }

        goalYPosition = nil
        if pos.row > 0 {
            select(columns[pos.column][pos.row - 1].id, scrollToSelection: true)
        }
    }

    /// Navigate down in current column
    func selectDown() {
        lastNavigationProbeCount = 0
        guard let currentID = selectedItemID,
              let pos = navigationPosition(for: currentID) else {
            select(items.first?.id, scrollToSelection: true)
            return
        }

        goalYPosition = nil
        let column = columns[pos.column]
        if pos.row < column.count - 1 {
            select(column[pos.row + 1].id, scrollToSelection: true)
        }
    }

    // MARK: - Shift+Navigation (Extend Selection)

    /// Extend selection up in current column (Shift+K/Up)
    func extendSelectionUp() {
        lastNavigationProbeCount = 0
        guard let currentID = selectedItemID else {
            select(items.first?.id, scrollToSelection: true)
            return
        }

        goalYPosition = nil
        guard let position = navigationPosition(for: currentID) else { return }
        if position.row > 0 {
            let targetID = columns[position.column][position.row - 1].id
            selectedIDs.insert(targetID)
            selectionAnchor = targetID
            shouldScrollToSelection = true
        }
    }

    /// Extend selection down in current column (Shift+J/Down)
    func extendSelectionDown() {
        lastNavigationProbeCount = 0
        guard let currentID = selectedItemID else {
            select(items.first?.id, scrollToSelection: true)
            return
        }

        goalYPosition = nil
        guard let position = navigationPosition(for: currentID) else { return }
        let column = columns[position.column]
        if position.row < column.count - 1 {
            let targetID = column[position.row + 1].id
            selectedIDs.insert(targetID)
            selectionAnchor = targetID
            shouldScrollToSelection = true
        }
    }

    /// Extend selection left using the same spatial model as unmodified navigation.
    func extendSelectionLeft() {
        extendSelectionHorizontally(offset: -1)
    }

    /// Extend selection right using the same spatial model as unmodified navigation.
    func extendSelectionRight() {
        extendSelectionHorizontally(offset: 1)
    }

    private func extendSelectionHorizontally(offset: Int) {
        lastNavigationProbeCount = 0
        guard !items.isEmpty else { return }
        guard let currentID = selectedItemID else {
            select(items.first?.id, scrollToSelection: true)
            return
        }
        guard let target = horizontalNavigationTarget(
            from: currentID,
            columnOffset: offset
        ) else { return }

        selectedIDs.insert(target.id)
        selectionAnchor = target.id
        shouldScrollToSelection = true
        if goalYPosition == nil {
            goalYPosition = target.sourceCenterY
        }
    }

    // MARK: - Column Distribution

    private struct ColumnLayoutSnapshot {
        let columns: [[MediaItem]]
        let heights: [CGFloat]
        let positions: [UUID: NavigationPosition]
        let centerYs: [[CGFloat]]
    }

    /// Distribute items into columns using shortest-column-first algorithm.
    /// This produces a balanced masonry layout where items flow into whichever
    /// column currently has the least cumulative height.
    private func recalculateColumns() {
        guard !isColumnLayoutValid else {
            lastColumnLayoutItemVisitCount = 0
            return
        }

        PerfLog.measure("recalculateColumns", category: .layout, context: "\(items.count) items, \(columnCount) cols") {
            let snapshot = distributeToColumns(items: items, columnCount: columnCount)
            lastColumnLayoutItemVisitCount = items.count
            columns = snapshot.columns
            columnHeights = snapshot.heights
            navigationPositionByID = snapshot.positions
            columnItemCenterYs = snapshot.centerYs
            isColumnLayoutValid = true
        }
    }

    private func invalidateColumnCache() {
        isColumnLayoutValid = false
    }

    /// Extend the already-balanced layout from its existing running heights. The prior
    /// implementation redistributed every accumulated item after each pagination fetch; this
    /// visits only the new page while producing the same shortest-column result.
    private func appendToColumnLayout(_ newItems: [MediaItem]) {
        guard columns.count == columnCount,
              columnHeights.count == columnCount,
              columnItemCenterYs.count == columnCount else {
            invalidateColumnCache()
            recalculateColumns()
            return
        }

        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let columnWidth = (containerWidth - totalSpacing) / CGFloat(columnCount)
        var updatedColumns = columns
        var updatedCenterYs = columnItemCenterYs
        var runningHeights = zip(updatedColumns, columnHeights).map { column, height in
            column.isEmpty ? 0 : height + spacing
        }

        navigationPositionByID.reserveCapacity(items.count)
        lastColumnLayoutItemVisitCount = newItems.count
        for item in newItems {
            let shortestIndex = runningHeights.enumerated()
                .min(by: { $0.element < $1.element })?
                .offset ?? 0
            let row = updatedColumns[shortestIndex].count
            let aspectRatio = max(0.4, min(2.5, MasonryPresentationPolicy.layoutAspectRatio(for: item)))
            let itemHeight = columnWidth / aspectRatio

            updatedColumns[shortestIndex].append(item)
            updatedCenterYs[shortestIndex].append(runningHeights[shortestIndex] + itemHeight / 2)
            navigationPositionByID[item.id] = NavigationPosition(column: shortestIndex, row: row)
            runningHeights[shortestIndex] += itemHeight + spacing
        }

        columns = updatedColumns
        columnItemCenterYs = updatedCenterYs
        columnHeights = zip(updatedColumns, runningHeights).map { column, runningHeight in
            column.isEmpty ? 0 : max(0, runningHeight - spacing)
        }
    }

    /// Distribute items to columns based on cumulative height.
    /// Each item goes to the shortest column, creating a balanced masonry effect.
    /// CRITICAL: Must use same height calculation as ColumnMasonryLayout for navigation to work!
    private func distributeToColumns(items: [MediaItem], columnCount: Int) -> ColumnLayoutSnapshot {
        guard columnCount > 0 else {
            return ColumnLayoutSnapshot(columns: [], heights: [], positions: [:], centerYs: [])
        }
        guard !items.isEmpty else {
            return ColumnLayoutSnapshot(
                columns: Array(repeating: [], count: columnCount),
                heights: Array(repeating: 0, count: columnCount),
                positions: [:],
                centerYs: Array(repeating: [], count: columnCount)
            )
        }

        // Calculate column width (same formula as ColumnMasonryLayout)
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let columnWidth = (containerWidth - totalSpacing) / CGFloat(columnCount)

        var columns: [[MediaItem]] = Array(repeating: [], count: columnCount)
        // Running height used ONLY for shortest-column balancing (item heights + a spacing gap
        // per item so the greedy comparison matches the rendered layout).
        var running: [CGFloat] = Array(repeating: 0, count: columnCount)
        var counts: [Int] = Array(repeating: 0, count: columnCount)
        var itemHeightSums: [CGFloat] = Array(repeating: 0, count: columnCount)
        var positions: [UUID: NavigationPosition] = [:]
        var centerYs: [[CGFloat]] = Array(repeating: [], count: columnCount)
        positions.reserveCapacity(items.count)

        for item in items {
            // Find shortest column
            let shortestIndex = running.enumerated()
                .min(by: { $0.element < $1.element })?
                .offset ?? 0

            // ACTUAL pixel height (same clamp/formula as MasonryGrid.itemHeight)
            let aspectRatio = max(0.4, min(2.5, MasonryPresentationPolicy.layoutAspectRatio(for: item)))
            let itemHeight = columnWidth / aspectRatio
            let row = columns[shortestIndex].count
            columns[shortestIndex].append(item)
            positions[item.id] = NavigationPosition(column: shortestIndex, row: row)
            centerYs[shortestIndex].append(running[shortestIndex] + itemHeight / 2)
            running[shortestIndex] += itemHeight + spacing
            itemHeightSums[shortestIndex] += itemHeight
            counts[shortestIndex] += 1
        }

        // Exact rendered column height: item heights + inter-item spacing (n-1 gaps), matching
        // the LazyVStack the grid uses. This is what the grid pins each column to so the
        // independently-virtualizing stacks stay vertically aligned during scroll.
        let heights: [CGFloat] = zip(itemHeightSums, counts).map { sum, count in
            count > 0 ? sum + spacing * CGFloat(count - 1) : 0
        }

        return ColumnLayoutSnapshot(
            columns: columns,
            heights: heights,
            positions: positions,
            centerYs: centerYs
        )
    }
}

// MARK: - Keyboard Event Handler

extension MasonryGridViewModel {
    /// Handle keyboard events for grid navigation
    func handleKeyPress(_ event: KeyEquivalent) -> Bool {
        switch event {
        case .downArrow, "j":
            selectDown()
            return true
        case .upArrow, "k":
            selectUp()
            return true
        case .leftArrow, "h":
            selectLeft()
            return true
        case .rightArrow, "l":
            selectRight()
            return true
        default:
            return false
        }
    }
}
