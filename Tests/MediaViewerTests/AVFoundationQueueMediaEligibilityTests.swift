import GRDB
import XCTest
@testable import MediaViewer

final class AVFoundationQueueMediaEligibilityTests: XCTestCase {
    func testReprocessAndForcedEnqueueIncludeWebMAndNativeMedia() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AVFoundationQueueMediaEligibilityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let database = DatabaseManager(databaseURL: tempDirectory.appendingPathComponent("queue.sqlite"))
        try await database.initialize()

        let webMId = UUID()
        let nativeId = UUID()
        try await database.write { db in
            try Self.insertItem(
                id: webMId,
                mediaPath: "/archive/preserved.webm",
                metadataPath: "/archive/preserved.md",
                in: db
            )
            try Self.insertItem(
                id: nativeId,
                mediaPath: "/archive/native.mp4",
                metadataPath: "/archive/native.md",
                in: db
            )
            try Self.insertSegments(itemId: webMId, sourcePath: "/archive/preserved.webm", in: db)
            try Self.insertSegments(itemId: nativeId, sourcePath: "/archive/native.mp4", in: db)
        }

        let transcriptionQueue = TranscriptionQueue(database: database)
        let videoQueue = VideoUnderstandingQueue(database: database)
        await transcriptionQueue.pause()
        await videoQueue.pause()

        let transcriptionReprocessCount = await transcriptionQueue.reprocessAll()
        let videoReprocessCount = await videoQueue.reprocessAll()
        XCTAssertEqual(transcriptionReprocessCount, 2)
        XCTAssertEqual(videoReprocessCount, 2)

        // These are already pending after reprocessAll, so duplicate force requests
        // remain harmless while WebM is treated as an eligible derived-media job.
        await transcriptionQueue.enqueue(itemId: webMId, force: true)
        await videoQueue.enqueue(itemId: webMId, force: true)

        let webMState = try await state(for: webMId, database: database)
        XCTAssertEqual(webMState.transcriptionStatus, "none")
        XCTAssertEqual(webMState.transcriptionVersion, 0)
        XCTAssertEqual(webMState.transcriptionRetryCount, 0)
        XCTAssertEqual(webMState.transcriptionSegmentCount, 0)
        XCTAssertEqual(webMState.videoStatus, "none")
        XCTAssertEqual(webMState.videoVersion, 0)
        XCTAssertEqual(webMState.videoRetryCount, 0)
        XCTAssertEqual(webMState.videoSegmentCount, 0)

        let nativeState = try await state(for: nativeId, database: database)
        XCTAssertEqual(nativeState.transcriptionStatus, "none")
        XCTAssertEqual(nativeState.transcriptionVersion, 0)
        XCTAssertEqual(nativeState.transcriptionRetryCount, 0)
        XCTAssertEqual(nativeState.transcriptionSegmentCount, 0)
        XCTAssertEqual(nativeState.videoStatus, "none")
        XCTAssertEqual(nativeState.videoVersion, 0)
        XCTAssertEqual(nativeState.videoRetryCount, 0)
        XCTAssertEqual(nativeState.videoSegmentCount, 0)

