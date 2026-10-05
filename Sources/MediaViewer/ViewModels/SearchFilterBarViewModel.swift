import Foundation
import Combine

@MainActor
final class SearchFilterBarViewModel: ObservableObject {
    @Published private(set) var resultCount: Int?
    @Published private(set) var isCounting = true
    @Published private(set) var countError: String?
    @Published private(set) var availablePlatforms: [String] = []
    @Published private(set) var platformCounts: [String: Int] = [:]
    @Published private(set) var platformError: String?
    private weak var appState: AppState?
    private var subscriptions = Set<AnyCancellable>()
    private var countTask: Task<Void, Never>?
    private var platformTask: Task<Void, Never>?
    private var countGeneration = 0
    /// The query the in-flight or last count used (limit/offset stripped), so the
    /// early resolved-query signal and the later committed filter count once.
    private var countedFilter: FilterState?
    private var platformGeneration = 0

    func configure(with appState: AppState) async {
        subscriptions.removeAll()
        countTask?.cancel()
        platformTask?.cancel()
        self.appState = appState

        // Count the exact resolved query that produces the active browser's rows.
        // In particular, do not run a second CLIP search for the badge. The browser
        // announces it before fetching, so the count runs alongside the fetch; the
        // committed filter remains the fallback and is deduplicated against it.
        appState.resolvedLibraryQuery
            .sink { [weak self] filter in self?.scheduleCount(filter) }
            .store(in: &subscriptions)
        appState.mediaSelectionStore.$committedFilter
            .compactMap { $0 }
            .sink { [weak self] filter in self?.scheduleCount(filter) }
            .store(in: &subscriptions)

        let queryChanges: [AnyPublisher<Void, Never>] = [
            appState.$filterText.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            appState.$searchScope.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            appState.$sidebarSelection.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            appState.$activeSmartFolder.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            appState.$platformFilter.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            appState.$starredFilter.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            appState.$hasOCRFilter.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            appState.$colorFilters.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            appState.$colorSearchRGB.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            appState.$pipelineAttributeFilters.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            appState.$dateRangeFilter.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(queryChanges).sink { [weak self] in
            self?.countGeneration += 1
            self?.countTask?.cancel()
            self?.countedFilter = nil
            self?.isCounting = true
            self?.countError = nil
        }.store(in: &subscriptions)

        if let store = appState.mediaStore {
            Publishers.Merge(
                store.changes.map { _ in () }.eraseToAnyPublisher(),
                NotificationCenter.default.publisher(for: .mediaStoreDidChange).map { _ in () }.eraseToAnyPublisher()
            )
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.platformTask?.cancel()
                self.platformTask = Task { await self.refreshPlatforms() }
                if let filter = self.appState?.mediaSelectionStore.committedFilter {
                    self.scheduleCount(filter, force: true)
                }
            }.store(in: &subscriptions)
        }
        await refreshPlatforms()
    }

    func refreshPlatforms() async {
        guard let store = appState?.mediaStore else { return }
        platformGeneration += 1
        let generation = platformGeneration
        do {
            let counts = try await store.fetchPlatformCounts()
            guard !Task.isCancelled, generation == platformGeneration else { return }
            platformCounts = counts
            availablePlatforms = counts.keys.sorted()
            platformError = nil
        } catch {
            guard !Task.isCancelled, generation == platformGeneration else { return }
            platformError = "Could not refresh archive totals."
            logError("Platform totals: \(error)")
        }
    }

    private func scheduleCount(_ filter: FilterState, force: Bool = false) {
        guard let store = appState?.mediaStore else { return }
        var query = filter
        query.limit = 0
        query.offset = 0
        guard force || query != countedFilter else { return }
        countedFilter = query
        countTask?.cancel()
        countGeneration += 1
        let generation = countGeneration
        isCounting = true
        countTask = Task { [weak self] in
            do {
                let count = try await store.countItems(filter: filter)
                guard let self, !Task.isCancelled, generation == self.countGeneration else { return }
                self.resultCount = count
                self.countError = nil
                self.isCounting = false
            } catch {
                guard let self, !Task.isCancelled, generation == self.countGeneration else { return }
                self.resultCount = nil
                self.countError = "Count unavailable; change a filter or retry the query."
                self.isCounting = false
                logError("Result count: \(error)")
            }
        }
    }

    deinit { countTask?.cancel(); platformTask?.cancel() }
}
