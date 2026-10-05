import Foundation
import AVFoundation
import Combine
import GRDB
import PhotoPipeline

// MARK: - Video Understanding Status

struct VideoUnderstandingQueueStatus: Sendable, Equatable {
    let processing: Int
    let queued: Int
    let phase: String

    static let idle = VideoUnderstandingQueueStatus(processing: 0, queued: 0, phase: "idle")

    var isIdle: Bool { processing == 0 && queued == 0 && phase == "idle" }

    var displayText: String {
        if isIdle { return "" }
        return "Video: \(processing) processing, \(queued) queued (\(phase))"
    }
}

struct VideoUnderstandingQueueDiagnostics: Sendable, Equatable {
    let singleEligibilityQueryCount: Int
    let persistentBatchQueryCount: Int
    let duplicateEnqueueDropCount: Int
    let residentPendingCount: Int
    let hasDurableOverflow: Bool
    let compactedElementCount: Int
}

private enum VideoUnderstandingError: LocalizedError {
    case noVideo(UUID)
    case videoMissing(String)
    case noSegments(UUID)

    var errorDescription: String? {
        switch self {
        case .noVideo(let itemId):
            return "No video media found for item \(itemId)"
        case .videoMissing(let path):
            return "Video file not found: \(URL(fileURLWithPath: path).lastPathComponent)"
        case .noSegments(let itemId):
            return "No video segments produced for item \(itemId)"
        }
    }
}

// MARK: - Video Understanding Queue

