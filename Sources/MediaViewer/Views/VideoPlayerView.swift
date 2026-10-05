import SwiftUI
import AVKit
import AppKit
import WebKit

enum VideoPlaybackDefaults {
    static let volumeKey = "videoPlaybackVolume"
    static let defaultVolume: Float = 0.35

    static func initialVolume() -> Float {
        if let stored = UserDefaults.standard.object(forKey: volumeKey) as? Float {
            return clampVolume(stored)
        }
        if let stored = UserDefaults.standard.object(forKey: volumeKey) as? Double {
            return clampVolume(Float(stored))
        }
        return defaultVolume
    }

    static func persistVolume(_ value: Float) {
        UserDefaults.standard.set(Double(clampVolume(value)), forKey: volumeKey)
    }

    static func clampVolume(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}

struct VideoPlaybackState: Equatable {
    var isPlaying: Bool
    var rate: Float
    var isMuted: Bool
    var volume: Float
}

enum VideoPlaybackCommand: Equatable {
    case play(rate: Float)
    case pause
}

struct VideoPlaybackStateDelta: Equatable {
    var rate: Float?
    var isMuted: Bool?
    var volume: Float?
    var playbackCommand: VideoPlaybackCommand?

    static let none = VideoPlaybackStateDelta(
        rate: nil,
        isMuted: nil,
        volume: nil,
        playbackCommand: nil
    )

    static func between(
        previous: VideoPlaybackState?,
        requested: VideoPlaybackState
    ) -> VideoPlaybackStateDelta {
        VideoPlaybackStateDelta(
            rate: previous?.rate == requested.rate ? nil : requested.rate,
            isMuted: previous?.isMuted == requested.isMuted ? nil : requested.isMuted,
            volume: previous?.volume == requested.volume ? nil : requested.volume,
            playbackCommand: previous?.isPlaying == requested.isPlaying
                ? nil
                : (requested.isPlaying ? .play(rate: requested.rate) : .pause)
        )
    }
}

struct VideoSeekRequest: Equatable, Identifiable {
    let id = UUID()
    let sourceURL: URL
    let time: Double
}

struct VideoPlaybackUpdatePlan: Equatable {
    var reloadSource: Bool
    var stateDelta: VideoPlaybackStateDelta
    var seekRequest: VideoSeekRequest?
}

/// Converts SwiftUI state changes into discrete player operations. In particular, a rate-only
/// update produces only a rate assignment: it cannot reload media, replay, or reuse a seek that
/// belongs to a different source.
enum VideoPlaybackUpdatePolicy {
    static func plan(
        currentURL: URL?,
        requestedURL: URL,
        previousState: VideoPlaybackState?,
        requestedState: VideoPlaybackState,
        lastHandledSeekID: UUID?,
        seekRequest: VideoSeekRequest?
    ) -> VideoPlaybackUpdatePlan {
        guard sourcesMatch(currentURL, requestedURL) else {
            return VideoPlaybackUpdatePlan(
                reloadSource: true,
                stateDelta: .none,
                seekRequest: nil
            )
        }

        let applicableSeek = seekRequest.flatMap { request -> VideoSeekRequest? in
            guard request.id != lastHandledSeekID,
                  sourcesMatch(request.sourceURL, requestedURL) else { return nil }
            return request
        }

        return VideoPlaybackUpdatePlan(
            reloadSource: false,
            stateDelta: .between(previous: previousState, requested: requestedState),
            seekRequest: applicableSeek
        )
    }

    static func sourcesMatch(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return sourceIdentity(lhs) == sourceIdentity(rhs)
    }

    private static func sourceIdentity(_ url: URL) -> String {
        if url.isFileURL {
            return url.standardizedFileURL.absoluteString
        }
        return url.absoluteString
    }
}

enum VideoPlaybackEndAction: Equatable {
    case loop(rate: Float)
    case stop
}

enum VideoPlaybackEndPolicy {
    static func action(loopEnabled: Bool, requestedRate: Float) -> VideoPlaybackEndAction {
        loopEnabled ? .loop(rate: requestedRate) : .stop
    }
}

// MARK: - VideoPlayerView

struct UniversalVideoPlayerView: View {
    let url: URL
    @Binding var isPlaying: Bool
    @Binding var playbackRate: Float
    @Binding var isMuted: Bool
    @Binding var volume: Float
    @Binding var currentTime: Double
    @Binding var duration: Double
    @Binding var seekRequest: VideoSeekRequest?
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?

    var body: some View {
        if url.pathExtension.lowercased() == "webm" {
            WebMVideoPlayerView(
                url: url,
                isPlaying: $isPlaying,
                playbackRate: $playbackRate,
                isMuted: $isMuted,
                volume: $volume,
                currentTime: $currentTime,
                duration: $duration,
                seekRequest: $seekRequest,
                onLeft: onLeft,
                onRight: onRight
            )
        } else {
            VideoPlayerView(
                url: url,
                isPlaying: $isPlaying,
                playbackRate: $playbackRate,
                isMuted: $isMuted,
                volume: $volume,
                currentTime: $currentTime,
                duration: $duration,
                seekRequest: $seekRequest,
                onLeft: onLeft,
                onRight: onRight
            )
        }
    }
}

/// Click-to-play video player using AVPlayerView (AppKit) to avoid SwiftUI VideoPlayer crashes.
/// Arrow keys are forwarded to parent for navigation instead of frame stepping.
/// Respects user settings for autoplay and mute-by-default.
struct VideoPlayerView: NSViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool
    @Binding var playbackRate: Float
    @Binding var isMuted: Bool
    @Binding var volume: Float
    @Binding var currentTime: Double
    @Binding var duration: Double
    @Binding var seekRequest: VideoSeekRequest?
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?

