import SwiftUI
import Combine

protocol DuplicateTriageDetecting: Sendable {
    func detectDuplicates() async throws -> Int
    func cancelDetection() async
    func getProgress() async -> DuplicateDetector.DetectionProgress
}
extension DuplicateDetector: DuplicateTriageDetecting {}

/// Owns one bounded review deck. All commands capture identity before suspension;
/// generation tokens prevent old loads and reload notifications from replacing a decision.
@MainActor
final class DuplicateTriageViewModel: ObservableObject {
    enum Category: String, CaseIterable { case all = "All", exact = "Exact copies", similar = "Look-alikes" }
    @Published private(set) var groups: [DuplicateGroup] = []
    @Published private(set) var currentIndex = 0
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var snapshot: DuplicateReviewSnapshot?
    @Published private(set) var selectedIDs = Set<UUID>()
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: DuplicateDetector.DetectionProgress = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var historyEntries: [DuplicateReviewHistoryEntry] = []
    @Published var category: Category = .all
    @Published var showingLater = false

    private let detector: any DuplicateTriageDetecting
    private let service: any DuplicateReviewServicing
    private var allGroups: [DuplicateGroup] = []
    private var generation: UInt64 = 0
    private var pendingReload = false
    private var cancellables = Set<AnyCancellable>()
    private var scanTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    init(detector: any DuplicateTriageDetecting, service: any DuplicateReviewServicing, notificationCenter: NotificationCenter = .default) {
        self.detector = detector; self.service = service
        notificationCenter.publisher(for: .duplicateGroupsDidChange)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.isApplying { self.pendingReload = true; return }
                    await self.loadGroups()
                }
            }.store(in: &cancellables)
    }

    /// Mirrors `DuplicateReviewService.fetchGroups` LIMIT.
    static let batchLimit = 200

    struct EmptyStateCopy: Equatable { let icon: String; let title: String; let detail: String }

    /// What an empty deck means depends on the queue and on whether a scan just finished.
    var emptyStateCopy: EmptyStateCopy {
        if showingLater {
            return EmptyStateCopy(icon: "tray", title: "Nothing set aside",
                detail: "Groups you mark Later wait here. Turn off Set-aside queue to see groups still to review.")
        }
        let kind: String
        switch category {
        case .all: kind = "duplicates"
        case .exact: kind = "exact copies"
        case .similar: kind = "look-alikes"
        }
        if case .complete(let found, _, _, _) = scanProgress {
            if found == 0 {
                return EmptyStateCopy(icon: "checkmark.circle", title: "No duplicates found",
                    detail: (["Every exact copy was checked; look-alike matching can miss a few."]
                        + scanProgress.completionDetails).joined(separator: " "))
            }
            return EmptyStateCopy(icon: "checkmark.circle", title: "No \(kind) in this queue",
                detail: "Change the review filters or scan again after adding or changing files. \(scanProgress.displayText)")
        }
        return EmptyStateCopy(icon: "doc.on.doc", title: "No \(kind) to review",
            detail: "Scan to compare the files currently in your library. An empty queue before a scan doesn't mean there are no duplicates.")
    }

    var currentGroup: DuplicateGroup? { groups.indices.contains(currentIndex) ? groups[currentIndex] : nil }
    var totalCount: Int { groups.count }
    var isEmpty: Bool { groups.isEmpty }
    var selectedIndex: Int? { items.firstIndex { selectedIDs.contains($0.id) } }
    var canDecide: Bool { !isLoading && !isApplying && !isScanning && snapshot?.groupID == currentGroup?.id && !items.isEmpty }
    var rejectedCount: Int { items.count - selectedIDs.count }

    func loadGroups() async {
        guard !isApplying else { pendingReload = true; return }
        generation &+= 1
        let token = generation
        let previousID = currentGroup?.id
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await service.fetchGroups(includeLater: showingLater, exactOnly: category == .all ? nil : category == .exact)
            guard generation == token, !isApplying else { return }
            allGroups = loaded
            filterDeck(keeping: previousID)
            try await loadCurrentGroup(token: token)
            guard generation == token else { return }
            isLoading = false
        } catch {
            guard generation == token else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func updateFilter() async {
        await loadGroups() // apply category in SQL before LIMIT, never starve look-alikes
    }

    private func filterDeck(keeping id: UUID?) {
        groups = allGroups.filter { group in
            category == .all || (category == .exact ? group.detectionMethod == .exactDuplicate : group.detectionMethod != .exactDuplicate)
        }
        currentIndex = id.flatMap { id in groups.firstIndex { $0.id == id } } ?? min(currentIndex, max(0, groups.count - 1))
        clearItems()
    }

    private func clearItems() { items = []; snapshot = nil; selectedIDs = [] }

    private func loadCurrentGroup(token: UInt64) async throws {
        guard let group = currentGroup else { clearItems(); return }
        // Clear immediately. The next group's header may never accompany the previous items.
        clearItems()
        let detail = try await service.load(groupID: group.id)
        guard token == generation, group.id == currentGroup?.id, !isApplying else { return }
        items = detail.items
        snapshot = detail.snapshot
        // Keep is an explicit selection, never a hidden 'highest quality' recommendation.
        selectedIDs = group.primaryItemId.map { [$0] } ?? Set(items.prefix(1).map(\.id))
    }

    private func loadSelection(token: UInt64) async {
        isLoading = true; errorMessage = nil
        do { try await loadCurrentGroup(token: token) }
        catch { if token == generation { errorMessage = error.localizedDescription } }
        if token == generation { isLoading = false }
    }

    func skipToNext() { navigate(delta: 1) }
    func goToPrevious() { navigate(delta: -1) }
    private func navigate(delta: Int) {
        guard !isApplying, groups.indices.contains(currentIndex + delta) else { return }
        generation &+= 1
        let token = generation
        currentIndex += delta
        clearItems(); isLoading = true
        Task { await loadSelection(token: token) }
    }

    func selectItem(_ index: Int) {
        guard canDecide, items.indices.contains(index) else { return }
        selectedIDs = [items[index].id]
    }
    func toggleItem(_ id: UUID) {
        guard canDecide, items.contains(where: { $0.id == id }) else { return }
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }
    func selectNextItem() { selectItem(min((selectedIndex ?? -1) + 1, items.count - 1)) }
    func selectPreviousItem() { selectItem(max((selectedIndex ?? items.count) - 1, 0)) }

    /// Called synchronously from the button/key handler, before any animation or Task.
    func beginDecision(_ decision: TriageDecision) -> DuplicateReviewRequest? {
        guard canDecide, let snapshot,
              decision != .keepSelected || (!selectedIDs.isEmpty && rejectedCount > 0) else { return nil }
        let kept = decision == .keepSelected ? selectedIDs : Set(snapshot.itemIDs)
        let request = DuplicateReviewRequest(snapshot: snapshot, decision: decision, keptIDs: kept)
        isApplying = true
        generation &+= 1 // old reads cannot publish during this commit
        errorMessage = nil; notice = nil
        return request
    }

    func perform(_ request: DuplicateReviewRequest, undoStack: UndoStack?) async {
        guard isApplying else { return }
        do {
            try await service.apply(request)
            undoStack?.pushForUndo(DuplicateTriageUndoAction(operationID: request.id, description: request.decision.title, service: service))
            notice = request.rejectedIDs.isEmpty ? "\(request.decision.title). No items moved." : "Moved \(Self.counted(request.rejectedIDs.count, "whole item")) to Recently Deleted. Files and edits are retained."
            isApplying = false
            pendingReload = false
            await loadGroups()
            await loadHistory()
        } catch {
            isApplying = false
            errorMessage = error.localizedDescription
            // Keep the immutable failed snapshot visible; Reload is explicit. If another
            // actor announced changes mid-commit, invalidate actions until it is reloaded.
            if pendingReload { snapshot = nil; pendingReload = false }
        }
    }

    func loadHistory() async {
        do { historyEntries = try await service.history() }
        catch { errorMessage = error.localizedDescription }
    }
    func changeHistory(_ entry: DuplicateReviewHistoryEntry) async {
        guard !isApplying, !isScanning else { return }
        isApplying = true; generation &+= 1
        do {
            if entry.isUndone { try await service.redo(entry.id) } else { try await service.undo(entry.id) }
            isApplying = false; pendingReload = false
            await loadGroups(); await loadHistory()
        } catch { isApplying = false; errorMessage = error.localizedDescription }
    }

    func startScan() {
        guard !isScanning, !isApplying else { return }
        isScanning = true; errorMessage = nil; notice = nil
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.scanProgress = await self.detector.getProgress()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let count = try await self.detector.detectDuplicates()
                self.scanProgress = await self.detector.getProgress()
                self.notice = self.scanProgress.displayText + (count > 0 ? " Earlier review decisions are kept." : "")
            } catch is CancellationError { self.notice = "Scan cancelled. Previously completed results remain available." }
            catch { self.errorMessage = error.localizedDescription }
            self.scanProgress = await self.detector.getProgress()
            self.progressTask?.cancel(); self.progressTask = nil
            self.isScanning = false; self.scanTask = nil
            let failure = self.errorMessage
            await self.loadGroups()
            if let failure { self.errorMessage = failure }
        }
    }
    static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    func cancelScan() {
        scanTask?.cancel()
        Task { await detector.cancelDetection() }
    }
}
