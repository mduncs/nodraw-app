import SwiftUI
import AppKit

// MARK: - FullImageViewWithAnnotations

/// Full-resolution read-only image viewer: saved edits, OCR overlay, subject lifting,
/// zoom and the eyedropper. Editing happens in NativeImageEditorView.
struct FullImageViewWithAnnotations: View {
    let url: URL
    @Binding var ocrBlocks: [SerializableTextBlock]
    @Binding var hoveredOCRBlock: SerializableTextBlock?
    @Binding var selectedOCRBlock: SerializableTextBlock?
    /// Saved edits, rendered read-only. Editing happens in NativeImageEditorView.
    let annotations: AnnotationSet
    var errorMessage: String? = nil  // Error toast message for AI operation failures
    @Binding var isEyedropperActive: Bool  // Eyedropper mode for color sampling
    var onEyedropperColorPicked: ((Int, Int, Int) -> Void)?  // RGB callback when color is sampled

    @State private var sourcePixelSize: CGSize?
    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var zoomScale: CGFloat = 1.0
    @State private var showZoomControls = false
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var eyedropperHoverColor: (r: Int, g: Int, b: Int)? = nil  // Preview color under cursor

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = image {
                    let pointSize = image.size
                    let pixelSize: CGSize = {
                        if let sourcePixelSize { return sourcePixelSize }
                        if let rep = image.representations.first {
                            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                        }
                        return image.size
                    }()
                    let containerSize = geometry.size

                    let scaleX = min(1.0, containerSize.width / pointSize.width)
                    let scaleY = min(1.0, containerSize.height / pointSize.height)
                    let baseScale = min(scaleX, scaleY)

                    let displayWidth = pointSize.width * baseScale * zoomScale
                    let displayHeight = pointSize.height * baseScale * zoomScale

                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        ZStack {
                            EditorRenderedComposition(image: image,
                                annotations: annotations,
                                displaySize: CGSize(width: displayWidth, height: displayHeight),
                                coordinateSize: pixelSize)

                            if let crop = annotations.cropRegion {
                                Path { path in
                                    path.addRect(CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight))
                                    path.addRect(crop.scaled(to: CGSize(width: displayWidth, height: displayHeight)))
                                }
                                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                                .frame(width: displayWidth, height: displayHeight)
                                .allowsHitTesting(false)
                            }

                            // Apple native subject lifting (right-click or long-press to lift subjects)
                            if #available(macOS 14.0, *) {
                                SubjectLiftingOverlay(
                                    image: image,
                                    contentRect: CGRect(x: 0, y: 0, width: 1, height: 1)
                                )
                                .frame(width: displayWidth, height: displayHeight)
                            }

                            if !ocrBlocks.isEmpty {
                                OCROverlayView(
                                    blocks: $ocrBlocks,
                                    imageSize: pixelSize,
                                    displaySize: CGSize(width: displayWidth, height: displayHeight),
                                    hoveredBlock: $hoveredOCRBlock,
                                    selectedBlock: $selectedOCRBlock
                                )
                                .frame(width: displayWidth, height: displayHeight)
                            }

