import Combine
import Foundation
import XCTest
@testable import MediaViewer

@MainActor
final class FocusRelatedPanelTests: XCTestCase {
    func testPrimarySectionsCapDeduplicateAndExcludeFocus() {
        let focus = item("focus")
        let authors = (0..<15).map { item("author\($0)") }
        let similar = item("similar")
        let folder = item("folder")
        let tags = item("tags")
        let sections = FocusRelatedSections.make(author: [focus] + authors, authorTotal: 15,
            similar: [authors[0], similar, similar], folder: [similar, folder],
            tags: [focus, folder, tags], excluding: focus.id)
        XCTAssertEqual(sections.author.map(\.id), authors.prefix(12).map(\.id))
        XCTAssertEqual(sections.authorRemaining, 3)
        XCTAssertEqual(sections.similar.map(\.id), [similar.id])
        XCTAssertEqual(sections.folder.map(\.id), [folder.id])
        XCTAssertEqual(sections.tags.map(\.id), [tags.id])
        XCTAssertTrue(sections.hasPrimaryItems)
    }

    func testNoPrimaryMatchesKeepsQuietStateEvenWithMoreMatches() {
        let sections = FocusRelatedSections(folder: [item("folder")], tags: [item("tags")])
        XCTAssertFalse(sections.hasPrimaryItems)
        XCTAssertEqual(sections.authorRemaining, 0)
        XCTAssertFalse(FocusRelatedContent(item: item("focus"), sections: sections).moreExpanded)
    }

    func testSimilarRankingDropsFocusInvalidScoresAndDuplicateIDs() {
        let focus = UUID(), first = UUID(), second = UUID(), invalid = UUID()
        let ranked = FocusRelatedModel.rankedMatches([
            FocusSimilarMatch(itemID: first, score: 0.2),
            FocusSimilarMatch(itemID: focus, score: 1),
            FocusSimilarMatch(itemID: second, score: 0.9),
            FocusSimilarMatch(itemID: first, score: 0.9),
            FocusSimilarMatch(itemID: invalid, score: .nan)
        ], excluding: focus)
        XCTAssertEqual(ranked.map(\.itemID), [second, first])
        XCTAssertEqual(ranked.map(\.score), [0.9, 0.9])
    }

    func testAuthorPageCountsAllMatchesAndUsesExactAuthor() async throws {
        let author = "Alice \"A\" \\ Studio"
        let focus = item("focus", author: author)
        let matches = (0..<15).map { item("match\($0)", author: author, day: $0) }
        let partial = item("partial", author: author + " extra")
        let otherCase = item("case", author: author.lowercased())
        let (store, directory) = try await fixture([focus] + matches + [partial, otherCase])
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = try await store.fetchAuthorRelated(author, excluding: focus.id)
        XCTAssertEqual(page.total, 15)
        XCTAssertEqual(page.items.count, 12)
        XCTAssertEqual(page.items.map(\.id), matches.reversed().prefix(12).map(\.id))
        let legacy = try await store.fetchByAuthor(author, excluding: focus.id)
        XCTAssertEqual(legacy.count, 15, "The existing query keeps its over-fetch API")

        var filter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(to: &filter,
            filterText: MediaFilterBuilder.exactAuthorSearchText(author), searchScope: .all,
            visualResultIds: nil, allowVisualSearch: false)
        let library = try await store.fetchItems(filter: filter)
        XCTAssertEqual(Set(library.map(\.id)), Set([focus.id] + matches.map(\.id)))
    }

    func testExactAuthorTokenPreservesQuotesBackslashesWhitespaceAndCase() async throws {
        for author in ["alice", " Alice ", "Alice \"quoted\" \\ slash\nnext", "=name", "@user:tag", "%_"] {
            let text = MediaFilterBuilder.exactAuthorSearchText(author)
            let parsed = MediaFilterBuilder.parseSearchInput(text)
            XCTAssertEqual(parsed.exactAuthor, author)
            XCTAssertTrue(parsed.freeText.isEmpty)
            XCTAssertTrue(parsed.hasStructuredFilters)
            var filter = FilterState()
            _ = try await MediaFilterBuilder.applySearch(to: &filter, filterText: text,
                searchScope: .all, visualResultIds: nil, allowVisualSearch: false)
            XCTAssertEqual(filter.author, author)
            XCTAssertNil(filter.authorQuery)
            let token = try XCTUnwrap(LibraryFilterPresentation.tokens(in: text).first)
            XCTAssertEqual(token.label, "Author: \(author)")
            XCTAssertEqual(LibraryFilterPresentation.removing(token, from: text), "")
        }
        let ordinary = MediaFilterBuilder.parseSearchInput("author:alice")
        XCTAssertEqual(ordinary.authorQuery, "alice")
        XCTAssertNil(ordinary.exactAuthor)
    }

