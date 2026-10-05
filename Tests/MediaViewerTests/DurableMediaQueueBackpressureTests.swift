import Foundation
import GRDB
import XCTest
@testable import MediaViewer

final class DurableMediaQueueBackpressureTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurableMediaQueueBackpressureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testQueueBufferFrontRetryAndSelectiveRemovalPreserveFIFOOrder() throws {
        var buffer = DeduplicatingFIFOBuffer<Int>()
        XCTAssertEqual(buffer.append(contentsOf: 0..<512), 512)
        XCTAssertEqual(buffer.popFirst(), 0)
        XCTAssertTrue(buffer.prepend(0))
        XCTAssertFalse(buffer.prepend(0), "A cancellation retry must remain deduplicated")
        XCTAssertEqual(buffer.popFirst(), 0)

        XCTAssertEqual(buffer.removeAll { $0.isMultiple(of: 2) }, 255)
        var remaining: [Int] = []
        while let value = buffer.popFirst() {
            remaining.append(value)
        }
        XCTAssertEqual(remaining, Array(stride(from: 1, through: 511, by: 2)))

        // A 512-element Array/removeFirst queue would shift 130,816 elements. The resident
        // head-indexed window needs no compaction copies at this size.
        XCTAssertEqual(buffer.compactedElementCount, 0)
    }

    func testConcurrentDirectEnqueueUsesOneReservedEligibilityReadPerQueue() async throws {
        let database = try await makeDatabase(named: "concurrent.sqlite")
        let item = makeItem(index: 0)
        try await insert([item], into: database)

        let transcription = TranscriptionQueue(database: database)
        let video = VideoUnderstandingQueue(database: database)
        await transcription.pause()
        await video.pause()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask { await transcription.enqueue(itemId: item.id) }
                group.addTask { await video.enqueue(itemId: item.id) }
            }
        }

        let transcriptionStatus = await transcription.currentStatus
        let transcriptionDiagnostics = await transcription.diagnostics()
        XCTAssertEqual(transcriptionStatus.queued, 1)
        XCTAssertEqual(transcriptionStatus.phase, "queued")
        XCTAssertEqual(transcriptionDiagnostics.singleEligibilityQueryCount, 1)
        XCTAssertEqual(transcriptionDiagnostics.duplicateEnqueueDropCount, 63)

        let videoStatus = await video.currentStatus
        let videoDiagnostics = await video.diagnostics()
        XCTAssertEqual(videoStatus.queued, 1)
        XCTAssertEqual(videoStatus.phase, "queued")
        XCTAssertEqual(videoDiagnostics.singleEligibilityQueryCount, 1)
        XCTAssertEqual(videoDiagnostics.duplicateEnqueueDropCount, 63)
    }

    func testRestartBatchRestoresPersistedProcessingAndHonorsRetryCeilings() async throws {
        let database = try await makeDatabase(named: "restart.sqlite")
        let items = (0..<5).map(makeItem(index:))
        try await insert(items, into: database)
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE media_items
                    SET transcription_status = 'failed', transcription_retry_count = 2,
                        video_understanding_status = 'failed', video_understanding_retry_count = 2
                    WHERE id = ?
                """,
                arguments: [items[1].id.uuidString]
            )
            try db.execute(
                sql: """
                    UPDATE media_items
                    SET transcription_status = 'failed', transcription_retry_count = 3,
                        video_understanding_status = 'failed', video_understanding_retry_count = 3
                    WHERE id = ?
                """,
                arguments: [items[2].id.uuidString]
            )
            try db.execute(
                sql: """
                    UPDATE media_items
                    SET transcription_status = 'complete', transcription_version = ?,
                        video_understanding_status = 'complete', video_understanding_version = ?
                    WHERE id = ?
                """,
                arguments: [
                    TranscriptTimelineBuilder.currentVersion,
                    VideoTimelineBuilder.currentVersion,
                    items[3].id.uuidString
                ]
            )
            try db.execute(
                sql: """
                    UPDATE media_items
                    SET transcription_status = 'processing',
                        video_understanding_status = 'processing'
                    WHERE id = ?
                """,
                arguments: [items[4].id.uuidString]
            )
        }

        let transcription = TranscriptionQueue(database: database)
        let video = VideoUnderstandingQueue(database: database)
        await transcription.pause()
        await video.pause()
        await transcription.requeueIncomplete()
        await video.requeueIncomplete()

        let transcriptionStatus = await transcription.currentStatus
        let transcriptionDiagnostics = await transcription.diagnostics()
        XCTAssertEqual(transcriptionStatus.queued, 3, "nil, retryable failure, and interrupted processing must resume")
        XCTAssertEqual(transcriptionDiagnostics.persistentBatchQueryCount, 1)
        XCTAssertEqual(transcriptionDiagnostics.singleEligibilityQueryCount, 0)

        let videoStatus = await video.currentStatus
        let videoDiagnostics = await video.diagnostics()
        XCTAssertEqual(videoStatus.queued, 3, "nil, retryable failure, and interrupted processing must resume")
        XCTAssertEqual(videoDiagnostics.persistentBatchQueryCount, 1)
        XCTAssertEqual(videoDiagnostics.singleEligibilityQueryCount, 0)
    }

    func testLargeRestartKeepsBoundedResidentWindowsAndRefillsFromSQLite() async throws {
        let database = try await makeDatabase(named: "bounded.sqlite")
        let total = TranscriptionQueue.maxResidentPendingJobs + 37
        let items = (0..<total).map(makeItem(index:))
        try await insert(items, into: database)

        let transcription = TranscriptionQueue(database: database)
        let video = VideoUnderstandingQueue(database: database)
        await transcription.pause()
        await video.pause()
        await transcription.requeueIncomplete()
        await video.requeueIncomplete()

        var transcriptionDiagnostics = await transcription.diagnostics()
        var videoDiagnostics = await video.diagnostics()
        XCTAssertEqual(transcriptionDiagnostics.residentPendingCount, 512)
        XCTAssertEqual(videoDiagnostics.residentPendingCount, 512)
        XCTAssertTrue(transcriptionDiagnostics.hasDurableOverflow)
        XCTAssertTrue(videoDiagnostics.hasDurableOverflow)
        XCTAssertEqual(transcriptionDiagnostics.persistentBatchQueryCount, 1)
        XCTAssertEqual(videoDiagnostics.persistentBatchQueryCount, 1)

        let newest = try XCTUnwrap(items.last)
        await transcription.clear(itemId: newest.id)
        await video.clear(itemId: newest.id)
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE media_items
                    SET transcription_status = 'complete', transcription_version = ?,
                        video_understanding_status = 'complete', video_understanding_version = ?
                    WHERE id = ?
                """,
                arguments: [
                    TranscriptTimelineBuilder.currentVersion,
                    VideoTimelineBuilder.currentVersion,
                    newest.id.uuidString
                ]
            )
        }

        await transcription.requeueIncomplete()
        await video.requeueIncomplete()
        transcriptionDiagnostics = await transcription.diagnostics()
        videoDiagnostics = await video.diagnostics()

        XCTAssertEqual(transcriptionDiagnostics.residentPendingCount, 512)
        XCTAssertEqual(videoDiagnostics.residentPendingCount, 512)
        XCTAssertEqual(transcriptionDiagnostics.persistentBatchQueryCount, 2)
        XCTAssertEqual(videoDiagnostics.persistentBatchQueryCount, 2)

        let durableTranscriptionCount = try await eligibleCount(
            statusColumn: "transcription_status",
            versionColumn: "transcription_version",
            currentVersion: TranscriptTimelineBuilder.currentVersion,
            database: database
        )
        let durableVideoCount = try await eligibleCount(
            statusColumn: "video_understanding_status",
            versionColumn: "video_understanding_version",
            currentVersion: VideoTimelineBuilder.currentVersion,
            database: database
        )
        XCTAssertEqual(durableTranscriptionCount, total - 1)
        XCTAssertEqual(durableVideoCount, total - 1)
        XCTAssertGreaterThan(durableTranscriptionCount, transcriptionDiagnostics.residentPendingCount)
        XCTAssertGreaterThan(durableVideoCount, videoDiagnostics.residentPendingCount)
    }

    func testPersistentLoadFailureProducesVisibleErrorPhase() async {
        let database = DatabaseManager(
            databaseURL: temporaryDirectory.appendingPathComponent("uninitialized.sqlite")
        )
        let transcription = TranscriptionQueue(database: database)
        let video = VideoUnderstandingQueue(database: database)
        await transcription.pause()
        await video.pause()

        await transcription.requeueIncomplete()
        await video.requeueIncomplete()

        let transcriptionStatus = await transcription.currentStatus
        let videoStatus = await video.currentStatus
        XCTAssertEqual(transcriptionStatus.phase, "error")
        XCTAssertEqual(videoStatus.phase, "error")
        XCTAssertFalse(transcriptionStatus.isIdle)
        XCTAssertFalse(videoStatus.isIdle)
        XCTAssertFalse(transcriptionStatus.displayText.isEmpty)
        XCTAssertFalse(videoStatus.displayText.isEmpty)
    }

    func testEmptyPersistentLoadReturnsToIdle() async throws {
        let database = try await makeDatabase(named: "empty.sqlite")
        let transcription = TranscriptionQueue(database: database)
        let video = VideoUnderstandingQueue(database: database)
        await transcription.pause()
        await video.pause()

        await transcription.requeueIncomplete()
        await video.requeueIncomplete()

        let transcriptionStatus = await transcription.currentStatus
        let videoStatus = await video.currentStatus
        XCTAssertEqual(transcriptionStatus, .idle)
        XCTAssertEqual(videoStatus, .idle)
    }

    private func makeDatabase(named name: String) async throws -> DatabaseManager {
        let database = DatabaseManager(databaseURL: temporaryDirectory.appendingPathComponent(name))
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
        let basePath = temporaryDirectory.appendingPathComponent("archive", isDirectory: true)
        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("\(id.uuidString).md"),
            mediaFiles: [basePath.appendingPathComponent("asset-\(index).mp4")],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/queue/\(index)")!,
                platform: "test",
                archivedDate: Date(timeIntervalSince1970: TimeInterval(index))
            ),
            aspectRatio: 16.0 / 9.0
        )
    }

    private func eligibleCount(
        statusColumn: String,
        versionColumn: String,
        currentVersion: Int,
        database: DatabaseManager
    ) async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM media_items
                    WHERE \(statusColumn) IS NULL
                       OR \(statusColumn) IN ('none', 'failed', 'processing')
                       OR COALESCE(\(versionColumn), 0) < ?
                """,
                arguments: [currentVersion]
            ) ?? 0
        }
    }
}
