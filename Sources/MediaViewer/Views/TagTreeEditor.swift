import SwiftUI

// MARK: - TagTreeEditor

/// Hierarchical tree editor for tag management in Settings.
/// Replaces the flat grid with a recursive disclosure-based tree.
struct TagTreeEditor: View {
    @ObservedObject var tagSettings: TagSettings
    /// The app's live store. Nil while the library is still loading; archive-wide
    /// edits (rename cascade, delete) are unavailable until it exists.
    var mediaStore: MediaStore?
    /// App-wide undo stack so Edit ▸ Undo restores deletions made here.
    var undoStack: UndoStack?

    // MARK: - State

    /// Which nodes are expanded (show children)
    @State private var expandedNodes: Set<UUID> = []
    /// Which node is being renamed inline
    @State private var editingNodeId: UUID? = nil
    @State private var editingName: String = ""
    /// Which node is having a child added (nil = adding root)
    @State private var addingChildOf: UUID? = nil
    @State private var isAddingRoot: Bool = false
    @State private var newChildName: String = ""
    /// Counted deletion awaiting confirmation.
    @State private var pendingDeletion: TagTreeDeletionRequest? = nil
    /// Tag whose reference count is being fetched before confirmation.
    @State private var countingDeletionFor: UUID? = nil
    /// Whether the add-child field should show a duplicate name error
    @State private var showDuplicateNameError: Bool = false
    @State private var validationErrorMessage: String?
    @State private var shortcutErrorMessage: String?
    /// Outcome of the last archive-wide edit made from this editor.
    @State private var statusMessage: String?
    /// Canonical, path-aware filter for large vocabularies.
    @State private var filterText: String = ""
    @FocusState private var focusedTagID: UUID?

    /// Tag tree drag-and-drop state (shared helpers in TagTreeDrag.swift).
    @State private var tagDropIndicator: TagDropIndicator?
    @State private var tagRowHeights: [UUID: CGFloat] = [:]
    @State private var springLoadTagId: UUID?
    @State private var springLoadTask: Task<Void, Never>?

    private let colorOptions = TagDefinition.colorPalette

