import SwiftUI
import AVKit
import CoreMedia

// MARK: - VideoTrimSheet

/// NSViewRepresentable that wraps AVPlayerView with native macOS trim UI.
/// Presents filmstrip timeline with draggable in/out handles via `beginTrimmingWithCompletionHandler:`.
///
/// ## Issue #6: Keyboard Fine-Tune Controls Limitation
/// The native `AVPlayerView.beginTrimming()` API does not expose keyboard shortcuts for
/// frame-precise handle adjustment. Users must drag handles with mouse/trackpad.
/// This is a limitation of the macOS AVKit framework.
///
/// A future enhancement could implement a custom trim UI with:
/// - Arrow key nudging for frame-by-frame adjustment
/// - J/K/L for playback control during trim selection
/// - Keyboard shortcuts for in/out point marking
///
/// For now, users can achieve precise trimming by:
/// 1. Dragging handles while zoomed in on the timeline
/// 2. Using modifier keys (if supported by the native UI)
struct VideoTrimSheet: NSViewRepresentable {
    let sourceURL: URL
    let onComplete: (CMTimeRange?) -> Void  // nil = cancelled
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        let player = AVPlayer(url: sourceURL)
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false

        // Store references in coordinator for trim result extraction
        context.coordinator.player = player
        context.coordinator.playerView = playerView
        context.coordinator.onComplete = onComplete
        context.coordinator.onDismiss = onDismiss
        context.coordinator.trimSheetRef = self

        // Observe player item status to know when it's ready
        context.coordinator.statusObservation = player.currentItem?.observe(\.status, options: [.new]) { item, _ in
            DispatchQueue.main.async {
                if item.status == .readyToPlay {
                    Log.info("VideoTrimSheet: Player ready, canBeginTrimming = \(playerView.canBeginTrimming)")
                    context.coordinator.statusObservation = nil  // Stop observing
                    if playerView.canBeginTrimming {
                        context.coordinator.trimSheetRef?.beginTrimSession(playerView: playerView, context: context)
                    } else {
                        Log.warning("VideoTrimSheet: Player ready but cannot trim")
                        context.coordinator.onComplete?(nil)
                        context.coordinator.onDismiss?()
                    }
                } else if item.status == .failed {
                    Log.error("VideoTrimSheet: Player failed to load: \(String(describing: item.error))")
                    context.coordinator.statusObservation = nil
                    context.coordinator.onComplete?(nil)
                    context.coordinator.onDismiss?()
                }
            }
        }

        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        // No updates needed - trim session is one-shot
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func beginTrimSession(playerView: AVPlayerView, context: Context) {
        Log.info("VideoTrimSheet: Beginning trim session")
        playerView.beginTrimming { result in
            Log.info("VideoTrimSheet: Trim completed with result: \(result)")
            switch result {
            case .okButton:
                // User confirmed trim - extract the trim range from player item
                Log.info("VideoTrimSheet: User confirmed trim (OK)")
                if let item = context.coordinator.player?.currentItem {
                    let range = extractTrimRange(from: item)
                    Log.info("VideoTrimSheet: Extracted range: \(String(describing: range))")
                    context.coordinator.onComplete?(range)
                } else {
                    Log.warning("VideoTrimSheet: No current item to extract range from")
                    context.coordinator.onComplete?(nil)
                }
            case .cancelButton:
                Log.info("VideoTrimSheet: User cancelled trim")
                context.coordinator.onComplete?(nil)
            @unknown default:
                Log.warning("VideoTrimSheet: Unknown trim result")
                context.coordinator.onComplete?(nil)
            }
            context.coordinator.onDismiss?()
        }
    }

    /// Extracts the trim range from a player item after trimming UI completes.
    /// AVPlayerView sets reversePlaybackEndTime (in-point) and forwardPlaybackEndTime (out-point).
    @MainActor
    private func extractTrimRange(from item: AVPlayerItem) -> CMTimeRange? {
        let inPoint = item.reversePlaybackEndTime
        let outPoint = item.forwardPlaybackEndTime

        // Both times should be valid after a successful trim
        // Note: kCMTimeInvalid is returned if user didn't move handles
        if inPoint.isValid && outPoint.isValid {
            let duration = CMTimeSubtract(outPoint, inPoint)
            return CMTimeRange(start: inPoint, duration: duration)
        }

        // Fallback: user clicked OK without moving handles - return full duration
        // Using deprecated sync API here since we're in a callback context
        // and the fallback rarely triggers
        let duration = item.duration
        guard duration.isValid && !duration.isIndefinite else { return nil }
        return CMTimeRange(start: .zero, duration: duration)
    }

    // MARK: - Coordinator

    class Coordinator {
        var player: AVPlayer?
        var playerView: AVPlayerView?
        var onComplete: ((CMTimeRange?) -> Void)?
        var onDismiss: (() -> Void)?
        var statusObservation: NSKeyValueObservation?
        var trimSheetRef: VideoTrimSheet?
    }
}

// MARK: - VideoTrimSheetWrapper (Issue #3: Add visible Cancel + loading state)

/// Wrapper view that shows loading state while video loads and provides explicit Cancel button.
/// Addresses Issue #3: Trim sheet has no Cancel visible in the wrapper.
struct VideoTrimSheetWrapper: View {
    let sourceURL: URL
    let onComplete: (CMTimeRange?) -> Void
    let onDismiss: () -> Void

    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header with title and Cancel button
            HStack {
                Text("Trim Video")
                    .font(.headline)

                Spacer()

                // Issue #3: Visible Cancel button in wrapper
                Button("Cancel") {
                    onComplete(nil)
                    onDismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(Color(hex: 0x2a2a2a))

            Divider()

            // Main content
            if let error = loadError {
                // Error state
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Failed to Load Video")
                        .font(.headline)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    VideoTrimSheet(
                        sourceURL: sourceURL,
                        onComplete: onComplete,
                        onDismiss: onDismiss
                    )

                    // Issue #3: Loading state while canBeginTrimming is false
                    if isLoading {
                        ZStack {
                            Color.black.opacity(0.7)
                            VStack(spacing: 16) {
                                ProgressView()
                                    .scaleEffect(1.5)
                                Text("Loading video...")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }

            // Issue #4: Preview note in footer
            // Note: Full preview before export would require custom UI
            // The native trim UI allows scrubbing, which serves as preview
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Scrub through the timeline to preview your selection before clicking OK")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(hex: 0x2a2a2a))
        }
        .background(Color(hex: 0x1a1a1a))
        .onAppear {
            // Check if video can load and set loading state accordingly
            checkVideoLoad()
        }
    }

    private func checkVideoLoad() {
        let asset = AVURLAsset(url: sourceURL)
        Task {
            do {
                // Try to load basic properties to verify video is accessible
                let _ = try await asset.load(.duration)
                await MainActor.run {
                    // Give the AVPlayerView time to initialize
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct VideoTrimSheet_Previews: PreviewProvider {
    static var previews: some View {
        VideoTrimSheetWrapper(
            sourceURL: URL(fileURLWithPath: "/tmp/test.mp4"),
            onComplete: { range in
                if let range = range {
                    logDebug("Trim range: \(range.start.seconds)s - \(range.end.seconds)s")
                } else {
                    logDebug("Trim cancelled")
                }
            },
            onDismiss: {
                logDebug("Dismissed")
            }
        )
        .frame(width: 800, height: 500)
    }
}
#endif
