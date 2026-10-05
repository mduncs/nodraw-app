import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Sidebar Mode

/// Controls the list style based on where the sidebar is displayed.
enum SidebarMode {
    case navigationSplit  // In NavigationSplitView (default)
    case focusView        // In SingleFocusView
}

// MARK: - Sidebar List Style Modifier

/// Applies the appropriate list style based on sidebar mode.
/// Uses AnyView because SwiftUI list styles are different types.
struct SidebarListStyleModifier: ViewModifier {
    let mode: SidebarMode

    @ViewBuilder
    func body(content: Content) -> some View {
        switch mode {
        case .navigationSplit:
            AnyView(content.listStyle(.sidebar))
        case .focusView:
            AnyView(content.listStyle(.inset))
        }
    }
}

private struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory

    init(title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            accessory
                .frame(minWidth: 18, minHeight: 18, alignment: .trailing)
        }
        .frame(minHeight: 22)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}

/// Shared row metrics so every section lines up: icon column, spacing, insets.
private enum SidebarMetrics {
    static let rowSpacing: CGFloat = 6
    static let iconWidth: CGFloat = 16
    static let disclosureWidth: CGFloat = 16
    /// Month folder icons sit one step inside the year's folder icon; small enough that
    /// "YYYY-MM" plus its badge still fits at the 210pt sidebar minimum.
    static let folderMonthIndent: CGFloat = 24
    static let tagDepthIndent: CGFloat = 10
}

/// The one count capsule used by every sidebar row. Hidden at zero.
private struct SidebarCountBadge: View {
    let count: Int
    var tint: Color? = nil

    var body: some View {
        if count > 0 {
            Text(count.formatted(.number))
                .font(.caption.monospacedDigit())
                .foregroundStyle(tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(tint?.opacity(0.8) ?? Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: Capsule())
                .fixedSize()
                .accessibilityHidden(true)
        }
    }
}

private struct SidebarTagRowDisplay: Identifiable {
    let id: String
    let name: String
    let color: Color
    let count: Int
    let selection: SidebarSelection
    let depth: Int
    let tagId: UUID?
    let hasChildren: Bool
    let isExpanded: Bool
}

private struct SidebarFolderYearGroup: Identifiable {
    let year: String
    let folders: [SidebarItem]

    var id: String { year }
    var count: Int { folders.reduce(0) { $0 + $1.count } }
}

// MARK: - Sidebar View

/// Full sidebar with sections for folders, smart folders, platforms, and tags.
/// Dense layout with count badges and selection state.
struct SidebarView: View {
    var mode: SidebarMode = .navigationSplit
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = SidebarViewModel()
    @ObservedObject private var tagSettings = TagSettings.shared

    @State private var showingSmartFolderEditor = false
    @State private var editingSmartFolder: SmartFolder?
    @State private var showingColorPicker = false
    @State private var collapsedSidebarTagIds: Set<UUID> = SidebarView.loadCollapsedSidebarTagIds()
    @State private var collapsedSidebarFolderYears: Set<String> = SidebarView.loadCollapsedSidebarFolderYears()

    /// Track which folder is currently targeted for drop
    @State private var dropTargetFolder: String?
    /// Track which tag is currently targeted for drop
    @State private var dropTargetTag: String?
    /// Track if Rediscover section is targeted for drop
    @State private var dropTargetRediscover = false

    /// Track if Board section is targeted for drop (for Issue 4 drag affordance)
    @State private var dropTargetBoard: UUID?

    /// Tag tree drag-and-drop: which row + zone currently shows a drop affordance.
    @State private var tagDropIndicator: TagDropIndicator?
    /// Measured row heights, used to map a drop's pointer-Y to a zone.
    @State private var tagRowHeights: [UUID: CGFloat] = [:]
    /// Spring-loaded expand: the collapsed parent currently hovered during a drag.
    @State private var springLoadTagId: UUID?
    @State private var springLoadTask: Task<Void, Never>?

    /// Controls sidebar section collapsed states
    @Environment(SettingsStore.self) private var settings

    /// Issue 9: Cached canvas store and layout manager (avoid creating per render)
    /// Note: These are not ObservableObject, so use regular stored properties
    private let canvasStore = CanvasStore()
    private let canvasLayoutManager = CanvasLayoutManager()

    /// Issue 5: State for tag color editing
    @State private var editingTagForColor: String?
    @State private var showingTagColorPicker = false
    @State private var tagAwaitingDeletion: (name: String, count: Int)?

    private static let collapsedSidebarTagIdsKey = "sidebarCollapsedTagIds"
    private static let collapsedSidebarFolderYearsKey = "sidebarCollapsedFolderYears"

    var body: some View {
        List(selection: $viewModel.selection) {
            // MARK: - Browse Section
            // All Media (always first)
            allMediaSection

            // MARK: - Organize Section
            // Year-Month Folders (primary navigation)
            if !viewModel.folders.isEmpty {
                foldersSection
            }

            // MARK: - Smart Views Section
            // Smart Folders
            smartFoldersSection

            // Platforms
            if !viewModel.platforms.isEmpty {
                platformsSection
            }

            // Tags
            if !viewModel.tags.isEmpty {
                tagsSection
            }

            // MARK: - Collections Section
            // Collection Boards
            if FeatureFlags.boards {
                BoardListView()
            }

            // Canvas (infinite canvas view)
            if FeatureFlags.canvas {
                canvasSection
            }

            if settings.showSidebarColors {
                colorFilterSection
            }

            // MARK: - Review Section (at bottom)
            // Visual Clusters, Rediscover (flagged), Duplicates, Recently Deleted
            reviewSection
        }
        .modifier(SidebarListStyleModifier(mode: mode))
        .task(id: appState.mediaStore != nil) {
            configureAndLoad()
        }
        .onChange(of: viewModel.selection) { _, newSelection in
            updateAppState(for: newSelection)
        }
        .onChange(of: appState.sidebarSelection) { _, newSelection in
            if viewModel.selection != newSelection {
                viewModel.selection = newSelection
            }
        }
        .sheet(isPresented: $showingSmartFolderEditor) {
            SmartFolderEditor(
                existingFolder: editingSmartFolder,
                onSave: { folder in
                    Task {
                        await viewModel.saveSmartFolder(folder)
                    }
                },
                getPreviewCount: { folder in
                    await viewModel.countForSmartFolder(folder)
                }
            )
        }
        // Issue 5: Tag color picker popover
        .popover(isPresented: $showingTagColorPicker) {
            if let tagName = editingTagForColor {
                TagColorPickerPopover(tagName: tagName) {
                    showingTagColorPicker = false
                    editingTagForColor = nil
                    Task {
                        await viewModel.refreshCounts()
                    }
                }
            }
        }
        .alert(
            "Delete Tag?",
            isPresented: Binding(
                get: { tagAwaitingDeletion != nil },
                set: { if !$0 { tagAwaitingDeletion = nil } }
            ),
            presenting: tagAwaitingDeletion
        ) { tag in
            Button("Cancel", role: .cancel) { tagAwaitingDeletion = nil }
            Button("Delete Tag", role: .destructive) {
                Task {
                    await deleteTag(tag.name)
                    tagAwaitingDeletion = nil
                }
            }
        } message: { tag in
            Text("Delete the tag definition ‘\(tag.name)’ and remove this exact tag from \(tag.count) media item\(tag.count == 1 ? "" : "s") across the archive, including Recently Deleted. Child tags remain and move up one level. This can be undone.")
        }
        .contextMenu(forSelectionType: SidebarSelection.self) { selections in
            // Context menu for smart folder items
            if case .smartFolder(let id) = selections.first,
               let folder = viewModel.smartFolders.first(where: { $0.id == id }) {
                Button("Edit...") {
                    editingSmartFolder = folder
                    showingSmartFolderEditor = true
                }
                Divider()
                Button("Delete", role: .destructive) {
                    Task {
                        await viewModel.deleteSmartFolder(folder)
                    }
                }
            }
        }
    }

