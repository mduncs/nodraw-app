import XCTest
import GRDB
import PhotoPipeline
@testable import MediaViewer

final class VideoTimelineBuilderTests: XCTestCase {
    func testBuildSegmentsGroupsAdjacentFramesWithSharedLabels() {
        let itemId = UUID()
        let analysis = VideoAnalysis(
            duration: 20,
            frameCount: 4,
            labels: [
                SceneLabel(label: "cat", confidence: 0.9),
                SceneLabel(label: "car", confidence: 0.8)
            ],
            highlights: [],
            suggestedThumbnailTime: 0,
            frameAnalyses: [
                FrameAnalysis(time: 0, labels: [SceneLabel(label: "cat", confidence: 0.9)], qualityScore: 0.8),
                FrameAnalysis(time: 5, labels: [SceneLabel(label: "cat", confidence: 0.7)], qualityScore: 0.7),
                FrameAnalysis(time: 11, labels: [SceneLabel(label: "car", confidence: 0.8)], qualityScore: 0.6),
                FrameAnalysis(time: 16, labels: [SceneLabel(label: "car", confidence: 0.6)], qualityScore: 0.5)
            ]
        )

        let segments = VideoTimelineBuilder.buildSegments(
            itemId: itemId,
            mediaFileIndex: 0,
            sourcePath: "/tmp/example.mp4",
            analysis: analysis
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].summary, "cat")
        XCTAssertEqual(segments[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endTime, 11, accuracy: 0.001)
        XCTAssertEqual(segments[1].summary, "car")
        XCTAssertEqual(segments[1].startTime, 11, accuracy: 0.001)
        XCTAssertEqual(segments[1].endTime, 20, accuracy: 0.001)
    }

    func testSearchCaptionIsShortAndIncludesTimeline() {
        let itemId = UUID()
        let segments = (0..<20).map { index in
            VideoSegment(
                id: UUID(),
                itemId: itemId,
                mediaFileIndex: 0,
                sourcePath: "/tmp/example.mp4",
                startTime: Double(index * 5),
                endTime: Double(index * 5 + 5),
                summary: "cat, window, indoor",
                labels: [
                    VideoSegmentLabel(label: "cat", confidence: 0.9),
                    VideoSegmentLabel(label: "window", confidence: 0.6)
                ],
                confidence: 0.8,
                analysisSource: VideoTimelineBuilder.analysisSource,
                version: VideoTimelineBuilder.currentVersion
            )
        }

        let caption = VideoTimelineBuilder.makeSearchCaption(segments: segments, duration: 100)

        XCTAssertNotNil(caption)
        XCTAssertLessThanOrEqual(caption?.count ?? 0, 600)
        XCTAssertTrue(caption?.contains("Video: cat, window") == true)
        XCTAssertTrue(caption?.contains("Timeline: 0:00 cat") == true)
    }

    func testVideoSegmentRecordRoundTripsLabels() async throws {
        let fixture = try await ProductionAssetFixture()
        defer { fixture.cleanUp() }
        let dbQueue = fixture.database
        let itemId = UUID()
        let segment = VideoSegment(
            id: UUID(),
            itemId: itemId,
            mediaFileIndex: 1,
            sourcePath: fixture.files[1].path,
            startTime: 1.25,
            endTime: 4.5,
            summary: "cat",
            labels: [VideoSegmentLabel(label: "cat", confidence: 0.92)],
            confidence: 0.88,
            analysisSource: VideoTimelineBuilder.analysisSource,
            version: VideoTimelineBuilder.currentVersion
        )

        try await dbQueue.write { db in
            try fixture.insertItem(itemId, in: db)
            try VideoSegmentRecord(segment: segment).insert(db)
        }

        let fetched = try await dbQueue.read { db in
            try VideoSegmentRecord.fetchAll(db: db, itemId: itemId)
        }

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].mediaFileIndex, 1)
        XCTAssertEqual(fetched[0].summary, "cat")
        XCTAssertEqual(fetched[0].labels, [VideoSegmentLabel(label: "cat", confidence: 0.92)])
    }
}
