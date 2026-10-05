import SwiftUI
import AppKit

// MARK: - CanvasItemView

/// Individual item rendered on the canvas at its placement position.
/// Uses LOD-appropriate thumbnails based on zoom level for performance.
/// Supports resize handles (Issue #2), rotation (Issue #11), and Cmd-click multi-select (Issue #3).
struct CanvasItemView: View {
    let placement: CanvasItemPlacement
    let mediaItem: MediaItem?
    let lod: CanvasLOD
    let zoomLevel: CGFloat
    let isSelected: Bool
    let onSelect: (NSEvent.ModifierFlags) -> Void  // Issue #3: Pass modifiers for Cmd-click
    let onDoubleClick: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void
    let onResizeChanged: (CGSize) -> Void  // Issue #2
    let onResizeEnded: () -> Void  // Issue #2
    let onRotationChanged: (Double) -> Void  // Issue #11
    let onRotationEnded: () -> Void  // Issue #11

    @State private var isDragging = false
    @State private var dragOffset: CGSize = .zero
    @State private var isResizing = false
    @State private var isRotating = false
    @State private var isHovered = false

    // Resize state
    @State private var resizeStartSize: CGSize = .zero
    @State private var activeCorner: ResizeCorner? = nil

    // Rotation state
    @State private var rotationStartAngle: Double = 0

    private let handleSize: CGFloat = 10
    private let rotationHandleOffset: CGFloat = 30

