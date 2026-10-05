import Foundation
import Combine

// MARK: - UndoableAction Protocol

/// Protocol for actions that can be undone.
/// Actions are memory-only and cleared on app quit.
protocol UndoableAction: Sendable {
    /// Human-readable description shown in toast
    var description: String { get }

    /// Execute the action (called when action is first performed)
    func execute() async throws

    /// Undo the action (called when user triggers undo)
    func undo() async throws
}

// MARK: - Legacy UndoAction (for backward compatibility)

/// Simple undo action struct for backward compatibility with existing code.
/// Use UndoableAction protocol for new code.
struct LegacyUndoAction: Sendable {
    let description: String
    let undoClosure: @Sendable () -> Void

    init(description: String, undo: @escaping @Sendable () -> Void) {
        self.description = description
        self.undoClosure = undo
    }

    func undo() {
        undoClosure()
    }
}

/// Wrapper to convert legacy UndoAction to UndoableAction
struct LegacyUndoActionWrapper: UndoableAction {
    let legacyAction: LegacyUndoAction

    var description: String { legacyAction.description }

    func execute() async throws {
        // Already executed by caller
    }

    func undo() async throws {
        legacyAction.undo()
    }
}

// MARK: - Toast Model

/// Toast notification shown after an action is performed
struct UndoToast: Equatable, Identifiable {
    let id: UUID
    let message: String
    let showUndo: Bool
    let timestamp: Date

    init(message: String, showUndo: Bool = true) {
        self.id = UUID()
        self.message = message
        self.showUndo = showUndo
        self.timestamp = Date()
    }

    static func == (lhs: UndoToast, rhs: UndoToast) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - UndoStack

/// Memory-only undo stack with max depth.
/// Cleared on app quit per ADR-008.
@MainActor
final class UndoStack: ObservableObject {
    /// Maximum number of actions to keep in history
    private let maxDepth = 20

    /// Undo stack (most recent at end)
    private var stack: [UndoableAction] = []

    /// Redo stack (for actions that were undone)
    private var redoStack: [UndoableAction] = []

    /// Current toast notification
    @Published private(set) var currentToast: UndoToast?

    /// Toast dismiss timer
    private var dismissTask: Task<Void, Never>?

    /// Whether an undo is available
    var canUndo: Bool { !stack.isEmpty }

    /// Whether a redo is available
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Perform Action

    /// Execute an action and push it onto the undo stack.
    /// Shows a toast with the action description.
    /// - Parameters:
    ///   - action: The action to perform
    ///   - skipExecution: If true, the action was already performed externally.
    ///                    Just register it for undo without executing again.
    func performAction(_ action: UndoableAction, skipExecution: Bool = false) async throws {
        // Execute the action (unless already performed externally)
        if !skipExecution {
            do { try await action.execute() }
            catch let error as DeleteService.PartialDeletionError {
                // The DB deletion committed. Keep truthful recovery/Undo even
                // though the optional filesystem portion only partly succeeded.
                pushForUndo(action)
                showToast(error.localizedDescription, showUndo: true)
                throw error
            } catch let error as BatchStarPartialFailure {
                // Successful rows remain represented by the original action so
                // one Undo restores every changed row, even before a retry.
                if !error.succeededIDs.isEmpty {
                    pushForUndo(action)
                    showToast(error.localizedDescription, showUndo: true)
                }
                throw error
            }
        }

        // Push onto stack
        stack.append(action)
        if stack.count > maxDepth {
            stack.removeFirst()
        }

        // Clear redo stack (new action invalidates redo history)
        redoStack.removeAll()

        // Show toast
        showToast(action.description, showUndo: true)
    }

    /// Push an already-executed action onto the undo stack.
    /// Use this when the action was performed externally and you just want undo capability.
    func pushForUndo(_ action: UndoableAction) {
        stack.append(action)
        if stack.count > maxDepth {
            stack.removeFirst()
        }

        // Clear redo stack (new action invalidates redo history)
        redoStack.removeAll()
    }