    /// Read video settings from UserDefaults
    private var autoplay: Bool {
        // Default is true if key doesn't exist
        UserDefaults.standard.object(forKey: "videoAutoplay") as? Bool ?? true
    }

    private var loopEnabled: Bool {
        UserDefaults.standard.object(forKey: "videoLoopEnabled") as? Bool ?? false
    }

    private var clampedVolume: Float {
        VideoPlaybackDefaults.clampVolume(volume)
    }

    private var requestedPlaybackState: VideoPlaybackState {
        VideoPlaybackState(
            isPlaying: isPlaying,
            rate: playbackRate,
            isMuted: isMuted,
            volume: clampedVolume
        )
    }

    func makeNSView(context: Context) -> NavigableAVPlayerView {
        let playerView = NavigableAVPlayerView()
        playerView.controlsStyle = .none
        playerView.showsFullScreenToggleButton = false
        playerView.onLeft = onLeft
        playerView.onRight = onRight

        // Verify file exists
        if FileManager.default.fileExists(atPath: url.path) {
            let player = AVPlayer(url: url)
            player.currentItem?.audioTimePitchAlgorithm = .spectral   // pitch-corrected, supports full 0.25x-4.0x range
            player.defaultRate = playbackRate

            // Apply mute setting
            player.isMuted = isMuted
            player.volume = clampedVolume

            playerView.player = player
            context.coordinator.currentURL = url
            context.coordinator.desiredPlaybackRate = playbackRate
            context.coordinator.player = player

            // Apply autoplay setting
            if autoplay {
                player.playImmediately(atRate: playbackRate)
                DispatchQueue.main.async {
                    self.isPlaying = true
                }
            } else {
                DispatchQueue.main.async {
                    self.isPlaying = false
                }
            }
            context.coordinator.lastAppliedState = VideoPlaybackState(
                isPlaying: autoplay,
                rate: playbackRate,
                isMuted: isMuted,
                volume: clampedVolume
            )
        } else {
            // File missing - handled upstream in SingleFocusView
        }

        return playerView
    }

