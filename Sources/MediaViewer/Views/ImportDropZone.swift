import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ImportRecoveryStatus: ObservableObject {
    static let shared = ImportRecoveryStatus()
    @Published var result: ImportResult?
}

// MARK: - Import Drop Zone Modifier

/// ViewModifier that adds drag-drop import capability to any view.
/// When files are dropped from Finder, they are imported into the archive.
struct ImportDropZone: ViewModifier {
    @EnvironmentObject var appState: AppState
    @State private var isTargeted = false
    @State private var importTask: Task<Void, Never>?
    @State private var importStatus: ImportStatus = .idle
    @State private var showingTagPresetSheet = false
    @State private var pendingImportURLs: [URL] = []
    @State private var pendingScopes: [ImportSecurityScope] = []
    @State private var pendingDropErrors: [ImportError] = []
    @State private var importGeneration = UUID()
    @State private var importProgress: ImportProgress?
    @State private var isCancelling = false
    @ObservedObject private var recoveryStatus = ImportRecoveryStatus.shared

    func body(content: Content) -> some View {
        content
            // NOTE: Use onDrop instead of dropDestination to avoid intercepting
            // internal app drag operations. dropDestination can block internal
            // draggable/onDrag gestures from starting.
            .onDrop(of: [.fileURL], isTargeted: Binding(
                get: { isTargeted },
                set: { newValue in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isTargeted = newValue
                    }
                }
            )) { providers in
                // Only handle external file drops, not internal app drags.
                // Internal drags include the app-specific drag type identifier.
                let fileProviders = MediaDropClassification.externalFileProviders(in: providers)
                guard !fileProviders.isEmpty else { return false }

                ImportDropDecoder.load(fileProviders, archivePath: getArchivePath()) { handleDrop(batch: $0) }
                return true
            }
            .overlay {
                if isTargeted {
                    DropTargetOverlay()
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .overlay(alignment: .bottom) {
                if case .importing(let count) = importStatus {
                    ImportProgressBanner(count: count, progress: importProgress, isCancelling: isCancelling, onCancel: { isCancelling = true; importTask?.cancel() })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if case .complete(let result) = importStatus {
                    ImportCompleteBanner(result: result, onRetry: retry, onDismiss: dismissResult)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if case .idle = importStatus, let result = recoveryStatus.result, !result.errors.isEmpty {
                    ImportCompleteBanner(result: result, onRetry: retry, onDismiss: dismissResult)
                }
            }
            .sheet(isPresented: $showingTagPresetSheet, onDismiss: {
                pendingImportURLs = []
                pendingScopes = []
                pendingDropErrors = []
            }) {
                ImportTagPresetSheet(
                    fileCount: pendingImportURLs.count,
                    onImport: { tags, options in
                        showingTagPresetSheet = false
                        let scopes = pendingScopes
                        let errors = pendingDropErrors
                        pendingImportURLs = []
                        pendingScopes = []
                        pendingDropErrors = []
                        startImport(scopes: scopes, tags: tags, options: options, dropErrors: errors)
                    },
                    onCancel: {
                        showingTagPresetSheet = false
                        pendingImportURLs = []
                        pendingScopes = []
                        pendingDropErrors = []
                    }
                )
            }
    }

    private func handleDrop(batch: ImportDropBatch) {
        // Cancel any existing import
        importTask?.cancel()

        let validScopes = batch.scopes
        let fileURLs = validScopes.map(\.url)

        guard !fileURLs.isEmpty else {
            startImport(scopes: [], tags: [], options: .default, dropErrors: batch.errors)
            return
        }

        logInfo("ImportDropZone: Received drop of \(fileURLs.count) files")

        // The explicit copy policy must also be reachable for a one-file drop.
        pendingImportURLs = fileURLs
        pendingScopes = validScopes
        pendingDropErrors = batch.errors
        showingTagPresetSheet = true
    }

    @MainActor
    private func startImport(scopes: [ImportSecurityScope], tags: [String], options: ImportOptions, dropErrors: [ImportError] = []) {
        let previousTask = importTask
        previousTask?.cancel()
        let generation = UUID()
        importGeneration = generation
        isCancelling = false
        importTask = Task {
            // Cancellation retracts only our journaled publications. Let that
            // settle before a replacement attempt resumes the same operation.
            await previousTask?.value
            guard !Task.isCancelled, importGeneration == generation else { return }
            await performImport(scopes: scopes, tags: tags, options: options, generation: generation, dropErrors: dropErrors)
        }
    }

    @MainActor
    private func retry(_ urls: [URL]) {
        // Provider failures have no durable operation yet; do not hide them when
        // retrying an unrelated file that does have a usable source URL.
        let retained = recoveryStatus.result?.errors.filter { error in
            error.operationID == nil && !urls.contains(where: { $0 == error.sourceURL })
        } ?? []
        startImport(scopes: urls.map(ImportSecurityScope.init), tags: [], options: .default, dropErrors: retained)
    }

    @MainActor
    private func dismissResult() {
        importStatus = .idle
        recoveryStatus.result = nil
    }

    @MainActor
    private func performImport(
        scopes: [ImportSecurityScope],
        tags: [String] = [],
        options: ImportOptions = .default,
        generation: UUID,
        dropErrors: [ImportError]
    ) async {
        defer { withExtendedLifetime(scopes) {} }
        let urls = scopes.map(\.url)
        if urls.isEmpty {
            let result = ImportResult(importedCount: 0, skippedCount: 0, failedCount: dropErrors.count, createdItemIds: [], errors: dropErrors)
            importStatus = .complete(result: result)
            recoveryStatus.result = result
            return
        }
        guard let mediaStore = appState.mediaStore else {
            let errors = dropErrors + urls.map { ImportError(filename: $0.lastPathComponent, reason: "The library is not ready. Wait for it to open, then retry.", sourceURL: $0) }
            let result = ImportResult(importedCount: 0, skippedCount: 0, failedCount: errors.count, createdItemIds: [], errors: errors)
            importStatus = .complete(result: result)
            recoveryStatus.result = result
            return
        }

        // Get archive path from UserDefaults or default
        let archivePath = getArchivePath()

        // Show importing status
        withAnimation {
            importStatus = .importing(count: urls.count)
            importProgress = nil
        }

        // Create import service
        let visionQueue = VisionJobQueue.sharedIfConfigured
        if visionQueue == nil {
            logWarning("ImportDropZone: Vision queue not configured, import will skip background vision enqueue")
        }
        let videoUnderstandingQueue = VideoUnderstandingQueue.sharedIfConfigured
        let transcriptionQueue = TranscriptionQueue.sharedIfConfigured

        let importService = ImportService(
            mediaStore: mediaStore,
            visionQueue: visionQueue,
            videoUnderstandingQueue: videoUnderstandingQueue,
            transcriptionQueue: transcriptionQueue,
            archivePath: archivePath
        )

        do {
            var result = try await importService.importFiles(urls, tags: tags, options: options.forFileDrop) { progress in
                await MainActor.run {
                    if importGeneration == generation { importProgress = progress }
                }
            }
            result = ImportDropBatch.adding(errors: dropErrors, to: result)
            // Retrying one file must not hide other durable failures.
            let pendingErrors = await importService.unresolvedImportErrors()
            let currentKeys = Set(result.errors.flatMap { [$0.operationID?.uuidString, $0.sourceURL?.path].compactMap { $0 } })
            let additional = pendingErrors.filter { pending in
                let keys = [pending.operationID?.uuidString, pending.sourceURL?.path].compactMap { $0 }
                return keys.isEmpty ? !result.errors.contains(where: { $0.filename == pending.filename && $0.reason == pending.reason }) : keys.allSatisfy { !currentKeys.contains($0) }
            }
            if !additional.isEmpty {
                result = ImportResult(importedCount: result.importedCount, skippedCount: result.skippedCount, failedCount: result.failedCount + additional.count, createdItemIds: result.createdItemIds, errors: result.errors + additional, cancelledCount: result.cancelledCount, skippedItems: result.skippedItems)
            }

            if SettingsStore.shared.autoScanOnImport, !result.createdItemIds.isEmpty,
               let detector = appState.duplicateDetector {
                let createdIDs = result.createdItemIds
                Task(priority: .utility) {
                    do {
                        let groups = try await detector.detectDuplicatesForItems(createdIDs)
                        logInfo("ImportDropZone: Auto-scan found \(groups) duplicate group(s)")
                    } catch {
                        logError("ImportDropZone: Auto-scan failed - \(error.localizedDescription)")
                    }
                }
            }

            // Log result
            logInfo("ImportDropZone: Import complete - \(result.summary)")

            // Show completion briefly
            guard importGeneration == generation else { return }
            withAnimation {
                importStatus = .complete(result: result)
                recoveryStatus.result = result.errors.isEmpty ? nil : result
            }

            // Failures/cancellation remain inspectable until retried or dismissed.
            if result.errors.isEmpty {
                try? await Task.sleep(for: .seconds(result.skippedItems.isEmpty ? 3 : 8))
                if importGeneration == generation { withAnimation { importStatus = .idle } }
            }
        } catch {
            logError("ImportDropZone: Import failed - \(error.localizedDescription)")
            guard importGeneration == generation else { return }
            let errors = dropErrors + urls.map { ImportError(filename: $0.lastPathComponent, reason: error.localizedDescription, sourceURL: $0) }
            let result = ImportResult(importedCount: 0, skippedCount: 0, failedCount: errors.count, createdItemIds: [], errors: errors)
            importStatus = .complete(result: result)
            recoveryStatus.result = result
        }
    }

    /// Get the archive path from UserDefaults or use default.
    private func getArchivePath() -> URL {
        ArchivePathStore.currentPath()
    }
}

// MARK: - Import Status

private enum ImportStatus: Equatable {
    case idle
    case importing(count: Int)
    case complete(result: ImportResult)

    static func == (lhs: ImportStatus, rhs: ImportStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.importing(let a), .importing(let b)):
            return a == b
        case (.complete(let a), .complete(let b)):
            return a.importedCount == b.importedCount &&
                   a.skippedCount == b.skippedCount &&
                   a.failedCount == b.failedCount
        default:
            return false
        }
    }
}

// MARK: - Design Constants

private enum ImportTheme {
    static let overlayBackground = Color.black.opacity(0.75)
    static let cardBackground = Color(hex: 0x1e1e1e)
    static let cardBorder = Color.white.opacity(0.08)
    static let accentGradient = LinearGradient(
        colors: [Color.accentOrange, Color.accentOrange.opacity(0.8)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let successColor = Color(hex: 0x34C759)
    static let warningColor = Color(hex: 0xFF9500)
}

// MARK: - Drop Target Overlay

/// Visual feedback overlay shown when files are dragged over the drop zone.
struct DropTargetOverlay: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Frosted glass background
            ImportTheme.overlayBackground
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            // Animated border glow
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(
                    ImportTheme.accentGradient,
                    style: StrokeStyle(lineWidth: 3, dash: [12, 8])
                )
                .padding(32)
                .opacity(isPulsing ? 0.6 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)

            // Center content
            VStack(spacing: 20) {
                // Animated icon
                ZStack {
                    Circle()
                        .fill(Color.accentOrange.opacity(0.15))
                        .frame(width: 100, height: 100)
                        .scaleEffect(isPulsing ? 1.1 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)

                    Circle()
                        .fill(Color.accentOrange.opacity(0.1))
                        .frame(width: 80, height: 80)

                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(Color.accentOrange)
                        .offset(y: isPulsing ? -2 : 2)
                        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: isPulsing)
                }

                VStack(spacing: 8) {
                    Text("Drop to Import")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("Images, videos, and supported media files")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(48)
            .background {
                RoundedRectangle(cornerRadius: 20)
                    .fill(ImportTheme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(Color.accentOrange.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: Color.accentOrange.opacity(0.2), radius: 30, x: 0, y: 10)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drop zone active. Release to import files.")
        .onAppear {
            isPulsing = true
        }
    }
}

// MARK: - Import Progress Banner

/// Banner shown at bottom of screen during import.
struct ImportProgressBanner: View {
    let count: Int
    var progress: ImportProgress? = nil
    var isCancelling = false
    var onCancel: () -> Void = {}
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 14) {
            // Animated spinner
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 2)
                    .frame(width: 22, height: 22)

                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 22, height: 22)
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: isAnimating)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(isCancelling ? "Cancelling import…" : "Importing \(count) file\(count == 1 ? "" : "s")")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                Text(progress.map { "\($0.completed) of \($0.total) · \($0.filename)" } ?? "Preparing files…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(isCancelling ? 0.5 : 0.95))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.18), in: Capsule())
                .disabled(isCancelling)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.accentOrange, Color.accentOrange.opacity(0.85)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .shadow(color: Color.accentOrange.opacity(0.4), radius: 12, x: 0, y: 6)
        }
        .frame(maxWidth: 320)
        .padding(.bottom, 60)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Importing \(count) file\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Import Complete Banner

/// Banner shown after import completes.
struct ImportCompleteBanner: View {
    let result: ImportResult
    var onRetry: ([URL]) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 14) {
            // Success/warning icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 32, height: 32)

                Image(systemName: statusIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)

                Text(statusSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss import result")
          }
          if !result.skippedItems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(result.skippedItems.prefix(3).enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text("Already in library: \(item.existingName)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([item.existingURL]) }
                            .controlSize(.small)
                    }
                }
                if result.skippedItems.count > 3 {
                    Text("And \(result.skippedItems.count - 3) more already in the library")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 46)
          }
          if !result.errors.isEmpty {
            // A short list sizes to its rows; only a long one scrolls.
            if result.errors.count <= 3 {
                errorList
            } else {
                ScrollView { errorList }.frame(maxHeight: 160)
            }
          }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(ImportTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(statusColor.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
        }
        .frame(maxWidth: 460)
        .padding(.bottom, 60)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statusTitle). \(result.summary).")
    }