    /// Retry failed members of an already-captured batch-star action. This keeps
    /// the initial before-state and avoids a second undo entry for retries.
    func retryBatchStar(
        _ action: BatchStarAction,
        failedIDs: Set<UUID>,
        alreadyUndoable: Bool
    ) async throws {
        do {
            try await action.execute(only: failedIDs)
        } catch let error as BatchStarPartialFailure {
            let isUndoable = alreadyUndoable || !error.succeededIDs.isEmpty
            if !alreadyUndoable, !error.succeededIDs.isEmpty {
                pushForUndo(action)
                showToast(error.localizedDescription, showUndo: true)
            }
            throw BatchStarRetryFailure(
                succeededIDs: error.succeededIDs,
                failedIDs: error.failedIDs,
                isUndoable: isUndoable
            )
        }

        if !alreadyUndoable {
            pushForUndo(action)
        }
        showToast(action.description, showUndo: true)
    }

    // MARK: - Undo

    /// Undo the most recent action.
    /// Returns the action that was undone, or nil if stack is empty.
    @discardableResult
    func undo() async throws -> UndoableAction? {
        guard let action = stack.popLast() else { return nil }

        // Undo the action
        do { try await action.undo() }
        catch {
            stack.append(action)
            throw error
        }

        // Push to redo stack
        redoStack.append(action)
        if redoStack.count > maxDepth {
            redoStack.removeFirst()
        }

        // Show toast
        showToast("Undid: \(action.description)", showUndo: false)

        return action
    }

    // MARK: - Redo

    /// Redo the most recently undone action.
    /// Returns the action that was redone, or nil if redo stack is empty.
    @discardableResult
    func redo() async throws -> UndoableAction? {
        guard let action = redoStack.popLast() else { return nil }

        // Re-execute the action
        do { try await action.execute() }
        catch let error as DeleteService.PartialDeletionError {
            stack.append(action)
            showToast(error.localizedDescription, showUndo: true)
            throw error
        } catch let error as BatchStarPartialFailure {
            if !error.succeededIDs.isEmpty {
                stack.append(action)
                showToast(error.localizedDescription, showUndo: true)
            } else {
                redoStack.append(action)
            }
            throw error
        } catch {
            redoStack.append(action)
            throw error
        }

        // Push back to undo stack
        stack.append(action)
        if stack.count > maxDepth {
            stack.removeFirst()
        }

        // Show toast
        showToast("Redid: \(action.description)", showUndo: true)

        return action
    }

    // MARK: - Toast Management

    /// Show a toast notification with auto-dismiss after 4 seconds.
    private func showToast(_ message: String, showUndo: Bool) {
        // Cancel existing dismiss timer
        dismissTask?.cancel()

        // Set new toast
        currentToast = UndoToast(message: message, showUndo: showUndo)

        // Schedule auto-dismiss
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.currentToast = nil
            }
        }
    }

    /// Dismiss the current toast immediately.
    func dismissToast() {
        dismissTask?.cancel()
        currentToast = nil
    }

    /// Show a success toast (with undo button for recently performed action)
    func showSuccessToast(_ message: String) {
        showToast(message, showUndo: true)
    }

    /// Show an info toast (no undo button)
    func showInfoToast(_ message: String) {
        showToast(message, showUndo: false)
    }

    // MARK: - Clear

    /// Clear all undo/redo history.
    func clear() {
        stack.removeAll()
        redoStack.removeAll()
        dismissTask?.cancel()
        currentToast = nil
    }
}

// MARK: - Concrete Actions

/// Toggle star state on a single item
struct ToggleStarAction: UndoableAction {
    let itemId: UUID
    let wasStarred: Bool
    let mediaStore: MediaStore

    var description: String {
        wasStarred ? "Unstarred item" : "Starred item"
    }

    func execute() async throws {
        try await mediaStore.toggleStar(id: itemId)
    }

    func undo() async throws {
        try await mediaStore.toggleStar(id: itemId)
    }
}

/// Add a tag to an item
struct AddTagAction: UndoableAction {
    let itemId: UUID
    let tag: String
    let mediaStore: MediaStore

    var description: String {
        "Added tag '\(tag)'"
    }

    func execute() async throws {
        try await mediaStore.addTag(id: itemId, tag: tag)
    }

    func undo() async throws {
        try await mediaStore.removeTag(id: itemId, tag: tag)
    }
}

/// Remove a tag from an item
struct RemoveTagAction: UndoableAction {
    let itemId: UUID
    let tag: String
    let mediaStore: MediaStore

    var description: String {
        "Removed tag '\(tag)'"
    }

    func execute() async throws {
        try await mediaStore.removeTag(id: itemId, tag: tag)
    }

    func undo() async throws {
        try await mediaStore.addTag(id: itemId, tag: tag)
    }
}

