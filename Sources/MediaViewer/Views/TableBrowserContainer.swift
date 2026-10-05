import SwiftUI
import Combine
import AppKit

enum TableBrowserHydration {
    static let maximumTableItems = 5_000

    /// A grid snapshot intentionally omits ML attributes. Table score fields
    /// require a bounded enrichment pass when reusing that shared corpus. Match
    /// the table's normal query cap even if Grid has accumulated more pages.
    static func hydrateMLAttributes(_ items: [MediaItem], using store: MediaStore) async throws -> [MediaItem] {
        let tableItems = Array(items.prefix(maximumTableItems))
        guard !tableItems.isEmpty else { return [] }
        let rowsByItem = try await store.fetchAttributes(itemIds: tableItems.map(\.id))
        return tableItems.map { cachedItem in
            var item = cachedItem
            item.mlAttributes = (rowsByItem[item.id] ?? []).reduce(into: [:]) { attributes, row in
                attributes["\(row.module).\(row.key)"] = row.value
            }
            return item
        }
    }
}

// MARK: - Table Browser Container

/// Container view that owns the TableBrowserViewModel, handles data loading,
/// and subscribes to filter changes — mirrors MasonryGridContainer pattern.
struct TableBrowserContainer: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = TableBrowserViewModel()
    @State private var cachedClipResultIds: [UUID]?
    @State private var cachedClipQuery: String?
    @State private var tableTopResetGeneration: Int = 0
    @State private var pendingItemRevealRequest: LibraryScrollRequest?
    @State private var itemRevealRequest: TableLibraryItemRevealRequest?

    var body: some View {
        TableBrowserView(viewModel: viewModel, itemRevealRequest: itemRevealRequest)
            // Reconstructing the native Table is the reliable macOS 14 handoff for a committed
            // result-set replacement; a fresh Table starts at its first row in both grouped and
            // flat modes. Anchor restores keep the existing table identity and selection.
            .id(tableTopResetGeneration)
            .overlay {
                if viewModel.items.isEmpty {
                    LibraryEmptyResultsView()
                }
            }
        .onAppear {
            viewModel.setSelectionStore(appState.mediaSelectionStore)
            appState.mediaSelectionStore.activate(.table)
            handleLibraryScrollRequest(appState.libraryScrollRequest)
        }
        .modifier(TableDataModifier(appState: appState, viewModel: viewModel, loadItems: loadItems))
        .onChange(of: viewModel.selectedIDs) { _, newIDs in
            appState.selectedItemIDs = newIDs
            appState.selectedItemID = viewModel.selectedItemID ?? appState.orderedItemIDs(in: newIDs).first
            appState.updateDisplayContextSelection(
                surface: .table,
                selectedIDs: newIDs,
                anchorID: viewModel.selectedItemID
            )
        }
        .onChange(of: appState.selectedItemIDs) { _, newIDs in
            let syncedIDs = newIDs.intersection(viewModel.loadedItemIDs)
            if viewModel.selectedIDs != syncedIDs {
                viewModel.selectedIDs = syncedIDs
            }
        }
        .onChange(of: viewModel.groupBy) { _, _ in
            appState.setDisplayContext(
                surface: .table,
                items: viewModel.visibleItemsInDisplayOrder,
                selectedIDs: viewModel.selectedIDs,
                anchorID: viewModel.selectedItemID
            )
        }
        .onChange(of: appState.libraryScrollRequest) { _, request in
            handleLibraryScrollRequest(request)
        }
    }

    // MARK: - Data Loading

    private func loadItems() async {
        viewModel.setSelectionStore(appState.mediaSelectionStore)
        guard let queryToken = appState.mediaSelectionStore.beginQuery(from: .table) else { return }
        guard let store = appState.mediaStore else { return }

        do {
            guard var filter = MediaFilterBuilder.makeBaseFilter(
                sidebarSelection: appState.sidebarSelection,
                activeSmartFolder: appState.activeSmartFolder,
                unsupportedSelectionBehavior: .returnEmpty
            ) else {
                // These use specialized views, not available in table mode.
                viewModel.setItems([])
                appState.setDisplayContext(surface: .table, items: [])
                appState.selectedItemIDs = []
                appState.selectedItemID = nil
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
                hideJunk: SettingsStore.shared.hideJunkItems,
                hideSafetyFlagged: SettingsStore.shared.hideSafetyFlagged
            )

            filter.sortOrder = appState.sortOrder
            filter.shuffleSeed = appState.shuffleSeed
            filter.limit = 5000

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
            if appState.mediaSelectionStore.canReuseLoadedResults(for: filter, switchingTo: .table) {
                // Grid's common query is deliberately shallow. Rehydrate only
                // the already-loaded corpus, keeping its order and avoiding a
                // second unbounded filter scan while populating table scores.
                items = try await TableBrowserHydration.hydrateMLAttributes(
                    appState.mediaSelectionStore.items,
                    using: store
                )
            } else {
                items = try await store.fetchItems(filter: filter,
                    // Score columns and the matching CSV fields are visible in Table mode;
                    // load these values on the already bounded 5,000-row table query.
                    includeMLAttributes: true, includePerFileOCR: false,
                    includeVideoSegments: false, includeTranscriptSegments: false)
            }
            guard !Task.isCancelled, appState.mediaSelectionStore.accepts(queryToken) else { return }
            appState.mediaSelectionStore.rememberFilter(filter)
            viewModel.setItems(items)
            fulfillPendingItemRevealIfPossible()
            appState.setDisplayContext(
                surface: .table,
                items: viewModel.visibleItemsInDisplayOrder,
                selectedIDs: viewModel.selectedIDs,
                anchorID: viewModel.selectedItemID
            )
        } catch {
            logError("Table load failed: \(error.localizedDescription)")
        }
    }

    /// A focus-return request can arrive before a pending query finishes. Keep it until the UUID
    /// index confirms the row is loaded, then let the native table bridge reveal its selected row.
    private func handleLibraryScrollRequest(_ request: LibraryScrollRequest) {
        switch request.target {
        case .top:
            pendingItemRevealRequest = nil
            itemRevealRequest = nil
            tableTopResetGeneration = request.generation
        case .item:
            pendingItemRevealRequest = request
            fulfillPendingItemRevealIfPossible()
        }
    }

    private func fulfillPendingItemRevealIfPossible() {
        guard let pendingItemRevealRequest,
              case .item(let id) = pendingItemRevealRequest.target,
              viewModel.containsItem(id) else {
            return
        }

        if viewModel.selectedIDs != [id] || viewModel.selectedItemID != id {
            viewModel.select(id)
        }
        itemRevealRequest = TableLibraryItemRevealRequest(
            generation: pendingItemRevealRequest.generation,
            itemID: id
        )
        self.pendingItemRevealRequest = nil
    }
}