                            // Eyedropper overlay (when eyedropper mode is active)
                            if isEyedropperActive {
                                EyedropperOverlay(
                                    image: image,
                                    displaySize: CGSize(width: displayWidth, height: displayHeight),
                                    pixelSize: pixelSize,
                                    hoverColor: $eyedropperHoverColor,
                                    onColorPicked: { r, g, b in
                                        onEyedropperColorPicked?(r, g, b)
                                        isEyedropperActive = false
                                    }
                                )
                                .frame(width: displayWidth, height: displayHeight)
                            }
                        }
                        .frame(
                            minWidth: containerSize.width,
                            minHeight: containerSize.height
                        )
                    }
                    .transition(.opacity.animation(.easeIn(duration: 0.2)))
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

                    if hoveredOCRBlock != nil || selectedOCRBlock != nil {
                        VStack {
                            Spacer()
                            HStack {
                                OCRTextTooltip(
                                    block: selectedOCRBlock ?? hoveredOCRBlock,
                                    isSelected: selectedOCRBlock != nil
                                )
                                Spacer()
                            }
                            .padding(16)
                        }
                    }

                    // Error toast for AI operation failures
                    if let error = errorMessage {
                        VStack {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.white)
                                Text(error)
                                    .font(.callout)
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.9))
                            .cornerRadius(8)
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                            .padding(.top, 60)

                            Spacer()
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .animation(.easeInOut(duration: 0.3), value: errorMessage)
                    }

                    // Eyedropper color preview (shows sampled color under cursor)
                    if isEyedropperActive, let color = eyedropperHoverColor {
                        VStack {
                            EyedropperColorPreview(r: color.r, g: color.g, b: color.b)
                                .padding(.top, 60)
                            Spacer()
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Zoom controls overlay with eyedropper button
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            // Calculate actual size scale for 1:1 pixel zoom
                            let actualSizeScale: CGFloat = {
                                let scaleToFit = baseScale
                                let screenScale = NSScreen.main?.backingScaleFactor ?? 2.0
                                let targetDisplayWidth = pixelSize.width / screenScale
                                let currentDisplayWidth = pointSize.width * scaleToFit
                                return targetDisplayWidth / currentDisplayWidth
                            }()
                            HStack(spacing: 8) {
                                // Eyedropper button
                                EyedropperButton(
                                    isActive: $isEyedropperActive,
                                    isVisible: $showZoomControls
                                )

                                ZoomControlsOverlay(
                                    zoomScale: $zoomScale,
                                    isVisible: $showZoomControls,
                                    actualSizeScale: actualSizeScale
                                )
                            }
                            .padding(16)
                        }
                    }
                } else if isLoading {
                    // GeometryReader places children top-leading; centre the transient states.
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 4)
                        Text("Can't open this image")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: url) {
            await loadFullImage()
        }
        .onChange(of: url) { _, _ in
            zoomScale = 1.0
            // FIX: Don't nil image immediately - keep showing old until new loads
            // This prevents the flash/loading spinner between cached images
            isLoading = true
            hoveredOCRBlock = nil
            selectedOCRBlock = nil
            showZoomControls = false
        }
        .onHover { hovering in
            if hovering {
                showZoomControlsTemporarily()
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active:
                showZoomControlsTemporarily()
            case .ended:
                break
            }
        }
    }

    private func showZoomControlsTemporarily() {
        showZoomControls = true
        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            showZoomControls = false
        }
    }

    private func loadFullImage() async {
        isLoading = true
        zoomScale = 1.0
        hoveredOCRBlock = nil
        selectedOCRBlock = nil

        async let metadataSize = ImageEditorSource.dimensions(at: url)
        let loaded = await ImageCache.shared.loadFullImage(from: url)
        let dimensions = await metadataSize
        guard !Task.isCancelled else { return }
        sourcePixelSize = dimensions

        // FIX: Reduced animation for snappier navigation (was 200ms)
        withAnimation(.easeIn(duration: 0.05)) {
            image = loaded
            isLoading = false
        }
    }

}

// MARK: - EyedropperOverlay