    func updateNSView(_ playerView: NavigableAVPlayerView, context: Context) {
        // Update callbacks
        playerView.onLeft = onLeft
        playerView.onRight = onRight

        let requestedState = requestedPlaybackState
        let updatePlan = VideoPlaybackUpdatePolicy.plan(
            currentURL: context.coordinator.currentURL,
            requestedURL: url,
            previousState: context.coordinator.lastAppliedState,
            requestedState: requestedState,
            lastHandledSeekID: context.coordinator.lastHandledSeekID,
            seekRequest: seekRequest
        )

        if updatePlan.reloadSource {
            context.coordinator.currentURL = url
            context.coordinator.desiredPlaybackRate = playbackRate
            context.coordinator.lastAppliedState = nil

            // Clean up old player to prevent audio bleed during rapid navigation
            if let oldPlayer = context.coordinator.player {
                oldPlayer.pause()
                oldPlayer.replaceCurrentItem(with: nil)
            }
            playerView.player = nil
            context.coordinator.player = nil

            if FileManager.default.fileExists(atPath: url.path) {
                let player = AVPlayer(url: url)
                player.currentItem?.audioTimePitchAlgorithm = .spectral   // pitch-corrected, supports full 0.25x-4.0x range
                player.defaultRate = playbackRate

                // Apply mute setting for new videos
                player.isMuted = isMuted
                player.volume = clampedVolume

                playerView.player = player
                context.coordinator.player = player

                // Apply autoplay setting for new videos
                if autoplay {
                    player.playImmediately(atRate: playbackRate)
                }
                context.coordinator.lastAppliedState = VideoPlaybackState(
                    isPlaying: autoplay,
                    rate: playbackRate,
                    isMuted: isMuted,
                    volume: clampedVolume
                )
            } else {
                playerView.player = nil
                context.coordinator.player = nil
                context.coordinator.lastAppliedState = VideoPlaybackState(
                    isPlaying: false,
                    rate: playbackRate,
                    isMuted: isMuted,
                    volume: clampedVolume
                )
            }

            let startsPlaying = autoplay && context.coordinator.player != nil
            DispatchQueue.main.async {
                self.isPlaying = startsPlaying
            }

            // URL just changed -- autoplay block above already handled play state.
            // Don't fall through to the play/pause block below with stale isPlaying.
            return
        }

        guard let player = context.coordinator.player else { return }

        if let rate = updatePlan.stateDelta.rate {
            context.coordinator.desiredPlaybackRate = rate
            player.defaultRate = rate
            if player.rate != 0, player.rate != rate {
                player.rate = rate
            }
        }
        if let muted = updatePlan.stateDelta.isMuted {
            player.isMuted = muted
        }
        if let volume = updatePlan.stateDelta.volume {
            player.volume = volume
        }

        context.coordinator.handleSeekRequest(updatePlan.seekRequest)

        switch updatePlan.stateDelta.playbackCommand {
        case .play(let rate):
            context.coordinator.desiredPlaybackRate = rate
            player.defaultRate = rate
            player.playImmediately(atRate: rate)
        case .pause:
            player.pause()
        case nil:
            break
        }

        context.coordinator.lastAppliedState = requestedState
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPlaying: $isPlaying, currentTime: $currentTime, duration: $duration)
    }

    /// Belt-and-braces teardown: stop playback promptly on ANY removal path, rather than
    /// waiting on Coordinator.deinit (which can lag behind a SwiftUI transition/fade).
    static func dismantleNSView(_ nsView: NavigableAVPlayerView, coordinator: Coordinator) {
        let player = coordinator.player
        player?.pause()
        coordinator.player = nil
        player?.replaceCurrentItem(with: nil)
        nsView.player = nil
    }

    class Coordinator {
        @Binding private var isPlaying: Bool
        @Binding private var currentTime: Double
        @Binding private var duration: Double

        init(
            isPlaying: Binding<Bool>,
            currentTime: Binding<Double>,
            duration: Binding<Double>
        ) {
            _isPlaying = isPlaying
            _currentTime = currentTime
            _duration = duration
        }

        var lastAppliedState: VideoPlaybackState?
        var desiredPlaybackRate: Float = 1
        var currentURL: URL?
        var lastHandledSeekID: UUID?

        var player: AVPlayer? {
            didSet {
                playerGeneration &+= 1

                // Remove old observers
                if let token = timeObserver {
                    oldValue?.removeTimeObserver(token)
                    timeObserver = nil
                }
                if let token = loopObserver {
                    NotificationCenter.default.removeObserver(token)
                    loopObserver = nil
                }
                currentTime = 0
                duration = 0

                // Add loop observer for new player
                if let player = player {
                    let generation = playerGeneration
                    timeObserver = player.addPeriodicTimeObserver(
                        forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                        queue: .main
                    ) { [weak self, weak player] time in
                        guard let self, let player,
                              self.isCurrent(player, generation: generation) else { return }
                        let seconds = CMTimeGetSeconds(time)
                        if seconds.isFinite && seconds >= 0 {
                            self.currentTime = seconds
                        }
                        self.updateDuration(from: player)
                    }

                    loopObserver = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemDidPlayToEndTime,
                        object: player.currentItem,
                        queue: .main
                    ) { [weak self, weak player] _ in
                        guard let self, let player,
                              self.isCurrent(player, generation: generation) else { return }
                        let shouldLoop = UserDefaults.standard.object(forKey: "videoLoopEnabled") as? Bool ?? false
                        switch VideoPlaybackEndPolicy.action(
                            loopEnabled: shouldLoop,
                            requestedRate: self.desiredPlaybackRate
                        ) {
                        case .loop(let rate):
                            player.seek(to: .zero) { [weak self, weak player] finished in
                                guard finished, let self, let player,
                                      self.isCurrent(player, generation: generation) else { return }
                                self.currentTime = 0
                                self.isPlaying = true
                                player.defaultRate = rate
                                player.playImmediately(atRate: rate)
                            }
                        case .stop:
                            player.pause()
                            self.isPlaying = false
                            self.updateLastAppliedPlaying(false)
                        }
                    }
                }
            }
        }

        private var loopObserver: Any?
        private var timeObserver: Any?
        private var playerGeneration: UInt = 0

        func handleSeekRequest(_ request: VideoSeekRequest?) {
            guard let request,
                  request.id != lastHandledSeekID,
                  let currentURL,
                  VideoPlaybackUpdatePolicy.sourcesMatch(request.sourceURL, currentURL),
                  let player else { return }
            lastHandledSeekID = request.id
            let targetSeconds = max(0, request.time)
            let target = CMTime(seconds: targetSeconds, preferredTimescale: 600)
            let generation = playerGeneration
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
                guard finished, let self, let player,
                      self.isCurrent(player, generation: generation) else { return }
                self.currentTime = targetSeconds
            }
        }

        private func isCurrent(_ candidate: AVPlayer, generation: UInt) -> Bool {
            player === candidate && playerGeneration == generation
        }

        private func updateLastAppliedPlaying(_ playing: Bool) {
            guard var state = lastAppliedState else { return }
            state.isPlaying = playing
            lastAppliedState = state
        }

        private func updateDuration(from player: AVPlayer) {
            guard let item = player.currentItem else { return }
            let seconds = CMTimeGetSeconds(item.duration)
            if seconds.isFinite && seconds > 0 {
                duration = seconds
            }
        }

        deinit {
            if let token = timeObserver {
                player?.removeTimeObserver(token)
            }
            if let token = loopObserver {
                NotificationCenter.default.removeObserver(token)
            }
            player?.pause()
            player?.replaceCurrentItem(with: nil)
        }
    }
}

// MARK: - WebMVideoPlayerView

enum WebMVideoScaleMode: String {
    case fit = "contain"
    case fill = "cover"
}

struct WebMLocalFileLoadPlan: Equatable {
    let fileURL: URL
    let readAccessURL: URL
}

