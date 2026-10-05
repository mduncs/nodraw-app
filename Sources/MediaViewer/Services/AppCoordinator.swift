import Foundation
import AppKit
import Combine
import AVFoundation
import GRDB

// MARK: - Archive Health Status

/// Status of the archive folder
enum ArchiveStatus: Equatable, Sendable {
    case unknown        // Not yet checked
    case notConfigured  // No path saved
    case missing        // Path doesn't exist
    case invalid        // Path exists but is not a directory
    case noAccess       // No read permission
    case readOnly       // Can read but not write
    case empty          // Valid folder but no archive content
    case healthy        // Everything looks good

    var isUsable: Bool {
        switch self {
        case .healthy, .empty, .readOnly:
            return true
        default:
            return false
        }
    }

    var description: String {
        switch self {
        case .unknown:
            return "Checking archive..."
        case .notConfigured:
            return "Archive folder not configured"
        case .missing:
            return "Archive folder not found"
        case .invalid:
            return "Invalid archive location"
        case .noAccess:
            return "Cannot access archive folder"
        case .readOnly:
            return "Archive is read-only"
        case .empty:
            return "Archive folder is empty"
        case .healthy:
            return "Archive ready"
        }
    }
}

// MARK: - App Initialization State

/// Observable state during app initialization
enum InitializationPhase: Equatable, Sendable {
    case notStarted
    case initializingDatabase
    case runningMigrations
    case startingWatcher
    case scanningArchive(progress: Double)
    case parsingMetadata(current: Int, total: Int)
    case preparingArchive
    case generatingSidecars(current: Int, total: Int)
    case insertingItems(total: Int)
    case updatingChangedItems(current: Int, total: Int)
    case reconcilingArchive
    case processingItems(current: Int, total: Int)
    case ready
    case failed(String)

