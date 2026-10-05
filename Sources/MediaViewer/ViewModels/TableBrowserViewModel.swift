import Foundation
import Combine
import DataTable

/// Fixed, named clipboard schema for the table's two copy affordances.
/// Column customization currently has no public value-to-field export API, so
/// both Cmd+C and row-context copy use this same explicit metadata schema.
enum TableCopyPolicy {
    static let headers = ["Platform", "Author", "Starred", "Tags", "Notes", "Archived", "Created", "Source"]

    static func tsv(items: [MediaItem]) -> String {
        let rows = items.map { item in
            [
                item.metadata.platform,
                item.metadata.author ?? "",
                item.metadata.starred ? "★" : "",
                item.metadata.tags.joined(separator: ", "),
                item.metadata.notes ?? "",
                DateCell.formatter.string(from: item.metadata.archivedDate),
                item.metadata.originalDate.map { DateCell.formatter.string(from: $0) } ?? "",
                item.metadata.source.absoluteString,
            ]
        }
        return TableExporter.buildTSV(headers: headers, rows: rows)
    }
}

// MARK: - Table Grouping

enum TableGroupBy: String, CaseIterable, Codable {
    case none = "None"
    case platform = "Platform"
    case author = "Author"
    case folder = "Folder"
    case starred = "Starred"
}

struct ItemGroup: Identifiable {
    let id: String
    let label: String
    let items: [MediaItem]
    var count: Int { items.count }
}

// MARK: - TableBrowserViewModel

@MainActor
final class TableBrowserViewModel: ObservableObject {
    private(set) var items: [MediaItem] {
        get { selectionStore.items }
        set { selectionStore.replaceItems(newValue) }
    }
    @Published var config: TableBrowserConfig {
        didSet { config.save() }
    }
    @Published var sortOrder: SortOrder = .archivedDateDescending

    /// SwiftUI Table native sort order (for column header click sorting)
    @Published var tableSortOrder: [KeyPathComparator<MediaItem>] = []

    /// Grouping mode
    @Published var groupBy: TableGroupBy = .none {
        didSet {
            UserDefaults.standard.set(groupBy.rawValue, forKey: "tableGroupBy")
            rebuildGroups()
        }
    }

    /// Computed groups (populated when groupBy != .none)
    @Published private(set) var groups: [ItemGroup] = []

    /// Stable lookup/display caches remove full collection scans from selection propagation and
    /// focus-return commands. They are rebuilt only when the table snapshot itself changes.
    private var itemIndexByID: [UUID: Int] = [:]
    private(set) var loadedItemIDs: Set<UUID> = []
    private var groupedItemsInDisplayOrder: [MediaItem] = []

    /// Deterministic counters for focused performance tests.
    private(set) var collectionReplacementCount = 0
    private(set) var lastCollectionIndexBuildItemCount = 0

    private var selectionStore = MediaSelectionStore()
    private var selectionStoreCancellable: AnyCancellable?
    private var recordChangeCancellable: AnyCancellable?
    private var projectedCorpusGeneration = -1

    var selectedIDs: Set<UUID> {
        get { selectionStore.selectedIDs }
        set { selectionStore.selectedIDs = newValue }
    }

    /// Row height multiplier (1.0 = compact, 1.5 = comfortable, 2.0 = spacious)
    @Published var rowHeight: CGFloat = 1.0 {
        didSet {
            UserDefaults.standard.set(rowHeight, forKey: "tableRowHeight")
        }
    }

    /// Currently selected single item (for inspector sync)
    var selectedItemID: UUID? {
        selectionStore.focusedID ?? selectionStore.orderedSelectedIDs.first
    }

    /// First selected item (for keyboard actions)
    var firstSelectedItem: MediaItem? {
        guard let id = selectedItemID else { return nil }
        return item(for: id)
    }

    var visibleItemsInDisplayOrder: [MediaItem] {
        guard groupBy != .none else { return items }
        return groupedItemsInDisplayOrder
    }

    init() {
        self.config = TableBrowserConfig.load()
        self.groupBy = TableGroupBy(rawValue: UserDefaults.standard.string(forKey: "tableGroupBy") ?? "None") ?? .none
        self.rowHeight = UserDefaults.standard.double(forKey: "tableRowHeight").clamped(to: 0.75...2.5, default: 1.0)
    }

