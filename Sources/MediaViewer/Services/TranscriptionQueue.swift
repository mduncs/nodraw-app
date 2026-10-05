import Combine
import Foundation
import GRDB

// MARK: - Transcription Status

struct TranscriptionQueueStatus: Sendable, Equatable {
    let processing: Int
    let queued: Int
    let phase: String

    static let idle = TranscriptionQueueStatus(processing: 0, queued: 0, phase: "idle")

    var isIdle: Bool { processing == 0 && queued == 0 && phase == "idle" }

    var displayText: String {
        if isIdle { return "" }
        return "Transcript: \(processing) processing, \(queued) queued (\(phase))"
    }
}

struct TranscriptionQueueDiagnostics: Sendable, Equatable {
    let singleEligibilityQueryCount: Int
    let persistentBatchQueryCount: Int
    let duplicateEnqueueDropCount: Int
    let residentPendingCount: Int
    let hasDurableOverflow: Bool
    let compactedElementCount: Int
}

private enum TranscriptionQueueError: LocalizedError {
    case noTranscribableMedia(UUID)
    case mediaMissing(String)

    var errorDescription: String? {
        switch self {
        case .noTranscribableMedia(let itemId):
            return "No audio or video media found for item \(itemId)"
        case .mediaMissing(let path):
            return "Media file not found: \(URL(fileURLWithPath: path).lastPathComponent)"
        }
    }
}

// MARK: - Transcription Queue

