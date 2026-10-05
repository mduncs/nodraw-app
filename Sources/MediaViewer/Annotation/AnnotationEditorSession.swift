import Foundation
import Combine
import AppKit

// MARK: - AnnotationEditorSession

/// Single state owner for an annotation editing session.
/// All mutations flow through commands, enabling undo/redo and dirty tracking.
/// This replaces direct AnnotationSet mutation scattered across views.
@MainActor
final class AnnotationEditorSession: ObservableObject {

    // MARK: - Published State

    /// Current annotation state
    @Published private(set) var annotationSet: AnnotationSet

    /// Currently selected shape IDs
    @Published var selectedShapeIds: Set<UUID> = []

    /// Whether the session has unsaved changes
    @Published private(set) var isDirty: Bool = false

    /// Monotonic edit revision, including undo, redo and explicit restoration.
    @Published private(set) var revision: UInt64 = 0

    /// Last revision successfully persisted to this asset's document.
    @Published private(set) var savedRevision: UInt64 = 0

    /// True until all queued saves have finished.
    @Published private(set) var isSaving: Bool = false

    /// Last persistence failure; retained until a save succeeds so retry stays visible.
    @Published private(set) var saveError: String?

    /// Whether undo is available
    @Published private(set) var canUndo: Bool = false

    /// Whether redo is available
    @Published private(set) var canRedo: Bool = false

    // MARK: - Identity

    /// Item ID being edited
    let itemId: UUID

    /// Media file index within the item
    let mediaFileIndex: Int
    let assetID: UUID?

    // MARK: - Undo/Redo

    /// Stack of inverse commands for undo
    private var undoStack: [(command: AnnotationCommand, description: String)] = []

    /// Stack of inverse commands for redo
    private var redoStack: [(command: AnnotationCommand, description: String)] = []

    /// Maximum undo depth
    private let maxUndoDepth = 50

    // MARK: - Autosave

    /// Debounce timer for autosave
    private var autosaveTask: Task<Void, Never>?

    /// Autosave interval in seconds
    private let autosaveInterval: TimeInterval?

    /// Keep persistence available while a failed/dirty session is retained for retry.
    private let store: AnnotationStore?
    private let pasteboard: NSPasteboard

    /// Each save waits for its predecessor, even if that predecessor failed.
    private var saveTask: Task<Void, Error>?
    private var pendingSaveCount = 0

    /// Callback for save operations (alternative to store for testing)
    var onSave: ((AnnotationSet) async throws -> Void)?

    // MARK: - Init

    init(
        itemId: UUID,
        mediaFileIndex: Int = 0,
        annotationSet: AnnotationSet = .empty,
        store: AnnotationStore? = nil,
        assetID: UUID? = nil,
        pasteboard: NSPasteboard = .general,
        autosaveInterval: TimeInterval? = 1.0
    ) {
        self.itemId = itemId
        self.mediaFileIndex = mediaFileIndex
        self.assetID = assetID
        self.annotationSet = annotationSet
        self.store = store
        self.pasteboard = pasteboard
        self.autosaveInterval = autosaveInterval
    }

    deinit {
        autosaveTask?.cancel()
    }

    // MARK: - Command Execution

    /// Execute a command, recording undo state.
    /// Returns whether the command had any effect.
    @discardableResult
    func execute(_ command: AnnotationCommand, description: String = "") -> Bool {
        let result = annotationSet.apply(command)
        guard result.didChange else { return false }

        // Push inverse onto undo stack
        undoStack.append((command: result.inverse, description: description))
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst()
        }

        // Clear redo on new action
        redoStack.removeAll()

