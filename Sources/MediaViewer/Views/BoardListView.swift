import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - BoardListView

/// Sidebar section showing all collection boards with create/edit functionality.
/// Supports drag-drop to add items to boards.
struct BoardListView: View {
    @EnvironmentObject var appState: AppState
    @Environment(SettingsStore.self) private var settings
    @StateObject private var viewModel = BoardListViewModel()

    @State private var showingCreateSheet = false
    @State private var editingBoard: CollectionBoard?
    @State private var showingDeleteConfirm = false
    @State private var boardToDelete: CollectionBoard?

    /// Track which board is currently targeted for drop (by ID)
    @State private var dropTargetBoardId: UUID?

    // Issue #3: Inline rename state
    @State private var inlineEditingBoardId: UUID?
    @State private var inlineEditText: String = ""

    // Issue #8: Create button hover state
    @State private var isCreateButtonHovered = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: Binding(
                get: { settings.sidebarBoardsExpanded },
                set: { settings.sidebarBoardsExpanded = $0 }
            )) {
                ForEach(viewModel.boards) { board in
                    boardRow(board)
                }
                .onMove { source, destination in
                    Task {
                        await viewModel.moveBoards(from: source, to: destination)
                    }
                }
            } label: {
                HStack {
                    Text("Boards")
                    Spacer()
                    // Issue #8: Improved create button style
                    Button {
                        showingCreateSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body)  // Changed from .caption
                            .foregroundStyle(isCreateButtonHovered ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isCreateButtonHovered ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .onHover { hovering in
                        isCreateButtonHovered = hovering
                    }
                    .accessibilityLabel("Create new board")
                }
            }
        }
        .task {
            if let store = appState.boardStore {
                viewModel.configure(boardStore: store)
                await viewModel.loadBoards()
            }
        }
        .sheet(isPresented: $showingCreateSheet) {
            BoardEditorSheet(
                mode: .create,
                onSave: { name, description in
                    Task {
                        await viewModel.createBoard(name: name, description: description)
                        showingCreateSheet = false
                    }
                }
            )
        }
        .sheet(item: $editingBoard) { board in
            BoardEditorSheet(
                mode: .edit(board),
                onSave: { name, description in
                    Task {
                        var updated = board
                        updated.name = name
                        updated.description = description
                        await viewModel.updateBoard(updated)
                        editingBoard = nil
                    }
                }
            )
        }
        .confirmationDialog(
            "Delete Board?",
            isPresented: $showingDeleteConfirm,
            presenting: boardToDelete
        ) { board in
            Button("Delete \"\(board.name)\"", role: .destructive) {
                Task {
                    await viewModel.deleteBoard(board)
                    boardToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                boardToDelete = nil
            }
        } message: { board in
            Text("This will remove the board but not delete the media items in it.")
        }
    }

    // MARK: - Board Row

    @ViewBuilder
    private func boardRow(_ board: CollectionBoard) -> some View {
        boardRowContent(board)
    }

    @ViewBuilder
    private func boardRowContent(_ board: CollectionBoard) -> some View {
        let isDropTarget = dropTargetBoardId == board.id
        let itemCount = viewModel.itemCounts[board.id] ?? 0
        let isInlineEditing = inlineEditingBoardId == board.id

        HStack(spacing: 6) {
            // Issue #11: Board cover preview thumbnail
            if let coverItem = viewModel.coverItems[board.id],
               let thumbnailURL = coverItem.thumbnailSource {
                AsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    default:
                        boardIcon
                    }
                }
            } else {
                boardIcon
            }

            // Issue #3: Inline editable board name
            if isInlineEditing {
                TextField("Board name", text: $inlineEditText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        commitInlineEdit(for: board)
                    }
                    .onExitCommand {
                        cancelInlineEdit()
                    }
            } else {
                Text(board.name)
                    .lineLimit(1)
            }

            Spacer()

            // Item count badge
            if itemCount > 0 {
                Text("\(itemCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: Capsule())
                    .accessibilityHidden(true)
            }
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
        // Issue #10: Increased animation duration from 0.15 to 0.20 with pulse
        .animation(.easeInOut(duration: 0.20), value: isDropTarget)
        .contentShape(Rectangle())
        .onTapGesture {
            // Explicitly set sidebar selection to this board
            appState.commitLibraryDestinationChange(.board(board.id))
        }
        // Issue #3: Double-click for inline rename
        .gesture(
            TapGesture(count: 2).onEnded {
                startInlineEdit(for: board)
            }
        )
        .tag(SidebarSelection.board(board.id))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Board \(board.name), \(itemCount) items")
        .accessibilityHint("Double-click to rename. Drop items here to add to this board. Right-click for options.")
        .contextMenu { boardContextMenu(for: board) }
        .onDrop(of: [.mediaViewerItem, .data], isTargeted: boardDropBinding(for: board)) { providers in
            handleBoardDrop(providers: providers, board: board)
        }
    }

    @ViewBuilder
    private func boardContextMenu(for board: CollectionBoard) -> some View {
        Button("Edit...") {
            editingBoard = board
        }
        // Issue #3: Quick rename option in context menu
        Button("Rename") {
            startInlineEdit(for: board)
        }
        Divider()
        Button("Export as Folder...") {
            exportAsFolder(board)
        }
        Button("Export as HTML Gallery...") {
            exportAsHTML(board)
        }
        Divider()
        Button("Delete", role: .destructive) {
            boardToDelete = board
            showingDeleteConfirm = true
        }
    }

    private func boardDropBinding(for board: CollectionBoard) -> Binding<Bool> {
        Binding(
            get: { dropTargetBoardId == board.id },
            set: { isTargeted in
                logInfo("DROP-BOARD: isTargeted changed to \(isTargeted) for board '\(board.name)'")
                if isTargeted {
                    dropTargetBoardId = board.id
                } else if dropTargetBoardId == board.id {
                    dropTargetBoardId = nil
                }
            }
        )
    }

    private func handleBoardDrop(providers: [NSItemProvider], board: CollectionBoard) -> Bool {
        logInfo("DROP-BOARD: Handler called with \(providers.count) providers")
        guard !providers.isEmpty else {
            logInfo("DROP-BOARD: No provider")
            return false
        }

        // Capture board.id and name before async context
        let targetBoardId = board.id
        let boardName = board.name

        // Use the robust helper that tries multiple type identifiers
        loadMediaItemDragData(from: providers) { dragData in
            guard let dragData = dragData else {
                logInfo("DROP-BOARD: Failed to load drag data for '\(boardName)'")
                return
            }

            logInfo("DROP-BOARD: Dropping \(dragData.itemIds.count) items onto '\(boardName)'")

            Task { @MainActor in
                await viewModel.addItemsToBoardWithUndo(
                    itemIds: dragData.itemIds,
                    boardId: targetBoardId,
                    boardName: boardName,
                    undoStack: appState.undoStack
                )
            }
        }
        return true
    }

    // Board icon fallback
    private var boardIcon: some View {
        Image(systemName: "rectangle.stack")
            .foregroundStyle(.purple)
            .frame(width: 32, height: 32)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Issue #3: Inline Edit Helpers

    private func startInlineEdit(for board: CollectionBoard) {
        inlineEditText = board.name
        inlineEditingBoardId = board.id
    }

    private func commitInlineEdit(for board: CollectionBoard) {
        let trimmedName = inlineEditText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != board.name else {
            cancelInlineEdit()
            return
        }

        Task {
            var updated = board
            updated.name = trimmedName
            await viewModel.updateBoard(updated)
            inlineEditingBoardId = nil
        }
    }

    private func cancelInlineEdit() {
        inlineEditingBoardId = nil
        inlineEditText = ""
    }

    // MARK: - Export Actions

    private func exportAsFolder(_ board: CollectionBoard) {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Location"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            Task {
                await viewModel.exportBoard(board, to: url, format: .folder)
            }
        }
    }

    private func exportAsHTML(_ board: CollectionBoard) {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Location"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            Task {
                await viewModel.exportBoard(board, to: url, format: .html)
            }
        }
    }
}

