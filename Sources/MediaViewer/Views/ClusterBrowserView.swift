import SwiftUI

// MARK: - Cluster Browser View

/// Browse items grouped by visual cluster.
/// Shows cluster thumbnails with item counts, clicking shows items in that cluster.
struct ClusterBrowserView: View {
    @EnvironmentObject private var appState: AppState

    /// Callback when user selects an item
    let onItemSelected: (MediaItem) -> Void

    /// Callback when user double-clicks to open item
    let onItemDoubleClicked: (MediaItem) -> Void

    /// Callback to dismiss the view
    let onDismiss: () -> Void

    // MARK: - State

    @State private var clusters: [ClusterInfo] = []
    @State private var selectedCluster: ClusterInfo?
    @State private var isLoading = true
    @State private var isLoadingItems = false
    @StateObject private var clusterGridViewModel = MasonryGridViewModel()
    @State private var errorMessage: String?
    @State private var isNotConfigured = false

    // Issue #3: Clustering progress and cancel
    @State private var isClustering = false
    @State private var clusteringProgress: String?
    @State private var clusteringTask: Task<Void, Never>?

    // Rename
    @State private var isRenamingCluster = false
    @State private var renamingClusterId: Int?
    @State private var renameText = ""

    var body: some View {
        HSplitView {
            // Left: Cluster list
            clusterListView
                .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

            // Right: Items in selected cluster
            clusterDetailView
                .frame(minWidth: 400)
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            await loadClusters()
        }
    }

    // MARK: - Cluster List View

