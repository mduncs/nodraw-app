import Foundation
import XCTest
@testable import MediaViewer

final class PipelineBackpressureTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineBackpressureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testPreferredSourceSkipsMissingFilesAndExistingVideo() throws {
        let video = try makeFile(named: "clip.mp4")
        let context = try makeFile(named: "context.png")
        let missingStill = tempDirectory.appendingPathComponent("missing.jpg")

        let result = PipelineAdapter.preferredExistingStillURL(
            mediaPaths: [missingStill.path, video.path],
            contextPath: context.path
        )

        XCTAssertEqual(result, context)
    }

    func testPreferredSourceUsesLaterStillBeforeContext() throws {
        let video = try makeFile(named: "clip.mov")
        let still = try makeFile(named: "second.jpeg")
        let context = try makeFile(named: "context.webp")

        let result = PipelineAdapter.preferredExistingStillURL(
            mediaPaths: [video.path, still.path],
            contextPath: context.path
        )

        XCTAssertEqual(result, still)
    }

    func testPreferredSourceReturnsNilForVideoOnlyCandidate() throws {
        let video = try makeFile(named: "clip.m4v")

        let result = PipelineAdapter.preferredExistingStillURL(
            mediaPaths: [video.path],
            contextPath: nil
        )

        XCTAssertNil(result)
    }

    func testPendingBufferDeduplicatesWithoutChangingFIFOOrder() throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        var buffer = DeduplicatingFIFOBuffer<UUID>()

        XCTAssertEqual(buffer.append(contentsOf: [first, second, first, third, second]), 3)
        XCTAssertEqual(buffer.count, 3)
        XCTAssertTrue(buffer.contains(second))
        XCTAssertEqual(buffer.popFirst(), first)
        XCTAssertEqual(buffer.popFirst(), second)
        XCTAssertEqual(buffer.popFirst(), third)
        XCTAssertNil(buffer.popFirst())
        XCTAssertTrue(buffer.isEmpty)
    }

    func testPendingBufferDrainHasLinearStructuralCopyBound() throws {
        let count = 20_000
        var buffer = DeduplicatingFIFOBuffer<Int>()
        XCTAssertEqual(buffer.append(contentsOf: 0..<count), count)

        for expected in 0..<count {
            XCTAssertEqual(buffer.popFirst(), expected)
        }

        // Array.removeFirst() would shift n(n-1)/2 = 199,990,000 elements here. Head-indexed
        // compaction copies fewer than 2n elements and leaves no resident jobs behind.
        let oldShiftCount = count * (count - 1) / 2
        XCTAssertLessThan(buffer.compactedElementCount, count * 2)
        XCTAssertLessThan(buffer.compactedElementCount, oldShiftCount / 1_000)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testConcurrentEnqueueReservesIDBeforeEligibilityAwait() async throws {
        let database = try await makeDatabase(named: "concurrent-enqueue.sqlite")
        let item = makeItem(index: 0)
        try await insert([item], into: database)
        let queue = PipelineQueue(database: database)
        await queue.pause()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await queue.enqueue(itemId: item.id)
                }
            }
        }

        let status = await queue.currentStatus
        let diagnostics = await queue.diagnostics()
        XCTAssertEqual(status.queued, 1)
        XCTAssertEqual(diagnostics.singleEligibilityQueryCount, 1)
        XCTAssertEqual(diagnostics.duplicateEnqueueDropCount, 99)
    }

    func testRestartRequeueUsesOneQueryAndHonorsDurableRetryState() async throws {
        let database = try await makeDatabase(named: "durable-requeue.sqlite")
        let items = (0..<6).map(makeItem(index:))
        try await insert(items, into: database)
        try await database.write { db in
            try db.execute(
                sql: "UPDATE media_items SET pipeline_status = 'phase1' WHERE id = ?",
                arguments: [items[1].id.uuidString]
            )
            try db.execute(
                sql: "UPDATE media_items SET pipeline_status = 'failed', pipeline_retry_count = 2 WHERE id = ?",
                arguments: [items[2].id.uuidString]
            )
            try db.execute(
                sql: "UPDATE media_items SET pipeline_status = 'failed', pipeline_retry_count = 3 WHERE id = ?",
                arguments: [items[3].id.uuidString]
            )
            try db.execute(
                sql: "UPDATE media_items SET pipeline_status = 'complete' WHERE id = ?",
                arguments: [items[4].id.uuidString]
            )
            try db.execute(
                sql: "UPDATE media_items SET deletedAt = ? WHERE id = ?",
                arguments: [Date(), items[5].id.uuidString]
            )
        }

        let queue = PipelineQueue(database: database)
        await queue.pause()
        await queue.requeueIncomplete()

        let status = await queue.currentStatus
        let diagnostics = await queue.diagnostics()
        XCTAssertEqual(status.queued, 3, "none, phase1, and retryable failed rows must resume")
        XCTAssertEqual(diagnostics.persistentBatchQueryCount, 1)
        XCTAssertEqual(
            diagnostics.singleEligibilityQueryCount,
            0,
            "A restart batch must not repeat one eligibility query per durable row"
        )
    }

    func testRestartQueueKeepsOnlyBoundedResidentWindow() async throws {
        let database = try await makeDatabase(named: "bounded-requeue.sqlite")
        let count = PipelineQueue.maxResidentPendingJobs + 75
        try await insert((0..<count).map(makeItem(index:)), into: database)
        let queue = PipelineQueue(database: database)
        await queue.pause()

        await queue.requeueIncomplete()

        let status = await queue.currentStatus
        XCTAssertEqual(status.queued, PipelineQueue.maxResidentPendingJobs)
        XCTAssertLessThan(status.queued, count)
    }

    func testPersistentLoadFailureIsObservableInsteadOfReportingSilentSuccess() async {
        let uninitialized = DatabaseManager(
            databaseURL: tempDirectory.appendingPathComponent("uninitialized.sqlite")
        )
        let queue = PipelineQueue(database: uninitialized)
        await queue.pause()

        await queue.requeueIncomplete()

        let status = await queue.currentStatus
        XCTAssertEqual(status.phase, "error")
        XCTAssertNotNil(status.lastError)
        XCTAssertTrue(status.displayText.hasPrefix("Pipeline error:"))
    }

    private func makeFile(named name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        let created = FileManager.default.createFile(atPath: url.path, contents: Data())
        XCTAssertTrue(created)
        return url
    }

    private func makeDatabase(named name: String) async throws -> DatabaseManager {
        let database = DatabaseManager(databaseURL: tempDirectory.appendingPathComponent(name))
        try await database.initialize()
        return database
    }

    private func insert(_ items: [MediaItem], into database: DatabaseManager) async throws {
        try await database.write { db in
            for item in items {
                try MediaItemRecord(from: item).insert(db)
            }
        }
    }

    private func makeItem(index: Int) -> MediaItem {
        let id = UUID()
        let basePath = tempDirectory.appendingPathComponent("archive", isDirectory: true)
        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("\(id.uuidString).md"),
            mediaFiles: [basePath.appendingPathComponent("asset-\(index).jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/pipeline/\(index)")!,
                platform: "test"
            ),
            aspectRatio: 1
        )
    }
}