// MARK: - Board Editor Sheet

/// Sheet for creating or editing a board
struct BoardEditorSheet: View {
    enum Mode {
        case create
        case edit(CollectionBoard)
    }

    let mode: Mode
    let onSave: (String, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var description: String = ""
    @FocusState private var nameFieldFocused: Bool
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(mode.title)
                    .font(.headline)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close (Esc)")
            }
            .padding()

            Divider()

            // Form
            Form {
                TextField("Name", text: $name)
                    .focused($nameFieldFocused)

                TextField("Description (optional)", text: $description, axis: .vertical)
                    .lineLimit(3...5)
            }
            .formStyle(.grouped)
            .padding()

            Divider()

            // Footer with buttons
            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    onSave(name, description.isEmpty ? nil : description)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 400, height: 280)
        .background(Color(nsColor: .windowBackgroundColor))
        .scaleEffect(appeared ? 1.0 : 0.95)
        .opacity(appeared ? 1.0 : 0)
        .onAppear {
            if case .edit(let board) = mode {
                name = board.name
                description = board.description ?? ""
            }
            nameFieldFocused = true
            withAnimation(.easeOut(duration: 0.15)) {
                appeared = true
            }
        }
    }
}

extension BoardEditorSheet.Mode {
    var title: String {
        switch self {
        case .create: return "New Board"
        case .edit: return "Edit Board"
        }
    }
}

// MARK: - BoardListViewModel