    func testShowAuthorLeavesDetailAndMakesOneLibraryHistoryStep() {
        let state = AppState()
        let focus = item("focus", author: "Alice")
        state.sidebarSelection = .platform("test")
        state.filterText = "old search"
        state.starredFilter = true
        state.openSingleFocus(focus)
        state.openRelatedAuthor("Alice")
        XCTAssertFalse(state.isShowingSingleFocus)
        XCTAssertEqual(state.sidebarSelection, .allMedia)
        XCTAssertEqual(MediaFilterBuilder.parseSearchInput(state.filterText).exactAuthor, "Alice")
        XCTAssertNil(state.starredFilter)
        XCTAssertTrue(state.navigateBack())
        XCTAssertEqual(state.sidebarSelection, .platform("test"))
        XCTAssertEqual(state.filterText, "old search")
        XCTAssertEqual(state.starredFilter, true)
        XCTAssertFalse(state.navigateBack(), "Author navigation should create one library transition")
    }

    func testDefaultSimilarProviderIsEmptyAndMoreLoadsOnlyWhenRequested() async throws {
        let focus = item("focus")
        let sibling = item("sibling")
        let (store, directory) = try await fixture([focus, sibling])
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = FocusRelatedModel()
        await model.load(item: focus, in: store)
        XCTAssertTrue(model.sections.similar.isEmpty)
        XCTAssertTrue(model.sections.folder.isEmpty)
        XCTAssertTrue(model.sections.tags.isEmpty)
        await model.loadMore(in: store)
        XCTAssertEqual(model.sections.folder.map(\.id), [sibling.id])
    }

    func testInjectedSimilarProviderResolvesIDsAndDeduplicatesAuthorResults() async throws {
        let focus = item("focus", author: "Alice")
        let author = item("author", author: "Alice")
        let similar = item("similar", author: "Bob")
        let (store, directory) = try await fixture([focus, author, similar])
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = FocusRelatedModel { _ in [
            FocusSimilarMatch(itemID: focus.id, score: 1),
            FocusSimilarMatch(itemID: UUID(), score: 0.99),
            FocusSimilarMatch(itemID: author.id, score: 0.98),
            FocusSimilarMatch(itemID: similar.id, score: 0.97)
        ] }
        await model.load(item: focus, in: store)
        XCTAssertEqual(model.sections.author.map(\.id), [author.id])
        XCTAssertEqual(model.sections.similar.map(\.id), [similar.id])
    }

    func testFocusedRecordTagChangesRefreshSharedTagsWithoutReloadingSimilar() async throws {
        let focus = item("focus")
        let tagged = item("tagged", tags: ["shared"], folder: "elsewhere")
        let (store, directory) = try await fixture([focus, tagged])
        defer { try? FileManager.default.removeItem(at: directory) }
        var providerCalls = 0
        let model = FocusRelatedModel { _ in providerCalls += 1; return [] }
        await model.load(item: focus, in: store, includeMore: true)
        XCTAssertTrue(model.sections.tags.isEmpty)
        let state = AppState(mediaStore: store)
        state.mediaSelectionStore.replaceItems([focus])
        var refresh: Task<Void, Never>?
        let subscription = state.mediaSelectionStore.recordChanges.sink { updated in
            refresh = Task { await model.refreshFocusedRecord(updated, in: store, includeMore: true) }
        }
        var updated = focus
        updated.metadata.tags = ["shared"]
        state.replaceCachedItemIfPresent(updated)
        await refresh?.value
        XCTAssertEqual(model.sections.tags.map(\.id), [tagged.id])
        XCTAssertEqual(providerCalls, 1)
        updated.metadata.tags = []
        state.replaceCachedItemIfPresent(updated)
        await refresh?.value
        XCTAssertTrue(model.sections.tags.isEmpty)
        XCTAssertEqual(providerCalls, 1)
        withExtendedLifetime(subscription) {}
    }

    private func item(_ name: String, author: String? = nil, tags: [String] = [],
                      folder: String = "month", day: Int = 0) -> MediaItem {
        let base = AppPaths.appDataDirectory.appendingPathComponent("synthetic-related")
            .appendingPathComponent(folder).appendingPathComponent(name)
        return MediaItem(id: UUID(), basePath: base, metadataFile: base.appendingPathExtension("md"),
            mediaFiles: [base.appendingPathExtension("jpg")],
            metadata: MediaMetadata(source: URL(string: "https://example.com/\(name)")!,
                platform: "test", author: author, archivedDate: Date(timeIntervalSince1970: Double(day) * 86_400),
                tags: tags))
    }

    private func fixture(_ items: [MediaItem]) async throws -> (MediaStore, URL) {
        let directory = AppPaths.appDataDirectory.appendingPathComponent("related-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        try await database.write { db in
            for item in items { try MediaItemRecord(from: item).insertWithFTSSync(db: db) }
        }
        return (MediaStore(database: database), directory)
    }
}
