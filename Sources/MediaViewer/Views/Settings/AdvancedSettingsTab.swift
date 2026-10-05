import SwiftUI

struct AdvancedSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @Environment(SettingsStore.self) private var settings
    @State private var showResetConfirmation = false
    @State private var resetMessage: String?

    /// What "Reset all settings" clears vs. keeps; mirrors `SettingsStore.managedKeys`
    /// and `SettingsStore.resetPreservedKeys`.
    static let resetScopeMessage = """
        Restores defaults for playback, content filters, sort and search scope, delete behavior, \
        duplicate detection, processing speed, sidebar sections, export options, image editor and \
        canvas defaults, and the hold-to-tag selector.

        Kept: library items and files, the archive location, tags with their colors and shortcuts, \
        tag rules, import tag presets, and the download server and launch-at-login state.

        This can't be undone.
        """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Search Index
                SettingsSection(
                    title: "Search Index",
                    icon: "magnifyingglass",
                    description: "Full-text search index health and rebuild controls."
                ) {
                    SearchIndexContent(appState: appState)
                }

                // Vision Processing
                SettingsSection(
                    title: "Vision Processing",
                    icon: "eye",
                    description: "Library-wide OCR and color jobs. These change stored analysis results, not settings."
                ) {
                    VisionProcessingContent(appState: appState, status: appState.backgroundStatus)
                }

                // Performance Logging
                SettingsSection(
                    title: "Performance Logging",
                    icon: "speedometer",
                    description: "Real-time console output for debugging performance."
                ) {
                    PerformanceLoggingContent()
                }

                // Debug Tools
                SettingsSection(
                    title: "Debug Tools",
                    icon: "ant",
                    description: "Developer tools for testing and diagnostics."
                ) {
                    DebugToolsContent()
                }

                // Danger Zone
                DangerZone("Danger Zone") {
                    VStack(alignment: .leading, spacing: 12) {
                        // Delete behavior is edited in one place (General) to avoid two
                        // toggles for the same preference; its current effect stays visible here.
                        HStack(spacing: 8) {
                            Image(systemName: settings.deleteFilesFromDisk ? "exclamationmark.triangle.fill" : "info.circle")
                                .foregroundStyle(settings.deleteFilesFromDisk ? .orange : .secondary)
                            Text(settings.deleteFilesFromDisk
                                 ? "Deleting items also moves their media files to Trash."
                                 : "Deleting items keeps their media files on disk.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                            Spacer()
                            Text("Change in General ▸ Deleting Items")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Divider()
                            .background(Color.red.opacity(0.3))

                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Reset all settings")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)
                                Text("Restore preference defaults. Tags, rules, import presets and library items are kept.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Reset…") {
                                showResetConfirmation = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }

                        if let resetMessage {
                            Label(resetMessage, systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .confirmationDialog(
                    "Reset all settings to their defaults?",
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset Settings", role: .destructive) {
                        resetPreferences()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text(Self.resetScopeMessage)
                }
            }
            .padding(20)
        }
        .task {
            await appState.checkFTSHealth()
        }
    }

    /// Reset clears stored preferences only. The open library holds its sort and
    /// search scope in memory, so carry the restored values over explicitly.
    private func resetPreferences() {
        settings.resetToDefaults()
        let sort = settings.lastSortOrder
        let scope = settings.defaultSearchScope
        if appState.sortOrder != sort || appState.searchScope != scope {
            appState.commitLibraryFilterChange {
                appState.sortOrder = sort
                appState.searchScope = scope
            }
        }
        resetMessage = "Preferences restored to defaults, including the library's sort and search scope. Panels that are already open may keep their current layout until reopened."
    }
}

// MARK: - Search Index Content

private struct SearchIndexContent: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Health status
            HStack(spacing: 12) {
                if let health = appState.ftsHealth {
                    let isHealthy = health.indexed == health.expected
                    HStack(spacing: 6) {
                        Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(isHealthy ? .green : .orange)
                        Text(isHealthy ? "Index Healthy" : "Index Out of Sync")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(isHealthy ? .green : .orange)
                    }

                    Spacer()

                    Text("\(health.indexed) / \(health.expected)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Checking…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Button {
                    Task { await appState.checkFTSHealth() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh health status")
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Rebuild action
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rebuild search index")
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                    Text("Drops and recreates the FTS index from all media items.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if appState.isRebuildingFTS {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button("Rebuild") {
                        Task { await appState.rebuildFTSIndex() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentOrange)
                }
            }
        }
    }
}

// MARK: - Vision Processing Content

/// Library-wide jobs that clear stored analysis before re-running it.
private enum VisionBulkAction: String, Identifiable {
    case colors, ocr, pipeline

    var id: String { rawValue }

    var confirmationTitle: String {
        switch self {
        case .colors: return "Re-index colors for every item?"
        case .ocr: return "Reprocess OCR for every item?"
        case .pipeline: return "Reprocess the image pipeline for every item?"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .colors:
            return "Clears the saved dominant colors on every item and analyzes them again in the background. Media files are not touched. On a large library this can take a long time."
        case .ocr:
            return "Clears recognized text and text boxes on every item and runs OCR again in the background. Searching by recognized text may miss items until they are reprocessed. Media files are not touched."
        case .pipeline:
            return "Deletes all ML attributes (scene, objects, quality, safety, junk, captions…) and re-runs the full pipeline in the background. Filters and searches that use those attributes are incomplete until it finishes. Same as Processing ▸ Reindex All."
        }
    }

    var confirmLabel: String {
        switch self {
        case .colors: return "Re-index Colors"
        case .ocr: return "Reprocess OCR"
        case .pipeline: return "Reprocess Pipeline"
        }
    }

    var startedMessage: String {
        switch self {
        case .colors: return "Color re-index requested. Progress appears in the status above."
        case .ocr: return "OCR reprocess requested. Progress appears in the status above."
        case .pipeline: return "Pipeline reprocess requested. Progress appears in Processing ▸ ML Pipeline."
        }
    }
}

private struct VisionProcessingContent: View {
    let appState: AppState
    @ObservedObject var status: BackgroundProcessingStatus
    @State private var pendingAction: VisionBulkAction?
    @State private var startedMessage: String?

    private var isProcessing: Bool {
        status.processingCount > 0 || status.queuedCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    // Idle means no OCR/color job is running, not that every item was analyzed;
                    // coverage lives in Processing ▸ ML Pipeline.
                    Image(systemName: isProcessing ? "info.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isProcessing ? .blue : .green)
                    Text(isProcessing ? "Processing \(status.processingCount), \(status.queuedCount) queued" : "No OCR or color jobs running")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isProcessing ? .blue : .green)
                }
                Spacer()
                Text("OCR and color extraction")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if isProcessing {
                Label("These jobs are available once current processing finishes.", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let startedMessage {
                Label(startedMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .background(Color.white.opacity(0.08))

            actionRow(
                "Re-index colors",
                description: "Clear and re-analyze colors for all items with the current palette.",
                button: "Re-index…"
            ) { pendingAction = .colors }

            actionRow(
                "Reprocess all OCR",
                description: "Clear and re-run OCR for all items.",
                button: "Reprocess…"
            ) { pendingAction = .ocr }

            actionRow(
                "Reprocess image pipeline",
                description: "Delete ML attributes and re-run the full pipeline for all items.",
                button: "Reprocess…"
            ) { pendingAction = .pipeline }

            // Non-destructive: only queues work that never finished.
            actionRow(
                "Resume incomplete items",
                description: "Queue items whose OCR or color analysis never finished. Existing results are kept.",
                button: "Queue"
            ) {
                appState.rebuildSearchIndex()
                startedMessage = "Incomplete items queued. Progress appears in the status above."
            }
        }
        .confirmationDialog(
            pendingAction?.confirmationTitle ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button(action.confirmLabel, role: .destructive) {
                run(action)
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { action in
            Text(action.confirmationMessage)
        }
    }

    private func actionRow(
        _ title: String,
        description: String,
        button: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action)
                .buttonStyle(.bordered)
                .disabled(isProcessing)
        }
    }

    private func run(_ action: VisionBulkAction) {
        switch action {
        case .colors: appState.reindexAllColors()
        case .ocr: appState.reprocessAllOCR()
        case .pipeline: appState.reprocessAllPipeline()
        }
        startedMessage = action.startedMessage
        pendingAction = nil
    }
}

// MARK: - Performance Logging Content

private struct PerformanceLoggingContent: View {
    /// PerfLog persists to UserDefaults without publishing changes; mirror it here so
    /// the picker, category list and checkboxes redraw when they change.
    @State private var level = PerfLog.level
    @State private var categoryRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Level picker
            HStack {
                Text("Level")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                Spacer()
                Picker("", selection: Binding(
                    get: { level },
                    set: { PerfLog.level = $0; level = $0 }
                )) {
                    ForEach(PerfLog.Level.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if level != .off {
                Divider()
                    .background(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Categories")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16)
                    ], spacing: 8) {
                        ForEach(PerfLog.Category.allCases, id: \.self) { category in
                            Toggle(isOn: Binding(
                                get: { _ = categoryRevision; return category.isEnabled },
                                set: { category.isEnabled = $0; categoryRevision += 1 }
                            )) {
                                HStack {
                                    Text(category.displayName)
                                        .font(.system(size: 12))
                                    Text("(\(Int(category.threshold))ms)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Debug Tools Content

private struct DebugToolsContent: View {
    @State private var showColorAlgorithmDebug = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Color algorithm comparison
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.purple)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Color extraction algorithms")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)

                    Text("Compare different color extraction algorithms side-by-side with timing information.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Button("Open Color Debug") {
                        showColorAlgorithmDebug = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentOrange)
                    .controlSize(.small)
                }
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Algorithm descriptions
            VStack(alignment: .leading, spacing: 8) {
                Text("Available algorithms")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                algorithmRow(
                    name: "Grid Sampling (Current)",
                    description: "Samples pixels in a grid pattern and classifies into HSV buckets.",
                    icon: "square.grid.3x3.fill"
                )

                algorithmRow(
                    name: "K-Means Clustering",
                    description: "Groups pixels into k=5 clusters using iterative refinement.",
                    icon: "circle.hexagongrid.fill"
                )

                algorithmRow(
                    name: "Saturation Weighted",
                    description: "Weights pixels by saturation for more vibrant results.",
                    icon: "slider.horizontal.3"
                )

                algorithmRow(
                    name: "Multi-Shade Buckets",
                    description: "Splits hue buckets into light/medium/dark variants.",
                    icon: "square.stack.3d.up.fill"
                )
            }
        }
        .sheet(isPresented: $showColorAlgorithmDebug) {
            ColorAlgorithmDebugView()
                .frame(minWidth: 700, minHeight: 600)
        }
    }

    private func algorithmRow(name: String, description: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}
