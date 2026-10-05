import XCTest
@testable import MediaViewer

final class VideoPlaybackUpdatePolicyTests: XCTestCase {
    func testRateOnlyChangeWhilePlayingCannotReloadSeekOrReplay() {
        let url = URL(fileURLWithPath: "/tmp/video.mp4")
        let handledSeek = VideoSeekRequest(sourceURL: url, time: 12)
        let previous = VideoPlaybackState(
            isPlaying: true,
            rate: 2,
            isMuted: false,
            volume: 0.35
        )
        var requested = previous
        requested.rate = 0.75

        let plan = VideoPlaybackUpdatePolicy.plan(
            currentURL: url,
            requestedURL: url,
            previousState: previous,
            requestedState: requested,
            lastHandledSeekID: handledSeek.id,
            seekRequest: handledSeek
        )

        XCTAssertFalse(plan.reloadSource)
        XCTAssertNil(plan.seekRequest)
        XCTAssertEqual(plan.stateDelta.rate, 0.75)
        XCTAssertNil(plan.stateDelta.playbackCommand)
        XCTAssertNil(plan.stateDelta.isMuted)
        XCTAssertNil(plan.stateDelta.volume)
    }

    func testEquivalentStandardizedFileURLDoesNotReloadSource() {
        let currentURL = URL(fileURLWithPath: "/tmp/archive/../video.mp4")
        let requestedURL = URL(fileURLWithPath: "/tmp/video.mp4")
        let state = VideoPlaybackState(
            isPlaying: true,
            rate: 1,
            isMuted: true,
            volume: 0.35
        )

        let plan = VideoPlaybackUpdatePolicy.plan(
            currentURL: currentURL,
            requestedURL: requestedURL,
            previousState: state,
            requestedState: state,
            lastHandledSeekID: nil,
            seekRequest: nil
        )

        XCTAssertFalse(plan.reloadSource)
        XCTAssertEqual(plan.stateDelta, .none)
    }

    func testSeekRequestFromPreviousSourceIsIgnored() {
        let previousURL = URL(fileURLWithPath: "/tmp/previous.mp4")
        let currentURL = URL(fileURLWithPath: "/tmp/current.mp4")
        let staleSeek = VideoSeekRequest(sourceURL: previousURL, time: 22)
        let state = VideoPlaybackState(
            isPlaying: true,
            rate: 1,
            isMuted: true,
            volume: 0.35
        )

        let plan = VideoPlaybackUpdatePolicy.plan(
            currentURL: currentURL,
            requestedURL: currentURL,
            previousState: state,
            requestedState: state,
            lastHandledSeekID: nil,
            seekRequest: staleSeek
        )

        XCTAssertFalse(plan.reloadSource)
        XCTAssertNil(plan.seekRequest)
    }

    func testSourceChangeSuppressesPlaybackAndSeekOperationsUntilReloadCompletes() {
        let previousURL = URL(fileURLWithPath: "/tmp/previous.mp4")
        let nextURL = URL(fileURLWithPath: "/tmp/next.mp4")
        let staleSeek = VideoSeekRequest(sourceURL: previousURL, time: 22)
        let previous = VideoPlaybackState(
            isPlaying: true,
            rate: 2,
            isMuted: true,
            volume: 0.35
        )
        var requested = previous
        requested.rate = 0.5

        let plan = VideoPlaybackUpdatePolicy.plan(
            currentURL: previousURL,
            requestedURL: nextURL,
            previousState: previous,
            requestedState: requested,
            lastHandledSeekID: nil,
            seekRequest: staleSeek
        )

        XCTAssertTrue(plan.reloadSource)
        XCTAssertEqual(plan.stateDelta, .none)
        XCTAssertNil(plan.seekRequest)
    }

    func testConfiguredLoopRetainsSelectedPlaybackRate() {
        XCTAssertEqual(
            VideoPlaybackEndPolicy.action(loopEnabled: true, requestedRate: 3),
            .loop(rate: 3)
        )
        XCTAssertEqual(
            VideoPlaybackEndPolicy.action(loopEnabled: false, requestedRate: 3),
            .stop
        )
    }
}

final class VideoTransportNavigationPolicyTests: XCTestCase {
    func testParentChangeResetsCarouselForForwardAndBackwardNavigation() {
        XCTAssertEqual(
            SingleFocusParentChangePolicy.initialMediaIndex(navigationDirection: .forward),
            0
        )
        XCTAssertEqual(
            SingleFocusParentChangePolicy.initialMediaIndex(navigationDirection: .backward),
            0
        )
    }

    func testOuterPreviousAlwaysMeansPreviousItem() {
        XCTAssertEqual(
            SingleFocusNavigationPolicy.action(
                for: .previousItemControl,
                selectedMediaIndex: 2,
                mediaCount: 4
            ),
            .previousItem
        )
    }

    func testOuterNextAlwaysMeansNextItem() {
        XCTAssertEqual(
            SingleFocusNavigationPolicy.action(
                for: .nextItemControl,
                selectedMediaIndex: 0,
                mediaCount: 4
            ),
            .nextItem
        )
    }

    func testArrowNavigationStillTraversesMediaBeforeItems() {
        XCTAssertEqual(
            SingleFocusNavigationPolicy.action(
                for: .previousMediaOrItem,
                selectedMediaIndex: 2,
                mediaCount: 4
            ),
            .selectMedia(index: 1)
        )
        XCTAssertEqual(
            SingleFocusNavigationPolicy.action(
                for: .nextMediaOrItem,
                selectedMediaIndex: 3,
                mediaCount: 4
            ),
            .nextItem
        )
    }

    @MainActor
    func testOuterNextUsesActiveFocusSequenceAcrossFolderBoundary() {
        let first = makeItem(folder: "2026-07")
        let second = makeItem(folder: "2026-08")
        let appState = AppState()
        appState.setDisplayContext(surface: .grid, items: [first, second])
        appState.openSingleFocus(first)

        XCTAssertNil(appState.nextItemInFolder(currentId: first.id))

        let action = SingleFocusNavigationPolicy.action(
            for: .nextItemControl,
            selectedMediaIndex: 0,
            mediaCount: first.mediaFiles.count
        )
        SingleFocusNavigationPolicy.perform(
            action,
            selectMedia: { _ in XCTFail("Outer transport must not select sub-media") },
            previousItem: { XCTFail("Next control must not invoke previous item") },
            nextItem: { appState.navigateToNextItem() }
        )

        XCTAssertEqual(appState.focusedItem?.id, second.id)
    }

    private func makeItem(folder: String) -> MediaItem {
        let id = UUID()
        let basePath = URL(fileURLWithPath: "/tmp/nodraw-playback-tests/\(folder)")
        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("\(id.uuidString).md"),
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString).mp4")],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/\(id.uuidString)")!,
                platform: "web",
                archivedDate: Date()
            )
        )
    }
}
