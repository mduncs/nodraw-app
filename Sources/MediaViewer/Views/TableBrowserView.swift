import SwiftUI
import DataTable

private struct TableBatchStarRequest: Equatable {
    let ids: Set<UUID>
    let starred: Bool

    var statusText: String {
        "\(starred ? "Starring" : "Unstarring") \(ids.count) item\(ids.count == 1 ? "" : "s")…"
    }
}

private struct TableBatchStarFailure: Identifiable {
    let id = UUID()
    let request: TableBatchStarRequest
    var action: BatchStarAction? = nil
    var failedIDs: Set<UUID> = []
    var isUndoable = false
    let message: String
}

private struct TableDeleteConfirmation {
    let ids: Set<UUID>
    let deleteFromDisk: Bool

    var message: String { BatchDeleteConfirmationCopy.message(deleteFromDisk: deleteFromDisk) }
}

// MARK: - Table Browser View

/// Database-style table view for browsing media items with sortable columns,
/// inline editing, grouping, column customization, and keyboard shortcuts.
struct TableBrowserView: View {
    @EnvironmentObject var appState: AppState
    @Environment(SettingsStore.self) private var settings
    @ObservedObject var viewModel: TableBrowserViewModel
    let itemRevealRequest: TableLibraryItemRevealRequest?

    @State private var activeBatchStar: TableBatchStarRequest?
    @State private var batchStarFailure: TableBatchStarFailure?
    @State private var pendingDeleteConfirmation: TableDeleteConfirmation?

    /// Native SwiftUI column customization (visibility + reorder, auto-persisted)
    @SceneStorage("tableColumnCustomization") private var columnCustomization: TableColumnCustomization<MediaItem>