/// Move a tag within the hierarchy (reparent and/or reorder).
/// Captures the tag's prior (parent, index) so undo restores it exactly.
/// Registered with `pushForUndo` after the UI has already performed the move.
struct MoveTagAction: UndoableAction {
    let tagId: UUID
    let tagName: String
    let oldParentId: UUID?
    let oldIndex: Int
    let newParentId: UUID?
    let newIndex: Int

    var description: String {
        "Moved tag '\(tagName)'"
    }

    func execute() async throws {
        await MainActor.run {
            _ = TagSettings.shared.move(tagId: tagId, toParent: newParentId, atIndex: newIndex)
        }
    }

    func undo() async throws {
        await MainActor.run {
            _ = TagSettings.shared.move(tagId: tagId, toParent: oldParentId, atIndex: oldIndex)
        }
    }
}

/// Batch star/unstar multiple items
/// GAP #12 fix: Now captures pre-state so undo restores original values
struct BatchStarAction: UndoableAction {
    let itemIds: [UUID]
    let setStarred: Bool
    /// Pre-operation starred state for each item (captured before execute)
    /// Only items that actually changed are included
    let previousStates: [UUID: Bool]
    private let setStarredOperation: @Sendable (UUID, Bool) async throws -> Void

    init(itemIds: [UUID], setStarred: Bool, mediaStore: MediaStore, previousStates: [UUID: Bool]) {
        self.itemIds = itemIds
        self.setStarred = setStarred
        self.previousStates = previousStates
        self.setStarredOperation = { id, starred in
            try await mediaStore.setStar(id: id, starred: starred)
        }
    }

    init(
        itemIds: [UUID],
        setStarred: Bool,
        previousStates: [UUID: Bool],
        setStarredOperation: @escaping @Sendable (UUID, Bool) async throws -> Void
    ) {
        self.itemIds = itemIds
        self.setStarred = setStarred
        self.previousStates = previousStates
        self.setStarredOperation = setStarredOperation
    }

    var description: String {
        let action = setStarred ? "Starred" : "Unstarred"
        let changedCount = previousStates.count
        return "\(action) \(changedCount) item\(changedCount == 1 ? "" : "s")"
    }

    func execute() async throws {
        try await execute(only: Set(previousStates.keys))
    }

    /// Retry only the failed subset while preserving the original pre-operation state.
    func execute(only requestedIDs: Set<UUID>) async throws {
        let targetIDs = requestedIDs.intersection(previousStates.keys)
        var succeededIDs = Set<UUID>()
        var failedIDs = Set<UUID>()
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for id in targetIDs {
                group.addTask {
                    do {
                        try await setStarredOperation(id, setStarred)
                        return (id, true)
                    } catch {
                        return (id, false)
                    }
                }
            }
            for await (id, succeeded) in group {
                if succeeded { succeededIDs.insert(id) }
                else { failedIDs.insert(id) }
            }
        }
        if !failedIDs.isEmpty {
            throw BatchStarPartialFailure(succeededIDs: succeededIDs, failedIDs: failedIDs)
        }
    }

    func undo() async throws {
        // Restore each item to its previous state
        var succeededIDs = Set<UUID>()
        var failedIDs = Set<UUID>()
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for (id, wasStarred) in previousStates {
                group.addTask {
                    do {
                        try await setStarredOperation(id, wasStarred)
                        return (id, true)
                    } catch {
                        return (id, false)
                    }
                }
            }
            for await (id, succeeded) in group {
                if succeeded { succeededIDs.insert(id) }
                else { failedIDs.insert(id) }
            }
        }
        if !failedIDs.isEmpty {
            throw BatchStarPartialFailure(succeededIDs: succeededIDs, failedIDs: failedIDs)
        }
    }
}

struct BatchStarPartialFailure: LocalizedError, Sendable {
    let succeededIDs: Set<UUID>
    let failedIDs: Set<UUID>

    var errorDescription: String? {
        "Starred-state updates failed for \(failedIDs.count) item\(failedIDs.count == 1 ? "" : "s")"
            + (succeededIDs.isEmpty ? ". No items changed." : "; \(succeededIDs.count) item\(succeededIDs.count == 1 ? " was" : "s were") updated and can be undone. Retry the failed items.")
    }
}

struct BatchStarRetryFailure: LocalizedError, Sendable {
    let succeededIDs: Set<UUID>
    let failedIDs: Set<UUID>
    let isUndoable: Bool

