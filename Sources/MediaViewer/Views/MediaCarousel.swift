import SwiftUI
import AVKit

/// Keeps the existing preview, position badge and page strip together. A sole page
/// fills the preview without a strip or its reserved height.
struct FocusPagePreview<Media: View>: View {
    let mediaFiles: [URL]
    let contextImage: URL?
    @Binding var selectedIndex: Int
    var showsPositionBadge = true
    @ViewBuilder let media: () -> Media

    private var pageCount: Int {
        SingleFocusPagePolicy.pages(mediaFiles: mediaFiles, contextImage: contextImage).count
    }

    var body: some View {
        VStack(spacing: 0) {
            media()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if pageCount > 1 && showsPositionBadge {
                        SubImagePositionBadge(index: selectedIndex + 1, total: pageCount)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
            if pageCount > 1 {
                HStack(spacing: 0) {
                    MediaCarousel(mediaFiles: mediaFiles, selectedIndex: $selectedIndex,
                        showsSelection: selectedIndex < mediaFiles.count)
                    if let contextImage {
                        Spacer(minLength: 8)
                        ContextCarouselThumbnail(url: contextImage,
                            isSelected: selectedIndex == mediaFiles.count,
                            onSelect: { selectedIndex = mediaFiles.count })
                            .accessibilityHint("Shows the source page screenshot")
                            .accessibilityAction { selectedIndex = mediaFiles.count }
                            .padding(.trailing, 8)
                    }
                }
                .frame(height: 72)
                .background(Color(hex: 0x1a1a1a))
                .accessibilityIdentifier("focus-page-strip")
            }
        }
    }
}

// MARK: - MediaCarousel

/// Horizontal carousel for items with multiple media files.
/// Displays thumbnails below the main media, supports keyboard nav (left/right arrows).
struct MediaCarousel: View {
    let mediaFiles: [URL]
    @Binding var selectedIndex: Int
    var showsSelection: Bool = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(mediaFiles.enumerated()), id: \.offset) { index, url in
                    CarouselThumbnail(
                        url: url,
                        isSelected: showsSelection && index == selectedIndex,
                        position: index + 1,
                        total: mediaFiles.count,
                        onSelect: { selectedIndex = index }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color(hex: 0x1a1a1a))
    }
}

// MARK: - CarouselThumbnail

private struct CarouselThumbnail: View {
    let url: URL
    let isSelected: Bool
    let position: Int
    let total: Int
    let onSelect: () -> Void

    @State private var image: NSImage?

    private var isVideo: Bool {
        ThumbnailGenerator.isVideo(url)
    }

    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color(hex: 0x333333))
            }

            // Video indicator
            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isSelected ? Color.accentOrange : Color.white.opacity(0.2),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help("Show downloaded image \(position) of \(total)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloaded image \(position) of \(total)")
        .accessibilityValue(isSelected ? "Displayed" : "Not displayed")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: url) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        image = nil
        let result = await ImageCache.shared.loadThumbnail(from: url, size: .small)

        // Update UI on main actor (implicit via @State)
        guard !Task.isCancelled else { return }
        image = result
    }

}

// MARK: - ContextCarouselThumbnail

/// Special thumbnail for the context screenshot, shown right-justified in the carousel strip.
struct ContextCarouselThumbnail: View {
    let url: URL
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color(hex: 0x333333))
            }

            // Screenshot indicator overlay
            VStack {
                Spacer()
                HStack {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                    Spacer()
                }
                .padding(3)
            }
        }
        .frame(width: 80, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    isSelected ? Color.accentOrange : Color.white.opacity(0.2),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help("Show context image (source page screenshot)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context image")
        .accessibilityHint("Show the source page screenshot")
        .accessibilityValue(isSelected ? "Displayed" : "Not displayed")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: url) {
            image = nil
            image = await ImageCache.shared.loadThumbnail(from: url, size: .small)
        }
    }
}

// MARK: - MediaCarouselWithKeyboard

/// Wrapper that adds keyboard navigation to MediaCarousel.
/// Keyboard navigation is handled by the parent SingleFocusView via NSViewRepresentable.
struct MediaCarouselWithKeyboard: View {
    let mediaFiles: [URL]
    @Binding var selectedIndex: Int

    var body: some View {
        MediaCarousel(mediaFiles: mediaFiles, selectedIndex: $selectedIndex)
    }
}

// MARK: - Preview

#if DEBUG
struct MediaCarousel_Previews: PreviewProvider {
    static var previews: some View {
        MediaCarousel(
            mediaFiles: [
                URL(fileURLWithPath: "/tmp/1.jpg"),
                URL(fileURLWithPath: "/tmp/2.jpg"),
                URL(fileURLWithPath: "/tmp/3.mp4"),
                URL(fileURLWithPath: "/tmp/4.jpg")
            ],
            selectedIndex: .constant(1)
        )
        .frame(height: 60)
        .background(Color(hex: 0x1a1a1a))
    }
}
#endif