/// Overlay that captures clicks to sample pixel color from image.
/// Shows crosshair cursor and samples color at click position.
private struct EyedropperOverlay: View {
    let image: NSImage
    let displaySize: CGSize
    let pixelSize: CGSize
    @Binding var hoverColor: (r: Int, g: Int, b: Int)?
    let onColorPicked: (Int, Int, Int) -> Void

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .cursor(.crosshair)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        // Sample color at hover position for preview
                        if let color = sampleColor(at: location) {
                            hoverColor = color
                        }
                    case .ended:
                        hoverColor = nil
                    }
                }
                .onTapGesture { location in
                    // Sample and return the clicked color
                    if let color = sampleColor(at: location) {
                        onColorPicked(color.r, color.g, color.b)
                    }
                }
        }
    }

    /// Sample the pixel color at a display coordinate
    private func sampleColor(at displayPoint: CGPoint) -> (r: Int, g: Int, b: Int)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // The displayed image may be a bounded decode of a much larger source.
        // Sample its actual raster, not the editor's full-resolution coordinate space.
        let pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        // Convert display coordinates to pixel coordinates
        let scaleX = pixelSize.width / displaySize.width
        let scaleY = pixelSize.height / displaySize.height

        let pixelX = Int(displayPoint.x * scaleX)
        let pixelY = Int(displayPoint.y * scaleY)

        // Clamp to valid pixel range
        let clampedX = max(0, min(Int(pixelSize.width) - 1, pixelX))
        let clampedY = max(0, min(Int(pixelSize.height) - 1, pixelY))

        // Create a 1x1 bitmap context to sample the pixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: 4)

        guard let context = CGContext(
            data: &pixelData,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Draw the single pixel from the source image
        context.draw(cgImage, in: CGRect(
            x: -CGFloat(clampedX),
            y: -CGFloat(Int(pixelSize.height) - clampedY - 1),  // Flip Y
            width: pixelSize.width,
            height: pixelSize.height
        ))

        // Extract RGB values
        let r = Int(pixelData[0])
        let g = Int(pixelData[1])
        let b = Int(pixelData[2])

        return (r, g, b)
    }
}

// MARK: - EyedropperButton

/// Button to toggle eyedropper mode for color sampling.
private struct EyedropperButton: View {
    @Binding var isActive: Bool
    @Binding var isVisible: Bool

    var body: some View {
        Button {
            isActive.toggle()
        } label: {
            Image(systemName: "eyedropper")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? .orange : .white.opacity(0.9))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(ZoomButtonStyle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.7))
        )
        .opacity(isVisible || isActive ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .help(isActive ? "Cancel color picker (click to sample)" : "Pick color from image")
        .accessibilityLabel("Color eyedropper")
        .accessibilityValue(isActive ? "active" : "inactive")
        .accessibilityIdentifier("eyedropper-button")
        .onHover { hovering in
            if hovering {
                isVisible = true
            }
        }
    }
}

// MARK: - EyedropperColorPreview

/// Shows a preview of the color under the eyedropper cursor.
private struct EyedropperColorPreview: View {
    let r: Int
    let g: Int
    let b: Int

    private var hexString: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }

    private var color: Color {
        Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Color swatch
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 32, height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(hexString)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Text("R:\(r) G:\(g) B:\(b)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }

            Text("Click to search")
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.85))
        )
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

// MARK: - Cursor Extension

/// Custom cursor modifier for SwiftUI views
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Mask Compositing View

/// Helpers for mask compositing. Masks must be rendered as direct ZStack children
/// alongside the base Image (not nested in child views) for .blendMode(.destinationOut)
/// to composite correctly within a .compositingGroup().
enum MaskCompositeView {
    /// Build a mask Image view ready for blend compositing.
    @ViewBuilder
    static func maskImageView(
        maskData: Data, bounds: NormalizedRect, blendMode: BlendMode,
        opacity: CGFloat, featherRadius: CGFloat, displaySize: CGSize
    ) -> some View {
        let baseMask: NSImage? = {
            if featherRadius > 0 {
                return FeatheredMaskCache.shared.featheredImage(for: maskData, featherRadius: featherRadius)
                    ?? NSImage(data: maskData)
            }
            return NSImage(data: maskData)
        }()

        // Vision masks store intensity in RGB brightness (no alpha channel).
        // .blendMode(.destinationOut) works via alpha, so we must convert.
        // maskKeep: invert brightness→alpha (background becomes opaque → removed).
        // maskRemove: direct brightness→alpha (foreground becomes opaque → removed).
        let displayMask: NSImage? = {
            guard let base = baseMask else { return nil }
            let shouldInvert = (blendMode == .maskKeep)
            return prepareMaskForCompositing(base, invert: shouldInvert)
        }()

        if let displayMask {
            let cgRect = bounds.scaled(to: displaySize)
            Image(nsImage: displayMask)
                .resizable()
                .frame(width: cgRect.width, height: cgRect.height)
                .position(x: cgRect.midX, y: cgRect.midY)
                .blendMode(.destinationOut)
                .opacity(opacity)
        }
    }