    var errorDescription: String? {
        BatchStarPartialFailure(succeededIDs: succeededIDs, failedIDs: failedIDs).localizedDescription
    }
}

/// Batch add/remove tag on multiple items
/// GAP #12 fix: Now captures pre-state so undo only affects items that actually changed
struct BatchTagAction: UndoableAction {
    let itemIds: [UUID]
    let tag: String
    let wasAdded: Bool
    let mediaStore: MediaStore
    /// Items that actually changed (had tag added or removed)
    let changedItemIds: Set<UUID>

    var description: String {
        let action = wasAdded ? "Added" : "Removed"
        let count = changedItemIds.count
        return "\(action) tag '\(tag)' on \(count) item\(count == 1 ? "" : "s")"
    }

    func execute() async throws {
        var failedCount = 0
        await withTaskGroup(of: Bool.self) { group in
            for id in changedItemIds {
                group.addTask {
                    do {
                        if wasAdded {
                            try await mediaStore.addTag(id: id, tag: tag)
                        } else {
                            try await mediaStore.removeTag(id: id, tag: tag)
                        }
                        return true
                    } catch {
                        return false
                    }
                }
            }
            for await success in group {
                if !success { failedCount += 1 }
            }
        }
        if failedCount > 0 {
            Log.warning("BatchTagAction.execute: \(failedCount)/\(changedItemIds.count) items failed")
        }
    }

    func undo() async throws {
        var failedCount = 0
        await withTaskGroup(of: Bool.self) { group in
            for id in changedItemIds {
                group.addTask {
                    do {
                        if wasAdded {
                            // Was added, so remove to undo
                            try await mediaStore.removeTag(id: id, tag: tag)
                        } else {
                            // Was removed, so add back to undo
                            try await mediaStore.addTag(id: id, tag: tag)
                        }
                        return true
                    } catch {
                        return false
                    }
                }
            }
            for await success in group {
                if !success { failedCount += 1 }
            }
        }
        if failedCount > 0 {
            Log.warning("BatchTagAction.undo: \(failedCount)/\(itemIds.count) items failed")
        }
    }
}

/// Update notes on an item
struct UpdateNotesAction: UndoableAction {
    let itemId: UUID
    let oldNotes: String?
    let newNotes: String?
    let mediaStore: MediaStore

    var description: String {
        if oldNotes == nil && newNotes != nil {
            return "Added notes"
        } else if oldNotes != nil && newNotes == nil {
            return "Removed notes"
        } else {
            return "Updated notes"
        }
    }

    func execute() async throws {
        try await mediaStore.updateNotes(id: itemId, notes: newNotes)
    }

    func undo() async throws {
        try await mediaStore.updateNotes(id: itemId, notes: oldNotes)
    }
}

/// Soft delete items (sets deleted_at timestamp)
/// Note: Requires adding deleted_at column to schema
struct DeleteItemsAction: UndoableAction {
    let itemIds: [UUID]
    let mediaStore: MediaStore
    var deleteService: DeleteService? = nil

    var description: String {
        "Moved \(itemIds.count) item\(itemIds.count == 1 ? "" : "s") to Trash"
    }

    func execute() async throws {
        let items = try await mediaStore.fetchItems(ids: itemIds)

        // If items are already gone/soft-deleted, keep operation idempotent.
        guard !items.isEmpty else { return }

        let result = try await (deleteService ?? DeleteService(mediaStore: mediaStore)).deleteItems(items)
        if result.hasFileErrors {
            throw DeleteService.PartialDeletionError(result: result)
        }
    }

    func undo() async throws {
        var items: [MediaItem] = []
        for id in itemIds {
            guard let item = try await mediaStore.fetchItem(id: id) else {
                throw DeleteUndoError(message: "This item is no longer available to restore. Its undo entry was retained for review.")
            }
            items.append(item)
        }
        let missing = items.flatMap { $0.mediaFiles + [$0.contextImage].compactMap { $0 } }
            .filter { !FileManager.default.fileExists(atPath: $0.path) }
        guard missing.isEmpty else {
            throw DeleteUndoError(message: "Restore the missing files from Finder Trash before undoing this deletion: " + missing.map(\.lastPathComponent).joined(separator: ", "))
        }
        try await mediaStore.restoreDeleted(ids: itemIds)
    }