actor VideoUnderstandingQueue {
    nonisolated(unsafe) private static var _shared: VideoUnderstandingQueue?

    nonisolated static var shared: VideoUnderstandingQueue {
        guard let instance = _shared else {
            fatalError("VideoUnderstandingQueue.shared accessed before setShared(_:) was called")
        }
        return instance
    }

    nonisolated static var sharedIfConfigured: VideoUnderstandingQueue? {
        _shared
    }

    nonisolated static func setShared(_ queue: VideoUnderstandingQueue) {
        _shared = queue
    }

    nonisolated static var isConfigured: Bool {
        _shared != nil
    }

    private static let maxRetries = 3
    /// Incomplete work remains durable in `media_items`; only this bounded window is resident.
    static let maxResidentPendingJobs = 512
    // PhotoPipeline analyzes these containers directly through AVFoundation. WebM
    // enters PhotoPipeline only after bounded ffmpeg frame sampling into MOV.
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv"]
    private static let derivedVideoExtensions: Set<String> = ["webm"]
    static let videoMediaPredicateSQL = mediaPredicateSQL(
        extensions: videoExtensions.union(derivedVideoExtensions)
    )

    private let database: DatabaseManager
    private let analyzer: VideoAnalyzer
    private let webMExtractor: WebMDerivedAssetExtractor
    private let webMWorkCoordinator: WebMBackgroundWorkCoordinator

    private var pending = DeduplicatingFIFOBuffer<UUID>()
    private var pendingWebMStreamInfo: [UUID: WebMStreamInfo] = [:]
    private var inProgress: Set<UUID> = []
    private var enqueueReservations: Set<UUID> = []
    private var pendingGeneration = 0
    private var isPersistentLoadInFlight = false
    private var persistentLoadRequestedWhileInFlight = false
    private var persistentRefillNeeded = false
    private var excludedFromPersistentRefill: Set<UUID> = []
    private var lastServiceError: String?
    private var singleEligibilityQueryCount = 0
    private var persistentBatchQueryCount = 0
    private var duplicateEnqueueDropCount = 0
    private var processingTask: Task<Void, Never>?
    private var processingItemId: UUID?
    private var discardCancelledItems: Set<UUID> = []
    private var isPaused = false
    private var isInteractionSuspended = false
    private var memorySource: DispatchSourceMemoryPressure?
    private var interactionObserver: NSObjectProtocol?

    @MainActor
    private let statusSubject = CurrentValueSubject<VideoUnderstandingQueueStatus, Never>(.idle)

    @MainActor
    var status: AnyPublisher<VideoUnderstandingQueueStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    @MainActor
    var currentStatus: VideoUnderstandingQueueStatus {
        statusSubject.value
    }

    init(
        database: DatabaseManager = .shared,
        analyzer: VideoAnalyzer = VideoAnalyzer(),
        webMExtractor: WebMDerivedAssetExtractor = WebMDerivedAssetExtractor(),
        webMWorkCoordinator: WebMBackgroundWorkCoordinator = .shared
    ) {
        self.database = database
        self.analyzer = analyzer
        self.webMExtractor = webMExtractor
        self.webMWorkCoordinator = webMWorkCoordinator
        Task { await setupMemoryPressureMonitor() }
        Task { await setupInteractionObserver() }
    }

    deinit {
        memorySource?.setEventHandler(handler: nil)
        memorySource?.cancel()
        if let interactionObserver { NotificationCenter.default.removeObserver(interactionObserver) }
    }

    nonisolated static func requiresDerivedAsset(for url: URL) -> Bool {
        derivedVideoExtensions.contains(url.pathExtension.lowercased())
    }

    func enqueue(itemId: UUID, force: Bool = false) async {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        guard !inProgress.contains(itemId),
              !pending.contains(itemId),
              !enqueueReservations.contains(itemId) else {
            duplicateEnqueueDropCount += 1
            return
        }

        excludedFromPersistentRefill.remove(itemId)
        enqueueReservations.insert(itemId)
        let generation = pendingGeneration
        defer { enqueueReservations.remove(itemId) }

        var probedStreamInfo: WebMStreamInfo?
        do {
            singleEligibilityQueryCount += 1
            let shouldQueue = try await database.read { db -> Bool in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT mediaFilesJSON,
                               video_understanding_status,
                               video_understanding_version,
                               video_understanding_retry_count
                        FROM media_items
                        WHERE id = ?
                          AND (deletedAt IS NULL OR deletedAt = '')
                    """,
                    arguments: [itemId.uuidString]
                ) else { return false }

                let mediaFilesJSON: String = row["mediaFilesJSON"]
                let status: String? = row["video_understanding_status"]
                let version: Int? = row["video_understanding_version"]
                let retries: Int? = row["video_understanding_retry_count"]

                guard Self.firstVideoPath(in: mediaFilesJSON) != nil else { return false }
                if (retries ?? 0) >= Self.maxRetries && !force { return false }
                return force ||
                    status != "complete" ||
                    (version ?? 0) < VideoTimelineBuilder.currentVersion
            }

            guard shouldQueue, !Task.isCancelled else { return }
            guard generation == pendingGeneration else {
                persistentRefillNeeded = true
                Task { await self.loadNextPersistentBatch() }
                return
            }

            let target = try await loadVideoTarget(itemId)
            if Self.requiresDerivedAsset(for: target.url),
               FileManager.default.fileExists(atPath: target.url.path) {
                do {
                    let streamInfo = try await webMExtractor.probeStreams(in: target.url)
                    if !streamInfo.hasVideo {
                        guard generation == pendingGeneration else {
                            persistentRefillNeeded = true
                            Task { await self.loadNextPersistentBatch() }
                            return
                        }
                        logInfo("VideoUnderstandingQueue: \(target.url.lastPathComponent) has no video stream; excluding it from video analysis")
                        try await markNoVideoComplete(itemId: itemId)
                        await notifyItemChanged(itemId)
                        return
                    }
                    probedStreamInfo = streamInfo
                } catch is CancellationError {
                    return
                } catch {
                    // Extraction probes again inside the cancellable processing
                    // task. A transient eligibility-probe failure must not make
                    // a potentially valid video permanently ineligible.
                    logWarning("VideoUnderstandingQueue: stream eligibility probe failed for \(target.url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            // Check compatibility before reset so a forced WebM enqueue cannot
            // erase preserved analysis state.
            if force {
                try await resetItem(itemId)
            }
            guard !Task.isCancelled else { return }
            guard generation == pendingGeneration else {
                persistentRefillNeeded = true
                Task { await self.loadNextPersistentBatch() }
                return
            }
        } catch {
            lastServiceError = String(error.localizedDescription.prefix(1_000))
            logError("VideoUnderstandingQueue: enqueue eligibility failed for \(itemId): \(error.localizedDescription)")
            await updateStatus()
            return
        }

        // A full in-memory window is not data loss: the reset/incomplete database row remains
        // eligible for a later persistent refill.
        guard residentPendingCount < Self.maxResidentPendingJobs else {
            persistentRefillNeeded = true
            return
        }

        guard !inProgress.contains(itemId), pending.append(itemId) else {
            duplicateEnqueueDropCount += 1
            return
        }
        if let probedStreamInfo {
            pendingWebMStreamInfo[itemId] = probedStreamInfo
        }
        lastServiceError = nil
        await updateStatus()
        processNext()
    }

    func requeueIncomplete() async {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        excludedFromPersistentRefill.removeAll(keepingCapacity: true)
        pendingGeneration &+= 1
        await loadNextPersistentBatch()
    }

    @discardableResult
    func reprocessAll() async -> Int {
        pendingGeneration &+= 1
        excludedFromPersistentRefill.removeAll(keepingCapacity: true)
        do {
            let count = try await database.write { db -> Int in
                let count = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM media_items
                        WHERE (deletedAt IS NULL OR deletedAt = '')
                          AND \(Self.videoMediaPredicateSQL)
                    """
                ) ?? 0

                try db.execute(sql: """
                    DELETE FROM video_segments
                    WHERE association_state = 'attached' AND item_id IN (
                        SELECT id FROM media_items
                        WHERE (deletedAt IS NULL OR deletedAt = '')
                          AND \(Self.videoMediaPredicateSQL)
                    )
                """)
                try db.execute(sql: """
                    UPDATE media_items
                    SET video_understanding_status = 'none',
                        video_understanding_version = 0,
                        video_understanding_retry_count = 0,
                        video_understanding_last_error = NULL,
                        video_understanding_failed_at = NULL
                    WHERE (deletedAt IS NULL OR deletedAt = '')
                      AND \(Self.videoMediaPredicateSQL)
                """)

                return count
            }

            persistentRefillNeeded = count > residentPendingCount
            await loadNextPersistentBatch()
            return count
        } catch {
            lastServiceError = String(error.localizedDescription.prefix(1_000))
            logError("VideoUnderstandingQueue: reprocess all failed: \(error.localizedDescription)")
            await updateStatus()
            return 0
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        processingTask?.cancel()
        logInfo("VideoUnderstandingQueue: paused")
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        logInfo("VideoUnderstandingQueue: resumed")
        processNext()
    }

    func clear(itemId: UUID) async {
        pendingGeneration &+= 1
        excludedFromPersistentRefill.insert(itemId)
        pending.removeAll { $0 == itemId }
        pendingWebMStreamInfo.removeValue(forKey: itemId)
        if processingItemId == itemId {
            discardCancelledItems.insert(itemId)
            processingTask?.cancel()
        }
        try? await resetItem(itemId)
        await updateStatus()
    }

    func diagnostics() -> VideoUnderstandingQueueDiagnostics {
        VideoUnderstandingQueueDiagnostics(
            singleEligibilityQueryCount: singleEligibilityQueryCount,
            persistentBatchQueryCount: persistentBatchQueryCount,
            duplicateEnqueueDropCount: duplicateEnqueueDropCount,
            residentPendingCount: residentPendingCount,
            hasDurableOverflow: persistentRefillNeeded,
            compactedElementCount: pending.compactedElementCount
        )
    }

    func interactionStateDidChange(_ state: AppInteractionMonitor.State) {
        let shouldSuspend = state == .foregroundInteracting
        guard shouldSuspend != isInteractionSuspended else {
            if !shouldSuspend { processNext() }
            return
        }

        isInteractionSuspended = shouldSuspend
        if shouldSuspend {
            processingTask?.cancel()
            logInfo("VideoUnderstandingQueue: yielding active work for interaction")
        } else {
            processNext()
        }
    }

    private var residentPendingCount: Int {
        pending.count
    }

    private func processNext() {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        guard !isPaused,
              !isInteractionSuspended,
              !AppInteractionMonitor.shared.shouldSuspendBackgroundProcessing(),
              inProgress.isEmpty,
              processingTask == nil else { return }

        guard let itemId = pending.popFirst() else {
            if persistentRefillNeeded {
                Task { await self.loadNextPersistentBatch() }
            }
            return
        }
        inProgress.insert(itemId)
        processingItemId = itemId

        processingTask = Task.detached(priority: .utility) {
            await self.processItem(itemId)
        }
        Task { await updateStatus() }
    }

    /// Restores one bounded FIFO window directly from durable state. WebM stream validation stays
    /// in the cancellable processing task (and the direct-force path), so startup does not launch
    /// hundreds of ffprobe processes merely to construct the resident queue.
    private func loadNextPersistentBatch() async {
        guard !isPersistentLoadInFlight else {
            persistentLoadRequestedWhileInFlight = true
            return
        }

        isPersistentLoadInFlight = true
        let generation = pendingGeneration
        let residentIDs = pendingItemIDs()
        var excludedIDs = Set(residentIDs)
        excludedIDs.formUnion(inProgress)
        excludedIDs.formUnion(enqueueReservations)
        excludedIDs.formUnion(excludedFromPersistentRefill)
        let availableCapacity = max(0, Self.maxResidentPendingJobs - residentPendingCount)
        let queryLimit = max(1, availableCapacity + 1)
        let currentVersion = VideoTimelineBuilder.currentVersion
        let maxRetries = Self.maxRetries

        defer {
            let shouldReload = persistentLoadRequestedWhileInFlight
            persistentLoadRequestedWhileInFlight = false
            isPersistentLoadInFlight = false
            if shouldReload {
                Task { await self.loadNextPersistentBatch() }
            }
        }

        do {
            persistentBatchQueryCount += 1
            let sortedExcludedIDs = excludedIDs.sorted { $0.uuidString < $1.uuidString }
            let exclusionClause: String
            if sortedExcludedIDs.isEmpty {
                exclusionClause = ""
            } else {
                let placeholders = sortedExcludedIDs.map { _ in "?" }.joined(separator: ", ")
                exclusionClause = "AND id NOT IN (\(placeholders))"
            }

            var arguments: [DatabaseValueConvertible] = [currentVersion, maxRetries]
            arguments.append(contentsOf: sortedExcludedIDs.map(\.uuidString))
            arguments.append(queryLimit)
            let statementArguments = StatementArguments(arguments)!

            let itemIds = try await database.read { db -> [UUID] in
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT id FROM media_items
                        WHERE (deletedAt IS NULL OR deletedAt = '')
                          AND \(Self.videoMediaPredicateSQL)
                          AND (
                              video_understanding_status IS NULL
                              OR video_understanding_status IN ('none', 'failed', 'processing')
                              OR COALESCE(video_understanding_version, 0) < ?
                          )
                          AND COALESCE(video_understanding_retry_count, 0) < ?
                          \(exclusionClause)
                        ORDER BY archivedDate DESC, id ASC
                        LIMIT ?
                    """,
                    arguments: statementArguments
                ).compactMap(UUID.init(uuidString:))
            }

            guard generation == pendingGeneration else {
                persistentRefillNeeded = true
                persistentLoadRequestedWhileInFlight = true
                return
            }

            let currentCapacity = max(0, Self.maxResidentPendingJobs - residentPendingCount)
            let candidates = itemIds.filter {
                !inProgress.contains($0) &&
                    !pending.contains($0) &&
                    !enqueueReservations.contains($0) &&
                    !excludedFromPersistentRefill.contains($0)
            }
            let accepted = candidates.prefix(currentCapacity)
            let addedCount = pending.append(contentsOf: accepted)
            persistentRefillNeeded = itemIds.count == queryLimit || candidates.count > currentCapacity
            lastServiceError = nil

            logInfo(
                "VideoUnderstandingQueue: loaded \(addedCount) durable jobs " +
                    "(resident=\(residentPendingCount), refill=\(persistentRefillNeeded))"
            )
            await updateStatus()
            processNext()
        } catch {
            persistentRefillNeeded = false
            lastServiceError = String(error.localizedDescription.prefix(1_000))
            logError("VideoUnderstandingQueue: requeue failed: \(error.localizedDescription)")
            await updateStatus()
        }
    }

    private func pendingItemIDs() -> [UUID] {
        var copy = pending
        var itemIDs: [UUID] = []
        itemIDs.reserveCapacity(copy.count)
        while let itemID = copy.popFirst() {
            itemIDs.append(itemID)
        }
        return itemIDs
    }

    private func processItem(_ itemId: UUID) async {
        var wasCancelled = false
        do {
            try await setStatus(itemId: itemId, status: "processing")
            try Task.checkCancellation()

            let target = try await loadVideoTarget(itemId)
            guard FileManager.default.fileExists(atPath: target.url.path) else {
                throw VideoUnderstandingError.videoMissing(target.url.path)
            }

            let analysis: VideoAnalysis?
            if Self.requiresDerivedAsset(for: target.url) {
                let queuedStreamInfo = pendingWebMStreamInfo.removeValue(forKey: itemId)
                analysis = try await webMWorkCoordinator.withExclusiveAccess(to: target.url) {
                    try Task.checkCancellation()
                    let streamInfo: WebMStreamInfo
                    if let queuedStreamInfo {
                        streamInfo = queuedStreamInfo
                    } else {
                        streamInfo = try await webMExtractor.probeStreams(in: target.url)
                    }
                    guard streamInfo.hasVideo else { return nil }

                    let derivedAsset = try await webMExtractor.extractSampledVideo(
                        from: target.url,
                        streamInfo: streamInfo
                    ) { duration in
                        VideoTimelineBuilder.samplingFramesPerSecond(for: duration)
                    }
                    defer { derivedAsset.cleanup() }
                    try Task.checkCancellation()

                    let derivedAnalysis = try await analyzer.analyze(
                        videoURL: derivedAsset.url,
                        framesPerSecond: derivedAsset.framesPerSecond
                    )
                    try Task.checkCancellation()
                    return Self.analysis(
                        derivedAnalysis,
                        mappedTo: derivedAsset.timelineMapping
                    )
                }
            } else {
                let duration = Self.videoDuration(for: target.url)
                let fps = VideoTimelineBuilder.samplingFramesPerSecond(for: duration)
                analysis = try await analyzer.analyze(videoURL: target.url, framesPerSecond: fps)
            }
            try Task.checkCancellation()

            guard let analysis else {
                logInfo("VideoUnderstandingQueue: \(target.url.lastPathComponent) has no video stream; recording successful exclusion")
                try await markNoVideoComplete(itemId: itemId)
                await finishProcessing(itemId, requeue: false)
                return
            }
            let segments = VideoTimelineBuilder.buildSegments(
                itemId: itemId,
                mediaFileIndex: target.index,
                sourcePath: target.url.path,
                analysis: analysis
            )
            guard !segments.isEmpty else {
                throw VideoUnderstandingError.noSegments(itemId)
            }

            try Task.checkCancellation()
            try await saveSegments(
                itemId: itemId,
                mediaFileIndex: target.index,
                sourcePath: target.url.path,
                segments: segments,
                duration: analysis.duration,
                assetID: target.assetID
            )
        } catch {
            if error is CancellationError || Task.isCancelled {
                wasCancelled = true
                logInfo("VideoUnderstandingQueue: interrupted \(itemId); preserving it for retry")
                try? await setInterrupted(itemId: itemId)
            } else {
                logError("VideoUnderstandingQueue: failed \(itemId): \(error.localizedDescription)")
                try? await setFailed(itemId: itemId, error: error)
            }
        }

        await finishProcessing(itemId, requeue: wasCancelled)
    }

    private func loadVideoTarget(_ itemId: UUID) async throws -> (index: Int, url: URL, assetID: UUID) {
        let target = try await database.write { db -> (Int, URL, UUID)? in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT mediaFilesJSON FROM media_items WHERE id = ?",
                arguments: [itemId.uuidString]
            ) else { return nil }

            let mediaFilesJSON: String = row["mediaFilesJSON"]
            guard let source = Self.firstVideoPath(in: mediaFilesJSON) else { return nil }
            let asset = try ItemAssetStore.prepareWrite(in: db, itemID: itemId, assetID: nil, path: source.path, index: source.index)
            return (asset.index, URL(fileURLWithPath: source.path), asset.id)
        }

        guard let target else {
            throw VideoUnderstandingError.noVideo(itemId)
        }
        return target
    }

    private func saveSegments(
        itemId: UUID,
        mediaFileIndex: Int,
        sourcePath: String,
        segments: [VideoSegment],
        duration: Double,
        assetID: UUID? = nil
    ) async throws {
        let caption = VideoTimelineBuilder.makeSearchCaption(segments: segments, duration: duration)
        let now = ISO8601DateFormatter().string(from: Date())

        try await database.write { db in
            let asset = try ItemAssetStore.prepareWrite(in: db, itemID: itemId, assetID: assetID, path: sourcePath, index: mediaFileIndex)
            try db.execute(
                sql: """
                    DELETE FROM video_segments
                    WHERE item_id = ?
                      AND asset_id = ?
                      AND analysis_source = ?
                """,
                arguments: [
                    itemId.uuidString,
                    asset.id.uuidString,
                    VideoTimelineBuilder.analysisSource
                ]
            )

            for segment in segments {
                try VideoSegmentRecord(segment: segment, timestamp: now, assetID: asset.id).insert(db)
            }

            try db.execute(
                sql: """
                    UPDATE media_items
                    SET generatedCaption = ?,
                        video_understanding_status = 'complete',
                        video_understanding_version = ?,
                        video_understanding_retry_count = 0,
                        video_understanding_last_error = NULL,
                        video_understanding_failed_at = NULL
                    WHERE id = ?
                """,
                arguments: [
                    caption ?? DatabaseValue.null,
                    VideoTimelineBuilder.currentVersion,
                    itemId.uuidString
                ]
            )
        }
    }

    private func setStatus(itemId: UUID, status: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE media_items SET video_understanding_status = ? WHERE id = ?",
                arguments: [status, itemId.uuidString]
            )
        }
    }

    private func setFailed(itemId: UUID, error: Error) async throws {
        let message = String(error.localizedDescription.prefix(1000))
        let failedAt = ISO8601DateFormatter().string(from: Date())
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE media_items
                    SET video_understanding_status = 'failed',
                        video_understanding_retry_count = COALESCE(video_understanding_retry_count, 0) + 1,
                        video_understanding_last_error = ?,
                        video_understanding_failed_at = ?
                    WHERE id = ?
                """,
                arguments: [message, failedAt, itemId.uuidString]
            )
        }
    }

    private func setInterrupted(itemId: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE media_items
                    SET video_understanding_status = 'none',
                        video_understanding_last_error = NULL,
                        video_understanding_failed_at = NULL
                    WHERE id = ?
                      AND video_understanding_status = 'processing'
                """,
                arguments: [itemId.uuidString]
            )
        }
    }

    private func markNoVideoComplete(itemId: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM video_segments WHERE item_id = ? AND association_state = 'attached'",
                arguments: [itemId.uuidString]
            )
            try db.execute(
                sql: """
                    UPDATE media_items
                    SET video_understanding_status = 'complete',
                        video_understanding_version = ?,
                        video_understanding_retry_count = 0,
                        video_understanding_last_error = NULL,
                        video_understanding_failed_at = NULL
                    WHERE id = ?
                """,
                arguments: [VideoTimelineBuilder.currentVersion, itemId.uuidString]
            )
        }
    }

    private func resetItem(_ itemId: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM video_segments WHERE item_id = ? AND association_state = 'attached'", arguments: [itemId.uuidString])
            try db.execute(
                sql: """
                    UPDATE media_items
                    SET video_understanding_status = 'none',
                        video_understanding_version = 0,
                        video_understanding_retry_count = 0,
                        video_understanding_last_error = NULL,
                        video_understanding_failed_at = NULL
                    WHERE id = ?
                """,
                arguments: [itemId.uuidString]
            )
        }
    }

    private func finishProcessing(_ itemId: UUID, requeue: Bool) async {
        inProgress.remove(itemId)
        if processingItemId == itemId {
            processingTask = nil
            processingItemId = nil
        }
        let shouldDiscard = discardCancelledItems.remove(itemId) != nil
        if requeue, !shouldDiscard, !pending.contains(itemId) {
            if residentPendingCount < Self.maxResidentPendingJobs {
                pending.prepend(itemId)
            } else {
                persistentRefillNeeded = true
            }
        }
        await updateStatus()

        await notifyItemChanged(itemId)

        let delay = BackgroundProcessingIntensity.current.pipelineInterJobDelay
        if delay == .zero {
            processNext()
            return
        }

        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            await self.processNext()
        }
    }

    private func notifyItemChanged(_ itemId: UUID) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .mediaStoreDidChange,
                object: nil,
                userInfo: ["itemId": itemId]
            )
        }
    }

    private func updateStatus() async {
        let processing = inProgress.count
        let queued = residentPendingCount
        let phase: String
        if lastServiceError != nil {
            phase = "error"
        } else if processing > 0 {
            phase = "processing"
        } else if queued == 0 && persistentRefillNeeded {
            phase = "refilling"
        } else if queued > 0 {
            phase = "queued"
        } else {
            phase = "idle"
        }
        await MainActor.run {
            statusSubject.send(
                VideoUnderstandingQueueStatus(
                    processing: processing,
                    queued: queued,
                    phase: phase
                )
            )
        }
    }

    private func setupMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            Task {
                if event.contains(.critical) || event.contains(.warning) {
                    await self.pause()
                } else {
                    await self.resume()
                }
            }
        }
        source.resume()
        memorySource = source
    }

    private func setupInteractionObserver() {
        interactionObserver = NotificationCenter.default.addObserver(
            forName: .appInteractionStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let state = notification.object as? AppInteractionMonitor.State
                ?? AppInteractionMonitor.shared.snapshot()
            Task { await self.interactionStateDidChange(state) }
        }
        interactionStateDidChange(AppInteractionMonitor.shared.snapshot())
    }

    static func firstVideoPath(in mediaFilesJSON: String) -> (index: Int, path: String)? {
        let paths = (try? JSONDecoder().decode([String].self, from: Data(mediaFilesJSON.utf8))) ?? []
        if let nativeVideo = paths.enumerated().first(where: { _, path in
            videoExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
        }) {
            return (nativeVideo.offset, nativeVideo.element)
        }

        return paths.enumerated().first { _, path in
            derivedVideoExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
        }.map { ($0.offset, $0.element) }
    }

    private static func mediaPredicateSQL(extensions: Set<String>) -> String {
        let clauses = extensions.sorted().map {
            "lower(json_each.value) LIKE '%.\($0)'"
        }
        return """
            EXISTS (
                SELECT 1
                FROM json_each(mediaFilesJSON)
                WHERE \(clauses.joined(separator: " OR "))
            )
        """
    }

    private static func videoDuration(for url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        return duration.isFinite && duration > 0 ? duration : 0
    }

    nonisolated static func analysis(
        _ analysis: VideoAnalysis,
        mappedTo timeline: WebMTimelineMapping
    ) -> VideoAnalysis {
        VideoAnalysis(
            duration: timeline.sourceDuration,
            frameCount: analysis.frameCount,
            labels: analysis.labels,
            highlights: analysis.highlights.map { highlight in
                VideoHighlight(
                    time: timeline.sourceTime(forDerivedTime: highlight.time),
                    score: highlight.score,
                    labels: highlight.labels
                )
            },
            suggestedThumbnailTime: timeline.sourceTime(
                forDerivedTime: analysis.suggestedThumbnailTime
            ),
            frameAnalyses: analysis.frameAnalyses.map { frame in
                FrameAnalysis(
                    time: timeline.sourceTime(forDerivedTime: frame.time),
                    labels: frame.labels,
                    qualityScore: frame.qualityScore
                )
            }
        )
    }
}
