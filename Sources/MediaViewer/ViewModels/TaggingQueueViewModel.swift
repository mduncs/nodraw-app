import SwiftUI
import Foundation
import Combine

/// Drives the batch tagging queue -- a keyboard-driven mode that lets
/// users fly through items and assign tags via number/letter keys mapped
/// to the hierarchical tag tree.
@MainActor
final class TaggingQueueViewModel: ObservableObject {

    // MARK: - Types

    enum QueueScope {
        case untagged                   // items with empty tags
        case folder(String)             // specific folder path (untagged within folder)
        case selection(Set<UUID>)       // manual selection for retagging

        /// Why a queue for this scope came back empty.
        var emptyMessage: String {
            switch self {
            case .untagged: return "No untagged items in the library"
            case .folder: return "No untagged items in this folder"
            case .selection: return "None of the selected items are available to tag"
            }
        }
    }

    struct HistoryEntry: Identifiable {
        let id = UUID()
        let item: MediaItem
        let addedTags: [String]
        let removedTags: [String]
        let queueIndex: Int
        let wasSkipped: Bool

        /// Compatibility/readability name used by existing history UI and tests.
        var appliedTags: [String] { addedTags }
    }

    private struct StagedChanges {
        var additions: Set<String> = []
        var removals: Set<String> = []
    }

    enum TagCreationError: Equatable {
        case emptyName
        case duplicateName(String)
        case branchUnavailable
        case rejected

        var message: String {
            switch self {
            case .emptyName:
                return "Enter a tag name."
            case .duplicateName(let name):
                return "A tag named '\(name)' already exists."
            case .branchUnavailable:
                return "That tag branch no longer exists."
            case .rejected:
                return "The tag could not be created."
            }
        }
    }

    enum NavigationDirection {
        case forward
        case backward
    }

    enum TagStagingState: Equatable {
        case available
        case onItem
        case adding
        case removing
    }

    // MARK: - Published State

    @Published var isActive: Bool = false
    @Published var currentItem: MediaItem?
    @Published var currentIndex: Int = 0
    @Published var totalCount: Int = 0
    @Published var emptyQueueMessage: String? = nil

    // Tree navigation
    @Published var currentLevel: [TagTreeNode] = []     // nodes at current depth
    @Published var navigationPath: [TagTreeNode] = []   // breadcrumb of drilled-into nodes
    @Published var selectedLeafTags: Set<String> = []   // multi-select at leaf level
    @Published private(set) var stagedRemovalTags: Set<String> = []

    // Queue/session status. Position and completed work are intentionally separate.
    @Published private(set) var completedCount: Int = 0
    @Published private(set) var skippedCount: Int = 0
    @Published private(set) var changedCount: Int = 0
    @Published private(set) var operationError: String?
    @Published private(set) var isPerformingAction: Bool = false

    // H2: Animation direction tracking
    @Published var navigationDirection: NavigationDirection = .forward

    // H5: Undo history
    @Published var history: [HistoryEntry] = []

    // Inline tag creation feedback
    @Published private(set) var tagCreationError: TagCreationError?

    // M4: Onboarding hint
    @Published var showOnboardingHint: Bool = false

    // MARK: - Private

    private var queue: [MediaItem] = []
    private var stagedChangesByItemID: [UUID: StagedChanges] = [:]
    private let mediaStore: MediaStore
    private let tagSettings: TagSettings
    private var tagDefinitionsCancellable: AnyCancellable?
    private var isAdvancing = false
    private static let maxHistorySize = 10
    private var onboardingDismissTask: Task<Void, Never>?

