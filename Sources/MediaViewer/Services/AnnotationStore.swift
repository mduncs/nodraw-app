import Foundation
import GRDB
import Combine

// MARK: - AnnotationStore

/// Service for managing annotations with undo/redo support.
/// Provides CRUD operations and change observation.
@MainActor
final class AnnotationStore: ObservableObject {
    private let database: DatabaseManager

    /// Write-back queue for syncing annotation state flags to .md frontmatter
    var writeBackQueue: WriteBackQueue?

    /// In-memory undo stack for current editing session
    private var undoStack: [AnnotationSnapshot] = []
    private var redoStack: [AnnotationSnapshot] = []

    /// Maximum undo depth
    private let maxUndoDepth = 50

    /// Publisher for annotation changes
    private let changesSubject = PassthroughSubject<AnnotationChangeEvent, Never>()

    var changes: AnyPublisher<AnnotationChangeEvent, Never> {
        changesSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    // MARK: - Fetch Operations

    /// Fetch annotations for a specific media file
    func fetchAnnotations(itemId: UUID, mediaFileIndex: Int = 0, assetID: UUID? = nil) async throws -> AnnotationSet {
        try await database.read { db in
            guard let record = try AnnotationRecord.fetch(db: db, itemId: itemId, mediaFileIndex: mediaFileIndex, assetID: assetID) else {
                return .empty
            }
            return try record.decodedAnnotationSet()
        }
    }

    /// Fetch all annotations for an item (all media files)
    func fetchAllAnnotations(itemId: UUID) async throws -> [Int: AnnotationSet] {
        try await database.read { db in
            let records = try AnnotationRecord.fetchAll(db: db, itemId: itemId)
            var result: [Int: AnnotationSet] = [:]
            for record in records {
                result[record.mediaFileIndex] = try record.decodedAnnotationSet()
            }
            return result
        }
    }

    /// Check if an item has any annotations
    func hasAnnotations(itemId: UUID) async throws -> Bool {
        try await database.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM annotations WHERE itemId = ?",
                arguments: [itemId.uuidString]
            ) ?? 0
            return count > 0
        }
    }

    // MARK: - Write Operations

    /// Save annotations for a specific media file.
    /// Automatically records undo state.
    func saveAnnotations(
        itemId: UUID,
        mediaFileIndex: Int = 0,
        annotationSet: AnnotationSet,
        recordUndo: Bool = true,
        assetID: UUID? = nil
    ) async throws {
        // Validate encoding before any write. A failed encode must never turn
        // an existing document into AnnotationRecord's legacy empty fallback.
        let encodedJSON = String(decoding: try JSONEncoder().encode(annotationSet), as: UTF8.self)

        // Record undo state before saving (if annotations exist)
        if recordUndo {
            let previousSet = try await fetchAnnotations(itemId: itemId, mediaFileIndex: mediaFileIndex, assetID: assetID)
            pushUndoState(
                itemId: itemId,
                mediaFileIndex: mediaFileIndex,
                annotationSet: previousSet,
                assetID: assetID
            )
        }

        // Save to database
        do {
        try await database.write { db in
            let asset = try ItemAssetStore.prepareWrite(in: db, itemID: itemId, assetID: assetID, index: mediaFileIndex)
            if annotationSet == .empty {
                // Preserve intentionally empty layers and their settings.
                try db.execute(
                    sql: "DELETE FROM annotations WHERE itemId = ? AND asset_id = ? AND association_state = 'attached'",
                    arguments: [itemId.uuidString, asset.id.uuidString]
                )
            } else {
                // Upsert record
                var record = AnnotationRecord(
                    itemId: itemId,
                    mediaFileIndex: mediaFileIndex,
                    annotationSet: annotationSet,
                    assetID: asset.id
                )
                record.annotationsJSON = encodedJSON
                try record.upsert(db: db)
            }
        }
        } catch ItemAssetStore.AssociationError.staleAsset {
            guard let assetID else { throw ItemAssetStore.AssociationError.staleAsset }
            try await retainDraft(itemId: itemId, assetID: assetID, originalIndex: mediaFileIndex, annotationSet: annotationSet)
            throw ItemAssetStore.AssociationError.draftRetained
        }

        // Notify observers
        notifyChange(.saved(itemId: itemId, mediaFileIndex: mediaFileIndex))

        // Enqueue write-back to update annotated flag in frontmatter
        if let queue = writeBackQueue {
            await queue.enqueue(itemId)
        }
    }

    /// Keep unsaved edits to a replaced/removed file separate from both its
    /// committed annotation and the replacement. Retrying updates this draft.
    private func retainDraft(itemId: UUID, assetID: UUID, originalIndex: Int, annotationSet: AnnotationSet) async throws {
        let json = String(decoding: try JSONEncoder().encode(annotationSet), as: UTF8.self)
        try await database.write { db in
            try ItemAssetStore.reconcile(in: db, itemID: itemId.uuidString)
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM item_assets WHERE asset_id = ? AND item_id = ? AND is_current = 0)", arguments: [assetID.uuidString, itemId.uuidString]) == true else { throw ItemAssetStore.AssociationError.staleAsset }
            if let draftID = try String.fetchOne(db, sql: "SELECT id FROM annotations WHERE itemId = ? AND asset_id = ? AND association_state = 'retained-draft'", arguments: [itemId.uuidString, assetID.uuidString]) {
                try db.execute(sql: "UPDATE annotations SET annotationsJSON = ?, updatedAt = ? WHERE id = ?", arguments: [json, Date(), draftID])
            } else {
                let ordinal = min(-1, (try Int.fetchOne(db, sql: "SELECT MIN(mediaFileIndex) FROM annotations WHERE itemId = ?", arguments: [itemId.uuidString]) ?? 0) - 1)
                try db.execute(sql: "INSERT INTO annotations(id, itemId, mediaFileIndex, annotationsJSON, createdAt, updatedAt, asset_id, association_state, legacy_file_index) VALUES (?, ?, ?, ?, ?, ?, ?, 'retained-draft', ?)", arguments: [UUID().uuidString, itemId.uuidString, ordinal, json, Date(), Date(), assetID.uuidString, originalIndex])
            }
        }
        notifyChange(.saved(itemId: itemId, mediaFileIndex: originalIndex))
        if let writeBackQueue { await writeBackQueue.enqueue(itemId) }
    }

    /// Delete all annotations for an item
    func deleteAllAnnotations(itemId: UUID) async throws {
        try await database.write { db in
            try AnnotationRecord.deleteAll(db: db, itemId: itemId)
        }

        // GAP #10 fix: Clear undo/redo stacks for the deleted item
        // Stale snapshots would reference annotations that no longer exist
        clearUndoHistory(for: itemId)

        notifyChange(.deleted(itemId: itemId))

        // Enqueue write-back to clear annotated flag in frontmatter
        if let queue = writeBackQueue {
            await queue.enqueue(itemId)
        }
    }

    // MARK: - Undo/Redo

    /// Undo the last annotation change for the specified item/file
    @MainActor
    func undo(itemId: UUID, mediaFileIndex: Int, assetID: UUID? = nil) async throws -> Bool {
        // Find the last matching snapshot (search from end)
        guard let index = undoStack.lastIndex(where: {
            $0.itemId == itemId && (assetID == nil ? $0.mediaFileIndex == mediaFileIndex : $0.assetID == assetID)
        }) else {
            return false
        }

        let snapshot = undoStack.remove(at: index)

        // Save current state to redo stack
        let currentSet = try await fetchAnnotations(itemId: itemId, mediaFileIndex: mediaFileIndex, assetID: snapshot.assetID)
        redoStack.append(AnnotationSnapshot(
            itemId: itemId,
            mediaFileIndex: mediaFileIndex,
            annotationSet: currentSet,
            assetID: snapshot.assetID
        ))
        if redoStack.count > maxUndoDepth {
            redoStack.removeFirst()
        }

        // Restore previous state
        try await saveAnnotations(
            itemId: itemId,
            mediaFileIndex: mediaFileIndex,
            annotationSet: snapshot.annotationSet,
            recordUndo: false,  // Don't record undo for undo operation
            assetID: snapshot.assetID
        )

        return true
    }

    /// Redo the last undone annotation change for the specified item/file
    @MainActor
    func redo(itemId: UUID, mediaFileIndex: Int, assetID: UUID? = nil) async throws -> Bool {
        // Find the last matching snapshot (search from end)
        guard let index = redoStack.lastIndex(where: {
            $0.itemId == itemId && (assetID == nil ? $0.mediaFileIndex == mediaFileIndex : $0.assetID == assetID)
        }) else {
            return false
        }

        let snapshot = redoStack.remove(at: index)

        // Save current state to undo stack
        let currentSet = try await fetchAnnotations(itemId: itemId, mediaFileIndex: mediaFileIndex, assetID: snapshot.assetID)
        undoStack.append(AnnotationSnapshot(
            itemId: itemId,
            mediaFileIndex: mediaFileIndex,
            annotationSet: currentSet,
            assetID: snapshot.assetID
        ))
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst()
        }

        // Restore redo state
        try await saveAnnotations(
            itemId: itemId,
            mediaFileIndex: mediaFileIndex,
            annotationSet: snapshot.annotationSet,
            recordUndo: false,
            assetID: snapshot.assetID
        )

        return true
    }

    /// Check if undo is available for the current item/file
    /// Searches the entire stack for matching item/file (not just last entry)
    @MainActor
    func canUndo(itemId: UUID, mediaFileIndex: Int, assetID: UUID? = nil) -> Bool {
        undoStack.contains { $0.itemId == itemId && (assetID == nil ? $0.mediaFileIndex == mediaFileIndex : $0.assetID == assetID) }
    }

    /// Check if redo is available for the current item/file
    /// Searches the entire stack for matching item/file (not just last entry)
    @MainActor
    func canRedo(itemId: UUID, mediaFileIndex: Int, assetID: UUID? = nil) -> Bool {
        redoStack.contains { $0.itemId == itemId && (assetID == nil ? $0.mediaFileIndex == mediaFileIndex : $0.assetID == assetID) }
    }

    /// Clear undo/redo stacks (e.g., when switching items)
    @MainActor
    func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Clear undo/redo stacks for a specific item only
    /// GAP #10 fix: Called when all annotations for an item are deleted
    @MainActor
    func clearUndoHistory(for itemId: UUID) {
        undoStack.removeAll { $0.itemId == itemId }
        redoStack.removeAll { $0.itemId == itemId }
    }

    // Issue #11: Get undo/redo step counts for current item
    @MainActor
    func undoCount(itemId: UUID, mediaFileIndex: Int, assetID: UUID? = nil) -> Int {
        undoStack.filter { $0.itemId == itemId && (assetID == nil ? $0.mediaFileIndex == mediaFileIndex : $0.assetID == assetID) }.count
    }

    @MainActor
    func redoCount(itemId: UUID, mediaFileIndex: Int, assetID: UUID? = nil) -> Int {
        redoStack.filter { $0.itemId == itemId && (assetID == nil ? $0.mediaFileIndex == mediaFileIndex : $0.assetID == assetID) }.count
    }

    // MARK: - Private Helpers

    @MainActor
    private func pushUndoState(itemId: UUID, mediaFileIndex: Int, annotationSet: AnnotationSet, assetID: UUID? = nil) {
        // Clear redo stack when new action is taken
        redoStack.removeAll()

        undoStack.append(AnnotationSnapshot(
            itemId: itemId,
            mediaFileIndex: mediaFileIndex,
            annotationSet: annotationSet,
            assetID: assetID
        ))

        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst()
        }
    }

    @MainActor
    private func notifyChange(_ event: AnnotationChangeEvent) {
        changesSubject.send(event)
    }
}

// MARK: - Supporting Types

/// Snapshot of annotation state for undo/redo
private struct AnnotationSnapshot {
    let itemId: UUID
    let mediaFileIndex: Int
    let annotationSet: AnnotationSet
    var assetID: UUID? = nil
}

/// Events published when annotations change
enum AnnotationChangeEvent {
    case saved(itemId: UUID, mediaFileIndex: Int)
    case deleted(itemId: UUID)
}