    var displayText: String {
        switch self {
        case .notStarted:
            return "Starting..."
        case .initializingDatabase:
            return "Initializing database..."
        case .runningMigrations:
            return "Running migrations..."
        case .startingWatcher:
            return "Starting file watcher..."
        case .scanningArchive(let progress):
            return "Scanning archive... \(Int(progress * 100))%"
        case .parsingMetadata(let current, let total):
            return "Reading metadata… \(current)/\(total)"
        case .preparingArchive:
            return "Preparing archive updates…"
        case .generatingSidecars(let current, let total):
            return "Creating metadata… \(current)/\(total)"
        case .insertingItems(let total):
            return "Adding \(total) new items…"
        case .updatingChangedItems(let current, let total):
            return "Updating \(total) changed items… \(current)/\(total)"
        case .reconcilingArchive:
            return "Reconciling archive…"
        case .processingItems(let current, let total):
            return "Processing items... \(current)/\(total)"
        case .ready:
            return "Ready"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    var progressFraction: Double? {
        switch self {
        case .scanningArchive(let progress):
            return progress
        case .parsingMetadata(let current, let total),
             .generatingSidecars(let current, let total),
             .updatingChangedItems(let current, let total):
            return total > 0 ? Double(current) / Double(total) : nil
        default:
            return nil
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - App Coordinator

/// Actor that orchestrates app startup and coordinates services.
/// Initializes database, starts file watcher, performs initial scan,
/// and feeds discovered items to the Vision processing queue.
actor AppCoordinator {
    // MARK: - Configuration

    // MARK: - Services

    private let database: DatabaseManager
    private var archiveWatcher: ArchiveWatcher?
    private let visionQueue: VisionJobQueue
    private let pipelineQueue: PipelineQueue
    private let videoUnderstandingQueue: VideoUnderstandingQueue
    private let transcriptionQueue: TranscriptionQueue
    private let mediaStore: MediaStore

    /// Reused for base-name normalization (`foo-1` -> `foo`).
    private nonisolated static let trailingSingleIndexSuffixRegex = try? NSRegularExpression(pattern: #"^(.+)[-_][1-9]$"#)
    /// Reused to extract Twitter/X status IDs from source URLs.
    private nonisolated static let twitterStatusIDRegex = try? NSRegularExpression(pattern: #"/status/([0-9]+)"#)

    private enum StartupMaintenanceFlag: String {
        case contextOnlyAspectRatios = "context-only-aspect-ratios.v1"
        case videoAspectRatios = "video-aspect-ratios.v1"
        case imageExifOrientationRatios = "image-exif-orientation-ratios.v1"
        case metadataMediaAssociations = "metadata-media-associations.v1"
    }

    // MARK: - State

    private var archivePath: URL
    private var isInitialized = false
    private var watcherTask: Task<Void, Never>?
    private var deferredStartupScanVerifications: [ScannedArchiveEntry] = []
    private var postLaunchMaintenanceTask: Task<Void, Never>?

    /// Archive health status
    private var _archiveStatus: ArchiveStatus = .unknown

    /// Folder existence watcher
    private var folderWatcher: FolderExistenceWatcher?

    /// Published state for UI observation
    @MainActor
    private let phaseSubject = CurrentValueSubject<InitializationPhase, Never>(.notStarted)

    /// Observable initialization phase
    @MainActor
    var phase: AnyPublisher<InitializationPhase, Never> {
        phaseSubject.eraseToAnyPublisher()
    }

    /// Current phase value
    @MainActor
    var currentPhase: InitializationPhase {
        phaseSubject.value
    }

    // MARK: - Initialization

    init(
        database: DatabaseManager = .shared,
        archivePath: URL? = nil,
        transcriber: ParakeetTranscriptionService? = nil
    ) {
        self.database = database
        self.archivePath = archivePath ?? ArchivePathStore.reconciledPath()
        self.visionQueue = VisionJobQueue(database: database)
        self.pipelineQueue = PipelineQueue(database: database)
        self.videoUnderstandingQueue = VideoUnderstandingQueue(database: database)
        self.transcriptionQueue = TranscriptionQueue(database: database, transcriber: transcriber ?? ParakeetTranscriptionService())

        // Shared tracker so MediaStore's write-back can tell the watcher to skip
        let selfWriteTracker = SelfWriteTracker()
        self.mediaStore = MediaStore(database: database, selfWriteTracker: selfWriteTracker)

        // Set shared instances for global access
        VisionJobQueue.setShared(self.visionQueue)
        PipelineQueue.setShared(self.pipelineQueue)
        VideoUnderstandingQueue.setShared(self.videoUnderstandingQueue)
        TranscriptionQueue.setShared(self.transcriptionQueue)
        ClusteringEngine.setShared(ClusteringEngine(database: database))
    }

    // MARK: - Public API

    /// Get the media store for data access
    func getMediaStore() -> MediaStore {
        mediaStore
    }

    /// Get the vision queue for status observation
    func getVisionQueue() -> VisionJobQueue {
        visionQueue
    }

    /// Get the ML pipeline queue for status observation
    func getPipelineQueue() -> PipelineQueue {
        pipelineQueue
    }

    /// Get the native video understanding queue for status observation
    func getVideoUnderstandingQueue() -> VideoUnderstandingQueue {
        videoUnderstandingQueue
    }

    /// Get the local speech transcription queue for status observation
    func getTranscriptionQueue() -> TranscriptionQueue {
        transcriptionQueue
    }

    /// Initialize all app services
    /// Call this once at app launch
    func initialize() async {
        guard !isInitialized else { return }
        let started = StartupMetrics.begin()
        defer { StartupMetrics.end("coordinator_initialize", since: started, once: true) }

        logInfo("Starting initialization...")
        logInfo("Archive path: \(archivePath.path)")

        do {
            // Phase 0: Verify archive folder health
            logDebug("Verifying archive folder...")
            _archiveStatus = await verifyArchiveFolder(at: archivePath)

            if !_archiveStatus.isUsable {
                logWarning("Archive not usable: \(_archiveStatus)")
                let onboardingCompleted = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

                if onboardingCompleted {
                    await showConfigurationIfNeeded()

                    _archiveStatus = await verifyArchiveFolder(at: archivePath)
                    if !_archiveStatus.isUsable {
                        logError("Archive still not usable after config dialog")
                        await updatePhase(.failed("Archive folder not configured or inaccessible"))
                        return
                    }
                } else {
                    await updatePhase(.failed("Archive folder not configured"))
                    return
                }
            }
            logInfo("Archive status: \(_archiveStatus)")

            startFolderMonitoring()

            // Phase 1: Initialize database
            logInfo("Phase 1: Initializing database...")
            await updatePhase(.initializingDatabase)
            try await database.initialize()
            logInfo("Database initialized")

            // Phase 2: Migrations
            await updatePhase(.runningMigrations)
            logDebug("Migrations complete")

            // Phase 2b: Load tag rules and wire into media store
            await MainActor.run { mediaStore.tagRuleEngine = TagRuleEngine.shared }
            try await TagRuleEngine.shared.loadRules()
            logDebug("Tag rules loaded: \(await TagRuleEngine.shared.rules.count) rules")

            // Settle owned import publications before orphan-sidecar generation
            // or watcher indexing can assign competing identities.
            let importRecovery = await ImportService(mediaStore: mediaStore, visionQueue: nil, archivePath: archivePath).recoverInterruptedImports()
            await MainActor.run {
                ImportRecoveryStatus.shared.result = importRecovery.errors.isEmpty ? nil : importRecovery
            }

            // Phase 3: Create watcher (but don't start FSEvents yet — sidecar generation would trigger races)
            archiveWatcher = ArchiveWatcher(archivePath: archivePath)

            // Phase 4: Perform initial scan (includes sidecar generation for orphaned media)
            logInfo("Phase 4: Scanning archive...")
            await updatePhase(.scanningArchive(progress: 0))
            let scanStarted = StartupMetrics.begin()
            let scannedItems = try await performInitialScan()
            StartupMetrics.end("archive_scan", since: scanStarted, once: true, count: scannedItems.count)
            logInfo("Scan complete: \(scannedItems.count) items found")

            // Phase 4b: NOW start file watcher (after sidecars are written and batch-inserted)
            logInfo("Starting file watcher...")
            await updatePhase(.startingWatcher)
            try await archiveWatcher?.start()
            startWatcherEventLoop()
            logInfo("File watcher started")

            // Phase 5: Reconcile DB against filesystem (regenerate sidecars or remove stale entries)
            await updatePhase(.reconcilingArchive)
            let reconciliation = try await mediaStore.reconcileOrphans()
            if reconciliation.skipped {
                logDebug("Reconciliation: skipped (recent signature cache hit)")
            } else {
                if reconciliation.regeneratedCount > 0 {
                    logInfo("Reconciliation: regenerated \(reconciliation.regeneratedCount) sidecars (media files still on disk)")
                }
                if reconciliation.softDeletedCount > 0 {
                    logInfo("Reconciliation: soft-deleted \(reconciliation.softDeletedCount) orphaned items (no files on disk)")
                }
            }

            await reconcileTagDefinitions()

            // Keep association repair in the foreground because mismatches can detach media from notes.
            await runStartupMaintenanceOnce(.metadataMediaAssociations) {
                await fixMetadataMediaAssociations()
            }

            startPostLaunchMaintenance()

            // Ready
            await updatePhase(.ready)
            isInitialized = true
            startDeferredStartupScanVerificationIfNeeded()
            logInfo("Initialization complete!")

        } catch {
            logError("Initialization failed: \(error.localizedDescription)")
            await updatePhase(.failed(error.localizedDescription))
        }
    }

    /// Shutdown all services gracefully
    func shutdown() async {
        // Flush pending vault writes before stopping services
        await mediaStore.writeBackQueue.flushNow()

        watcherTask?.cancel()
        watcherTask = nil
        postLaunchMaintenanceTask?.cancel()
        postLaunchMaintenanceTask = nil
        await archiveWatcher?.stop()
        archiveWatcher = nil

        // Note: download server NOT stopped on app quit — launchd owns the lifecycle.
        // Server continues running in the background via its launchd plist.
    }

    /// Update archive path (requires restart of watcher)
    func setArchivePath(_ path: URL) async throws {
        guard !BackgroundQAConfiguration.isEnabled else {
            throw BackgroundQAConfiguration.ConfigurationError.archiveChangeSuppressed
        }
        let normalizedPath = path.standardizedFileURL
        archivePath = normalizedPath
        ArchivePathStore.setCurrentPath(normalizedPath)

        // Verify the new path
        _archiveStatus = await verifyArchiveFolder(at: normalizedPath)

        // Restart watcher if already running
        if archiveWatcher != nil {
            await archiveWatcher?.stop()
            archiveWatcher = ArchiveWatcher(archivePath: normalizedPath)
            try await archiveWatcher?.start()
            startWatcherEventLoop()
        }

        // Start folder monitoring
        startFolderMonitoring()
    }

    /// Get current archive status
    func getArchiveStatus() -> ArchiveStatus {
        _archiveStatus
    }

    // MARK: - Archive Health Check

    /// Verify the archive folder exists and is accessible
    private func verifyArchiveFolder(at path: URL) async -> ArchiveStatus {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        if !fm.fileExists(atPath: path.path, isDirectory: &isDir) {
            return .missing
        }

        if !isDir.boolValue {
            return .invalid
        }

        // Check read access
        if !fm.isReadableFile(atPath: path.path) {
            return .noAccess
        }

        // Check write access (optional, for saving metadata)
        let isWritable = fm.isWritableFile(atPath: path.path)

        // Check for expected structure (year-month folders)
        let hasValidStructure = await checkArchiveStructure(at: path)

        if hasValidStructure {
            return isWritable ? .healthy : .readOnly
        } else {
            return .empty
        }
    }

    /// Check if the archive has expected folder structure
    private func checkArchiveStructure(at url: URL) async -> Bool {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            // Look for year-month folders (2025-12 format)
            let yearMonthRegex = try? NSRegularExpression(pattern: "^\\d{4}-\\d{2}$")
            return contents.contains { url in
                let name = url.lastPathComponent
                let range = NSRange(name.startIndex..., in: name)
                return yearMonthRegex?.firstMatch(in: name, range: range) != nil
            }
        } catch {
            return false
        }
    }

    /// Start monitoring the archive folder for deletion
    private func startFolderMonitoring() {
        folderWatcher?.stop()
        folderWatcher = nil

        folderWatcher = FolderExistenceWatcher(path: archivePath) { [weak self] exists in
            Task {
                guard let self = self else { return }
                if exists {
                    let status = await self.verifyArchiveFolder(at: self.archivePath)
                    await self.updateArchiveStatus(status)
                } else {
                    await self.updateArchiveStatus(.missing)
                    await self.showArchiveMissingAlert()
                }
            }
        }
        folderWatcher?.start()
    }

    private func updateArchiveStatus(_ status: ArchiveStatus) {
        _archiveStatus = status
    }

    /// Show alert when archive folder goes missing
    private func showArchiveMissingAlert() async {
        guard !BackgroundQAConfiguration.isEnabled else {
            logError("Isolated preview archive is missing; archive switching and modal recovery are disabled")
            await updatePhase(.failed("Preview archive is unavailable. Quit and reopen the preview to restore its sample folder."))
            return
        }
        let pathCopy = archivePath
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Archive Folder Not Found"
            alert.informativeText = "The media archive folder could not be found at:\n\(pathCopy.path)\n\nWould you like to select a new location?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Select Folder")
            alert.addButton(withTitle: "Ignore")

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                Task {
                    await self.showFolderPicker()
                }
            }
        }
    }

    /// Show folder picker to select archive location
    func showFolderPicker() async {
        guard !BackgroundQAConfiguration.isEnabled else {
            logWarning("Isolated preview archive cannot be changed")
            return
        }
        let parentDir = archivePath.deletingLastPathComponent()
        let selectedURL = await MainActor.run { () -> URL? in
            let panel = NSOpenPanel()
            panel.title = "Select Media Archive Folder"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.directoryURL = parentDir

            let response = panel.runModal()
            return response == .OK ? panel.url : nil
        }

        if let url = selectedURL {
            try? await self.setArchivePath(url)
        }
    }

    /// Show configuration dialog if archive is not properly set up
    func showConfigurationIfNeeded() async {
        switch _archiveStatus {
        case .notConfigured, .missing, .invalid, .noAccess:
            await showFolderPicker()
        default:
            break
        }
    }

    // MARK: - Private Methods

    private func updatePhase(_ phase: InitializationPhase) async {
        await MainActor.run {
            phaseSubject.send(phase)
        }
    }

    private func startDownloadServerIfNeeded() async {
        await DownloadServerManager.shared.startIfNeeded()
    }

    private func startPostLaunchMaintenance() {
        guard !BackgroundQAConfiguration.isEnabled else {
            logInfo("Background QA: post-launch maintenance and queue restoration suppressed")
            return
        }
        postLaunchMaintenanceTask?.cancel()
        postLaunchMaintenanceTask = Task { [weak self] in
            await self?.runPostLaunchMaintenance()
        }
    }

    private func runPostLaunchMaintenance() async {
        logInfo("Post-launch maintenance started")

        // These are migration/backfill-style repairs. They are useful, but not required
        // before the first library page can render.
        await runStartupMaintenanceOnce(.contextOnlyAspectRatios) {
            await fixContextOnlyAspectRatios()
        }
        await runStartupMaintenanceOnce(.videoAspectRatios) {
            await fixVideoAspectRatios()
        }
        await runStartupMaintenanceOnce(.imageExifOrientationRatios) {
            await fixImageExifOrientationRatios()
        }

        guard !Task.isCancelled else { return }

        logInfo("Queueing incomplete items for vision processing...")
        await visionQueue.requeueIncomplete()
        logInfo("Vision queue populated")

        guard !Task.isCancelled else { return }

        logInfo("Queueing items for ML pipeline processing...")
        await pipelineQueue.requeueIncomplete()
        logInfo("Pipeline queue populated")

        guard !Task.isCancelled else { return }

        logInfo("Queueing video items for native video understanding...")
        await videoUnderstandingQueue.requeueIncomplete()
        logInfo("Video understanding queue populated")

        guard !Task.isCancelled else { return }

        logInfo("Queueing audio/video items for local transcription...")
        await transcriptionQueue.requeueIncomplete()
        logInfo("Transcription queue populated")

        guard !Task.isCancelled else { return }

        async let downloadServerStartup: Void = startDownloadServerIfNeeded()
        async let enrichmentBackfill: Void = runEnrichmentBackfillIfNeeded()
        _ = await (downloadServerStartup, enrichmentBackfill)

        logInfo("Post-launch maintenance complete")
    }

    private func runStartupMaintenanceOnce(
        _ flag: StartupMaintenanceFlag,
        operation: () async -> Bool
    ) async {
        let key = await startupMaintenanceKey(for: flag)
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        if await operation() {
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    private func startupMaintenanceKey(for flag: StartupMaintenanceFlag) async -> String {
        let dbPath = await database.databasePath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "appCoordinator.startupMaintenance.\(flag.rawValue).\(dbPath)"
    }

    /// One-time backfill to push already-enriched items into vault frontmatter.
    private func runEnrichmentBackfillIfNeeded() async {
        let backfillKey = "vault.backfill.enrichment.v1"
        guard !UserDefaults.standard.bool(forKey: backfillKey) else { return }

        do {
            let enrichedIds = try await mediaStore.itemIdsWithEnrichment()
            if !enrichedIds.isEmpty {
                logInfo("Backfill: enqueueing \(enrichedIds.count) enriched items for vault write-back")
                try await mediaStore.writeBackQueue.persistBackfill(enrichedIds)
            }
            UserDefaults.standard.set(true, forKey: backfillKey)
            logInfo("Backfill: complete (key set, won't run again)")
        } catch {
            logWarning("Backfill: failed to query enriched items: \(error.localizedDescription)")
            // Don't set the key — retry next launch.
        }
    }

    private func reconcileTagDefinitions() async {
        do {
            let tags = try await mediaStore.fetchAllTags()
            let importedCount = await MainActor.run {
                TagSettings.shared.ensureDefinitionsExist(for: tags)
            }
            if importedCount > 0 {
                logInfo("Imported \(importedCount) missing tag definitions from database")
            }
        } catch {
            logWarning("Failed to reconcile tag definitions from database: \(error.localizedDescription)")
        }
    }

    /// Perform initial scan of archive directory
    func performInitialScan(watcher: ArchiveWatcher? = nil) async throws -> [MediaItem] {
        guard let watcher = watcher ?? archiveWatcher else {
            throw CoordinatorError.watcherNotStarted
        }

        await updatePhase(.scanningArchive(progress: 0))
        let discoveredFiles = try await watcher.scanArchive()
        let scannedFiles = try await mediaStore.reconcileCombinedAssociations(discoveredFiles)
        try await mediaStore.backfillStatusURLAuthors()
        await updatePhase(.preparingArchive)
        var newItems: [MediaItem] = []
        var adoptedItems: [MediaItem] = []
        var changedExistingItems: [(parsed: MediaItem, state: MediaStore.StartupScanState)] = []

        // Phase 1: Parse metadata + compute aspect ratios with bounded concurrency.
        // Parsing/frontmatter and media metadata I/O are independent per item.
        let startupScanStates = try await mediaStore.fetchStartupScanStates()
        let persistedParseFailures = try await database.fetchSidecarParseFailures()
        var discoveredSidecarPaths = Set<String>()
        var sidecarIdentitiesByPath: [String: SidecarFileIdentity] = [:]
        for (_, files) in scannedFiles {
            guard let metadataFile = files.metadataFile else { continue }
            if let identity = MetadataParser.sidecarIdentity(fileAt: metadataFile) {
                // `sidecarIdentity` already resolves the canonical path and reads the
                // lightweight file fingerprint. Reuse both below instead of issuing a
                // second realpath + attributes lookup for every sidecar at startup.
                discoveredSidecarPaths.insert(identity.canonicalPath)
                sidecarIdentitiesByPath[metadataFile.path] = identity
            } else {
                // Keep unreadable/missing files represented for negative-cache pruning,
                // even though they cannot supply a stable fingerprint this pass.
                discoveredSidecarPaths.insert(SidecarFileIdentity.canonicalPath(for: metadataFile))
            }
        }

        let prunedParseFailureCount = try await database.pruneSidecarParseFailures(
            keepingCanonicalPaths: discoveredSidecarPaths
        )
        if prunedParseFailureCount > 0 {
            logInfo("Startup sidecar failures: pruned \(prunedParseFailureCount) missing files")
        }

        let parseFailuresByPath = Dictionary(
            uniqueKeysWithValues: persistedParseFailures
                .filter { discoveredSidecarPaths.contains($0.canonicalPath) }
                .map { ($0.canonicalPath, $0) }
        )
        var cacheBackfills: [(state: MediaStore.StartupScanState, fingerprint: MetadataFileFingerprint)] = []
        var deferredVerificationEntries: [ScannedArchiveEntry] = []
        var skippedCachedCount = 0
        var skippedBackfilledCount = 0
        var skippedParseFailureCount = 0
        var retriedParseFailureCount = 0

        let completeEntries = scannedFiles.compactMap { (baseURL, files) -> ScannedArchiveEntry? in
            guard files.isComplete, let metadataFile = files.metadataFile else {
                return nil
            }

            let sidecarIdentity = sidecarIdentitiesByPath[metadataFile.path]
            let canonicalPath = sidecarIdentity?.canonicalPath
                ?? SidecarFileIdentity.canonicalPath(for: metadataFile)
            let cachedParseFailure = parseFailuresByPath[canonicalPath]
            if let cachedParseFailure,
               let sidecarIdentity,
               cachedParseFailure.matches(sidecarIdentity) {
                skippedParseFailureCount += 1
                return nil
            }
            if cachedParseFailure != nil {
                // A positive startup cache must never mask a changed formerly-bad file.
                // Bypass it so editing a malformed sidecar always causes a retry.
                retriedParseFailureCount += 1
            }

            let existingState = startupScanStates[metadataFile.path]
            if cachedParseFailure == nil,
               let existingState,
               existingState.matchesDiscoveredFiles(mediaFiles: files.mediaFiles, contextImage: files.contextImage),
               let fingerprint = sidecarIdentity?.fingerprint
                    ?? MetadataFileFingerprint.current(for: metadataFile) {
                if existingState.matchesCacheAfterStoredFilesMatch(fingerprint: fingerprint) {
                    skippedCachedCount += 1
                    return nil
                }

                if existingState.cachedFingerprint == nil {
                    let entry = ScannedArchiveEntry(
                        baseURL: baseURL,
                        metadataFile: metadataFile,
                        mediaFiles: files.mediaFiles,
                        contextImage: files.contextImage,
                        existingState: existingState,
                        sidecarIdentity: sidecarIdentity,
                        hadCachedParseFailure: false
                    )
                    cacheBackfills.append((existingState, fingerprint))
                    deferredVerificationEntries.append(entry)
                    skippedBackfilledCount += 1
                    return nil
                }

                if existingState.cachedFingerprint == fingerprint {
                    cacheBackfills.append((existingState, fingerprint))
                    skippedBackfilledCount += 1
                    return nil
                }
            }

            return ScannedArchiveEntry(
                baseURL: baseURL,
                metadataFile: metadataFile,
                mediaFiles: files.mediaFiles,
                contextImage: files.contextImage,
                existingState: existingState,
                sidecarIdentity: sidecarIdentity,
                hadCachedParseFailure: cachedParseFailure != nil
            )
        }
        let totalComplete = completeEntries.count
        let skippedTotal = skippedCachedCount + skippedBackfilledCount
        if skippedTotal > 0 || totalComplete > 0 {
            logInfo(
                "Startup scan cache: skipped \(skippedTotal) unchanged items " +
                "(\(skippedBackfilledCount) cache backfills), parsing \(totalComplete)"
            )
        }
        try await mediaStore.backfillStartupScanCache(cacheBackfills)
        deferredStartupScanVerifications.append(contentsOf: deferredVerificationEntries)

        if skippedParseFailureCount > 0 || retriedParseFailureCount > 0 {
            logInfo(
                "Startup sidecar failures: skipped \(skippedParseFailureCount) unchanged malformed files, " +
                "retrying \(retriedParseFailureCount) changed files"
            )
        }

        var successfulParseRetryPaths = Set<String>()
        var parseFailureCandidatesByPath: [String: SidecarParseFailureCandidate] = [:]
        if totalComplete > 0 {
            await updatePhase(.parsingMetadata(current: 0, total: totalComplete))
            let maxConcurrentParsers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
            await withTaskGroup(of: (
                item: MediaItem?,
                existingState: MediaStore.StartupScanState?,
                errorMessage: String?,
                sidecarIdentity: SidecarFileIdentity?,
                hadCachedParseFailure: Bool
            ).self) { group in
                var nextEntryIndex = 0
                let initialTaskCount = min(maxConcurrentParsers, totalComplete)

                for _ in 0..<initialTaskCount {
                    let entry = completeEntries[nextEntryIndex]
                    nextEntryIndex += 1
                    group.addTask {
                        let result = await Self.parseScannedItem(
                            baseURL: entry.baseURL,
                            metadataFile: entry.metadataFile,
                            mediaFiles: entry.mediaFiles,
                            contextImage: entry.contextImage
                        )
                        return (
                            result.item,
                            entry.existingState,
                            result.errorMessage,
                            entry.sidecarIdentity,
                            entry.hadCachedParseFailure
                        )
                    }
                }

                var processed = 0
                while let result = await group.next() {
                    processed += 1

                    if let item = result.item {
                        if let existingState = result.existingState {
                            changedExistingItems.append((item, existingState))
                        } else {
                            newItems.append(item)
                        }
                    }
                    if let errorMessage = result.errorMessage {
                        logError(errorMessage)
                        if let identity = result.sidecarIdentity {
                            parseFailureCandidatesByPath[identity.canonicalPath] = SidecarParseFailureCandidate(
                                identity: identity,
                                parseError: errorMessage
                            )
                        }
                    } else if result.hadCachedParseFailure,
                              let identity = result.sidecarIdentity {
                        successfulParseRetryPaths.insert(identity.canonicalPath)
                    }

                    if processed % 50 == 0 || processed == totalComplete {
                        await updatePhase(processed == totalComplete
                            ? .preparingArchive
                            : .parsingMetadata(current: processed, total: totalComplete))
                    }

                    if nextEntryIndex < totalComplete {
                        let entry = completeEntries[nextEntryIndex]
                        nextEntryIndex += 1
                        group.addTask {
                            let result = await Self.parseScannedItem(
                                baseURL: entry.baseURL,
                                metadataFile: entry.metadataFile,
                                mediaFiles: entry.mediaFiles,
                                contextImage: entry.contextImage
                            )
                            return (
                                result.item,
                                entry.existingState,
                                result.errorMessage,
                                entry.sidecarIdentity,
                                entry.hadCachedParseFailure
                            )
                        }
                    }
                }
            }
        }

        try await database.applySidecarParseResults(
            successfulCanonicalPaths: successfulParseRetryPaths,
            failures: Array(parseFailureCandidatesByPath.values)
        )

        // Offline sidecar renames must keep their UUID before insertion/reconciliation.
        let adoptedIDs = try await mediaStore.adoptMovedSidecars(
            newItems.map { (url: $0.metadataFile, mediaFiles: $0.mediaFiles) }
        )
        if !adoptedIDs.isEmpty {
            var remainingNewItems: [MediaItem] = []
            for parsed in newItems {
                if let id = adoptedIDs[parsed.metadataFile.path],
                   let existingItem = try await mediaStore.fetchItem(id: id) {
                    let updated = Self.changedScannedItem(parsed, preserving: existingItem)
                    try await mediaStore.updateItem(updated, source: .sidecar)
                    adoptedItems.append(updated)
                } else {
                    remainingNewItems.append(parsed)
                }
            }
            newItems = remainingNewItems
        }

        // Phase 1b: Auto-generate sidecars for media files without metadata
        let incompleteItems = scannedFiles.filter { (_, files) in
            files.metadataFile == nil && (!files.mediaFiles.isEmpty || files.contextImage != nil)
        }

        if !incompleteItems.isEmpty {
            logInfo("Found \(incompleteItems.count) media files without sidecars, generating...")
            var generatedCount = 0

            await updatePhase(.generatingSidecars(current: 0, total: incompleteItems.count))
            for (index, entry) in incompleteItems.enumerated() {
                let (baseURL, files) = entry
                // Count every attempted sidecar, including skipped and failed ones.
                await updatePhase(.generatingSidecars(current: index, total: incompleteItems.count))
                let mediaFile = files.mediaFiles.first ?? files.contextImage
                guard let mediaFile = mediaFile else { continue }

                do {
                    // Use file modification date as archived date (preserves original download time)
                    let fileDate: Date
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: mediaFile.path),
                       let modDate = attrs[.modificationDate] as? Date {
                        fileDate = modDate
                    } else {
                        fileDate = Date()
                    }

                    // Try to extract platform/author from downloader filename pattern:
                    // YYYY-MM-DD-platform-author-id-N.ext or YYYY-MM-DD-HHMMSS-platform-...
                    let basename = mediaFile.deletingPathExtension().lastPathComponent
                    let parts = basename.split(separator: "-").map(String.init)
                    var detectedPlatform: String?
                    var detectedAuthor: String?
                    let knownPlatforms = ["twitter", "instagram", "reddit", "youtube", "tiktok", "tumblr", "flickr", "bluesky", "bsky"]
                    // Skip date parts (YYYY, MM, DD, optional HHMMSS), find first known platform
                    for (i, part) in parts.enumerated() where i >= 3 {
                        let normalizedPart = part.lowercased()
                        if knownPlatforms.contains(normalizedPart) {
                            detectedPlatform = normalizedPart == "bsky" ? "bluesky" : normalizedPart
                            // Author is the next part after platform (if it exists and isn't a tweet ID)
                            if i + 1 < parts.count {
                                let candidate = parts[i + 1]
                                // Tweet IDs are long numeric strings; usernames are not
                                if candidate.count < 15 || candidate.contains(where: { !$0.isNumber }) {
                                    detectedAuthor = candidate
                                }
                            }
                            break
                        }
                    }

                    let sidecarURL = try MetadataParser.createMetadataFile(
                        forMediaAt: mediaFile,
                        source: URL(string: "file://\(mediaFile.path)"),
                        tags: [],
                        archivedDate: fileDate,
                        platform: detectedPlatform,
                        author: detectedAuthor
                    )

                    // Parse the newly created sidecar
                    let result = await MetadataParser.parseGracefullyAsync(fileAt: sidecarURL)
                    guard let metadata = result.metadata else {
                        logError("Failed to parse generated sidecar for \(mediaFile.lastPathComponent): \(result.errors)")
                        continue
                    }

                    let thumbnailSource = files.mediaFiles.first ?? files.contextImage
                    let aspectRatio = await Self.calculateAspectRatio(for: thumbnailSource) ?? 1.0

                    let item = MediaItem(
                        id: UUID(),
                        basePath: baseURL,
                        metadataFile: sidecarURL,
                        mediaFiles: files.mediaFiles,
                        contextImage: files.contextImage,
                        metadata: metadata,
                        indexedContent: nil,
                        aspectRatio: aspectRatio
                    )
                    newItems.append(item)
                    generatedCount += 1
                } catch let error as WriterError where error == .fileExists {
                    // Sidecar already exists (race condition or leftover) - skip silently
                    logDebug("Sidecar already exists for \(mediaFile.lastPathComponent), skipping")
                } catch {
                    logError("Failed to generate sidecar for \(mediaFile.lastPathComponent): \(error.localizedDescription)")
                }
            }

            logInfo("Generated \(generatedCount) sidecars for orphaned media files")
        }

        // Phase 2: Batch insert new items and apply focused updates for changed existing items.
        if !newItems.isEmpty {
            await updatePhase(.insertingItems(total: newItems.count))
            try await mediaStore.insertItemsBatch(newItems)
        }
        try await applyChangedScannedItems(changedExistingItems, reportsProgress: true)
        await updatePhase(.reconcilingArchive)
        _ = try await mediaStore.reconcileContextAssociations(scannedFiles)

        return newItems + adoptedItems + changedExistingItems.map(\.parsed)
    }

    private struct ScannedArchiveEntry: Sendable {
        let baseURL: URL
        let metadataFile: URL
        let mediaFiles: [URL]
        let contextImage: URL?
        let existingState: MediaStore.StartupScanState?
        let sidecarIdentity: SidecarFileIdentity?
        let hadCachedParseFailure: Bool
    }

    private func startDeferredStartupScanVerificationIfNeeded() {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        let entries = deferredStartupScanVerifications
        deferredStartupScanVerifications.removeAll(keepingCapacity: true)
        guard !entries.isEmpty else { return }

        Task(priority: .utility) { [weak self] in
            await self?.verifyDeferredStartupScanEntries(entries)
        }
    }

    private func verifyDeferredStartupScanEntries(_ entries: [ScannedArchiveEntry]) async {
        logInfo("Startup scan cache: verifying \(entries.count) newly cached sidecars in background")

        var changedItems: [(parsed: MediaItem, state: MediaStore.StartupScanState)] = []
        changedItems.reserveCapacity(min(entries.count, 100))
        var successfulParseRetryPaths = Set<String>()
        var parseFailureCandidatesByPath: [String: SidecarParseFailureCandidate] = [:]

        for entry in entries {
            guard let existingState = entry.existingState else { continue }

            let result = await Self.parseScannedItem(
                baseURL: entry.baseURL,
                metadataFile: entry.metadataFile,
                mediaFiles: entry.mediaFiles,
                contextImage: entry.contextImage
            )
            if let errorMessage = result.errorMessage {
                logError(errorMessage)
                if let identity = entry.sidecarIdentity {
                    parseFailureCandidatesByPath[identity.canonicalPath] = SidecarParseFailureCandidate(
                        identity: identity,
                        parseError: errorMessage
                    )
                }
            } else if entry.hadCachedParseFailure,
                      let identity = entry.sidecarIdentity {
                successfulParseRetryPaths.insert(identity.canonicalPath)
            }

            guard let parsed = result.item,
                  await deferredScanParsedItemDiffers(parsed, from: existingState) else {
                continue
            }

            changedItems.append((parsed, existingState))
            if changedItems.count >= 100 {
                await applyDeferredScanChanges(changedItems)
                changedItems.removeAll(keepingCapacity: true)
            }

            await Task.yield()
        }

        if !changedItems.isEmpty {
            await applyDeferredScanChanges(changedItems)
        }

        do {
            try await database.applySidecarParseResults(
                successfulCanonicalPaths: successfulParseRetryPaths,
                failures: Array(parseFailureCandidatesByPath.values)
            )
        } catch {
            logError("Startup sidecar failures: failed to persist background results: \(error.localizedDescription)")
        }

        logInfo("Startup scan cache: background sidecar verification complete")
    }

    private func deferredScanParsedItemDiffers(_ parsed: MediaItem, from state: MediaStore.StartupScanState) async -> Bool {
        do {
            guard let existingItem = try await mediaStore.fetchItem(id: state.itemId) else {
                return true
            }

            return existingItem.metadata != parsed.metadata ||
                existingItem.mediaFiles != parsed.mediaFiles ||
                existingItem.contextImage != parsed.contextImage ||
                existingItem.aspectRatio != parsed.aspectRatio
        } catch {
            logError("Startup scan cache: failed to fetch item for verification: \(error.localizedDescription)")
            return false
        }
    }

    private func applyDeferredScanChanges(_ changes: [(parsed: MediaItem, state: MediaStore.StartupScanState)]) async {
        do {
            try await applyChangedScannedItems(changes)
        } catch {
            logError("Startup scan cache: failed to apply background verification updates: \(error.localizedDescription)")
        }
    }

    func applyChangedScannedItems(
        _ changedItems: [(parsed: MediaItem, state: MediaStore.StartupScanState)],
        reportsProgress: Bool = false
    ) async throws {
        guard !changedItems.isEmpty else { return }

        logInfo("Startup scan: updating \(changedItems.count) changed existing items")
        if reportsProgress {
            await updatePhase(.updatingChangedItems(current: 0, total: changedItems.count))
        }
        let batchSize = 150
        for start in stride(from: 0, to: changedItems.count, by: batchSize) {
            try Task.checkCancellation()
            let end = min(start + batchSize, changedItems.count)
            let batch = changedItems[start..<end].map { (parsed: $0.parsed, itemID: $0.state.itemId) }
            do {
                try await mediaStore.updateChangedScannedItemsBatch(batch)
            } catch {
                try Task.checkCancellation()
                // Retain the old prefix-commit behavior if one sidecar fails.
                // The failed transaction rolled back, so replay only this batch.
                for (offset, changed) in changedItems[start..<end].enumerated() {
                    if let existing = try await mediaStore.fetchItem(id: changed.state.itemId) {
                        let updated = Self.changedScannedItem(changed.parsed, preserving: existing)
                        try await mediaStore.updateItem(updated, source: .sidecar)
                    }
                    if reportsProgress {
                        await updatePhase(.updatingChangedItems(current: start + offset + 1, total: changedItems.count))
                    }
                }
            }
            if reportsProgress {
                await updatePhase(end == changedItems.count
                    ? .reconcilingArchive
                    : .updatingChangedItems(current: end, total: changedItems.count))
            }
        }
    }

    /// Applies freshly parsed filesystem fields without resetting derived processing state.
    /// Startup scans only reparse sidecar/media metadata; they do not supersede pipeline,
    /// transcription, video-understanding, OCR, or timeline results already stored for the item.
    nonisolated static func changedScannedItem(_ parsed: MediaItem, preserving existingItem: MediaItem) -> MediaItem {
        MediaItem(
            id: existingItem.id,
            basePath: parsed.basePath,
            metadataFile: parsed.metadataFile,
            mediaFiles: parsed.mediaFiles,
            contextImage: parsed.contextImage,
            prefersContextImage: existingItem.prefersContextImage,
            metadata: parsed.metadata,
            indexedContent: existingItem.indexedContent,
            aspectRatio: parsed.aspectRatio ?? existingItem.aspectRatio,
            parseStatus: parsed.parseStatus,
            parseErrors: parsed.parseErrors,
            deletionReason: existingItem.deletionReason,
            generatedCaption: existingItem.generatedCaption,
            pipelineStatus: existingItem.pipelineStatus,
            pipelineLastError: existingItem.pipelineLastError,
            pipelineFailedAt: existingItem.pipelineFailedAt,
            pipelineRetryCount: existingItem.pipelineRetryCount,
            videoUnderstandingStatus: existingItem.videoUnderstandingStatus,
            videoUnderstandingLastError: existingItem.videoUnderstandingLastError,
            videoUnderstandingFailedAt: existingItem.videoUnderstandingFailedAt,
            videoUnderstandingRetryCount: existingItem.videoUnderstandingRetryCount,
            videoUnderstandingVersion: existingItem.videoUnderstandingVersion,
            transcriptionStatus: existingItem.transcriptionStatus,
            transcriptionLastError: existingItem.transcriptionLastError,
            transcriptionFailedAt: existingItem.transcriptionFailedAt,
            transcriptionRetryCount: existingItem.transcriptionRetryCount,
            transcriptionVersion: existingItem.transcriptionVersion,
            mlAttributes: existingItem.mlAttributes,
            perFileOCR: existingItem.perFileOCR,
            videoSegments: existingItem.videoSegments,
            transcriptSegments: existingItem.transcriptSegments
        )
    }

    /// Parse one scanned archive entry into a MediaItem.
    /// Runs in parallel task-group workers during startup scan.
    private nonisolated static func parseScannedItem(
        baseURL: URL,
        metadataFile: URL,
        mediaFiles: [URL],
        contextImage: URL?
    ) async -> (item: MediaItem?, errorMessage: String?) {
        do {
            let metadata = try await MetadataParser.parseAsync(fileAt: metadataFile)
            let thumbnailSource = mediaFiles.first ?? contextImage
            let aspectRatio = await Self.calculateAspectRatio(for: thumbnailSource) ?? 1.0

            let item = MediaItem(
                id: UUID(),
                basePath: baseURL,
                metadataFile: metadataFile,
                mediaFiles: mediaFiles,
                contextImage: contextImage,
                metadata: metadata,
                indexedContent: nil,
                aspectRatio: aspectRatio
            )
            return (item, nil)
        } catch {
            return (nil, "Failed to parse \(metadataFile.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Calculate aspect ratio from media file (image or video)
    private nonisolated static func calculateAspectRatio(for url: URL?) async -> CGFloat? {
        guard let url = url else { return nil }

        let ext = url.pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
        let videoExtensions = ["mp4", "mov", "webm", "m4v", "avi", "mkv"]

        if videoExtensions.contains(ext) {
            // Extract actual dimensions from video track
            return await Self.calculateVideoAspectRatio(for: url)
        }

        guard imageExtensions.contains(ext) else {
            // Unknown media type - fallback to square
            return 1.0
        }

        // Load image dimensions
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return 1.0
        }

        // Check EXIF orientation - orientations 5-8 indicate 90/270 degree rotation
        // where the visual width/height are swapped from the raw pixel dimensions
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let isRotated = [5, 6, 7, 8].contains(orientation)

        let ratio: CGFloat
        if isRotated {
            // Swap dimensions for rotated images
            ratio = CGFloat(height) / CGFloat(width)
        } else {
            ratio = CGFloat(width) / CGFloat(height)
        }

        // Clamp to reasonable bounds to prevent layout breakage
        // 0.25 = 1:4 portrait, 4.0 = 4:1 landscape
        return min(max(ratio, 0.25), 4.0)
    }

    /// Calculate aspect ratio from video file using AVAsset
    private nonisolated static func calculateVideoAspectRatio(for url: URL) async -> CGFloat? {
        let asset = AVAsset(url: url)

        do {
            // Load video tracks
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = tracks.first else {
                return 16.0 / 9.0 // Fallback for videos without video track
            }

            // Get natural size (accounts for transform/rotation)
            let size = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)

            // Apply transform to get display dimensions
            // Portrait videos have a 90-degree rotation in their transform
            let transformedSize = size.applying(transform)
            let width = abs(transformedSize.width)
            let height = abs(transformedSize.height)

            guard width > 0, height > 0 else {
                return 16.0 / 9.0
            }

            let ratio = width / height
            // Clamp to reasonable bounds
            return min(max(ratio, 0.25), 4.0)
        } catch {
            logDebug("Failed to get video dimensions for \(url.lastPathComponent): \(error.localizedDescription)")
            return 16.0 / 9.0 // Fallback on error
        }
    }

    /// Fix aspect ratios for context-only items that have incorrect values.
    /// Context-only items (alt+click) have no media files but have a .context.png image.
    /// Previously these were stored with aspectRatio=1.0 instead of the actual image ratio.
    private func fixContextOnlyAspectRatios() async -> Bool {
        let store = mediaStore

        do {
            // Fetch all items
            let allItems = try await store.fetchItems(filter: .all.withUnlimitedLimit())

            // Find context-only items with incorrect aspect ratios
            let contextOnlyItems = allItems.filter { item in
                item.mediaFiles.isEmpty &&
                item.contextImage != nil &&
                (item.aspectRatio == 1.0 || item.aspectRatio == nil)
            }

            guard !contextOnlyItems.isEmpty else {
                logDebug("No context-only items need aspect ratio fixes")
                return true
            }

            logInfo("Fixing aspect ratios for \(contextOnlyItems.count) context-only items")

            for item in contextOnlyItems {
                guard let contextURL = item.contextImage else { continue }

                // Calculate actual aspect ratio from context image
                if let actualRatio = await Self.calculateAspectRatio(for: contextURL),
                   actualRatio != item.aspectRatio {
                    var updated = item
                    updated.aspectRatio = actualRatio
                    try await store.updateItem(updated)
                    logDebug("Fixed aspect ratio for \(item.metadataFile.lastPathComponent): \(item.aspectRatio ?? 0) -> \(actualRatio)")
                }
            }

            logInfo("Aspect ratio fix complete")
            return true
        } catch {
            logError("Failed to fix context-only aspect ratios: \(error.localizedDescription)")
            return false
        }
    }

    /// Fix aspect ratios for video items that were stored with incorrect 16:9 default.
    /// Videos (especially portrait videos) need their actual dimensions extracted from the video track.
    private func fixVideoAspectRatios() async -> Bool {
        let store = mediaStore
        let videoExtensions = Set(["mp4", "mov", "webm", "m4v", "avi", "mkv"])

        do {
            let allItems = try await store.fetchItems(filter: .all.withUnlimitedLimit())

            // Find video items that might have incorrect aspect ratios (close to 16:9 default)
            let videoItems = allItems.filter { item in
                guard let primaryMedia = item.primaryMedia else { return false }
                let ext = primaryMedia.pathExtension.lowercased()
                guard videoExtensions.contains(ext) else { return false }

                // Check if aspect ratio is the default 16:9 (1.777...) or nil
                // This catches items that were stored before we fixed the video aspect ratio calculation
                if let ratio = item.aspectRatio {
                    let defaultRatio: CGFloat = 16.0 / 9.0
                    return abs(ratio - defaultRatio) < 0.01 // Within 1% of 16:9
                }
                return true // nil aspect ratio
            }

            guard !videoItems.isEmpty else {
                logDebug("No video items need aspect ratio fixes")
                return true
            }

            logInfo("Checking aspect ratios for \(videoItems.count) video items")
            var fixedCount = 0

            for item in videoItems {
                guard let videoURL = item.primaryVideoMedia else { continue }

                if let actualRatio = await Self.calculateVideoAspectRatio(for: videoURL),
                   actualRatio != item.aspectRatio {
                    var updated = item
                    updated.aspectRatio = actualRatio
                    try await store.updateItem(updated)
                    logDebug("Fixed video aspect ratio for \(item.metadataFile.lastPathComponent): \(item.aspectRatio ?? 0) -> \(actualRatio)")
                    fixedCount += 1
                }
            }

            if fixedCount > 0 {
                logInfo("Fixed aspect ratios for \(fixedCount) video items")
            }
            return true
        } catch {
            logError("Failed to fix video aspect ratios: \(error.localizedDescription)")
            return false
        }
    }

    /// Fix aspect ratios for images that have EXIF orientation rotation.
    /// Previously calculateAspectRatio didn't account for EXIF orientation 5-8 (90/270 degree rotations),
    /// causing portrait screenshots to be stored with landscape aspect ratios.
    private func fixImageExifOrientationRatios() async -> Bool {
        let store = mediaStore
        let imageExtensions = Set(["jpg", "jpeg", "png", "heic", "webp"])

        do {
            let allItems = try await store.fetchItems(filter: .all.withUnlimitedLimit())
            var fixedCount = 0

            for item in allItems {
                // Get the thumbnail source (primary media or context image)
                guard let sourceURL = item.thumbnailSource else { continue }

                let ext = sourceURL.pathExtension.lowercased()
                guard imageExtensions.contains(ext) else { continue }

                // Recalculate aspect ratio with EXIF orientation fix
                if let newRatio = await Self.calculateAspectRatio(for: sourceURL),
                   let oldRatio = item.aspectRatio,
                   abs(newRatio - oldRatio) > 0.01 {  // Changed by more than 1%
                    var updated = item
                    updated.aspectRatio = newRatio
                    try await store.updateItem(updated)
                    logDebug("Fixed EXIF orientation ratio for \(item.metadataFile.lastPathComponent): \(oldRatio) -> \(newRatio)")
                    fixedCount += 1
                }
            }

            if fixedCount > 0 {
                logInfo("Fixed EXIF orientation aspect ratios for \(fixedCount) items")
            }
            return true
        } catch {
            logError("Failed to fix EXIF orientation aspect ratios: \(error.localizedDescription)")
            return false
        }
    }

    /// Repair media associations derived from sidecars.
    /// Handles:
    /// - legacy suffixed metadata files (`...-3.md`)
    /// - quote-tweet metadata where source tweet ID differs from sidecar filename
    func fixMetadataMediaAssociations() async -> Bool {
        let store = mediaStore

        do {
            let candidateRows: [(metadataFileString: String, platform: String, sourceURL: String)] = try await database.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT metadataFileString, platform, sourceURL
                        FROM media_items
                        WHERE (deletedAt IS NULL OR deletedAt = '')
                          AND (
                            metadataFileString GLOB '*-[1-9].md'
                            OR metadataFileString GLOB '*_[1-9].md'
                            OR (
                              platform = 'twitter'
                              AND sourceURL LIKE '%/status/%'
                            )
                          )
                    """
                )
                return rows.compactMap { row in
                    guard let metadataFileString: String = row["metadataFileString"],
                          let platform: String = row["platform"],
                          let sourceURL: String = row["sourceURL"] else {
                        return nil
                    }
                    return (metadataFileString, platform, sourceURL)
                }
            }

            guard !candidateRows.isEmpty else {
                return true
            }

            var candidateMetadataPaths: [String] = []
            candidateMetadataPaths.reserveCapacity(candidateRows.count)

            for row in candidateRows {
                let metadataURL = URL(fileURLWithPath: row.metadataFileString)
                let metadataStem = metadataURL.deletingPathExtension().lastPathComponent
                let isSuffixedSidecar = Self.normalizeBaseName(metadataStem) != metadataStem

                var isTwitterQuoteMismatch = false
                if row.platform.lowercased() == "twitter",
                   let sourceURL = URL(string: row.sourceURL),
                   let statusID = Self.extractTwitterStatusID(from: sourceURL) {
                    isTwitterQuoteMismatch = !metadataStem.contains(statusID)
                }

                if isSuffixedSidecar || isTwitterQuoteMismatch {
                    candidateMetadataPaths.append(row.metadataFileString)
                }
            }

            guard !candidateMetadataPaths.isEmpty else {
                return true
            }

            var fixedCount = 0
            var groupsByDirectory: [URL: [URL: ArchiveItemFiles]] = [:]
            for metadataPath in candidateMetadataPaths {
                guard let item = try await store.fetchItem(byMetadataPath: metadataPath) else {
                    continue
                }

                let metadataStem = item.metadataFile.deletingPathExtension().lastPathComponent
                let isSuffixedSidecar = Self.normalizeBaseName(metadataStem) != metadataStem

                let statusID = Self.extractTwitterStatusID(from: item.metadata.source)
                let isTwitterQuoteMismatch =
                    item.metadata.platform.lowercased() == "twitter" &&
                    (statusID.map { !metadataStem.contains($0) } ?? false)

                guard isSuffixedSidecar || isTwitterQuoteMismatch else { continue }

                let directory = item.metadataFile.deletingLastPathComponent()
                if groupsByDirectory[directory] == nil {
                    let discovered = ArchiveAssociationResolver.items(in: directory, archivePath: archivePath)
                    groupsByDirectory[directory] = try await store.reconcileCombinedAssociations(discovered)
                }
                let key = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(item.metadataFile)).deletingPathExtension()
                let associated = groupsByDirectory[directory]?[key]
                let matchedMediaFiles = associated?.mediaFiles ?? []
                let matchedContextImage = associated?.contextImage

                guard !matchedMediaFiles.isEmpty || matchedContextImage != nil else { continue }

                if matchedMediaFiles != item.mediaFiles || matchedContextImage != item.contextImage {
                    var updated = item
                    updated.mediaFiles = matchedMediaFiles
                    updated.contextImage = matchedContextImage

                    if let ratio = await Self.calculateAspectRatio(for: matchedMediaFiles.first ?? matchedContextImage) {
                        updated.aspectRatio = ratio
                    }

                    try await store.updateItem(updated)
                    fixedCount += 1
                }
            }

            if fixedCount > 0 {
                logInfo("Fixed media association for \(fixedCount) metadata items")
            }
            return true
        } catch {
            logError("Failed to repair metadata media associations: \(error.localizedDescription)")
            return false
        }
    }

    /// Start background task to process file watcher events
    private func startWatcherEventLoop() {
        guard let watcher = archiveWatcher else { return }

        watcherTask = Task { [weak self] in
            for await change in watcher.changes {
                guard let self = self else { break }
                await self.handleFileChange(change)
            }
        }
    }

    /// Handle a file system change event
    func handleFileChange(_ change: FileChange) async {
        // Only process .md files for metadata changes
        // Media files are discovered through their parent .md
        let ext = change.url.pathExtension.lowercased()

        switch change.type {
        case .created, .modified:
            if ext == "md" {
                await handleMetadataChange(change.url)
            } else if isMediaFile(ext) {
                // Media file created/modified - update aspect ratio if needed
                await handleMediaChange(change.url)
            }

        case .deleted:
            if ext == "md" {
                await handleMetadataDeleted(change.url)
            }

        case .renamed(let oldPath), .moved(let oldPath):
            // Handle rename/move by updating paths in database
            // This preserves user data (stars, tags, notes)
            await handleFileRenamed(from: oldPath, to: change.url)
        }
    }

    /// Handle file rename/move by updating database paths instead of delete+recreate
    private func handleFileRenamed(from oldPath: URL, to newPath: URL) async {
        do {
            let updated: Bool = try await database.write { db in
                // Update the path in the database
                try MediaItemRecord.updateFilePath(
                    db: db,
                    oldPath: oldPath.path,
                    newPath: newPath.path
                )
            }
            if updated {
                logInfo("Updated path: \(oldPath.lastPathComponent) -> \(newPath.lastPathComponent)")
            }
        } catch {
            logError("Failed to update path for \(oldPath.lastPathComponent): \(error.localizedDescription)")
            // Fallback: treat as create at new location
            let ext = newPath.pathExtension.lowercased()
            if ext == "md" {
                await handleMetadataChange(newPath)
            }
        }
    }

    private func isMediaFile(_ ext: String) -> Bool {
        [
            "jpg", "jpeg", "png", "gif", "webp", "heic",
            "mp4", "mov", "webm", "m4v", "avi", "mkv",
            "mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "caf"
        ].contains(ext)
    }

    private func isVideoFile(_ ext: String) -> Bool {
        ["mp4", "mov", "webm", "m4v", "avi", "mkv"].contains(ext)
    }

    private func isTranscribableFile(_ ext: String) -> Bool {
        TranscriptionQueue.isTranscribableExtension(ext)
    }

    /// Handle new or modified metadata file
    private func handleMetadataChange(_ url: URL) async {
        // Import even a self-publication: it may have merged another writer's
        // unrelated fields. Transaction-scoped source tagging prevents loops.

        do {
            let discoveredFiles = ArchiveAssociationResolver.items(in: url.deletingLastPathComponent(), archivePath: archivePath)
            let directoryItems = try await mediaStore.reconcileCombinedAssociations(discoveredFiles)
            let changedPath = ArchiveAssociationResolver.canonicalPath(url)
            if let owner = directoryItems.values.first(where: {
                $0.absorbedContextSidecars.contains { ArchiveAssociationResolver.canonicalPath($0) == changedPath }
            })?.metadataFile {
                await handleMetadataChange(owner)
                return
            }
            let metadata = try await MetadataParser.parseAsync(fileAt: url)

            // Find associated media files
            let basePath = url.deletingLastPathComponent()
            let associated = directoryItems[URL(fileURLWithPath: changedPath).deletingPathExtension()]
            let mediaFiles = associated?.mediaFiles ?? []
            let contextImage = associated?.contextImage

            // Context-only items (alt+click) have no media files but may have context image
            let thumbnailSource = mediaFiles.first ?? contextImage
            guard thumbnailSource != nil || !mediaFiles.isEmpty else { return }

            let aspectRatio = await Self.calculateAspectRatio(for: thumbnailSource)

            // A sidecar renamed/moved beside the same media re-attaches to its original item
            // instead of minting a new identity.
            var existing = try await mediaStore.fetchItem(byMetadataPath: url.path)
            if existing == nil,
               let adoptedID = try await mediaStore.adoptMovedSidecar(at: url, mediaFiles: mediaFiles) {
                logInfo("Re-attached moved sidecar: \(url.lastPathComponent)")
                existing = try await mediaStore.fetchItem(byMetadataPath: url.path)
                assert(existing?.id == adoptedID)
            }

            // Check if item already exists
            if let existingItem = existing {
                let hadVideo = existingItem.hasVideo
                let hadTranscribableMedia = existingItem.hasTranscribableMedia
                let mediaFilesChanged = existingItem.mediaFiles.map(\.path) != mediaFiles.map(\.path)

                // Update existing item
                var updated = existingItem
                updated.metadata = metadata
                updated.mediaFiles = mediaFiles
                updated.contextImage = contextImage
                if let ar = aspectRatio {
                    updated.aspectRatio = ar
                }
                try await mediaStore.updateItem(updated, source: .sidecar)

                if mediaFilesChanged {
                    if updated.hasVideo {
                        await videoUnderstandingQueue.enqueue(itemId: updated.id, force: true)
                    } else if hadVideo {
                        await videoUnderstandingQueue.clear(itemId: updated.id)
                    }

                    if updated.hasTranscribableMedia {
                        await transcriptionQueue.enqueue(itemId: updated.id, force: true)
                    } else if hadTranscribableMedia {
                        await transcriptionQueue.clear(itemId: updated.id)
                    }
                }

                // updateItem imports deletion state while preserving pending user recovery.
            } else {
                // Create new item
                let item = MediaItem(
                    id: UUID(),
                    basePath: basePath,
                    metadataFile: url,
                    mediaFiles: mediaFiles,
                    contextImage: contextImage,
                    metadata: metadata,
                    indexedContent: nil,
                    aspectRatio: aspectRatio
                )
                try await mediaStore.insertItem(item)

                // Respect deleted flag from frontmatter (vault-wins on DB rebuild)
                if metadata.deleted {
                    try? await mediaStore.softDelete(ids: [item.id])
                }

                // Enqueue visual media for Vision processing; audio-only items go straight to
                // transcription. Context-only items (no media files, just a context screenshot —
                // e.g. alt+click saves) are also vision-eligible via the contextImage fallback.
                if Self.shouldEnqueueVision(mediaFiles: item.mediaFiles, contextImage: item.contextImage) {
                    await visionQueue.enqueue(itemId: item.id, priority: .normal)
                }
                if item.hasVideo {
                    await videoUnderstandingQueue.enqueue(itemId: item.id)
                }
                if item.hasTranscribableMedia {
                    await transcriptionQueue.enqueue(itemId: item.id)
                }
            }
            _ = try await mediaStore.reconcileContextAssociations(directoryItems)
        } catch {
            logError("Failed to process \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Handle deleted metadata file
    private func handleMetadataDeleted(_ url: URL) async {
        do {
            if let item = try await mediaStore.fetchItem(byMetadataPath: url.path) {
                if await mediaStore.writeBackQueue.isPending(item.id) {
                    // An unavailable sidecar is a retryable projection failure,
                    // not permission to cascade-delete its only durable intent.
                    await mediaStore.writeBackQueue.enqueue(item.id)
                    logWarning("Keeping pending metadata for missing sidecar: \(url.lastPathComponent)")
                    return
                }
                // Usually a rename/move: keep the item and its media, restorable and adoptable
                // by the sidecar's new path (see handleMetadataChange).
                try await mediaStore.markSidecarMissing(id: item.id)
            }
        } catch {
            logError("Failed to delete item for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Handle media file change (update aspect ratio)
    private func handleMediaChange(_ url: URL) async {
        // Find the corresponding metadata file
        guard let metadataURL = ArchiveAssociationResolver.owner(of: url, archivePath: archivePath) else { return }

        await handleMetadataChange(metadataURL)

        do {
            if var item = try await mediaStore.fetchItem(byMetadataPath: metadataURL.path) {
                // Ordinary file notifications never reverse an explicit user decision.
                if item.metadata.deleted && !ArchiveReappearancePolicy.shouldRestore(item) { return }
                // Same-path replacements can preserve aspect ratio. Refresh
                // identity before admitting any new analysis or annotations.
                try await mediaStore.refreshAssets(itemID: item.id)
                // If a previously soft-deleted item's media file reappears on disk
                // (for example after Finder "Put Back"), restore visibility.
                if ArchiveReappearancePolicy.shouldRestore(item) {
                    let restored = try await mediaStore.restoreMissingFiles(ids: [item.id])
                    guard restored.contains(item.id) else { return }
                    item.metadata.deleted = false
                    item.deletionReason = nil
                    logInfo("Auto-restored soft-deleted item after media reappeared: \(item.id)")
                }

                let aspectRatio = await Self.calculateAspectRatio(for: url)
                if let ar = aspectRatio, ar != item.aspectRatio {
                    var updated = item
                    updated.aspectRatio = ar
                    try await mediaStore.updateItem(updated)
                }

                let ext = url.pathExtension.lowercased()

                // Re-enqueue image/video Vision processing only for visual media.
                if !TranscriptionQueue.isAudioExtension(ext) {
                    await visionQueue.enqueue(itemId: item.id, priority: .normal)
                }
                if isVideoFile(ext) {
                    await videoUnderstandingQueue.enqueue(itemId: item.id, force: true)
                }
                if isTranscribableFile(ext) {
                    await transcriptionQueue.enqueue(itemId: item.id, force: true)
                }
            }
        } catch {
            logError("Failed to update media for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Vision-eligible: has at least one non-audio media file, OR is a context-only
    /// item (no media files, but a context screenshot) — VisionJobQueue.process()
    /// already handles the contextImage fallback.
    nonisolated static func shouldEnqueueVision(mediaFiles: [URL], contextImage: URL?) -> Bool {
        if mediaFiles.contains(where: { !TranscriptionQueue.isAudioExtension($0.pathExtension.lowercased()) }) {
            return true
        }
        return mediaFiles.isEmpty && contextImage != nil
    }

    private nonisolated static func normalizeBaseName(_ rawName: String) -> String {
        var filename = rawName

        // Strip .context suffix(es) (e.g., tweet_abc.context.context.png -> tweet_abc)
        while filename.hasSuffix(".context") {
            filename = String(filename.dropLast(".context".count))
        }

        // Only strip trailing _N or -N where N is a single digit (1-9)
        // to avoid stripping IDs that are part of normal filenames.
        if let regex = Self.trailingSingleIndexSuffixRegex,
           let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
           let range = Range(match.range(at: 1), in: filename) {
            return String(filename[range])
        }

        return filename
    }

    private nonisolated static func extractTwitterStatusID(from sourceURL: URL) -> String? {
        let source = sourceURL.absoluteString
        guard let regex = Self.twitterStatusIDRegex,
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else {
            return nil
        }
        return String(source[range])
    }
}

// MARK: - Errors

enum CoordinatorError: Error, LocalizedError {
    case watcherNotStarted
    case databaseNotInitialized

    var errorDescription: String? {
        switch self {
        case .watcherNotStarted:
            return "File watcher not started"
        case .databaseNotInitialized:
            return "Database not initialized"
        }
    }
}

// MARK: - FolderExistenceWatcher

/// Watches a folder for deletion/creation using dispatch source
private class FolderExistenceWatcher: @unchecked Sendable {
    private let path: URL
    private let onChange: @Sendable (Bool) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.nodraw.folderwatcher")

    init(path: URL, onChange: @escaping @Sendable (Bool) -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        // Watch the parent directory since we can't watch a non-existent folder
        let watchPath = path.deletingLastPathComponent()

        fileDescriptor = open(watchPath.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            logWarning("FolderExistenceWatcher: Failed to open \(watchPath.path)")
            return
        }

        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )

        source?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let exists = FileManager.default.fileExists(atPath: self.path.path)
            self.onChange(exists)
        }

        source?.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
        }

        source?.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}
