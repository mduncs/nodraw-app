import XCTest
@testable import MediaViewer

final class VideoHoverPreviewPolicyTests: XCTestCase {
    @MainActor
    func testAutoplayCoordinatorKeepsOnlyLatestHoverDelay() async {
        let coordinator = VideoHoverAutoplayCoordinator()
        var fired: [Int] = []

        coordinator.schedule(after: .milliseconds(80)) {
            fired.append(1)
        }
        coordinator.schedule(after: .milliseconds(10)) {
            fired.append(2)
        }

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(fired, [2])
        XCTAssertFalse(coordinator.hasScheduledTask)
    }

    @MainActor
    func testAutoplayCoordinatorCancellationEndsCellLifecycleWork() async {
        let coordinator = VideoHoverAutoplayCoordinator()
        var didFire = false

        coordinator.schedule(after: .milliseconds(20)) {
            didFire = true
        }
        XCTAssertTrue(coordinator.hasScheduledTask)
        coordinator.cancel()

        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(didFire)
        XCTAssertFalse(coordinator.hasScheduledTask)
    }

    func testWebMRoutesToWebKitCaseInsensitively() {
        XCTAssertEqual(
            VideoHoverPreviewPolicy.backend(for: URL(fileURLWithPath: "/archive/clip.webm")),
            .webKit
        )
        XCTAssertEqual(
            VideoHoverPreviewPolicy.backend(for: URL(fileURLWithPath: "/archive/CLIP.WEBM")),
            .webKit
        )
    }

    func testNativeAndExistingFallbackFormatsKeepAVPlayerRoute() {
        for fileName in ["clip.mp4", "clip.mov", "clip.mkv"] {
            XCTAssertEqual(
                VideoHoverPreviewPolicy.backend(for: URL(fileURLWithPath: "/archive/\(fileName)")),
                .avPlayer
            )
        }
    }

    func testPausedPreviewPlansFractionalSeek() throws {
        let plan = try XCTUnwrap(
            VideoHoverPreviewPolicy.seekPlan(
                scrubFraction: 0.25,
                duration: 120,
                isPlaying: false,
                lastSeekedFraction: nil
            )
        )

        XCTAssertEqual(plan.fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(plan.time, 30, accuracy: 0.0001)
    }

    func testScrubFractionIsClampedToMediaBounds() throws {
        let beforeStart = try XCTUnwrap(
            VideoHoverPreviewPolicy.seekPlan(
                scrubFraction: -0.5,
                duration: 20,
                isPlaying: false,
                lastSeekedFraction: nil
            )
        )
        let afterEnd = try XCTUnwrap(
            VideoHoverPreviewPolicy.seekPlan(
                scrubFraction: 1.5,
                duration: 20,
                isPlaying: false,
                lastSeekedFraction: nil
            )
        )

        XCTAssertEqual(beforeStart, VideoHoverSeekPlan(fraction: 0, time: 0))
        XCTAssertEqual(afterEnd, VideoHoverSeekPlan(fraction: 1, time: 20))
    }

    func testPlayingPreviewDoesNotSeek() {
        XCTAssertNil(
            VideoHoverPreviewPolicy.seekPlan(
                scrubFraction: 0.5,
                duration: 20,
                isPlaying: true,
                lastSeekedFraction: nil
            )
        )
    }

    func testEquivalentScrubFractionDoesNotRepeatSeek() {
        XCTAssertNil(
            VideoHoverPreviewPolicy.seekPlan(
                scrubFraction: 0.503,
                duration: 20,
                isPlaying: false,
                lastSeekedFraction: 0.5
            )
        )
    }

    func testPreviewWaitsForFinitePositiveDuration() {
        let unavailableDurations: [Double] = [0, -.infinity, .infinity, .nan]
        for duration in unavailableDurations {
            XCTAssertNil(
                VideoHoverPreviewPolicy.seekPlan(
                    scrubFraction: 0.5,
                    duration: duration,
                    isPlaying: false,
                    lastSeekedFraction: nil
                )
            )
        }
    }
}