enum WebMVideoNavigationOutcome: Equatable {
    case finished
    case failed(domain: String, code: Int)
}

/// WebKit renders a directly loaded local WebM through its media-document path. On macOS that
/// path can report WebKit error 204 (the load was handed to the media plug-in) even though the
/// resulting document contains a ready `<video>` element, so that one failure is a completion
/// signal rather than a reason to abandon configuration.
enum WebMLocalFileLoadPolicy {
    static let mediaDocumentHandledErrorDomain = "WebKitErrorDomain"
    static let mediaDocumentHandledErrorCode = 204
    static let maximumConfigurationAttempts = 20
    static let configurationRetryDelay: TimeInterval = 0.1

    static func plan(for url: URL) -> WebMLocalFileLoadPlan {
        let fileURL = url.standardizedFileURL
        return WebMLocalFileLoadPlan(
            fileURL: fileURL,
            readAccessURL: fileURL.deletingLastPathComponent()
        )
    }

    static func shouldConfigure(after outcome: WebMVideoNavigationOutcome) -> Bool {
        switch outcome {
        case .finished:
            return true
        case .failed(let domain, let code):
            return domain == mediaDocumentHandledErrorDomain
                && code == mediaDocumentHandledErrorCode
        }
    }

    static func shouldRetryConfiguration(afterAttempt attempt: Int) -> Bool {
        attempt < maximumConfigurationAttempts
    }
}

struct WebMVideoDOMConfiguration: Equatable {
    var playbackState: VideoPlaybackState
    var showsNativeControls: Bool
    var loopEnabled: Bool
    var scaleMode: WebMVideoScaleMode
}

