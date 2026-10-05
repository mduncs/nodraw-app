import SwiftUI
import AppKit

// MARK: - CachedImageView

/// SwiftUI view that displays images from the ImageCache.
/// Uses `.task(id:)` for proper lifecycle management - cancels on scroll-away, restarts on scroll-back.
///
/// Smart scaling: When contentMode is .fill, automatically switches to blur-fill
/// if filling the cell would require upscaling the image. This prevents small
/// thumbnails from appearing blurry/pixelated when stretched into larger cells.
struct CachedImageView: View {
    let item: MediaItem
    var size: ThumbnailGenerator.Size = .small
    var contentMode: ContentMode = .fill
    /// A supplied cell size avoids measuring geometry; nil retains the layout fallback.
    var displaySize: CGSize? = nil

    @Environment(\.displayScale) private var displayScale

    @State private var image: NSImage?
    @State private var blurredImage: NSImage?
    @State private var loadState: LoadState = .idle
    @State private var releaseTask: Task<Void, Never>?
    @State private var loadedSource: String?

    enum LoadState {
        case idle
        case loading
        case loaded
        case failed
    }

    var body: some View {
        Group {
            if let displaySize {
                content(cellSize: displaySize)
            } else {
                GeometryReader { geometry in
                    content(cellSize: geometry.size)
                }
            }
        }
        .onAppear { cancelScheduledRelease() }
        .onDisappear { scheduleImageRelease() }
    }

