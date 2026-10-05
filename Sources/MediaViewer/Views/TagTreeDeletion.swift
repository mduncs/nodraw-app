import Foundation

// MARK: - Deletion request

/// A counted, not-yet-confirmed request to delete a tag from the Settings tree.
/// Counts are exact canonical references (`countItemsTaggedExactly`), the same key
/// the deletion itself uses, so the confirmation text states the real scope.
struct TagTreeDeletionRequest: Identifiable, Equatable {
    let tag: TagDefinition
    /// Direct children, promoted to the tag's parent by "keep child tags".
    let children: [TagDefinition]
    /// Every descendant (BFS order), removed too by "delete child tags".
    let descendants: [TagDefinition]
    /// Items carrying this exact tag.
    let itemCount: Int
    /// Tag assignments across all descendants (an item with two child tags counts twice).
    let descendantAssignmentCount: Int

    var id: UUID { tag.id }
    var hasChildren: Bool { !children.isEmpty }

    @MainActor
    static func counted(
        tag: TagDefinition,
        settings: TagSettings,
        mediaStore: MediaStore
    ) async throws -> TagTreeDeletionRequest {
        let children = settings.children(of: tag.id)
        let descendants = settings.allDescendants(of: tag.id)
        let itemCount = try await mediaStore.countItemsTaggedExactly(tag: tag.name)
        var descendantAssignments = 0
        for descendant in descendants {
            descendantAssignments += try await mediaStore.countItemsTaggedExactly(tag: descendant.name)
        }
        return TagTreeDeletionRequest(
            tag: tag,
            children: children,
            descendants: descendants,
            itemCount: itemCount,
            descendantAssignmentCount: descendantAssignments
        )
    }

    /// Live definitions for a confirmed request, or why it no longer matches what
    /// the dialog described.
    enum Resolution: Equatable {
        /// Same tags, names and parents as confirmed; carries the live copies.
        case current(tag: TagDefinition, children: [TagDefinition], descendants: [TagDefinition])
        /// The tag was deleted while the dialog was open.
        case missing
        /// A tag in scope was renamed, moved, added or removed; carries the live tag.
        case changed(TagDefinition)
    }

    /// Never broadens a confirmed deletion: any tree change inside the captured
    /// scope makes the request stale instead of silently deleting something new.
    @MainActor
    func resolve(in settings: TagSettings) -> Resolution {
        guard let live = settings.definitions.first(where: { $0.id == tag.id }) else { return .missing }
        let liveDescendants = settings.allDescendants(of: live.id)
        guard Self.scope(live, liveDescendants) == Self.scope(tag, descendants) else { return .changed(live) }
        return .current(tag: live, children: settings.children(of: live.id), descendants: liveDescendants)
    }

    private struct ScopeEntry: Hashable {
        let id: UUID
        let key: String
        let parentId: UUID?
    }

    private static func scope(_ root: TagDefinition, _ descendants: [TagDefinition]) -> Set<ScopeEntry> {
        Set(([root] + descendants).map {
            ScopeEntry(id: $0.id, key: TagCanonicalizer.key($0.name), parentId: $0.parentId)
        })
    }

