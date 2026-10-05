import SwiftUI

// MARK: - CanvasPickerSheet

/// Sheet for selecting a canvas to add items to.
/// Issue #1: Enables adding items to canvas from grid context menu.
struct CanvasPickerSheet: View {
    let itemIds: [UUID]
    let onDismiss: () -> Void

    @EnvironmentObject var appState: AppState
    @State private var canvases: [CanvasDocument] = []
    @State private var hoveredCanvasId: UUID?
    @State private var showingCreateCanvas = false
    @State private var isLoading = true
    @FocusState private var searchFocused: Bool
    @State private var searchText = ""

    private let canvasStore = CanvasStore()
    private let canvasLayoutManager = CanvasLayoutManager()

    private var filteredCanvases: [CanvasDocument] {
        if searchText.isEmpty {
            return canvases
        }
        return canvases.filter {
            ($0.name ?? $0.folderId ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add to Canvas")
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
                TextField("Search canvases...", text: $searchText)
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

            // Canvas list
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if canvases.isEmpty {
                emptyState
            } else if filteredCanvases.isEmpty {
                noMatchesState
            } else {
                canvasList
            }

            Divider()

            // Create new canvas button
            Button {
                showingCreateCanvas = true
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Create New Canvas")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.clear)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(width: 320, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await loadCanvases()
            searchFocused = true
        }
        .sheet(isPresented: $showingCreateCanvas) {
            CanvasCreateSheet(
                onSave: { name in
                    Task {
                        if let newCanvas = await createCanvas(name: name) {
                            await addItemsToCanvas(newCanvas)
                        }
                        showingCreateCanvas = false
                    }
                }
            )
        }
    }

    // MARK: - Canvas List

    private var canvasList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(filteredCanvases) { canvas in
                    canvasRow(canvas)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func canvasRow(_ canvas: CanvasDocument) -> some View {
        let isHovered = hoveredCanvasId == canvas.id
        let canvasName = canvas.name ?? canvas.folderId ?? "Untitled Canvas"

        Button {
            Task {
                await addItemsToCanvas(canvas)
            }
        } label: {
            HStack(spacing: 10) {
                // Canvas icon
                Image(systemName: "square.grid.3x3")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                    .frame(width: 32, height: 32)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(canvasName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("Updated \(canvas.updatedAt.formatted(date: .abbreviated, time: .omitted))")
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
            hoveredCanvasId = hovering ? canvas.id : nil
        }
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("No Canvases Yet")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Create a canvas to arrange your media freely")
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

            Text("No matching canvases")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func loadCanvases() async {
        isLoading = true
        do {
            canvases = try await canvasStore.fetchCanvases()
        } catch {
            logError("Failed to load canvases: \(error)")
        }
        isLoading = false
    }

    private func createCanvas(name: String?) async -> CanvasDocument? {
        do {
            let canvas = try await canvasLayoutManager.createCanvas(folderId: "all", name: name)
            await loadCanvases()
            return canvas
        } catch {
            logError("Failed to create canvas: \(error)")
            return nil
        }
    }

    private func addItemsToCanvas(_ canvas: CanvasDocument) async {
        guard let store = appState.mediaStore else { return }

        do {
            // Get media items for the IDs
            let items = try await store.fetchItems(filter: .all.withUnlimitedLimit())
            let targetItems = items.filter { itemIds.contains($0.id) }

            guard !targetItems.isEmpty else {
                logError("No items found to add to canvas")
                return
            }

            // Load canvas into layout manager and add items
            try await canvasLayoutManager.loadCanvas(canvas.id)
            let addedCount = try await canvasLayoutManager.addItemsToCanvas(
                items: targetItems,
                canvasId: canvas.id,
                startPosition: nil
            )

            let itemWord = addedCount == 1 ? "item" : "items"
            let canvasName = canvas.name ?? "canvas"
            appState.undoStack.showSuccessToast("Added \(addedCount) \(itemWord) to \(canvasName)")

            onDismiss()
        } catch {
            logError("Failed to add items to canvas: \(error)")
        }
    }
}

// MARK: - CanvasCreateSheet

/// Simple sheet for creating a new canvas with a name.
struct CanvasCreateSheet: View {
    let onSave: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("New Canvas")
                .font(.headline)

            TextField("Canvas name (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .frame(width: 250)

            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])

                Button("Create") {
                    onSave(name.isEmpty ? nil : name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(24)
        .onAppear {
            nameFocused = true
        }
    }
}

// MARK: - Preview

#if DEBUG
struct CanvasPickerSheet_Previews: PreviewProvider {
    static var previews: some View {
        CanvasPickerSheet(
            itemIds: [UUID()],
            onDismiss: {}
        )
        .environmentObject(AppState())
    }
}
#endif