    private var errorList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(result.errors.enumerated()), id: \.offset) { _, error in
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.filename).font(.caption.bold()).foregroundStyle(.white)
                    Text(error.reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack(spacing: 6) {
                        if let source = error.sourceURL { Button("Retry") { onRetry([source]) } }
                        if let target = error.operationID.map({ ArchivePathStore.currentPath().appendingPathComponent(".nodraw-imports/\($0.uuidString)") }) ?? error.sourceURL {
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([target]) }
                        }
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 46)
    }

    /// Everything was skipped: nothing new was added, which is not a green "complete".
    private var nothingNew: Bool {
        result.importedCount == 0 && result.failedCount == 0 && result.cancelledCount == 0 && result.skippedCount > 0
    }

    private var statusIcon: String {
        if nothingNew { return "equal.circle.fill" }
        if !result.errors.isEmpty {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if nothingNew { return .secondary }
        if !result.errors.isEmpty {
            return ImportTheme.warningColor
        }
        return ImportTheme.successColor
    }

    private var statusTitle: String {
        if result.cancelledCount > 0 { return "Import cancelled" }
        if nothingNew { return "Nothing new to import" }
        if result.failedCount > 0 {
            return "Import completed with issues"
        }
        return "Import complete"
    }

    private var statusSubtitle: String {
        if nothingNew {
            let n = result.skippedCount
            return "\(n) file\(n == 1 ? "" : "s") skipped: already imported or not a supported media type"
        }
        return result.summary
    }
}

// MARK: - View Extension

extension View {
    /// Add drag-drop import capability to this view.
    func importDropZone() -> some View {
        modifier(ImportDropZone())
    }
}