    var confirmationMessage: String {
        let items = itemCount == 1 ? "1 item" : "\(itemCount) items"
        var lines = ["Removes ‘\(tag.name)’ from \(items)."]
        if hasChildren {
            let descendantsLabel = descendants.count == 1 ? "1 child tag" : "\(descendants.count) child tags"
            let preview = descendants.prefix(3).map(\.name).joined(separator: ", ")
            let suffix = descendants.count > 3 ? ", …" : ""
            lines.append("It has \(descendantsLabel) (\(preview)\(suffix)).")
            let parentLabel = tag.parentId == nil ? "the top level" : "its parent"
            lines.append("Keep: direct children move up to \(parentLabel) and stay on their items.")
            let assignments = descendantAssignmentCount == 1 ? "1 tag assignment" : "\(descendantAssignmentCount) tag assignments"
            lines.append("Delete all: also removes \(assignments) held by the child tags.")
        }
        lines.append("Media files are not touched. Edit ▸ Undo (⌘Z) restores the tags.")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Subtree deletion

/// Undoable archive-wide removal of a tag and every descendant definition.
///
/// Item references for the whole subtree are removed in one transaction
/// (`removeTagsGlobally`) and the exact affected IDs are captured per tag, so Undo
/// restores only the items that actually carried each tag. Definitions are removed
/// only after that write succeeds; a failed write leaves the archive and tree as
/// they were and nothing is pushed for undo.
final class DeleteTagSubtreeAction: UndoableAction, @unchecked Sendable {
    private let root: TagDefinition
    private let descendants: [TagDefinition]
    private let mediaStore: MediaStore
    private(set) var affectedItemIDsByTag: [UUID: [UUID]] = [:]

    init(root: TagDefinition, descendants: [TagDefinition], mediaStore: MediaStore) {
        self.root = root
        self.descendants = descendants
        self.mediaStore = mediaStore
    }

    var description: String {
        switch descendants.count {
        case 0: return "Deleted tag ‘\(root.name)’"
        case 1: return "Deleted ‘\(root.name)’ and 1 child tag"
        default: return "Deleted ‘\(root.name)’ and \(descendants.count) child tags"
        }
    }

    private var subtree: [TagDefinition] { [root] + descendants }

    func execute() async throws {
        let removedByKey = try await mediaStore.removeTagsGlobally(tags: subtree.map(\.name))
        affectedItemIDsByTag = Dictionary(
            subtree.map { ($0.id, removedByKey[TagCanonicalizer.key($0.name)] ?? []) },
            uniquingKeysWith: { first, _ in first }
        )
        let removedIDs = Set(subtree.map(\.id))
        await MainActor.run {
            TagSettings.shared.definitions.removeAll { removedIDs.contains($0.id) }
        }
    }

    func undo() async throws {
        // References first, in one transaction that does not auto-create definitions,
        // so the snapshots below stay authoritative. If it fails, the tree stays in its
        // deleted state and UndoStack keeps the action for a retry.
        var assignments: [String: [UUID]] = [:]
        var displayNameByKey: [String: String] = [:]
        for tag in subtree {
            let ids = affectedItemIDsByTag[tag.id] ?? []
            guard !ids.isEmpty else { continue }
            let key = TagCanonicalizer.key(tag.name)
            let display = displayNameByKey[key] ?? tag.name
            displayNameByKey[key] = display
            assignments[display, default: []].append(contentsOf: ids)
        }
        if !assignments.isEmpty {
            try await mediaStore.restoreTagAssignments(assignments)
        }
        let snapshots = subtree
        await MainActor.run {
            let settings = TagSettings.shared
            settings.definitions = Self.restoring(snapshots, into: settings.definitions)
        }
    }

    /// Re-insert deleted definitions (parents before children). A tag recreated
    /// under the same canonical name in the meantime is kept, and the restored
    /// children attach to it instead of producing a duplicate definition.
    static func restoring(_ snapshots: [TagDefinition], into current: [TagDefinition]) -> [TagDefinition] {
        var definitions = current
        var remap: [UUID: UUID] = [:]
        for snapshot in snapshots {
            let key = TagCanonicalizer.key(snapshot.name)
            if let existing = definitions.first(where: {
                $0.id != snapshot.id && TagCanonicalizer.key($0.name) == key
            }) {
                remap[snapshot.id] = existing.id
                continue
            }
            var restored = snapshot
            if let parentID = restored.parentId {
                let mapped = remap[parentID] ?? parentID
                restored.parentId = definitions.contains(where: { $0.id == mapped }) ? mapped : nil
            }
            if let shortcut = TagSettings.normalizedShortcut(restored.shortcutKey),
               definitions.contains(where: {
                   $0.id != restored.id
                       && $0.parentId == restored.parentId
                       && TagSettings.normalizedShortcut($0.shortcutKey) == shortcut
               }) {
                restored.shortcutKey = nil
            }
            if let index = definitions.firstIndex(where: { $0.id == restored.id }) {
                definitions[index] = restored
            } else {
                definitions.append(restored)
            }
        }
        return definitions
    }
}