@MainActor
final class BoardListViewModel: ObservableObject {
    @Published private(set) var boards: [CollectionBoard] = []
    @Published private(set) var itemCounts: [UUID: Int] = [:]
    @Published private(set) var coverItems: [UUID: MediaItem] = [:]  // Issue #11: Cover items for thumbnails
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var boardStore: BoardStore?
    private var cancellables = Set<AnyCancellable>()

    func configure(boardStore: BoardStore) {
        self.boardStore = boardStore

        // Observe changes
        Task {
            boardStore.changes
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] in
                    Task {
                        await self?.loadBoards()
                    }
                }
                .store(in: &cancellables)
        }
    }

    func loadBoards() async {
        guard let store = boardStore else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let boardsWithCounts = try await store.fetchBoardsWithCounts()
            boards = boardsWithCounts.map(\.board)
            itemCounts = Dictionary(uniqueKeysWithValues: boardsWithCounts.map { ($0.board.id, $0.itemCount) })

            // Issue #11: Load cover items for thumbnails
            var covers: [UUID: MediaItem] = [:]
            for board in boards {
                if let coverItem = try await store.fetchCoverItem(boardId: board.id) {
                    covers[board.id] = coverItem
                }
            }
            coverItems = covers
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createBoard(name: String, description: String?) async {
        guard let store = boardStore else { return }

        do {
            _ = try await store.createBoard(name: name, description: description)
            await loadBoards()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateBoard(_ board: CollectionBoard) async {
        guard let store = boardStore else { return }

        do {
            try await store.updateBoard(board)
            await loadBoards()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteBoard(_ board: CollectionBoard) async {
        guard let store = boardStore else { return }

        do {
            try await store.deleteBoard(id: board.id)
            await loadBoards()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveBoards(from source: IndexSet, to destination: Int) async {
        guard let store = boardStore, let sourceIndex = source.first else { return }

        do {
            try await store.reorderBoards(from: sourceIndex, to: destination)
            await loadBoards()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addItemToBoard(itemId: UUID, boardId: UUID) async {
        guard let store = boardStore else { return }

        do {
            try await store.addItem(itemId, to: boardId)
            await loadBoards()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addItemsToBoard(itemIds: [UUID], boardId: UUID) async {
        guard let store = boardStore else { return }

        do {
            try await store.addItems(itemIds, to: boardId)
            await loadBoards()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Add items to board with undo support and toast feedback
    func addItemsToBoardWithUndo(
        itemIds: [UUID],
        boardId: UUID,
        boardName: String,
        undoStack: UndoStack
    ) async {
        guard let store = boardStore else { return }

        do {
            // Add items and get result
            let result = try await store.addItems(itemIds, to: boardId)
            await loadBoards()

            // Show appropriate toast and register undo based on result
            switch result {
            case .added(let count):
                // All items were added - register undo action
                let action = AddToBoardAction(
                    itemIds: itemIds,
                    boardId: boardId,
                    boardName: boardName,
                    boardStore: store
                )
                // Push to undo stack (items already added, so just register for undo)
                undoStack.pushForUndo(action)
                let itemWord = count == 1 ? "item" : "items"
                undoStack.showSuccessToast("Added \(count) \(itemWord) to \(boardName)")

            case .allExisted:
                // All items already in board - show info toast (no undo needed)
                let itemWord = itemIds.count == 1 ? "Item" : "Items"
                undoStack.showInfoToast("\(itemWord) already in \(boardName)")

            case .partial(let added, let existed):
                // Some added, some existed - register undo for added items only
                // Note: We register undo for all itemIds since removeItems handles non-existent gracefully
                let action = AddToBoardAction(
                    itemIds: itemIds,
                    boardId: boardId,
                    boardName: boardName,
                    boardStore: store
                )
                undoStack.pushForUndo(action)
                undoStack.showSuccessToast("Added \(added) item\(added == 1 ? "" : "s") to \(boardName) (\(existed) already there)")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportBoard(_ board: CollectionBoard, to url: URL, format: BoardExportFormat) async {
        guard let store = boardStore else { return }

        do {
            let items = try await store.fetchItems(in: board.id)
            let exporter = BoardExporter()

            let result: BoardExportResult
            switch format {
            case .folder:
                result = try exporter.exportAsFolder(board: board, items: items, to: url)
            case .html:
                result = try exporter.exportAsHTML(board: board, items: items, to: url)
            }

            if result.isSuccess {
                // Open in Finder
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: result.outputURL.path)
            } else {
                errorMessage = result.errors.joined(separator: "\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Preview

#if DEBUG
struct BoardListView_Previews: PreviewProvider {
    static var previews: some View {
        List {
            BoardListView()
        }
        .environmentObject(AppState())
        .environment(SettingsStore.shared)
        .frame(width: 220, height: 300)
    }
}
#endif