/// WebKit-backed WebM player for codecs AVFoundation cannot reliably render.
struct WebMVideoPlayerView: NSViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool
    @Binding var playbackRate: Float
    @Binding var isMuted: Bool
    @Binding var volume: Float
    @Binding var currentTime: Double
    @Binding var duration: Double
    @Binding var seekRequest: VideoSeekRequest?
    var showsNativeControls: Bool = false
    var autoplayOverride: Bool? = nil
    var loopOverride: Bool? = nil
    var scaleMode: WebMVideoScaleMode = .fit
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?

    private var autoplay: Bool {
        autoplayOverride
            ?? (UserDefaults.standard.object(forKey: "videoAutoplay") as? Bool ?? true)
    }

    private var loopEnabled: Bool {
        loopOverride
            ?? (UserDefaults.standard.object(forKey: "videoLoopEnabled") as? Bool ?? false)
    }

    private var clampedVolume: Float {
        VideoPlaybackDefaults.clampVolume(volume)
    }

    private var requestedPlaybackState: VideoPlaybackState {
        VideoPlaybackState(
            isPlaying: isPlaying,
            rate: playbackRate,
            isMuted: isMuted,
            volume: clampedVolume
        )
    }

    func makeNSView(context: Context) -> NavigableWKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = NavigableWKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.onLeft = onLeft
        webView.onRight = onRight
        webView.setValue(false, forKey: "drawsBackground")
        load(url, in: webView, context: context)
        return webView
    }

    func updateNSView(_ webView: NavigableWKWebView, context: Context) {
        webView.onLeft = onLeft
        webView.onRight = onRight

        let requestedState = requestedPlaybackState
        let updatePlan = VideoPlaybackUpdatePolicy.plan(
            currentURL: context.coordinator.currentURL,
            requestedURL: url,
            previousState: context.coordinator.lastAppliedState,
            requestedState: requestedState,
            lastHandledSeekID: context.coordinator.lastHandledSeekID,
            seekRequest: seekRequest
        )

        if updatePlan.reloadSource {
            load(url, in: webView, context: context)
            return
        }

        applyPlaybackState(
            updatePlan.stateDelta,
            requestedState: requestedState,
            in: webView,
            coordinator: context.coordinator
        )
        context.coordinator.handleSeekRequest(updatePlan.seekRequest, in: webView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentTime: $currentTime, duration: $duration)
    }

    /// Belt-and-braces teardown: the Coordinator's deinit only invalidated the poll timer and
    /// relied on WKWebView dealloc to silence the <video> element, which is indirect and can lag
    /// behind a SwiftUI transition/fade. Stop + unload explicitly on any removal path.
    static func dismantleNSView(_ webView: NavigableWKWebView, coordinator: Coordinator) {
        coordinator.invalidateDocument()
        webView.navigationDelegate = nil
        webView.evaluateJavaScript("document.querySelector('video')?.pause();")
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)   // kills media + JS context deterministically
    }

    private func load(_ url: URL, in webView: WKWebView, context: Context) {
        let plan = WebMLocalFileLoadPolicy.plan(for: url)
        let initialState = VideoPlaybackState(
            isPlaying: autoplay,
            rate: playbackRate,
            isMuted: isMuted,
            volume: clampedVolume
        )
        context.coordinator.beginLoading(
            plan,
            configuration: WebMVideoDOMConfiguration(
                playbackState: initialState,
                showsNativeControls: showsNativeControls,
                loopEnabled: loopEnabled,
                scaleMode: scaleMode
            )
        )
        currentTime = 0
        duration = 0
        let navigation = webView.loadFileURL(
            plan.fileURL,
            allowingReadAccessTo: plan.readAccessURL
        )
        context.coordinator.register(navigation: navigation)

        DispatchQueue.main.async {
            self.isPlaying = autoplay
        }
    }

    private func applyPlaybackState(
        _ delta: VideoPlaybackStateDelta,
        requestedState: VideoPlaybackState,
        in webView: WKWebView,
        coordinator: Coordinator
    ) {
        coordinator.updateDesiredPlaybackState(requestedState)
        guard delta != .none else { return }
        coordinator.applyDesiredPlaybackStateIfNeeded(in: webView)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        typealias JavaScriptEvaluator = (
            _ webView: WKWebView,
            _ script: String,
            _ completion: @escaping (Any?, Error?) -> Void
        ) -> Void

        @Binding private var currentTime: Double
        @Binding private var duration: Double
        private let javaScriptEvaluator: JavaScriptEvaluator

        init(
            currentTime: Binding<Double>,
            duration: Binding<Double>,
            javaScriptEvaluator: @escaping JavaScriptEvaluator = { webView, script, completion in
                webView.evaluateJavaScript(script, completionHandler: completion)
            }
        ) {
            _currentTime = currentTime
            _duration = duration
            self.javaScriptEvaluator = javaScriptEvaluator
            super.init()
        }

        private(set) var lastAppliedState: VideoPlaybackState?
        var currentURL: URL?
        var lastHandledSeekID: UUID?
        private(set) var documentToken = UUID().uuidString
        private(set) var isDocumentConfigured = false
        private var pollTimer: Timer?
        private var documentGeneration: UInt = 0
        private var currentNavigation: WKNavigation?
        private var loadPlan: WebMLocalFileLoadPlan?
        private var desiredConfiguration: WebMVideoDOMConfiguration?
        private var pendingSeekTime: Double?
        private var configurationSequenceStarted = false
        private var playbackStateApplicationInFlight = false

        func beginLoading(
            _ plan: WebMLocalFileLoadPlan,
            configuration: WebMVideoDOMConfiguration
        ) {
            documentGeneration &+= 1
            pollTimer?.invalidate()
            pollTimer = nil
            currentNavigation = nil
            loadPlan = plan
            desiredConfiguration = configuration
            pendingSeekTime = nil
            configurationSequenceStarted = false
            playbackStateApplicationInFlight = false
            isDocumentConfigured = false
            currentURL = plan.fileURL
            lastAppliedState = nil
            documentToken = UUID().uuidString
            currentTime = 0
            duration = 0
        }

        func register(navigation: WKNavigation?) {
            currentNavigation = navigation
        }

        func updateDesiredPlaybackState(_ state: VideoPlaybackState) {
            desiredConfiguration?.playbackState = state
        }

        func invalidateDocument() {
            documentGeneration &+= 1
            pollTimer?.invalidate()
            pollTimer = nil
            currentURL = nil
            lastAppliedState = nil
            currentNavigation = nil
            loadPlan = nil
            desiredConfiguration = nil
            pendingSeekTime = nil
            configurationSequenceStarted = false
            playbackStateApplicationInFlight = false
            isDocumentConfigured = false
            documentToken = UUID().uuidString
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            beginConfigurationIfCurrent(
                navigation: navigation,
                outcome: .finished,
                webView: webView
            )
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            beginConfigurationIfCurrent(
                navigation: navigation,
                outcome: .failed(
                    domain: (error as NSError).domain,
                    code: (error as NSError).code
                ),
                webView: webView
            )
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            beginConfigurationIfCurrent(
                navigation: navigation,
                outcome: .failed(
                    domain: (error as NSError).domain,
                    code: (error as NSError).code
                ),
                webView: webView
            )
        }

        private func beginConfigurationIfCurrent(
            navigation: WKNavigation?,
            outcome: WebMVideoNavigationOutcome,
            webView: WKWebView
        ) {
            guard isCurrent(navigation: navigation),
                  WebMLocalFileLoadPolicy.shouldConfigure(after: outcome),
                  !configurationSequenceStarted else { return }
            configureCurrentDocument(in: webView)
        }

        /// Starts configuration for the active load. Kept separate from the navigation delegate
        /// callback so the state/acknowledgement handshake can be exercised deterministically.
        func configureCurrentDocument(in webView: WKWebView) {
            guard !configurationSequenceStarted else { return }
            configurationSequenceStarted = true
            configureDocument(in: webView, generation: documentGeneration, attempt: 1)
        }

        private func isCurrent(navigation: WKNavigation?) -> Bool {
            // WebKit may supply nil for the plug-in-handled provisional failure. Native
            // generation and in-document URL checks still prevent an old load configuring a
            // newer document.
            guard let navigation, let currentNavigation else { return true }
            return currentNavigation === navigation
        }

        private func configureDocument(
            in webView: WKWebView,
            generation: UInt,
            attempt: Int
        ) {
            guard documentGeneration == generation,
                  let loadPlan,
                  let configuration = desiredConfiguration else { return }

            let expectedURL = Self.javaScriptLiteral(loadPlan.fileURL.absoluteString)
            let token = Self.javaScriptLiteral(documentToken)
            let seekStatement = pendingSeekTime.map { "try { video.currentTime = \($0); } catch (_) {}" } ?? ""
            let state = configuration.playbackState
            let action = state.isPlaying
                ? "video.play().catch(() => {});"
                : "video.pause();"
            let script = """
            (() => {
                if (window.location.href !== \(expectedURL)) return false;
                const video = document.querySelector('video');
                if (!video) return false;
                document.documentElement.style.cssText = 'margin:0;width:100%;height:100%;overflow:hidden;background:#000';
                if (document.body) document.body.style.cssText = 'margin:0;width:100%;height:100%;overflow:hidden;background:#000';
                video.id = 'video';
                video.style.cssText = 'display:block;width:100%;height:100%;object-fit:\(configuration.scaleMode.rawValue);background:#000';
                video.controls = \(configuration.showsNativeControls ? "true" : "false");
                video.playsInline = true;
                video.loop = \(configuration.loopEnabled ? "true" : "false");
                video.autoplay = \(state.isPlaying ? "true" : "false");
                video.playbackRate = \(Double(state.rate));
                video.muted = \(state.isMuted ? "true" : "false");
                video.defaultMuted = \(state.isMuted ? "true" : "false");
                video.volume = \(Double(state.volume));
                window.noDrawVideoDocumentToken = \(token);
                \(seekStatement)
                \(action)
                return true;
            })();
            """

            javaScriptEvaluator(webView, script) { [weak self, weak webView] result, _ in
                guard let self, let webView,
                      self.documentGeneration == generation else { return }
                if (result as? Bool) == true {
                    // `state` is the exact snapshot embedded in the acknowledged script. Desired
                    // state may have changed while WebKit was evaluating it, so record only the
                    // snapshot and immediately reconcile the delta.
                    self.lastAppliedState = state
                    self.isDocumentConfigured = true
                    self.pendingSeekTime = nil
                    self.startPolling(webView)
                    self.applyDesiredPlaybackStateIfNeeded(in: webView)
                } else if WebMLocalFileLoadPolicy.shouldRetryConfiguration(afterAttempt: attempt) {
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + WebMLocalFileLoadPolicy.configurationRetryDelay
                    ) { [weak self, weak webView] in
                        guard let self, let webView,
                              self.documentGeneration == generation else { return }
                        self.configureDocument(
                            in: webView,
                            generation: generation,
                            attempt: attempt + 1
                        )
                    }
                }
            }
        }

        /// Serializes DOM playback writes and advances `lastAppliedState` only after JavaScript
        /// confirms that it updated the current document. A newer desired state is picked up after
        /// the acknowledgement, preventing an older completion from winning the race.
        func applyDesiredPlaybackStateIfNeeded(in webView: WKWebView) {
            guard isDocumentConfigured,
                  !playbackStateApplicationInFlight,
                  let desiredState = desiredConfiguration?.playbackState else { return }

            let delta = VideoPlaybackStateDelta.between(
                previous: lastAppliedState,
                requested: desiredState
            )
            guard delta != .none else { return }

            var statements: [String] = []
            if let rate = delta.rate {
                statements.append("video.playbackRate = \(Double(rate));")
            }
            if let muted = delta.isMuted {
                statements.append("video.muted = \(muted ? "true" : "false");")
            }
            if let volume = delta.volume {
                statements.append("video.volume = \(Double(volume));")
            }
            switch delta.playbackCommand {
            case .play:
                statements.append("video.play().catch(() => {});")
            case .pause:
                statements.append("video.pause();")
            case nil:
                break
            }

            let generation = documentGeneration
            let token = Self.javaScriptLiteral(documentToken)
            let script = """
            (() => {
                const video = document.getElementById('video');
                if (!video || window.noDrawVideoDocumentToken !== \(token)) return false;
                \(statements.joined(separator: "\n"))
                return true;
            })();
            """

            playbackStateApplicationInFlight = true
            javaScriptEvaluator(webView, script) { [weak self, weak webView] result, _ in
                guard let self, let webView,
                      self.documentGeneration == generation else { return }
                self.playbackStateApplicationInFlight = false
                guard (result as? Bool) == true else { return }
                self.lastAppliedState = desiredState
                self.applyDesiredPlaybackStateIfNeeded(in: webView)
            }
        }

        private static func javaScriptLiteral(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed]
            ), let literal = String(data: data, encoding: .utf8) else {
                return "\"\""
            }
            return literal
        }

        func startPolling(_ webView: WKWebView) {
            pollTimer?.invalidate()
            let generation = documentGeneration
            let token = documentToken
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak webView] _ in
                guard let self, let webView,
                      self.documentGeneration == generation else { return }
                let script = """
                (() => {
                    const video = document.getElementById('video');
                    if (!video || window.noDrawVideoDocumentToken !== "\(token)") return null;
                    const duration = Number.isFinite(video.duration) ? video.duration : 0;
                    return [video.currentTime || 0, duration];
                })();
                """
                webView.evaluateJavaScript(script) { [weak self] result, _ in
                    guard let self,
                          self.documentGeneration == generation else { return }
                    guard let values = result as? [Any], values.count == 2 else { return }
                    if let time = values[0] as? Double, time.isFinite, time >= 0 {
                        self.currentTime = time
                    }
                    if let duration = values[1] as? Double, duration.isFinite, duration > 0 {
                        self.duration = duration
                    }
                }
            }
        }

        func handleSeekRequest(_ request: VideoSeekRequest?, in webView: WKWebView) {
            guard let request,
                  request.id != lastHandledSeekID,
                  let currentURL,
                  VideoPlaybackUpdatePolicy.sourcesMatch(request.sourceURL, currentURL) else { return }
            lastHandledSeekID = request.id
            let target = max(0, request.time)
            currentTime = target
            pendingSeekTime = target
            guard isDocumentConfigured else { return }
            let token = documentToken
            webView.evaluateJavaScript("""
            (() => {
                const video = document.getElementById('video');
                if (!video || window.noDrawVideoDocumentToken !== "\(token)") return;
                video.currentTime = \(target);
            })();
            """) { [weak self] _, error in
                if error == nil {
                    self?.pendingSeekTime = nil
                }
            }
        }

        deinit {
            pollTimer?.invalidate()
        }
    }
}