    func setSelectionStore(_ store: MediaSelectionStore) {
        if selectionStore === store {
            if projectedCorpusGeneration != store.corpusGeneration {
                rebuildItemIndex()
                rebuildGroups()
            }
            return
        }
        selectionStore = store
        selectionStoreCancellable = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        recordChangeCancellable = store.recordChanges.sink { [weak self, weak store] record in
            guard store?.acceptsSurface(.table) == true else { return }
            self?.replaceItemIfPresent(record)
        }
        rebuildItemIndex()
        rebuildGroups()
        objectWillChange.send()
    }

    func setItems(_ newItems: [MediaItem]) {
        var preparedItems = newItems
        if !tableSortOrder.isEmpty {
            preparedItems.sort(using: tableSortOrder)
        }

        // Store-change publishers can converge on the same query. Comparing once is cheaper than
        // replacing/diffing a 5,000-row native table snapshot with identical values.
        guard preparedItems != items else {
            lastCollectionIndexBuildItemCount = 0
            return
        }

        items = preparedItems
        collectionReplacementCount += 1
        rebuildItemIndex()
        selectionStore.preserveVisibleIDs(loadedItemIDs)
        rebuildGroups()
    }

    func replaceItemIfPresent(_ updated: MediaItem) {
        guard let index = itemIndexByID[updated.id], items.indices.contains(index) else {
            return
        }

        var updatedItems = items
        updatedItems[index] = updated
        if !tableSortOrder.isEmpty {
            updatedItems.sort(using: tableSortOrder)
        }
        items = updatedItems
        collectionReplacementCount += 1
        rebuildItemIndex()
        rebuildGroups()
    }

    /// Optimistically remove deleted items from table rows and selection.
    func removeItems(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let beforeCount = items.count
        items.removeAll { ids.contains($0.id) }
        guard items.count != beforeCount else { return }
        collectionReplacementCount += 1
        rebuildItemIndex()
        selectionStore.remove(ids)
        rebuildGroups()
    }

    func sortItems(using comparators: [KeyPathComparator<MediaItem>]) {
        var sortedItems = items
        sortedItems.sort(using: comparators)
        guard sortedItems != items else { return }
        items = sortedItems
        collectionReplacementCount += 1
        rebuildItemIndex()
        rebuildGroups()
    }

    func containsItem(_ id: UUID) -> Bool {
        itemIndexByID[id] != nil
    }

    func item(for id: UUID) -> MediaItem? {
        guard let index = itemIndexByID[id], items.indices.contains(index) else { return nil }
        return items[index]
    }

    func select(_ id: UUID?) {
        selectionStore.select(id)
    }

    func toggleSelection(_ id: UUID) {
        selectionStore.toggle(id)
    }

    func clearSelection() {
        selectionStore.clear()
    }

    func selectAll() {
        selectionStore.selectAll(visibleItemsInDisplayOrder.map(\.id))
    }

    // MARK: - Grouping

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
        lastCollectionIndexBuildItemCount = items.count
    }

    private func rebuildGroups() {
        guard groupBy != .none else {
            groups = []
            groupedItemsInDisplayOrder = []
            return
        }

        let grouped: [String: [MediaItem]]
        switch groupBy {
        case .none:
            groups = []
            return
        case .platform:
            grouped = Dictionary(grouping: items) { LibraryFilterPresentation.platformName($0.metadata.platform) }
        case .author:
            grouped = Dictionary(grouping: items) { $0.metadata.author ?? "(no author)" }
        case .folder:
            grouped = Dictionary(grouping: items) { $0.folderName }
        case .starred:
            grouped = Dictionary(grouping: items) { $0.metadata.starred ? "Starred" : "Not Starred" }
        }

        let rebuiltGroups = grouped
            .map { ItemGroup(id: $0.key, label: $0.key, items: $0.value) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        groups = rebuiltGroups
        groupedItemsInDisplayOrder = rebuiltGroups.flatMap(\.items)
    }
}

// MARK: - Double clamping helper

private extension Double {
    func clamped(to range: ClosedRange<Double>, default defaultValue: Double) -> Double {
        if self == 0 { return defaultValue }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
