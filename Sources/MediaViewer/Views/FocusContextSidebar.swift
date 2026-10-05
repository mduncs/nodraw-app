import SwiftUI

/// Related author/similarity results, with folder and tag matches kept behind More.
@MainActor
struct FocusContextSidebar: View {
    let item: MediaItem
    let onItemSelected: (MediaItem) -> Void
    var showsHeader = true
    @EnvironmentObject var appState: AppState
    @AppStorage("focusRelatedMoreExpanded") private var moreExpanded = false
    @StateObject private var model: FocusRelatedModel

    init(item: MediaItem, showsHeader: Bool = true, similarProvider: @escaping FocusSimilarProvider = { _ in [] },
         onItemSelected: @escaping (MediaItem) -> Void) {
        self.item = item
        self.onItemSelected = onItemSelected
        self.showsHeader = showsHeader
        _model = StateObject(wrappedValue: FocusRelatedModel(similarProvider: similarProvider))
    }

    private struct LoadIdentity: Hashable {
        let id: UUID
        let hasStore: Bool
    }

    private struct MetadataIdentity: Equatable {
        let author: String?
        let tags: Set<String>
    }

    private var currentItem: MediaItem { appState.mediaSelectionStore.item(for: item.id) ?? item }

    var body: some View {
        ScrollView {
            FocusRelatedContent(item: currentItem, sections: model.sections, isLoading: model.isLoading,
                showsHeader: showsHeader,
                moreExpanded: $moreExpanded, onItemSelected: onItemSelected,
                onShowAuthor: { appState.openRelatedAuthor($0) })
        }
        .background(Color(hex: 0x1f1f1f))
        .task(id: LoadIdentity(id: item.id, hasStore: appState.mediaStore != nil)) {
            // Arrow-key browsing should settle before querying the next item.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let store = appState.mediaStore else { return }
            await model.load(item: currentItem, in: store, includeMore: moreExpanded)
        }
        .onReceive(appState.mediaSelectionStore.recordChanges) { updated in
            guard updated.id == item.id, let store = appState.mediaStore else { return }
            Task { await model.refreshFocusedRecord(updated, in: store, includeMore: moreExpanded) }
        }
        .onChange(of: MetadataIdentity(author: currentItem.metadata.author, tags: Set(currentItem.metadata.tags))) { _, _ in
            guard let store = appState.mediaStore else { return }
            Task { await model.refreshFocusedRecord(currentItem, in: store, includeMore: moreExpanded) }
        }
        .onChange(of: moreExpanded) { _, expanded in
            guard expanded, let store = appState.mediaStore else { return }
            Task { await model.loadMore(in: store) }
        }
    }

    /// Preserve the existing query-test API and author → folder → tags priority.
    nonisolated static func distinctSections(author: [MediaItem], folder: [MediaItem], tags: [MediaItem],
                                 limit: Int = 12) -> (author: [MediaItem], folder: [MediaItem], tags: [MediaItem]) {
        let sections = FocusRelatedSections.make(author: author, authorTotal: author.count,
            similar: [], folder: folder, tags: tags, limit: limit)
        return (sections.author, sections.folder, sections.tags)
    }
}

extension AppState {
    func openRelatedAuthor(_ author: String) {
        guard !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        commitLibraryFilterChange {
            clearLibrarySearchAndFilterState()
            sidebarSelection = .allMedia
            activeSmartFolder = nil
            showDuplicateReview = false
            searchScope = .all
            filterText = MediaFilterBuilder.exactAuthorSearchText(author)
        }
    }
}
