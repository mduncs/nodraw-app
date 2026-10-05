import SwiftUI
import AppKit
import AVKit

// MARK: - Rediscover View

/// Full-screen review session for FSRS spaced repetition.
/// Shows items due for review with rating buttons (Again/Hard/Good/Easy).
struct RediscoverView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: RediscoverViewModel

    let onClose: () -> Void

    init(onClose: @escaping () -> Void, mediaStore: MediaStore) {
        self.onClose = onClose
        self._viewModel = StateObject(wrappedValue: RediscoverViewModel(mediaStore: mediaStore))
    }

    var body: some View {
        ZStack {
            // Background
            Color(hex: 0x1a1a1a)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                topBar

                Divider()
                    .background(Color.white.opacity(0.1))

                // Main content
                if viewModel.isLoading {
                    loadingView
                } else if viewModel.dueItems.isEmpty {
                    emptyView
                } else if let currentItem = viewModel.currentItem {
                    reviewContent(item: currentItem)
                } else {
                    completedView
                }
            }

            // Undo toast overlay (Issue #5)
            if viewModel.showUndoToast {
                VStack {
                    Spacer()
                    undoToast
                        .padding(.bottom, 100)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.showUndoToast)
            }
        }
        .background(
            RediscoverKeyHandler(
                onClose: onClose,
                onGrade: { grade in
                    Task { await viewModel.rateCurrentItem(grade: grade) }
                },
                onSkip: {
                    Task { await viewModel.skipCurrentItem() }
                },
                onUndo: {
                    Task { await viewModel.undoLastRating() }
                }
            )
        )
        .task {
            await viewModel.loadDueItems()
            syncDisplayContext()
        }
        .onChange(of: viewModel.dueItems) { _ in
            syncDisplayContext()
        }
        .onChange(of: viewModel.currentItem?.id) { _ in
            syncDisplayContext()
        }
    }

    // MARK: - Undo Toast (Issue #5)

    private var undoToast: some View {
        HStack(spacing: 12) {
            Text(viewModel.undoMessage)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)

            Button(action: {
                Task { await viewModel.undoLastRating() }
            }) {
                Text("Undo")
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .foregroundColor(Color.accentOrange)
            }
            .buttonStyle(.plain)

            Text("(Cmd+Z)")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))

            Button(action: {
                viewModel.dismissUndoToast()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: 0x2a2a2a))
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Back button
            Button(action: onClose) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.medium))
                    Text("Back")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.05))
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            // Progress indicator with time estimate (Issue #9)
            if !viewModel.dueItems.isEmpty {
                progressIndicator
            }

            Spacer()

            // Session stats
            if viewModel.sessionReviews > 0 {
                sessionStats
            }

            // Time remaining estimate (Issue #9)
            if let timeEstimate = viewModel.estimatedTimeRemaining {
                Text(timeEstimate)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.05), in: Capsule())
                    .help("Estimated time remaining based on your average rating speed")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: 0x1f1f1f))
    }

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            // Current position (Issue #12: show reviewed count, not 1-indexed position)
            Text("\(viewModel.sessionReviews)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(Color.accentOrange)

            Text("of \(viewModel.dueItems.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            // Progress bar (Issue #12: 0% until first rating)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.1))

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentOrange)
                        .frame(width: geo.size.width * viewModel.progressPercentage)
                }
            }
            .frame(width: 80, height: 4)
        }
    }

    private var sessionStats: some View {
        HStack(spacing: 12) {
            statBadge(count: viewModel.sessionReviews, label: "reviewed", color: .green)
            if viewModel.sessionSkipped > 0 {
                statBadge(count: viewModel.sessionSkipped, label: "skipped", color: .orange)
            }
        }
    }

    private func statBadge(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading items...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty View (Issue #7: Explain how to add items)

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("All caught up!")
                .font(.title.weight(.semibold))

            Text("No items due for review right now.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Issue #7: Helper text explaining how to add items
            VStack(spacing: 8) {
                Divider()
                    .frame(width: 200)
                    .padding(.vertical, 8)

                HStack(spacing: 8) {
                    Image(systemName: "hand.draw")
                        .foregroundStyle(.purple)
                    Text("Drag items to Rediscover in the sidebar to add them")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "r.square")
                        .foregroundStyle(.purple)
                    Text("Or press R on any selected item")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 8)

            Button("Done") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Completed View

    private var completedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "star.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentOrange)

            Text("Session Complete!")
                .font(.title.weight(.semibold))

            VStack(spacing: 8) {
                Text("You reviewed \(viewModel.sessionReviews) items")
                    .font(.body)
                if viewModel.sessionSkipped > 0 {
                    Text("Skipped \(viewModel.sessionSkipped) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Done") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Review Content

    @ViewBuilder
    private func reviewContent(item: MediaItem) -> some View {
        VStack(spacing: 0) {
            // Main media display
            GeometryReader { geo in
                mediaView(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // Rating buttons
            ratingBar(for: item)
        }
    }

    @ViewBuilder
    private func mediaView(for item: MediaItem) -> some View {
        if let mediaURL = item.primaryMedia ?? item.contextImage {
            if ThumbnailGenerator.isVideo(mediaURL) {
                VideoThumbnailView(url: mediaURL)
            } else {
                CachedAsyncImage(url: mediaURL)
            }
        } else {
            // Placeholder for items without media
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No preview available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hex: 0x2a2a2a))
        }
    }

    private func ratingBar(for item: MediaItem) -> some View {
        VStack(spacing: 16) {
            // Item info
            HStack(spacing: 12) {
                if item.metadata.starred {
                    Image(systemName: "star.fill")
                        .foregroundStyle(Color.accentOrange)
                }

                if let author = item.metadata.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Issue #13: Consistent platform badge styling
                platformBadge(for: item.metadata.platform)

                // Issue #3: Interest score with better explanation
                if let score = viewModel.currentInterestScore {
                    interestScoreView(score: score, item: item)
                }

                Spacer()

                // View in Focus button (Issue #6: for videos without rating)
                Button(action: {
                    syncDisplayContext()
                    appState.openSingleFocus(item, navigationItems: viewModel.dueItems)
                    onClose()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                        Text("View")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Open in Focus view without rating")
            }

            // Issue #4: Predictions header + Anki-style rating buttons
            VStack(spacing: 8) {
                Text("Next review if you rate:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Rating buttons with embedded predictions (Issue #4, #11)
                HStack(spacing: 12) {
                    ForEach(ReviewGrade.allCases, id: \.rawValue) { grade in
                        ratingButton(grade: grade, prediction: viewModel.nextReviewPredictions?[grade])
                    }

                    // Issue #10: Explicit Skip button for mouse users
                    skipButton
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(hex: 0x1f1f1f))
    }

    // Issue #13: Consistent platform badge styling
    private func platformBadge(for platform: String) -> some View {
        Text(platform.capitalized)
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.15))
            )
    }

    private func syncDisplayContext() {
        let selectedID = viewModel.currentItem?.id
        appState.setDisplayContext(
            surface: .rediscover,
            items: viewModel.dueItems,
            selectedIDs: selectedID.map { [$0] } ?? [],
            anchorID: selectedID
        )
    }

    // Issue #10: Skip button for mouse users
    private var skipButton: some View {
        Button {
            Task { await viewModel.skipCurrentItem() }
        } label: {
            VStack(spacing: 4) {
                Text("Skip")
                    .font(.headline)
                Text("[S]")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 70)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    /// Issue #3: Interest score indicator with flame icon and detailed tooltip
    private func interestScoreView(score: Double, item: MediaItem) -> some View {
        let level: String
        let color: Color
        if score >= 0.8 {
            level = "High"
            color = .orange
        } else if score >= 0.5 {
            level = "Med"
            color = .yellow
        } else {
            level = "Low"
            color = .gray
        }

        // Build factors list for tooltip
        var factors: [String] = []
        if item.metadata.starred { factors.append("starred") }
        if !item.metadata.tags.isEmpty { factors.append("\(item.metadata.tags.count) tags") }
        if item.metadata.notes != nil { factors.append("notes") }
        let factorsText = factors.isEmpty ? "no engagement yet" : factors.joined(separator: ", ")

        return HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.caption)
                .foregroundStyle(color)
            Text(level)
                .font(.caption)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
        .help("Interest Score: \(Int(score * 100))%\nBased on: \(factorsText)")
    }

    private func formatInterval(to date: Date) -> String {
        let days = date.timeIntervalSinceNow / 86400
        if days < 1 {
            let hours = max(1, Int(days * 24))
            return "\(hours)h"
        } else if days < 7 {
            return "\(Int(days))d"
        } else if days < 30 {
            let weeks = Int(days / 7)
            return "\(weeks)w"
        } else if days < 365 {
            let months = Int(days / 30)
            return "\(months)mo"
        } else {
            let years = Int(days / 365)
            return "\(years)y"
        }
    }

    /// Issue #4 + #11: Rating button with embedded prediction and keyboard hint
    private func ratingButton(grade: ReviewGrade, prediction: Date?) -> some View {
        let gradeColor = Color(
            red: grade.color.red,
            green: grade.color.green,
            blue: grade.color.blue
        )

        return Button {
            Task { await viewModel.rateCurrentItem(grade: grade) }
        } label: {
            VStack(spacing: 4) {
                // Issue #11: Keyboard hint in button (e.g., "[1] Again")
                HStack(spacing: 4) {
                    Text("[\(grade.keyboardShortcut)]")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(gradeColor.opacity(0.7))
                    Text(grade.displayName)
                        .font(.headline)
                }

                // Issue #4: Anki-style prediction in button
                if let prediction = prediction {
                    Text(formatInterval(to: prediction))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(gradeColor.opacity(0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(gradeColor.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(gradeColor)
    }
}

// MARK: - View Model

@MainActor
class RediscoverViewModel: ObservableObject {
    @Published var dueItems: [MediaItem] = []
    @Published var currentIndex: Int = 0
    @Published var isLoading: Bool = true
    @Published var sessionReviews: Int = 0
    @Published var sessionSkipped: Int = 0
    @Published var nextReviewPredictions: [ReviewGrade: Date]? = nil
    @Published var currentInterestScore: Double? = nil

    // Issue #5: Undo support
    @Published var showUndoToast: Bool = false
    @Published var undoMessage: String = ""
    private var lastRating: (itemId: UUID, grade: ReviewGrade, previousState: ReviewStateRecord?)?
    private var undoDismissTask: Task<Void, Never>?

    // Issue #9: Time estimation
    private var ratingTimes: [Date] = []
    private var sessionStartTime: Date?

    private let mediaStore: MediaStore
    let scheduler: ReviewScheduler

    var currentItem: MediaItem? {
        guard currentIndex < dueItems.count else { return nil }
        return dueItems[currentIndex]
    }

    // Issue #12: Progress based on reviews done, not current index
    var progressPercentage: Double {
        guard !dueItems.isEmpty else { return 0 }
        return Double(sessionReviews) / Double(dueItems.count)
    }

    // Issue #9: Estimated time remaining
    var estimatedTimeRemaining: String? {
        guard sessionReviews >= 2 else { return nil } // Need at least 2 ratings for estimate

        let remaining = dueItems.count - sessionReviews - sessionSkipped
        guard remaining > 0, let startTime = sessionStartTime else { return nil }

        let elapsed = Date().timeIntervalSince(startTime)
        let completed = sessionReviews + sessionSkipped
        guard completed > 0 else { return nil }

        let avgTimePerItem = elapsed / Double(completed)
        let estimatedSeconds = avgTimePerItem * Double(remaining)

        if estimatedSeconds < 60 {
            return "~\(Int(estimatedSeconds))s left"
        } else {
            let minutes = Int(estimatedSeconds / 60)
            return "~\(minutes)m left"
        }
    }

    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
        self.scheduler = ReviewScheduler()
    }

    func loadDueItems() async {
        isLoading = true
        sessionStartTime = Date()

        do {
            // Get due item IDs from scheduler
            // Read deck size from settings (default 50)
            let deckSize = UserDefaults.standard.integer(forKey: "fsrsDeckSize")
            let limit = deckSize > 0 ? deckSize : 50
            let dueIds = try await scheduler.fetchDueItems(limit: limit)

            // Fetch due items in one batch (preserves scheduler order).
            dueItems = try await mediaStore.fetchItems(ids: dueIds)
            currentIndex = 0
            isLoading = false

            // Load predictions for first item
            await loadPredictions()
        } catch {
            logError("Failed to load due items: \(error.localizedDescription)")
            isLoading = false
        }
    }

    func rateCurrentItem(grade: ReviewGrade) async {
        guard let item = currentItem else { return }

        do {
            // Issue #5: Store previous state for undo
            let previousState = try? await scheduler.fetchState(for: item.id)

            try await scheduler.updateAfterReview(itemId: item.id, grade: grade)

            // Track for undo
            lastRating = (itemId: item.id, grade: grade, previousState: previousState)
            showUndoToastWithMessage("Rated \(grade.displayName)")

            sessionReviews += 1
            ratingTimes.append(Date())
            moveToNext()
        } catch {
            logError("Failed to rate item: \(error.localizedDescription)")
        }
    }

    func skipCurrentItem() async {
        if let item = currentItem {
            // Snooze for 1 day instead of leaving it due
            try? await scheduler.snoozeItem(item.id, days: 1)
        }
        sessionSkipped += 1
        moveToNext()
    }

    // Issue #5: Undo last rating
    func undoLastRating() async {
        guard let last = lastRating else { return }

        do {
            if let previousState = last.previousState {
                // Restore previous state
                try await scheduler.restoreState(previousState)
            } else {
                // Remove the review state entirely if it was new
                try await scheduler.removeState(for: last.itemId)
            }

            // Move back
            if currentIndex > 0 {
                currentIndex -= 1
                sessionReviews = max(0, sessionReviews - 1)
            }

            lastRating = nil
            dismissUndoToast()
            await loadPredictions()
        } catch {
            logError("Failed to undo rating: \(error.localizedDescription)")
        }
    }

    private func showUndoToastWithMessage(_ message: String) {
        undoMessage = message
        showUndoToast = true

        // Auto-dismiss after 4 seconds
        undoDismissTask?.cancel()
        undoDismissTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.showUndoToast = false
            }
        }
    }

    func dismissUndoToast() {
        undoDismissTask?.cancel()
        showUndoToast = false
    }

    private func moveToNext() {
        currentIndex += 1
        Task {
            await loadPredictions()
        }
    }

    private func loadPredictions() async {
        guard let item = currentItem else {
            nextReviewPredictions = nil
            currentInterestScore = nil
            return
        }

        do {
            nextReviewPredictions = try await scheduler.predictNextReview(for: item.id)
            // Also load interest score
            if let state = try await scheduler.fetchState(for: item.id) {
                currentInterestScore = state.interestScore
            } else {
                currentInterestScore = nil
            }
        } catch {
            nextReviewPredictions = nil
            currentInterestScore = nil
        }
    }
}

// MARK: - Key Handler

private struct RediscoverKeyHandler: NSViewRepresentable {
    let onClose: () -> Void
    let onGrade: (ReviewGrade) -> Void
    let onSkip: () -> Void
    let onUndo: () -> Void  // Issue #5: Undo support

    func makeNSView(context: Context) -> RediscoverKeyView {
        let view = RediscoverKeyView()
        view.onClose = onClose
        view.onGrade = onGrade
        view.onSkip = onSkip
        view.onUndo = onUndo
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: RediscoverKeyView, context: Context) {
        nsView.onClose = onClose
        nsView.onGrade = onGrade
        nsView.onSkip = onSkip
        nsView.onUndo = onUndo
    }
}

private class RediscoverKeyView: NSView {
    var onClose: (() -> Void)?
    var onGrade: ((ReviewGrade) -> Void)?
    var onSkip: (() -> Void)?
    var onUndo: (() -> Void)?  // Issue #5

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Issue #5: Handle Cmd+Z for undo
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           chars == "z" {
            onUndo?()
            return
        }

        switch event.keyCode {
        case 53: // Escape
            onClose?()
        default:
            if let chars = event.charactersIgnoringModifiers {
                switch chars {
                case "1":
                    onGrade?(.again)
                case "2":
                    onGrade?(.hard)
                case "3":
                    onGrade?(.good)
                case "4":
                    onGrade?(.easy)
                case "s", "S":
                    onSkip?()
                default:
                    super.keyDown(with: event)
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

// MARK: - Video Thumbnail View (Issue #6: Click-to-play inline)

/// Video thumbnail with click-to-play capability for review.
/// Shows first frame with play button, clicking toggles inline playback.
private struct VideoThumbnailView: View {
    let url: URL

    @State private var thumbnail: NSImage?
    @State private var isPlaying: Bool = false
    @State private var playbackRate: Float = 1.0
    @State private var isMuted: Bool = UserDefaults.standard.object(forKey: "videoMuteByDefault") as? Bool ?? true
    @State private var volume: Float = VideoPlaybackDefaults.initialVolume()
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var seekRequest: VideoSeekRequest?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if isPlaying, url.pathExtension.lowercased() == "webm" {
                WebMVideoPlayerView(
                    url: url,
                    isPlaying: $isPlaying,
                    playbackRate: $playbackRate,
                    isMuted: $isMuted,
                    volume: $volume,
                    currentTime: $currentTime,
                    duration: $duration,
                    seekRequest: $seekRequest,
                    showsNativeControls: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isPlaying, let player = player {
                // Issue #6: Inline video player
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        player.play()
                    }
                    .onDisappear {
                        player.pause()
                    }

                // Stop button overlay
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            isPlaying = false
                            player.pause()
                        }) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white.opacity(0.8))
                                .shadow(radius: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(16)
                    }
                    Spacer()
                }
            } else {
                // Thumbnail view
                if let image = thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Rectangle()
                        .fill(Color(hex: 0x2a2a2a))
                }

                // Play button
                Button(action: {
                    if player == nil, url.pathExtension.lowercased() != "webm" {
                        player = AVPlayer(url: url)
                        player?.isMuted = isMuted
                        player?.volume = VideoPlaybackDefaults.clampVolume(volume)
                    }
                    isPlaying = true
                }) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.8))
                        .shadow(radius: 4)
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: url) {
            thumbnail = await generateVideoThumbnail(url: url)
        }
    }

    private func generateVideoThumbnail(url: URL) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ThumbnailGenerator.generateVideoThumbnail(from: url, size: .medium))
            }
        }
    }
}

import AVFoundation

// MARK: - Rediscover Preview View (Issue #1)

/// Preview grid showing due items before starting a full review session.
/// Displayed in the main grid area when "Rediscover" is selected in sidebar.
struct RediscoverPreviewView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel: RediscoverPreviewViewModel

    init(mediaStore: MediaStore) {
        self._viewModel = StateObject(wrappedValue: RediscoverPreviewViewModel(mediaStore: mediaStore))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with action buttons
            headerBar

            Divider()
                .background(Color.white.opacity(0.1))

            // Preview content
            if viewModel.isLoading {
                loadingView
            } else if viewModel.dueItems.isEmpty {
                emptyView
            } else {
                previewGrid
            }
        }
        .background(Color(hex: 0x1a1a1a))
        .task {
            await viewModel.loadDueItems()
            syncDisplayContext()
        }
        .onChange(of: viewModel.dueItems) { _ in
            syncDisplayContext()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rediscover")
                    .font(.title2.weight(.semibold))

                if !viewModel.dueItems.isEmpty {
                    Text("\(viewModel.dueItems.count) items due for review")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !viewModel.dueItems.isEmpty {
                // Estimated time
                if let estimate = viewModel.estimatedSessionTime {
                    Text(estimate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.05), in: Capsule())
                }

                // Start Session button
                Button(action: {
                    appState.showRediscoverSession = true
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.caption)
                        Text("Start Session")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(hex: 0x1f1f1f))
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading due items...")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("All caught up!")
                .font(.title.weight(.semibold))

            Text("No items due for review right now.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Help text
            VStack(spacing: 8) {
                Divider()
                    .frame(width: 200)
                    .padding(.vertical, 8)

                HStack(spacing: 8) {
                    Image(systemName: "hand.draw")
                        .foregroundStyle(.purple)
                    Text("Drag items to Rediscover in the sidebar to add them")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "r.square")
                        .foregroundStyle(.purple)
                    Text("Or press R on any selected item")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200))], spacing: 16) {
                ForEach(viewModel.dueItems) { item in
                    PreviewThumbnail(item: item) {
                        // Double-click opens in focus view
                        syncDisplayContext(selectedID: item.id)
                        appState.openSingleFocus(item, navigationItems: viewModel.dueItems)
                    }
                }
            }
            .padding(20)
        }
    }

    private func syncDisplayContext(selectedID: UUID? = nil) {
        appState.setDisplayContext(
            surface: .rediscover,
            items: viewModel.dueItems,
            selectedIDs: selectedID.map { [$0] } ?? [],
            anchorID: selectedID
        )
    }
}

