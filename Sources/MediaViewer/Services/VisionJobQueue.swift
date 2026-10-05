import Foundation
import GRDB
import Combine
import PhotoPipeline

// MARK: - Queue Status

/// Observable status of the Vision processing queue
struct QueueStatus: Sendable, Equatable {
    let processing: Int
    let queued: Int
    let recentErrors: [ProcessingError]

    static let idle = QueueStatus(processing: 0, queued: 0, recentErrors: [])

    var displayText: String {
        if processing == 0 && queued == 0 { return "" }
        return "\(processing) processing, \(queued) queued"
    }

    var isIdle: Bool {
        processing == 0 && queued == 0
    }
}

/// A processing error with context
struct ProcessingError: Sendable, Equatable, Identifiable {
    let id: UUID
    let itemId: UUID
    let stage: String
    let message: String
    let timestamp: Date

    init(itemId: UUID, stage: String, message: String) {
        self.id = UUID()
        self.itemId = itemId
        self.stage = stage
        self.message = message
        self.timestamp = Date()
    }
}

// MARK: - Job Priority

/// Priority level for processing jobs
enum JobPriority: Int, Sendable, Comparable {
    case low = 0
    case normal = 1
    case high = 2  // For user-visible items

    static func < (lhs: JobPriority, rhs: JobPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Processing Result

/// Result of processing a single item through all stages
struct ProcessingResult: Sendable {
    let ocrText: Result<String?, Error>
    let ocrBlocks: Result<[TextBlock], Error>
    let colors: Result<[VisionProcessor.ExtractedColor], Error>
    let saliency: Result<CGRect?, Error>
    let hash: Result<String?, Error>
    /// True if all stages succeeded (even with nil results)
    var isFullSuccess: Bool {
        if case .failure = ocrText { return false }
        if case .failure = ocrBlocks { return false }
        if case .failure = colors { return false }
        if case .failure = saliency { return false }
        if case .failure = hash { return false }
        return true
    }

    /// True if at least one stage produced usable data
    var hasPartialSuccess: Bool {
        if case .success(let text) = ocrText, text != nil { return true }
        if case .success(let blocks) = ocrBlocks, !blocks.isEmpty { return true }
        if case .success(let c) = colors, !c.isEmpty { return true }
        if case .success(let rect) = saliency, rect != nil { return true }
        if case .success(let h) = hash, h != nil { return true }
        return false
    }
}

// MARK: - Vision Job Queue

/// Actor-based job queue for Vision processing operations.
/// Manages concurrent processing of media items with priority support.
actor VisionJobQueue {

    private enum MemoryPressureTier: Sendable {
        case normal
        case warning
        case critical
    }

    /// Shared instance for global access (set by AppCoordinator during initialization)
    private static var _shared: VisionJobQueue?

    /// Access the shared instance. Must be set via `setShared(_:)` before use.
    static var shared: VisionJobQueue {
        guard let instance = _shared else {
            fatalError("VisionJobQueue.shared accessed before setShared(_:) was called")
        }
        return instance
    }

    /// Optional access for call sites that can gracefully continue without queueing.
    static var sharedIfConfigured: VisionJobQueue? {
        _shared
    }

    /// Set the shared instance (called by AppCoordinator during initialization)
    static func setShared(_ queue: VisionJobQueue) {
        _shared = queue
    }

    private static let supportedImageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "heic"]

    /// A still-image source that should receive OCR. Context screenshots use the index
    /// immediately after the media array so they remain distinct and addressable in the
    /// existing per-file OCR table without colliding with a primary media file.
    struct OCRSource: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case media
            case contextImage
        }