    var existingTags: [String] {
        (currentItem?.metadata.tags ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var pendingAdditions: [String] {
        selectedLeafTags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var pendingRemovals: [String] {
        stagedRemovalTags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var remainingCount: Int { max(0, totalCount - completedCount) }
    var canMoveBackward: Bool { currentIndex > 0 }
    var canMoveForward: Bool { currentIndex + 1 < queue.count }

    var progressDescription: String {
        "Item \(min(currentIndex + 1, totalCount)) of \(totalCount), "
            + "\(completedCount) reviewed, \(remainingCount) remaining"
    }

    func stagingState(for tagName: String) -> TagStagingState {
        let key = TagCanonicalizer.key(tagName)
        if stagedRemovalTags.contains(where: { TagCanonicalizer.key($0) == key }) { return .removing }
        if selectedLeafTags.contains(where: { TagCanonicalizer.key($0) == key }) { return .adding }
        if existingTags.contains(where: { TagCanonicalizer.key($0) == key }) { return .onItem }
        return .available
    }

    /// Leaf tags anywhere in the tree matching `query`, with their paths, so a large
    /// vocabulary is reachable without drilling or scanning the no-shortcut overflow.
    /// Parent tags are excluded because the queue stages leaves only.
    func tagSearchResults(for query: String, limit: Int = 8) -> [TagDefinitionSearch.Match] {
        // Search the whole tree so a parent name finds its leaves, then keep leaves.
        let leaves = TagDefinitionSearch.matches(query: query, in: tagSettings.definitions)
            .filter { tagSettings.isLeaf($0.definition.id) }
        return Array(leaves.prefix(limit))
    }

    func canStageTag(named tagName: String) -> Bool {
        let key = TagCanonicalizer.key(tagName)
        if existingTags.contains(where: { TagCanonicalizer.key($0) == key }) { return true }
        guard let definition = tagSettings.definitions.first(where: {
            TagCanonicalizer.key($0.name) == key
        }) else { return false }
        return tagSettings.isLeaf(definition.id)
    }

    // MARK: - Init

    init(mediaStore: MediaStore, tagSettings: TagSettings? = nil) {
        self.mediaStore = mediaStore
        self.tagSettings = tagSettings ?? TagSettings.shared

        tagDefinitionsCancellable = self.tagSettings.$definitions
            // @Published emits from willSet; receive on the main run loop so the
            // authoritative definitions have been stored before rebuilding the tree.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshTagTreeAfterDefinitionChange()
            }
    }

    deinit {
        tagDefinitionsCancellable?.cancel()
    }

    // MARK: - Queue Lifecycle

    /// Start a tagging queue with the given scope.
    /// If `startingItemId` is provided, the queue begins at that item instead of the first.
    func startQueue(scope: QueueScope, startingItemId: UUID? = nil) async {
        do {
            let items: [MediaItem]
            switch scope {
            case .untagged:
                // Use SmartFolder mechanism -- tagsEmpty rule is already defined
                var filter = FilterState()
                filter.smartFolder = SmartFolder(
                    name: "_tagging_queue",
                    icon: "tag.slash",
                    rules: [.tagsEmpty]
                )
                filter.limit = -1 // explicit no limit -- load all untagged
                items = try await mediaStore.fetchItems(filter: filter)

            case .folder(let path):
                var filter = FilterState()
                filter.smartFolder = SmartFolder(
                    name: "_tagging_queue",
                    icon: "tag.slash",
                    rules: [.tagsEmpty]
                )
                filter.folderPath = path
                filter.limit = -1
                items = try await mediaStore.fetchItems(filter: filter)

            case .selection(let ids):
                // A Set has no stable iteration order; sort once so next/previous and resume
                // remain deterministic across launches.
                items = try await mediaStore.fetchItems(
                    ids: ids.sorted { $0.uuidString < $1.uuidString }
                )
            }

            guard !items.isEmpty else {
                logInfo("TaggingQueue: No items found for scope")
                emptyQueueMessage = scope.emptyMessage
                currentItem = nil
                isActive = false
                return
            }

            emptyQueueMessage = nil
            queue = items
            totalCount = items.count
            history.removeAll()
            stagedChangesByItemID.removeAll()
            completedCount = 0
            skippedCount = 0
            changedCount = 0
            operationError = nil

            // An explicit starting item wins. Otherwise resume only when the persisted item
            // still belongs to this freshly fetched scope.
            let requestedStartID = startingItemId ?? SettingsStore.shared.taggingQueueResumeItemID
            if let startId = requestedStartID,
               let idx = items.firstIndex(where: { $0.id == startId }) {
                currentIndex = idx
            } else {
                currentIndex = 0
            }
            currentItem = items[currentIndex]
            selectedLeafTags.removeAll()
            stagedRemovalTags.removeAll()
            navigationPath.removeAll()
            tagCreationError = nil
            resetCurrentLevel()
            isActive = true
            persistResumePosition()

            // M4: Show onboarding hint on first HUD show
            if !UserDefaults.standard.bool(forKey: "taggingHUDOnboardingShown") {
                showOnboardingHint = true
                onboardingDismissTask = Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if !Task.isCancelled {
                        dismissOnboardingHint()
                    }
                }
            }

        } catch {
            logError("TaggingQueue: Failed to load items: \(error.localizedDescription)")
            // Callers show this message; without it a load failure read as "all tagged".
            emptyQueueMessage = "Couldn’t load the tagging queue: \(error.localizedDescription)"
            currentItem = nil
            isActive = false
        }
    }

    func dismissOnboardingHint() {
        guard showOnboardingHint else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            showOnboardingHint = false
        }
        UserDefaults.standard.set(true, forKey: "taggingHUDOnboardingShown")
        onboardingDismissTask?.cancel()
        onboardingDismissTask = nil
    }

    /// Exit tagging mode and reset all state.
    /// The current focused item is preserved -- caller decides navigation.
    func exitTagging(clearResumePosition: Bool = false) {
        if clearResumePosition {
            SettingsStore.shared.taggingQueueResumeItemID = nil
        } else {
            persistCurrentStagedChanges()
            persistResumePosition()
        }
        isActive = false
        currentItem = nil
        queue = []
        stagedChangesByItemID = [:]
        navigationPath = []
        selectedLeafTags = []
        stagedRemovalTags = []
        currentLevel = []
        currentIndex = 0
        totalCount = 0
        emptyQueueMessage = nil
        history.removeAll()
        completedCount = 0
        skippedCount = 0
        changedCount = 0
        operationError = nil
        isPerformingAction = false
        tagCreationError = nil
        onboardingDismissTask?.cancel()
        onboardingDismissTask = nil
    }

    /// Keep the tagging cursor aligned when focus navigation changes the visible item directly.
    /// Pending tag choices and tree depth belong to the prior item, so they reset just as they do
    /// after the queue's normal item advance. Tagging history remains intact for explicit undo.
    @discardableResult
    func synchronizeFocusedItem(
        _ item: MediaItem,
        navigationItemsIfQueueUnavailable: [MediaItem]? = nil
    ) -> Bool {
        guard isActive else { return false }

        if queue.isEmpty, let navigationItemsIfQueueUnavailable {
            queue = navigationItemsIfQueueUnavailable
            totalCount = queue.count
        }

        guard let index = queue.firstIndex(where: { $0.id == item.id }) else {
            return false
        }

        persistCurrentStagedChanges()
        navigationDirection = index < currentIndex ? .backward : .forward
        queue[index] = item
        currentIndex = index
        currentItem = item
        restoreStagedChanges(for: item.id)
        navigationPath.removeAll()
        tagCreationError = nil
        operationError = nil
        resetCurrentLevel()
        persistResumePosition()
        return true
    }

    // MARK: - Key Handling

    /// Handle a key press -- drill into tree or toggle leaf selection.
    /// Returns true if the key matched a node and was consumed.
    @discardableResult
    func handleKeyPress(_ key: Character) -> Bool {
        // M4: Dismiss onboarding on any keypress
        if showOnboardingHint {
            dismissOnboardingHint()
        }

        let lowered = Character(key.lowercased())
        guard let node = currentLevel.first(where: { $0.keyBinding == lowered }) else { return false }

        selectNode(node)
        return true
    }

    func selectNode(_ node: TagTreeNode) {
        if showOnboardingHint {
            dismissOnboardingHint()
        }

        if node.isLeaf {
            toggleLeafTag(named: node.name)
        } else {
            // H2: Drill into children with forward animation
            withAnimation(.easeInOut(duration: 0.15)) {
                navigationDirection = .forward
                navigationPath.append(node)
                var children = node.children
                TagTreeNode.assignKeyBindings(to: &children)
                currentLevel = children
            }
        }
    }

    /// Toggle a pending leaf selection. Both keyboard and pointer activation use this path.
    func toggleLeafTag(named name: String) {
        operationError = nil
        let requestedKey = TagCanonicalizer.key(name)
        let existingDisplayName = existingTags.first { TagCanonicalizer.key($0) == requestedKey }
        let definition = tagSettings.definitions.first { TagCanonicalizer.key($0.name) == requestedKey }
        guard existingDisplayName != nil || definition.map({ tagSettings.isLeaf($0.id) }) == true else { return }

        if let existingDisplayName {
            selectedLeafTags = Set(selectedLeafTags.filter {
                TagCanonicalizer.key($0) != requestedKey
            })
            if let stagedName = stagedRemovalTags.first(where: {
                TagCanonicalizer.key($0) == requestedKey
            }) {
                stagedRemovalTags.remove(stagedName)
            } else {
                stagedRemovalTags.insert(existingDisplayName)
            }
        } else {
            guard let definition else { return }
            stagedRemovalTags = Set(stagedRemovalTags.filter {
                TagCanonicalizer.key($0) != requestedKey
            })
            if let selectedName = selectedLeafTags.first(where: {
                TagCanonicalizer.key($0) == requestedKey
            }) {
                selectedLeafTags.remove(selectedName)
            } else {
                selectedLeafTags.insert(definition.name)
            }
        }
        persistCurrentStagedChanges()
    }

    /// Create a leaf at the currently visible branch (or at root) and select it immediately.
    /// TagSettings remains the single authority for validation, ordering, and persistence.
    @discardableResult
    func createTag(named rawName: String) -> Bool {
        let name: String
        switch tagSettings.validateName(rawName) {
        case .empty:
            tagCreationError = .emptyName
            return false
        case .duplicate(let existingName):
            tagCreationError = .duplicateName(existingName)
            return false
        case .valid(let displayName):
            name = displayName
        }

        let parentID = navigationPath.last?.id
        if let parentID,
           !tagSettings.definitions.contains(where: { $0.id == parentID }) {
            tagCreationError = .branchUnavailable
            refreshTagTreeAfterDefinitionChange()
            return false
        }

        guard tagSettings.addChildTag(name: name, parentId: parentID) else {
            tagCreationError = .rejected
            return false
        }

        // The definitions publisher also refreshes on the next main-run-loop turn. Refresh now so
        // the new chip and its pending selection are usable in the same interaction.
        refreshTagTreeAfterDefinitionChange()
        selectedLeafTags.insert(name)
        persistCurrentStagedChanges()
        tagCreationError = nil
        return true
    }

    func clearTagCreationError() {
        tagCreationError = nil
    }

    /// Enter key -- confirm tags and advance to next item.
    func confirmAndAdvance() async {
        guard !isAdvancing else { return }
        isAdvancing = true
        isPerformingAction = true
        operationError = nil
        defer { isAdvancing = false }
        defer { isPerformingAction = false }
        guard let item = currentItem else { return }

        // Determine what to tag:
        // 1. If selectedLeafTags is not empty, apply those
        // 2. If nothing selected but we drilled into a node, apply the deepest navigated tag
        // 3. If nothing selected and nothing navigated, skip (no tag applied)
        var tagsToApply: [String] = []
        if !selectedLeafTags.isEmpty {
            tagsToApply = pendingAdditions
        } else if stagedRemovalTags.isEmpty, let lastDrilled = navigationPath.last {
            tagsToApply = [lastDrilled.name]
        }
        let tagsToRemove = pendingRemovals
        let existingTagKeys = Set(existingTags.map(TagCanonicalizer.key))
        let tagsToAdd = tagsToApply.filter {
            !existingTagKeys.contains(TagCanonicalizer.key($0))
        }

        var completedRemovals: [String] = []
        var completedAdditions: [String] = []
        do {
            for tag in tagsToRemove {
                try await mediaStore.removeTag(id: item.id, tag: tag)
                completedRemovals.append(tag)
            }
            for tag in tagsToAdd {
                try await mediaStore.addTag(id: item.id, tag: tag)
                completedAdditions.append(tag)
            }
        } catch {
            // Existing MediaStore actions are single-tag operations. Compensate in reverse
            // order so a mid-save error does not silently leave the item half changed.
            for tag in completedAdditions.reversed() {
                try? await mediaStore.removeTag(id: item.id, tag: tag)
            }
            for tag in completedRemovals.reversed() {
                try? await mediaStore.addTag(id: item.id, tag: tag)
            }
            operationError = "Couldn’t save tag changes: \(error.localizedDescription)"
            logError("TaggingQueue: Failed to save tag changes: \(error.localizedDescription)")
            return
        }

        // Keep the queue snapshot truthful without forcing a refetch between items.
        var updatedItem = item
        let removalKeys = Set(tagsToRemove.map(TagCanonicalizer.key))
        updatedItem.metadata.tags.removeAll { removalKeys.contains(TagCanonicalizer.key($0)) }
        var updatedKeys = Set(updatedItem.metadata.tags.map(TagCanonicalizer.key))
        for tag in tagsToAdd where updatedKeys.insert(TagCanonicalizer.key(tag)).inserted {
            updatedItem.metadata.tags.append(tag)
            if let definition = tagSettings.definitions.first(where: {
                TagCanonicalizer.key($0.name) == TagCanonicalizer.key(tag)
            }) {
                tagSettings.recordTagUsage(definition.id)
            }
        }
        queue[currentIndex] = updatedItem
        currentItem = updatedItem

        // H5: Push to history before advancing. The original item snapshot makes both
        // additions and removals exactly reversible.
        let entry = HistoryEntry(
            item: item,
            addedTags: tagsToAdd,
            removedTags: tagsToRemove,
            queueIndex: currentIndex,
            wasSkipped: false
        )
        history.append(entry)
        if history.count > Self.maxHistorySize {
            history.removeFirst()
        }

        completedCount += 1
        if !tagsToAdd.isEmpty || !tagsToRemove.isEmpty { changedCount += 1 }
        stagedChangesByItemID.removeValue(forKey: item.id)
        await advanceToNext()
    }

    /// H5: Go back to the previous item, undoing tags that were applied.
    func undoAndGoBack() async {
        guard !isAdvancing, !history.isEmpty else { return }
        isAdvancing = true
        defer { isAdvancing = false }

        let entry = history.removeLast()
        operationError = nil
        isPerformingAction = true
        defer { isPerformingAction = false }

        // Reverse additions, then restore removals.
        var notRemoved: [String] = []
        var notRestored: [String] = []
        for tag in entry.appliedTags {
            do {
                try await mediaStore.removeTag(id: entry.item.id, tag: tag)
            } catch {
                notRemoved.append(tag)
                logError("TaggingQueue: Failed to undo tag '\(tag)': \(error.localizedDescription)")
            }
        }
        for tag in entry.removedTags {
            do {
                try await mediaStore.addTag(id: entry.item.id, tag: tag)
            } catch {
                notRestored.append(tag)
                logError("TaggingQueue: Failed to restore tag '\(tag)': \(error.localizedDescription)")
            }
        }

        // Restore item as current. After a partial failure, show the saved state
        // rather than the pre-change snapshot, which would no longer be true.
        var restoredItem = entry.item
        if !notRemoved.isEmpty || !notRestored.isEmpty {
            if let saved = try? await mediaStore.fetchItem(id: entry.item.id) {
                restoredItem = saved
            }
            operationError = Self.incompleteUndoMessage(notRemoved: notRemoved, notRestored: notRestored)
        }
        currentIndex = entry.queueIndex
        if queue.indices.contains(entry.queueIndex) {
            queue[entry.queueIndex] = restoredItem
        }
        currentItem = restoredItem
        // Only restore tags that are actual leaves in the tag tree.
        // Parent tags may have been auto-applied when the user drilled without selecting.
        let leafOnly = entry.appliedTags.filter { tagName in
            guard let def = tagSettings.definitions.first(where: {
                TagCanonicalizer.key($0.name) == TagCanonicalizer.key(tagName)
            }) else {
                return true // unknown tag -- keep it, safer default
            }
            return tagSettings.isLeaf(def.id)
        }
        selectedLeafTags = Set(leafOnly)
        stagedRemovalTags = Set(entry.removedTags)
        stagedChangesByItemID[entry.item.id] = StagedChanges(
            additions: selectedLeafTags,
            removals: stagedRemovalTags
        )
        completedCount = max(0, completedCount - 1)
        if entry.wasSkipped {
            skippedCount = max(0, skippedCount - 1)
        } else if !entry.addedTags.isEmpty || !entry.removedTags.isEmpty {
            changedCount = max(0, changedCount - 1)
        }
        navigationPath.removeAll()
        resetCurrentLevel()
        persistResumePosition()

        logInfo("TaggingQueue: Undid tagging on item \(entry.item.id), restored \(entry.appliedTags.count) tags as selected")
    }

    static func incompleteUndoMessage(notRemoved: [String], notRestored: [String]) -> String {
        var parts: [String] = []
        if !notRemoved.isEmpty {
            parts.append("couldn’t remove \(notRemoved.map { "‘\($0)’" }.joined(separator: ", "))")
        }
        if !notRestored.isEmpty {
            parts.append("couldn’t restore \(notRestored.map { "‘\($0)’" }.joined(separator: ", "))")
        }
        return "Undo was incomplete: " + parts.joined(separator: "; ") + ". Showing the item’s saved tags."
    }

    /// Skip current item without tagging.
    func skipItem() async {
        guard !isAdvancing else { return }
        isAdvancing = true
        isPerformingAction = true
        operationError = nil
        defer { isAdvancing = false }
        defer { isPerformingAction = false }
        guard let item = currentItem else { return }
        history.append(HistoryEntry(
            item: item,
            addedTags: [],
            removedTags: [],
            queueIndex: currentIndex,
            wasSkipped: true
        ))
        if history.count > Self.maxHistorySize { history.removeFirst() }
        completedCount += 1
        skippedCount += 1
        stagedChangesByItemID.removeValue(forKey: item.id)
        await advanceToNext()
    }

    /// Move through the queue without committing the current staged changes.
    /// Arrow navigation can call these methods while Enter and Tab remain confirm/skip.
    @discardableResult
    func moveToPreviousItem() -> Bool {
        guard canMoveBackward else { return false }
        moveCursor(to: currentIndex - 1, direction: .backward)
        return true
    }

    @discardableResult
    func moveToNextItem() -> Bool {
        guard canMoveForward else { return false }
        moveCursor(to: currentIndex + 1, direction: .forward)
        return true
    }

    /// Jump to a specific breadcrumb level. -1 = root, 0 = first drilled node, etc.
    /// Truncates navigationPath and resets currentLevel accordingly.
    func jumpToLevel(_ index: Int) {
        // H2: Animate breadcrumb jumps backward
        withAnimation(.easeInOut(duration: 0.15)) {
            navigationDirection = .backward
            if index < 0 {
                // Jump to root
                navigationPath.removeAll()
            } else {
                // Keep path up to and including index
                let keepCount = min(index + 1, navigationPath.count)
                navigationPath = Array(navigationPath.prefix(keepCount))
            }
            resetCurrentLevel()
        }
    }

    /// Go back up one tree level (Escape/Backspace) without losing pending leaf selections.
    /// At root, Escape still clears pending selections before a subsequent Escape exits.
    func goBack() {
        if !navigationPath.isEmpty {
            withAnimation(.easeInOut(duration: 0.15)) {
                navigationDirection = .backward
                navigationPath.removeLast()
                resetCurrentLevel()
            }
        } else if !selectedLeafTags.isEmpty || !stagedRemovalTags.isEmpty {
            selectedLeafTags.removeAll()
            stagedRemovalTags.removeAll()
            persistCurrentStagedChanges()
        } else {
            exitTagging()
        }
    }

    // MARK: - Private Helpers

    /// Reconcile the visible tree after TagSettings changes without disturbing the queue.
    /// Breadcrumb nodes are matched by definition ID and only remain in the path while their
    /// parent/child relationship is still valid in the authoritative tree.
    private func refreshTagTreeAfterDefinitionChange() {
        guard isActive else { return }

        let requestedPath = navigationPath.map(\.id)
        let roots = TagTreeNode.buildTree(from: tagSettings)

        var validPath: [TagTreeNode] = []
        var nextLevel = roots
        for nodeID in requestedPath {
            guard let node = nextLevel.first(where: { $0.id == nodeID }) else { break }
            validPath.append(node)
            nextLevel = node.children
        }

        navigationPath = validPath

        var refreshedLevel = validPath.last?.children ?? roots
        TagTreeNode.assignKeyBindings(to: &refreshedLevel)
        currentLevel = refreshedLevel

        let leafNames = Set(
            tagSettings.definitions
                .filter { tagSettings.isLeaf($0.id) }
                .map { TagCanonicalizer.key($0.name) }
        )
        selectedLeafTags = Set(
            selectedLeafTags.filter { leafNames.contains(TagCanonicalizer.key($0)) }
        )
        let existingKeys = Set(existingTags.map(TagCanonicalizer.key))
        stagedRemovalTags = Set(
            stagedRemovalTags.filter { existingKeys.contains(TagCanonicalizer.key($0)) }
        )
        persistCurrentStagedChanges()
    }

    private func advanceToNext() async {
        let nextIndex = currentIndex + 1
        selectedLeafTags.removeAll()
        stagedRemovalTags.removeAll()
        navigationPath.removeAll()
        tagCreationError = nil
        operationError = nil
        resetCurrentLevel()

        if nextIndex < queue.count {
            moveCursor(to: nextIndex, direction: .forward, preserveCurrentStage: false)
        } else {
            // Queue exhausted -- exit before index goes out of range
            exitTagging(clearResumePosition: true)
        }
    }

    private func moveCursor(
        to index: Int,
        direction: NavigationDirection,
        preserveCurrentStage: Bool = true
    ) {
        guard queue.indices.contains(index) else { return }
        if preserveCurrentStage { persistCurrentStagedChanges() }
        navigationDirection = direction
        currentIndex = index
        currentItem = queue[index]
        restoreStagedChanges(for: queue[index].id)
        navigationPath.removeAll()
        tagCreationError = nil
        operationError = nil
        resetCurrentLevel()
        persistResumePosition()
    }

    private func persistCurrentStagedChanges() {
        guard let itemID = currentItem?.id else { return }
        if selectedLeafTags.isEmpty && stagedRemovalTags.isEmpty {
            stagedChangesByItemID.removeValue(forKey: itemID)
        } else {
            stagedChangesByItemID[itemID] = StagedChanges(
                additions: selectedLeafTags,
                removals: stagedRemovalTags
            )
        }
    }

    private func restoreStagedChanges(for itemID: UUID) {
        let staged = stagedChangesByItemID[itemID] ?? StagedChanges()
        selectedLeafTags = staged.additions
        stagedRemovalTags = staged.removals
    }

    private func persistResumePosition() {
        guard isActive, let itemID = currentItem?.id else { return }
        SettingsStore.shared.taggingQueueResumeItemID = itemID
    }

    private func resetCurrentLevel() {
        if navigationPath.isEmpty {
            // Show root
            var roots = TagTreeNode.buildTree(from: tagSettings)
            TagTreeNode.assignKeyBindings(to: &roots)
            currentLevel = roots
        } else {
            // Show children of last navigated node
            var children = navigationPath.last!.children
            TagTreeNode.assignKeyBindings(to: &children)
            currentLevel = children
        }
    }
}
