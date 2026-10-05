import Combine
import Foundation

struct FocusSimilarMatch: Equatable, Sendable {
    let itemID: UUID
    let score: Double
}

typealias FocusSimilarProvider = @MainActor (MediaItem) async throws -> [FocusSimilarMatch]

@MainActor
final class FocusRelatedModel: ObservableObject {
    @Published private(set) var sections = FocusRelatedSections()
    @Published private(set) var isLoading = false
    private let similarProvider: FocusSimilarProvider
    private var focusedItem: MediaItem?
    private var generation = 0
    private var moreLoaded = false
    private var authorCandidates: [MediaItem] = []
    private var authorTotal = 0
    private var similarCandidates: [MediaItem] = []
    private var folderCandidates: [MediaItem] = []
    private var tagCandidates: [MediaItem] = []

    init(similarProvider: @escaping FocusSimilarProvider = { _ in [] }) {
        self.similarProvider = similarProvider
    }

    func load(item: MediaItem, in store: MediaStore, includeMore: Bool = false) async {
        generation += 1
        let request = generation
        focusedItem = item
        moreLoaded = false
        isLoading = true
        defer { if generation == request { isLoading = false } }
        async let author = loadAuthor(item, in: store)
        async let similar = loadSimilar(item, in: store)
        let (authorResult, similarResult) = await (author, similar)
        guard generation == request, !Task.isCancelled else { return }
        authorCandidates = authorResult.items
        authorTotal = authorResult.total
        similarCandidates = similarResult
        folderCandidates = []
        tagCandidates = []
        publishSections()
        if includeMore { await loadMore(in: store) }
    }

    func loadMore(in store: MediaStore) async {
        guard let item = focusedItem, !moreLoaded else { return }
        let request = generation
        async let folders = loadFolder(item, in: store)
        async let tags = loadTags(item, in: store)
        let (folderResult, tagResult) = await (folders, tags)
        guard generation == request, !Task.isCancelled else { return }
        folderCandidates = folderResult
        tagCandidates = tagResult
        moreLoaded = true
        publishSections()
    }

    /// Tag changes only refetch the tag section; author/folder results stay in place.
    func refreshFocusedRecord(_ updated: MediaItem, in store: MediaStore, includeMore: Bool) async {
        guard let current = focusedItem, current.id == updated.id else { return }
        guard current.metadata.author != updated.metadata.author ||
              Set(current.metadata.tags) != Set(updated.metadata.tags) else { return }
        if isLoading || current.metadata.author != updated.metadata.author {
            await load(item: updated, in: store, includeMore: includeMore)
            return
        }
        guard Set(current.metadata.tags) != Set(updated.metadata.tags) else { return }
        let hadMore = moreLoaded
        focusedItem = updated
        generation += 1
        let request = generation
        moreLoaded = false
        tagCandidates = []
        publishSections()
        guard includeMore else { return }
        guard hadMore else { await loadMore(in: store); return }
        let tags = await loadTags(updated, in: store)
        guard generation == request, !Task.isCancelled else { return }
        tagCandidates = tags
        moreLoaded = true
        publishSections()
    }

    static func rankedMatches(_ matches: [FocusSimilarMatch], excluding focusedID: UUID) -> [FocusSimilarMatch] {
        var seen: Set<UUID> = [focusedID]
        return matches.enumerated()
            .filter { $0.element.score.isFinite }
            .sorted { left, right in
                left.element.score == right.element.score ? left.offset < right.offset : left.element.score > right.element.score
            }
            .compactMap { seen.insert($0.element.itemID).inserted ? $0.element : nil }
    }

    private func publishSections() {
        sections = .make(author: authorCandidates, authorTotal: authorTotal,
            similar: similarCandidates, folder: folderCandidates, tags: tagCandidates,
            excluding: focusedItem?.id)
    }

    private func loadAuthor(_ item: MediaItem, in store: MediaStore) async -> (items: [MediaItem], total: Int) {
        guard let author = item.metadata.author,
              !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ([], 0) }
        return (try? await store.fetchAuthorRelated(author, excluding: item.id)) ?? ([], 0)
    }

    private func loadSimilar(_ item: MediaItem, in store: MediaStore) async -> [MediaItem] {
        let matches = Array(Self.rankedMatches((try? await similarProvider(item)) ?? [], excluding: item.id).prefix(36))
        guard !matches.isEmpty else { return [] }
        let items = (try? await store.fetchItems(ids: matches.map(\.itemID), includeMLAttributes: false,
            includePerFileOCR: false, includeVideoSegments: false, includeTranscriptSegments: false)) ?? []
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return matches.compactMap { byID[$0.itemID] }
    }

    private func loadFolder(_ item: MediaItem, in store: MediaStore) async -> [MediaItem] {
        let folder = item.basePath.deletingLastPathComponent().path
        guard !folder.isEmpty, folder != "/" else { return [] }
        return (try? await store.fetchInFolder(folder, excluding: item.id)) ?? []
    }

    private func loadTags(_ item: MediaItem, in store: MediaStore) async -> [MediaItem] {
        guard !item.metadata.tags.isEmpty else { return [] }
        return (try? await store.fetchBySharedTags(item.metadata.tags, excluding: item.id)) ?? []
    }
}