        updateUndoRedoState()
        selectedShapeIds.formIntersection(annotationSet.shapes.map(\.id))
        markDirty()
        return true
    }

    /// Execute multiple commands as an atomic group.
    @discardableResult
    func executeGroup(_ commands: [AnnotationCommand], description: String = "") -> Bool {
        execute(.group(commands), description: description)
    }

    /// Compatibility bridge for legacy Binding<AnnotationSet> callbacks.
    /// Protect locked content while allowing explicit lock, visibility and name
    /// controls; restoration used by undo/redo remains an exact snapshot.
    @discardableResult
    func replaceDocument(_ document: AnnotationSet, description: String = "Edit annotations") -> Bool {
        guard document != annotationSet,
              Set(document.layers.map(\.id)).count == document.layers.count,
              Set(document.shapes.map(\.id)).count == document.shapes.count,
              document.activeLayerId == nil || document.layers.contains(where: { $0.id == document.activeLayerId }) else { return false }
        for locked in annotationSet.layers where locked.isLocked {
            guard let replacement = document.layers.first(where: { $0.id == locked.id }),
                  replacement.shapes == locked.shapes,
                  replacement.opacity == locked.opacity,
                  replacement.blendMode == locked.blendMode else { return false }
        }
        return execute(.restoreSnapshot(document), description: description)
    }

    // MARK: - Undo / Redo

    /// Undo the last command.
    @discardableResult
    func undo() -> Bool {
        guard let entry = undoStack.popLast() else { return false }

        let result = annotationSet.apply(entry.command)
        if result.didChange {
            redoStack.append((command: result.inverse, description: entry.description))
        }

        updateUndoRedoState()
        if result.didChange {
            selectedShapeIds.formIntersection(annotationSet.shapes.map(\.id))
            markDirty()
        }
        return result.didChange
    }

    /// Redo the last undone command.
    @discardableResult
    func redo() -> Bool {
        guard let entry = redoStack.popLast() else { return false }

        let result = annotationSet.apply(entry.command)
        if result.didChange {
            undoStack.append((command: result.inverse, description: entry.description))
        }

        updateUndoRedoState()
        if result.didChange {
            selectedShapeIds.formIntersection(annotationSet.shapes.map(\.id))
            markDirty()
        }
        return result.didChange
    }

    /// Clear all undo/redo history.
    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoRedoState()
    }

    /// Number of undo steps available
    var undoCount: Int { undoStack.count }

    /// Number of redo steps available
    var redoCount: Int { redoStack.count }

    /// Description of the next undo action
    var undoDescription: String? {
        undoStack.last?.description.isEmpty == false ? undoStack.last?.description : nil
    }

    /// Description of the next redo action
    var redoDescription: String? {
        redoStack.last?.description.isEmpty == false ? redoStack.last?.description : nil
    }

    // MARK: - Selection

    /// Select a single shape (replacing current selection)
    func select(_ shapeId: UUID) {
        selectedShapeIds = [shapeId]
    }

    /// Toggle selection of a shape (for multi-select with modifier key)
    func toggleSelection(_ shapeId: UUID) {
        if selectedShapeIds.contains(shapeId) {
            selectedShapeIds.remove(shapeId)
        } else {
            selectedShapeIds.insert(shapeId)
        }
    }

    /// Clear selection
    func clearSelection() {
        selectedShapeIds.removeAll()
    }

    /// Select all shapes
    func selectAll() {
        selectedShapeIds = Set(annotationSet.shapes.map(\.id))
    }

    /// Whether a shape is selected
    func isSelected(_ shapeId: UUID) -> Bool {
        selectedShapeIds.contains(shapeId)
    }

    /// Get all selected shapes
    var selectedShapes: [AnnotationShape] {
        annotationSet.shapes.filter { selectedShapeIds.contains($0.id) }
    }

    // MARK: - Convenience Mutators

    /// Delete all selected shapes
    @discardableResult
    func deleteSelected() -> Bool {
        guard !selectedShapeIds.isEmpty else { return false }
        let ids = Array(selectedShapeIds)
        return execute(.deleteShapes(shapeIds: ids), description: "Delete \(ids.count) shape(s)")
    }

    /// Duplicate all selected shapes
    @discardableResult
    func duplicateSelected() -> Bool {
        guard !selectedShapeIds.isEmpty else { return false }
        let editableShapes = selectedShapes.filter { annotationSet.layerContaining(shapeId: $0.id)?.isLocked == false }
        guard !editableShapes.isEmpty else { return false }
        let newShapes = editableShapes.map { $0.duplicated() }

        let result = execute(
            .duplicateShapes(shapeIds: editableShapes.map(\.id), newShapes: newShapes),
            description: "Duplicate \(newShapes.count) shape(s)"
        )

        if result {
            selectedShapeIds = Set(newShapes.map(\.id))
        }
        return result
    }

    // MARK: - Arrange

    /// Bring selected shape forward one step in its layer
    @discardableResult
    func bringForward() -> Bool {
        guard selectedShapeIds.count == 1, let shapeId = selectedShapeIds.first else { return false }
        return execute(.bringForward(shapeId: shapeId), description: "Bring Forward")
    }

    /// Send selected shape backward one step in its layer
    @discardableResult
    func sendBackward() -> Bool {
        guard selectedShapeIds.count == 1, let shapeId = selectedShapeIds.first else { return false }
        return execute(.sendBackward(shapeId: shapeId), description: "Send Backward")
    }

    /// Bring selected shape to front of its layer
    @discardableResult
    func bringToFront() -> Bool {
        guard selectedShapeIds.count == 1, let shapeId = selectedShapeIds.first else { return false }
        return execute(.bringToFront(shapeId: shapeId), description: "Bring to Front")
    }

    /// Send selected shape to back of its layer
    @discardableResult
    func sendToBack() -> Bool {
        guard selectedShapeIds.count == 1, let shapeId = selectedShapeIds.first else { return false }
        return execute(.sendToBack(shapeId: shapeId), description: "Send to Back")
    }

    // MARK: - Clipboard

    /// Custom pasteboard type for annotation shapes
    static let shapesPasteboardType = NSPasteboard.PasteboardType("com.nodraw.annotation.shapes")
    private static let legacyShapesPasteboardType = NSPasteboard.PasteboardType("com.mediaviewer.annotation.shapes")

    /// Copy selected shapes to the system clipboard as JSON
    func copySelected() {
        let shapes = selectedShapes
        guard !shapes.isEmpty else { return }

        guard let data = try? JSONEncoder().encode(shapes) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.shapesPasteboardType)
        pasteboard.setData(data, forType: Self.legacyShapesPasteboardType)
    }

    /// Cut selected shapes (copy + delete)
    @discardableResult
    func cutSelected() -> Bool {
        copySelected()
        return deleteSelected()
    }

    /// Paste shapes from clipboard, offset slightly so they don't overlap originals
    @discardableResult
    func pasteFromClipboard() -> Bool {
        guard let data = pasteboard.data(forType: Self.shapesPasteboardType)
                ?? pasteboard.data(forType: Self.legacyShapesPasteboardType),
              let shapes = try? JSONDecoder().decode([AnnotationShape].self, from: data) else {
            return false
        }

        let newShapes = shapes.map { $0.duplicated() }
        let commands = newShapes.map { AnnotationCommand.addShape(shape: $0, layerId: nil) }
        let result = execute(.group(commands), description: "Paste \(newShapes.count) shape(s)")

        if result {
            selectedShapeIds = Set(newShapes.map(\.id))
        }
        return result
    }

    // MARK: - Load / Save

    /// Load only into a clean, unchanged session. A slow fetch must never erase
    /// edits that happened while the database read was suspended.
    func load() async throws {
        guard let store else { return }
        guard !isDirty, !isSaving else { throw PersistenceError.unsavedChanges }
        let loadingRevision = revision
        let loaded = try await store.fetchAnnotations(itemId: itemId, mediaFileIndex: mediaFileIndex, assetID: assetID)
        guard revision == loadingRevision, !isDirty, !isSaving else { throw PersistenceError.unsavedChanges }
        annotationSet = loaded
        savedRevision = revision
        isDirty = false
        saveError = nil
        selectedShapeIds.removeAll()
        clearHistory()
    }

    /// Persist the state at this call's revision, in request order. In-flight
    /// writes are independent of the debounce task's cancellation and edits
    /// made while a write awaits remain dirty after that write succeeds.
    func save() async throws {
        let snapshot = annotationSet
        let savingRevision = revision
        let predecessor = saveTask
        let saveCallback = onSave
        pendingSaveCount += 1
        isSaving = true

        let task = Task { @MainActor [self] in
            // A failed older write must not prevent a newer snapshot or retry.
            if let predecessor { _ = try? await predecessor.value }
            defer {
                pendingSaveCount -= 1
                isSaving = pendingSaveCount > 0
                if pendingSaveCount == 0 { saveTask = nil }
            }
            do {
                if let saveCallback {
                    try await saveCallback(snapshot)
                } else if let store {
                    try await store.saveAnnotations(
                        itemId: itemId,
                        mediaFileIndex: mediaFileIndex,
                        annotationSet: snapshot,
                        recordUndo: false,
                        assetID: assetID
                    )
                } else {
                    throw PersistenceError.unavailable
                }
                savedRevision = savingRevision
                isDirty = revision != savedRevision
                saveError = nil
            } catch {
                // Retained-draft association failures also stay visible: the
                // original asset's draft is safe, but the document did not save.
                saveError = error.localizedDescription
                isDirty = revision != savedRevision
                throw error
            }
        }
        saveTask = task
        try await task.value
    }

    /// Save/retry immediately, bypassing only the debounce (never an active write).
    func saveNow() async throws {
        autosaveTask?.cancel()
        autosaveTask = nil
        try await save()
    }

    enum PersistenceError: LocalizedError {
        case unavailable
        case unsavedChanges

        var errorDescription: String? {
            switch self {
            case .unavailable: return "The annotation store is unavailable. Your edits are still in this editor."
            case .unsavedChanges: return "Annotations cannot be reloaded while unsaved edits are present."
            }
        }
    }

    // MARK: - Snapshot / Restore

    /// Take a snapshot of current state (for external use)
    func snapshot() -> AnnotationSet {
        annotationSet
    }

    /// Restore from a snapshot (replaces state, clears undo)
    func restore(_ set: AnnotationSet) {
        annotationSet = set
        selectedShapeIds.removeAll()
        clearHistory()
        markDirty()
    }

    // MARK: - Private

    private func updateUndoRedoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func markDirty() {
        revision += 1
        isDirty = revision != savedRevision
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard let autosaveInterval, store != nil || onSave != nil else { return }
        autosaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(autosaveInterval))
                guard !Task.isCancelled, let self else { return }
                try await self.save()
            } catch {
                // save() publishes persistence failures; debounce cancellation
                // is expected and must not hide an earlier save error.
            }
        }
    }
}
