import SwiftUI
import WebKit
import XCTest
@testable import MediaViewer

@MainActor
final class WebMPlaybackStateSynchronizationTests: XCTestCase {
    func testStateMutationDuringConfigurationIsReappliedAfterAcknowledgement() {
        var currentTime = 0.0
        var duration = 0.0
        let evaluator = DeferredJavaScriptEvaluator()
        let coordinator = WebMVideoPlayerView.Coordinator(
            currentTime: Binding(
                get: { currentTime },
                set: { currentTime = $0 }
            ),
            duration: Binding(
                get: { duration },
                set: { duration = $0 }
            ),
            javaScriptEvaluator: evaluator.evaluate
        )
        let webView = WKWebView(frame: .zero)
        let url = URL(fileURLWithPath: "/tmp/racing-state.webm")
        let initialState = VideoPlaybackState(
            isPlaying: true,
            rate: 1,
            isMuted: false,
            volume: 0.35
        )
        let updatedState = VideoPlaybackState(
            isPlaying: false,
            rate: 2,
            isMuted: true,
            volume: 0.6
        )

        coordinator.beginLoading(
            WebMLocalFileLoadPolicy.plan(for: url),
            configuration: WebMVideoDOMConfiguration(
                playbackState: initialState,
                showsNativeControls: false,
                loopEnabled: false,
                scaleMode: .fit
            )
        )
        coordinator.configureCurrentDocument(in: webView)

        XCTAssertEqual(evaluator.scripts.count, 1)
        XCTAssertNil(coordinator.lastAppliedState)

        coordinator.updateDesiredPlaybackState(updatedState)
        coordinator.applyDesiredPlaybackStateIfNeeded(in: webView)

        // Configuration is still outstanding, so the update remains desired rather than being
        // incorrectly treated as applied or sent concurrently.
        XCTAssertEqual(evaluator.scripts.count, 1)
        XCTAssertNil(coordinator.lastAppliedState)

        evaluator.completeNext(with: true)

        // The configuration acknowledgement applies only its captured snapshot, then queues the
        // newer desired state as a second, serialized DOM write.
        XCTAssertEqual(coordinator.lastAppliedState, initialState)
        XCTAssertEqual(evaluator.scripts.count, 2)
        XCTAssertTrue(evaluator.scripts[1].contains("video.playbackRate = 2.0;"))
        XCTAssertTrue(evaluator.scripts[1].contains("video.muted = true;"))
        XCTAssertTrue(evaluator.scripts[1].contains("video.volume = 0.6"))
        XCTAssertTrue(evaluator.scripts[1].contains("video.pause();"))

        evaluator.completeNext(with: true)

        XCTAssertEqual(coordinator.lastAppliedState, updatedState)
        XCTAssertEqual(evaluator.scripts.count, 2)
        coordinator.invalidateDocument()
    }
}

@MainActor
private final class DeferredJavaScriptEvaluator {
    typealias Completion = (Any?, Error?) -> Void

    private(set) var scripts: [String] = []
    private var completions: [Completion] = []

    func evaluate(
        _ webView: WKWebView,
        _ script: String,
        _ completion: @escaping Completion
    ) {
        scripts.append(script)
        completions.append(completion)
    }

    func completeNext(with result: Any?, error: Error? = nil) {
        XCTAssertFalse(completions.isEmpty, "Expected a pending JavaScript evaluation")
        guard !completions.isEmpty else { return }
        completions.removeFirst()(result, error)
    }
}