    var body: some View {
        ZStack {
            // Main item content
            itemContent
                .frame(
                    width: placement.width * zoomLevel,
                    height: placement.height * zoomLevel
                )
                .background(backgroundColor)
                .overlay(selectionOverlay)
                .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
                .rotationEffect(.degrees(placement.rotation))  // Issue #11
                .offset(dragOffset)
                .gesture(dragGesture)
                // IMPORTANT: Double tap MUST come before single tap in SwiftUI
                .onTapGesture(count: 2) {
                    onDoubleClick()
                }
                .onTapGesture {
                    // Issue #3: Pass current modifiers for multi-select
                    onSelect(NSEvent.modifierFlags)
                }
                .animation(.easeOut(duration: 0.1), value: isDragging)
                .onHover { hovering in
                    isHovered = hovering
                }

            // Issue #2: Resize handles (only show when selected and zoomed in enough)
            if isSelected && zoomLevel > 0.3 {
                resizeHandles
                    .rotationEffect(.degrees(placement.rotation))
            }

            // Issue #11: Rotation handle (only show when selected)
            if isSelected && zoomLevel > 0.3 {
                rotationHandle
                    .rotationEffect(.degrees(placement.rotation))
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var itemContent: some View {
        switch lod {
        case .dot:
            // Just a colored rectangle at extreme zoom-out
            dotView

        case .micro:
            // Tiny thumbnail
            thumbnailView(size: .small, cornerRadius: 2)

        case .thumb:
            // Small thumbnail
            thumbnailView(size: .small, cornerRadius: 4)

        case .preview:
            // Medium thumbnail
            thumbnailView(size: .medium, cornerRadius: 6)

        case .full:
            // Full quality
            thumbnailView(size: .medium, cornerRadius: 8)
        }
    }

    // MARK: - Dot View (extreme zoom-out)

    private var dotView: some View {
        Rectangle()
            .fill(dominantColor)
    }

    // MARK: - Thumbnail View

    @ViewBuilder
    private func thumbnailView(size: ThumbnailGenerator.Size, cornerRadius: CGFloat) -> some View {
        if let item = mediaItem {
            CachedImageView(item: item, size: size, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius * zoomLevel))
        } else {
            placeholderView(cornerRadius: cornerRadius)
        }
    }

    private func placeholderView(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius * zoomLevel)
            .fill(Color(hex: 0x2a2a2a))
            .overlay(
                Image(systemName: "photo")
                    .font(.system(size: min(24, 12 * zoomLevel)))
                    .foregroundStyle(.secondary)
            )
    }

    // MARK: - Dominant Color (for dot view)

    private var dominantColor: Color {
        if let item = mediaItem,
           let colors = item.indexedContent?.dominantColors,
           let first = colors.first {
            let rgb = first.uiColor
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        }
        return Color(hex: 0x3a3a3a)
    }

    // MARK: - Selection & Shadow

    private var backgroundColor: Color {
        Color(hex: 0x1e1e1e)
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8 * zoomLevel)
                .stroke(Color.accentColor, lineWidth: max(2, 3 * zoomLevel))
        }
    }

    private var shadowColor: Color {
        isDragging ? .black.opacity(0.4) : .black.opacity(0.2)
    }

    private var shadowRadius: CGFloat {
        isDragging ? 12 : 4
    }

    private var shadowY: CGFloat {
        isDragging ? 8 : 2
    }

    // MARK: - Drag Gesture

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    onSelect(NSEvent.modifierFlags)
                }
                dragOffset = value.translation
                onDragChanged(value.translation)
            }
            .onEnded { _ in
                isDragging = false
                dragOffset = .zero
                onDragEnded()
            }
    }

    // MARK: - Issue #2: Resize Handles

    private var resizeHandles: some View {
        let scaledWidth = placement.width * zoomLevel
        let scaledHeight = placement.height * zoomLevel

        return ZStack {
            // Corner handles
            ForEach(ResizeCorner.allCases, id: \.self) { corner in
                resizeHandle(at: corner, width: scaledWidth, height: scaledHeight)
            }
        }
    }

    @ViewBuilder
    private func resizeHandle(at corner: ResizeCorner, width: CGFloat, height: CGFloat) -> some View {
        let position = corner.position(width: width, height: height)

        Circle()
            .fill(Color.accentColor)
            .frame(width: handleSize, height: handleSize)
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 1.5)
            )
            .position(x: width / 2 + position.x, y: height / 2 + position.y)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !isResizing {
                            isResizing = true
                            resizeStartSize = placement.size
                            activeCorner = corner
                        }
                        let newSize = calculateNewSize(
                            startSize: resizeStartSize,
                            translation: value.translation,
                            corner: corner,
                            constrainAspectRatio: NSEvent.modifierFlags.contains(.shift)
                        )
                        onResizeChanged(newSize)
                    }
                    .onEnded { _ in
                        isResizing = false
                        activeCorner = nil
                        onResizeEnded()
                    }
            )
            .onHover { hovering in
                if hovering {
                    corner.cursor.set()
                } else if !isResizing {
                    NSCursor.arrow.set()
                }
            }
    }

    private func calculateNewSize(
        startSize: CGSize,
        translation: CGSize,
        corner: ResizeCorner,
        constrainAspectRatio: Bool
    ) -> CGSize {
        let scaledTranslation = CGSize(
            width: translation.width / zoomLevel,
            height: translation.height / zoomLevel
        )

        var newWidth = startSize.width
        var newHeight = startSize.height

        switch corner {
        case .topLeft:
            newWidth = startSize.width - scaledTranslation.width
            newHeight = startSize.height - scaledTranslation.height
        case .topRight:
            newWidth = startSize.width + scaledTranslation.width
            newHeight = startSize.height - scaledTranslation.height
        case .bottomLeft:
            newWidth = startSize.width - scaledTranslation.width
            newHeight = startSize.height + scaledTranslation.height
        case .bottomRight:
            newWidth = startSize.width + scaledTranslation.width
            newHeight = startSize.height + scaledTranslation.height
        }

        // Minimum size constraints
        newWidth = max(50, newWidth)
        newHeight = max(50, newHeight)

        // Constrain aspect ratio if Shift is held
        if constrainAspectRatio && startSize.width > 0 && startSize.height > 0 {
            let aspectRatio = startSize.width / startSize.height
            let newAspect = newWidth / newHeight

            if newAspect > aspectRatio {
                newWidth = newHeight * aspectRatio
            } else {
                newHeight = newWidth / aspectRatio
            }
        }

        return CGSize(width: newWidth, height: newHeight)
    }

    // MARK: - Issue #11: Rotation Handle

    private var rotationHandle: some View {
        let scaledWidth = placement.width * zoomLevel
        let scaledHeight = placement.height * zoomLevel

        return Circle()
            .fill(Color.cyan)
            .frame(width: handleSize, height: handleSize)
            .overlay(
                Circle()
                    .stroke(Color.white, lineWidth: 1.5)
            )
            .overlay(
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 6))
                    .foregroundStyle(.white)
            )
            .position(x: scaledWidth / 2, y: -rotationHandleOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !isRotating {
                            isRotating = true
                            rotationStartAngle = placement.rotation
                        }

                        // Calculate angle from center of item to drag location
                        let center = CGPoint(x: scaledWidth / 2, y: scaledHeight / 2)
                        let startPoint = CGPoint(x: scaledWidth / 2, y: -rotationHandleOffset)
                        let currentPoint = CGPoint(
                            x: startPoint.x + value.translation.width,
                            y: startPoint.y + value.translation.height
                        )

                        let startAngle = atan2(startPoint.y - center.y, startPoint.x - center.x)
                        let currentAngle = atan2(currentPoint.y - center.y, currentPoint.x - center.x)
                        let deltaAngle = (currentAngle - startAngle) * 180 / .pi

                        var newRotation = rotationStartAngle + deltaAngle

                        // Snap to 15-degree increments if Shift is held
                        if NSEvent.modifierFlags.contains(.shift) {
                            newRotation = round(newRotation / 15) * 15
                        }

                        onRotationChanged(newRotation)
                    }
                    .onEnded { _ in
                        isRotating = false
                        onRotationEnded()
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.crosshair.set()
                } else if !isRotating {
                    NSCursor.arrow.set()
                }
            }
    }
}

