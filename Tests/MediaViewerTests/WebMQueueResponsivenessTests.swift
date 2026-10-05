import GRDB
import Foundation
import XCTest
@testable import MediaViewer

final class WebMQueueResponsivenessTests: XCTestCase {
    func testSilentWebMCompletesAsEmptyTranscriptWithoutRetry() async throws {
        guard let ffmpegURL = DependencyManager.executableURL(named: "ffmpeg"),
              let ffprobeURL = DependencyManager.executableURL(named: "ffprobe") else {
            throw XCTSkip("ffmpeg and ffprobe are required")
        }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("silent.webm")
        try makeFixture(
            at: sourceURL,
            ffmpegURL: ffmpegURL,
            inputs: [
                "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10:duration=1",
                "-c:v", "libvpx", "-deadline", "realtime", "-cpu-used", "8", "-an"
            ]
        )

        let database = DatabaseManager(databaseURL: root.appendingPathComponent("silent.sqlite"))
        try await database.initialize()
        let itemId = UUID()
        try await insertItem(itemId: itemId, mediaURL: sourceURL, database: database)

        let extractor = WebMDerivedAssetExtractor(
            ffmpegURL: ffmpegURL,
            ffprobeURL: ffprobeURL,
            temporaryRoot: root.appendingPathComponent("derived", isDirectory: true)
        )
        let queue = TranscriptionQueue(
            database: database,
            webMExtractor: extractor,
            webMWorkCoordinator: WebMBackgroundWorkCoordinator()
        )
        await queue.enqueue(itemId: itemId)

        let state = try await waitForState(itemId: itemId, database: database) {
            $0.transcriptionStatus == "complete"
                && $0.transcriptionVersion == TranscriptTimelineBuilder.currentVersion
        }
        XCTAssertEqual(state.transcriptionRetryCount, 0)
        XCTAssertNil(state.transcriptionLastError)
        XCTAssertEqual(state.transcriptSegmentCount, 0)
    }

    func testAudioOnlyWebMIsExcludedFromVideoQueueWithoutFailure() async throws {
        guard let ffmpegURL = DependencyManager.executableURL(named: "ffmpeg"),
              let ffprobeURL = DependencyManager.executableURL(named: "ffprobe") else {
            throw XCTSkip("ffmpeg and ffprobe are required")
        }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("audio-only.webm")
        try makeFixture(
            at: sourceURL,
            ffmpegURL: ffmpegURL,
            inputs: [
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1",
                "-c:a", "libopus", "-vn"
            ]
        )

        let database = DatabaseManager(databaseURL: root.appendingPathComponent("audio-only.sqlite"))
        try await database.initialize()
        let itemId = UUID()
        try await insertItem(itemId: itemId, mediaURL: sourceURL, database: database)

        let extractor = WebMDerivedAssetExtractor(
            ffmpegURL: ffmpegURL,
            ffprobeURL: ffprobeURL,
            temporaryRoot: root.appendingPathComponent("derived", isDirectory: true)
        )
        let queue = VideoUnderstandingQueue(
            database: database,
            webMExtractor: extractor,
            webMWorkCoordinator: WebMBackgroundWorkCoordinator()
        )
        await queue.enqueue(itemId: itemId)

        let status = await queue.currentStatus
        XCTAssertEqual(status, .idle)
        let state = try await readState(itemId: itemId, database: database)
        XCTAssertEqual(state.videoStatus, "complete")
        XCTAssertEqual(state.videoVersion, VideoTimelineBuilder.currentVersion)
        XCTAssertEqual(state.videoRetryCount, 0)
        XCTAssertNil(state.videoLastError)
        XCTAssertEqual(state.videoSegmentCount, 0)
    }

    func testConcurrentEnqueueUsesAtomicReservation() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager(databaseURL: root.appendingPathComponent("reservation.sqlite"))
        try await database.initialize()