    var body: some View {
        let visibility = filterVisibility
        let entries = flattenedTree(visibility: visibility)
        return VStack(alignment: .leading, spacing: 12) {
            headerRow(visibility: visibility)
            messageRows
            if isAddingRoot {
                addChildField(depth: 0) {
                    commitAddChild(parentId: nil)
                } onCancel: {
                    isAddingRoot = false
                    newChildName = ""
                }
            }
            treeContent(entries: entries, visibility: visibility)
        }
        .confirmationDialog(
            deletionDialogTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { request in
            deletionDialogButtons(request)
        } message: { request in
            Text(request.confirmationMessage)
        }
        .onAppear {
            let validIDs = Set(tagSettings.definitions.map(\.id))
            expandedNodes = SettingsStore.shared.tagTreeExpandedNodeIDs.intersection(validIDs)
        }
        .onChange(of: expandedNodes) { _, newValue in
            SettingsStore.shared.tagTreeExpandedNodeIDs = newValue
        }
        .onChange(of: tagSettings.definitions.map(\.id)) { _, ids in
            expandedNodes.formIntersection(Set(ids))
            if let focusedTagID, !ids.contains(focusedTagID) {
                self.focusedTagID = nil
            }
        }
    }

    // MARK: - Header

    private func headerRow(visibility: FilterVisibility?) -> some View {
        HStack(spacing: 10) {
            if !tagSettings.definitions.isEmpty {
                filterField
                Text(summaryText(visibility: visibility))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            if !tagSettings.definitions.isEmpty && visibility == nil {
                Button {
                    collapseAll()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.caption2)
                        Text("Collapse")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Collapse all tags")

                Button {
                    expandAll()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                        Text("Expand")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Expand all tags")
            }

            Button {
                isAddingRoot = true
                addingChildOf = nil
                newChildName = ""
                validationErrorMessage = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add Tag")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentOrange)
            )
            .accessibilityLabel("Add root tag")
        }
    }

    @ViewBuilder
    private var messageRows: some View {
        if let message = validationErrorMessage ?? shortcutErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityLabel("Tag management error: \(message)")
        } else if let statusMessage {
            HStack(spacing: 6) {
                Label(statusMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    self.statusMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Dismiss")
            }
        }

        if mediaStore == nil && !tagSettings.definitions.isEmpty {
            Label("Library is still loading. Rename and delete, which update every tagged item, are unavailable until it finishes.",
                  systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Tree

    @ViewBuilder
    private func treeContent(entries: [FlatEntry], visibility: FilterVisibility?) -> some View {
        if tagSettings.definitions.isEmpty && !isAddingRoot {
            emptyState
        } else if visibility != nil && entries.isEmpty {
            Text("No tags match ‘\(TagCanonicalizer.displayName(filterText))’.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.horizontal, 10)
        } else {
            // Flattened for SwiftUI compatibility; lazy so a few hundred rows stay cheap.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries, id: \.tag.id) { entry in
                    draggableEditorRow(entry, visibility: visibility)
                }
            }
            .onPreferenceChange(TagRowHeightPreferenceKey.self) { heights in
                tagRowHeights = heights
            }
        }
    }

    // MARK: - Delete confirmation

    private var deletionDialogTitle: String {
        guard let request = pendingDeletion else { return "Delete tag?" }
        return request.hasChildren
            ? "Delete ‘\(request.tag.name)’ and its child tags?"
            : "Delete tag ‘\(request.tag.name)’?"
    }

    @ViewBuilder
    private func deletionDialogButtons(_ request: TagTreeDeletionRequest) -> some View {
        if request.hasChildren {
            let kept = request.children.count
            let removed = request.descendants.count
            Button("Delete ‘\(request.tag.name)’, keep \(kept) child tag\(kept == 1 ? "" : "s")") {
                perform(request, includeDescendants: false)
            }
            Button("Delete ‘\(request.tag.name)’ and \(removed) child tag\(removed == 1 ? "" : "s")", role: .destructive) {
                perform(request, includeDescendants: true)
            }
        } else {
            Button("Delete Tag", role: .destructive) {
                perform(request, includeDescendants: false)
            }
        }
        Button("Cancel", role: .cancel) { pendingDeletion = nil }
    }

    // MARK: - Empty State (M6: trailing-aligned arrow)

    private var emptyState: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Image(systemName: "arrow.up")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Click Add Tag above to create your first tag")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Tags help you organize and filter your media")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.vertical, 20)
        .padding(.trailing, 8)
    }

    // MARK: - Flattened Tree

    private struct FlatEntry {
        let tag: TagDefinition
        let depth: Int
    }

    private struct FilterVisibility: Equatable {
        let matchedIDs: Set<UUID>
        let visibleIDs: Set<UUID>
    }

    /// Nil when no filter is active. While filtering, matches and their ancestors
    /// are shown fully expanded so every hit keeps its hierarchy context.
    private var filterVisibility: FilterVisibility? {
        guard !TagCanonicalizer.key(filterText).isEmpty else { return nil }
        let result = TagDefinitionSearch.treeVisibility(query: filterText, in: tagSettings.definitions)
        return FilterVisibility(matchedIDs: result.matchedIDs, visibleIDs: result.visibleIDs)
    }

    private func flattenedTree(visibility: FilterVisibility? = nil) -> [FlatEntry] {
        var result: [FlatEntry] = []
        func walk(_ parentId: UUID?, depth: Int) {
            let kids = parentId == nil ? tagSettings.rootTags() : tagSettings.children(of: parentId!)
            for child in kids {
                if let visibility {
                    guard visibility.visibleIDs.contains(child.id) else { continue }
                    result.append(FlatEntry(tag: child, depth: depth))
                    walk(child.id, depth: depth + 1)
                } else {
                    result.append(FlatEntry(tag: child, depth: depth))
                    if expandedNodes.contains(child.id) {
                        walk(child.id, depth: depth + 1)
                    }
                }
            }
        }
        walk(nil, depth: 0)
        return result
    }

    private var filterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Find tag or parent…", text: $filterText)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(minWidth: 140, maxWidth: 220)
                .onExitCommand { filterText = "" }
                .accessibilityLabel("Find tag")
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func summaryText(visibility: FilterVisibility?) -> String {
        let total = tagSettings.definitions.count
        if let visibility {
            let count = visibility.matchedIDs.count
            return "\(count) of \(total) match"
        }
        let roots = tagSettings.rootTags().count
        return "\(total) tag\(total == 1 ? "" : "s") · \(roots) top-level"
    }

    // MARK: - Expand / Collapse All

    private func expandAll() {
        let allIDs = Set(tagSettings.definitions.map(\.id))
        withAnimation(.easeInOut(duration: 0.15)) {
            expandedNodes = allIDs
        }
    }

    private func collapseAll() {
        withAnimation(.easeInOut(duration: 0.15)) {
            expandedNodes.removeAll()
        }
    }

    // MARK: - Reparent Helpers

    /// Legal new parents (not itself, a descendant or the current parent), labelled
    /// with their ancestor path and ordered like the tree so same-named tags in
    /// different branches are distinguishable.
    private func validReparentTargets(for tagId: UUID) -> [TagMoveTarget] {
        let descendantIDs = tagSettings.allDescendantIDs(of: tagId)
        let currentParent = tagSettings.definitions.first(where: { $0.id == tagId })?.parentId
        var targets: [TagMoveTarget] = []
        func walk(_ parentId: UUID?, ancestors: [String]) {
            let kids = parentId == nil ? tagSettings.rootTags() : tagSettings.children(of: parentId!)
            for child in kids where child.id != tagId && !descendantIDs.contains(child.id) {
                if child.id != currentParent {
                    targets.append(TagMoveTarget(
                        id: child.id,
                        name: child.name,
                        ancestorLabel: ancestors.joined(separator: " › "),
                        color: child.color
                    ))
                }
                walk(child.id, ancestors: ancestors + [child.name])
            }
        }
        walk(nil, ancestors: [])
        return targets
    }

    private func siblingInfo(for tag: TagDefinition) -> (isFirst: Bool, isLast: Bool) {
        let siblings = tag.parentId == nil ? tagSettings.rootTags() : tagSettings.children(of: tag.parentId!)
        guard let idx = siblings.firstIndex(where: { $0.id == tag.id }) else { return (true, true) }
        return (idx == 0, idx == siblings.count - 1)
    }

    private func tagRow(_ tag: TagDefinition, depth: Int, visibility: FilterVisibility?) -> some View {
        let hasKids = !tagSettings.children(of: tag.id).isEmpty
        let childCount = hasKids ? tagSettings.childCount(of: tag.id) : 0
        let sib = siblingInfo(for: tag)

        return TagTreeRow(
            tag: tag,
            depth: depth,
            hasChildren: hasKids,
            childCount: childCount,
            isExpanded: visibility != nil ? hasKids : expandedNodes.contains(tag.id),
            isFilterContext: visibility.map { !$0.matchedIDs.contains(tag.id) } ?? false,
            isFiltering: visibility != nil,
            isDeleting: countingDeletionFor == tag.id,
            canEditArchive: mediaStore != nil,
            isEditing: editingNodeId == tag.id,
            editingName: editingNodeId == tag.id ? $editingName : .constant(""),
            isAddingChild: addingChildOf == tag.id,
            newChildName: $newChildName,
            showDuplicateNameError: $showDuplicateNameError,
            colorOptions: colorOptions,
            isRoot: tag.parentId == nil,
            isFirstSibling: sib.isFirst,
            isLastSibling: sib.isLast,
            reparentTargets: { self.validReparentTargets(for: tag.id) },
            onToggleExpand: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expandedNodes.contains(tag.id) {
                        expandedNodes.remove(tag.id)
                    } else {
                        expandedNodes.insert(tag.id)
                    }
                }
            },
            onStartRename: {
                editingNodeId = tag.id
                editingName = tag.name
                validationErrorMessage = nil
            },
            onCommitRename: {
                commitRename(tag: tag)
            },
            onCancelRename: {
                editingNodeId = nil
                editingName = ""
            },
            onColorChange: { newColor in
                tagSettings.updateColor(for: tag.id, color: newColor)
            },
            onResetColor: {
                let autoColor = TagDefinition.autoColor(for: tag.name)
                tagSettings.updateColor(for: tag.id, color: autoColor)
            },
            onAddChild: {
                addingChildOf = tag.id
                isAddingRoot = false
                newChildName = ""
                showDuplicateNameError = false
                validationErrorMessage = nil
                expandedNodes.insert(tag.id)
            },
            onCommitAddChild: {
                commitAddChild(parentId: tag.id)
            },
            onCancelAddChild: {
                addingChildOf = nil
                newChildName = ""
                showDuplicateNameError = false
            },
            onDelete: {
                requestDeletion(of: tag)
            },
            onReparent: { newParentId in
                guard tagSettings.reparent(tagId: tag.id, newParentId: newParentId) else {
                    let destination = newParentId.map { tagSettings.fullPath(of: $0) } ?? "the top level"
                    if let key = tag.shortcutKey?.uppercased() {
                        shortcutErrorMessage = "Could not move ‘\(tag.name)’ to \(destination): a tag there already uses shortcut \(key). Set this tag's shortcut to Auto first."
                    } else {
                        shortcutErrorMessage = "Could not move ‘\(tag.name)’ to \(destination)."
                    }
                    return
                }
                shortcutErrorMessage = nil
                if let newParentId {
                    expandedNodes.insert(newParentId)
                }
                statusMessage = "Moved ‘\(tag.name)’ to \(newParentId.map { tagSettings.fullPath(of: $0) } ?? "the top level")."
            },
            onMoveUp: {
                tagSettings.moveSortOrder(tagId: tag.id, direction: -1)
            },
            onMoveDown: {
                tagSettings.moveSortOrder(tagId: tag.id, direction: 1)
            },
            onShortcutChange: { rawKey in
                switch tagSettings.setShortcutKey(rawKey, for: tag.id) {
                case .success:
                    shortcutErrorMessage = nil
                case .failure(let error):
                    shortcutErrorMessage = error.message
                }
            }
        )
    }

