import SwiftUI
import Combine

struct ProcessingSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Library Maintenance
                SettingsSection(
                    title: "Library Maintenance",
                    icon: "arrow.triangle.2.circlepath",
                    description: "Keep the library in step with the files on disk and repair stale entries."
                ) {
                    FilesystemSyncContent(appState: appState)
                }

                // ML Pipeline
                SettingsSection(
                    title: "ML Pipeline",
                    icon: "cpu",
                    description: "Image analysis, OCR, and content classification."
                ) {
                    PipelineContent(appState: appState, settings: settings)
                }

                // Canvas Settings
                if FeatureFlags.canvas || FeatureFlags.boards {
                    SettingsSection(
                        title: "Canvas",
                        icon: "rectangle.3.group",
                        description: "Infinite canvas behavior for boards."
                    ) {
                        CanvasContent(settings: settings)
                    }
                }

                // Image editor defaults (read when focus view opens Edit image)
                SettingsSection(
                    title: "Image Editor",
                    icon: "pencil.tip.crop.circle",
                    description: "Starting pen width and color for Edit image. Takes effect the next time an item opens in focus view."
                ) {
                    AnnotationContent(settings: settings)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Filesystem Sync Content

private struct FilesystemSyncContent: View {
    @ObservedObject var appState: AppState
    @State private var showSyncConfirmation = false
    @State private var showCleanupConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Sync with filesystem
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync with filesystem")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                    Text("Move items whose media files are missing on disk to Recently Deleted.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if appState.isFilesystemSyncing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 80)
                } else {
                    Button("Sync Now…") {
                        showSyncConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .confirmationDialog(
                        "Sync the library with files on disk?",
                        isPresented: $showSyncConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Sync Now") {
                            Task { await appState.syncWithFilesystem() }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("Items whose media files are all missing move to Recently Deleted, where they can be restored. Items that only lost their media but still have a context image keep that image as their preview; that change is not undone by restoring. Nothing is removed from disk.")
                    }
                }
            }

            if let result = appState.lastFilesystemSyncResult {
                HStack(spacing: 16) {
                    Label("\(result.scannedCount) scanned", systemImage: "doc.text.magnifyingglass")
                    Label("\(result.softDeletedCount) moved to Recently Deleted", systemImage: "trash")
                    if result.cleanedUpCount > 0 {
                        Label("\(result.cleanedUpCount) cleaned", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Database cleanup
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Database cleanup")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                    Text("Remove file:// entries that duplicate a captured item's files, and repair month-only folder paths.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if appState.isDatabaseCleaning {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 80)
                } else {
                    Button("Clean Up…") {
                        showCleanupConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .confirmationDialog(
                        "Clean up duplicate library entries?",
                        isPresented: $showCleanupConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Clean Up", role: .destructive) {
                            Task { await appState.cleanupDatabaseIssues() }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("Permanently removes library entries imported from file:// sources whose media files also belong to an item with a real source URL; the files stay on disk with that item. Also repoints items whose stored folder is only a month folder (like 2026-02) to their own item folder. This skips Recently Deleted and can't be undone.")
                    }
                }
            }

            if let result = appState.lastDatabaseCleanupResult {
                HStack(spacing: 16) {
                    if result.duplicateFileUrlsDeleted > 0 {
                        Label("\(result.duplicateFileUrlsDeleted) duplicates deleted", systemImage: "doc.on.doc")
                    }
                    if result.basePathsFixed > 0 {
                        Label("\(result.basePathsFixed) paths fixed", systemImage: "folder.badge.gearshape")
                    }
                    if result.duplicateFileUrlsDeleted == 0 && result.basePathsFixed == 0 {
                        Label("No issues found", systemImage: "checkmark.circle")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Pipeline Content

private struct PipelineContent: View {
    @ObservedObject var appState: AppState
    let settings: SettingsStore
    @State private var pipelineStatus: PipelineQueueStatus = .idle
    @State private var processedCount = 0
    @State private var totalCount = 0
    @State private var failedCount = 0
    @State private var attributeCount = 0
    @State private var vectorCount = 0
    @State private var isReindexing = false
    @State private var isBackfilling = false
    @State private var isRetryingFailed = false
    @State private var showReindexConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status
            HStack(spacing: 8) {
                let isActive = !pipelineStatus.isIdle
                let isConfigured = PipelineQueue.isConfigured
                Circle()
                    .fill(isActive ? Color.orange : (isConfigured ? Color.green : Color.secondary))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isActive ? "Processing" : (isConfigured ? "Idle" : "Not running"))
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                    Text(pipelineStatusDetail(isActive: isActive, isConfigured: isConfigured))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if isActive {
                    Button("Pause") {
                        Task {
                            guard let pipelineQueue = PipelineQueue.sharedIfConfigured else { return }
                            await pipelineQueue.pause()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if PipelineQueue.isConfigured {
                    Button("Resume") {
                        Task {
                            guard let pipelineQueue = PipelineQueue.sharedIfConfigured else { return }
                            await pipelineQueue.resume()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider()
                .background(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 8) {
                Text("Analysis coverage")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)

                HStack(spacing: 12) {
                    coverageStat(label: "Items", value: "\(processedCount) / \(totalCount)")
                    coverageStat(label: "Attributes", value: attributeCount.formatted())
                    coverageStat(label: "CLIP vectors", value: vectorCount.formatted())
                }

                Text("Scene, object, face, quality, safety, curation, junk, caption, fingerprint, body pose, animal, document, and barcode modules are available when the ML pipeline is configured.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()
                .background(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 8) {
                Text("Background processing speed")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)

                Picker(
                    "",
                    selection: Binding(
                        get: { settings.backgroundProcessingIntensity },
                        set: { settings.backgroundProcessingIntensity = $0 }
                    )
                ) {
                    ForEach(BackgroundProcessingIntensity.allCases, id: \.self) { intensity in
                        Text(intensity.label)
                            .tag(intensity)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.backgroundProcessingIntensity.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Content filters are edited in Library; show what the pipeline's labels hide today.
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                Text(contentFilterSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                Spacer()
                Text("Change in Library ▸ Content Filters")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Actions
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Backfill unprocessed")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                    Text("Queue items that haven't been analyzed yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isBackfilling {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button("Backfill") {
                        Task { await backfillUnprocessed() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!PipelineQueue.isConfigured)
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reindex all items")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                    Text("Delete ML attributes, then re-run the full pipeline for every item.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isReindexing {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button("Reindex All") {
                        showReindexConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(!PipelineQueue.isConfigured || totalCount == 0)
                    .confirmationDialog(
                        "Reindex all \(totalCount) items?",
                        isPresented: $showReindexConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Reindex All", role: .destructive) {
                            Task { await reindexAll() }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("Deletes all ML attributes and re-runs analysis for the whole library. Filters and searches that use those attributes are incomplete until it finishes, which may take a long time. Media files are not touched.")
                    }
                }
            }

            if failedCount > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Retry failed items")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                        Text("\(failedCount) item\(failedCount == 1 ? "" : "s") failed. Reset and analyze again.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isRetryingFailed {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Button("Retry") {
                            Task { await retryFailed() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.accentOrange)
                        .disabled(!PipelineQueue.isConfigured)
                    }
                }
            }
        }
        .task { await loadStats() }
        .onReceive(pipelineStatusPublisher) { status in
            pipelineStatus = status
        }
    }

    private func pipelineStatusDetail(isActive: Bool, isConfigured: Bool) -> String {
        if isActive { return "\(pipelineStatus.processing) active, \(pipelineStatus.queued) queued" }
        guard isConfigured else { return "The ML pipeline isn't loaded in this session, so its actions are unavailable." }
        let remaining = max(0, totalCount - processedCount)
        return remaining == 0 ? "Every item has been analyzed." : "\(remaining.formatted()) not analyzed yet; new items are queued as they arrive."
    }

    private var contentFilterSummary: String {
        switch (settings.hideJunkItems, settings.hideSafetyFlagged) {
        case (true, true): return "Junk and safety-flagged items are hidden from the library."
        case (true, false): return "Junk items are hidden; safety-flagged items are shown."
        case (false, true): return "Safety-flagged items are hidden; junk items are shown."
        case (false, false): return "Junk and safety-flagged items are shown."
        }
    }

    private var pipelineStatusPublisher: AnyPublisher<PipelineQueueStatus, Never> {
        guard let pipelineQueue = PipelineQueue.sharedIfConfigured else {
            return Empty().eraseToAnyPublisher()
        }
        return pipelineQueue.status
    }

    private func coverageStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func loadStats() async {
        let db = DatabaseManager.shared
        processedCount = (try? await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE pipeline_status = 'complete' AND (deletedAt IS NULL OR deletedAt = '')")
        }) ?? 0
        totalCount = (try? await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE (deletedAt IS NULL OR deletedAt = '')")
        }) ?? 0
        failedCount = (try? await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE pipeline_status = 'failed' AND (deletedAt IS NULL OR deletedAt = '')")
        }) ?? 0
        attributeCount = (try? await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_attributes")
        }) ?? 0
        vectorCount = (try? await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_vectors")
        }) ?? 0
        if let pipelineQueue = PipelineQueue.sharedIfConfigured {
            pipelineStatus = pipelineQueue.currentStatus
        }
    }

    private func backfillUnprocessed() async {
        guard let pipelineQueue = PipelineQueue.sharedIfConfigured else { return }
        isBackfilling = true
        await pipelineQueue.requeueIncomplete()
        try? await Task.sleep(for: .seconds(1))
        isBackfilling = false
        await loadStats()
    }

    private func reindexAll() async {
        guard let pipelineQueue = PipelineQueue.sharedIfConfigured else { return }
        isReindexing = true
        _ = await pipelineQueue.reprocessAll()
        isReindexing = false
        await loadStats()
    }

    private func retryFailed() async {
        guard let pipelineQueue = PipelineQueue.sharedIfConfigured else { return }
        isRetryingFailed = true
        await pipelineQueue.forceRetryFailed()
        isRetryingFailed = false
        await loadStats()
    }
}

// MARK: - Canvas Content

private struct CanvasContent: View {
    let settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsToggle(
                "Snap to grid",
                description: "Align items to a grid when dragging.",
                isOn: Binding(
                    get: { settings.canvasSnapToGrid },
                    set: { settings.canvasSnapToGrid = $0 }
                )
            )

            if settings.canvasSnapToGrid {
                SettingsSlider(
                    "Grid size",
                    description: "Size of grid cells for snapping.",
                    value: Binding(
                        get: { Double(settings.canvasGridSize) },
                        set: { settings.canvasGridSize = Int($0) }
                    ),
                    in: 10...100,
                    format: "%.0fpx"
                )
            }
        }
    }
}

// MARK: - Annotation Content

private struct AnnotationContent: View {
    let settings: SettingsStore

    private var presetColors: [(name: String, value: Int, usesSystemAccent: Bool)] {
        [
            ("System", AnnotationColorDefaults.systemAccentRGBA, true),
            ("Orange", 0xFF6B35FF, false),
            ("Red", 0xFF4444FF, false),
            ("Yellow", 0xFFE66DFF, false),
            ("Green", 0x44DD44FF, false),
            ("Cyan", 0x4ECDC4FF, false),
            ("Blue", 0x4444FFFF, false),
            ("Purple", 0xAA44FFFF, false),
            ("White", 0xFFFFFFFF, false),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Stroke width
            SettingsSlider(
                "Default stroke width",
                value: Binding(
                    get: { Double(settings.annotationDefaultStrokeWidth) },
                    set: { settings.annotationDefaultStrokeWidth = Int($0) }
                ),
                in: 1...20,
                format: "%.0fpx"
            )

            Divider()
                .background(Color.white.opacity(0.08))

            // Color selection
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("Default stroke color")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                    Spacer()
                    // Live preview of width and color together.
                    Capsule()
                        .fill(colorFromInt(settings.annotationDefaultColor))
                        .frame(width: 56, height: CGFloat(settings.annotationDefaultStrokeWidth))
                        .frame(height: 20)
                        .accessibilityHidden(true)
                }

                HStack(spacing: 10) {
                    ForEach(presetColors, id: \.name) { preset in
                        Button {
                            if preset.usesSystemAccent {
                                settings.useSystemAnnotationDefaultColor()
                            } else {
                                settings.annotationDefaultColor = preset.value
                            }
                        } label: {
                            Circle()
                                .fill(colorFromInt(preset.value))
                                .frame(width: 26, height: 26)
                                .padding(3)
                                .overlay(
                                    Circle()
                                        .strokeBorder(
                                            isPresetSelected(preset) ? Color.white.opacity(0.9) : Color.clear,
                                            lineWidth: 2
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .help(preset.usesSystemAccent ? "System accent color" : preset.name)
                        .accessibilityLabel(preset.usesSystemAccent ? "System accent color" : preset.name)
                        .accessibilityAddTraits(isPresetSelected(preset) ? [.isSelected] : [])
                    }
                }
            }

        }
    }

    private func colorFromInt(_ value: Int) -> Color {
        Color(
            red: CGFloat((value >> 24) & 0xFF) / 255.0,
            green: CGFloat((value >> 16) & 0xFF) / 255.0,
            blue: CGFloat((value >> 8) & 0xFF) / 255.0,
            opacity: CGFloat(value & 0xFF) / 255.0
        )
    }

    private func isPresetSelected(_ preset: (name: String, value: Int, usesSystemAccent: Bool)) -> Bool {
        if preset.usesSystemAccent {
            return settings.annotationDefaultColorUsesSystemAccent
        }
        return !settings.annotationDefaultColorUsesSystemAccent &&
            preset.value == settings.annotationDefaultColor
    }
}