// MARK: - NavigableAVPlayerView

/// Custom AVPlayerView that forwards arrow keys for navigation instead of frame stepping.
/// Uses performKeyEquivalent to intercept keys BEFORE they reach internal AVKit controls.
class NavigableAVPlayerView: AVPlayerView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?

    /// Intercept arrow keys before AVKit's internal controls consume them for frame stepping.
    /// performKeyEquivalent is called on the entire view hierarchy, giving us a chance
    /// to handle the event before subviews (like AVKit's scrubber) can claim it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only intercept arrow keys without modifiers (allow shift+arrow for selection, etc.)
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.keyCode {
        case 123: // Left arrow -> navigation, not frame step
            onLeft?()
            return true // Consumed - don't let AVKit frame-step
        case 124: // Right arrow -> navigation, not frame step
            onRight?()
            return true // Consumed - don't let AVKit frame-step
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // Left arrow -> navigation (fallback if performKeyEquivalent missed it)
            onLeft?()
        case 124: // Right arrow -> navigation
            onRight?()
        case 53: // Escape - let parent handle
            super.keyDown(with: event)
        default:
            // Let other keys (space for play/pause, etc.) work normally
            super.keyDown(with: event)
        }
    }
}

final class NavigableWKWebView: WKWebView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.keyCode {
        case 123:
            onLeft?()
            return true
        case 124:
            onRight?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123:
            onLeft?()
        case 124:
            onRight?()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Video Transport Controls

struct VideoTransportControls: View {
    @Binding var isPlaying: Bool
    @Binding var isMuted: Bool
    @Binding var volume: Float
    @Binding var rate: Float
    let currentTime: Double
    let duration: Double