    // MARK: - All Media Section

    private var allMediaSection: some View {
        Section {
            sidebarRow(
                name: "All Media",
                icon: "photo.on.rectangle",
                count: viewModel.totalCount,
                selection: .allMedia
            )
        }
    }

    // MARK: - Review Section (Visual Clusters + Rediscover + Duplicates + Recently Deleted)
    // Issue 1: Moved to bottom of sidebar, combined into single section

    private var reviewSection: some View {
        Section {
            DisclosureGroup(isExpanded: Binding(
                get: { settings.sidebarTriageExpanded },
                set: { settings.sidebarTriageExpanded = $0 }
            )) {
                visualClustersRow
                // Rediscover row
                if FeatureFlags.rediscover {
                    rediscoverRow
                }
                // Duplicates row
                if FeatureFlags.deduplicate {
                    duplicatesRow
                }
                recentlyDeletedRow
            } label: {
                sectionHeader("Review")
            }
        }
    }

    private var recentlyDeletedRow: some View {
        HStack(spacing: SidebarMetrics.rowSpacing) {
            Image(systemName: "trash")
                .foregroundStyle(viewModel.recentlyDeletedCount > 0 ? .secondary : .tertiary)
                .frame(width: SidebarMetrics.iconWidth)
                .accessibilityHidden(true)

            Text("Recently Deleted")
                .lineLimit(1)

            Spacer(minLength: 4)

            SidebarCountBadge(count: viewModel.recentlyDeletedCount)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .tag(SidebarSelection.recentlyDeleted)
        .help("Review items removed from the library. Restore them or delete them permanently.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recently Deleted, \(viewModel.recentlyDeletedCount.formatted(.number)) items")
        .accessibilityIdentifier("sidebar-recently-deleted")
        .accessibilityAddTraits(viewModel.selection == .recentlyDeleted ? [.isSelected] : [])
    }

    @ViewBuilder
    private var rediscoverRow: some View {
        HStack(spacing: SidebarMetrics.rowSpacing) {
            Image(systemName: "sparkles")
                .foregroundStyle(
                    viewModel.rediscoverCount > 0 ? .purple : .secondary
                )
                .frame(width: SidebarMetrics.iconWidth)

            Text("Rediscover")
                .lineLimit(1)

            Spacer(minLength: 4)

            // Issue 2: Keep purple badge for actionable items
            SidebarCountBadge(count: viewModel.rediscoverCount, tint: .purple)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(dropTargetRediscover ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(dropTargetRediscover ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
        .animation(.easeInOut(duration: 0.15), value: dropTargetRediscover)
        .tag(SidebarSelection.rediscover)
        // Issue #2: Help text explaining Rediscover
        .help("Review saved media via spaced repetition. Items are scheduled based on how well you remember them.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Rediscover, \(viewModel.rediscoverCount.formatted(.number)) items due")
        .accessibilityIdentifier("sidebar-rediscover")
        .accessibilityHint("Drop items here to add to Rediscover queue")
        .accessibilityAddTraits(viewModel.selection == .rediscover ? [.isSelected] : [])
        .onDrop(of: [.mediaViewerItem, .data], isTargeted: $dropTargetRediscover) { providers in
            guard !providers.isEmpty else { return false }

            loadMediaItemDragData(from: providers) { dragData in
                guard let dragData = dragData else {
                    logInfo("DROP-REDISCOVER: Failed to load drag data")
                    return
                }

                logInfo("DROP-REDISCOVER: Adding \(dragData.itemIds.count) items to Rediscover queue")

                Task { @MainActor in
                    await handleDropOnRediscover(itemIds: dragData.itemIds)
                }
            }
            return true
        }
    }

    @ViewBuilder
    private var duplicatesRow: some View {
        HStack(spacing: SidebarMetrics.rowSpacing) {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(appState.pendingDuplicateCount > 0 ? .orange : .secondary)
                .frame(width: SidebarMetrics.iconWidth)

            Text("Duplicates")
                .lineLimit(1)

            Spacer(minLength: 4)

            // Issue 2: Keep orange badge for actionable items
            SidebarCountBadge(count: appState.pendingDuplicateCount, tint: .orange)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .tag(SidebarSelection.duplicates)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Duplicates, \(appState.pendingDuplicateCount.formatted(.number)) pending groups")
        .accessibilityIdentifier("sidebar-duplicates")
        .accessibilityHint("Review and resolve duplicate groups")
        .accessibilityAddTraits(viewModel.selection == .duplicates ? [.isSelected] : [])
    }

    /// Handle dropping items onto the Rediscover row
    private func handleDropOnRediscover(itemIds: [UUID]) async {
        let scheduler = ReviewScheduler()
        do {
            try await scheduler.initializeForItems(itemIds)
            // Refresh rediscover count
            await viewModel.refreshCounts()
            // Show toast feedback
            let itemWord = itemIds.count == 1 ? "item" : "items"
            appState.undoStack.showSuccessToast("Added \(itemIds.count) \(itemWord) to Rediscover")
            logInfo("DROP-REDISCOVER: Successfully added \(itemIds.count) items")
        } catch {
            logError("DROP-REDISCOVER: Failed to add items: \(error.localizedDescription)")
        }
    }

    // MARK: - Folders Section

    private var foldersSection: some View {
        Section {
            DisclosureGroup(isExpanded: Binding(
                get: { settings.sidebarFoldersExpanded },
                set: { settings.sidebarFoldersExpanded = $0 }
            )) {
                ForEach(folderYearGroups) { group in
                    folderYearRow(group)

                    if isFolderYearExpanded(group.year) {
                        ForEach(group.folders) { item in
                            folderRow(
                                name: item.name,
                                icon: item.icon,
                                count: item.count,
                                selection: item.selection,
                                depth: 1
                            )
                        }
                    }
                }
            } label: {
                sectionHeader("Folders") {
                    folderExpansionControls
                }
            }
        }
    }

    /// One toggle: expands every year while any is collapsed, otherwise collapses all.
    private var folderExpansionControls: some View {
        let anyCollapsed = folderYearGroups.contains { !isFolderYearExpanded($0.year) }
        return sidebarHeaderIconButton(
            systemName: anyCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
            help: anyCollapsed ? "Expand all folder years" : "Collapse all folder years",
            isEnabled: folderYearGroups.count > 1
        ) {
            if anyCollapsed { expandAllFolderYears() } else { collapseAllFolderYears() }
        }
    }

    private func sidebarHeaderIconButton(
        systemName: String,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            NSApp.keyWindow?.makeFirstResponder(nil)
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }

    private var folderYearGroups: [SidebarFolderYearGroup] {
        let grouped = Dictionary(grouping: viewModel.folders) { item in
            String(item.name.prefix(4))
        }

        return grouped
            .map { year, folders in
                SidebarFolderYearGroup(
                    year: year,
                    folders: folders.sorted { $0.name > $1.name }
                )
            }
            .sorted { $0.year > $1.year }
    }

    private func folderYearRow(_ group: SidebarFolderYearGroup) -> some View {
        let isExpanded = isFolderYearExpanded(group.year)
        let selection = SidebarSelection.folderYear(group.year)
        let isSelected = viewModel.selection == selection

        return HStack(spacing: SidebarMetrics.rowSpacing) {
            Button {
                setFolderYear(group.year, expanded: !isExpanded)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: SidebarMetrics.disclosureWidth, height: 22)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse \(group.year) folders" : "Expand \(group.year) folders")
            .accessibilityLabel(isExpanded ? "Collapse folder year \(group.year)" : "Expand folder year \(group.year)")

            Button {
                NSApp.keyWindow?.makeFirstResponder(nil)
                selectSidebar(selection)
            } label: {
                HStack(spacing: SidebarMetrics.rowSpacing) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .frame(width: SidebarMetrics.iconWidth)
                        .accessibilityHidden(true)

                    Text(group.year)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    SidebarCountBadge(count: group.count)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Folder year \(group.year), \(group.count.formatted(.number)) items")
            .accessibilityHint("Selects all folders in \(group.year)")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .tag(selection)
    }

    @ViewBuilder
    private func folderRow(
        name: String,
        icon: String,
        count: Int,
        selection: SidebarSelection,
        depth: Int = 0
    ) -> some View {
        let isDropTarget = dropTargetFolder == name

        HStack(spacing: SidebarMetrics.rowSpacing) {
            if depth > 0 {
                Color.clear
                    .frame(width: CGFloat(depth) * SidebarMetrics.folderMonthIndent - SidebarMetrics.rowSpacing)
            }

            // Issue 7: Removed manual orange tinting - let SwiftUI List selection handle highlighting
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: SidebarMetrics.iconWidth)
                .accessibilityHidden(true)

            Text(name)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 4)

            // Issue 2: Hide count badge when 0
            SidebarCountBadge(count: count)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isDropTarget ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isDropTarget ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
        .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        .contentShape(Rectangle())
        .tag(selection)
        .onTapGesture {
            selectSidebar(selection)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Folder \(name), \(count.formatted(.number)) items")
        .accessibilityHint("Drop items here to move them to this folder. Right-click for options.")
        .accessibilityAddTraits(viewModel.selection == selection ? [.isSelected] : [])
        .onDrop(of: [.mediaViewerItem, .data], isTargeted: Binding(
            get: { dropTargetFolder == name },
            set: { isTargeted in
                if isTargeted {
                    dropTargetFolder = name
                } else if dropTargetFolder == name {
                    dropTargetFolder = nil
                }
            }
        )) { providers in
            guard !providers.isEmpty else { return false }

            // Capture name before async context
            let targetFolder = name

            // Use the robust helper that tries multiple type identifiers
            loadMediaItemDragData(from: providers) { dragData in
                guard let dragData = dragData else {
                    logInfo("DROP-FOLDER: Failed to load drag data for folder '\(targetFolder)'")
                    return
                }

                logInfo("DROP-FOLDER: Moving \(dragData.itemIds.count) items to folder '\(targetFolder)'")

                Task { @MainActor in
                    await handleDropOnFolder(itemIds: dragData.itemIds, folderName: targetFolder)
                }
            }
            return true
        }
        // Issue 5: Add context menu to folders
        .contextMenu {
            Button("Reveal in Finder") {
                revealFolderInFinder(name)
            }
        }
    }

    /// Reveal a year-month folder in Finder (Issue 5)
    private func revealFolderInFinder(_ folderName: String) {
        let archivePath = ArchivePathStore.currentPath()
            .appendingPathComponent(folderName)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: archivePath.path)
    }

    /// Handle dropping items onto a folder row
    private func handleDropOnFolder(itemIds: [UUID], folderName: String) async {
        guard let store = appState.mediaStore else { return }

        let archivePath = ArchivePathStore.currentPath()

        do {
            try await store.moveItemsToFolder(ids: itemIds, targetFolder: folderName, archivePath: archivePath)
            // Refresh counts
            await viewModel.refreshCounts()
        } catch {
            logError("Failed to move items to folder: \(error.localizedDescription)")
            if error is MediaStore.FolderMoveError {
                appState.undoStack.showInfoToast(error.localizedDescription)
            }
        }
    }

    // MARK: - Smart Folders Section

    private var smartFoldersSection: some View {
        Section {
            DisclosureGroup(isExpanded: Binding(
                get: { settings.sidebarSmartFoldersExpanded },
                set: { settings.sidebarSmartFoldersExpanded = $0 }
            )) {
                ForEach(viewModel.smartFolders) { folder in
                    smartFolderRow(folder)
                }
            } label: {
                sectionHeader("Smart Folders") {
                    sidebarHeaderIconButton(systemName: "plus", help: "New smart folder…", isEnabled: true) {
                        editingSmartFolder = nil
                        showingSmartFolderEditor = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func smartFolderRow(_ folder: SmartFolder) -> some View {
        HStack(spacing: SidebarMetrics.rowSpacing) {
            Image(systemName: folder.displayIcon)
                .foregroundStyle(Color.accentColor)
                .frame(width: SidebarMetrics.iconWidth)
                .accessibilityHidden(true)

            Text(folder.name)
                .lineLimit(1)
                .help(folder.name)

            Spacer(minLength: 4)

            // Count badge (loaded async)
            SmartFolderCountBadge(folder: folder, viewModel: viewModel)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .tag(SidebarSelection.smartFolder(folder.id))
        .contentShape(Rectangle())
        .onTapGesture {
            selectSidebar(.smartFolder(folder.id))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Smart folder \(folder.name)")
        .accessibilityHint("Right-click to edit or delete")
        .contextMenu {
            Button("Edit...") {
                editingSmartFolder = folder
                showingSmartFolderEditor = true
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteSmartFolder(folder)
                }
            }
        }
    }

    // MARK: - Canvas Section

    @State private var canvases: [CanvasDocument] = []

    // Issue #5: Canvas deletion confirmation
    @State private var canvasToDelete: CanvasDocument?
    @State private var showingDeleteConfirmation = false

    // Issue #12: Canvas renaming
    @State private var renamingCanvas: CanvasDocument?
    @State private var renameText: String = ""

    private var canvasSection: some View {
        Section {
            DisclosureGroup(isExpanded: Binding(
                get: { settings.sidebarCanvasExpanded },
                set: { settings.sidebarCanvasExpanded = $0 }
            )) {
                ForEach(canvases) { canvas in
                    canvasRow(canvas)
                }
            } label: {
                sectionHeader("Canvas") {
                    sidebarHeaderIconButton(systemName: "plus", help: "Create new canvas", isEnabled: true) {
                        Task {
                            await createNewCanvas()
                        }
                    }
                }
            }
        }
        .task {
            await loadCanvases()
        }
        // Issue #5: Deletion confirmation alert
        .alert("Delete Canvas?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                canvasToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let canvas = canvasToDelete {
                    Task {
                        await deleteCanvas(canvas)
                        canvasToDelete = nil
                    }
                }
            }
        } message: {
            if let canvas = canvasToDelete {
                Text("Are you sure you want to delete \"\(canvas.name ?? "Untitled Canvas")\"? This cannot be undone.")
            }
        }
        // Issue #12: Canvas rename popover
        .popover(item: $renamingCanvas) { canvas in
            VStack(spacing: 12) {
                Text("Rename Canvas")
                    .font(.headline)
                TextField("Canvas name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                HStack {
                    Button("Cancel") {
                        renamingCanvas = nil
                    }
                    Button("Save") {
                        Task {
                            await renameCanvas(canvas, to: renameText)
                            renamingCanvas = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func canvasRow(_ canvas: CanvasDocument) -> some View {
        let canvasName = canvas.name ?? canvas.folderId ?? "Untitled Canvas"

        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3")
                .foregroundStyle(
                    isCanvasSelected(canvas.id) ? Color.accentColor : .cyan
                )
                .frame(width: 16)
                .accessibilityHidden(true)

            Text(canvasName)
                .lineLimit(1)

            Spacer()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .tag(SidebarSelection.canvas(canvas.id))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Canvas \(canvasName)")
        .accessibilityHint("Double-click to rename, right-click for options")
        .accessibilityAddTraits(isCanvasSelected(canvas.id) ? [.isSelected] : [])
        // Issue #12: Double-click to rename
        .onTapGesture(count: 2) {
            renameText = canvas.name ?? ""
            renamingCanvas = canvas
        }
        .contextMenu {
            // Issue #12: Rename option
            Button {
                renameText = canvas.name ?? ""
                renamingCanvas = canvas
            } label: {
                Label("Rename...", systemImage: "pencil")
            }
            Divider()
            // Issue #5: Delete with confirmation
            Button(role: .destructive) {
                canvasToDelete = canvas
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func isCanvasSelected(_ id: UUID) -> Bool {
        if case .canvas(let selectedId) = viewModel.selection {
            return selectedId == id
        }
        return false
    }

    // Issue 9: Use cached canvasStore instead of creating instances per render
    private func loadCanvases() async {
        do {
            canvases = try await canvasStore.fetchCanvases()
        } catch {
            logError("Failed to load canvases: \(error)")
        }
    }

    private func createNewCanvas() async {
        do {
            // Create canvas for current folder if one is selected, otherwise "all"
            let folderId: String
            if case .folder(let name) = viewModel.selection {
                folderId = name
            } else if case .folderYear(let year) = viewModel.selection {
                folderId = year
            } else {
                folderId = "all"
            }
            // Issue 9: Use cached canvasLayoutManager for creation
            let canvas = try await canvasLayoutManager.createCanvas(folderId: folderId, name: nil)
            await loadCanvases()
            viewModel.selection = .canvas(canvas.id)
        } catch {
            logError("Failed to create canvas: \(error)")
        }
    }

    private func deleteCanvas(_ canvas: CanvasDocument) async {
        do {
            try await canvasStore.deleteCanvas(id: canvas.id)
            await loadCanvases()
            // If we deleted the selected canvas, go back to all
            if case .canvas(let id) = viewModel.selection, id == canvas.id {
                viewModel.selection = .allMedia
            }
        } catch {
            logError("Failed to delete canvas: \(error)")
        }
    }

    // Issue #12: Rename canvas
    private func renameCanvas(_ canvas: CanvasDocument, to newName: String) async {
        var updated = canvas
        updated.name = newName.isEmpty ? nil : newName
        do {
            try await canvasStore.saveCanvas(updated)
            await loadCanvases()
        } catch {
            logError("Failed to rename canvas: \(error)")
        }
    }

    // MARK: - Visual Clusters Row (Issue 1 fix; lives in the Review section)

    private var visualClustersRow: some View {
        HStack(spacing: SidebarMetrics.rowSpacing) {
            Image(systemName: "square.grid.3x3.middle.filled")
                .foregroundStyle(.purple)
                .frame(width: SidebarMetrics.iconWidth)
                .accessibilityHidden(true)

            Text("Visual Clusters")
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .tag(SidebarSelection.visualClusters)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Visual Clusters")
        .accessibilityHint("Browse items grouped by visual similarity")
    }

    // MARK: - Platforms Section

    private var platformsSection: some View {
        Section {
            DisclosureGroup(isExpanded: Binding(
                get: { settings.sidebarPlatformsExpanded },
                set: { settings.sidebarPlatformsExpanded = $0 }
            )) {
                ForEach(viewModel.platforms) { item in
                    sidebarRow(
                        name: item.name,
                        icon: item.icon,
                        count: item.count,
                        selection: item.selection
                    )
                }
            } label: {
                sectionHeader("Platforms")
            }
        }
    }

    // MARK: - Tags Section

    private var tagsSection: some View {
        Section {
            DisclosureGroup(isExpanded: Binding(
                get: { settings.sidebarTagsExpanded },
                set: { settings.sidebarTagsExpanded = $0 }
            )) {
                ForEach(visibleSidebarTagRows) { item in
                    tagRow(
                        name: item.name,
                        color: item.color,
                        count: item.count,
                        selection: item.selection,
                        depth: item.depth,
                        tagId: item.tagId,
                        hasChildren: item.hasChildren,
                        isExpanded: item.isExpanded
                    )
                }
                .onPreferenceChange(TagRowHeightPreferenceKey.self) { heights in
                    tagRowHeights = heights
                }
            } label: {
                sectionHeader("Tags")
            }
        }
    }

    private var visibleSidebarTagRows: [SidebarTagRowDisplay] {
        let itemByName = Dictionary(
            viewModel.tags.map { (TagCanonicalizer.key($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let definedNames = Set(tagSettings.definitions.map { TagCanonicalizer.key($0.name) })
        var rows: [SidebarTagRowDisplay] = []

        func appendDefinitions(_ definitions: [TagDefinition], depth: Int) {
            for definition in definitions {
                let children = tagSettings.children(of: definition.id)
                let isExpanded = !collapsedSidebarTagIds.contains(definition.id)
                let item = itemByName[TagCanonicalizer.key(definition.name)]
                rows.append(SidebarTagRowDisplay(
                    id: definition.id.uuidString,
                    name: definition.name,
                    color: definition.color,
                    count: item?.count ?? 0,
                    selection: .tag(definition.name),
                    depth: depth,
                    tagId: definition.id,
                    hasChildren: !children.isEmpty,
                    isExpanded: isExpanded
                ))

                if isExpanded {
                    appendDefinitions(children, depth: depth + 1)
                }
            }
        }

        appendDefinitions(tagSettings.rootTags(), depth: 0)

        for item in viewModel.tags where !definedNames.contains(TagCanonicalizer.key(item.name)) {
            rows.append(SidebarTagRowDisplay(
                id: item.id,
                name: item.name,
                color: viewModel.tagColors[item.name] ?? .gray,
                count: item.count,
                selection: item.selection,
                depth: 0,
                tagId: nil,
                hasChildren: false,
                isExpanded: false
            ))
        }

        return rows
    }

    @ViewBuilder
    private func tagRow(
        name: String,
        color: Color,
        count: Int,
        selection: SidebarSelection,
        depth: Int = 0,
        tagId: UUID? = nil,
        hasChildren: Bool = false,
        isExpanded: Bool = false
    ) -> some View {
        let isDropTarget = dropTargetTag == name
        let dropZone: TagDropZone? = (tagId != nil && tagDropIndicator?.tagId == tagId)
            ? tagDropIndicator?.zone : nil
        let highlight = isDropTarget || dropZone == .into

        HStack(spacing: SidebarMetrics.rowSpacing) {
            if depth > 0 {
                Color.clear
                    // Keep deeply nested labels readable in the compact sidebar.
                    .frame(width: CGFloat(min(depth, 4)) * SidebarMetrics.tagDepthIndent - SidebarMetrics.rowSpacing)
            }

            if hasChildren, let tagId {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 18)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .offset(x: -5)
                    .frame(width: 16, height: 24)
                    .highPriorityGesture(
                        TapGesture().onEnded {
                            toggleSidebarTagExpansion(tagId)
                        }
                    )
                    .help(isExpanded ? "Collapse \(name)" : "Expand \(name)")
                    .accessibilityLabel(isExpanded ? "Collapse \(name)" : "Expand \(name)")
                    .accessibilityAddTraits(.isButton)
            } else {
                // Reserve the disclosure column so sibling dots and names line up.
                Color.clear
                    .frame(width: SidebarMetrics.disclosureWidth)
                    .accessibilityHidden(true)
            }

            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .frame(width: 10)
                .accessibilityHidden(true)

            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(name)

            Spacer(minLength: 4)

            SidebarCountBadge(count: count)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(highlight ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(highlight ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
        .overlay(alignment: .top) {
            if dropZone == .before { tagInsertionLine(depth: depth) }
        }
        .overlay(alignment: .bottom) {
            if dropZone == .after { tagInsertionLine(depth: depth) }
        }
        .background {
            if let tagId {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TagRowHeightPreferenceKey.self,
                        value: [tagId: geo.size.height]
                    )
                }
            }
        }
        .animation(.easeInOut(duration: 0.12), value: highlight)
        .animation(.easeInOut(duration: 0.12), value: dropZone)
        .contentShape(Rectangle())
        .tag(selection)
        .onTapGesture {
            selectSidebar(selection)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tag \(name), \(count.formatted(.number)) items")
        .accessibilityHint("Drag to reorganize, or drop items here to add this tag")
        .accessibilityAddTraits(viewModel.selection == selection ? [.isSelected] : [])
        .draggableTag(tagId)
        .onDrop(
            of: [.nodrawTag, .mediaViewerItem, .data],
            delegate: TagRowDropDelegate(
                rowTagId: tagId,
                rowName: name,
                rowHeight: tagId.flatMap { tagRowHeights[$0] } ?? 0,
                indicator: $tagDropIndicator,
                mediaDropTargetTag: $dropTargetTag,
                isCollapsedParent: { id in
                    tagSettings.childCount(of: id) > 0 && collapsedSidebarTagIds.contains(id)
                },
                onSpringLoadHover: { scheduleSpringLoad($0) },
                performTagMove: { movedId, targetId, zone in
                    performTagMove(movedId: movedId, targetRowId: targetId, zone: zone)
                },
                performMediaDrop: { providers, tag in
                    loadMediaItemDragData(from: providers) { dragData in
                        guard let dragData else {
                            logInfo("DROP-TAG: Failed to load drag data for tag '\(tag)'")
                            return
                        }
                        Task { @MainActor in
                            await handleDropOnTag(itemIds: dragData.itemIds, tag: tag)
                        }
                    }
                }
            )
        )
        // Issue 5: Add context menu to tags
        .contextMenu {
            Button("Change Color...") {
                editingTagForColor = name
                showingTagColorPicker = true
            }
            Divider()
            Button("Delete Tag…", role: .destructive) {
                Task {
                    guard let store = appState.mediaStore else {
                        appState.undoStack.showInfoToast("The media store is not ready; tag was not deleted")
                        return
                    }
                    do {
                        let count = try await store.countItemsTaggedExactly(tag: name)
                        tagAwaitingDeletion = (name: name, count: count)
                    } catch {
                        logError("Unable to count items tagged ‘\(name)’: \(error.localizedDescription)")
                        appState.undoStack.showInfoToast("Unable to count tag references; tag was not deleted")
                    }
                }
            }
        }
    }

    /// Handle dropping items onto a tag row
    private func handleDropOnTag(itemIds: [UUID], tag: String) async {
        guard let store = appState.mediaStore else { return }
        do {
            try await store.addTagToItems(ids: itemIds, tag: tag)
            // Refresh counts
            await viewModel.refreshCounts()
        } catch {
            logError("Failed to add tag to items: \(error.localizedDescription)")
        }
    }

    /// Delete a tag and keep an undo snapshot for the global item-tag change.
    private func deleteTag(_ tagName: String) async {
        guard let store = appState.mediaStore else { return }
        let definition = TagSettings.shared.definitions.first(where: {
            TagCanonicalizer.key($0.name) == TagCanonicalizer.key(tagName)
        }) ?? TagDefinition(name: TagCanonicalizer.displayName(tagName))
        do {
            let children = tagSettings.children(of: definition.id)
            let action = DeleteTagDefinitionAction(tag: definition, children: children, mediaStore: store)
            try await appState.undoStack.performAction(action)
            if viewModel.selection == .tag(tagName) {
                selectSidebar(.allMedia)
            }
            await viewModel.loadData()
        } catch {
            logError("Failed to delete tag ‘\(tagName)’: \(error.localizedDescription)")
            appState.undoStack.showInfoToast("Could not delete tag ‘\(tagName)’")
        }
    }

    // MARK: - Color Filter Section (Issue 3: Collapsed by default)

    private var colorFilterSection: some View {
        Section {
            DisclosureGroup(isExpanded: Binding(
                get: { settings.sidebarColorsExpanded },
                set: { settings.sidebarColorsExpanded = $0 }
            )) {
                VStack(alignment: .leading, spacing: 10) {
                    // Active precision color search (if any)
                    if let colorSearch = appState.colorSearchRGB {
                        ColorSearchChip(colorSearch: colorSearch) {
                            appState.commitLibraryFilterChange {
                                appState.colorSearchRGB = nil
                            }
                        }
                    }

                    // All 12 color buckets in a 4-column grid
                    let colorColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
                    LazyVGrid(columns: colorColumns, spacing: 6) {
                        ForEach(ColorBucket.allCases, id: \.self) { bucket in
                            ColorChip(bucket: bucket)
                        }
                    }
                }
                .padding(.vertical, 6)
            } label: {
                sectionHeader("Colors") {
                    sidebarHeaderIconButton(systemName: "eyedropper", help: "Precise color…", isEnabled: true) {
                        showingColorPicker = true
                    }
                    .popover(isPresented: $showingColorPicker, arrowEdge: .trailing) {
                        PrecisionColorSearchPopover(colorSearch: precisionColorBinding)
                    }
                }
            }
        }
    }

    private var precisionColorBinding: Binding<ColorSearchRGB?> {
        Binding(
            get: { appState.colorSearchRGB },
            set: { value in
                appState.commitLibraryFilterChange {
                    appState.colorSearchRGB = value
                }
            }
        )
    }

    // MARK: - Row Helper
    // Issue 7: Removed manual orange tinting - let SwiftUI List selection handle highlighting

    private func sectionHeader(_ title: String) -> some View {
        SidebarSectionHeader(title: title) {
            EmptyView()
        }
    }

    private func sectionHeader<Accessory: View>(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        SidebarSectionHeader(title: title, accessory: accessory)
    }

    @ViewBuilder
    private func sidebarRow(
        name: String,
        icon: String,
        count: Int,
        selection: SidebarSelection
    ) -> some View {
        HStack(spacing: SidebarMetrics.rowSpacing) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: SidebarMetrics.iconWidth)
                .accessibilityHidden(true)

            Text(name)
                .lineLimit(1)
                .help(name)

            Spacer(minLength: 4)

            // Issue 2: Hide count badge when 0
            SidebarCountBadge(count: count)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .tag(selection)
        .onTapGesture {
            selectSidebar(selection)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count > 0 ? "\(name), \(count.formatted(.number)) items" : name)
        .accessibilityIdentifier("sidebar-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))")
        .accessibilityAddTraits(viewModel.selection == selection ? [.isSelected] : [])
    }

    private static func loadCollapsedSidebarFolderYears() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapsedSidebarFolderYearsKey) ?? [])
    }

    private func saveCollapsedSidebarFolderYears() {
        UserDefaults.standard.set(
            Array(collapsedSidebarFolderYears).sorted(),
            forKey: Self.collapsedSidebarFolderYearsKey
        )
    }

    private func setFolderYear(_ year: String, expanded: Bool) {
        if expanded {
            collapsedSidebarFolderYears.remove(year)
        } else {
            collapsedSidebarFolderYears.insert(year)
        }
        saveCollapsedSidebarFolderYears()
    }

    private func isFolderYearExpanded(_ year: String) -> Bool {
        !collapsedSidebarFolderYears.contains(year)
    }

    private func expandAllFolderYears() {
        let visibleYears = Set(folderYearGroups.map(\.year))
        collapsedSidebarFolderYears.subtract(visibleYears)
        saveCollapsedSidebarFolderYears()
    }

    private func collapseAllFolderYears() {
        let visibleYears = Set(folderYearGroups.map(\.year))
        collapsedSidebarFolderYears.formUnion(visibleYears)
        saveCollapsedSidebarFolderYears()
    }

    private static func loadCollapsedSidebarTagIds() -> Set<UUID> {
        let rawIds = UserDefaults.standard.stringArray(forKey: collapsedSidebarTagIdsKey) ?? []
        return Set(rawIds.compactMap(UUID.init(uuidString:)))
    }

    private func saveCollapsedSidebarTagIds() {
        let rawIds = collapsedSidebarTagIds.map(\.uuidString).sorted()
        UserDefaults.standard.set(rawIds, forKey: Self.collapsedSidebarTagIdsKey)
    }

    private func toggleSidebarTagExpansion(_ tagId: UUID) {
        if collapsedSidebarTagIds.contains(tagId) {
            collapsedSidebarTagIds.remove(tagId)
        } else {
            collapsedSidebarTagIds.insert(tagId)
        }
        saveCollapsedSidebarTagIds()
    }

    // MARK: - Tag tree drag-and-drop

    /// Thin insertion line shown when a tag drop will reorder (drop in a row gap).
    private func tagInsertionLine(depth: Int) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.leading, CGFloat(depth) * 12 + 4)
            .padding(.trailing, 4)
    }

    /// Spring-loaded expand: after hovering a collapsed parent for a beat during a
    /// drag, auto-expand it so the user can drop into its subtree.
    private func scheduleSpringLoad(_ tagId: UUID?) {
        guard tagId != springLoadTagId else { return }
        springLoadTask?.cancel()
        springLoadTagId = tagId
        guard let tagId else { return }
        springLoadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, springLoadTagId == tagId else { return }
            collapsedSidebarTagIds.remove(tagId)
            saveCollapsedSidebarTagIds()
        }
    }

    /// Resolve a drop (moved tag + target row + zone) into a concrete move through
    /// the canonical `TagSettings.move`, then register it for undo.
    private func performTagMove(movedId: UUID, targetRowId: UUID, zone: TagDropZone) {
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

        // Capture prior position for undo before mutating.
        let oldParent = s.definitions.first(where: { $0.id == movedId })?.parentId
        let oldIndex = s.siblingIndex(of: movedId) ?? 0
        let name = s.definitions.first(where: { $0.id == movedId })?.name ?? "tag"

        guard s.move(tagId: movedId, toParent: destParent, atIndex: insertIndex) else { return }

        let newIndex = s.siblingIndex(of: movedId) ?? insertIndex
        let action = MoveTagAction(
            tagId: movedId,
            tagName: name,
            oldParentId: oldParent,
            oldIndex: oldIndex,
            newParentId: destParent,
            newIndex: newIndex
        )
        appState.undoStack.pushForUndo(action)

        // Reveal the moved tag: expand its new parent if it was collapsed.
        if let destParent {
            collapsedSidebarTagIds.remove(destParent)
            saveCollapsedSidebarTagIds()
        }
    }

    // MARK: - Actions

    private func configureAndLoad() {
        if let store = appState.mediaStore {
            let archivePath = ArchivePathStore.currentPath()
            viewModel.configure(mediaStore: store, archivePath: archivePath)
            Task {
                await viewModel.loadData()
            }
        }
    }

    private func updateAppState(for selection: SidebarSelection) {
        guard appState.sidebarSelection != selection else { return }
        let smartFolder: SmartFolder?
        if case .smartFolder(let id) = selection {
            smartFolder = viewModel.smartFolders.first { $0.id == id }
        } else {
            smartFolder = nil
        }
        appState.commitLibraryDestinationChange(selection, smartFolder: smartFolder)
    }

    private func selectSidebar(_ selection: SidebarSelection) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        viewModel.selection = selection
    }
}

// MARK: - Smart Folder Count Badge

/// Async loading badge for smart folder counts - uses cached counts from ViewModel
/// Issue 6: Shows "--" while loading instead of spinner
struct SmartFolderCountBadge: View {
    let folder: SmartFolder
    @ObservedObject var viewModel: SidebarViewModel

    var body: some View {
        Group {
            if let count = viewModel.smartFolderCounts[folder.id] {
                // Hidden when count is 0 (Issue 2)
                SidebarCountBadge(count: count)
            } else {
                // Issue 6: Show placeholder instead of spinner while loading
                Text("--")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
            }
        }
        .task(id: folder.id) {
            // Only fetch if not already cached
            if viewModel.smartFolderCounts[folder.id] == nil {
                await viewModel.loadSmartFolderCount(folder)
            }
        }
    }
}

// MARK: - Color Chip

/// Clean, minimal color chip for the sidebar color filter grid.
/// Shows a colored dot with subtle selection state.
struct ColorChip: View {
    let bucket: ColorBucket

    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

    private var isSelected: Bool {
        appState.colorFilters.contains(bucket)
    }

    private var color: Color {
        let c = bucket.uiColor
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    var body: some View {
        Button {
            appState.commitLibraryFilterChange {
                if isSelected {
                    appState.colorFilters.remove(bucket)
                } else {
                    // Only toggle this specific color - no coupling to warm/cool
                    appState.colorFilters.insert(bucket)
                }
            }
        } label: {
            VStack(spacing: 4) {
                // Color swatch
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(
                                isSelected ? Color.white.opacity(0.6) : Color.white.opacity(0.1),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                    .shadow(color: isSelected ? color.opacity(0.4) : .clear, radius: 4)

                // Label
                Text(bucket.displayName)
                    .font(.system(size: 9, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .opacity(isHovered ? 0.85 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(bucket.displayName) color filter")
        .accessibilityValue(isSelected ? "enabled" : "disabled")
        .accessibilityHint("Toggle to filter by \(bucket.displayName) images")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Color Picker Popover

/// Popover for picking a custom color via hex, RGB, or native color picker.
/// Finds the nearest ColorBucket and adds it to filters.
struct ColorPickerPopover: View {
    let onColorSelected: (ColorBucket) -> Void

    @State private var hexInput: String = ""
    @State private var redValue: Double = 128
    @State private var greenValue: Double = 128
    @State private var blueValue: Double = 128
    @State private var pickedColor: Color = .gray
    @State private var hexError: String?
    @State private var matchedBucket: ColorBucket?

    private var currentColor: Color {
        Color(red: redValue / 255, green: greenValue / 255, blue: blueValue / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a Color")
                .font(.headline)

            // Native color picker
            HStack {
                ColorPicker("", selection: $pickedColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 30, height: 30)
                    .onChange(of: pickedColor) { _, newColor in
                        updateFromSwiftUIColor(newColor)
                    }

                Text("Use system picker")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Divider()

            // Hex input
            VStack(alignment: .leading, spacing: 4) {
                Text("Hex Code")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("#FF5733", text: $hexInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onSubmit {
                            parseHex()
                        }

                    Button("Apply") {
                        parseHex()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let error = hexError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Divider()

            // RGB sliders
            VStack(alignment: .leading, spacing: 6) {
                Text("RGB Values")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                rgbSlider(label: "R", value: $redValue, color: .red)
                rgbSlider(label: "G", value: $greenValue, color: .green)
                rgbSlider(label: "B", value: $blueValue, color: .blue)
            }
            .onChange(of: redValue) { _, _ in updateMatchedBucket() }
            .onChange(of: greenValue) { _, _ in updateMatchedBucket() }
            .onChange(of: blueValue) { _, _ in updateMatchedBucket() }

            Divider()

            // Preview and match
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(currentColor)
                        .frame(width: 40, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                        )
                    Text("Input")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)

                if let bucket = matchedBucket {
                    VStack(spacing: 4) {
                        let c = bucket.uiColor
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: c.red, green: c.green, blue: c.blue))
                            .frame(width: 40, height: 40)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                            )
                        Text(bucket.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            // Find button
            Button {
                if let bucket = matchedBucket {
                    onColorSelected(bucket)
                }
            } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text("Find Similar")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(matchedBucket == nil)
        }
        .padding()
        .frame(width: 220)
        .onAppear {
            updateMatchedBucket()
        }
    }

    @ViewBuilder
    private func rgbSlider(label: String, value: Binding<Double>, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.monospaced())
                .frame(width: 12)

            Slider(value: value, in: 0...255, step: 1)
                .tint(color)

            Text("\(Int(value.wrappedValue))")
                .font(.caption.monospaced())
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func parseHex() {
        hexError = nil

        var hex = hexInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }

        guard hex.count == 6 else {
            hexError = "Enter 6 hex digits"
            return
        }

        guard let hexInt = UInt64(hex, radix: 16) else {
            hexError = "Invalid hex format"
            return
        }

        redValue = Double((hexInt >> 16) & 0xFF)
        greenValue = Double((hexInt >> 8) & 0xFF)
        blueValue = Double(hexInt & 0xFF)

        // Sync the native picker
        pickedColor = currentColor
        updateMatchedBucket()
    }

    private func updateFromSwiftUIColor(_ color: Color) {
        // Convert SwiftUI Color to NSColor to extract RGB
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.gray
        redValue = Double(nsColor.redComponent) * 255
        greenValue = Double(nsColor.greenComponent) * 255
        blueValue = Double(nsColor.blueComponent) * 255

        // Update hex field
        hexInput = String(format: "#%02X%02X%02X", Int(redValue), Int(greenValue), Int(blueValue))
        hexError = nil
        updateMatchedBucket()
    }

    private func updateMatchedBucket() {
        matchedBucket = ColorBucket.nearest(
            red: redValue / 255,
            green: greenValue / 255,
            blue: blueValue / 255
        )
    }
}

// MARK: - ColorBucket Nearest Match

extension ColorBucket {
    /// Find the nearest ColorBucket for an RGB color.
    /// Uses HSV conversion for hue-based matching, with special handling for neutrals.
    static func nearest(red: Double, green: Double, blue: Double) -> ColorBucket {
        // Convert RGB to HSV
        let maxC = max(red, green, blue)
        let minC = min(red, green, blue)
        let delta = maxC - minC

        let saturation = maxC > 0 ? delta / maxC : 0
        let value = maxC

        // Check for neutrals first (low saturation)
        if saturation < 0.15 {
            if value < 0.25 {
                return .black
            } else if value > 0.85 {
                return .white
            } else {
                return .gray
            }
        }

        // Calculate hue (0-360 degrees)
        var hue: Double = 0
        if delta > 0 {
            if maxC == red {
                hue = 60 * (((green - blue) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxC == green {
                hue = 60 * (((blue - red) / delta) + 2)
            } else {
                hue = 60 * (((red - green) / delta) + 4)
            }
        }
        if hue < 0 { hue += 360 }

        // Map hue to bucket
        // Hue ranges (approximate):
        // Red: 345-15 (wraps around)
        // Orange: 15-45
        // Yellow: 45-70
        // Green: 70-165
        // Cyan: 165-195
        // Blue: 195-265
        // Purple: 265-295
        // Pink: 295-345
        // Brown: low saturation orange-red

        // Special case: brown is low-saturation red-orange-yellow
        if saturation < 0.5 && value < 0.6 {
            if hue >= 0 && hue < 50 {
                return .brown
            }
        }

        // Map by hue angle
        switch hue {
        case 0..<15, 345..<360:
            return .red
        case 15..<45:
            return .orange
        case 45..<70:
            return .yellow
        case 70..<165:
            return .green
        case 165..<195:
            return .cyan
        case 195..<265:
            return .blue
        case 265..<295:
            return .purple
        case 295..<345:
            return .pink
        default:
            return .gray
        }
    }
}

// MARK: - Tag Color Picker Popover (Issue 5)

/// Simple color picker popover for changing tag colors
struct TagColorPickerPopover: View {
    let tagName: String
    let onDismiss: () -> Void

    @State private var selectedColor: Color

    private let presetColors: [UInt] = [
        0xE57373, 0xF06292, 0xBA68C8, 0x9575CD,
        0x7986CB, 0x64B5F6, 0x4FC3F7, 0x4DD0E1,
        0x4DB6AC, 0x81C784, 0xAED581, 0xDCE775,
        0xFFD54F, 0xFFB74D, 0xFF8A65, 0xA1887F
    ]

    init(tagName: String, onDismiss: @escaping () -> Void) {
        self.tagName = tagName
        self.onDismiss = onDismiss
        let definition = TagSettings.shared.definition(for: tagName)
        self._selectedColor = State(initialValue: definition.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Color for \"\(tagName)\"")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 30))], spacing: 8) {
                ForEach(presetColors, id: \.self) { colorHex in
                    let color = Color(hex: colorHex)
                    Button {
                        selectedColor = color
                        saveColor(hex: colorHex)
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                ColorPicker("Custom:", selection: $selectedColor, supportsOpacity: false)
                    .onChange(of: selectedColor) { _, newColor in
                        saveColorFromSwiftUI(newColor)
                    }
            }

            Button("Done") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding()
        .frame(width: 200)
    }

    private func saveColor(hex: UInt) {
        if let definition = TagSettings.shared.definitions.first(where: {
            TagCanonicalizer.key($0.name) == TagCanonicalizer.key(tagName)
        }) {
            TagSettings.shared.updateColor(for: definition.id, color: hex)
        }
    }

    private func saveColorFromSwiftUI(_ color: Color) {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.gray
        let r = UInt(nsColor.redComponent * 255) & 0xFF
        let g = UInt(nsColor.greenComponent * 255) & 0xFF
        let b = UInt(nsColor.blueComponent * 255) & 0xFF
        let hex = (r << 16) | (g << 8) | b
        saveColor(hex: hex)
    }
}

/// Undoable archive-wide tag removal. The tag definition and exact affected IDs are
/// retained so Undo restores the former hierarchy entry and each media reference.
final class DeleteTagDefinitionAction: UndoableAction, @unchecked Sendable {
    private let definition: TagDefinition
    private let childDefinitions: [TagDefinition]
    private let mediaStore: MediaStore
    private(set) var affectedItemIDs: [UUID] = []

    init(tag: TagDefinition, children: [TagDefinition], mediaStore: MediaStore) {
        self.definition = tag
        self.childDefinitions = children
        self.mediaStore = mediaStore
    }

    var description: String { "Deleted tag ‘\(definition.name)’" }

    func execute() async throws {
        affectedItemIDs = try await mediaStore.removeTagGlobally(tag: definition.name)
        await MainActor.run {
            let settings = TagSettings.shared
            for (offset, child) in childDefinitions.enumerated() {
                guard settings.move(
                    tagId: child.id,
                    toParent: definition.parentId,
                    atIndex: definition.sortOrder + offset
                ) else {
                    // A sibling-scoped shortcut may collide after promotion. Drop only
                    // that override so the normal automatic shortcut sequence can apply.
                    _ = settings.setShortcutKey(nil, for: child.id)
                    _ = settings.move(
                        tagId: child.id,
                        toParent: definition.parentId,
                        atIndex: definition.sortOrder + offset
                    )
                    continue
                }
            }
            settings.removeTag(definition)
        }
    }

    func undo() async throws {
        // Restore the durable item references first. If that write fails, keep the
        // hierarchy in its deleted state too, so a retry does not expose a tag
        // definition whose references are still missing.
        try await mediaStore.addTagToItems(ids: affectedItemIDs, tag: definition.name)
        await MainActor.run {
            let settings = TagSettings.shared
            var definitions = settings.definitions
            for child in childDefinitions {
                if let index = definitions.firstIndex(where: { $0.id == child.id }) {
                    definitions[index] = child
                }
            }
            if let index = definitions.firstIndex(where: { $0.id == definition.id }) {
                definitions[index] = definition
            } else {
                definitions.append(definition)
            }
            settings.definitions = definitions
        }
    }

}

// MARK: - Preview

#if DEBUG
struct SidebarView_Previews: PreviewProvider {
    static var previews: some View {
        SidebarView()
            .environmentObject(AppState())
            .frame(width: 220, height: 600)
    }
}

struct ColorPickerPopover_Previews: PreviewProvider {
    static var previews: some View {
        ColorPickerPopover { bucket in
            logDebug("Selected: \(bucket)")
        }
        .frame(width: 250, height: 400)
    }
}
#endif