        let transcriptionId = UUID()
        let videoId = UUID()
        try await insertItem(
            itemId: transcriptionId,
            mediaURL: root.appendingPathComponent("missing-transcription.webm"),
            database: database
        )
        try await insertItem(
            itemId: videoId,
            mediaURL: root.appendingPathComponent("missing-video.webm"),
            database: database
        )

        let transcription = TranscriptionQueue(database: database)
        let video = VideoUnderstandingQueue(database: database)
        await transcription.pause()
        await video.pause()

        async let transcriptionA: Void = transcription.enqueue(itemId: transcriptionId)
        async let transcriptionB: Void = transcription.enqueue(itemId: transcriptionId)
        async let videoA: Void = video.enqueue(itemId: videoId)
        async let videoB: Void = video.enqueue(itemId: videoId)
        _ = await (transcriptionA, transcriptionB, videoA, videoB)

        let transcriptionStatus = await transcription.currentStatus
        let videoStatus = await video.currentStatus
        XCTAssertEqual(transcriptionStatus.queued, 1)
        XCTAssertEqual(videoStatus.queued, 1)
    }

    func testInteractionAndPauseCancellationRequeueWhileClearCancelsActiveExtraction() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeFFmpeg = try makeCancellableFakeFFmpeg(in: root)
        let fakeFFprobe = try makeFakeFFprobe(in: root)
        let sourceURL = root.appendingPathComponent("busy.webm")
        try Data([0]).write(to: sourceURL)
        let derivedRoot = root.appendingPathComponent("derived", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedRoot, withIntermediateDirectories: true)

        let database = DatabaseManager(databaseURL: root.appendingPathComponent("cancel.sqlite"))
        try await database.initialize()
        let itemId = UUID()
        try await insertItem(itemId: itemId, mediaURL: sourceURL, database: database)

        let extractor = WebMDerivedAssetExtractor(
            ffmpegURL: fakeFFmpeg,
            ffprobeURL: fakeFFprobe,
            temporaryRoot: derivedRoot,
            configuration: .init(audioTimeout: 30, terminationGrace: 0.05)
        )
        let queue = TranscriptionQueue(
            database: database,
            webMExtractor: extractor,
            webMWorkCoordinator: WebMBackgroundWorkCoordinator()
        )
        await queue.enqueue(itemId: itemId)
        try await waitUntil {
            let status = await queue.currentStatus
            let hasDerivedWork = !(try contents(of: derivedRoot).isEmpty)
            return status.processing == 1 && hasDerivedWork
        }

        let cancellationStarted = Date()
        await queue.interactionStateDidChange(.foregroundInteracting)
        try await waitUntil {
            let status = await queue.currentStatus
            return status.processing == 0 && status.queued == 1
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancellationStarted), 1.5)
        XCTAssertTrue(try contents(of: derivedRoot).isEmpty)
        var state = try await readState(itemId: itemId, database: database)
        XCTAssertEqual(state.transcriptionStatus, "none")
        XCTAssertEqual(state.transcriptionRetryCount, 0)
        XCTAssertNil(state.transcriptionLastError)

        await queue.interactionStateDidChange(.foregroundIdle)
        try await waitUntil {
            let status = await queue.currentStatus
            return status.processing == 1
        }
        await queue.pause()
        try await waitUntil {
            let status = await queue.currentStatus
            return status.processing == 0 && status.queued == 1
        }
        state = try await readState(itemId: itemId, database: database)
        XCTAssertEqual(state.transcriptionStatus, "none")
        XCTAssertEqual(state.transcriptionRetryCount, 0)

        await queue.resume()
        try await waitUntil {
            let status = await queue.currentStatus
            return status.processing == 1
        }
        await queue.clear(itemId: itemId)
        try await waitUntil {
            let status = await queue.currentStatus
            return status.processing == 0 && status.queued == 0
        }
        XCTAssertTrue(try contents(of: derivedRoot).isEmpty)
        state = try await readState(itemId: itemId, database: database)
        XCTAssertEqual(state.transcriptionStatus, "none")
        XCTAssertEqual(state.transcriptionRetryCount, 0)
    }

    func testVideoExtractionPauseCancelsAndRequeuesWithoutFailure() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeFFmpeg = try makeCancellableFakeFFmpeg(in: root)
        let fakeFFprobe = try makeFakeFFprobe(in: root)
        let sourceURL = root.appendingPathComponent("busy-video.webm")
        try Data([0]).write(to: sourceURL)
        let derivedRoot = root.appendingPathComponent("derived", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedRoot, withIntermediateDirectories: true)

        let database = DatabaseManager(databaseURL: root.appendingPathComponent("video-cancel.sqlite"))
        try await database.initialize()
        let itemId = UUID()
        try await insertItem(itemId: itemId, mediaURL: sourceURL, database: database)

        let extractor = WebMDerivedAssetExtractor(
            ffmpegURL: fakeFFmpeg,
            ffprobeURL: fakeFFprobe,
            temporaryRoot: derivedRoot,
            configuration: .init(videoTimeout: 30, terminationGrace: 0.05)
        )
        let queue = VideoUnderstandingQueue(
            database: database,
            webMExtractor: extractor,
            webMWorkCoordinator: WebMBackgroundWorkCoordinator()
        )
        await queue.enqueue(itemId: itemId)
        try await waitUntil {
            let status = await queue.currentStatus
            return status.processing == 1
        }

        await queue.pause()
        try await waitUntil {
            let status = await queue.currentStatus
            return status.processing == 0 && status.queued == 1
        }
        let state = try await readState(itemId: itemId, database: database)
        XCTAssertEqual(state.videoStatus, "none")
        XCTAssertEqual(state.videoRetryCount, 0)
        XCTAssertNil(state.videoLastError)
        XCTAssertTrue(try contents(of: derivedRoot).isEmpty)

        await queue.clear(itemId: itemId)
        let clearedStatus = await queue.currentStatus
        XCTAssertEqual(clearedStatus, .idle)
    }

    func testSharedWebMCoordinatorSerializesAndCancelsWaiters() async throws {
        let coordinator = WebMBackgroundWorkCoordinator()
        let gauge = ConcurrencyGauge()
        let sourceA = URL(fileURLWithPath: "/tmp/a.webm")
        let sourceB = URL(fileURLWithPath: "/tmp/b.webm")

        let first = Task {
            try await coordinator.withExclusiveAccess(to: sourceA) {
                await gauge.enter()
                do {
                    try await Task.sleep(for: .milliseconds(200))
                    await gauge.leave()
                } catch {
                    await gauge.leave()
                    throw error
                }
            }
        }
        try await waitUntil {
            let snapshot = await coordinator.snapshot()
            return snapshot.isActive
        }

        let cancelledWaiter = Task {
            try await coordinator.withExclusiveAccess(to: sourceB) {
                await gauge.enter()
                await gauge.leave()
            }
        }
        try await waitUntil {
            let snapshot = await coordinator.snapshot()
            return snapshot.waiting == 1
        }
        cancelledWaiter.cancel()
        do {
            try await cancelledWaiter.value
            XCTFail("Expected a waiting WebM job to cancel")
        } catch is CancellationError {
            // Expected.
        }

        try await first.value
        let snapshot = await coordinator.snapshot()
        let maximumConcurrency = await gauge.maximum()
        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(snapshot.waiting, 0)
        XCTAssertEqual(maximumConcurrency, 1)
    }

    private struct QueueState {
        let transcriptionStatus: String
        let transcriptionVersion: Int
        let transcriptionRetryCount: Int
        let transcriptionLastError: String?
        let transcriptSegmentCount: Int
        let videoStatus: String
        let videoVersion: Int
        let videoRetryCount: Int
        let videoLastError: String?
        let videoSegmentCount: Int
    }

    private func waitForState(
        itemId: UUID,
        database: DatabaseManager,
        predicate: (QueueState) -> Bool
    ) async throws -> QueueState {
        var last = try await readState(itemId: itemId, database: database)
        for _ in 0..<200 {
            if predicate(last) { return last }
            try await Task.sleep(for: .milliseconds(10))
            last = try await readState(itemId: itemId, database: database)
        }
        XCTFail("Timed out waiting for queue state")
        throw QueueTestTimeout()
    }

    private func waitUntil(
        _ predicate: () async throws -> Bool
    ) async throws {
        for _ in 0..<200 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for asynchronous condition")
        throw QueueTestTimeout()
    }

    private func readState(itemId: UUID, database: DatabaseManager) async throws -> QueueState {
        try await database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT transcription_status, transcription_version,
                           transcription_retry_count, transcription_last_error,
                           video_understanding_status, video_understanding_version,
                           video_understanding_retry_count, video_understanding_last_error
                    FROM media_items WHERE id = ?
                """,
                arguments: [itemId.uuidString]
            )!
            return QueueState(
                transcriptionStatus: row["transcription_status"],
                transcriptionVersion: row["transcription_version"],
                transcriptionRetryCount: row["transcription_retry_count"],
                transcriptionLastError: row["transcription_last_error"],
                transcriptSegmentCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM transcript_segments WHERE item_id = ?",
                    arguments: [itemId.uuidString]
                ) ?? 0,
                videoStatus: row["video_understanding_status"],
                videoVersion: row["video_understanding_version"],
                videoRetryCount: row["video_understanding_retry_count"],
                videoLastError: row["video_understanding_last_error"],
                videoSegmentCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM video_segments WHERE item_id = ?",
                    arguments: [itemId.uuidString]
                ) ?? 0
            )
        }
    }

    private func insertItem(
        itemId: UUID,
        mediaURL: URL,
        database: DatabaseManager
    ) async throws {
        let mediaJSON = String(
            decoding: try JSONEncoder().encode([mediaURL.path]),
            as: UTF8.self
        )
        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO media_items (
                        id, basePathString, metadataFileString, mediaFilesJSON,
                        sourceURL, platform, archivedDate, starred, tagsJSON, parseStatus,
                        transcription_status, transcription_version, transcription_retry_count,
                        video_understanding_status, video_understanding_version,
                        video_understanding_retry_count
                    ) VALUES (?, ?, ?, ?, ?, 'test', ?, 0, '[]', 'success',
                              'none', 0, 0, 'none', 0, 0)
                """,
                arguments: [
                    itemId.uuidString,
                    mediaURL.deletingLastPathComponent().path,
                    mediaURL.deletingPathExtension().appendingPathExtension("md").path,
                    mediaJSON,
                    "https://example.invalid/\(itemId.uuidString)",
                    Date()
                ]
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WebMQueueResponsivenessTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeFixture(at outputURL: URL, ffmpegURL: URL, inputs: [String]) throws {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
            + inputs
            + [outputURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("ffmpeg cannot encode the synthetic WebM fixture")
        }
    }

    private func makeCancellableFakeFFmpeg(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("ffmpeg")
        let script = """
            #!/bin/sh
            trap 'exit 0' TERM INT
            while :
            do
                sleep 0.05
            done
            """
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeFakeFFprobe(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("ffprobe")
        let script = """
            #!/bin/sh
            printf '%s\\n' '{"streams":[{"codec_type":"video","start_time":"0.000000"},{"codec_type":"audio","start_time":"0.000000"}],"format":{"start_time":"0.000000","duration":"1.000000"}}'
            """
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func contents(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
    }
}

private actor ConcurrencyGauge {
    private var current = 0
    private var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }

    func maximum() -> Int { peak }
}

private struct QueueTestTimeout: Error {}