actor TranscriptionQueue {
    nonisolated(unsafe) private static var _shared: TranscriptionQueue?

    nonisolated static var shared: TranscriptionQueue {
        guard let instance = _shared else {
            fatalError("TranscriptionQueue.shared accessed before setShared(_:) was called")
        }
        return instance
    }

    nonisolated static var sharedIfConfigured: TranscriptionQueue? {
        _shared
    }

    nonisolated static func setShared(_ queue: TranscriptionQueue) {
        _shared = queue
    }

    nonisolated static var isConfigured: Bool {
        _shared != nil
    }

    private static let maxRetries = 3
    /// Incomplete work remains durable in `media_items`; only this bounded window is resident.
    static let maxResidentPendingJobs = 512
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "caf"]
    // Parakeet extracts these containers through AVFoundation. WebM is deliberately
    // separate: the queue first creates a mono 16 kHz PCM compatibility asset.
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv"]
    private static let derivedVideoExtensions: Set<String> = ["webm"]
    static let transcribableMediaPredicateSQL = mediaPredicateSQL(
        extensions: audioExtensions.union(videoExtensions).union(derivedVideoExtensions)
    )

    private let database: DatabaseManager
    private let transcriber: ParakeetTranscriptionService
    private let webMExtractor: WebMDerivedAssetExtractor
    private let webMWorkCoordinator: WebMBackgroundWorkCoordinator

    private var pending = DeduplicatingFIFOBuffer<UUID>()
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
    private let statusSubject = CurrentValueSubject<TranscriptionQueueStatus, Never>(.idle)

    @MainActor
    var status: AnyPublisher<TranscriptionQueueStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    @MainActor
    var currentStatus: TranscriptionQueueStatus {
        statusSubject.value
    }

    init(
        database: DatabaseManager = .shared,
        transcriber: ParakeetTranscriptionService = ParakeetTranscriptionService(),
        webMExtractor: WebMDerivedAssetExtractor = WebMDerivedAssetExtractor(),
        webMWorkCoordinator: WebMBackgroundWorkCoordinator = .shared
    ) {
        self.database = database
        self.transcriber = transcriber
        self.webMExtractor = webMExtractor
        self.webMWorkCoordinator = webMWorkCoordinator
        Task { await setupMemoryPressureMonitor() }
        Task { await setupInteractionObserver() }
    }

    deinit {
        memorySource?.setEventHandler(handler: nil)
        memorySource?.cancel()
        if let interactionObserver {
            NotificationCenter.default.removeObserver(interactionObserver)
        }
    }

    nonisolated static func isAudioExtension(_ ext: String) -> Bool {
        audioExtensions.contains(ext.lowercased())
    }

    nonisolated static func isVideoExtension(_ ext: String) -> Bool {
        videoExtensions.contains(ext.lowercased())
    }

    nonisolated static func isTranscribableExtension(_ ext: String) -> Bool {
        isAudioExtension(ext) || isVideoExtension(ext) || derivedVideoExtensions.contains(ext.lowercased())
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

        do {
            singleEligibilityQueryCount += 1
            let shouldQueue = try await database.read { db -> Bool in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT mediaFilesJSON,
                               transcription_status,
                               transcription_version,
                               transcription_retry_count
                        FROM media_items
                        WHERE id = ?
                          AND (deletedAt IS NULL OR deletedAt = '')
                    """,
                    arguments: [itemId.uuidString]
                ) else { return false }

                let mediaFilesJSON: String = row["mediaFilesJSON"]
                let status: String? = row["transcription_status"]
                let version: Int? = row["transcription_version"]
                let retries: Int? = row["transcription_retry_count"]

                guard Self.firstTranscribablePath(in: mediaFilesJSON) != nil else { return false }
                if (retries ?? 0) >= Self.maxRetries && !force { return false }
                return force ||
                    status != "complete" ||
                    (version ?? 0) < TranscriptTimelineBuilder.currentVersion
            }

            guard shouldQueue, !Task.isCancelled else { return }
            guard generation == pendingGeneration else {
                persistentRefillNeeded = true
                Task { await self.loadNextPersistentBatch() }
                return
            }

            // Check compatibility before reset so a forced WebM enqueue cannot
            // erase a preserved transcript or its completion state.
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
            logError("TranscriptionQueue: enqueue eligibility failed for \(itemId): \(error.localizedDescription)")
            await updateStatus()
            return
        }

        // Capacity overflow is still represented by the incomplete database status and will be
        // discovered by the next persistent refill. A direct force enqueue has already reset the
        // durable row, so it is likewise safe to defer when the resident window is full.
        guard residentPendingCount < Self.maxResidentPendingJobs else {
            persistentRefillNeeded = true
            return
        }

        guard !inProgress.contains(itemId), pending.append(itemId) else {
            duplicateEnqueueDropCount += 1
            return
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
                          AND \(Self.transcribableMediaPredicateSQL)
                    """
                ) ?? 0

                try db.execute(sql: """
                    DELETE FROM transcript_segments
                    WHERE association_state = 'attached' AND item_id IN (
                        SELECT id FROM media_items
                        WHERE (deletedAt IS NULL OR deletedAt = '')
                          AND \(Self.transcribableMediaPredicateSQL)
                    )
                """)
                try db.execute(sql: """
                    UPDATE media_items
                    SET transcription_status = 'none',
                        transcription_version = 0,
                        transcription_retry_count = 0,
                        transcription_last_error = NULL,
                        transcription_failed_at = NULL
                    WHERE (deletedAt IS NULL OR deletedAt = '')
                      AND \(Self.transcribableMediaPredicateSQL)
                """)

                return count
            }

            persistentRefillNeeded = count > residentPendingCount
            await loadNextPersistentBatch()
            return count
        } catch {
            lastServiceError = String(error.localizedDescription.prefix(1_000))
            logError("TranscriptionQueue: reprocess all failed: \(error.localizedDescription)")
            await updateStatus()
            return 0
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        processingTask?.cancel()
        logInfo("TranscriptionQueue: paused")
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        logInfo("TranscriptionQueue: resumed")
        processNext()
    }

    func clear(itemId: UUID) async {
        pendingGeneration &+= 1
        excludedFromPersistentRefill.insert(itemId)
        pending.removeAll { $0 == itemId }
        if processingItemId == itemId {
            discardCancelledItems.insert(itemId)
            processingTask?.cancel()
        }
        try? await resetItem(itemId)
        await updateStatus()
    }

    func diagnostics() -> TranscriptionQueueDiagnostics {
        TranscriptionQueueDiagnostics(
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
            logInfo("TranscriptionQueue: yielding active work for interaction")
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

    /// Restores one bounded FIFO window directly from durable state. In contrast to the previous
    /// restart loop, this performs one eligibility query for the whole window and never calls the
    /// per-item `enqueue` path.
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
        // One extra row is a cheap, exact signal that additional durable work remains.
        let queryLimit = max(1, availableCapacity + 1)
        let currentVersion = TranscriptTimelineBuilder.currentVersion
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
                          AND \(Self.transcribableMediaPredicateSQL)
                          AND (
                              transcription_status IS NULL
                              OR transcription_status IN ('none', 'failed', 'processing')
                              OR COALESCE(transcription_version, 0) < ?
                          )
                          AND COALESCE(transcription_retry_count, 0) < ?
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
                "TranscriptionQueue: loaded \(addedCount) durable jobs " +
                    "(resident=\(residentPendingCount), refill=\(persistentRefillNeeded))"
            )
            await updateStatus()
            processNext()
        } catch {
            persistentRefillNeeded = false
            lastServiceError = String(error.localizedDescription.prefix(1_000))
            logError("TranscriptionQueue: requeue failed: \(error.localizedDescription)")
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

            let target = try await loadTranscriptionTarget(itemId)
            guard FileManager.default.fileExists(atPath: target.url.path) else {
                throw TranscriptionQueueError.mediaMissing(target.url.path)
            }

            let transcription: (result: ParakeetTranscriptionResult, timelineOffset: Double)
            if Self.requiresDerivedAsset(for: target.url) {
                transcription = try await webMWorkCoordinator.withExclusiveAccess(to: target.url) {
                    try Task.checkCancellation()
                    let streamInfo = try await webMExtractor.probeStreams(in: target.url)
                    guard streamInfo.hasAudio else {
                        logInfo("TranscriptionQueue: \(target.url.lastPathComponent) has no audio stream; recording an empty successful transcript")
                        return (
                            ParakeetTranscriptionResult(
                                text: "",
                                confidence: 0,
                                duration: streamInfo.formatDuration ?? 0,
                                tokens: [],
                                language: nil,
                                model: TranscriptTimelineBuilder.defaultModelName
                            ),
                            0
                        )
                    }

                    let derivedAsset = try await webMExtractor.extractTranscriptionAudio(
                        from: target.url,
                        streamInfo: streamInfo
                    )
                    defer { derivedAsset.cleanup() }
                    try Task.checkCancellation()
                    let result = try await transcriber.transcribe(sourceURL: derivedAsset.url)
                    try Task.checkCancellation()
                    return (result, derivedAsset.sourceTimelineOffset)
                }
            } else {
                transcription = (
                    try await transcriber.transcribe(sourceURL: target.url),
                    0
                )
            }
            try Task.checkCancellation()
            let unadjustedSegments = TranscriptTimelineBuilder.buildSegments(
                itemId: itemId,
                mediaFileIndex: target.index,
                sourcePath: target.url.path,
                transcriptText: transcription.result.text,
                transcriptConfidence: transcription.result.confidence,
                tokens: transcription.result.tokens,
                duration: transcription.result.duration,
                language: transcription.result.language,
                model: transcription.result.model
            )
            let segments = Self.applyingTimelineOffset(
                transcription.timelineOffset,
                to: unadjustedSegments
            )

            try Task.checkCancellation()
            try await saveSegments(
                itemId: itemId,
                mediaFileIndex: target.index,
                sourcePath: target.url.path,
                segments: segments,
                assetID: target.assetID
            )
        } catch {
            if error is CancellationError || Task.isCancelled {
                wasCancelled = true
                logInfo("TranscriptionQueue: interrupted \(itemId); preserving it for retry")
                try? await setInterrupted(itemId: itemId)
            } else {
                logError("TranscriptionQueue: failed \(itemId): \(error.localizedDescription)")
                try? await setFailed(itemId: itemId, error: error)
            }
        }

        await finishProcessing(itemId, requeue: wasCancelled)
    }

    private func loadTranscriptionTarget(_ itemId: UUID) async throws -> (index: Int, url: URL, assetID: UUID) {
        let target = try await database.write { db -> (Int, URL, UUID)? in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT mediaFilesJSON FROM media_items WHERE id = ?",
                arguments: [itemId.uuidString]
            ) else { return nil }

            let mediaFilesJSON: String = row["mediaFilesJSON"]
            guard let source = Self.firstTranscribablePath(in: mediaFilesJSON) else { return nil }
            let asset = try ItemAssetStore.prepareWrite(in: db, itemID: itemId, assetID: nil, path: source.path, index: source.index)
            return (asset.index, URL(fileURLWithPath: source.path), asset.id)
        }

        guard let target else {
            throw TranscriptionQueueError.noTranscribableMedia(itemId)
        }
        return target
    }

    func saveSegments(
        itemId: UUID,
        mediaFileIndex: Int,
        sourcePath: String,
        segments: [TranscriptSegment],
        assetID: UUID? = nil
    ) async throws {
        let now = ISO8601DateFormatter().string(from: Date())

        try await database.write { db in
            let asset = try ItemAssetStore.prepareWrite(in: db, itemID: itemId, assetID: assetID, path: sourcePath, index: mediaFileIndex)
            try db.execute(
                sql: """
                    DELETE FROM transcript_segments
                    WHERE item_id = ?
                      AND asset_id = ?
                """,
                arguments: [itemId.uuidString, asset.id.uuidString]
            )

            for segment in segments {
                try TranscriptSegmentRecord(segment: segment, timestamp: now, assetID: asset.id).insert(db)
            }

            let existingCaption = try String.fetchOne(
                db,
                sql: "SELECT generatedCaption FROM media_items WHERE id = ?",
                arguments: [itemId.uuidString]
            )
            let caption = TranscriptTimelineBuilder.makeSearchCaption(
                segments: segments,
                existingCaption: existingCaption
            )

            try db.execute(
                sql: """
                    UPDATE media_items
                    SET generatedCaption = ?,
                        transcription_status = 'complete',
                        transcription_version = ?,
                        transcription_retry_count = 0,
                        transcription_last_error = NULL,
                        transcription_failed_at = NULL
                    WHERE id = ?
                """,
                arguments: [
                    caption ?? DatabaseValue.null,
                    TranscriptTimelineBuilder.currentVersion,
                    itemId.uuidString
                ]
            )
        }
    }

    nonisolated static func applyingTimelineOffset(
        _ offset: Double,
        to segments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard offset.isFinite, offset > 0 else { return segments }
        return segments.map { segment in
            TranscriptSegment(
                id: segment.id,
                itemId: segment.itemId,
                mediaFileIndex: segment.mediaFileIndex,
                sourcePath: segment.sourcePath,
                startTime: segment.startTime + offset,
                endTime: segment.endTime + offset,
                text: segment.text,
                confidence: segment.confidence,
                language: segment.language,
                model: segment.model,
                version: segment.version
            )
        }
    }

    private func setStatus(itemId: UUID, status: String) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE media_items SET transcription_status = ? WHERE id = ?",
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
                    SET transcription_status = 'failed',
                        transcription_retry_count = COALESCE(transcription_retry_count, 0) + 1,
                        transcription_last_error = ?,
                        transcription_failed_at = ?
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
                    SET transcription_status = 'none',
                        transcription_last_error = NULL,
                        transcription_failed_at = NULL
                    WHERE id = ?
                      AND transcription_status = 'processing'
                """,
                arguments: [itemId.uuidString]
            )
        }
    }

    private func resetItem(_ itemId: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM transcript_segments WHERE item_id = ? AND association_state = 'attached'", arguments: [itemId.uuidString])
            try db.execute(
                sql: """
                    UPDATE media_items
                    SET transcription_status = 'none',
                        transcription_version = 0,
                        transcription_retry_count = 0,
                        transcription_last_error = NULL,
                        transcription_failed_at = NULL
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
                // `setInterrupted` already restored durable eligibility. A concurrently filled
                // resident window must not make cancellation exceed the memory bound.
                persistentRefillNeeded = true
            }
        }
        await updateStatus()

        await MainActor.run {
            NotificationCenter.default.post(
                name: .mediaStoreDidChange,
                object: nil,
                userInfo: ["itemId": itemId]
            )
        }

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
                TranscriptionQueueStatus(
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
                    await self.transcriber.releaseIdleResources()
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

    static func firstTranscribablePath(in mediaFilesJSON: String) -> (index: Int, path: String)? {
        let paths = (try? JSONDecoder().decode([String].self, from: Data(mediaFilesJSON.utf8))) ?? []

        if let audio = paths.enumerated().first(where: { _, path in
            audioExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
        }) {
            return (audio.offset, audio.element)
        }

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
}
