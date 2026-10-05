import XCTest
import GRDB
@testable import MediaViewer

private enum ProcessingTestError: Error { case timeout, failure }

private func eventually(_ condition: @escaping () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while !(try await condition()) {
        guard ContinuousClock.now < deadline else { throw ProcessingTestError.timeout }
        try await Task.sleep(for: .milliseconds(2))
    }
}

final class AsyncSemaphoreProductionTests: XCTestCase {
    func testLastCancelledSharedImageRequestLeavesLimiterImmediately() async throws {
        let semaphore = AsyncSemaphore(limit: 1)
        let broker = SharedImageLoadBroker()
        try await semaphore.acquire()
        let request = Task {
            await broker.value(for: "cancelled-thumbnail") {
                do { try await semaphore.acquire() } catch { return nil }
                await semaphore.release()
                return nil
            }
        }
        try await eventually { await semaphore.snapshot.waiting == 1 }
        request.cancel()
        let result = await request.value
        XCTAssertNil(result)
        let state = await semaphore.snapshot
        XCTAssertEqual(state.waiting, 0)
        XCTAssertEqual(state.active, 1)
        await semaphore.release()
    }

    func testLoweringFourToOnePaysDownActivePermitsAndRaisingPreservesFIFO() async throws {
        let semaphore = AsyncSemaphore(limit: 4)
        for _ in 0..<4 { try await semaphore.acquire() }
        let first = Task { try await semaphore.acquire() }
        try await eventually { await semaphore.snapshot.waiting == 1 }
        let second = Task { try await semaphore.acquire() }
        try await eventually { await semaphore.snapshot.waiting == 2 }

        await semaphore.setLimit(1)
        for expectedActive in [3, 2, 1] {
            await semaphore.release()
            let state = await semaphore.snapshot
            XCTAssertEqual(state.active, expectedActive)
            XCTAssertEqual(state.waiting, 2, "A reduction must not hand an excess permit to a waiter")
        }
        await semaphore.release()
        try await first.value
        var state = await semaphore.snapshot
        XCTAssertEqual(state.active, 1)
        XCTAssertEqual(state.waiting, 1)
        await semaphore.setLimit(2)
        try await second.value
        state = await semaphore.snapshot
        XCTAssertEqual(state.active, 2)
        XCTAssertEqual(state.waiting, 0)
        await semaphore.release()
        await semaphore.release()
        state = await semaphore.snapshot
        XCTAssertEqual(state.active, 0)
    }

    func testCancelledWaiterRemovedWithoutReleasingAnUnownedPermit() async throws {
        let semaphore = AsyncSemaphore(limit: 1)
        try await semaphore.acquire()
        let cancelled = Task { try await semaphore.acquire() }
        try await eventually { await semaphore.snapshot.waiting == 1 }
        let survivor = Task { try await semaphore.acquire() }
        try await eventually { await semaphore.snapshot.waiting == 2 }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let state = await semaphore.snapshot
        XCTAssertEqual(state.active, 1)
        XCTAssertEqual(state.waiting, 1)
        await semaphore.release()
        try await survivor.value
        await semaphore.release()
        let drained = await semaphore.snapshot
        XCTAssertEqual(drained.active, 0)
    }

    func testCancellationGrantRaceBalancesPermits() async throws {
        let semaphore = AsyncSemaphore(limit: 1)
        for _ in 0..<100 {
            try await semaphore.acquire()
            let waiter = Task {
                do {
                    try await semaphore.acquire()
                    await semaphore.release() // Includes cancellation immediately after a grant.
                } catch is CancellationError { }
            }
            waiter.cancel()
            await semaphore.release()
            try await waiter.value
        }
        try await eventually { await semaphore.snapshot.waiting == 0 }
        let state = await semaphore.snapshot
        XCTAssertEqual(state.active, 0)
    }
}