// MARK: - ResizeCorner

private enum ResizeCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func position(width: CGFloat, height: CGFloat) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: -width / 2, y: -height / 2)
        case .topRight: return CGPoint(x: width / 2, y: -height / 2)
        case .bottomLeft: return CGPoint(x: -width / 2, y: height / 2)
        case .bottomRight: return CGPoint(x: width / 2, y: height / 2)
        }
    }

    var cursor: NSCursor {
        switch self {
        case .topLeft, .bottomRight:
            return NSCursor(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)!, hotSpot: NSPoint(x: 8, y: 8))
        case .topRight, .bottomLeft:
            return NSCursor(image: NSImage(systemSymbolName: "arrow.up.right.and.arrow.down.left", accessibilityDescription: nil)!, hotSpot: NSPoint(x: 8, y: 8))
        }
    }
}

// MARK: - CanvasItemView Preview

#if DEBUG
struct CanvasItemView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // Different LOD levels
            ForEach(CanvasLOD.allCases, id: \.rawValue) { lod in
                HStack {
                    Text(String(describing: lod))
                        .frame(width: 80)

                    CanvasItemView(
                        placement: CanvasItemPlacement(
                            canvasId: UUID(),
                            mediaItemId: UUID(),
                            width: 200,
                            height: 150
                        ),
                        mediaItem: nil,
                        lod: lod,
                        zoomLevel: 1.0,
                        isSelected: false,
                        onSelect: { _ in },
                        onDoubleClick: {},
                        onDragChanged: { _ in },
                        onDragEnded: {},
                        onResizeChanged: { _ in },
                        onResizeEnded: {},
                        onRotationChanged: { _ in },
                        onRotationEnded: {}
                    )
                }
            }
        }
        .padding()
        .background(Color(hex: 0x1a1a1a))
    }
}
#endif