        let fileIndex: Int
        let url: URL
        let kind: Kind
    }

    static func ocrSources(mediaURLs: [URL], contextImageURL: URL?) -> [OCRSource] {
        var sources = mediaURLs.enumerated().compactMap { index, url -> OCRSource? in
            guard supportedImageExtensions.contains(url.pathExtension.lowercased()) else {
                return nil
            }
            return OCRSource(fileIndex: index, url: url, kind: .media)
        }

        if let contextImageURL,
           supportedImageExtensions.contains(contextImageURL.pathExtension.lowercased()) {
            sources.append(OCRSource(
                fileIndex: mediaURLs.count,
                url: contextImageURL,
                kind: .contextImage
            ))
        }

        return sources
    }

    static let requeueIncompleteSQL = """
        SELECT id FROM media_items
        WHERE (
            ocrText IS NULL
            OR (
                mediaFilesJSON != '[]'
                AND contextImageString IS NOT NULL
                AND contextImageString != ''
                AND (
                    lower(contextImageString) LIKE '%.jpg'
                    OR lower(contextImageString) LIKE '%.jpeg'
                    OR lower(contextImageString) LIKE '%.png'
                    OR lower(contextImageString) LIKE '%.gif'
                    OR lower(contextImageString) LIKE '%.webp'
                    OR lower(contextImageString) LIKE '%.heic'
                )
                AND NOT EXISTS (
                    SELECT 1
                    FROM media_file_ocr
                    WHERE media_file_ocr.item_id = media_items.id
                      AND media_file_ocr.file_url = media_items.contextImageString
                      AND media_file_ocr.file_index = json_array_length(media_items.mediaFilesJSON)
                      AND media_file_ocr.association_state = 'attached'
                )
            )
            OR (
                (
                    EXISTS (
                        SELECT 1
                        FROM json_each(mediaFilesJSON)
                        WHERE lower(json_each.value) LIKE '%.jpg'
                           OR lower(json_each.value) LIKE '%.jpeg'
                           OR lower(json_each.value) LIKE '%.png'
                           OR lower(json_each.value) LIKE '%.gif'
                           OR lower(json_each.value) LIKE '%.webp'
                           OR lower(json_each.value) LIKE '%.heic'
                    )
                    OR (contextImageString IS NOT NULL AND contextImageString != '')
                )
                AND (
                    dominantColorsJSON IS NULL
                    OR perceptualHash IS NULL
                )
            )
        )
        AND (mediaFilesJSON != '[]'
             OR (contextImageString IS NOT NULL AND contextImageString != ''))
        AND (deletedAt IS NULL OR deletedAt = '')
    """

    /// Check if shared instance has been configured
    static var isConfigured: Bool {
        _shared != nil
    }

    /// Concurrency limit for Vision operations.
    private var maxConcurrent = BackgroundProcessingIntensity.current.visionNormalConcurrency
    private var memoryTier: MemoryPressureTier = .normal
    private var memorySource: DispatchSourceMemoryPressure?
    private var interactionObserver: NSObjectProtocol?
    private var lastProcessNextDiagnostic: String?

    /// Pending jobs ordered by priority (high priority at front)
    static let maxResidentPendingJobs = 512
    private var pending = VisionPendingBuffer()
    private var enqueueReservations: [UUID: UUID] = [:]
    private var reservedPriorities: [UUID: JobPriority] = [:]
    private var pendingGeneration = 0
    private var admissionGeneration = 0
    private var isPersistentLoadInFlight = false
    private var persistentRefillNeeded = false
    private var refillRetryTask: Task<Void, Never>?
    private var failedActiveJobs: Set<UUID> = []
    private let storage: any VisionQueueStorage
    private let processor: (@Sendable (UUID) async throws -> Void)?
    private let configuredConcurrency: Int?
    private let observesEnvironment: Bool

    struct Diagnostics: Sendable {
        let residentPending: Int
        let processing: Int
        let reservations: Int
        let loading: Bool
        let refillNeeded: Bool
    }

    var diagnostics: Diagnostics {
        Diagnostics(residentPending: pending.count, processing: inProgress.count,
                    reservations: enqueueReservations.count, loading: isPersistentLoadInFlight,
                    refillNeeded: persistentRefillNeeded)
    }

    /// Currently processing item IDs
    private var inProgress: Set<UUID> = []

    /// Whether the queue is paused (no new processing starts)
    private var isPaused = false

    /// Recent errors (last 10)
    private var recentErrors: [ProcessingError] = []
    private let maxRecentErrors = 10

    /// Reference to database for updates
    private let database: DatabaseManager

    // MARK: - Scroll-Aware Pausing

    /// Whether the queue is paused due to active scrolling
    private var isPausedForScroll = false

    /// Task to resume after scroll ends (debounced)
    private var scrollResumeTask: Task<Void, Never>?

    /// Status publisher for UI observation
    @MainActor
    private let statusSubject = CurrentValueSubject<QueueStatus, Never>(.idle)

    /// Observable queue status
    @MainActor
    var status: AnyPublisher<QueueStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    /// Current status value
    @MainActor
    var currentStatus: QueueStatus {
        statusSubject.value
    }

    // MARK: - Initialization

    init(database: DatabaseManager = .shared,
         storage: (any VisionQueueStorage)? = nil,
         processor: (@Sendable (UUID) async throws -> Void)? = nil,
         concurrency: Int? = nil,
         observesEnvironment: Bool = true) {
        self.database = database
        self.storage = storage ?? DatabaseVisionQueueStorage(database: database)
        self.processor = processor
        self.configuredConcurrency = concurrency.map { max(1, $0) }
        self.observesEnvironment = observesEnvironment
        if observesEnvironment {
            Task { await setupMemoryPressureMonitor() }
            Task { await setupInteractionObserver() }
        }
    }

    deinit {
        memorySource?.setEventHandler(handler: nil)
        memorySource?.cancel()
        if let interactionObserver { NotificationCenter.default.removeObserver(interactionObserver) }
        scrollResumeTask?.cancel()
        refillRetryTask?.cancel()
    }

    // MARK: - Public API

    /// Enqueue an item for Vision processing
    /// - Parameters:
    ///   - itemId: The media item ID to process
    ///   - priority: Priority level (high for visible items)
    func enqueue(itemId: UUID, priority: JobPriority = .normal, force: Bool = false) async {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        guard force || !inProgress.contains(itemId) else { return }
        if enqueueReservations[itemId] != nil {
            reservedPriorities[itemId] = max(reservedPriorities[itemId] ?? priority, priority)
            return
        }
        if !force, let existing = pending.priority(itemId), existing >= priority { return }
        let reservation = UUID()
        enqueueReservations[itemId] = reservation
        reservedPriorities[itemId] = priority
        persistentRefillNeeded = true
        let generation = pendingGeneration
        defer {
            if enqueueReservations[itemId] == reservation {
                enqueueReservations.removeValue(forKey: itemId)
                reservedPriorities.removeValue(forKey: itemId)
            }
            processNext()
        }
        do {
            guard var job = try await storage.enqueue(itemId, priority: priority),
                  generation == pendingGeneration, enqueueReservations[itemId] == reservation else { return }
            while let promoted = reservedPriorities[itemId], promoted > job.priority {
                guard let updated = try await storage.enqueue(itemId, priority: promoted),
                      generation == pendingGeneration, enqueueReservations[itemId] == reservation else { return }
                job = updated
            }
            persistentRefillNeeded = true
            if !inProgress.contains(itemId),
               pending.contains(itemId) || pending.count < Self.maxResidentPendingJobs || pending.evictBelow(job.priority) {
                admissionGeneration += 1
                pending.append(job)
            }
        } catch {
            addError(ProcessingError(itemId: itemId, stage: "enqueue", message: error.localizedDescription))
        }

        await updateStatus()
        processNext()
    }

    /// Enqueue multiple items at once
    func enqueueBatch(_ itemIds: [UUID], priority: JobPriority = .normal) async {
        logInfo("Vision: enqueueing batch of \(itemIds.count) items at priority \(priority)")
        for itemId in itemIds {
            await enqueue(itemId: itemId, priority: priority)
        }
        logInfo("Vision: batch enqueue complete, pending=\(pending.count)")
    }

    /// Cancel processing for an item (removes from queue if pending)
    func cancel(itemId: UUID) async {
        // Invalidate a stale refill, but not unrelated enqueue reservations/promotion.
        // The per-item reservation token invalidates this item's suspended enqueue.
        admissionGeneration += 1
        enqueueReservations.removeValue(forKey: itemId)
        reservedPriorities.removeValue(forKey: itemId)
        pending.remove(itemId)
        do { try await storage.cancel(itemId) }
        catch { addError(ProcessingError(itemId: itemId, stage: "cancel", message: error.localizedDescription)) }
        // Note: Can't cancel in-progress items as Vision requests aren't interruptible
        await updateStatus()
        processNext()
    }

    /// Clear all pending items from queue
    func clearPending() async {
        pendingGeneration += 1
        enqueueReservations.removeAll()
        reservedPriorities.removeAll()
        pending.removeAll()
        persistentRefillNeeded = false
        refillRetryTask?.cancel()
        refillRetryTask = nil
        do { try await storage.clear(excluding: inProgress) }
        catch { addError(ProcessingError(itemId: UUID(), stage: "clear", message: error.localizedDescription)) }
        await updateStatus()
    }

    /// Pause the queue - no new processing will start
    /// In-flight jobs will complete but no new ones will begin
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        logInfo("Vision: queue paused")
    }

    /// Resume the queue - processing continues from where it left off
    func resume() {
        guard isPaused else { return }
        isPaused = false
        logInfo("Vision: queue resumed")
        processNext()
    }

    // MARK: - Scroll-Aware Pausing

    /// Pause processing during active scrolling.
    /// Call this when scroll starts to prevent Vision work from competing with thumbnail loading.
    func pauseForScroll() {
        isPausedForScroll = true
        scrollResumeTask?.cancel()
        scrollResumeTask = nil
    }

    /// Signal that scrolling has ended. Processing resumes after 500ms debounce.
    /// This prevents rapid scroll/stop cycles from causing thrashing.
    func onScrollEnded() {
        scrollResumeTask?.cancel()
        scrollResumeTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            isPausedForScroll = false
            processNext()
        }
    }

    /// Whether jobs can be processed (not paused by user AND not paused for scroll)
    private var canProcessJobs: Bool {
        !isPaused && !isPausedForScroll && inProgress.count < maxConcurrent
    }

    /// Re-queue items that were marked incomplete on last run
    func requeueIncomplete() async {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        let generation = pendingGeneration
        do {
            _ = try await storage.seedIncomplete()
            guard generation == pendingGeneration else { return }
            persistentRefillNeeded = true
            await loadNextPersistentBatch()
        } catch {
            addError(ProcessingError(
                itemId: UUID(),
                stage: "requeue",
                message: "Failed to fetch incomplete items: \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Processing

    /// Start processing the next item if capacity allows
    private func processNext() {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        refreshThroughputConfiguration()
        // Don't start new processing while paused (user pause or scroll pause).
        if isPaused || isPausedForScroll {
            logProcessNextDiagnostic(
                key: "paused-\(isPaused)-\(isPausedForScroll)",
                message: "processNext: paused (isPaused=\(isPaused), isPausedForScroll=\(isPausedForScroll)), skipping"
            )
            return
        }

        // Respect concurrency cap.
        guard inProgress.count < maxConcurrent else {
            logProcessNextDiagnostic(
                key: "capacity-\(inProgress.count)-\(maxConcurrent)",
                message: "processNext: at capacity (inProgress=\(inProgress.count), maxConcurrent=\(maxConcurrent))"
            )
            return
        }

        guard !pending.isEmpty else {
            if persistentRefillNeeded && inProgress.isEmpty && enqueueReservations.isEmpty && !isPersistentLoadInFlight && refillRetryTask == nil {
                Task { await self.loadNextPersistentBatch() }
            }
            logProcessNextDiagnostic(
                key: "idle-\(inProgress.count)-\(pending.count)",
                message: "processNext: nothing to do (inProgress=\(inProgress.count), pending=\(pending.count))"
            )
            return
        }

        let highOnly = observesEnvironment && AppInteractionMonitor.shared.shouldSuspendBackgroundProcessing()
        guard let job = pending.pop(highOnly: highOnly) else { return }
        admissionGeneration += 1
        inProgress.insert(job.itemId)
        lastProcessNextDiagnostic = nil
        logInfo("Vision: starting job \(job.itemId) (pending=\(pending.count), inProgress=\(inProgress.count))")

        // Spawn detached task for processing
        Task.detached(priority: taskPriority(for: job.priority)) { [weak self] in
            guard let self = self else {
                logError("Vision: self was deallocated!")
                return
            }
            await self.run(job)
        }

        // Try to fill remaining slots.
        if inProgress.count < maxConcurrent && !pending.isEmpty {
            processNext()
        }
    }

    private func loadNextPersistentBatch() async {
        guard !isPersistentLoadInFlight else { return }
        let capacity = Self.maxResidentPendingJobs - pending.count
        guard capacity > 0 else { return }
        isPersistentLoadInFlight = true
        let generation = pendingGeneration
        let admission = admissionGeneration
        defer {
            isPersistentLoadInFlight = false
            processNext()
        }
        do {
            let jobs = try await storage.load(limit: capacity, excluding: inProgress)
            guard generation == pendingGeneration else { return }
            guard admission == admissionGeneration else {
                persistentRefillNeeded = true
                return
            }
            // A completion or enqueue may have happened during this read. Keep refill armed
            // until an empty read with no active jobs proves the durable backlog has drained.
            persistentRefillNeeded = !jobs.isEmpty || !inProgress.isEmpty || !enqueueReservations.isEmpty
            for job in jobs where !inProgress.contains(job.itemId) && enqueueReservations[job.itemId] == nil {
                guard pending.count < Self.maxResidentPendingJobs else { break }
                pending.append(job)
            }
            await updateStatus()
        } catch {
            addError(ProcessingError(itemId: UUID(), stage: "requeue", message: error.localizedDescription))
            persistentRefillNeeded = true
            scheduleRefillRetry()
        }
    }

    private func scheduleRefillRetry() {
        guard refillRetryTask == nil else { return }
        refillRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            await self.retryPersistentLoad()
        }
    }

    private func retryPersistentLoad() {
        refillRetryTask = nil
        processNext()
    }

    private func run(_ job: VisionPendingJob) async {
        if let processor {
            do { try await processor(job.itemId) }
            catch { addError(ProcessingError(itemId: job.itemId, stage: "process", message: error.localizedDescription)) }
        } else {
            await process(job.itemId, priority: job.priority)
        }
        do { try await storage.finish(job, succeeded: !failedActiveJobs.contains(job.itemId)) }
        catch {
            addError(ProcessingError(itemId: job.itemId, stage: "finish", message: error.localizedDescription))
            scheduleRefillRetry()
        }
        failedActiveJobs.remove(job.itemId)
        await finishProcessing(job.itemId, priority: job.priority)
    }

    /// Interaction, queue, and memory notifications can all ask the actor to process the same
    /// unchanged state. Emit each blocked/idle state once instead of synchronously reopening the
    /// app log for every duplicate request.
    private func logProcessNextDiagnostic(key: String, message: @autoclosure () -> String) {
        guard key != lastProcessNextDiagnostic else { return }
        lastProcessNextDiagnostic = key
        logDebug(message())
    }

    /// Process a single item through all Vision stages.
    /// Processes ALL media files in the item (carousel support) plus an eligible context image.
    private func process(_ itemId: UUID, priority: JobPriority) async {
        CrashTelemetry.leave("vision-process \(itemId)")

        // Fetch ALL media files AND contextImage for this item
        let mediaURLs: [URL]
        let contextImageURL: URL?
        let capturedAssets: [ItemAsset]
        do {
            (mediaURLs, contextImageURL, capturedAssets) = try await database.write { db -> ([URL], URL?, [ItemAsset]) in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT mediaFilesJSON, contextImageString FROM media_items WHERE id = ?",
                    arguments: [itemId.uuidString]
                ) else {
                    return ([], nil, [])
                }

                let json: String = row["mediaFilesJSON"]
                let paths = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
                let urls = paths.map { URL(fileURLWithPath: $0) }

                let contextPath: String? = row["contextImageString"]
                let contextURL = contextPath.map { URL(fileURLWithPath: $0) }

                try ItemAssetStore.reconcile(in: db, itemID: itemId.uuidString)
                return (urls, contextURL, try ItemAssetStore.fetchBatch(in: db, itemIDs: [itemId])[itemId] ?? [])
            }
        } catch {
            addError(ProcessingError(
                itemId: itemId,
                stage: "fetch",
                message: "Database error: \(error.localizedDescription)"
            ))
            return
        }

        guard !mediaURLs.isEmpty || contextImageURL != nil else {
            addError(ProcessingError(
                itemId: itemId,
                stage: "fetch",
                message: "Item not found or has no media files or context image"
            ))
            return
        }

        if mediaURLs.isEmpty, contextImageURL != nil {
            logInfo("Vision: processing context-only item \(itemId)")
        }

        var sourcesToProcess = mediaURLs.enumerated().map { index, url in
            OCRSource(fileIndex: index, url: url, kind: .media)
        }
        if let contextImageURL {
            sourcesToProcess.append(OCRSource(
                fileIndex: mediaURLs.count,
                url: contextImageURL,
                kind: .contextImage
            ))
        }

        let ocrSourcesByIndex = Dictionary(uniqueKeysWithValues:
            Self.ocrSources(mediaURLs: mediaURLs, contextImageURL: contextImageURL)
                .map { ($0.fileIndex, $0) }
        )
        let ocrEligibleIndices = Set(ocrSourcesByIndex.keys)
        var processedFirstImage = false
        var firstImageResult: ProcessingResult?

        for source in sourcesToProcess {
            let index = source.fileIndex
            let url = source.url
            let sourceAssets = capturedAssets.filter { ItemAssetStore.canonicalPath($0.url.path) == ItemAssetStore.canonicalPath(url.path) }
            guard sourceAssets.count == 1, let sourceAsset = sourceAssets.first else { continue }

            // Check if file still exists (might have been deleted)
            guard FileManager.default.fileExists(atPath: url.path) else {
                addError(ProcessingError(
                    itemId: itemId,
                    stage: "validate",
                    message: "Media file not found: \(url.lastPathComponent)"
                ))
                continue
            }

            // Skip non-image files for OCR (video processing is separate)
            guard let ocrSource = ocrSourcesByIndex[index] else {
                if !processedFirstImage && ocrEligibleIndices.isEmpty {
                    // Video-only items without a still source can try direct hashing,
                    // but startup requeue should not loop forever if that never works.
                    let hashResult = await processHash(url: url, itemId: itemId)
                    if case .success(let hash) = hashResult, hash != nil {
                        firstImageResult = ProcessingResult(
                            ocrText: .success(nil),
                            ocrBlocks: .success([]),
                            colors: .success([VisionProcessor.ExtractedColor]()),
                            saliency: .success(nil),
                            hash: hashResult
                        )
                        processedFirstImage = true
                    }
                }
                continue
            }

            // Run OCR for this file
            let ocrResult = await processOCR(url: url, itemId: itemId)

            // Save per-file OCR to database
            await savePerFileOCR(
                itemId: itemId,
                fileIndex: index,
                fileURL: url.path,
                ocrResult: ocrResult,
                sourceKind: ocrSource.kind,
                assetID: sourceAsset.assetID
            )

            // For the first image, also run colors/saliency/hash
            // Note: feature vectors are now handled by PipelineQueue (CLIP 768D)
            if !processedFirstImage {
                async let colorsTask = processColors(url: url, itemId: itemId)
                async let saliencyTask = processSaliency(url: url, itemId: itemId)
                async let hashTask = processHash(url: url, itemId: itemId)

                firstImageResult = ProcessingResult(
                    ocrText: ocrResult.text,
                    ocrBlocks: ocrResult.blocks,
                    colors: await colorsTask,
                    saliency: await saliencyTask,
                    hash: await hashTask
                )
                processedFirstImage = true
            }
        }

        // Per-file writes already validate captured identity. Do not let an old
        // whole-item completion clean up or publish aggregate data after a
        // reorder/replacement that happened during async analysis.
        do {
            let current = try await database.write { db in
                try ItemAssetStore.reconcile(in: db, itemID: itemId.uuidString)
                return try ItemAssetStore.fetchBatch(in: db, itemIDs: [itemId])[itemId] ?? []
            }
            guard current == capturedAssets else { return }
        } catch { return }

        // Remove stale per-file OCR rows when media composition changes
        // (e.g., image removed/reordered or replaced with a non-image file).
        await cleanupPerFileOCRRows(itemId: itemId, validFileIndices: ocrEligibleIndices)

        // Update legacy database columns with first image results
        // (for backwards compatibility and search indexing)
        if let result = firstImageResult {
            await updateDatabase(itemId: itemId, result: result)
        }

        // Aggregate all per-file OCR text into media_items.ocrText for FTS indexing
        await aggregateOCRForSearch(itemId: itemId)
    }

    /// Aggregate all per-file OCR text into media_items.ocrText for full-text search indexing.
    /// This ensures carousel images (2, 3, 4+) are searchable via FTS5.
    private func aggregateOCRForSearch(itemId: UUID) async {
        do {
            try await database.write { db in
                // Query all per-file OCR text, ordered by file index
                let ocrTexts = try String.fetchAll(db, sql: """
                    SELECT ocr_text FROM media_file_ocr
                    WHERE item_id = ? AND ocr_text IS NOT NULL AND ocr_text != ''
                      AND association_state = 'attached'
                    ORDER BY file_index
                """, arguments: [itemId.uuidString])

                // Join with separator. Empty string means "processed, no text found".
                let aggregatedText = ocrTexts.isEmpty ? "" : ocrTexts.joined(separator: "\n\n---\n\n")

                // Update media_items.ocrText
                try db.execute(
                    sql: "UPDATE media_items SET ocrText = ? WHERE id = ?",
                    arguments: [aggregatedText, itemId.uuidString]
                )

                // Sync to FTS
                try self.syncToFTS(db: db, itemId: itemId)
            }
        } catch {
            addError(ProcessingError(
                itemId: itemId,
                stage: "aggregate-ocr",
                message: "Failed to aggregate OCR for search: \(error.localizedDescription)"
            ))
        }
    }

    /// Save per-file OCR data to the media_file_ocr table
    func savePerFileOCR(
        itemId: UUID,
        fileIndex: Int,
        fileURL: String,
        ocrResult: OCRProcessingResult,
        sourceKind: OCRSource.Kind = .media,
        assetID: UUID? = nil
    ) async {
        let ocrText: String?
        let ocrBlocks: [SerializableTextBlock]?
        let textSucceeded: Bool
        let blocksSucceeded: Bool

        if case .success(let text) = ocrResult.text {
            textSucceeded = true
            ocrText = text
        } else {
            textSucceeded = false
            ocrText = nil
        }

        if case .success(let blocks) = ocrResult.blocks {
            blocksSucceeded = true
            ocrBlocks = blocks.isEmpty ? nil : blocks.map { SerializableTextBlock(from: $0) }
        } else {
            blocksSucceeded = false
            ocrBlocks = nil
        }

        // Clear only when OCR completed successfully and explicitly found no text.
        // On OCR failure, keep existing data to avoid wiping previously indexed content.
        let preserveEmptyResult = sourceKind == .contextImage
        let shouldClearExistingRow = textSucceeded && blocksSucceeded && ocrText == nil && ocrBlocks == nil
        if shouldClearExistingRow && !preserveEmptyResult {
            do {
                try await database.write { db in
                    let asset = try ItemAssetStore.prepareWrite(in: db, itemID: itemId, assetID: assetID, path: fileURL, index: fileIndex)
                    try db.execute(
                        sql: "DELETE FROM media_file_ocr WHERE item_id = ? AND asset_id = ? AND association_state = 'attached'",
                        arguments: [itemId.uuidString, asset.id.uuidString]
                    )
                }
            } catch {
                addError(ProcessingError(
                    itemId: itemId,
                    stage: "save-ocr",
                    message: "Failed to clear per-file OCR: \(error.localizedDescription)"
                ))
            }
            return
        }

        // OCR failed and produced nothing: keep existing row as-is.
        let shouldPersistEmptyResult = preserveEmptyResult && textSucceeded && blocksSucceeded
        guard ocrText != nil || ocrBlocks != nil || shouldPersistEmptyResult else { return }

        do {
            try await database.write { db in
                let record = MediaFileOCRRecord(
                    itemId: itemId,
                    fileURL: fileURL,
                    fileIndex: fileIndex,
                    ocrText: ocrText,
                    ocrBlocks: ocrBlocks,
                    assetID: assetID
                )
                try record.upsert(db: db)
            }
        } catch {
            addError(ProcessingError(
                itemId: itemId,
                stage: "save-ocr",
                message: "Failed to save per-file OCR: \(error.localizedDescription)"
            ))
        }
    }

    /// Remove per-file OCR rows for file indexes that are no longer OCR-eligible.
    private func cleanupPerFileOCRRows(itemId: UUID, validFileIndices: Set<Int>) async {
        do {
            try await database.write { db in
                if validFileIndices.isEmpty {
                    try db.execute(
                        sql: "DELETE FROM media_file_ocr WHERE item_id = ? AND association_state = 'attached'",
                        arguments: [itemId.uuidString]
                    )
                    return
                }

                let sortedIndices = validFileIndices.sorted()
                let placeholders = sortedIndices.map { _ in "?" }.joined(separator: ", ")
                var arguments: [DatabaseValueConvertible] = [itemId.uuidString]
                arguments.append(contentsOf: sortedIndices)

                try db.execute(
                    sql: "DELETE FROM media_file_ocr WHERE item_id = ? AND association_state = 'attached' AND file_index NOT IN (\(placeholders))",
                    arguments: StatementArguments(arguments)
                )
            }
        } catch {
            addError(ProcessingError(
                itemId: itemId,
                stage: "cleanup-ocr",
                message: "Failed to clean stale per-file OCR rows: \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - Individual Stage Processing

    /// OCR result containing both text and blocks
    struct OCRProcessingResult: Sendable {
        let text: Result<String?, Error>
        let blocks: Result<[TextBlock], Error>
    }

    private func processOCR(url: URL, itemId: UUID) async -> OCRProcessingResult {
        do {
            let result = try await VisionProcessor.extractOCRWithRegions(from: url)
            return OCRProcessingResult(
                text: .success(result.text),
                blocks: .success(result.blocks)
            )
        } catch {
            addError(ProcessingError(
                itemId: itemId,
                stage: "OCR",
                message: error.localizedDescription
            ))
            return OCRProcessingResult(
                text: .failure(error),
                blocks: .failure(error)
            )
        }
    }

    private func processColors(url: URL, itemId: UUID) async -> Result<[VisionProcessor.ExtractedColor], Error> {
        do {
            let colors = try await VisionProcessor.extractDominantColors(from: url)
            return .success(colors)
        } catch {
            addError(ProcessingError(
                itemId: itemId,
                stage: "colors",
                message: error.localizedDescription
            ))
            // Fallback to gray on failure
            return .success([VisionProcessor.ExtractedColor(bucket: .gray, r: 128, g: 128, b: 128, prominence: 1.0)])
        }
    }

    private func processSaliency(url: URL, itemId: UUID) async -> Result<CGRect?, Error> {
        do {
            let rect = try await VisionProcessor.extractSaliencyRect(from: url)
            return .success(rect)
        } catch {
            addError(ProcessingError(
                itemId: itemId,
                stage: "saliency",
                message: error.localizedDescription
            ))
            // Null saliency is fine - will use center crop
            return .success(nil)
        }
    }

    private func processHash(url: URL, itemId: UUID) async -> Result<String?, Error> {
        do {
            let hash = try await PerceptualHash.computeHash(from: url)
            return .success(hash)
        } catch {
            addError(ProcessingError(
                itemId: itemId,
                stage: "hash",
                message: error.localizedDescription
            ))
            return .failure(error)
        }
    }

    // MARK: - Database Updates

    private func updateDatabase(itemId: UUID, result: ProcessingResult) async {
        do {
            try await database.write { [result] db in
                // Build update SQL dynamically based on what succeeded
                var updates: [String] = []
                var arguments: [any DatabaseValueConvertible] = []

                if case .success(let text) = result.ocrText {
                    updates.append("ocrText = ?")
                    // Use empty string for "no text found" to distinguish from "not processed"
                    // This prevents items without text from being requeued forever
                    arguments.append(text ?? "")
                }

                // Store OCR blocks (serialized as JSON)
                if case .success(let blocks) = result.ocrBlocks {
                    let json: String?
                    if !blocks.isEmpty {
                        // Legacy column stores OCRTextRegion[] for backward compatibility.
                        let regions = blocks.map { block in
                            OCRTextRegion(
                                text: block.text,
                                boundingBox: block.boundingBox,
                                confidence: block.confidence
                            )
                        }
                        json = (try? JSONEncoder().encode(regions))
                            .flatMap { String(data: $0, encoding: .utf8) }
                    } else {
                        json = nil
                    }
                    updates.append("ocrBoundingBoxesJSON = ?")
                    if let json = json {
                        arguments.append(json)
                    } else {
                        arguments.append(DatabaseValue.null)
                    }
                }

                if case .success(let colors) = result.colors, !colors.isEmpty {
                    // Store bucket names in JSON for backward compatibility
                    let bucketNames = colors.map { $0.bucket.rawValue }
                    let json = (try? JSONEncoder().encode(bucketNames))
                        .flatMap { String(data: $0, encoding: .utf8) }
                    updates.append("dominantColorsJSON = ?")
                    if let json = json {
                        arguments.append(json)
                    } else {
                        arguments.append(DatabaseValue.null)
                    }
                }

                if case .success(let rect) = result.saliency {
                    let json: String?
                    if let rect = rect {
                        let serializable = SerializableCGRect(rect: rect)
                        json = (try? JSONEncoder().encode(serializable))
                            .flatMap { String(data: $0, encoding: .utf8) }
                    } else {
                        json = nil
                    }
                    updates.append("saliencyRectJSON = ?")
                    if let json = json {
                        arguments.append(json)
                    } else {
                        arguments.append(DatabaseValue.null)
                    }
                }

                if case .success(let hash) = result.hash {
                    updates.append("perceptualHash = ?")
                    if let hash = hash {
                        arguments.append(hash)
                    } else {
                        arguments.append(DatabaseValue.null)
                    }
                }

                guard !updates.isEmpty else { return }

                arguments.append(itemId.uuidString)
                let sql = "UPDATE media_items SET \(updates.joined(separator: ", ")) WHERE id = ?"
                try db.execute(sql: sql, arguments: StatementArguments(arguments))

                // Sync to FTS
                if case .success(let text) = result.ocrText, text != nil {
                    try self.syncToFTS(db: db, itemId: itemId)
                }

                // Sync colors to junction table for filtering
                if case .success(let colors) = result.colors, !colors.isEmpty {
                    try self.syncColorsToJunctionTable(db: db, itemId: itemId, colors: colors)
                }

                // Note: Feature vectors now handled by PipelineQueue (CLIP 768D embeddings)
            }
        } catch {
            addError(ProcessingError(
                itemId: itemId,
                stage: "database",
                message: "Failed to update: \(error.localizedDescription)"
            ))
        }
    }

    /// No-op: FTS is content-synced with triggers (migration 24).
    /// The UPDATE on media_items that sets ocrText triggers automatic FTS sync.
    private nonisolated func syncToFTS(db: Database, itemId: UUID) throws {
        // Content-synced FTS5 uses triggers; manual sync is not needed.
    }

    /// Sync colors to junction table for fast filtering (nonisolated to be callable from database closure)
    /// Stores both bucket classification and actual RGB values for precision color search
    private nonisolated func syncColorsToJunctionTable(db: Database, itemId: UUID, colors: [VisionProcessor.ExtractedColor]) throws {
        // Delete existing colors for this item
        try db.execute(
            sql: "DELETE FROM media_colors WHERE item_id = ?",
            arguments: [itemId.uuidString]
        )

        // Insert each color with RGB values
        for color in colors {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO media_colors
                    (item_id, color_bucket, rgb_r, rgb_g, rgb_b, prominence)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    itemId.uuidString,
                    color.bucket.rawValue,
                    Int(color.r),
                    Int(color.g),
                    Int(color.b),
                    color.prominence
                ]
            )
        }
    }

    // MARK: - Status Management

    private func addError(_ error: ProcessingError) {
        if inProgress.contains(error.itemId) { failedActiveJobs.insert(error.itemId) }
        recentErrors.append(error)
        if recentErrors.count > maxRecentErrors {
            recentErrors.removeFirst()
        }
        Task {
            await updateStatus()
        }
    }

    private func updateStatus() async {
        let processingCount = inProgress.count
        let queuedCount = pending.count
        let errors = recentErrors

        await MainActor.run {
            let status = QueueStatus(
                processing: processingCount,
                queued: queuedCount,
                recentErrors: errors
            )
            statusSubject.send(status)
        }
    }

    // MARK: - Memory Pressure

    private func setupMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data
            Task {
                if event.contains(.critical) {
                    await self.handleMemoryPressure(.critical)
                } else if event.contains(.warning) {
                    await self.handleMemoryPressure(.warning)
                } else {
                    await self.handleMemoryPressure(.normal)
                }
            }
        }
        source.resume()
        memorySource = source
    }

    private func handleMemoryPressure(_ tier: MemoryPressureTier) {
        guard tier != memoryTier else { return }
        memoryTier = tier

        refreshThroughputConfiguration()

        switch tier {
        case .normal:
            logInfo("Vision: memory normal, restoring \(maxConcurrent) concurrent")
        case .warning:
            logInfo("Vision: memory warning, throttling to \(maxConcurrent) concurrent")
        case .critical:
            logWarning("Vision: memory critical, throttling to \(maxConcurrent) concurrent")
        }

        processNext()
    }

    private func refreshThroughputConfiguration() {
        if let configuredConcurrency {
            maxConcurrent = configuredConcurrency
            return
        }
        let intensity = BackgroundProcessingIntensity.current

        switch memoryTier {
        case .normal:
            maxConcurrent = intensity.visionNormalConcurrency
        case .warning:
            maxConcurrent = intensity.visionWarningConcurrency
        case .critical:
            maxConcurrent = intensity.visionCriticalConcurrency
        }
    }

    private func setupInteractionObserver() {
        interactionObserver = NotificationCenter.default.addObserver(
            forName: .appInteractionStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.processNext() }
        }
    }

    private func taskPriority(for priority: JobPriority) -> TaskPriority {
        priority == .high ? .utility : BackgroundProcessingIntensity.current.taskPriority
    }

    private func interJobDelay(after priority: JobPriority) -> Duration {
        priority == .high ? .zero : BackgroundProcessingIntensity.current.visionInterJobDelay
    }

    private func finishProcessing(_ itemId: UUID, priority: JobPriority) async {
        inProgress.remove(itemId)
        logInfo("Vision: finished \(itemId) (remaining: \(pending.count) pending, \(inProgress.count) in progress)")
        await updateStatus()

        // Trigger downstream ML pipeline once vision-stage extraction is complete.
        if observesEnvironment, let pipelineQueue = PipelineQueue.sharedIfConfigured {
            await pipelineQueue.enqueue(itemId: itemId)
        }

        // Notify UI
        if observesEnvironment { await MainActor.run {
            NotificationCenter.default.post(
                name: .mediaStoreDidChange,
                object: nil,
                userInfo: ["itemId": itemId]
            )
        } }

        let delay = observesEnvironment ? interJobDelay(after: priority) : .zero
        if delay == .zero {
            processNext()
            return
        }

        Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(for: delay)
            await self.processNext()
        }
    }
}