    // MARK: - Drag-and-drop row wrapper

    @ViewBuilder
    private func draggableEditorRow(_ entry: FlatEntry, visibility: FilterVisibility?) -> some View {
        let tag = entry.tag
        let depth = entry.depth
        let dropZone: TagDropZone? = (tagDropIndicator?.tagId == tag.id) ? tagDropIndicator?.zone : nil

        tagRow(tag, depth: depth, visibility: visibility)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(dropZone == .into ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(alignment: .top) {
                if dropZone == .before { editorInsertionLine(depth: depth) }
            }
            .overlay(alignment: .bottom) {
                if dropZone == .after { editorInsertionLine(depth: depth) }
            }
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TagRowHeightPreferenceKey.self,
                        value: [tag.id: geo.size.height]
                    )
                }
            }
            .animation(.easeInOut(duration: 0.12), value: dropZone)
            .draggableTag(tag.id)
            .focusable(editingNodeId != tag.id && addingChildOf != tag.id)
            .focused($focusedTagID, equals: tag.id)
            .onMoveCommand { direction in
                handleTreeMove(direction, from: tag.id)
            }
            .simultaneousGesture(TapGesture().onEnded {
                focusedTagID = tag.id
            })
            .onDrop(
                of: [.nodrawTag],
                delegate: TagRowDropDelegate(
                    rowTagId: tag.id,
                    rowName: tag.name,
                    rowHeight: tagRowHeights[tag.id] ?? 0,
                    indicator: $tagDropIndicator,
                    mediaDropTargetTag: .constant(nil),
                    isCollapsedParent: { id in
                        tagSettings.childCount(of: id) > 0 && !expandedNodes.contains(id)
                    },
                    onSpringLoadHover: { scheduleSpringLoad($0) },
                    performTagMove: { movedId, targetId, zone in
                        performEditorTagMove(movedId: movedId, targetRowId: targetId, zone: zone)
                    },
                    performMediaDrop: { _, _ in }
                )
            )
    }

    private func handleTreeMove(_ direction: MoveCommandDirection, from tagID: UUID) {
        let visibility = filterVisibility
        let entries = flattenedTree(visibility: visibility)
        if visibility != nil {
            // Filtered rows are always expanded; arrows only move between visible rows.
            guard let index = entries.firstIndex(where: { $0.tag.id == tagID }) else { return }
            switch direction {
            case .up:
                if index > 0 { focusedTagID = entries[index - 1].tag.id }
            case .down:
                if index + 1 < entries.count { focusedTagID = entries[index + 1].tag.id }
            case .left:
                if let parentID = entries[index].tag.parentId { focusedTagID = parentID }
            case .right:
                if index + 1 < entries.count, entries[index + 1].tag.parentId == tagID {
                    focusedTagID = entries[index + 1].tag.id
                }
            @unknown default:
                break
            }
            return
        }
        guard let index = entries.firstIndex(where: { $0.tag.id == tagID }) else { return }
        switch direction {
        case .up:
            if index > 0 { focusedTagID = entries[index - 1].tag.id }
        case .down:
            if index + 1 < entries.count { focusedTagID = entries[index + 1].tag.id }
        case .right:
            if tagSettings.childCount(of: tagID) > 0 {
                if expandedNodes.contains(tagID), index + 1 < entries.count {
                    focusedTagID = entries[index + 1].tag.id
                } else {
                    expandedNodes.insert(tagID)
                }
            }
        case .left:
            if expandedNodes.contains(tagID) {
                expandedNodes.remove(tagID)
            } else if let parentID = entries[index].tag.parentId {
                focusedTagID = parentID
            }
        @unknown default:
            break
        }
    }

    private func editorInsertionLine(depth: Int) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.leading, CGFloat(min(depth, 8)) * 20 + 8)
            .padding(.trailing, 8)
    }

    private func scheduleSpringLoad(_ tagId: UUID?) {
        guard tagId != springLoadTagId else { return }
        springLoadTask?.cancel()
        springLoadTagId = tagId
        guard let tagId else { return }
        springLoadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, springLoadTagId == tagId else { return }
            _ = withAnimation(.easeInOut(duration: 0.15)) {
                expandedNodes.insert(tagId)
            }
        }
    }

    private func performEditorTagMove(movedId: UUID, targetRowId: UUID, zone: TagDropZone) {
        guard movedId != targetRowId else { return }
        let s = tagSettings

        let destParent: UUID?
        let insertIndex: Int
        switch zone {
        case .into:
            destParent = targetRowId
            insertIndex = s.children(of: targetRowId).filter { $0.id != movedId }.count
        case .before, .after:
            let targetParent = s.definitions.first(where: { $0.id == targetRowId })?.parentId
            destParent = targetParent
            let siblings = (targetParent == nil ? s.rootTags() : s.children(of: targetParent!))
                .filter { $0.id != movedId }
            let j = siblings.firstIndex(where: { $0.id == targetRowId }) ?? siblings.count
            insertIndex = (zone == .before) ? j : j + 1
        }

        guard s.move(tagId: movedId, toParent: destParent, atIndex: insertIndex) else { return }

        if let destParent {
            _ = withAnimation(.easeInOut(duration: 0.15)) {
                expandedNodes.insert(destParent)
            }
        }
    }

    private func addChildField(depth: Int, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) -> some View {
        AddChildField(
            depth: depth,
            includeDisclosureSpacer: false,
            placeholder: "Tag name",
            newChildName: $newChildName,
            showDuplicateNameError: $showDuplicateNameError,
            onCommit: onCommit,
            onCancel: onCancel
        )
    }

    // MARK: - Actions

    private func commitRename(tag: TagDefinition) {
        let displayName: String
        switch tagSettings.validateName(editingName, excluding: tag.id) {
        case .empty:
            validationErrorMessage = "Enter a tag name."
            return
        case .duplicate(let existingName):
            validationErrorMessage = "A tag named ‘\(existingName)’ already exists."
            return
        case .valid(let validName):
            displayName = validName
        }

        if displayName != tag.name {
            guard let store = mediaStore else {
                // A definition-only rename would orphan every item still carrying the
                // old name; there is no deferred cascade, so refuse instead.
                validationErrorMessage = "The library is still loading; try the rename again once it finishes."
                return
            }
            // Full rename with DB, smart folder and rule cascade.
            tagSettings.renameTag(tagId: tag.id, newName: displayName, mediaStore: store)
            statusMessage = "Renamed ‘\(tag.name)’ to ‘\(displayName)’; tagged items, smart folders and rules are updated in the background."
        }
        validationErrorMessage = nil
        editingNodeId = nil
        editingName = ""
    }

    private func commitAddChild(parentId: UUID?) {
        let displayName: String
        switch tagSettings.validateName(newChildName) {
        case .empty:
            validationErrorMessage = "Enter a tag name."
            showDuplicateNameError = true
            return
        case .duplicate(let existingName):
            validationErrorMessage = "A tag named ‘\(existingName)’ already exists."
            showDuplicateNameError = true
            return
        case .valid(let validName):
            displayName = validName
        }
        let success = tagSettings.addChildTag(name: displayName, parentId: parentId)
        if success {
            newChildName = ""
            addingChildOf = nil
            isAddingRoot = false
            showDuplicateNameError = false
            validationErrorMessage = nil
        } else {
            showDuplicateNameError = true
            validationErrorMessage = "The tag could not be created."
        }
    }

    /// Count exact references first so the confirmation states the real scope.
    /// Nothing is deleted until the user picks an option in the dialog.
    private func requestDeletion(of tag: TagDefinition) {
        guard let store = mediaStore else {
            validationErrorMessage = "The library is still loading; tags can be deleted once it finishes."
            return
        }
        guard countingDeletionFor == nil else { return }
        countingDeletionFor = tag.id
        validationErrorMessage = nil
        Task { @MainActor in
            defer { countingDeletionFor = nil }
            do {
                pendingDeletion = try await TagTreeDeletionRequest.counted(
                    tag: tag,
                    settings: tagSettings,
                    mediaStore: store
                )
            } catch {
                logError("TagTreeEditor: unable to count references for ‘\(tag.name)’: \(error)")
                validationErrorMessage = "Could not count items tagged ‘\(tag.name)’, so nothing was deleted."
            }
        }
    }

    private func perform(_ request: TagTreeDeletionRequest, includeDescendants: Bool) {
        pendingDeletion = nil
        guard let store = mediaStore else { return }
        // Delete exactly what the dialog described; a changed scope is re-confirmed.
        let tag: TagDefinition
        let children: [TagDefinition]
        let descendants: [TagDefinition]
        switch request.resolve(in: tagSettings) {
        case .missing:
            validationErrorMessage = "‘\(request.tag.name)’ no longer exists, so nothing was deleted."
            return
        case .changed(let live):
            requestDeletion(of: live)
            validationErrorMessage = "‘\(live.name)’ or its child tags changed while the confirmation was open. Nothing was deleted; review the updated scope."
            return
        case let .current(liveTag, liveChildren, liveDescendants):
            tag = liveTag
            children = liveChildren
            descendants = liveDescendants
        }

        let action: UndoableAction
        let summary: String
        let removedItemCount: () -> Int
        if includeDescendants {
            let subtreeAction = DeleteTagSubtreeAction(root: tag, descendants: descendants, mediaStore: store)
            action = subtreeAction
            summary = "Deleted ‘\(tag.name)’ and \(descendants.count) child tag\(descendants.count == 1 ? "" : "s")"
            removedItemCount = { subtreeAction.affectedItemIDsByTag[tag.id]?.count ?? 0 }
        } else {
            let tagAction = DeleteTagDefinitionAction(tag: tag, children: children, mediaStore: store)
            action = tagAction
            summary = children.isEmpty
                ? "Deleted ‘\(tag.name)’"
                : "Deleted ‘\(tag.name)’; its child tags moved up"
            removedItemCount = { tagAction.affectedItemIDs.count }
        }
        let undoHint = undoStack == nil ? "" : " Edit ▸ Undo (⌘Z) restores it."
        Task { @MainActor in
            do {
                if let undoStack {
                    try await undoStack.performAction(action)
                } else {
                    try await action.execute()
                }
                let count = removedItemCount()
                let items = count == 1 ? "1 item" : "\(count) items"
                statusMessage = "\(summary) (was on \(items)).\(undoHint)"
            } catch {
                logError("TagTreeEditor: failed to delete ‘\(tag.name)’: \(error)")
                validationErrorMessage = "Could not delete ‘\(tag.name)’: \(error.localizedDescription)"
            }
        }
    }
}

