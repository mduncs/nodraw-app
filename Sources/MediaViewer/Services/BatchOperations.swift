import Foundation
import GRDB

// MARK: - Batch Operations

/// Service for creating batch operation actions on multiple media items.
/// Uses the existing UndoableAction types from UndoManager.swift.
/// All actions integrate with UndoStack for undo/redo support.
final class BatchOperationsService: @unchecked Sendable {
    private let mediaStore: MediaStore

    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
    }

    // MARK: - Star Operations

    /// Create an action to star all items in the set
    /// GAP #12 fix: Now captures pre-state for proper undo
    func makeStarAllAction(ids: Set<UUID>) async throws -> BatchStarAction {
        // Query current starred state for items that aren't already starred
        let previousStates = try await mediaStore.getStarredStates(ids: Array(ids))
        // Filter to only items that will actually change (not already starred)
        let changingItems = previousStates.filter { !$0.value }
        return BatchStarAction(
            itemIds: Array(ids),
            setStarred: true,
            mediaStore: mediaStore,
            previousStates: changingItems
        )
    }

    /// Create an action to unstar all items in the set
    /// GAP #12 fix: Now captures pre-state for proper undo
    func makeUnstarAllAction(ids: Set<UUID>) async throws -> BatchStarAction {
        // Query current starred state for items that aren't already unstarred
        let previousStates = try await mediaStore.getStarredStates(ids: Array(ids))
        // Filter to only items that will actually change (currently starred)
        let changingItems = previousStates.filter { $0.value }
        return BatchStarAction(
            itemIds: Array(ids),
            setStarred: false,
            mediaStore: mediaStore,
            previousStates: changingItems
        )
    }

    // MARK: - Tag Operations

    /// Create an action to add a tag to all items in the set
    /// GAP #12 fix: Now captures pre-state for proper undo
    func makeAddTagAction(tag: String, to ids: Set<UUID>) async throws -> BatchTagAction {
        // Find items that DON'T already have this tag (those are the ones that will change)
        let itemsWithTag = try await mediaStore.getItemsWithTag(ids: Array(ids), tag: tag)
        let itemsToChange = ids.subtracting(itemsWithTag)
        return BatchTagAction(
            itemIds: Array(ids),
            tag: tag,
            wasAdded: true,
            mediaStore: mediaStore,
            changedItemIds: itemsToChange
        )
    }

    /// Create an action to remove a tag from all items in the set
    /// GAP #12 fix: Now captures pre-state for proper undo
    func makeRemoveTagAction(tag: String, from ids: Set<UUID>) async throws -> BatchTagAction {
        // Find items that DO have this tag (those are the ones that will change)
        let itemsWithTag = try await mediaStore.getItemsWithTag(ids: Array(ids), tag: tag)
        return BatchTagAction(
            itemIds: Array(ids),
            tag: tag,
            wasAdded: false,
            mediaStore: mediaStore,
            changedItemIds: itemsWithTag
        )
    }

    // MARK: - Delete Operations

    /// Create an action to delete all items in the set
    func makeDeleteAction(ids: Set<UUID>) -> DeleteItemsAction {
        DeleteItemsAction(
            itemIds: Array(ids),
            mediaStore: mediaStore
        )
    }
}

// MARK: - Batch Result

/// Result of a batch operation for UI feedback
struct BatchResult: Sendable {
    let successCount: Int
    let failureCount: Int
    let errors: [String]

    var isFullSuccess: Bool { failureCount == 0 }

    static let empty = BatchResult(successCount: 0, failureCount: 0, errors: [])
}