// MARK: - Convenience Extensions

extension VisionJobQueue {

    /// Process a single item and wait for completion
    func processAndWait(itemId: UUID) async {
        await enqueue(itemId: itemId, priority: .high)

        // Poll until not in progress
        while await isQueued(itemId) {
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
    }

    /// Check if an item is currently being processed
    func isProcessing(_ itemId: UUID) -> Bool {
        inProgress.contains(itemId)
    }

    /// Check if an item is in the queue (pending or processing)
    func isQueued(_ itemId: UUID) async -> Bool {
        if inProgress.contains(itemId) || pending.contains(itemId) || enqueueReservations[itemId] != nil { return true }
        return (try? await storage.contains(itemId)) ?? false
    }

    /// Sync existing color data from dominantColorsJSON to the media_colors junction table.
    /// Fast operation - doesn't re-extract colors, just populates the junction table for filtering.
    func syncColorsToJunctionTable() async {
        logInfo("Vision: Syncing colors to junction table")

        do {
            let count = try await database.write { db -> Int in
                // Clear existing junction table entries
                try db.execute(sql: "DELETE FROM media_colors")

                // Populate from existing dominantColorsJSON
                try db.execute(sql: """
                    INSERT INTO media_colors (item_id, color_bucket)
                    SELECT id, json_each.value
                    FROM media_items, json_each(dominantColorsJSON)
                    WHERE dominantColorsJSON IS NOT NULL AND dominantColorsJSON != '[]'
                """)

                return try Int.fetchOne(db, sql: "SELECT changes()") ?? 0
            }
            logInfo("Vision: Synced \(count) color entries to junction table")
        } catch {
            addError(ProcessingError(
                itemId: UUID(),
                stage: "sync-colors",
                message: "Failed to sync colors: \(error.localizedDescription)"
            ))
        }
    }

    /// Re-index colors for all items using the expanded color bucket system.
    /// Clears dominantColorsJSON for all items and requeues them for processing.
    /// Use this after updating the color classification system.
    func reindexAllColors() async {
        logInfo("Vision: Starting color re-index for all items")

        do {
            // Clear dominantColorsJSON for all items
            let count = try await database.write { db -> Int in
                try db.execute(sql: "UPDATE media_items SET dominantColorsJSON = NULL")
                let count = db.changesCount
                try db.execute(sql: """
                    INSERT INTO vision_pending_jobs(item_id, priority)
                    SELECT id, 0 FROM (\(Self.requeueIncompleteSQL)) WHERE true
                    ON CONFLICT(item_id) DO UPDATE SET retry_count = 0, revision = revision + 1
                    """)
                return count
            }
            logInfo("Vision: Cleared colors for \(count) items")
            pendingGeneration += 1
            pending.removeAll()

            // Requeue incomplete items (which now includes all items with NULL colors)
            await requeueIncomplete()
            logInfo("Vision: Color re-index queued")
        } catch {
            addError(ProcessingError(
                itemId: UUID(),
                stage: "reindex-colors",
                message: "Failed to clear colors: \(error.localizedDescription)"
            ))
        }
    }

    /// Force reprocess OCR for an item, even if it already has OCR text.
    /// Use this to regenerate OCR with bounding boxes for items processed before that feature existed.
    /// Clears both legacy OCR data and per-file OCR data.
    /// - Parameter itemId: The media item ID to reprocess
    /// Bulk reprocess ALL OCR: clears OCR data for every item and re-queues them.
    /// Used when the OCR pipeline changes (e.g. quality filter added).
    /// Returns the number of items queued.
    @discardableResult
    func reprocessAllOCR() async -> Int {
        do {
            let count = try await database.write { db -> Int in
                // Clear all legacy OCR columns
                try db.execute(sql: """
                    UPDATE media_items
                    SET ocrText = NULL, ocrBoundingBoxesJSON = NULL
                    WHERE (mediaFilesJSON != '[]'
                           OR (contextImageString IS NOT NULL AND contextImageString != ''))
                """)
                // Regenerate current results without discarding retained legacy evidence.
                try db.execute(sql: "DELETE FROM media_file_ocr WHERE association_state = 'attached'")

                // Persist the entire request in the same transaction without fetching all IDs.
                try db.execute(sql: """
                    INSERT INTO vision_pending_jobs(item_id, priority)
                    SELECT id, 0 FROM media_items
                    WHERE (mediaFilesJSON != '[]'
                           OR (contextImageString IS NOT NULL AND contextImageString != ''))
                    AND (deletedAt IS NULL OR deletedAt = '')
                    ON CONFLICT(item_id) DO UPDATE SET retry_count = 0, revision = revision + 1
                """)
                return db.changesCount
            }

            Log.info("Bulk OCR reprocess: durably queued \(count) items")
            pendingGeneration += 1
            pending.removeAll()
            persistentRefillNeeded = true
            await loadNextPersistentBatch()
            return count
        } catch {
            Log.error("Bulk OCR reprocess failed: \(error)")
            return 0
        }
    }

    func reprocessOCR(itemId: UUID) async {
        // Clear existing OCR data first so the item will be fully reprocessed
        do {
            try await database.write { db in
                // Clear legacy OCR columns
                try db.execute(
                    sql: "UPDATE media_items SET ocrText = NULL, ocrBoundingBoxesJSON = NULL WHERE id = ?",
                    arguments: [itemId.uuidString]
                )
                // Clear per-file OCR data
                try MediaFileOCRRecord.deleteAll(db: db, itemId: itemId)
                try db.execute(sql: """
                    INSERT INTO vision_pending_jobs(item_id, priority)
                    SELECT id, 2 FROM media_items WHERE id = ? AND (deletedAt IS NULL OR deletedAt = '')
                    ON CONFLICT(item_id) DO UPDATE SET priority = 2, retry_count = 0, revision = revision + 1
                    """, arguments: [itemId.uuidString])
            }
        } catch {
            addError(ProcessingError(
                itemId: itemId,
                stage: "reprocess-clear",
                message: "Failed to clear existing OCR: \(error.localizedDescription)"
            ))
            return
        }

        // Now enqueue for processing with high priority
        await enqueue(itemId: itemId, priority: .high, force: true)
    }
}
