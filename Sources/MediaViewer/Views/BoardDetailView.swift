import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Sort Options

enum BoardSortOption: String, CaseIterable {
    case manual = "Manual"
    case dateAdded = "Date Added"
    case name = "Name"

    var icon: String {
        switch self {
        case .manual: return "hand.draw"
        case .dateAdded: return "calendar"
        case .name: return "textformat"
        }
    }
}

// MARK: - BoardDetailView

/// Grid view showing contents of a collection board with drag-to-reorder support.
struct BoardDetailView: View {
    let boardId: UUID

    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = BoardDetailViewModel()

    @State private var selectedItems: Set<UUID> = []
    @State private var showingRemoveConfirm = false
    @State private var draggedItem: UUID?

    // Issue #4: Filtering and sorting
    @State private var searchText = ""
    @State private var sortOption: BoardSortOption = .manual

    // Issue #5: Keyboard navigation
    @State private var focusedIndex: Int? = nil
    @FocusState private var isGridFocused: Bool

    // Issue #6: Hover state for position badge
    @State private var hoveredItemId: UUID?
    @State private var isDragging = false

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 12)
    ]

    // Filtered and sorted items
    private var displayItems: [MediaItem] {
        var result = viewModel.items

        // Apply search filter
        if !searchText.isEmpty {
            result = result.filter { item in
                item.metadata.platform.localizedCaseInsensitiveContains(searchText) ||
                (item.metadata.author?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                item.metadata.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }

        // Apply sorting (only if not manual)
        switch sortOption {
        case .manual:
            break // Keep original order
        case .dateAdded:
            result.sort(by: { $0.metadata.archivedDate > $1.metadata.archivedDate })
        case .name:
            result.sort(by: { ($0.metadata.author ?? "").localizedCaseInsensitiveCompare($1.metadata.author ?? "") == .orderedAscending })
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            if let board = viewModel.board {
                boardHeader(board)
            }

            // Issue #4: Toolbar with search and sort
            if !viewModel.items.isEmpty {
                filterToolbar
            }

            // Content
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.items.isEmpty {
                emptyState
            } else if displayItems.isEmpty {
                noMatchesState
            } else {
                itemsGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x1a1a1a))
        .task {
            if let store = appState.boardStore {
                viewModel.configure(boardStore: store, boardId: boardId, undoStack: appState.undoStack)
                await viewModel.loadBoard()
            }
        }
        .confirmationDialog(
            "Remove Selected Items?",
            isPresented: $showingRemoveConfirm
        ) {
            Button("Remove \(selectedItems.count) Item\(selectedItems.count == 1 ? "" : "s")", role: .destructive) {
                Task {
                    await viewModel.removeItems(Array(selectedItems))
                    selectedItems.removeAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items will be removed from this board but not deleted from your library.")
        }
        // Issue #5: Keyboard navigation via NotificationCenter
        .onReceive(NotificationCenter.default.publisher(for: .gridNavigateUp)) { _ in
            navigateGrid(direction: .up)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gridNavigateDown)) { _ in
            navigateGrid(direction: .down)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gridNavigateLeft)) { _ in
            navigateGrid(direction: .left)
        }
        .onReceive(NotificationCenter.default.publisher(for: .gridNavigateRight)) { _ in
            navigateGrid(direction: .right)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAll)) { _ in
            selectAll()
        }
        // Issue #9: Delete key handled via background NSView keyboard monitor
        .background(
            BoardKeyboardMonitor(
                onDelete: { handleDeleteKey() },
                onExport: { handleExport() }
            )
        )
    }

    // MARK: - Board Header

    @ViewBuilder
    private func boardHeader(_ board: CollectionBoard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(.purple)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(board.name)
                        .font(.title2.bold())

                    if let description = board.description, !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Item count
                Text("\(viewModel.items.count) items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Actions
                Menu {
                    Button("Set Cover from Selected") {
                        if let first = selectedItems.first {
                            Task {
                                await viewModel.setCover(itemId: first)
                            }
                        }
                    }
                    .disabled(selectedItems.count != 1)

                    Divider()

                    Button("Remove Selected", role: .destructive) {
                        showingRemoveConfirm = true
                    }
                    .disabled(selectedItems.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                }
                .menuStyle(.borderlessButton)

                // Close button
                Button {
                    appState.commitLibraryDestinationChange(.allMedia)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close board")
                .accessibilityLabel("Close board")
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Filter Toolbar (Issue #4)

    private var filterToolbar: some View {
        HStack(spacing: 12) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search in board...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 250)

            // Sort picker
            Picker("Sort", selection: $sortOption) {
                ForEach(BoardSortOption.allCases, id: \.self) { option in
                    Label(option.rawValue, systemImage: option.icon)
                        .tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            Spacer()

            // Selection info
            if !selectedItems.isEmpty {
                Text("\(selectedItems.count) selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    // MARK: - Empty State (Issue #7)

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Items in Board")
                .font(.headline)

            // Issue #7: Updated empty state text
            Text("Press B or use context menu > Add to Board to add items.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Matching Items")
                .font(.headline)

            Text("Try adjusting your search")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Clear Search") {
                searchText = ""
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Items Grid

    private var itemsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                    boardItemCell(item, index: index)
                }
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .focusable()
        .focused($isGridFocused)
        .onAppear {
            isGridFocused = true
        }
    }

    // MARK: - Item Cell

    @ViewBuilder
    private func boardItemCell(_ item: MediaItem, index: Int) -> some View {
        let isSelected = selectedItems.contains(item.id)
        let isFocused = focusedIndex == index
        let isHovered = hoveredItemId == item.id
        // Issue #6: Show position badge only on hover or while dragging
        let showPositionBadge = isHovered || isDragging || draggedItem != nil

        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // Thumbnail
                CachedImageView(item: item, size: .small, contentMode: .fill)
                    .frame(height: 150)
                    .clipped()

                // Info bar
                HStack {
                    Text(item.metadata.platform)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if item.mediaFiles.count > 1 {
                        Label("\(item.mediaFiles.count)", systemImage: "square.stack")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if item.hasVideo {
                        Image(systemName: "video")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.accentColor : (isFocused ? Color.accentColor.opacity(0.5) : Color.clear),
                        lineWidth: isSelected ? 3 : (isFocused ? 2 : 0)
                    )
            )
            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)

            // Selection indicator
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(8)
            }

            // Issue #6: Position badge (only on hover or while dragging)
            if showPositionBadge {
                Text("\(index + 1)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.5), in: Capsule())
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .onHover { hovering in
            hoveredItemId = hovering ? item.id : nil
        }
        .onTapGesture {
            focusedIndex = index
            if isSelected {
                selectedItems.remove(item.id)
            } else {
                selectedItems.insert(item.id)
            }
        }
        .mediaFileDrag {
            isDragging = true
            draggedItem = item.id
            return try MediaTransferResolver.resolve(items: [item])
        }
        .onDrop(of: [.mediaViewerItem], delegate: BoardItemDropDelegate(
            item: item,
            index: index,
            items: displayItems,
            draggedItem: $draggedItem,
            isDragging: $isDragging,
            onReorder: { from, to in
                Task {
                    await viewModel.reorderItem(from: from, to: to)
                }
            }
        ))
        .contextMenu {
            Button("View in Library") {
                // Navigate to item in main grid
                appState.commitLibraryDestinationChange(.allMedia, selecting: item.id)
            }

            if viewModel.board?.coverItemId != item.id {
                Button("Set as Cover") {
                    Task {
                        await viewModel.setCover(itemId: item.id)
                    }
                }
            }

            Divider()

            Button("Remove from Board", role: .destructive) {
                Task {
                    await viewModel.removeItems([item.id])
                    selectedItems.remove(item.id)
                }
            }
        }
    }

    private var placeholderImage: some View {
        Rectangle()
            .fill(Color(nsColor: .quaternaryLabelColor))
            .frame(height: 150)
            .overlay(
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            )
    }

    // MARK: - Keyboard Navigation (Issue #5)

    private enum NavigationDirection {
        case up, down, left, right
    }

    private func navigateGrid(direction: NavigationDirection) {
        guard !displayItems.isEmpty else { return }

        let columnsPerRow = max(1, Int(floor(600 / 200))) // Approximate based on typical width

        let newIndex: Int
        switch direction {
        case .up:
            if let current = focusedIndex {
                newIndex = max(0, current - columnsPerRow)
            } else {
                newIndex = 0
            }
        case .down:
            if let current = focusedIndex {
                newIndex = min(displayItems.count - 1, current + columnsPerRow)
            } else {
                newIndex = 0
            }
        case .left:
            if let current = focusedIndex {
                newIndex = max(0, current - 1)
            } else {
                newIndex = displayItems.count - 1
            }
        case .right:
            if let current = focusedIndex {
                newIndex = min(displayItems.count - 1, current + 1)
            } else {
                newIndex = 0
            }
        }

        focusedIndex = newIndex
    }

    private func selectAll() {
        selectedItems = Set(displayItems.map(\.id))
    }

    // MARK: - Issue #9: Keyboard Delete

    private func handleDeleteKey() {
        guard !selectedItems.isEmpty else { return }
        showingRemoveConfirm = true
    }

    // MARK: - Issue #12: Export

    private func handleExport() {
        guard !selectedItems.isEmpty, let board = viewModel.board else { return }

        // Export board as folder
        let panel = NSOpenPanel()
        panel.title = "Choose Export Location"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Export selected items
            let selectedItemsList = displayItems.filter { selectedItems.contains($0.id) }
            let exporter = BoardExporter()
            do {
                _ = try exporter.exportAsFolder(board: board, items: selectedItemsList, to: url)
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
            } catch {
                logError("Export failed: \(error)")
            }
        }
    }
}

// MARK: - Keyboard Monitor for Delete/Export

/// NSViewRepresentable that monitors for Delete and Cmd+Shift+E keys
struct BoardKeyboardMonitor: NSViewRepresentable {
    let onDelete: () -> Void
    let onExport: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = BoardKeyboardView()
        view.onDelete = onDelete
        view.onExport = onExport
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? BoardKeyboardView {
            view.onDelete = onDelete
            view.onExport = onExport
        }
    }
}

private class BoardKeyboardView: NSView {
    var onDelete: (() -> Void)?
    var onExport: (() -> Void)?
    private var keyMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupMonitor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMonitor()
    }

    private func setupMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Delete/Backspace
            if event.keyCode == 51 || event.keyCode == 117 { // Backspace or Delete
                self.onDelete?()
                return nil
            }

            // Cmd+Shift+E for export
            if event.modifierFlags.contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "e" {
                self.onExport?()
                return nil
            }

            return event
        }
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil // Pass through all clicks
    }
}

// MARK: - Drop Delegate

struct BoardItemDropDelegate: DropDelegate {
    let item: MediaItem
    let index: Int
    let items: [MediaItem]
    @Binding var draggedItem: UUID?
    @Binding var isDragging: Bool
    let onReorder: (Int, Int) -> Void

    func performDrop(info: DropInfo) -> Bool {
        isDragging = false
        draggedItem = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggedItem = draggedItem,
              draggedItem != item.id,
              let fromIndex = items.firstIndex(where: { $0.id == draggedItem }) else {
            return
        }

        if fromIndex != index {
            onReorder(fromIndex, index)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Keep isDragging true until performDrop
    }
}

// MARK: - BoardDetailViewModel

@MainActor
final class BoardDetailViewModel: ObservableObject {
    @Published private(set) var board: CollectionBoard?
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var boardStore: BoardStore?
    private var boardId: UUID?
    private var undoStack: UndoStack?
    private var cancellables = Set<AnyCancellable>()

    func configure(boardStore: BoardStore, boardId: UUID, undoStack: UndoStack) {
        self.boardStore = boardStore
        self.boardId = boardId
        self.undoStack = undoStack

        // Observe changes
        Task {
            boardStore.changes
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] in
                    Task {
                        await self?.loadBoard()
                    }
                }
                .store(in: &cancellables)
        }
    }

    func loadBoard() async {
        guard let store = boardStore, let boardId = boardId else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            board = try await store.fetchBoard(id: boardId)
            items = try await store.fetchItems(in: boardId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Issue #13: Reorder with undo support
    func reorderItem(from sourceIndex: Int, to destinationIndex: Int) async {
        guard let store = boardStore, let boardId = boardId, let undoStack = undoStack else { return }

        // Capture old positions for undo
        let oldItems = items

        // Optimistic update for smooth drag
        let movedItem = items.remove(at: sourceIndex)
        let insertIndex = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        items.insert(movedItem, at: max(0, min(insertIndex, items.count)))

        do {
            try await store.reorderItem(in: boardId, from: sourceIndex, to: destinationIndex)

            // Register undo action
            let action = ReorderBoardItemAction(
                boardId: boardId,
                fromIndex: sourceIndex,
                toIndex: destinationIndex,
                boardStore: store
            )
            undoStack.pushForUndo(action)
        } catch {
            errorMessage = error.localizedDescription
            // Revert to old order
            items = oldItems
        }
    }

    func removeItems(_ itemIds: [UUID]) async {
        guard let store = boardStore, let boardId = boardId else { return }

        do {
            try await store.removeItems(itemIds, from: boardId)
            await loadBoard()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setCover(itemId: UUID?) async {
        guard let store = boardStore, let boardId = boardId else { return }

        do {
            try await store.setCover(boardId: boardId, itemId: itemId)
            await loadBoard()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Issue #13: Reorder Undo Action

struct ReorderBoardItemAction: UndoableAction {
    let boardId: UUID
    let fromIndex: Int
    let toIndex: Int
    let boardStore: BoardStore

    var description: String {
        "Reordered board item"
    }

    func execute() async throws {
        // Already executed
    }

    func undo() async throws {
        // Reverse the reorder
        try await boardStore.reorderItem(in: boardId, from: toIndex, to: fromIndex)
    }
}

// MARK: - Preview

#if DEBUG
struct BoardDetailView_Previews: PreviewProvider {
    static var previews: some View {
        BoardDetailView(boardId: UUID())
            .environmentObject(AppState())
            .frame(width: 600, height: 500)
    }
}
#endif
