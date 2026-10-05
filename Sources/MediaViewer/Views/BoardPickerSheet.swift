import SwiftUI

// MARK: - BoardPickerSheet

/// Sheet for selecting a board to add items to.
/// Similar pattern to TagOverlay but as a modal sheet with list of boards.
struct BoardPickerSheet: View {
    let itemIds: [UUID]
    let onDismiss: () -> Void

    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = BoardPickerViewModel()
    @State private var hoveredBoardId: UUID?
    @State private var showingCreateBoard = false
    @FocusState private var searchFocused: Bool
    @State private var searchText = ""

    private var filteredBoards: [CollectionBoard] {
        if searchText.isEmpty {
            return viewModel.boards
        }
        return viewModel.boards.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add to Board")
                    .font(.headline)

                Spacer()

                Text("\(itemIds.count) item\(itemIds.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    onDismiss()
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

            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search boards...", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.top, 12)

            // Board list
            if viewModel.boards.isEmpty {
                emptyState
            } else if filteredBoards.isEmpty {
                noMatchesState
            } else {
                boardList
            }

            Divider()

            // Create new board button
            Button {
                showingCreateBoard = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Create New Board")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hoveredBoardId == nil ? Color.clear : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 320, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if let store = appState.boardStore {
                viewModel.configure(boardStore: store)
                await viewModel.loadBoards()
            }
            searchFocused = true
        }
        .sheet(isPresented: $showingCreateBoard) {
            BoardEditorSheet(
                mode: .create,
                onSave: { name, description in
                    Task {
                        if let newBoard = await viewModel.createBoard(name: name, description: description) {
                            // Add items to new board
                            await addItemsToBoard(newBoard)
                        }
                        showingCreateBoard = false
                    }
                }
            )
        }
    }

    // MARK: - Board List

    private var boardList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(filteredBoards) { board in
                    boardRow(board)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func boardRow(_ board: CollectionBoard) -> some View {
        let isHovered = hoveredBoardId == board.id
        let itemCount = viewModel.itemCounts[board.id] ?? 0

        Button {
            Task {
                await addItemsToBoard(board)
            }
        } label: {
            HStack(spacing: 10) {
                // Board thumbnail preview
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

                VStack(alignment: .leading, spacing: 2) {
                    Text(board.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(itemCount) item\(itemCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredBoardId = hovering ? board.id : nil
        }
    }

    private var boardIcon: some View {
        Image(systemName: "rectangle.stack")
            .font(.title3)
            .foregroundStyle(.purple)
            .frame(width: 32, height: 32)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("No Boards Yet")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Create a board to organize your media")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("No matching boards")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func addItemsToBoard(_ board: CollectionBoard) async {
        guard let store = appState.boardStore else { return }

        do {
            let result = try await store.addItems(itemIds, to: board.id)

            // Show toast based on result
            switch result {
            case .added(let count):
                let action = AddToBoardAction(
                    itemIds: itemIds,
                    boardId: board.id,
                    boardName: board.name,
                    boardStore: store
                )
                appState.undoStack.pushForUndo(action)
                let itemWord = count == 1 ? "item" : "items"
                appState.undoStack.showSuccessToast("Added \(count) \(itemWord) to \(board.name)")

            case .allExisted:
                let itemWord = itemIds.count == 1 ? "Item" : "Items"
                appState.undoStack.showInfoToast("\(itemWord) already in \(board.name)")

            case .partial(let added, let existed):
                let action = AddToBoardAction(
                    itemIds: itemIds,
                    boardId: board.id,
                    boardName: board.name,
                    boardStore: store
                )
                appState.undoStack.pushForUndo(action)
                appState.undoStack.showSuccessToast("Added \(added) item\(added == 1 ? "" : "s") to \(board.name) (\(existed) already there)")
            }

            onDismiss()
        } catch {
            logError("Failed to add items to board: \(error)")
        }
    }
}

// MARK: - BoardPickerViewModel

@MainActor
final class BoardPickerViewModel: ObservableObject {
    @Published private(set) var boards: [CollectionBoard] = []
    @Published private(set) var itemCounts: [UUID: Int] = [:]
    @Published private(set) var coverItems: [UUID: MediaItem] = [:]

    private var boardStore: BoardStore?

    func configure(boardStore: BoardStore) {
        self.boardStore = boardStore
    }

    func loadBoards() async {
        guard let store = boardStore else { return }

        do {
            let boardsWithCounts = try await store.fetchBoardsWithCounts()
            boards = boardsWithCounts.map(\.board)
            itemCounts = Dictionary(uniqueKeysWithValues: boardsWithCounts.map { ($0.board.id, $0.itemCount) })

            // Load cover items for thumbnails
            for board in boards {
                if let coverItem = try await store.fetchCoverItem(boardId: board.id) {
                    coverItems[board.id] = coverItem
                }
            }
        } catch {
            logError("Failed to load boards: \(error)")
        }
    }

    func createBoard(name: String, description: String?) async -> CollectionBoard? {
        guard let store = boardStore else { return nil }

        do {
            let board = try await store.createBoard(name: name, description: description)
            await loadBoards()
            return board
        } catch {
            logError("Failed to create board: \(error)")
            return nil
        }
    }
}

// MARK: - Preview

#if DEBUG
struct BoardPickerSheet_Previews: PreviewProvider {
    static var previews: some View {
        BoardPickerSheet(
            itemIds: [UUID()],
            onDismiss: {}
        )
        .environmentObject(AppState())
    }
}
#endif