/// Thumbnail for preview grid
private struct PreviewThumbnail: View {
    let item: MediaItem
    let onDoubleClick: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 8) {
            // Thumbnail
            CachedImageView(item: item, size: .small, contentMode: .fill)
                .frame(height: 150)
                .clipped()
                .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isHovered ? Color.purple.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
            )

            // Metadata
            if let author = item.metadata.author {
                Text(author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            onDoubleClick()
        }
    }
}

/// ViewModel for preview
@MainActor
class RediscoverPreviewViewModel: ObservableObject {
    @Published var dueItems: [MediaItem] = []
    @Published var isLoading: Bool = true

    private let mediaStore: MediaStore
    private let scheduler = ReviewScheduler()

    var estimatedSessionTime: String? {
        guard !dueItems.isEmpty else { return nil }
        // Assume ~5 seconds per item on average
        let seconds = dueItems.count * 5
        if seconds < 60 {
            return "~\(seconds)s"
        } else {
            let minutes = seconds / 60
            return "~\(minutes) min"
        }
    }

    init(mediaStore: MediaStore) {
        self.mediaStore = mediaStore
    }

    func loadDueItems() async {
        isLoading = true

        do {
            let deckSize = UserDefaults.standard.integer(forKey: "fsrsDeckSize")
            let limit = deckSize > 0 ? deckSize : 50
            let dueIds = try await scheduler.fetchDueItems(limit: limit)

            dueItems = try await mediaStore.fetchItems(ids: dueIds)
            isLoading = false
        } catch {
            logError("Failed to load due items: \(error.localizedDescription)")
            isLoading = false
        }
    }
}

// MARK: - Cached Async Image

/// Simple async image loader for review view
private struct CachedAsyncImage: View {
    let url: URL

    @State private var image: NSImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                ProgressView()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            isLoading = true
            image = await loadImage(from: url)
            isLoading = false
        }
    }

    /// Load image from URL on background thread
    private func loadImage(from url: URL) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let image = NSImage(contentsOf: url)
                continuation.resume(returning: image)
            }
        }
    }
}