    /// Prepare a mask image for .destinationOut compositing.
    /// Handles two mask formats:
    /// - RGB brightness (Vision raw output: alphaInfo=noneSkipLast): mask in RGB, no alpha
    /// - Alpha channel (after TIFF/PNG conversion): mask data in alpha, RGB=0
    /// Detects format automatically and maps mask intensity to alpha channel.
    static func prepareMaskForCompositing(_ source: NSImage, invert: Bool) -> NSImage? {
        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        guard let readCtx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        readCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = readCtx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        // Detect mask format: sample pixels to check if mask data is in RGB or alpha.
        // If RGB brightness has variance, use RGB. If alpha has variance (and RGB ≈ 0), use alpha.
        let sampleCount = min(1000, width * height)
        let step = max(1, width * height / sampleCount)
        var rgbSum: Int = 0, alphaVariance: Int = 0
        for i in stride(from: 0, to: width * height, by: step) {
            let o = i * 4
            rgbSum += Int(pixels[o]) + Int(pixels[o + 1]) + Int(pixels[o + 2])
            if pixels[o + 3] != 255 { alphaVariance += 1 }
        }
        let useAlpha = rgbSum < sampleCount * 10 && alphaVariance > 0

        for i in 0..<(width * height) {
            let offset = i * 4
            let maskValue: UInt8
            if useAlpha {
                // Mask data is in alpha channel (TIFF/PNG converted masks)
                maskValue = pixels[offset + 3]
            } else {
                // Mask data is in RGB brightness (Vision raw output)
                let r = pixels[offset], g = pixels[offset + 1], b = pixels[offset + 2]
                maskValue = UInt8((Int(r) * 77 + Int(g) * 150 + Int(b) * 29) >> 8)
            }
            let alpha = invert ? (255 - maskValue) : maskValue
            pixels[offset] = 255       // R = white
            pixels[offset + 1] = 255   // G = white
            pixels[offset + 2] = 255   // B = white
            pixels[offset + 3] = alpha // A = compositing mask
        }

        guard let result = readCtx.makeImage() else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: width, height: height))
    }
}

// MARK: - Extracted Subject View

/// View for rendering an extracted subject with transform
struct ExtractedSubjectView: View {
    let assetKey: String
    let bounds: NormalizedRect
    let opacity: CGFloat
    let transform: ShapeTransform
    let displaySize: CGSize
    let isSelected: Bool
    var dragOffset: NormalizedPoint? = nil  // Live drag preview offset

    @State private var loadedImage: NSImage?

    var body: some View {
        ZStack {
            if let image = loadedImage {
                // Apply transform + live drag offset
                let effectiveOffset = NormalizedPoint(
                    x: transform.offset.x + (dragOffset?.x ?? 0),
                    y: transform.offset.y + (dragOffset?.y ?? 0)
                )
                let transformedBounds = NormalizedRect(
                    x: bounds.x + effectiveOffset.x,
                    y: bounds.y + effectiveOffset.y,
                    width: bounds.width * transform.scale,
                    height: bounds.height * transform.scale
                )
                let cgRect = transformedBounds.scaled(to: displaySize)

                Image(nsImage: image)
                    .resizable()
                    .frame(width: cgRect.width, height: cgRect.height)
                    .rotationEffect(.degrees(transform.rotation))
                    .position(x: cgRect.midX, y: cgRect.midY)
                    .opacity(opacity)
                    .overlay(
                        isSelected ? selectionOverlay(for: cgRect) : nil
                    )
            }
        }
        .task(id: assetKey) {
            loadedImage = await AnnotationAssetStore.shared.loadImage(assetKey)
        }
    }

    @ViewBuilder
    private func selectionOverlay(for rect: CGRect) -> some View {
        Rectangle()
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}