    private func content(cellSize: CGSize) -> some View {
        ZStack {
            if image == nil { placeholder }

            if let image {
                if needsBlurFill(image, cellSize: cellSize) {
                    if let blurredImage {
                        Image(nsImage: blurredImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .saturation(0.5)
                            .brightness(-0.3)
                    }
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            }
        }
        .frame(width: cellSize.width, height: cellSize.height)
        .clipped()
        .transition(.opacity.animation(.easeIn(duration: 0.05)))
        .task(id: ImageCache.thumbnailLoadIdentity(for: item, size: size,
            displaySize: cellSize, displayScale: displayScale)) {
            cancelScheduledRelease()
            await loadImage(cellSize: cellSize)
        }
    }

    /// The legacy rule compared bitmap pixels with cell points. Keep it in pixels: Retina
    /// point sizing would otherwise send every 400 px tile down the letterboxed blur path.
    private func needsBlurFill(_ image: NSImage, cellSize: CGSize) -> Bool {
        guard contentMode == .fill,
              let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        return max(cellSize.width / CGFloat(bitmap.width), cellSize.height / CGFloat(bitmap.height)) > 1
    }

    // MARK: - Placeholder

    @ViewBuilder
    private var placeholder: some View {
        switch loadState {
        case .idle, .loading:
            // Simple gray placeholder (no spinner - local files are fast per ADR-003)
            Rectangle()
                .fill(Color.gray.opacity(0.15))
                .overlay {
                    // Subtle gradient to indicate loading
                    if loadState == .loading {
                        LinearGradient(
                            colors: [Color.clear, Color.white.opacity(0.05), Color.clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                }

        case .failed:
            // Error state
            Rectangle()
                .fill(Color.gray.opacity(0.1))
                .overlay {
                    Image(systemName: "photo")
                        .foregroundColor(.gray.opacity(0.4))
                        .font(.title2)
                }

        case .loaded:
            EmptyView()
        }
    }

    // MARK: - Loading

    private func loadImage(cellSize: CGSize) async {
        // A reused cell can retain its prior @State while its display source
        // changes. Clear synchronously before awaiting the source-aware cache.
        // A new display size alone keeps the current image until the resized one lands.
        let source = ImageCache.thumbnailLoadIdentity(for: item, size: size)
        if loadedSource != source {
            image = nil
            blurredImage = nil
            loadState = .loading
        }

        // Load from cache (handles all three tiers)
        let loaded = await ImageCache.shared.loadThumbnail(for: item, size: size,
            displaySize: cellSize, displayScale: displayScale)

        // Check for cancellation
        guard !Task.isCancelled else { return }

        if let loaded = loaded {
            let blurred = needsBlurFill(loaded, cellSize: cellSize)
                ? await ImageCache.shared.loadBlurredThumbnail(for: item, source: loaded) : nil
            guard !Task.isCancelled else { return }

            // Minimal animation for instant response
            withAnimation(.easeIn(duration: 0.05)) {
                image = loaded
                blurredImage = blurred
                loadState = .loaded
            }
            loadedSource = source
            StartupMetrics.mark("first_thumbnail_ready")
        } else {
            loadState = .failed
        }
    }

    private func cancelScheduledRelease() {
        releaseTask?.cancel()
        releaseTask = nil
    }

    private func scheduleImageRelease() {
        releaseTask?.cancel()
        releaseTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            image = nil
            blurredImage = nil
            loadedSource = nil
            loadState = .idle
            releaseTask = nil
        }
    }
}

// MARK: - BlurFillImageView

/// Image view that uses .fit with blurred background fill for extreme aspect ratios.
/// Preserves full image content while filling the cell shape with a subtle blur.
struct BlurFillImageView: View {
    let item: MediaItem
    var size: ThumbnailGenerator.Size = .small
    /// A supplied cell size avoids measuring geometry; nil retains the layout fallback.
    var displaySize: CGSize? = nil

    @Environment(\.displayScale) private var displayScale

    @State private var image: NSImage?
    @State private var blurredImage: NSImage?
    @State private var loadState: CachedImageView.LoadState = .idle
    @State private var releaseTask: Task<Void, Never>?
    @State private var loadedSource: String?

    var body: some View {
        Group {
            if let displaySize {
                content(cellSize: displaySize)
            } else {
                GeometryReader { geo in
                    content(cellSize: geo.size)
                }
            }
        }
        .onAppear { cancelScheduledRelease() }
        .onDisappear { scheduleImageRelease() }
    }

    private func content(cellSize: CGSize) -> some View {
        ZStack {
            // Blurred background fill - uses pre-rendered blurred image
            if let blurredImage = blurredImage {
                Image(nsImage: blurredImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .saturation(0.5)
                    .brightness(-0.3)
            }

            // Actual image fitted - preserves full content
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }

            // Placeholder while loading
            if image == nil {
                placeholder
            }
        }
        .frame(width: cellSize.width, height: cellSize.height)
        .clipped()
        .task(id: ImageCache.thumbnailLoadIdentity(for: item, size: size,
            displaySize: cellSize, displayScale: displayScale)) {
            cancelScheduledRelease()
            await loadImage(cellSize: cellSize)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch loadState {
        case .idle, .loading:
            Rectangle()
                .fill(Color.gray.opacity(0.15))
        case .failed:
            Rectangle()
                .fill(Color.gray.opacity(0.1))
                .overlay {
                    Image(systemName: "photo")
                        .foregroundColor(.gray.opacity(0.4))
                        .font(.title2)
                }
        case .loaded:
            EmptyView()
        }
    }

    private func loadImage(cellSize: CGSize) async {
        // A new display size alone keeps the current image until the resized one lands.
        let source = ImageCache.thumbnailLoadIdentity(for: item, size: size)
        if loadedSource != source {
            image = nil
            blurredImage = nil
            loadState = .loading
        }

        let loaded = await ImageCache.shared.loadThumbnail(for: item, size: size,
            displaySize: cellSize, displayScale: displayScale)

        guard !Task.isCancelled else { return }

        if let loaded = loaded {
            let blurred = await ImageCache.shared.loadBlurredThumbnail(for: item, source: loaded)
            guard !Task.isCancelled else { return }

            withAnimation(.easeIn(duration: 0.05)) {
                image = loaded
                blurredImage = blurred
                loadState = .loaded
            }
            loadedSource = source
        } else {
            loadState = .failed
        }
    }

    private func cancelScheduledRelease() {
        releaseTask?.cancel()
        releaseTask = nil
    }

    private func scheduleImageRelease() {
        releaseTask?.cancel()
        releaseTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            image = nil
            blurredImage = nil
            loadedSource = nil
            loadState = .idle
            releaseTask = nil
        }
    }
}

// MARK: - Preview Support

#if DEBUG
extension CachedImageView {
    /// Create a preview with a mock image
    static func preview(
        color: NSColor = .systemBlue,
        size: CGSize = CGSize(width: 200, height: 200)
    ) -> some View {
        Rectangle()
            .fill(Color(nsColor: color))
            .frame(width: size.width, height: size.height)
    }
}
#endif