    private static let steps: [Float] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]
    let onSeek: (Double) -> Void
    let onToggleMute: () -> Void
    let canGoToPreviousResult: Bool
    let canGoToNextResult: Bool
    let onPreviousItem: () -> Void
    let onNextItem: () -> Void

    private var displayText: String {
        if rate == Float(Int(rate)) {
            return "\(Int(rate))x"
        }
        // Drop trailing zeros: 0.50 -> 0.5, 1.25 -> 1.25
        let formatted = String(format: "%g", rate)
        return "\(formatted)x"
    }

    private var nearestStepIndex: Int {
        Self.steps.enumerated().min { lhs, rhs in
            abs(lhs.element - rate) < abs(rhs.element - rate)
        }?.offset ?? 3
    }

    var body: some View {
        VStack(spacing: 6) {
            VideoProgressControl(
                currentTime: currentTime,
                duration: duration,
                onSeek: onSeek
            )

            // Narrow viewers drop the volume slider first; mute stays, and the bar never clips.
            ViewThatFits(in: .horizontal) {
                controlsRow(showsVolumeSlider: true)
                controlsRow(showsVolumeSlider: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        .accessibilityElement(children: .contain)
    }

    private func controlsRow(showsVolumeSlider: Bool) -> some View {
        HStack(spacing: 8) {
            VideoControlButton(
                systemImage: "backward.end.fill",
                label: AppCommandCatalog.previousResult.title,
                action: onPreviousItem
            )
            .disabled(!canGoToPreviousResult)
            .help(AppCommandCatalog.previousResult.help)
            VideoControlButton(
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                label: isPlaying ? "Pause" : "Play",
                shortcut: "Space",
                isPrimary: true
            ) {
                isPlaying.toggle()
            }
            VideoControlButton(
                systemImage: volumeIcon,
                label: isMuted ? "Unmute" : "Mute"
            ) {
                onToggleMute()
            }
            if showsVolumeSlider {
                VideoVolumeControl(volume: $volume, isMuted: $isMuted)
            }

            Divider()
                .frame(height: 22)
                .background(Color.white.opacity(0.18))

            VideoControlButton(systemImage: "minus", label: "Slow down") {
                stepRate(by: -1)
            }
            Text(displayText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(rate == 1.0 ? .secondary : .primary)
                .frame(width: 46, height: 32)
                .accessibilityLabel("Playback speed \(displayText)")
            VideoControlButton(systemImage: "plus", label: "Speed up") {
                stepRate(by: 1)
            }

            Divider()
                .frame(height: 22)
                .background(Color.white.opacity(0.18))

            VideoControlButton(
                systemImage: "forward.end.fill",
                label: AppCommandCatalog.nextResult.title,
                action: onNextItem
            )
            .disabled(!canGoToNextResult)
            .help(AppCommandCatalog.nextResult.help)
        }
    }

    private func stepRate(by offset: Int) {
        let nextIndex = min(max(nearestStepIndex + offset, 0), Self.steps.count - 1)
        rate = Self.steps[nextIndex]
    }

    private var volumeIcon: String {
        if isMuted || volume <= 0.001 {
            return "speaker.slash.fill"
        }
        if volume < 0.5 {
            return "speaker.wave.1.fill"
        }
        return "speaker.wave.2.fill"
    }
}

private struct VideoProgressControl: View {
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    private var effectiveDuration: Double {
        duration.isFinite && duration > 0 ? duration : 1
    }

    private var displayedTime: Double {
        isScrubbing ? scrubTime : min(max(currentTime, 0), effectiveDuration)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(VideoSegment.formatTime(displayedTime))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { displayedTime },
                    set: { newValue in
                        scrubTime = min(max(newValue, 0), effectiveDuration)
                    }
                ),
                in: 0...effectiveDuration,
                onEditingChanged: { editing in
                    if editing {
                        scrubTime = displayedTime
                        isScrubbing = true
                    } else {
                        isScrubbing = false
                        onSeek(scrubTime)
                    }
                }
            )
            .controlSize(.small)
            .tint(Color.accentOrange)
            .disabled(duration <= 0)
            .accessibilityLabel("Video progress")
            .accessibilityValue("\(VideoSegment.formatTime(displayedTime)) of \(VideoSegment.formatTime(duration))")

            Text(duration > 0 ? VideoSegment.formatTime(duration) : "0:00")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
        .frame(maxWidth: 480)
        .help("Scrub video")
    }
}

private struct VideoVolumeControl: View {
    @Binding var volume: Float
    @Binding var isMuted: Bool

    var body: some View {
        HStack(spacing: 6) {
            NativeVolumeSlider(volume: $volume, isMuted: $isMuted)
                .frame(width: 96, height: 18)
                .accessibilityLabel("Video volume")
                .accessibilityValue("\(Int(round(VideoPlaybackDefaults.clampVolume(volume) * 100))) percent")
        }
        .frame(width: 104, height: 32)
        .contentShape(Rectangle())
        .help("Volume. Scroll while hovering to adjust.")
    }
}

private struct NativeVolumeSlider: NSViewRepresentable {
    @Binding var volume: Float
    @Binding var isMuted: Bool

    func makeNSView(context: Context) -> ScrollableVolumeSlider {
        let slider = ScrollableVolumeSlider(
            value: Double(VideoPlaybackDefaults.clampVolume(volume)),
            minValue: 0,
            maxValue: 1,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.isContinuous = true
        slider.controlSize = .small
        slider.scrollHandler = { delta in
            context.coordinator.adjustVolume(delta: delta)
        }
        return slider
    }

    func updateNSView(_ slider: ScrollableVolumeSlider, context: Context) {
        let clamped = VideoPlaybackDefaults.clampVolume(volume)
        if abs(Float(slider.doubleValue) - clamped) > 0.001 {
            slider.doubleValue = Double(clamped)
        }
        slider.scrollHandler = { delta in
            context.coordinator.adjustVolume(delta: delta)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(volume: $volume, isMuted: $isMuted)
    }

    final class Coordinator: NSObject {
        @Binding private var volume: Float
        @Binding private var isMuted: Bool

        init(volume: Binding<Float>, isMuted: Binding<Bool>) {
            _volume = volume
            _isMuted = isMuted
        }

        @objc func valueChanged(_ sender: NSSlider) {
            setVolume(Float(sender.doubleValue))
        }

        func adjustVolume(delta: CGFloat) {
            let step: Float = delta > 0 ? 0.05 : -0.05
            setVolume(volume + step)
        }

        private func setVolume(_ newValue: Float) {
            let clamped = VideoPlaybackDefaults.clampVolume(newValue)
            volume = clamped
            isMuted = clamped <= 0.001
        }
    }
}

private final class ScrollableVolumeSlider: NSSlider {
    var scrollHandler: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.5 else {
            super.scrollWheel(with: event)
            return
        }
        scrollHandler?(delta)
    }
}

private struct VideoControlButton: View {
    let systemImage: String
    let label: String
    var shortcut: String? = nil
    /// Play/pause reads first: full-strength glyph, slightly larger.
    var isPrimary = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isPrimary ? 16 : 14, weight: .semibold))
                .foregroundStyle(isHovered || isPrimary ? .primary : .secondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(shortcut.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
    }
}

// MARK: - Scroll Wheel Modifier

private struct ScrollWheelModifier: ViewModifier {
    let handler: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background(
            ScrollWheelReceiver(handler: handler)
        )
    }
}

private struct ScrollWheelReceiver: NSViewRepresentable {
    let handler: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.handler = handler
    }
}

private class ScrollWheelNSView: NSView {
    var handler: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        if abs(delta) > 0.5 {
            handler?(delta)
        }
    }
}

private extension View {
    func onScrollWheel(_ handler: @escaping (CGFloat) -> Void) -> some View {
        modifier(ScrollWheelModifier(handler: handler))
    }
}
