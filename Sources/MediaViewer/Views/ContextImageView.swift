import SwiftUI
import AppKit

// MARK: - ContextImageView

/// View for displaying context.png (source screenshot).
/// Shows at native size (up to container bounds), supports zoom.
struct ContextImageView: View {
    let url: URL

    @State private var image: NSImage?
    @State private var zoomScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = image {
                    let imageSize = image.size
                    let containerSize = geometry.size

                    // Calculate base scale: native size unless too large
                    let scaleX = min(1.0, containerSize.width / imageSize.width)
                    let scaleY = min(1.0, containerSize.height / imageSize.height)
                    let baseScale = min(scaleX, scaleY)

                    let displayWidth = imageSize.width * baseScale * zoomScale
                    let displayHeight = imageSize.height * baseScale * zoomScale

                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: displayWidth, height: displayHeight)
                            .frame(
                                minWidth: containerSize.width,
                                minHeight: containerSize.height
                            )
                    }
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                zoomScale = max(0.5, min(4.0, value))
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            zoomScale = zoomScale > 1.0 ? 1.0 : 2.0
                        }
                    }
                } else {
                    Rectangle()
                        .fill(Color(hex: 0x2a2a2a))
                }
            }
        }
        .task(id: url) {
            image = NSImage(contentsOf: url)
            zoomScale = 1.0
        }
    }
}