/// A legal "Move to…" destination, labelled with its path.
struct TagMoveTarget: Identifiable, Equatable {
    let id: UUID
    let name: String
    let ancestorLabel: String
    let color: Color
}

// MARK: - TagTreeRow

private struct TagTreeRow: View {
    let tag: TagDefinition
    let depth: Int
    let hasChildren: Bool
    let childCount: Int
    let isExpanded: Bool
    /// Shown only as an ancestor of a filter match.
    let isFilterContext: Bool
    let isFiltering: Bool
    /// Reference count in flight for a delete request.
    let isDeleting: Bool
    /// False while the library store is unavailable (rename/delete need it).
    let canEditArchive: Bool
    let isEditing: Bool
    @Binding var editingName: String
    let isAddingChild: Bool
    @Binding var newChildName: String
    @Binding var showDuplicateNameError: Bool
    let colorOptions: [UInt]

    let isRoot: Bool
    let isFirstSibling: Bool
    let isLastSibling: Bool
    let reparentTargets: () -> [TagMoveTarget]

    let onToggleExpand: () -> Void
    let onStartRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onColorChange: (UInt) -> Void
    let onResetColor: () -> Void
    let onAddChild: () -> Void
    let onCommitAddChild: () -> Void
    let onCancelAddChild: () -> Void
    let onDelete: () -> Void
    let onReparent: (UUID?) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onShortcutChange: (String?) -> Void

