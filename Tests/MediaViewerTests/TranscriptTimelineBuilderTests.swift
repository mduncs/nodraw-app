import GRDB
import XCTest
@testable import MediaViewer

final class TranscriptTimelineBuilderTests: XCTestCase {
    func testMergeTokensIntoWordsUsesWhitespaceBoundaries() {
        let tokens = [
            TranscriptToken(token: " Hel", startTime: 0.0, endTime: 0.1, confidence: 0.8),
            TranscriptToken(token: "lo", startTime: 0.1, endTime: 0.2, confidence: 0.9),
            TranscriptToken(token: " wor", startTime: 0.3, endTime: 0.4, confidence: 0.7),
            TranscriptToken(token: "ld", startTime: 0.4, endTime: 0.5, confidence: 0.9)
        ]

        let words = TranscriptTimelineBuilder.mergeTokensIntoWords(tokens)

        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].text, "Hello")
        XCTAssertEqual(words[0].startTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(words[0].endTime, 0.2, accuracy: 0.001)
        XCTAssertEqual(words[0].confidence, 0.85, accuracy: 0.001)
        XCTAssertEqual(words[1].text, "world")
    }

    func testBuildSegmentsGroupsTimedWordsIntoReadableChunks() {
        let itemId = UUID()
        let tokens = [
            TranscriptToken(token: " This", startTime: 0.0, endTime: 0.4, confidence: 0.9),
            TranscriptToken(token: " is", startTime: 0.5, endTime: 0.7, confidence: 0.9),
            TranscriptToken(token: " first", startTime: 0.8, endTime: 1.2, confidence: 0.9),
            TranscriptToken(token: ".", startTime: 1.2, endTime: 1.3, confidence: 0.9),
            TranscriptToken(token: " This", startTime: 9.0, endTime: 9.4, confidence: 0.8),
            TranscriptToken(token: " is", startTime: 9.5, endTime: 9.7, confidence: 0.8),
            TranscriptToken(token: " second", startTime: 9.8, endTime: 10.4, confidence: 0.8),
            TranscriptToken(token: ".", startTime: 10.4, endTime: 10.5, confidence: 0.8)
        ]

        let segments = TranscriptTimelineBuilder.buildSegments(
            itemId: itemId,
            mediaFileIndex: 0,
            sourcePath: "/tmp/example.m4a",
            transcriptText: "This is first. This is second.",
            transcriptConfidence: 0.85,
            tokens: tokens,
            duration: 11,
            language: "en"
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "This is first.")
        XCTAssertEqual(segments[0].startTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endTime, 1.3, accuracy: 0.001)
        XCTAssertEqual(segments[1].text, "This is second.")
        XCTAssertEqual(segments[1].startTime, 9.0, accuracy: 0.001)
    }

    func testBuildSegmentsFallsBackToWholeTranscriptWithoutTimings() {
        let itemId = UUID()

        let segments = TranscriptTimelineBuilder.buildSegments(
            itemId: itemId,
            mediaFileIndex: 2,
            sourcePath: "/tmp/example.mp3",
            transcriptText: "No token timings here.",
            transcriptConfidence: 0.72,
            tokens: [],
            duration: 4.5,
            language: nil
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].mediaFileIndex, 2)
        XCTAssertEqual(segments[0].text, "No token timings here.")
        XCTAssertEqual(segments[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endTime, 4.5, accuracy: 0.001)
        XCTAssertEqual(segments[0].confidence, 0.72, accuracy: 0.001)
    }

    func testSearchCaptionPreservesVisualCaptionAndReplacesOldSpeech() {
        let itemId = UUID()
        let segment = TranscriptSegment(
            id: UUID(),
            itemId: itemId,
            mediaFileIndex: 0,
            sourcePath: "/tmp/example.mp4",
            startTime: 0,
            endTime: 2,
            text: "A concise spoken line.",
            confidence: 0.9,
            language: "en",
            model: TranscriptTimelineBuilder.defaultModelName,
            version: TranscriptTimelineBuilder.currentVersion
        )

        let caption = TranscriptTimelineBuilder.makeSearchCaption(
            segments: [segment],
            existingCaption: "Video: face, indoor. Speech: old words"
        )

        XCTAssertEqual(caption, "Video: face, indoor. Speech: A concise spoken line.")
    }

    func testTranscriptSegmentRecordRoundTrips() async throws {
        let fixture = try await ProductionAssetFixture()
        defer { fixture.cleanUp() }
        let dbQueue = fixture.database
        let itemId = UUID()
        let segment = TranscriptSegment(
            id: UUID(),
            itemId: itemId,
            mediaFileIndex: 1,
            sourcePath: fixture.files[1].path,
            startTime: 1.2,
            endTime: 3.4,
            text: "hello there",
            confidence: 0.87,
            language: "en",
            model: TranscriptTimelineBuilder.defaultModelName,
            version: TranscriptTimelineBuilder.currentVersion
        )

        try await dbQueue.write { db in
            try fixture.insertItem(itemId, in: db)
            try TranscriptSegmentRecord(segment: segment).insert(db)
        }

        let fetched = try await dbQueue.read { db in
            try TranscriptSegmentRecord.fetchAll(db: db, itemId: itemId)
        }

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].mediaFileIndex, 1)
        XCTAssertEqual(fetched[0].text, "hello there")
        XCTAssertEqual(fetched[0].language, "en")
        XCTAssertEqual(fetched[0].model, TranscriptTimelineBuilder.defaultModelName)
    }
}