        let transcriptionStatus = await transcriptionQueue.currentStatus
        let videoStatus = await videoQueue.currentStatus
        XCTAssertEqual(transcriptionStatus.queued, 2)
        XCTAssertEqual(videoStatus.queued, 2)
    }

    func testTranscriptionSelectionUsesNativeInputsFirstAndWebMAsDerivedFallback() throws {
        let cases: [([String], Int?)] = [
            (["/archive/clip.webm"], 0),
            (["/archive/clip.WEBM"], 0),
            (["/archive/clip.mp4"], 0),
            (["/archive/clip.webm", "/archive/clip.MOV"], 1),
            (["/archive/clip.webm", "/archive/speech.m4a"], 1),
            (["/archive/still.png"], nil)
        ]

        for (paths, expectedIndex) in cases {
            let json = try encode(paths)
            let selected = TranscriptionQueue.firstTranscribablePath(in: json)
            let sqlEligible = try matchesSQLPredicate(
                TranscriptionQueue.transcribableMediaPredicateSQL,
                mediaFilesJSON: json
            )

            XCTAssertEqual(selected?.index, expectedIndex, "Unexpected selection for \(paths)")
            XCTAssertEqual(sqlEligible, expectedIndex != nil, "SQL/in-memory mismatch for \(paths)")
        }

        XCTAssertFalse(TranscriptionQueue.isVideoExtension("webm"))
        XCTAssertTrue(TranscriptionQueue.isTranscribableExtension("webm"))
        XCTAssertTrue(TranscriptionQueue.isVideoExtension("mp4"))
        XCTAssertTrue(TranscriptionQueue.isAudioExtension("m4a"))
        XCTAssertTrue(
            TranscriptionQueue.requiresDerivedAsset(for: URL(fileURLWithPath: "/archive/clip.WEBM"))
        )
        XCTAssertFalse(
            TranscriptionQueue.requiresDerivedAsset(for: URL(fileURLWithPath: "/archive/clip.mp4"))
        )
    }

    func testVideoUnderstandingSelectionUsesNativeVideoFirstAndWebMAsDerivedFallback() throws {
        let cases: [([String], Int?)] = [
            (["/archive/clip.webm"], 0),
            (["/archive/clip.WEBM"], 0),
            (["/archive/clip.mp4"], 0),
            (["/archive/clip.webm", "/archive/clip.M4V"], 1),
            (["/archive/speech.m4a"], nil),
            (["/archive/still.png"], nil)
        ]

        for (paths, expectedIndex) in cases {
            let json = try encode(paths)
            let selected = VideoUnderstandingQueue.firstVideoPath(in: json)
            let sqlEligible = try matchesSQLPredicate(
                VideoUnderstandingQueue.videoMediaPredicateSQL,
                mediaFilesJSON: json
            )

            XCTAssertEqual(selected?.index, expectedIndex, "Unexpected selection for \(paths)")
            XCTAssertEqual(sqlEligible, expectedIndex != nil, "SQL/in-memory mismatch for \(paths)")
        }

        XCTAssertTrue(
            VideoUnderstandingQueue.requiresDerivedAsset(for: URL(fileURLWithPath: "/archive/clip.webm"))
        )
        XCTAssertFalse(
            VideoUnderstandingQueue.requiresDerivedAsset(for: URL(fileURLWithPath: "/archive/clip.mov"))
        )
    }

    private func encode(_ paths: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)
    }

    private func matchesSQLPredicate(_ predicate: String, mediaFilesJSON: String) throws -> Bool {
        let database = try DatabaseQueue()
        return try database.write { db in
            try db.execute(sql: "CREATE TABLE media_items (mediaFilesJSON TEXT NOT NULL)")
            try db.execute(
                sql: "INSERT INTO media_items (mediaFilesJSON) VALUES (?)",
                arguments: [mediaFilesJSON]
            )
            return try Int.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM media_items WHERE \(predicate))"
            ) == 1
        }
    }

    private struct QueueState {
        let transcriptionStatus: String
        let transcriptionVersion: Int
        let transcriptionRetryCount: Int
        let transcriptionSegmentCount: Int
        let videoStatus: String
        let videoVersion: Int
        let videoRetryCount: Int
        let videoSegmentCount: Int
    }

    private func state(for itemId: UUID, database: DatabaseManager) async throws -> QueueState {
        try await database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT transcription_status,
                           transcription_version,
                           transcription_retry_count,
                           video_understanding_status,
                           video_understanding_version,
                           video_understanding_retry_count
                    FROM media_items
                    WHERE id = ?
                """,
                arguments: [itemId.uuidString]
            )!
            return QueueState(
                transcriptionStatus: row["transcription_status"],
                transcriptionVersion: row["transcription_version"],
                transcriptionRetryCount: row["transcription_retry_count"],
                transcriptionSegmentCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM transcript_segments WHERE item_id = ?",
                    arguments: [itemId.uuidString]
                ) ?? 0,
                videoStatus: row["video_understanding_status"],
                videoVersion: row["video_understanding_version"],
                videoRetryCount: row["video_understanding_retry_count"],
                videoSegmentCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM video_segments WHERE item_id = ?",
                    arguments: [itemId.uuidString]
                ) ?? 0
            )
        }
    }

    private static func insertItem(
        id: UUID,
        mediaPath: String,
        metadataPath: String,
        in db: Database
    ) throws {
        let mediaFilesJSON = String(
            decoding: try JSONEncoder().encode([mediaPath]),
            as: UTF8.self
        )
        try db.execute(
            sql: """
                INSERT INTO media_items (
                    id, basePathString, metadataFileString, mediaFilesJSON,
                    sourceURL, platform, archivedDate, starred, tagsJSON,
                    transcription_status, transcription_version, transcription_retry_count,
                    transcription_last_error, transcription_failed_at,
                    video_understanding_status, video_understanding_version,
                    video_understanding_retry_count, video_understanding_last_error,
                    video_understanding_failed_at, parseStatus
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, '[]', 'complete', 7, 2,
                          'preserved transcription error', 'preserved transcription date',
                          'complete', 8, 2, 'preserved video error',
                          'preserved video date', 'success')
            """,
            arguments: [
                id.uuidString,
                "/archive",
                metadataPath,
                mediaFilesJSON,
                "https://example.invalid/item/\(id.uuidString)",
                "test",
                Date()
            ]
        )
    }

    private static func insertSegments(itemId: UUID, sourcePath: String, in db: Database) throws {
        try TranscriptSegmentRecord(
            segment: TranscriptSegment(
                id: UUID(),
                itemId: itemId,
                mediaFileIndex: 0,
                sourcePath: sourcePath,
                startTime: 0,
                endTime: 1,
                text: "preserved transcript",
                confidence: 0.9,
                language: "en",
                model: "preserved-model",
                version: 7
            )
        ).insert(db)
        try VideoSegmentRecord(
            segment: VideoSegment(
                id: UUID(),
                itemId: itemId,
                mediaFileIndex: 0,
                sourcePath: sourcePath,
                startTime: 0,
                endTime: 1,
                summary: "preserved analysis",
                labels: [],
                confidence: 0.9,
                analysisSource: "preserved-source",
                version: 8
            )
        ).insert(db)
    }
}