private actor VisionProcessorProbe {
    private(set) var started: [UUID] = []
    private(set) var maximumActive = 0
    private var active: Set<UUID> = []
    private var suspended: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let gated: Bool
    private let failures: Set<UUID>

    init(gated: Bool = false, failures: Set<UUID> = []) { self.gated = gated; self.failures = failures }

    func process(_ id: UUID) async throws {
        started.append(id)
        XCTAssertTrue(active.insert(id).inserted, "Duplicate production admission")
        maximumActive = max(maximumActive, active.count)
        if gated { await withCheckedContinuation { suspended[id] = $0 } }
        active.remove(id)
        if failures.contains(id) { throw ProcessingTestError.failure }
    }

    func releaseAll() {
        let waiters = suspended.values
        suspended.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// This wraps only storage IO to expose actor reentrancy; all scheduling is the
/// shipped VisionJobQueue, not the older TestableVisionJobQueue clone.
private actor SuspendedVisionStorage: VisionQueueStorage {
    let base: DatabaseVisionQueueStorage
    var holdEnqueue = false
    var holdLoad = false
    private var failNextLoad = false
    private(set) var enqueueCalls = 0
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(database: DatabaseManager) { base = DatabaseVisionQueueStorage(database: database) }
    func suspendEnqueue() { holdEnqueue = true }
    func suspendLoad() { holdLoad = true }
    func failOneLoad() { failNextLoad = true }
    func release() { holdEnqueue = false; holdLoad = false; waiting = false; continuation?.resume(); continuation = nil }
    func enqueue(_ id: UUID, priority: JobPriority) async throws -> VisionPendingJob? {
        enqueueCalls += 1
        let result = try await base.enqueue(id, priority: priority)
        if holdEnqueue { waiting = true; await withCheckedContinuation { continuation = $0 } }
        return result
    }
    func seedIncomplete() async throws -> Int { try await base.seedIncomplete() }
    func load(limit: Int, excluding: Set<UUID>) async throws -> [VisionPendingJob] {
        if failNextLoad { failNextLoad = false; throw ProcessingTestError.failure }
        let result = try await base.load(limit: limit, excluding: excluding)
        if holdLoad { waiting = true; await withCheckedContinuation { continuation = $0 } }
        return result
    }
    func cancel(_ id: UUID) async throws { try await base.cancel(id) }
    func clear(excluding: Set<UUID>) async throws { try await base.clear(excluding: excluding) }
    func finish(_ job: VisionPendingJob, succeeded: Bool) async throws { try await base.finish(job, succeeded: succeeded) }
    func contains(_ id: UUID) async throws -> Bool { try await base.contains(id) }
}

final class VisionBoundedProductionTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VisionBounded-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: directory.appendingPathComponent("isolated.sqlite"))
        try await database.initialize()
    }

    override func tearDown() async throws {
        database = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func insert(_ count: Int, incomplete: Bool = false) async throws -> [UUID] {
        let ids = (0..<count).map { _ in UUID() }
        let root = directory!
        try await database.write { db in
            for id in ids {
                let item = MediaItem(id: id, basePath: root, metadataFile: root.appendingPathComponent("\(id).md"),
                                     mediaFiles: [root.appendingPathComponent("\(id).jpg")],
                                     metadata: MediaMetadata(source: URL(string: "https://example.com/\(id)")!, platform: "test", archivedDate: Date()))
                var record = MediaItemRecord(from: item)
                record.ocrText = incomplete ? nil : ""
                record.dominantColorsJSON = "[\"red\"]"
                record.perceptualHash = "done"
                try record.insert(db)
            }
        }
        return ids
    }

    private func queue(_ probe: VisionProcessorProbe, storage: (any VisionQueueStorage)? = nil, concurrency: Int = 4) -> VisionJobQueue {
        VisionJobQueue(database: database, storage: storage, processor: { try await probe.process($0) },
                       concurrency: concurrency, observesEnvironment: false)
    }

    private func waitForDrain(_ queue: VisionJobQueue) async throws {
        try await eventually {
            let state = await queue.diagnostics
            return state.processing == 0 && state.residentPending == 0 && !state.loading && !state.refillNeeded
        }
    }

    func testExplicitCompleteBacklogBeyond512SurvivesRestartAndDrainsExactlyOnce() async throws {
        let ids = try await insert(1_137)
        let oldProbe = VisionProcessorProbe()
        var oldQueue: VisionJobQueue? = queue(oldProbe)
        await oldQueue!.pause()
        await oldQueue!.enqueueBatch(ids)
        let resident = await oldQueue!.diagnostics
        XCTAssertEqual(resident.residentPending, 512)
        oldQueue = nil

        let probe = VisionProcessorProbe()
        let restarted = queue(probe)
        await restarted.requeueIncomplete() // Legacy complete items must still restore explicit intent.
        try await waitForDrain(restarted)
        let processed = await probe.started
        XCTAssertEqual(processed.count, ids.count)
        XCTAssertEqual(Set(processed), Set(ids))
        let maximumActive = await probe.maximumActive
        XCTAssertLessThanOrEqual(maximumActive, 4)
        let durableCount = try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM vision_pending_jobs") }
        XCTAssertEqual(durableCount, 0)
    }

    func testIncompleteRestoreRetriesDoNotStarveLaterPagesOrReseedExhaustedJobs() async throws {
        let ids = try await insert(520, incomplete: true)
        let probe = VisionProcessorProbe(failures: Set(ids))
        let queue = queue(probe)
        await queue.pause()
        await queue.requeueIncomplete()
        let state = await queue.diagnostics
        XCTAssertEqual(state.residentPending, 512)
        await queue.resume()
        try await waitForDrain(queue)
        let processed = await probe.started
        XCTAssertEqual(processed.count, ids.count * 3)
        XCTAssertEqual(Set(processed), Set(ids))
        await queue.requeueIncomplete()
        try await waitForDrain(queue)
        let afterReseed = await probe.started.count
        XCTAssertEqual(afterReseed, ids.count * 3)
    }

    func testPromotionFIFOAndPauseResumeUseProductionQueue() async throws {
        let ids = try await insert(4)
        let probe = VisionProcessorProbe(gated: true)
        let queue = queue(probe, concurrency: 1)
        await queue.pause()
        await queue.enqueueBatch(ids, priority: .low)
        await queue.enqueue(itemId: ids[2], priority: .high)
        await queue.enqueue(itemId: ids[3], priority: .normal)
        let pausedStarts = await probe.started
        XCTAssertTrue(pausedStarts.isEmpty)
        await queue.resume()
        for count in 1...4 {
            try await eventually { await probe.started.count == count }
            await probe.releaseAll()
        }
        try await waitForDrain(queue)
        let order = await probe.started
        XCTAssertEqual(order, [ids[2], ids[3], ids[0], ids[1]])
    }

    func testReservationDeduplicatesAndPromotesWhileStorageIsSuspended() async throws {
        let id = try await insert(1)[0]
        let storage = SuspendedVisionStorage(database: database)
        let probe = VisionProcessorProbe()
        let queue = queue(probe, storage: storage)
        await queue.pause()
        await storage.suspendEnqueue()
        let first = Task { await queue.enqueue(itemId: id, priority: .low) }
        try await eventually { await storage.waiting }
        await queue.enqueue(itemId: id, priority: .low)
        await queue.enqueue(itemId: id, priority: .high)
        await storage.release()
        await first.value
        let calls = await storage.enqueueCalls
        XCTAssertEqual(calls, 2, "One original write and one necessary promotion")
        let jobs = try await storage.base.load(limit: 512, excluding: [])
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.priority, .high)
        await queue.resume()
        try await waitForDrain(queue)
        let starts = await probe.started
        XCTAssertEqual(starts, [id])
    }

    func testClearRejectsSuspendedEnqueueAndRestoreGenerations() async throws {
        let id = try await insert(1, incomplete: true)[0]
        let storage = SuspendedVisionStorage(database: database)
        let queue = queue(VisionProcessorProbe(), storage: storage)
        await queue.pause()
        await storage.suspendEnqueue()
        let enqueue = Task { await queue.enqueue(itemId: id) }
        try await eventually { await storage.waiting }
        await queue.clearPending()
        await storage.release()
        await enqueue.value
        var state = await queue.diagnostics
        XCTAssertEqual(state.residentPending, 0)
        XCTAssertEqual(state.reservations, 0)
        await storage.suspendLoad()
        let restore = Task { await queue.requeueIncomplete() }
        try await eventually { await storage.waiting }
        await queue.clearPending()
        await storage.release()
        await restore.value
        state = await queue.diagnostics
        XCTAssertEqual(state.residentPending, 0)
        XCTAssertFalse(state.refillNeeded)
    }

    func testInFlightCompletionCannotEraseNewerForcedIntentOrRecreatedRow() async throws {
        let id = try await insert(1)[0]
        let store = DatabaseVisionQueueStorage(database: database)
        let originalJob = try await store.enqueue(id, priority: .low)
        let original = try XCTUnwrap(originalJob)
        _ = try await store.enqueue(id, priority: .high)
        try await store.finish(original, succeeded: true)
        var jobs = try await store.load(limit: 512, excluding: [])
        XCTAssertEqual(jobs.count, 1)
        let promoted = try XCTUnwrap(jobs.first)
        try await store.cancel(id)
        _ = try await store.enqueue(id, priority: .high)
        try await store.finish(promoted, succeeded: true)
        jobs = try await store.load(limit: 512, excluding: [])
        XCTAssertEqual(jobs.count, 1)
    }

    func testForcedIntentDuringProcessingRunsAgainButPendingForceRunsOnlyOnce() async throws {
        let id = try await insert(1)[0]
        let probe = VisionProcessorProbe(gated: true)
        let queue = queue(probe, concurrency: 1)
        await queue.pause()
        await queue.enqueue(itemId: id, priority: .high)
        await queue.reprocessOCR(itemId: id)
        await queue.resume()
        try await eventually { await probe.started.count == 1 }
        await queue.reprocessOCR(itemId: id)
        await probe.releaseAll()
        try await eventually { await probe.started.count == 2 }
        await probe.releaseAll()
        try await waitForDrain(queue)
        let starts = await probe.started
        XCTAssertEqual(starts, [id, id])
    }

    func testTransientRestoreFailureRetainsDurableWorkAndRetries() async throws {
        let ids = try await insert(1, incomplete: true)
        let storage = SuspendedVisionStorage(database: database)
        await storage.failOneLoad()
        let probe = VisionProcessorProbe()
        let queue = queue(probe, storage: storage)
        await queue.requeueIncomplete()
        let state = await queue.diagnostics
        XCTAssertTrue(state.refillNeeded)
        try await waitForDrain(queue)
        let starts = await probe.started
        XCTAssertEqual(starts, ids)
    }

    func testClearPendingKeepsRunningJobDurableAndDeletedJobsAreNotQueued() async throws {
        let ids = try await insert(2)
        let probe = VisionProcessorProbe(gated: true)
        let queue = queue(probe, concurrency: 1)
        await queue.enqueueBatch(ids)
        try await eventually { await probe.started.count == 1 }
        await queue.clearPending()
        let storage = DatabaseVisionQueueStorage(database: database)
        let activePersisted = try await storage.contains(ids[0])
        let pendingPersisted = try await storage.contains(ids[1])
        XCTAssertTrue(activePersisted)
        XCTAssertFalse(pendingPersisted)
        await probe.releaseAll()
        try await waitForDrain(queue)
        _ = try await storage.enqueue(ids[1], priority: .normal)
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET deletedAt = ? WHERE id = ?", arguments: ["2026-09-04", ids[1].uuidString])
        }
        let deletedQueued = await queue.isQueued(ids[1])
        XCTAssertFalse(deletedQueued)
    }
}