// MARK: - Table Data Modifier

/// Handles data loading and filter subscriptions for the table browser.
/// Mirrors GridDataModifier pattern from MasonryGrid.
private struct TableDataModifier: ViewModifier {
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: TableBrowserViewModel
    let loadItems: () async -> Void
    @State private var pendingLoadTask: Task<Void, Never>?
    @State private var hasPendingLoad = false
    @State private var isLoadInProgress = false

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
        .map { _ in () }
    }

    @MainActor
    private func requestLoad(debounceNanoseconds: UInt64 = 0) {
        appState.mediaSelectionStore.invalidateQueries(from: .table)
        pendingLoadTask?.cancel()
        pendingLoadTask = Task { @MainActor in
            if debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }
            }
            hasPendingLoad = true
            await drainLoadQueue()
        }
    }

    @MainActor
    private func drainLoadQueue() async {
        guard !isLoadInProgress else { return }
        isLoadInProgress = true
        defer { isLoadInProgress = false }

        while hasPendingLoad {
            hasPendingLoad = false
            await loadItems()
        }
    }

    func body(content: Content) -> some View {
        content
            .task {
                await MainActor.run {
                    requestLoad()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .mediaStoreDidChange)
            ) { notification in
                if let deletedItemIds = notification.userInfo?["deletedItemIds"] as? [UUID],
                   !deletedItemIds.isEmpty {
                    let ids = Set(deletedItemIds)
                    viewModel.removeItems(ids)
                    appState.removeDisplayedItems(ids: ids)
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .mediaStoreDidChange)
                    .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            ) { _ in
                requestLoad()
            }
            // Subscribe to MediaStore.changes (fired by toggleStar, etc.)
            .onReceive(
                (appState.mediaStore?.changes ?? Empty().eraseToAnyPublisher())
                    .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            ) { _ in
                requestLoad()
            }
            .onReceive(filterPublisher) { _ in
                requestLoad()
            }
            .onReceive(appState.$colorFilters.dropFirst()) { _ in
                requestLoad()
            }
            .onReceive(appState.$colorSearchRGB.dropFirst()) { _ in
                requestLoad()
            }
            .onReceive(appState.$starredFilter.dropFirst()) { _ in
                requestLoad()
            }
            .onReceive(appState.$hasOCRFilter.dropFirst()) { _ in
                requestLoad()
            }
            .onReceive(appState.$platformFilter.dropFirst()) { _ in
                requestLoad()
            }
            .onReceive(appState.$pipelineAttributeFilters.dropFirst()) { _ in
                requestLoad()
            }
            .onReceive(appState.$searchScope.dropFirst()) { _ in
                requestLoad()
            }
            .onReceive(appState.$sortOrder.dropFirst()) { _ in
                viewModel.tableSortOrder = []
                requestLoad()
            }
            .onReceive(appState.$shuffleSeed.dropFirst()) { _ in
                viewModel.tableSortOrder = []
                requestLoad()
            }
            // Column header sorting is handled in-memory by ViewModel
            .onDisappear {
                appState.mediaSelectionStore.invalidateQueries(from: .table)
                pendingLoadTask?.cancel()
                pendingLoadTask = nil
            }
    }
}