    struct DeleteUndoError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

// MARK: - Board Actions

/// Add items to a collection board
struct AddToBoardAction: UndoableAction {
    let itemIds: [UUID]
    let boardId: UUID
    let boardName: String
    let boardStore: BoardStore

    var description: String {
        let itemWord = itemIds.count == 1 ? "item" : "items"
        return "Added \(itemIds.count) \(itemWord) to \(boardName)"
    }

    func execute() async throws {
        try await boardStore.addItems(itemIds, to: boardId)
    }

    func undo() async throws {
        try await boardStore.removeItems(itemIds, from: boardId)
    }
}

// MARK: - Video Trim Actions (Issue #9)

/// Undo action for video trim that deletes the trimmed file and reverts the MediaItem.
/// Note: This is a destructive undo - the trimmed file is permanently deleted.
struct TrimUndoAction: UndoableAction {
    let trimmedFileURL: URL
    let mediaItem: MediaItem
    let wasRetrim: Bool
    let mediaStore: MediaStore

    var description: String {
        "Trimmed video"
    }

    func execute() async throws {
        // The trim was already performed - nothing to do
        // This action is registered with skipExecution: true
    }

    func undo() async throws {
        // Delete the trimmed file from disk
        if FileManager.default.fileExists(atPath: trimmedFileURL.path) {
            try FileManager.default.removeItem(at: trimmedFileURL)
            Log.info("TrimUndoAction: Deleted trimmed file \(trimmedFileURL.lastPathComponent)")
        }

        // If this wasn't a re-trim (overwrite), also remove from MediaItem's file list
        if !wasRetrim {
            var updatedItem = mediaItem
            updatedItem.mediaFiles.removeAll { $0 == trimmedFileURL }
            // Update in database
            try await mediaStore.updateMediaFiles(id: mediaItem.id, files: updatedItem.mediaFiles)
        }
        // If it was a re-trim, we just deleted the overwritten file - the original is gone
        // and cannot be recovered (this is documented as a limitation)
    }
}

/// Undo action for "Replace Original" trim mode.
/// Restores the original file from its .bak backup.
struct ReplaceOriginalUndoAction: UndoableAction {
    let originalURL: URL
    let backupURL: URL
    let mediaItem: MediaItem
    let mediaStore: MediaStore

    var description: String {
        "Replaced original with trim"
    }

    func execute() async throws {
        // Already performed externally - registered with skipExecution: true
    }

    func undo() async throws {
        let fm = FileManager.default

        // Restore backup over the replaced file
        guard fm.fileExists(atPath: backupURL.path) else {
            Log.warning("ReplaceOriginalUndoAction: Backup not found at \(backupURL.lastPathComponent)")
            return
        }

        do {
            // Remove the trimmed version that replaced the original
            if fm.fileExists(atPath: originalURL.path) {
                try fm.removeItem(at: originalURL)
            }
            // Restore the backup to the original path
            try fm.moveItem(at: backupURL, to: originalURL)
            Log.info("ReplaceOriginalUndoAction: Restored original from backup")
        } catch {
            Log.error("ReplaceOriginalUndoAction: Failed to restore - \(error.localizedDescription)")
            throw error
        }
    }
}

/// Undo action for "Save as New Clip" trim mode.
/// Soft-deletes the new item from DB and removes files from disk.
struct SaveAsNewClipUndoAction: UndoableAction {
    let newItemId: UUID
    let trimmedFileURL: URL
    let metadataFileURL: URL
    let mediaStore: MediaStore

    var description: String {
        "Saved trimmed clip"
    }

    func execute() async throws {
        // Already performed externally - registered with skipExecution: true
    }

    func undo() async throws {
        let fm = FileManager.default

        // Soft-delete the new item from DB
        try await mediaStore.softDelete(ids: [newItemId])

        // Remove the trimmed file from disk
        if fm.fileExists(atPath: trimmedFileURL.path) {
            try fm.removeItem(at: trimmedFileURL)
            Log.info("SaveAsNewClipUndoAction: Deleted trimmed file \(trimmedFileURL.lastPathComponent)")
        }

        // Remove the derivative sidecar
        if fm.fileExists(atPath: metadataFileURL.path) {
            try fm.removeItem(at: metadataFileURL)
            Log.info("SaveAsNewClipUndoAction: Deleted sidecar \(metadataFileURL.lastPathComponent)")
        }
    }
}
