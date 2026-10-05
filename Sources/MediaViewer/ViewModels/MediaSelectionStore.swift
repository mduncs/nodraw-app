import Foundation
import Combine

@MainActor
final class MediaSelectionStore: ObservableObject {
    /// Canonical loaded corpus. Grid/table layout caches are derived from this array;
    /// AppState and detail retain IDs, never independently editable item snapshots.
    @Published private(set) var items: [MediaItem] = []
    private var itemIndex: [UUID: Int] = [:]
    private var retainedItems: [UUID: MediaItem] = [:]
    private(set) var displayedItems: [MediaItem] = []
    private var displayIndex: [UUID: Int] = [:]
    @Published var activeDisplayContext: DisplayContext?
    @Published var focusSession: FocusSession?
    private var detailID: UUID?
    private var lastDetailID: UUID?
    private(set) var activeDetailURL: URL?
    private(set) var activeDetailAssetID: UUID?
    private let focusedChanges = PassthroughSubject<MediaItem?, Never>()
    let recordsChanges = PassthroughSubject<[MediaItem], Never>()
    private(set) var isUpdatingRecords = false
    let recordChanges = PassthroughSubject<MediaItem, Never>()
    private(set) var focusGeneration = 0
    private var queryGeneration = 0
    private(set) var corpusGeneration = 0
    /// The actual query used by the active browser, shared with count/summary observers.
    @Published private(set) var committedFilter: FilterState?
    private var activeSurface: DisplaySurface?

    struct QueryToken: Equatable {
        let surface: DisplaySurface
        let generation: Int
    }

    @Published var selectedIDs: Set<UUID> = [] {
        didSet {
            if focusedID.map({ !selectedIDs.contains($0) }) ?? true {
                // A lone selection outside the display order (the open detail item after a tag
                // filter swaps results) is still the focus. Deriving nil here published a transient
                // nil before select() set the ID, and the grid's focus mirror ping-ponged forever.
                let lone = selectedIDs.count == 1 ? selectedIDs.first : nil
                self.focusedID = orderedIDs(in: selectedIDs).first ?? lone
            }
        }
    }
    @Published var focusedID: UUID?

    var orderedSelectedIDs: [UUID] { orderedIDs(in: selectedIDs) }
    var focusedItemPublisher: AnyPublisher<MediaItem?, Never> {
        focusedChanges.prepend(focusedItem).eraseToAnyPublisher()
    }
    var focusedItem: MediaItem? {
        get { detailID.flatMap(item(for:)) }
        set {
            objectWillChange.send()
            focusGeneration += 1
            if detailID != newValue?.id {
                activeDetailURL = nil
                activeDetailAssetID = nil
            }
            if let newValue { retain([newValue]) }
            detailID = newValue?.id
            focusedChanges.send(newValue)
        }
    }

    func setActiveDetailAsset(itemID: UUID, url: URL?) {
        guard detailID == itemID else { return }
        let id = url.flatMap { url in
            item(for: itemID)?.assets.first {
                ItemAssetStore.canonicalPath($0.url.path) == ItemAssetStore.canonicalPath(url.path)
            }?.assetID
        }
        guard activeDetailURL != url || activeDetailAssetID != id else { return }
        objectWillChange.send()
        activeDetailURL = url
        activeDetailAssetID = id
    }
    var lastFocusedItem: MediaItem? {
        get { lastDetailID.flatMap(item(for:)) }
        set {
            if let newValue { retain([newValue]) }
            lastDetailID = newValue?.id
        }
    }

    func activate(_ surface: DisplaySurface) {
        guard activeSurface != surface else { return }
        activeSurface = surface
        queryGeneration += 1
    }

    func invalidateQueries(from surface: DisplaySurface) {
        guard activeSurface == surface else { return }
        queryGeneration += 1
    }

    func beginQuery(from surface: DisplaySurface) -> QueryToken? {
        if activeSurface == nil { activate(surface) }
        guard activeSurface == surface else { return nil }
        queryGeneration += 1
        return QueryToken(surface: surface, generation: queryGeneration)
    }

    func accepts(_ token: QueryToken) -> Bool {
        activeSurface == token.surface && queryGeneration == token.generation
    }
    func acceptsSurface(_ surface: DisplaySurface) -> Bool { activeSurface == nil || activeSurface == surface }
    func currentQueryToken(from surface: DisplaySurface) -> QueryToken? {
        guard activeSurface == surface else { return nil }
        return QueryToken(surface: surface, generation: queryGeneration)
    }
    func rememberFilter(_ filter: FilterState) { committedFilter = normalized(filter) }
    func canReuseLoadedResults(for filter: FilterState, switchingTo surface: DisplaySurface) -> Bool {
        guard let origin = activeDisplayContext?.surface,
              [.grid, .table].contains(origin), origin != surface else { return false }
        return committedFilter == normalized(filter)
    }
    private func normalized(_ filter: FilterState) -> FilterState {
        var value = filter
        value.limit = 0
        value.offset = 0
        return value
    }

    func replaceItems(_ incomingItems: [MediaItem]) {
        let newItems = keepingDetailAnalysis(incomingItems)
        guard items != newItems else { return }
        corpusGeneration += 1
        // Only off-result records needed by the open/last detail survive replacement.
        let retainedIDs = Set(focusSession?.navigationIDs ?? [])
            .union([detailID, lastDetailID].compactMap { $0 })
        for item in items where retainedIDs.contains(item.id) { retainedItems[item.id] = item }
        items = newItems
        itemIndex = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
        retainedItems = retainedItems.filter { retainedIDs.contains($0.key) && itemIndex[$0.key] == nil }
        setDisplayOrder(items)
    }