    var body: some View {
        DataTableContainer(
            itemCount: viewModel.items.count,
            selectedCount: viewModel.selectedIDs.count,
            onCopy: { copySelectedItems() },
            onExport: { exportCSV() },
            toolbar: { tableToolbar }
        ) {
            tableContent
        }
        .alert(item: $batchStarFailure) { failure in
            Alert(
                title: Text("Batch Action Failed"),
                message: Text(failure.message),
                primaryButton: .default(Text("Retry")) {
                    retryBatchStar(failure)
                },
                secondaryButton: .cancel()
            )
        }
        .confirmationDialog(
            "Delete \(pendingDeleteConfirmation?.ids.count ?? 0) items?",
            isPresented: Binding(
                get: { pendingDeleteConfirmation != nil },
                set: { if !$0 { pendingDeleteConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let confirmation = pendingDeleteConfirmation else { return }
                pendingDeleteConfirmation = nil
                appState.deleteItems(Array(confirmation.ids), deleteFromDisk: confirmation.deleteFromDisk)
            }
            Button("Cancel", role: .cancel) { pendingDeleteConfirmation = nil }
        } message: {
            Text(pendingDeleteConfirmation?.message ?? "")
        }
    }

    // MARK: - Toolbar

    private var tableToolbar: some View {
        HStack(spacing: 8) {
            // The table footer already reports item/selection counts; only surface the cap here.
            if viewModel.items.count >= 5000 {
                Text("(limit)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Showing first 5000 items. Add filters to narrow results.")
            }

            Spacer()

            if let activeBatchStar {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(activeBatchStar.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(activeBatchStar.statusText)
                .accessibilityAddTraits(.updatesFrequently)
            }

            // Group by picker
            GroupByPicker(selection: $viewModel.groupBy)

            // Row height control
            RowHeightControl(multiplier: $viewModel.rowHeight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Table Content

    @ViewBuilder
    private var tableContent: some View {
        Table(
            of: MediaItem.self,
            selection: Binding(
                get: { viewModel.selectedIDs },
                set: { viewModel.selectedIDs = $0 }
            ),
            sortOrder: $viewModel.tableSortOrder,
            columnCustomization: $columnCustomization
        ) {
            identityColumns
            metadataColumns
            dateAndSourceColumns
            mlColumns
        } rows: {
            tableRows
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .environment(\.defaultMinListRowHeight, 28 * viewModel.rowHeight)
        .overlay(LibraryViewportCommandBridge(
            surface: .table,
            isEnabled: !appState.isShowingSingleFocus && !appState.showCommandPalette
        ))
        .overlay(TableSelectionRevealBridge(request: itemRevealRequest, contextSelectionEnabled: { !appState.isShowingSingleFocus }))
        .onChange(of: viewModel.tableSortOrder) { _, newOrder in
            // Defer to next runloop tick — mutating @Published items during
            // Table's sort-descriptor update causes NSTableView diff crash
            Task { @MainActor in
                viewModel.sortItems(using: newOrder)
                syncDisplayedItemsToTable()
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            tableContextMenu(for: ids)
        } primaryAction: { ids in
            if let firstID = appState.orderedItemIDs(in: ids).first,
               let item = viewModel.item(for: firstID) {
                openInFocusView(item)
            }
        }
        .onKeyPress(.space) {
            openSelectedInFocusView()
            return .handled
        }
        .onKeyPress(.return) {
            openSelectedInFocusView()
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePreview)) { _ in
            openSelectedInFocusView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDetail)) { _ in
            openSelectedInFocusView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAll)) { _ in
            viewModel.selectAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deselectAll)) { _ in
            viewModel.clearSelection()
        }
    }

    // MARK: - Rows (flat or grouped)

    @TableRowBuilder<MediaItem>
    private var tableRows: some TableRowContent<MediaItem> {
        if viewModel.groupBy != .none && !viewModel.groups.isEmpty {
            ForEach(viewModel.groups) { group in
                Section(group.label + " (\(group.count))") {
                    ForEach(group.items) { item in
                        TableRow(item)
                    }
                }
            }
        } else {
            ForEach(viewModel.items) { item in
                TableRow(item)
            }
        }
    }

    // MARK: - Column Groups (split for type checker)

    private var identityColumns: some TableColumnContent<MediaItem, KeyPathComparator<MediaItem>> {
        TableColumn("Platform", value: \.metadata.platform) { item in
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.doc")
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 24)
                    .contentShape(Rectangle())
                    .mediaFileDrag {
                        let targets = MediaTransferResolver.orderedTargets(items: viewModel.visibleItemsInDisplayOrder,
                            selected: viewModel.selectedIDs, clicked: item)
                        return try MediaTransferResolver.resolve(items: targets)
                    }
                    .help("Drag displayed files. Selected rows transfer in display order.")
                    .accessibilityLabel("Drag displayed files")
                EditableTextCell(text: item.metadata.platform, placeholder: "Platform") { newValue in
                    updatePlatform(item: item, platform: newValue)
                }
            }
        }
        .width(min: 60, ideal: 90)
        .customizationID("platform")
        .defaultVisibility(.visible)
    }

    private var metadataColumns: some TableColumnContent<MediaItem, KeyPathComparator<MediaItem>> {
        Group {
            TableColumn("Author", value: \MediaItem.sortAuthor) { item in
                EditableTextCell(text: item.metadata.author, placeholder: "Author") { newValue in
                    updateAuthor(item: item, author: newValue)
                }
            }
            .width(min: 80, ideal: 120)
            .customizationID("author")
            .defaultVisibility(.visible)

            TableColumn("Star", sortUsing: KeyPathComparator(\MediaItem.sortStarred, order: .reverse)) { item in
                StarToggleCell(starred: item.metadata.starred) {
                    toggleStar(item: item)
                }
            }
            .width(min: 32, ideal: 40, max: 50)
            .customizationID("star")
            .defaultVisibility(.visible)

            TableColumn("Tags", sortUsing: KeyPathComparator(\MediaItem.sortTagCount)) { item in
                TagsCell(
                    tags: item.metadata.tags,
                    onAddTag: { addTagToItem(item: item) },
                    onRemoveTag: { tag in removeTagFromItem(item: item, tag: tag) }
                )
            }
            .width(min: 100, ideal: 180)
            .customizationID("tags")
            .defaultVisibility(.visible)

            TableColumn("Notes", value: \MediaItem.sortNotes) { item in
                NotesCell(notes: item.metadata.notes) { newNotes in
                    updateNotes(item: item, notes: newNotes)
                }
            }
            .width(min: 100, ideal: 200)
            .customizationID("notes")
            .defaultVisibility(.visible)

            TableColumn("OCR", value: \MediaItem.sortOCRText) { item in
                TextCell(text: item.combinedOCRText ?? "")
            }
            .width(min: 120, ideal: 220)
            .customizationID("ocrText")
            .defaultVisibility(.hidden)
        }
    }

    private var dateAndSourceColumns: some TableColumnContent<MediaItem, KeyPathComparator<MediaItem>> {
        Group {
            TableColumn("Archived", sortUsing: KeyPathComparator(\MediaItem.metadata.archivedDate, order: .reverse)) { item in
                DateCell(date: item.metadata.archivedDate)
            }
            .width(min: 90, ideal: 130)
            .customizationID("archived")
            .defaultVisibility(.visible)

            TableColumn("Created", sortUsing: KeyPathComparator(\MediaItem.sortOriginalDate, order: .reverse)) { item in
                DateCell(date: item.metadata.originalDate)
            }
            .width(min: 90, ideal: 130)
            .customizationID("created")
            .defaultVisibility(.visible)

            TableColumn("Downloaded", sortUsing: KeyPathComparator(\MediaItem.sortDownloadDate, order: .reverse)) { item in
                DateCell(date: item.metadata.downloadDate)
            }
            .width(min: 90, ideal: 130)
            .customizationID("downloaded")
            .defaultVisibility(.hidden)

            TableColumn("Imported", sortUsing: KeyPathComparator(\MediaItem.sortImportDate, order: .reverse)) { item in
                DateCell(date: item.metadata.importDate)
            }
            .width(min: 90, ideal: 130)
            .customizationID("imported")
            .defaultVisibility(.hidden)

            TableColumn("Uploaded", sortUsing: KeyPathComparator(\MediaItem.sortUploadDate, order: .reverse)) { item in
                DateCell(date: item.metadata.uploadDate)
            }
            .width(min: 90, ideal: 130)
            .customizationID("uploaded")
            .defaultVisibility(.hidden)

            TableColumn("Source", value: \MediaItem.sortSourceURL) { item in
                TextCell(text: item.metadata.source.absoluteString)
            }
            .width(min: 120, ideal: 200)
            .customizationID("source")
            .defaultVisibility(.visible)

            TableColumn("Folder", value: \MediaItem.folderName) { item in
                TextCell(text: item.folderName)
            }
            .width(min: 70, ideal: 100)
            .customizationID("folder")
            .defaultVisibility(.visible)
        }
    }

    private var mlColumns: some TableColumnContent<MediaItem, KeyPathComparator<MediaItem>> {
        Group {
            TableColumn("Caption", value: \MediaItem.sortCaption) { item in
                TextCell(text: item.generatedCaption ?? "")
            }
            .width(min: 100, ideal: 200)
            .customizationID("caption")
            .defaultVisibility(.visible)

            TableColumn("Aesthetics", sortUsing: KeyPathComparator(\MediaItem.sortAesthetics, order: .reverse)) { item in
                ScoreCell(score: item.mlAttributes["quality.aesthetics"])
            }
            .width(min: 60, ideal: 80, max: 100)
            .customizationID("aesthetics")
            .defaultVisibility(.visible)

            TableColumn("Curation", sortUsing: KeyPathComparator(\MediaItem.sortCuration, order: .reverse)) { item in
                ScoreCell(score: item.mlAttributes["curation.score"])
            }
            .width(min: 60, ideal: 80, max: 100)
            .customizationID("curation")
            .defaultVisibility(.visible)

            TableColumn("Pipeline", value: \MediaItem.sortPipelineStatus) { item in
                PipelineStatusCell(status: item.pipelineStatus)
            }
            .width(min: 60, ideal: 90, max: 120)
            .customizationID("pipeline")
            .defaultVisibility(.visible)
        }
    }

    // MARK: - Keyboard Actions

    private func openSelectedInFocusView() {
        guard let item = viewModel.firstSelectedItem else { return }
        openInFocusView(item)
    }

    private func openInFocusView(_ item: MediaItem) {
        viewModel.select(item.id)
        appState.openSingleFocus(item)
    }

    private func syncDisplayedItemsToTable() {
        appState.setDisplayContext(
            surface: .table,
            items: viewModel.visibleItemsInDisplayOrder,
            selectedIDs: viewModel.selectedIDs,
            anchorID: viewModel.selectedItemID
        )
    }

    // MARK: - Copy & Export

    private func copySelectedItems() -> String {
        let selected = viewModel.visibleItemsInDisplayOrder.filter { viewModel.selectedIDs.contains($0.id) }
        return TableCopyPolicy.tsv(items: selected)
    }

    private func exportCSV() {
        let headers = ["Platform", "Author", "Starred", "Tags", "Notes", "Archived", "Created", "Downloaded", "Imported", "Uploaded", "Source", "Folder", "Caption", "Aesthetics", "Curation", "Pipeline"]
        let rows = viewModel.items.map { item -> [String] in
            [
                item.metadata.platform,
                item.metadata.author ?? "",
                item.metadata.starred ? "true" : "false",
                item.metadata.tags.joined(separator: "; "),
                item.metadata.notes ?? "",
                DateCell.formatter.string(from: item.metadata.archivedDate),
                item.metadata.originalDate.map { DateCell.formatter.string(from: $0) } ?? "",
                item.metadata.downloadDate.map { DateCell.formatter.string(from: $0) } ?? "",
                item.metadata.importDate.map { DateCell.formatter.string(from: $0) } ?? "",
                item.metadata.uploadDate.map { DateCell.formatter.string(from: $0) } ?? "",
                item.metadata.source.absoluteString,
                item.folderName,
                item.generatedCaption ?? "",
                item.mlAttributes["quality.aesthetics"].map { String(format: "%.3f", $0) } ?? "",
                item.mlAttributes["curation.score"].map { String(format: "%.3f", $0) } ?? "",
                item.pipelineStatus ?? "none",
            ]
        }
        let csv = TableExporter.buildCSV(headers: headers, rows: rows)
        TableExporter.exportCSV(csv, filename: "media-export")
    }

    // MARK: - Inline Edit Actions

    private func toggleStar(item: MediaItem) {
        // Keep the inline control on the same undoable, failure-reporting path as
        // row and selection context actions.
        performBatchStar(ids: [item.id], starred: !item.metadata.starred)
    }

    private func updateAuthor(item: MediaItem, author: String) {
        guard let store = appState.mediaStore else { return }
        Task {
            do {
                var updated = item
                updated.metadata = MediaMetadata(
                    source: item.metadata.source,
                    platform: item.metadata.platform,
                    author: author.isEmpty ? nil : author,
                    originalDate: item.metadata.originalDate,
                    archivedDate: item.metadata.archivedDate,
                    downloadDate: item.metadata.downloadDate,
                    importDate: item.metadata.importDate,
                    starred: item.metadata.starred,
                    tags: item.metadata.tags,
                    notes: item.metadata.notes,
                    originalDateString: item.metadata.originalDateString,
                    deleted: item.metadata.deleted,
                    annotated: item.metadata.annotated,
                    subreddit: item.metadata.subreddit,
                    boardName: item.metadata.boardName,
                    blogName: item.metadata.blogName,
                    channelName: item.metadata.channelName,
                    artistName: item.metadata.artistName,
                    galleryName: item.metadata.galleryName,
                    sourceTags: item.metadata.sourceTags,
                    uploadDate: item.metadata.uploadDate,
                    viewCount: item.metadata.viewCount,
                    likeCount: item.metadata.likeCount
                )
                try await store.updateItem(updated)
            } catch {
                logError("Author update failed: \(error.localizedDescription)")
            }
        }
    }

    private func updatePlatform(item: MediaItem, platform: String) {
        guard let store = appState.mediaStore else { return }
        guard !platform.isEmpty else { return }
        Task {
            do {
                var updated = item
                updated.metadata = MediaMetadata(
                    source: item.metadata.source,
                    platform: platform,
                    author: item.metadata.author,
                    originalDate: item.metadata.originalDate,
                    archivedDate: item.metadata.archivedDate,
                    downloadDate: item.metadata.downloadDate,
                    importDate: item.metadata.importDate,
                    starred: item.metadata.starred,
                    tags: item.metadata.tags,
                    notes: item.metadata.notes,
                    originalDateString: item.metadata.originalDateString,
                    deleted: item.metadata.deleted,
                    annotated: item.metadata.annotated,
                    subreddit: item.metadata.subreddit,
                    boardName: item.metadata.boardName,
                    blogName: item.metadata.blogName,
                    channelName: item.metadata.channelName,
                    artistName: item.metadata.artistName,
                    galleryName: item.metadata.galleryName,
                    sourceTags: item.metadata.sourceTags,
                    uploadDate: item.metadata.uploadDate,
                    viewCount: item.metadata.viewCount,
                    likeCount: item.metadata.likeCount
                )
                try await store.updateItem(updated)
            } catch {
                logError("Platform update failed: \(error.localizedDescription)")
            }
        }
    }

    private func addTagToItem(item: MediaItem) {
        appState.selectedItemID = item.id
        appState.showTagInput = true
    }

    private func removeTagFromItem(item: MediaItem, tag: String) {
        guard let store = appState.mediaStore else { return }
        Task {
            do {
                try await store.removeTag(id: item.id, tag: tag)
            } catch {
                logError("Tag removal failed: \(error.localizedDescription)")
            }
        }
    }

    private func updateNotes(item: MediaItem, notes: String?) {
        guard item.metadata.notes != notes else { return }
        var updated = item
        updated.metadata.notes = notes
        viewModel.replaceItemIfPresent(updated)
        appState.replaceCachedItemIfPresent(updated)
        syncDisplayedItemsToTable()
        appState.updateNotes(for: item.id, oldNotes: item.metadata.notes, newNotes: notes)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func tableContextMenu(for ids: Set<UUID>) -> some View {
        let items = viewModel.visibleItemsInDisplayOrder.filter { ids.contains($0.id) }
        let context = MediaActionContext(items: items)

        if !items.isEmpty {
            Menu("Transfer Source") { MediaTransferActionsMenu(context: context) }
            Button("Export with Metadata…") { MediaFileAction.exportMetadata.perform(context: context, source: .downloaded, appState: appState) }
                .disabled(!context.isEnabled(.exportMetadata, source: .downloaded))
            Divider()
        }

        if items.count == 1, let item = items.first {
            Button("Open in Focus View") {
                openInFocusView(item)
            }
            Divider()
            Button(item.metadata.starred ? "Unstar" : "Star") {
                performBatchStar(ids: [item.id], starred: !item.metadata.starred)
            }
            Divider()
            Button("Open Source URL") {
                NSWorkspace.shared.open(item.metadata.source)
            }
            Button("Reveal in Finder") {
                MediaFileAction.reveal.perform(context: context, appState: appState)
            }
            .disabled(!context.isEnabled(.reveal, source: .displayed))
            Divider()
            Button("Copy Source URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.metadata.source.absoluteString, forType: .string)
            }
            Button("Copy Row as TSV") {
                TableExporter.copyToClipboard(TableCopyPolicy.tsv(items: [item]))
            }
            Divider()
            Button("Delete Item", role: .destructive) {
                requestDeleteConfirmation(ids: [item.id])
            }
        } else if items.count > 1 {
            if let primaryItem = items.first {
                Button("Combine \(items.count) Items") {
                    combineItems(primaryID: primaryItem.id, secondaryIDs: items.dropFirst().map(\.id))
                }
                Divider()
            }
            Button("Star All (\(items.count))") {
                performBatchStar(ids: Set(items.map(\.id)), starred: true)
            }
            Button("Unstar All (\(items.count))") {
                performBatchStar(ids: Set(items.map(\.id)), starred: false)
            }
            Button("Delete \(items.count) Items", role: .destructive) {
                requestDeleteConfirmation(ids: Set(items.map(\.id)))
            }
            Divider()
            Button("Copy \(items.count) Rows as TSV") {
                TableExporter.copyToClipboard(TableCopyPolicy.tsv(items: items))
            }
        } else {
            EmptyView()
        }
    }

    private func performBatchStar(ids: Set<UUID>, starred: Bool) {
        guard !ids.isEmpty, activeBatchStar == nil else { return }
        let request = TableBatchStarRequest(ids: ids, starred: starred)
        guard let store = appState.mediaStore else {
            batchStarFailure = TableBatchStarFailure(request: request, message: "The library service is not available yet.")
            return
        }
        activeBatchStar = request
        batchStarFailure = nil
        Task { @MainActor in
            defer { activeBatchStar = nil }
            do {
                let service = BatchOperationsService(mediaStore: store)
                let action = starred
                    ? try await service.makeStarAllAction(ids: ids)
                    : try await service.makeUnstarAllAction(ids: ids)
                do {
                    try await appState.undoStack.performAction(action)
                } catch let partial as BatchStarPartialFailure {
                    batchStarFailure = TableBatchStarFailure(
                        request: request,
                        action: action,
                        failedIDs: partial.failedIDs,
                        isUndoable: !partial.succeededIDs.isEmpty,
                        message: partial.localizedDescription
                    )
                }
            } catch {
                logError("Table batch star failed: \(error.localizedDescription)")
                batchStarFailure = TableBatchStarFailure(request: request, message: error.localizedDescription)
            }
        }
    }

    private func retryBatchStar(_ failure: TableBatchStarFailure) {
        guard let action = failure.action, activeBatchStar == nil else {
            performBatchStar(ids: failure.request.ids, starred: failure.request.starred)
            return
        }
        activeBatchStar = TableBatchStarRequest(ids: failure.failedIDs, starred: failure.request.starred)
        batchStarFailure = nil
        Task { @MainActor in
            defer { activeBatchStar = nil }
            do {
                try await appState.undoStack.retryBatchStar(
                    action,
                    failedIDs: failure.failedIDs,
                    alreadyUndoable: failure.isUndoable
                )
            } catch let partial as BatchStarRetryFailure {
                batchStarFailure = TableBatchStarFailure(
                    request: failure.request,
                    action: action,
                    failedIDs: partial.failedIDs,
                    isUndoable: partial.isUndoable,
                    message: partial.localizedDescription
                )
            } catch {
                batchStarFailure = TableBatchStarFailure(
                    request: failure.request,
                    action: action,
                    failedIDs: failure.failedIDs,
                    isUndoable: failure.isUndoable,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func requestDeleteConfirmation(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let deleteFromDisk = settings.deleteFilesFromDisk
        pendingDeleteConfirmation = TableDeleteConfirmation(ids: ids, deleteFromDisk: deleteFromDisk)
    }

    private func combineItems(primaryID: UUID, secondaryIDs: [UUID]) {
        guard !secondaryIDs.isEmpty, let store = appState.mediaStore else { return }

        Task {
            do {
                let result = try await store.combineItems(primaryID: primaryID, secondaryIDs: secondaryIDs)
                let service = DeleteService(mediaStore: store)
                let cleanup = await service.trashCombineOrphansResult(result.orphanedFileURLs)
                if cleanup.hasFileErrors {
                    MediaTransferFeedback.shared.reportFileFailures(cleanup.fileErrors,
                        urls: cleanup.failedFileURLs, retryTargets: cleanup.retryTargets, service: service)
                }
                await MainActor.run {
                    viewModel.selectedIDs = [result.primaryID]
                }
            } catch {
                logError("Table combine failed: \(error.localizedDescription)")
                MediaTransferFeedback.shared.report(error)
            }
        }
    }
}