    private var clusterListView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Visual Clusters")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close (Esc)")
                .accessibilityLabel("Close cluster browser")
            }
            .padding()

            Divider()

            // Issue #2: Error display with retry
            if let error = errorMessage {
                errorView(message: error)
            } else if isNotConfigured {
                // Issue #4: Explicit message for not configured
                notConfiguredView
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if clusters.isEmpty {
                emptyClusterView
            } else {
                clusterList
            }
        }
    }

    // Issue #2: Error view with retry button
    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text("Error")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                errorMessage = nil
                Task {
                    await loadClusters()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // Issue #4: Not configured view
    private var notConfiguredView: some View {
        VStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("Vision Processing Required")
                .font(.headline)
            Text("Clustering requires Vision processing to complete first. Process your library in Settings > Maintenance.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyClusterView: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No clusters yet")
                .font(.headline)
            Text("Run clustering to group similar images")
                .font(.caption)
                .foregroundColor(.secondary)

            // Issue #3: Show progress during clustering
            if isClustering {
                VStack(spacing: 8) {
                    ProgressView()
                    if let progress = clusteringProgress {
                        Text(progress)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Button("Cancel") {
                        clusteringTask?.cancel()
                        clusteringTask = nil
                        isClustering = false
                        clusteringProgress = nil
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 8)
            } else {
                Button("Run Clustering") {
                    clusteringTask = Task {
                        await runClustering()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var clusterList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(clusters) { cluster in
                    ClusterRowView(
                        cluster: cluster,
                        isSelected: selectedCluster?.id == cluster.id
                    )
                    .onTapGesture {
                        selectCluster(cluster)
                    }
                    // Issue #7: Accessibility labels
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(cluster.name), \(cluster.itemCount) items")
                    .accessibilityHint("Double-tap to view items in this cluster")
                    .accessibilityAddTraits(selectedCluster?.id == cluster.id ? [.isSelected] : [])
                }
            }
            .padding()
        }
    }

    // MARK: - Cluster Detail View

    private var clusterDetailView: some View {
        VStack(spacing: 0) {
            // Header
            if let cluster = selectedCluster {
                clusterDetailHeader(cluster)
            } else {
                noClusterSelectedView
            }

            Divider()

            // Items
            if isLoadingItems {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedCluster == nil {
                Color.clear
            } else if clusterGridViewModel.items.isEmpty {
                Text("No items in this cluster")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MasonryGrid(
                    viewModel: clusterGridViewModel,
                    useHybridLayout: false,
                    showColorBars: false,
                    isBackgrounded: false,
                    onItemSelected: onItemSelected,
                    onItemDoubleClicked: onItemDoubleClicked,
                    onShowContextMenu: nil,
                    onLoadMore: nil
                )
            }
        }
    }

    private func clusterDetailHeader(_ cluster: ClusterInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if isRenamingCluster, renamingClusterId == cluster.clusterId {
                    TextField("Cluster name", text: $renameText, onCommit: {
                        commitRename(cluster)
                    })
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .frame(maxWidth: 300)
                    .onExitCommand {
                        isRenamingCluster = false
                    }
                } else {
                    Text(cluster.name)
                        .font(.headline)
                        .onTapGesture(count: 2) {
                            startRename(cluster)
                        }
                        .help("Double-click to rename")
                }
                if !cluster.topLabels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(cluster.topLabels, id: \.self) { label in
                            Text(label)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.1))
                                .cornerRadius(4)
                        }
                    }
                }
                Text("\(cluster.itemCount) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private var noClusterSelectedView: some View {
        Text("Select a cluster to view items")
            .foregroundColor(.secondary)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rename

    private func startRename(_ cluster: ClusterInfo) {
        renameText = cluster.name
        renamingClusterId = cluster.clusterId
        isRenamingCluster = true
    }

    private func commitRename(_ cluster: ClusterInfo) {
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            isRenamingCluster = false
            return
        }
        isRenamingCluster = false

        Task {
            guard let engine = ClusteringEngine.sharedIfConfigured else { return }
            await engine.renameCluster(cluster.clusterId, to: newName)
            // Update local state
            if let idx = clusters.firstIndex(where: { $0.clusterId == cluster.clusterId }) {
                clusters[idx].name = newName
            }
            if selectedCluster?.clusterId == cluster.clusterId {
                selectedCluster?.name = newName
            }
        }
    }

    // MARK: - Data Loading

    private func loadClusters() async {
        isLoading = true
        errorMessage = nil
        isNotConfigured = false

        do {
            // Issue #4: Explicit check for configuration
            guard let engine = ClusteringEngine.sharedIfConfigured else {
                await MainActor.run {
                    self.isNotConfigured = true
                    self.clusters = []
                    self.isLoading = false
                }
                return
            }

            // Get cluster summary
            let summary = try await engine.clusterSummary()

            // Get representative items for thumbnails
            let representatives = try await engine.clusterRepresentatives(perCluster: 3)

            // Issue #6: Batch fetch all representative items (avoid N+1)
            let store = MediaStore()
            var allRepIds: [UUID] = []
            for (_, repIds) in representatives {
                allRepIds.append(contentsOf: repIds.prefix(3))
            }

            let allItems = try await store.fetchItems(ids: allRepIds)
            let itemsById = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })

            var clusterInfos: [ClusterInfo] = []

            for entry in summary {
                let repIds = representatives[entry.clusterId] ?? []
                let thumbItems = repIds.prefix(3).compactMap { itemsById[$0] }

                clusterInfos.append(ClusterInfo(
                    clusterId: entry.clusterId,
                    itemCount: entry.count,
                    representativeItems: thumbItems,
                    name: entry.name,
                    topLabels: entry.topLabels
                ))
            }

            await MainActor.run {
                self.clusters = clusterInfos.sorted { $0.itemCount > $1.itemCount }
                self.isLoading = false

                // Auto-select first cluster
                if selectedCluster == nil, let first = self.clusters.first {
                    selectCluster(first)
                }
            }

        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func selectCluster(_ cluster: ClusterInfo) {
        selectedCluster = cluster
        Task {
            await loadClusterItems(cluster.clusterId)
        }
    }

    private func loadClusterItems(_ clusterId: Int) async {
        await MainActor.run {
            isLoadingItems = true
        }

        do {
            guard let engine = ClusteringEngine.sharedIfConfigured else {
                await MainActor.run {
                    self.clusterGridViewModel.setItems([])
                    self.appState.setDisplayContext(surface: .visualClusters, items: [])
                    self.isLoadingItems = false
                }
                return
            }
            let itemIds = try await engine.itemsInCluster(clusterId)

            // Issue #5: Batch fetch all items (avoid N+1)
            let store = MediaStore()
            let items = try await store.fetchItems(ids: itemIds)

            await MainActor.run {
                self.clusterGridViewModel.setItems(items)
                self.appState.setDisplayContext(surface: .visualClusters, items: items)
                self.isLoadingItems = false
            }

        } catch {
            await MainActor.run {
                self.clusterGridViewModel.setItems([])
                self.appState.setDisplayContext(surface: .visualClusters, items: [])
                self.isLoadingItems = false
            }
        }
    }

    private func runClustering() async {
        await MainActor.run {
            isClustering = true
            clusteringProgress = "Initializing..."
        }

        do {
            guard let engine = ClusteringEngine.sharedIfConfigured else {
                throw ClusteringError.notConfigured
            }

            // Issue #3: Adaptive k based on item count
            // Get total item count with feature vectors
            let store = MediaStore()
            let totalCount = try await store.countItems()

            // Adaptive k: sqrt(itemCount) capped at 50, minimum 5
            let adaptiveK = max(5, min(50, Int(sqrt(Double(totalCount)))))

            await MainActor.run {
                clusteringProgress = "Clustering \(totalCount) items into ~\(adaptiveK) clusters..."
            }

            try await engine.runClustering(k: adaptiveK)

            await MainActor.run {
                isClustering = false
                clusteringProgress = nil
            }

            await loadClusters()

        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isClustering = false
                self.clusteringProgress = nil
            }
        }
    }
}

// MARK: - Clustering Error

enum ClusteringError: Error, LocalizedError {
    case notConfigured
    case insufficientData

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Clustering engine not initialized"
        case .insufficientData:
            return "Not enough items with feature vectors to cluster"
        }
    }
}

// MARK: - Cluster Info

/// Info about a cluster including representative thumbnails
struct ClusterInfo: Identifiable {
    let clusterId: Int
    let itemCount: Int
    let representativeItems: [MediaItem]
    var name: String
    var topLabels: [String]

    var id: Int { clusterId }
}

// MARK: - Cluster Row View

/// Row showing a cluster in the list with thumbnails
struct ClusterRowView: View {
    let cluster: ClusterInfo
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Thumbnail stack
            ZStack {
                ForEach(Array(cluster.representativeItems.prefix(3).enumerated()), id: \.offset) { index, item in
                    thumbnailView(for: item)
                        .frame(width: 40, height: 40)
                        .cornerRadius(4)
                        .offset(x: CGFloat(index) * 8, y: CGFloat(index) * 4)
                }
            }
            .frame(width: 60, height: 50)

            VStack(alignment: .leading, spacing: 2) {
                Text(cluster.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                if !cluster.topLabels.isEmpty {
                    Text(cluster.topLabels.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text("\(cluster.itemCount) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(8)
    }

    private func thumbnailView(for item: MediaItem) -> some View {
        CachedImageView(item: item, size: .small, contentMode: .fill)
    }
}