    func appendItems(_ incomingItems: [MediaItem]) {
        let newItems = keepingDetailAnalysis(incomingItems)
        guard !newItems.isEmpty else { return }
        let offset = items.count
        items.append(contentsOf: newItems)
        corpusGeneration += 1
        for (index, item) in newItems.enumerated() {
            itemIndex[item.id] = offset + index
            retainedItems.removeValue(forKey: item.id)
        }
        // Pagination follows the query's existing order; no full index rebuild.
        displayedItems = items
        for (index, item) in newItems.enumerated() { displayIndex[item.id] = offset + index }
    }

    private func keepingDetailAnalysis(_ newItems: [MediaItem]) -> [MediaItem] {
        guard let detailID, let index = newItems.firstIndex(where: { $0.id == detailID }) else { return newItems }
        let kept = keepingDetailAnalysis(newItems[index])
        guard kept != newItems[index] else { return newItems }
        var result = newItems
        result[index] = kept
        return result
    }

    /// Grid and table queries skip per-file OCR, ML attributes and timelines. When one of those
    /// shallow records replaces the open detail item (the reload after adding a tag, a same-set
    /// retain, an optimistic star/tag snapshot), keep the analysis already hydrated so the
    /// inspector does not fall back to "no text". Payloads present in the incoming record always
    /// win, and a record whose media files changed brings only its own analysis.
    private func keepingDetailAnalysis(_ incoming: MediaItem) -> MediaItem {
        guard incoming.id == detailID, let current = item(for: incoming.id),
              incoming.mediaFiles == current.mediaFiles else { return incoming }
        var kept = incoming
        if kept.perFileOCR.isEmpty { kept.perFileOCR = current.perFileOCR }
        if kept.mlAttributes.isEmpty { kept.mlAttributes = current.mlAttributes }
        if kept.videoSegments.isEmpty { kept.videoSegments = current.videoSegments }
        if kept.transcriptSegments.isEmpty { kept.transcriptSegments = current.transcriptSegments }
        return kept
    }

    /// Display order is a derived projection (e.g. grouped table rows), not another
    /// mutable corpus. In the normal ungrouped case these arrays share COW storage.
    func setDisplayOrder(_ orderedItems: [MediaItem]) {
        displayedItems = orderedItems
        displayIndex = Dictionary(orderedItems.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    func retain(_ records: [MediaItem]) {
        isUpdatingRecords = true
        defer { isUpdatingRecords = false }
        var updatedItems = items
        var changed = false
        for incoming in records {
            let record = keepingDetailAnalysis(incoming)
            if let index = itemIndex[record.id] {
                if updatedItems[index] != record {
                    updatedItems[index] = record
                    changed = true
                }
            } else {
                retainedItems[record.id] = record
            }
            if let index = displayIndex[record.id], displayedItems[index] != record {
                displayedItems[index] = record
            }
        }
        if changed { items = updatedItems }
    }

    func item(for id: UUID) -> MediaItem? {
        if let index = itemIndex[id] { return items[index] }
        return retainedItems[id]
    }

    func displayedItem(for id: UUID) -> MediaItem? {
        guard let index = displayIndex[id] else { return nil }
        return displayedItems[index]
    }

    func displayPosition(of id: UUID) -> Int? { displayIndex[id] }

    func orderedIDs(in ids: Set<UUID>) -> [UUID] {
        ids.compactMap { id in displayIndex[id].map { ($0, id) } }
            .sorted { $0.0 < $1.0 }.map(\.1)
    }

    func replaceRecord(_ incoming: MediaItem) {
        replaceRecords([incoming])
    }

    func replaceRecords(_ incoming: [MediaItem]) {
        let records = incoming.compactMap { record -> MediaItem? in
            guard let current = item(for: record.id) else { return nil }
            let kept = keepingDetailAnalysis(record)
            return current == kept ? nil : kept
        }
        guard !records.isEmpty else { return }
        retain(records)
        // `items` publishes on assignment; a record kept only for a display context does not.
        if records.allSatisfy({ itemIndex[$0.id] == nil }) {
            isUpdatingRecords = true
            objectWillChange.send()
            isUpdatingRecords = false
        }
        recordsChanges.send(records)
        for record in records {
            recordChanges.send(record)
            if detailID == record.id { focusedChanges.send(record) }
        }
    }

    func forget(_ ids: Set<UUID>) {
        replaceItems(items.filter { !ids.contains($0.id) })
        for id in ids { retainedItems.removeValue(forKey: id) }
        remove(ids)
    }

    func select(_ id: UUID?) {
        if let id {
            selectedIDs = [id]
            focusedID = id
        } else {
            selectedIDs = []
            focusedID = nil
        }
    }

    func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
            if focusedID == id {
                focusedID = orderedIDs(in: selectedIDs).first
            }
        } else {
            selectedIDs.insert(id)
            focusedID = id
        }
    }

    func selectAll(_ ids: [UUID]) {
        selectedIDs = Set(ids)
        focusedID = ids.first
    }

    func preserveVisibleIDs(_ visibleIDs: Set<UUID>) {
        selectedIDs.formIntersection(visibleIDs)
        if let focusedID, !visibleIDs.contains(focusedID) {
            self.focusedID = orderedIDs(in: selectedIDs).first
        }
    }

    func remove(_ ids: Set<UUID>) {
        selectedIDs.subtract(ids)
        if let focusedID, ids.contains(focusedID) {
            self.focusedID = orderedIDs(in: selectedIDs).first
        }
    }

    func clear() {
        selectedIDs = []
        focusedID = nil
    }
}
