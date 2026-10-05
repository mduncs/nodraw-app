import Foundation
import GRDB
import Combine

// MARK: - Pipeline Queue Status

struct PipelineQueueStatus: Sendable, Equatable {
    let processing: Int
    let queued: Int
    let phase: String
    let lastError: String?

    static let idle = PipelineQueueStatus(
        processing: 0,
        queued: 0,
        phase: "idle",
        lastError: nil
    )

    var isIdle: Bool { processing == 0 && queued == 0 }

    var displayText: String {
        if let lastError { return "Pipeline error: \(lastError)" }
        if isIdle { return "" }
        return "Pipeline: \(processing) processing, \(queued) queued (\(phase))"
    }
}

// MARK: - Pending Job Buffer

/// FIFO storage with stable deduplication and amortized O(1) removal from the front.
///
/// `Array.removeFirst()` shifts every remaining UUID for every started job. Large restart queues
/// therefore performed O(n²) reference moves before doing any useful pipeline work. This buffer
/// advances a head index and occasionally compacts the remaining suffix instead.
struct DeduplicatingFIFOBuffer<Element: Hashable> {
    private var storage: [Element] = []
    private var head = 0
    private var membership: Set<Element> = []

    /// Test-visible structural counter. This measures actual elements copied during compaction,
    /// rather than relying on a timing assertion that would be noisy on busy machines.
    private(set) var compactedElementCount = 0

    var count: Int { membership.count }
    var isEmpty: Bool { membership.isEmpty }

    func contains(_ element: Element) -> Bool {
        membership.contains(element)
    }

    @discardableResult
    mutating func append(_ element: Element) -> Bool {
        guard membership.insert(element).inserted else { return false }
        storage.append(element)
        return true
    }

    @discardableResult
    mutating func append<S: Sequence>(contentsOf elements: S) -> Int where S.Element == Element {
        var insertedCount = 0
        for element in elements where append(element) {
            insertedCount += 1
        }
        return insertedCount
    }

    /// Inserts at the logical front while preserving deduplication. A recently popped slot is
    /// reused in O(1), which is the common case when a cancelled single-worker job is requeued.
    @discardableResult
    mutating func prepend(_ element: Element) -> Bool {
        guard membership.insert(element).inserted else { return false }
        if head > 0 {
            head -= 1
            storage[head] = element
        } else {
            storage.insert(element, at: 0)
        }
        return true
    }

    mutating func popFirst() -> Element? {
        guard head < storage.count else { return nil }

        let element = storage[head]
        head += 1
        membership.remove(element)
        compactIfNeeded()
        return element
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        membership.removeAll(keepingCapacity: keepingCapacity)
        head = 0
    }

    /// Removes matching pending jobs without exposing the buffer's storage representation.
    /// This is intentionally linear: selective cancellation is rare, while enqueue, membership,
    /// and front removal remain the high-frequency O(1)-amortized operations.
    @discardableResult
    mutating func removeAll(where shouldRemove: (Element) throws -> Bool) rethrows -> Int {
        var retained: [Element] = []
        retained.reserveCapacity(membership.count)
        var removedCount = 0

        for element in storage[head...] {
            if try shouldRemove(element) {
                removedCount += 1
            } else {
                retained.append(element)
            }
        }

        storage = retained
        head = 0
        membership = Set(retained)
        return removedCount
    }

    private mutating func compactIfNeeded() {
        if membership.isEmpty {
            storage.removeAll(keepingCapacity: true)
            head = 0
            return
        }

        // Avoid tiny frequent copies, then cap stale prefix storage to at most half the array.
        guard head >= 1_024, head >= storage.count / 2 else { return }
        compactedElementCount += storage.count - head
        storage.removeFirst(head)
        head = 0
    }
}

struct PipelineQueueDiagnostics: Sendable, Equatable {
    let singleEligibilityQueryCount: Int
    let persistentBatchQueryCount: Int
    let duplicateEnqueueDropCount: Int
    let compactedElementCount: Int
}

// MARK: - Memory Pressure Tier

private enum MemoryPressureTier {
    case normal    // full speed
    case throttle  // reduce concurrency to 1
    case pause     // stop entirely, release caches
}

// MARK: - Pipeline Queue