    @State private var isHovered: Bool = false
    @State private var showingColors: Bool = false
    @State private var showingMovePicker: Bool = false
    @FocusState private var isRenameFocused: Bool

    private var autoColorHex: UInt {
        TagDefinition.autoColor(for: tag.name)
    }

    // L2: Depth cap raised to 8
    private var indentWidth: CGFloat {
        CGFloat(min(depth, 8)) * 20
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // Indent
                if depth > 0 {
                    Spacer()
                        .frame(width: indentWidth)
                }

                // L2: Depth badge for tags deeper than 8
                if depth > 8 {
                    Text("\(depth)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.1))
                        )
                }

                // Disclosure triangle
                Button {
                    onToggleExpand()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .opacity(hasChildren ? 1 : 0)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(!hasChildren || isFiltering)
                .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(tag.name)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                // Color dot
                Button {
                    showingColors.toggle()
                } label: {
                    Circle()
                        .fill(tag.color)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingColors) {
                    colorPickerPopover
                }
                .accessibilityLabel("Color for \(tag.name)")

                // Name (editable or static)
                if isEditing {
                    TextField("Tag name", text: $editingName)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(hex: 0x3a3a3a))
                        )
                        .focused($isRenameFocused)
                        .onAppear { DispatchQueue.main.async { isRenameFocused = true } }
                        .onSubmit { onCommitRename() }
                        .onExitCommand { onCancelRename() }
                        .accessibilityLabel("Rename \(tag.name)")
                } else {
                    // L6: Bolder font for parents, child count in parens when collapsed
                    HStack(spacing: 4) {
                        Text(tag.name)
                            .font(.callout)
                            .fontWeight(hasChildren ? .medium : .regular)
                            .foregroundStyle(isFilterContext ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if hasChildren && !isExpanded {
                            Text("\(childCount)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                                .background(Color.white.opacity(0.06), in: Capsule())
                        }
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                    .help(tag.name)
                    .onTapGesture(count: 2) {
                        if canEditArchive { onStartRename() }
                    }
                }

                Spacer()

                // Hover actions keep their space so the shortcut column never shifts.
                ZStack {
                    HStack(spacing: 2) {
                        // Reorder buttons (up/down among siblings)
                        Button {
                            onMoveUp()
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.caption)
                                .foregroundStyle(isFirstSibling ? .quaternary : .secondary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(isFirstSibling)
                        .help("Move up")
                        .accessibilityLabel("Move \(tag.name) up")

                        Button {
                            onMoveDown()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.caption)
                                .foregroundStyle(isLastSibling ? .quaternary : .secondary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLastSibling)
                        .help("Move down")
                        .accessibilityLabel("Move \(tag.name) down")

                        Divider()
                            .frame(height: 14)
                            .padding(.horizontal, 2)

                        Button {
                            showingMovePicker = true
                        } label: {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help("Move under another tag…")
                        .accessibilityLabel("Move \(tag.name) under another tag")

                        // M5: Pencil icon to enter rename mode
                        Button {
                            onStartRename()
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canEditArchive)
                        .help(canEditArchive ? "Rename tag on every tagged item" : "Available once the library finishes loading")
                        .accessibilityLabel("Rename \(tag.name)")

                        Button {
                            onAddChild()
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help("Add child tag")
                        .accessibilityLabel("Add child to \(tag.name)")

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canEditArchive || isDeleting)
                        .help(canEditArchive ? "Delete tag… (shows affected item count first)" : "Available once the library finishes loading")
                        .accessibilityLabel("Delete \(tag.name)")
                    }
                    .opacity(isHovered && !isEditing && !isDeleting ? 1 : 0)
                    .allowsHitTesting(isHovered && !isEditing && !isDeleting)

                    if isDeleting {
                        ProgressView()
                            .controlSize(.small)
                            .help("Counting tagged items…")
                    }
                }

                Menu {
                    Button("Automatic") { onShortcutChange(nil) }
                    Divider()
                    ForEach(TagTreeNode.keySequence, id: \.self) { key in
                        Button(String(key).uppercased()) {
                            onShortcutChange(String(key))
                        }
                    }
                } label: {
                    // Automatic keys stay quiet; a pinned key reads as a keycap.
                    Text(tag.shortcutKey?.uppercased() ?? "auto")
                        .font(tag.shortcutKey == nil ? .caption2 : .caption2.monospaced().bold())
                        .foregroundStyle(tag.shortcutKey == nil ? .tertiary : .primary)
                        .frame(minWidth: 28)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            tag.shortcutKey == nil ? Color.clear : Color.accentColor.opacity(0.22),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Tagging shortcut for \(tag.name); automatic fills the next available key")
                .accessibilityLabel("Shortcut for \(tag.name)")
                .accessibilityValue(tag.shortcutKey?.uppercased() ?? "Automatic")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.05) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .accessibilityLabel(tag.name)
            .accessibilityIdentifier("tag-row-\(tag.id.uuidString.prefix(8))")
            .popover(isPresented: $showingMovePicker, arrowEdge: .trailing) {
                TagMoveTargetPicker(
                    tagName: tag.name,
                    isRoot: isRoot,
                    targets: reparentTargets(),
                    onPick: { targetID in
                        showingMovePicker = false
                        onReparent(targetID)
                    },
                    onCancel: { showingMovePicker = false }
                )
            }
            .contextMenu {
                // H1: Move Up / Move Down for sibling reorder
                if !isFirstSibling {
                    Button("Move Up") {
                        onMoveUp()
                    }
                }

                if !isLastSibling {
                    Button("Move Down") {
                        onMoveDown()
                    }
                }

                if !isFirstSibling || !isLastSibling {
                    Divider()
                }

                if !isRoot {
                    Button("Move to Root") {
                        onReparent(nil)
                    }
                }

                Button("Move Under…") {
                    showingMovePicker = true
                }

                Divider()

                Button("Rename") {
                    onStartRename()
                }
                .disabled(!canEditArchive)

                Button("Add Child") {
                    onAddChild()
                }

                Divider()

                Button("Delete…", role: .destructive) {
                    onDelete()
                }
                .disabled(!canEditArchive || isDeleting)
            }

            if isAddingChild {
                AddChildField(
                    depth: depth + 1,
                    includeDisclosureSpacer: true,
                    placeholder: "Child tag name",
                    newChildName: $newChildName,
                    showDuplicateNameError: $showDuplicateNameError,
                    onCommit: onCommitAddChild,
                    onCancel: onCancelAddChild
                )
            }
        }
    }

    // MARK: - Color Picker Popover (M2: Auto label + checkmark overlay)

    private var colorPickerPopover: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Color")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showingColors = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 4), spacing: 4) {
                Button {
                    onResetColor()
                    showingColors = false
                } label: {
                    VStack(spacing: 2) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: autoColorHex))
                                .frame(width: 28, height: 28)
                            Text("A")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                            if tag.colorHex == autoColorHex {
                                selectedCheckmark
                            }
                        }
                        Text("Auto")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Auto color")

                ForEach(colorOptions, id: \.self) { colorHex in
                    Button {
                        onColorChange(colorHex)
                        showingColors = false
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(hex: colorHex))
                                .frame(width: 28, height: 28)
                            if colorHex == tag.colorHex {
                                selectedCheckmark
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack(spacing: 6) {
                ColorPicker("Custom", selection: Binding(
                    get: { tag.color },
                    set: { newColor in
                        if let hex = TagColorHex.hex(from: newColor) {
                            onColorChange(hex)
                        }
                    }
                ), supportsOpacity: false)
                .font(.caption)
                Spacer()
                Text(String(format: "#%06X", tag.colorHex))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(width: 170)
        .background(Color(hex: 0x2a2a2a))
    }

    private var selectedCheckmark: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
    }
}

// MARK: - Move target picker

/// Searchable replacement for a flat "Move to" submenu, which is unusable once a
/// vocabulary has hundreds of tags or repeats a name in different branches.
private struct TagMoveTargetPicker: View {
    let tagName: String
    let isRoot: Bool
    let targets: [TagMoveTarget]
    let onPick: (UUID?) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""
    @FocusState private var isQueryFocused: Bool

    private var filtered: [TagMoveTarget] {
        let trimmed = TagCanonicalizer.displayName(query)
        guard !TagCanonicalizer.key(trimmed).isEmpty else { return targets }
        return targets.compactMap { target -> (TagMoveTarget, Int)? in
            if let score = TagCanonicalizer.matchScore(query: trimmed, candidate: target.name) {
                return (target, score)
            }
            if !target.ancestorLabel.isEmpty,
               let score = TagCanonicalizer.matchScore(query: trimmed, candidate: target.ancestorLabel),
               score < 100 {
                return (target, 1_000 + score)
            }
            return nil
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Move ‘\(tagName)’ under…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Find parent tag…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($isQueryFocused)
                    .onSubmit {
                        if let first = filtered.first { onPick(first.id) }
                    }
                    .onExitCommand { onCancel() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            if !isRoot {
                Button {
                    onPick(nil)
                } label: {
                    Label("Top level (no parent)", systemImage: "arrow.up.to.line")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { target in
                        Button {
                            onPick(target.id)
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(target.color)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(target.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                    if !target.ancestorLabel.isEmpty {
                                        Text(target.ancestorLabel)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 260)

            Text(filtered.isEmpty ? "No matching tags" : "\(filtered.count) possible parent\(filtered.count == 1 ? "" : "s") · Return picks the first")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { DispatchQueue.main.async { isQueryFocused = true } }
    }
}

/// sRGB hex conversion for custom tag colors.
enum TagColorHex {
    static func hex(from color: Color) -> UInt? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let r = UInt((rgb.redComponent * 255).rounded()) & 0xFF
        let g = UInt((rgb.greenComponent * 255).rounded()) & 0xFF
        let b = UInt((rgb.blueComponent * 255).rounded()) & 0xFF
        return (r << 16) | (g << 8) | b
    }
}

// MARK: - AddChildField

private struct AddChildField: View {
    let depth: Int
    let includeDisclosureSpacer: Bool
    let placeholder: String
    @Binding var newChildName: String
    @Binding var showDuplicateNameError: Bool
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if depth > 0 {
                Spacer()
                    .frame(width: CGFloat(min(depth, 8)) * 20)
            }

            if includeDisclosureSpacer {
                Spacer()
                    .frame(width: 18)
            }

            Circle()
                .fill(Color(hex: TagDefinition.autoColor(for: newChildName.isEmpty ? "new" : newChildName)))
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                TextField(placeholder, text: $newChildName)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: 0x3a3a3a))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(showDuplicateNameError ? Color.red.opacity(0.8) : Color.clear, lineWidth: 1)
                    )
                    .focused($isFocused)
                    .onAppear { DispatchQueue.main.async { isFocused = true } }
                    .onSubmit { onCommit() }
                    .onExitCommand { onCancel() }
                    .onChange(of: newChildName) { _, _ in
                        showDuplicateNameError = false
                    }

                if showDuplicateNameError {
                    Text("Check the tag name above")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                }
            }

            Button {
                onCommit()
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .disabled(newChildName.trimmingCharacters(in: .whitespaces).isEmpty)

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: 0x2a2a2a))
        )
    }
}