/// Background ML processing queue. Runs after VisionJobQueue completes.
/// Three-phase gated pipeline at .utility QoS, memory-pressure aware.
actor PipelineQueue {

    // MARK: - Shared Instance

    nonisolated(unsafe) private static var _shared: PipelineQueue?

    nonisolated static var shared: PipelineQueue {
        guard let instance = _shared else {
            fatalError("PipelineQueue.shared accessed before setShared(_:) was called")
        }
        return instance
    }

    /// Optional access for call sites that can gracefully skip work until configured.
    nonisolated static var sharedIfConfigured: PipelineQueue? {
        _shared
    }

    nonisolated static func setShared(_ queue: PipelineQueue) {
        _shared = queue
    }

    nonisolated static var isConfigured: Bool { _shared != nil }

    // MARK: - Configuration

    /// Keep the resident queue bounded. Remaining jobs stay durably represented by their
    /// non-complete database status and are pulled in when the current window drains.
    static let maxResidentPendingJobs = 512

    /// Max concurrent pipeline jobs (reduced under memory pressure)
    private var maxConcurrent = BackgroundProcessingIntensity.current.pipelineNormalConcurrency

    /// Whether the queue is paused
    private var isPaused = false

    // MARK: - Dependencies

    private let database: DatabaseManager
    private let adapter: PipelineAdapter

    // MARK: - State

    private var pending = DeduplicatingFIFOBuffer<UUID>()
    private var inProgress: Set<UUID> = []
    /// Reservations close the actor-reentrancy gap while an eligibility query is awaiting GRDB.
    private var enqueueReservations: Set<UUID> = []
    private var pendingGeneration = 0
    private var isPersistentLoadInFlight = false
    private var persistentRefillNeeded = false
    private var lastServiceError: String?
    private var singleEligibilityQueryCount = 0
    private var persistentBatchQueryCount = 0
    private var duplicateEnqueueDropCount = 0
    private var failureCounts: [UUID: Int] = [:]
    private let maxRetries = 3
    private var memoryTier: MemoryPressureTier = .normal
    private var memorySource: DispatchSourceMemoryPressure?
    private var interactionObserver: NSObjectProtocol?
    private var clipBackfillRequested = false
    private var clipBackfillTask: Task<Void, Never>?

    // MARK: - Status

    @MainActor
    private let statusSubject = CurrentValueSubject<PipelineQueueStatus, Never>(.idle)

    @MainActor
    var status: AnyPublisher<PipelineQueueStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    @MainActor
    var currentStatus: PipelineQueueStatus {
        statusSubject.value
    }

    // MARK: - Init

    init(database: DatabaseManager = .shared) {
        self.database = database
        self.adapter = PipelineAdapter(database: database)
        Task { await self.setupMemoryPressureMonitor() }
        Task { await self.setupInteractionObserver() }
    }

    // MARK: - Public API

    deinit {
        memorySource?.setEventHandler(handler: nil)
        memorySource?.cancel()
        if let interactionObserver { NotificationCenter.default.removeObserver(interactionObserver) }
        clipBackfillTask?.cancel()
    }

    /// Enqueue an item for pipeline processing.
    /// Only processes items whose pipeline_status is not 'complete'.
    func enqueue(itemId: UUID) async {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        guard !inProgress.contains(itemId),
              !pending.contains(itemId),
              !enqueueReservations.contains(itemId) else {
            duplicateEnqueueDropCount += 1
            return
        }

        enqueueReservations.insert(itemId)
        let generation = pendingGeneration
        defer { enqueueReservations.remove(itemId) }

        // Skip items that are already complete, deleted, unprocessable, or out of retries.
        do {
            singleEligibilityQueryCount += 1
            let shouldQueue = try await database.read { db -> Bool in
                let sql = """
                    SELECT EXISTS(
                        SELECT 1 FROM media_items
                        WHERE id = ?
                        AND (pipeline_status IS NULL OR pipeline_status IN ('none', 'phase1', 'failed'))
                        AND (mediaFilesJSON != '[]' OR (contextImageString IS NOT NULL AND contextImageString <> ''))
                        AND (deletedAt IS NULL OR deletedAt = '')
                        AND COALESCE(pipeline_retry_count, 0) < ?
                    )
                """
                let exists = try Int.fetchOne(
                    db,
                    sql: sql,
                    arguments: [itemId.uuidString, self.maxRetries]
                ) ?? 0
                return exists == 1
            }
            guard shouldQueue, generation == pendingGeneration else { return }
        } catch {
            recordServiceError(
                "Could not check queued item: \(error.localizedDescription)",
                logPrefix: "PipelineQueue: enqueue eligibility check failed for \(itemId)"
            )
            await updateStatus()
            return
        }

        // A full in-memory window is not data loss: the item's durable database status remains
        // incomplete, so the refill query will discover it after the resident window drains.
        guard pending.count < Self.maxResidentPendingJobs else {
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

    /// Enqueue all items that need pipeline processing.
    func requeueIncomplete() async {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        // Backfill vectors only after foreground pipeline work drains. Running this concurrently
        // with newly queued ML jobs made launch contention and memory pressure substantially worse.
        clipBackfillRequested = true
        await loadNextPersistentBatch()
    }

    /// Reset and reprocess ALL items through the ML pipeline from scratch.
    /// Clears pipeline status, retry counts, errors, and all ML attributes.
    @discardableResult
    func reprocessAll() async -> Int {
        do {
            let count = try await database.write { db -> Int in
                let rows = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM media_items
                    WHERE (mediaFilesJSON != '[]' OR (contextImageString IS NOT NULL AND contextImageString <> ''))
                    AND (deletedAt IS NULL OR deletedAt = '')
                """) ?? 0

                // Reset pipeline state for all items
                try db.execute(sql: """
                    UPDATE media_items
                    SET pipeline_status = 'none',
                        pipeline_retry_count = 0,
                        pipeline_last_error = NULL,
                        pipeline_failed_at = NULL
                    WHERE (mediaFilesJSON != '[]' OR (contextImageString IS NOT NULL AND contextImageString <> ''))
                    AND (deletedAt IS NULL OR deletedAt = '')
                """)

                // Clear all ML attributes
                try db.execute(sql: "DELETE FROM media_attributes")

                return rows
            }

            logInfo("PipelineQueue: full reprocess — reset \(count) items, cleared ML attributes")
            await requeueIncomplete()
            return count
        } catch {
            recordServiceError(
                "Could not reset pipeline work: \(error.localizedDescription)",
                logPrefix: "PipelineQueue: full reprocess failed"
            )
            await updateStatus()
            return 0
        }
    }

    /// Force-reprocess all failed items, resetting retry counts and error state.
    func forceRetryFailed() async {
        do {
            let count = try await database.write { db -> Int in
                let rows = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM media_items
                    WHERE pipeline_status = 'failed'
                    AND (deletedAt IS NULL OR deletedAt = '')
                """) ?? 0

                try db.execute(sql: """
                    UPDATE media_items
                    SET pipeline_status = 'none',
                        pipeline_retry_count = 0,
                        pipeline_last_error = NULL,
                        pipeline_failed_at = NULL
                    WHERE pipeline_status = 'failed'
                    AND (deletedAt IS NULL OR deletedAt = '')
                """)
                return rows
            }

            logInfo("PipelineQueue: force-retrying \(count) failed items")
            await requeueIncomplete()
        } catch {
            recordServiceError(
                "Could not retry failed jobs: \(error.localizedDescription)",
                logPrefix: "PipelineQueue: force retry failed"
            )
            await updateStatus()
        }
    }

    func pause() {
        isPaused = true
        cancelClipBackfillForForegroundWork()
        logInfo("PipelineQueue: paused")
    }

    func resume() {
        isPaused = false
        logInfo("PipelineQueue: resumed")
        processNext()
    }

    func clearPending() async {
        pending.removeAll()
        pendingGeneration &+= 1
        enqueueReservations.removeAll()
        persistentRefillNeeded = false
        await updateStatus()
    }

    func diagnostics() -> PipelineQueueDiagnostics {
        PipelineQueueDiagnostics(
            singleEligibilityQueryCount: singleEligibilityQueryCount,
            persistentBatchQueryCount: persistentBatchQueryCount,
            duplicateEnqueueDropCount: duplicateEnqueueDropCount,
            compactedElementCount: pending.compactedElementCount
        )
    }

    /// CLIP text-to-image search. Returns (itemId, score) pairs sorted by relevance.
    func clipSearch(query: String, limit: Int = 20) async throws -> [(itemId: UUID, score: Float)] {
        try await adapter.clipSearch(query: query, limit: limit)
    }

    // MARK: - Processing

    private var canProcess: Bool {
        !isPaused &&
        memoryTier != .pause &&
        !AppInteractionMonitor.shared.shouldSuspendBackgroundProcessing() &&
        inProgress.count < maxConcurrent
    }

    private func processNext() {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        refreshThroughputConfiguration()
        guard canProcess else { return }
        guard !pending.isEmpty else {
            startClipBackfillIfIdle()
            return
        }

        cancelClipBackfillForForegroundWork()

        guard let itemId = pending.popFirst() else { return }
        inProgress.insert(itemId)

        Task.detached(priority: BackgroundProcessingIntensity.current.taskPriority) {
            await self.processItem(itemId)
        }

        // Fill remaining slots
        if canProcess && !pending.isEmpty {
            processNext()
        }
    }

    /// Pull one bounded window of durable incomplete work. This is deliberately one SQL query and
    /// one queue/status mutation for the whole burst; the previous implementation called
    /// `enqueue` for every row and repeated the eligibility query N times.
    private func loadNextPersistentBatch() async {
        guard !isPersistentLoadInFlight else {
            persistentRefillNeeded = true
            return
        }

        isPersistentLoadInFlight = true
        let generation = pendingGeneration
        defer { isPersistentLoadInFlight = false }

        do {
            persistentBatchQueryCount += 1
            // The small allowance prevents currently running rows at the head of the durable
            // result from consuming slots in the next resident window.
            let queryLimit = Self.maxResidentPendingJobs + maxConcurrent
            let itemIds = try await database.read { db -> [UUID] in
                let sql = """
                    SELECT id FROM media_items
                    WHERE (pipeline_status IS NULL OR pipeline_status IN ('none', 'phase1', 'failed'))
                    AND (mediaFilesJSON != '[]' OR (contextImageString IS NOT NULL AND contextImageString <> ''))
                    AND (deletedAt IS NULL OR deletedAt = '')
                    AND COALESCE(pipeline_retry_count, 0) < ?
                    ORDER BY originalDate DESC
                    LIMIT ?
                """
                return try String.fetchAll(
                    db,
                    sql: sql,
                    arguments: [self.maxRetries, queryLimit]
                ).compactMap { UUID(uuidString: $0) }
            }

            guard generation == pendingGeneration else { return }

            let availableCapacity = max(0, Self.maxResidentPendingJobs - pending.count)
            let candidates = itemIds.filter {
                !inProgress.contains($0) &&
                !pending.contains($0) &&
                !enqueueReservations.contains($0)
            }
            let accepted = candidates.prefix(availableCapacity)
            let addedCount = pending.append(contentsOf: accepted)
            persistentRefillNeeded = itemIds.count == queryLimit || candidates.count > availableCapacity
            lastServiceError = nil

            logInfo(
                "PipelineQueue: loaded \(addedCount) durable jobs " +
                "(resident=\(pending.count), refill=\(persistentRefillNeeded))"
            )
            await updateStatus()
            processNext()
        } catch {
            persistentRefillNeeded = false
            recordServiceError(
                "Could not restore pending jobs: \(error.localizedDescription)",
                logPrefix: "PipelineQueue: requeue failed"
            )
            await updateStatus()
        }
    }

    private func processItem(_ itemId: UUID) async {
        CrashTelemetry.leave("pipeline-process \(itemId)")
        // Get current pipeline status
        let currentStatus: String? = try? await database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT pipeline_status FROM media_items WHERE id = ?",
                arguments: [itemId.uuidString]
            )
        }

        let status = currentStatus ?? "none"

        // Another worker may have completed this item before execution.
        if status == "complete" {
            await finishProcessing(itemId)
            return
        }

        // Phase 1: embeddings + scene
        if status == "none" || status == "failed" {
            do {
                try await adapter.runPhase1(itemId: itemId)
                try await setPipelineStatus(itemId: itemId, status: .phase1)
            } catch {
                logError("PipelineQueue: phase1 failed for \(itemId): \(error.localizedDescription)")
                lastServiceError = "Item processing failed: \(error.localizedDescription)"
                try? await setFailed(itemId: itemId, error: error)
                await finishProcessing(itemId)
                return
            }
        }

        // Phase 2+3: objects, faces, safety, junk, curation, etc.
        do {
            try await adapter.runPhase2And3(itemId: itemId)
            try await setPipelineStatus(itemId: itemId, status: .complete)
        } catch {
            logError("PipelineQueue: phase2+3 failed for \(itemId): \(error.localizedDescription)")
            lastServiceError = "Item processing failed: \(error.localizedDescription)"
            try? await setFailed(itemId: itemId, error: error)
        }

        await finishProcessing(itemId)
    }

    private func setPipelineStatus(itemId: UUID, status: PipelineStatus) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE media_items SET pipeline_status = ? WHERE id = ?",
                arguments: [status.rawValue, itemId.uuidString]
            )
        }
    }

    private func setFailed(itemId: UUID, error: Error) async throws {
        let errorMessage = String(error.localizedDescription.prefix(1000))
        let failedAt = ISO8601DateFormatter().string(from: Date())
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE media_items
                    SET pipeline_status = 'failed',
                        pipeline_retry_count = COALESCE(pipeline_retry_count, 0) + 1,
                        pipeline_last_error = ?,
                        pipeline_failed_at = ?
                    WHERE id = ?
                """,
                arguments: [errorMessage, failedAt, itemId.uuidString]
            )
        }
    }

    private func finishProcessing(_ itemId: UUID) async {
        await adapter.discardAnalysis(itemId: itemId)
        inProgress.remove(itemId)
        await updateStatus()

        // Notify UI
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
            guard let self = self else { return }
            try? await Task.sleep(for: delay)
            await self.processNext()
        }
    }

    private func updateStatus() async {
        let p = inProgress.count
        let q = pending.count
        let phase = lastServiceError == nil
            ? (inProgress.isEmpty ? "idle" : "processing")
            : "error"
        let error = lastServiceError
        await MainActor.run {
            statusSubject.send(
                PipelineQueueStatus(
                    processing: p,
                    queued: q,
                    phase: phase,
                    lastError: error
                )
            )
        }
    }

    private func recordServiceError(_ message: String, logPrefix: String) {
        lastServiceError = String(message.prefix(1_000))
        logError("\(logPrefix): \(message)")
    }

    // MARK: - Idle Maintenance

    private func startClipBackfillIfIdle() {
        if persistentRefillNeeded {
            Task { await self.loadNextPersistentBatch() }
            return
        }

        guard clipBackfillRequested,
              clipBackfillTask == nil,
              pending.isEmpty,
              inProgress.isEmpty,
              !isPaused,
              memoryTier != .pause,
              !AppInteractionMonitor.shared.shouldSuspendBackgroundProcessing() else {
            return
        }

        clipBackfillRequested = false
        let adapter = self.adapter
        clipBackfillTask = Task.detached(priority: .background) { [weak self] in
            _ = await adapter.backfillClipVectors()
            await self?.clipBackfillDidFinish()
        }
    }

    private func cancelClipBackfillForForegroundWork() {
        guard let clipBackfillTask else { return }
        // Treat direct manipulation, foreground pipeline work, and pressure as the end of this
        // maintenance opportunity. Re-arming here would let every idle/interaction cycle start a
        // fresh bounded batch and exceed the intended per-requeue budget.
        clipBackfillTask.cancel()
    }

    private func clipBackfillDidFinish() {
        clipBackfillTask = nil
        processNext()
    }

    // MARK: - Memory Pressure

    private func setupMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data
            Task {
                if event.contains(.critical) {
                    await self.handleMemoryPressure(.pause)
                } else if event.contains(.warning) {
                    await self.handleMemoryPressure(.throttle)
                } else {
                    await self.handleMemoryPressure(.normal)
                }
            }
        }
        source.resume()
        self.memorySource = source
    }

    private func handleMemoryPressure(_ tier: MemoryPressureTier) {
        if tier != .normal {
            Task { await adapter.releaseIdleResources() }
        }
        let oldTier = memoryTier
        memoryTier = tier

        refreshThroughputConfiguration()

        switch tier {
        case .normal:
            logInfo("PipelineQueue: memory normal, resuming full speed")
        case .throttle:
            logInfo("PipelineQueue: memory warning, throttling to 1 concurrent")
        case .pause:
            logInfo("PipelineQueue: memory critical, pausing pipeline")
            cancelClipBackfillForForegroundWork()
        }

        // If coming back from pressure, resume processing
        if oldTier == .pause && tier != .pause {
            processNext()
        }
    }

    private func refreshThroughputConfiguration() {
        let intensity = BackgroundProcessingIntensity.current

        switch memoryTier {
        case .normal:
            maxConcurrent = intensity.pipelineNormalConcurrency
        case .throttle:
            maxConcurrent = 1
        case .pause:
            break
        }
    }

    private func setupInteractionObserver() {
        interactionObserver = NotificationCenter.default.addObserver(
            forName: .appInteractionStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                if AppInteractionMonitor.shared.shouldSuspendBackgroundProcessing() {
                    await self.cancelClipBackfillForForegroundWork()
                } else {
                    await self.processNext()
                }
            }
        }
    }

    /// Called when system memory pressure subsides (from app delegate or similar)
    func onMemoryPressureNormal() {
        handleMemoryPressure(.normal)
    }
}
