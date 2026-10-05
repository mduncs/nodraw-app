import SwiftUI
import AppKit
import Combine

// MARK: - Feathered Mask Cache

/// Cache for pre-computed feathered masks to avoid recomputing on every draw
final class FeatheredMaskCache {
    static let shared = FeatheredMaskCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 20  // Keep ~20 feathered masks in memory
    }

    /// Generate cache key from mask data hash and feather radius
    private func cacheKey(dataHash: Int, featherRadius: CGFloat) -> NSString {
        "\(dataHash)_\(featherRadius)" as NSString
    }

    /// Get or compute feathered mask
    func featheredImage(for maskData: Data, featherRadius: CGFloat) -> NSImage? {
        let key = cacheKey(dataHash: maskData.hashValue, featherRadius: featherRadius)

        // Check cache first
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // Compute feathered mask
        guard let nsImage = NSImage(data: maskData),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let featheredCG = VisionProcessor.featherMask(cgImage, radius: featherRadius) else {
            return nil
        }

        let featheredNS = NSImage(cgImage: featheredCG, size: NSSize(width: featheredCG.width, height: featheredCG.height))
        cache.setObject(featheredNS, forKey: key)
        return featheredNS
    }

    /// Clear cache (call when memory pressure)
    func clear() {
        cache.removeAllObjects()
    }
}

// MARK: - AnnotationOverlay

/// SwiftUI Canvas for rendering and editing annotations on images.
/// Uses normalized coordinates (0-1 range) for resolution independence.
struct AnnotationOverlay: View {
    @Environment(\.imageEditorIsCropping) private var isCropping
    @Binding var annotations: AnnotationSet
    let imageSize: CGSize       // Actual image dimensions in pixels
    let displaySize: CGSize     // Current display size in points

    /// Currently selected tool
    @Binding var selectedTool: AnnotationTool

    /// Current drawing style
    @Binding var currentStyle: ShapeStyle

    /// Current text style for text annotations
    @Binding var currentTextStyle: TextStyle

    /// Currently selected shape for editing
    @Binding var selectedShapeId: UUID?

    /// Eraser mode (add to mask or remove from mask)
    @Binding var eraserMode: EraserMode

    /// Eraser brush size in normalized units (will be converted from pixels)
    @Binding var eraserBrushSize: CGFloat

    /// Callback when annotations change
    var onAnnotationsChanged: ((AnnotationSet) -> Void)?

    /// Callback when delete is requested for selected annotation
    var onDeleteSelected: (() -> Void)?

    /// Optional session-based editor (when non-nil, mutations go through session commands)
    var editorSession: AnnotationEditorSession? = nil

    /// The parent can render a shared source-correct composite instead of drawing committed shapes here.
    var rendersCommittedShapes: Bool = true

    /// Transient transformed document during move/resize; nil once committed or cancelled.
    var onPreviewAnnotationsChanged: ((AnnotationSet?) -> Void)? = nil

    /// Callback when sniper/subject select tool clicks on image (normalized point)
    var onSubjectSelectClick: ((NormalizedPoint) -> Void)?

    /// Binding for live drag preview of extracted subjects (shapeId + offset)
    @Binding var extractedSubjectDragInfo: (shapeId: UUID, offset: NormalizedPoint)?

    // Drawing state
    @State private var drawingPoints: [NormalizedPoint] = []
    @State private var drawingStartPoint: NormalizedPoint?
    @State private var isDrawing = false
    @State private var hoveredShapeId: UUID?
    @State private var currentMousePosition: NormalizedPoint?

    // Issue #13: Sniper click visual feedback
    @State private var sniperClickPosition: NormalizedPoint?
    @State private var sniperClickOpacity: CGFloat = 0

    // Text input state
    @State private var isShowingTextInput = false
    @State private var textInputPosition: NormalizedPoint = NormalizedPoint(x: 0, y: 0)
    @State private var textInputContent = ""
    @State private var lastTextCommit: Date?
    @FocusState private var isTextFieldFocused: Bool

    // Selection gestures keep an immutable starting document and commit once at the end.
    @State private var sessionSelectionIDs: Set<UUID> = []
    @State private var selectionGestureStart: NormalizedPoint?
    @State private var selectionOriginalShapes: [AnnotationShape] = []
    @State private var selectionOriginalBounds: NormalizedRect?
    @State private var selectionPreview: AnnotationSet?
    @State private var marqueeRect: NormalizedRect?
    @State private var marqueeSeed: Set<UUID> = []
    @State private var selectionGestureMovesObjects = false

    // NOTE: Mask annotations are rendered in FullImageView (not here) because
    // .blendMode(.destinationOut) must be a direct sibling of the base Image
    // within the same .compositingGroup() to composite correctly.
    // Nesting masks inside AnnotationOverlay's GeometryReader/ZStack prevents
    // the blend mode from affecting the parent compositing context.

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Main canvas for rendering non-mask shapes
                Canvas { context, size in
                    drawAnnotations(context: context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(drawingGesture)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        currentMousePosition = NormalizedPoint.normalized(from: location, in: displaySize)
                    case .ended:
                        currentMousePosition = nil
                    }
                }

                if isCropping {
                    SelectionHandles(
                        rect: cropPreviewRect,
                        displaySize: displaySize,
                        onBegin: {},
                        onResize: previewCrop,
                        onEnd: finishCrop
                    )
                } else if selectedTool == .select, let rect = selectionBounds {
                    SelectionHandles(
                        rect: rect,
                        displaySize: displaySize,
                        onBegin: beginResize,
                        onResize: previewResize,
                        onEnd: { finishSelectionTransform(description: "Resize Selection") }
                    )
                }

                if let marquee = marqueeRect {
                    let rect = marquee.scaled(to: displaySize)
                    Rectangle().fill(Color.accentOrange.opacity(0.08))
                        .overlay(Rectangle().stroke(Color.accentOrange.opacity(0.8), lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }

                // Eraser brush cursor
                if selectedTool == .eraser, let mousePos = currentMousePosition {
                    EraserCursorView(
                        position: mousePos,
                        brushSize: eraserBrushSize,
                        mode: eraserMode,
                        displaySize: displaySize,
                        imageSize: imageSize
                    )
                }

                // Issue #13: Sniper click visual feedback
                if let clickPos = sniperClickPosition {
                    SniperClickFeedbackView(
                        position: clickPos,
                        displaySize: displaySize,
                        opacity: sniperClickOpacity
                    )
                }

                // Text input overlay
                if isShowingTextInput {
                    textInputOverlay
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)
            .coordinateSpace(name: "annotationCanvas")
            // Delete key handler
            .background(
                DeleteKeyHandler(
                    isEnabled: !selectionIDs.isEmpty,
                    onDelete: {
                        deleteSelectedAnnotation()
                    }
                )
            )
            // Tool-based cursor changes
            .onAppear { updateCursor(for: selectedTool) }
            .onDisappear { resetSelectionGesture(); NSCursor.arrow.set() }
            .onChange(of: selectedTool) { _, _ in
                resetSelectionGesture()
                isDrawing = false
                drawingStartPoint = nil
                drawingPoints = []
                if selectedTool != .text && isShowingTextInput {
                    commitTextAnnotation()
                }
                updateCursor(for: selectedTool)
            }
            .onChange(of: isCropping) { _, _ in resetSelectionGesture() }
            .onReceive(editorSession?.$selectedShapeIds.eraseToAnyPublisher() ?? Just(Set<UUID>()).eraseToAnyPublisher()) { ids in
                guard editorSession != nil else { return }
                sessionSelectionIDs = ids
                if selectedShapeId.map({ !ids.contains($0) }) ?? true {
                    selectedShapeId = ids.sorted { $0.uuidString < $1.uuidString }.first
                }
            }
        }
    }

    // MARK: - Cursor Management

    /// Updates the cursor based on the currently selected annotation tool
    private func updateCursor(for tool: AnnotationTool) {
        switch tool {
        case .select:
            NSCursor.arrow.set()
        case .rectangle, .ellipse, .arrow, .freeform, .highlighter:
            NSCursor.crosshair.set()
        case .text:
            NSCursor.iBeam.set()
        case .eraser:
            // Eraser uses custom cursor view, but set crosshair as fallback
            NSCursor.crosshair.set()
        case .subjectSelect:
            // Sniper tool - use crosshair to indicate targeting
            NSCursor.crosshair.set()
        case .backgroundRemove, .personSegment, .mirrorH, .mirrorV:
            // Action tools - don't change cursor (they're one-click actions)
            NSCursor.arrow.set()
        }
    }

    // MARK: - Delete Selected

    private func deleteSelectedAnnotation() {
        if let session = editorSession {
            if session.selectedShapeIds.isEmpty, let id = selectedShapeId { session.select(id) }
            session.deleteSelected()
            annotations = session.annotationSet
        } else if let id = selectedShapeId {
            var updated = annotations
            updated.removeShape(id: id)
            annotations = updated
            onAnnotationsChanged?(updated)
        }
        selectedShapeId = nil
    }

    // MARK: - Drawing

    private func drawAnnotations(context: GraphicsContext, size: CGSize) {
        // Draw layers bottom-to-top (index 0 is bottom)
        for layer in rendersCommittedShapes ? (selectionPreview ?? annotations).layers : [] {
            // Skip hidden layers
            guard layer.isVisible else { continue }

            // Create layer context with opacity and blend mode
            var layerContext = context
            layerContext.opacity = layer.opacity

            // Apply layer blend mode
            let blendMode = layerBlendModeToGraphics(layer.blendMode)
            layerContext.blendMode = blendMode

            // Draw all shapes in this layer
            for shape in layer.shapes {
                let isSelected = shape.id == selectedShapeId
                let isHovered = shape.id == hoveredShapeId
                drawShape(context: layerContext, shape: shape, size: size, selected: isSelected, hovered: isHovered)
            }
        }

        // Draw current drawing in progress (always on top, in active layer context)
        if isDrawing {
            drawCurrentDrawing(context: context, size: size)
        }

        // Draw crop region if present
        if isCropping {
            drawCropRegion(context: context, crop: cropPreviewRect, size: size)
        } else if let crop = annotations.cropRegion {
            drawCropRegion(context: context, crop: crop, size: size)
        }
    }

    /// Convert LayerBlendMode to GraphicsContext.BlendMode
    private func layerBlendModeToGraphics(_ mode: LayerBlendMode) -> GraphicsContext.BlendMode {
        switch mode {
        case .normal: return .normal
        case .multiply: return .multiply
        case .screen: return .screen
        case .overlay: return .overlay
        case .darken: return .darken
        case .lighten: return .lighten
        }
    }

    private func drawShape(
        context: GraphicsContext,
        shape: AnnotationShape,
        size: CGSize,
        selected: Bool,
        hovered: Bool
    ) {
        switch shape {
        case .rectangle(_, let rect, let style):
            let path = Path(rect.scaled(to: size))
            drawStyledPath(context: context, path: path, style: style, selected: selected, hovered: hovered,
                           cap: .butt, join: .miter)

        case .ellipse(_, let rect, let style):
            let cgRect = rect.scaled(to: size)
            let path = Path(ellipseIn: cgRect)
            drawStyledPath(context: context, path: path, style: style, selected: selected, hovered: hovered)

        case .arrow(_, let from, let to, let style):
            let start = from.scaled(to: size)
            let end = to.scaled(to: size)
            let path = arrowPath(from: start, to: end, headLength: style.strokeWidth * 3 * pointsPerPixel)
            drawStyledPath(context: context, path: path, style: style, selected: selected, hovered: hovered, filled: false,
                           join: .miter)

        case .freeform(_, let points, let style):
            guard points.count >= 2 else { return }
            var path = Path()
            path.move(to: points[0].scaled(to: size))
            for point in points.dropFirst() {
                path.addLine(to: point.scaled(to: size))
            }
            drawStyledPath(context: context, path: path, style: style, selected: selected, hovered: hovered, filled: false)

        case .text(_, let position, let content, let style):
            let point = position.scaled(to: size)
            drawText(context: context, content: content, at: point, style: style, selected: selected)

        case .mask:
            // Masks are rendered as SwiftUI Image views outside Canvas for proper blend compositing
            return

        case .extractedSubject:
            // Extracted subjects are rendered as SwiftUI Image views outside Canvas
            // See FullImageView for extracted subject rendering
            return
        }
    }

    /// Stroke widths are stored in source pixels, exactly as AnnotationRenderer draws them.
    /// Previews scale them to the display so what is dragged is what the composite commits.
    private var pointsPerPixel: CGFloat {
        displaySize.width / max(1, imageSize.width)
    }

    private func drawStyledPath(
        context: GraphicsContext,
        path: Path,
        style: ShapeStyle,
        selected: Bool,
        hovered: Bool,
        filled: Bool = true,
        cap: CGLineCap = .round,
        join: CGLineJoin = .round
    ) {
        let lineWidth = max(0.75, style.strokeWidth * pointsPerPixel)
        let strokeColor = Color(
            red: style.strokeRed,
            green: style.strokeGreen,
            blue: style.strokeBlue,
            opacity: style.strokeAlpha
        )

        // Fill if provided
        if filled, let fillColor = style.fillColor {
            let fill = Color(
                red: CGFloat((fillColor >> 24) & 0xFF) / 255.0,
                green: CGFloat((fillColor >> 16) & 0xFF) / 255.0,
                blue: CGFloat((fillColor >> 8) & 0xFF) / 255.0,
                opacity: CGFloat(fillColor & 0xFF) / 255.0
            )
            context.fill(path, with: .color(fill))
        }

        // Selection/hover highlight
        if selected {
            context.stroke(
                path,
                with: .color(.white),
                style: StrokeStyle(lineWidth: lineWidth + 4, lineCap: cap, lineJoin: join)
            )
        } else if hovered {
            context.stroke(
                path,
                with: .color(.white.opacity(0.5)),
                style: StrokeStyle(lineWidth: lineWidth + 2, lineCap: cap, lineJoin: join)
            )
        }

        // Main stroke
        context.stroke(
            path,
            with: .color(strokeColor),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: cap, lineJoin: join)
        )
    }

    private func drawText(
        context: GraphicsContext,
        content: String,
        at point: CGPoint,
        style: TextStyle,
        selected: Bool
    ) {
        let textColor = Color(
            red: style.textRed,
            green: style.textGreen,
            blue: style.textBlue,
            opacity: style.textAlpha
        )

        // Selection indicator
        if selected {
            let handleSize: CGFloat = 8
            let handleRect = CGRect(x: point.x - handleSize/2, y: point.y - handleSize/2, width: handleSize, height: handleSize)
            context.fill(Path(ellipseIn: handleRect), with: .color(.white))
            context.stroke(Path(ellipseIn: handleRect), with: .color(.accentOrange), lineWidth: 2)
        }

        let scale = pointsPerPixel
        let layout = AnnotationRenderer.textLayout(content: content, style: style)

        // Draw background if specified
        if let bgColor = style.backgroundColor {
            let bg = Color(
                red: CGFloat((bgColor >> 24) & 0xFF) / 255.0,
                green: CGFloat((bgColor >> 16) & 0xFF) / 255.0,
                blue: CGFloat((bgColor >> 8) & 0xFF) / 255.0,
                opacity: CGFloat(bgColor & 0xFF) / 255.0
            )
            let padding = AnnotationRenderer.textBackgroundPadding(for: style) * scale
            let bgRect = CGRect(x: point.x - padding, y: point.y - padding,
                                width: layout.size.width * scale + padding * 2, height: layout.size.height * scale + padding * 2)
            context.fill(Path(roundedRect: bgRect, cornerRadius: min(padding, bgRect.height / 2)), with: .color(bg))
        }

        // Create resolved text for Canvas drawing
        var displayStyle = style
        displayStyle.fontSize = max(1, style.fontSize * scale)
        let text = Text(content)
            .font(Font(AnnotationRenderer.textFont(for: displayStyle)))
            .foregroundColor(textColor)

        let resolvedText = context.resolve(text)
        context.draw(resolvedText, at: point, anchor: .topLeading)
    }

    private func drawCurrentDrawing(context: GraphicsContext, size: CGSize) {
        guard let start = drawingStartPoint else { return }

        let style = currentStyle

        switch selectedTool {
        case .rectangle:
            if let end = drawingPoints.last {
                let rect = NormalizedRect(from: start, to: end)
                let path = Path(rect.scaled(to: size))
                drawStyledPath(context: context, path: path, style: style, selected: false, hovered: false,
                               cap: .butt, join: .miter)
            }

        case .ellipse:
            if let end = drawingPoints.last {
                let rect = NormalizedRect(from: start, to: end)
                let cgRect = rect.scaled(to: size)
                let path = Path(ellipseIn: cgRect)
                drawStyledPath(context: context, path: path, style: style, selected: false, hovered: false)
            }

        case .arrow:
            if let end = drawingPoints.last {
                let startPt = start.scaled(to: size)
                let endPt = end.scaled(to: size)
                let path = arrowPath(from: startPt, to: endPt, headLength: style.strokeWidth * 3 * pointsPerPixel)
                drawStyledPath(context: context, path: path, style: style, selected: false, hovered: false, filled: false,
                               join: .miter)
            }

        case .freeform, .highlighter:
            guard drawingPoints.count >= 2 else { return }
            var path = Path()
            path.move(to: drawingPoints[0].scaled(to: size))
            for point in drawingPoints.dropFirst() {
                path.addLine(to: point.scaled(to: size))
            }
            let drawStyle = style
            drawStyledPath(context: context, path: path, style: drawStyle, selected: false, hovered: false, filled: false)

        case .eraser:
            // Draw eraser stroke preview - show as semi-transparent circles along the path
            guard !drawingPoints.isEmpty else { return }
            let brushRadius = eraserBrushSize / 2.0
            // Convert brush size from pixels to display points
            let displayBrushRadius = brushRadius * (size.width / imageSize.width)
            let previewColor: Color = eraserMode == .addToMask ?
                Color.green.opacity(0.3) : Color.red.opacity(0.3)

            for point in drawingPoints {
                let center = point.scaled(to: size)
                let brushRect = CGRect(
                    x: center.x - displayBrushRadius,
                    y: center.y - displayBrushRadius,
                    width: displayBrushRadius * 2,
                    height: displayBrushRadius * 2
                )
                context.fill(Path(ellipseIn: brushRect), with: .color(previewColor))
            }

        default:
            break
        }
    }

    private func drawCropRegion(context: GraphicsContext, crop: NormalizedRect, size: CGSize) {
        let cgRect = crop.scaled(to: size)

        // Dim area outside crop
        let fullRect = CGRect(origin: .zero, size: size)
        var dimPath = Path(fullRect)
        dimPath.addRect(cgRect)
        context.fill(dimPath, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))

        // Crop border
        context.stroke(
            Path(cgRect),
            with: .color(.white),
            style: StrokeStyle(lineWidth: 2, dash: [5, 5])
        )

        // Rule of thirds grid
        let thirdW = cgRect.width / 3
        let thirdH = cgRect.height / 3
        var gridPath = Path()
        for i in 1...2 {
            let x = cgRect.minX + thirdW * CGFloat(i)
            gridPath.move(to: CGPoint(x: x, y: cgRect.minY))
            gridPath.addLine(to: CGPoint(x: x, y: cgRect.maxY))

            let y = cgRect.minY + thirdH * CGFloat(i)
            gridPath.move(to: CGPoint(x: cgRect.minX, y: y))
            gridPath.addLine(to: CGPoint(x: cgRect.maxX, y: y))
        }
        context.stroke(gridPath, with: .color(.white.opacity(0.4)), lineWidth: 1)
    }

    // MARK: - Gesture Handling

    private var drawingGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleDragChanged(value)
            }
            .onEnded { value in
                handleDragEnded(value)
            }
    }

    /// Ensure drawing starts immediately with initial point captured
    private func initializeDrawing(at point: NormalizedPoint) {
        isDrawing = true
        drawingStartPoint = point
        drawingPoints = [point]
    }

    private func handleDragChanged(_ value: DragGesture.Value) {
        let normalized = NormalizedPoint.normalized(from: value.location, in: displaySize)

        if isCropping {
            guard abs(value.translation.width) + abs(value.translation.height) > 3 else { return }
            let start = NormalizedPoint.normalized(from: value.startLocation, in: displaySize)
            previewCrop(NormalizedRect(from: start, to: normalized))
            return
        }

        if selectedTool == .select {
            handleSelectionChanged(value)
            return
        }

        if selectedTool == .text {
            // Text tool - just track position
            return
        }

        if selectedTool == .subjectSelect {
            // Sniper tool - just wait for click, don't draw
            return
        }

        // Start drawing (capture initial point immediately for freeform)
        if !isDrawing {
            initializeDrawing(at: normalized)
        } else {
            // Continue drawing - add point if different from last
            if let lastPoint = drawingPoints.last, lastPoint.distance(to: normalized) > 0.001 {
                drawingPoints.append(normalized)
            } else if drawingPoints.isEmpty {
                // Safety: ensure at least one point exists
                drawingPoints.append(normalized)
            }
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        let normalized = NormalizedPoint.normalized(from: value.location, in: displaySize)

        if isCropping {
            finishCrop()
            return
        }

        if selectedTool == .select {
            if selectionGestureMovesObjects {
                finishSelectionTransform(description: "Move Selection")
            } else {
                resetSelectionGesture()
            }
            return
        }

        if selectedTool == .text {
            // Clicking away commits typed text, as in the reference; the next click places new text.
            // AppKit may already have committed on focus loss during this same click.
            if isShowingTextInput {
                commitTextAnnotation()
                return
            }
            if let lastTextCommit, Date().timeIntervalSince(lastTextCommit) < 0.35 { return }
            textInputPosition = normalized
            textInputContent = ""
            isShowingTextInput = true
            return
        }

        if selectedTool == .subjectSelect {
            // Sniper tool - click to select subject at this point
            // Issue #13: Show visual feedback at click position
            showSniperClickFeedback(at: normalized)
            logDebug("[SNIPER] Click detected at \(normalized.x), \(normalized.y)")
            onSubjectSelectClick?(normalized)
            return
        }

        // Finalize shape
        guard isDrawing, let start = drawingStartPoint else { return }

        var newShape: AnnotationShape?

        switch selectedTool {
        case .rectangle:
            if let end = drawingPoints.last, start.distance(to: end) > 0.01 {
                let rect = NormalizedRect(from: start, to: end)
                newShape = .rectangle(id: UUID(), rect: rect, style: currentStyle)
            }

        case .ellipse:
            if let end = drawingPoints.last, start.distance(to: end) > 0.01 {
                let rect = NormalizedRect(from: start, to: end)
                newShape = .ellipse(id: UUID(), rect: rect, style: currentStyle)
            }

        case .arrow:
            if let end = drawingPoints.last, start.distance(to: end) > 0.01 {
                newShape = .arrow(id: UUID(), from: start, to: end, style: currentStyle)
            }

        case .freeform:
            // For freeform, ensure at least start and end points exist
            // If quick click-release, add end point to have minimum 2 points
            var finalPoints = drawingPoints
            if finalPoints.count == 1 {
                finalPoints.append(normalized)
            }
            if finalPoints.count >= 2 {
                newShape = .freeform(id: UUID(), points: finalPoints, style: currentStyle)
            }

        case .highlighter:
            // Same handling for highlighter
            var finalHighlightPoints = drawingPoints
            if finalHighlightPoints.count == 1 {
                finalHighlightPoints.append(normalized)
            }
            if finalHighlightPoints.count >= 2 {
                newShape = .freeform(id: UUID(), points: finalHighlightPoints, style: currentStyle)
            }

        case .eraser:
            // Create a mask from the eraser brush strokes
            if !drawingPoints.isEmpty {
                if let maskData = createEraserMaskData(points: drawingPoints, brushSize: eraserBrushSize) {
                    newShape = .mask(
                        id: UUID(),
                        maskData: maskData,
                        bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                        blendMode: eraserMode.blendMode,
                        opacity: 1.0,
                        featherRadius: 0.0  // Eraser strokes default to sharp edges
                    )
                }
            }

        default:
            break
        }

        // Add shape if created
        if let shape = newShape {
            if let session = editorSession {
                session.execute(.addShape(shape: shape, layerId: nil), description: "Draw \(selectedTool)")
                annotations = session.annotationSet
            } else {
                var updatedAnnotations = annotations
                updatedAnnotations.addShape(shape)
                annotations = updatedAnnotations
                onAnnotationsChanged?(updatedAnnotations)
            }
        }

        // Reset drawing state
        isDrawing = false
        drawingStartPoint = nil
        drawingPoints = []
    }

    // MARK: - Crop

    private var cropPreviewRect: NormalizedRect {
        selectionPreview?.cropRegion ?? annotations.cropRegion ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func previewCrop(_ rect: NormalizedRect) {
        let x = max(0, min(0.995, rect.x)), y = max(0, min(0.995, rect.y))
        let crop = NormalizedRect(x: x, y: y, width: max(0.005, min(1 - x, rect.width)), height: max(0.005, min(1 - y, rect.height)))
        var preview = annotations
        preview.cropRegion = crop
        selectionPreview = preview
        onPreviewAnnotationsChanged?(preview)
    }

    private func finishCrop() {
        if let crop = selectionPreview?.cropRegion {
            if let session = editorSession {
                session.execute(.setCropRegion(crop), description: "Crop Image")
                annotations = session.annotationSet
            } else {
                var updated = annotations
                _ = updated.apply(.setCropRegion(crop))
                annotations = updated
                onAnnotationsChanged?(updated)
            }
        }
        resetSelectionGesture()
    }

    // MARK: - General Selection, Movement, and Resize

    private var selectionIDs: Set<UUID> {
        if editorSession != nil { return sessionSelectionIDs }
        return Set(selectedShapeId.map { [$0] } ?? [])
    }

    private var editableShapes: [AnnotationShape] {
        annotations.layers.filter { $0.isVisible && !$0.isLocked }.flatMap(\.shapes)
    }

    private var selectionBounds: NormalizedRect? {
        let document = selectionPreview ?? annotations
        let shapes = document.layers.filter { $0.isVisible && !$0.isLocked }.flatMap(\.shapes)
            .filter { selectionIDs.contains($0.id) }
        return EditorShapeGeometry.union(shapes.map { EditorShapeGeometry.bounds(of: $0, imageSize: imageSize) })
    }

    private func setSelection(_ ids: Set<UUID>, primary: UUID? = nil) {
        editorSession?.selectedShapeIds = ids
        selectedShapeId = primary.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
    }

    private func hitShape(at point: NormalizedPoint) -> AnnotationShape? {
        let toleranceX = 5 / max(1, displaySize.width)
        let toleranceY = 5 / max(1, displaySize.height)
        return editableShapes.reversed().first { shape in
            let bounds = EditorShapeGeometry.bounds(of: shape, imageSize: imageSize)
            return NormalizedRect(x: bounds.x - toleranceX, y: bounds.y - toleranceY,
                                  width: bounds.width + toleranceX * 2, height: bounds.height + toleranceY * 2).contains(point)
        }
    }

    private func handleSelectionChanged(_ value: DragGesture.Value) {
        let start = NormalizedPoint.normalized(from: value.startLocation, in: displaySize)
        let current = NormalizedPoint.normalized(from: value.location, in: displaySize)
        if selectionGestureStart == nil {
            selectionGestureStart = start
            let extend = NSEvent.modifierFlags.contains(.shift)
            marqueeSeed = extend ? selectionIDs : []
            if let shape = hitShape(at: start) {
                if extend {
                    var ids = selectionIDs
                    if ids.contains(shape.id) { ids.remove(shape.id) } else { ids.insert(shape.id) }
                    setSelection(ids, primary: shape.id)
                } else if !selectionIDs.contains(shape.id) {
                    setSelection([shape.id], primary: shape.id)
                }
                selectionOriginalShapes = editableShapes.filter { selectionIDs.contains($0.id) }
                selectionOriginalBounds = selectionBounds
                selectionGestureMovesObjects = selectionIDs.contains(shape.id)
            } else {
                setSelection(marqueeSeed)
                selectionGestureMovesObjects = false
            }
        }
        let moved = abs(value.translation.width) + abs(value.translation.height) > 3
        guard moved else { return }
        if selectionGestureMovesObjects {
            let delta = NormalizedPoint(x: current.x - start.x, y: current.y - start.y)
            previewShapes(selectionOriginalShapes.map { EditorShapeGeometry.moved($0, by: delta) })
            // Legacy parent renderers still use this lightweight extracted-subject preview.
            if onPreviewAnnotationsChanged == nil, let shape = selectionOriginalShapes.first, shape.isExtractedSubject {
                extractedSubjectDragInfo = (shape.id, delta)
            }
        } else {
            let rect = NormalizedRect(from: start, to: current)
            marqueeRect = rect
            let ids = editableShapes.filter {
                let shape = EditorShapeGeometry.bounds(of: $0, imageSize: imageSize)
                return shape.x < rect.x + rect.width && shape.x + shape.width > rect.x &&
                    shape.y < rect.y + rect.height && shape.y + shape.height > rect.y
            }.map(\.id)
            setSelection(marqueeSeed.union(ids))
        }
    }

    private func beginResize() {
        selectionOriginalShapes = editableShapes.filter { selectionIDs.contains($0.id) }
        selectionOriginalBounds = selectionBounds
    }

    private func previewResize(_ rect: NormalizedRect) {
        guard let original = selectionOriginalBounds else { return }
        previewShapes(selectionOriginalShapes.map { EditorShapeGeometry.resized($0, from: original, to: rect) })
    }

    private func previewShapes(_ shapes: [AnnotationShape]) {
        var preview = annotations
        for shape in shapes { preview.replaceShape(id: shape.id, with: shape) }
        selectionPreview = preview
        onPreviewAnnotationsChanged?(preview)
    }

    private func finishSelectionTransform(description: String) {
        if let preview = selectionPreview {
            // A concurrent edit must not be overwritten by a gesture that began on older data.
            let commands = selectionOriginalShapes.compactMap { original -> AnnotationCommand? in
                guard annotations.shape(id: original.id) == original,
                      editableShapes.contains(where: { $0.id == original.id }),
                      let updated = preview.shape(id: original.id), updated != original else { return nil }
                return .replaceShape(shapeId: original.id, newShape: updated)
            }
            if let session = editorSession {
                session.executeGroup(commands, description: description)
                annotations = session.annotationSet
            } else if !commands.isEmpty {
                var updated = annotations
                _ = updated.apply(.group(commands))
                annotations = updated
                onAnnotationsChanged?(updated)
            }
        }
        resetSelectionGesture()
    }

    private func resetSelectionGesture() {
        selectionGestureStart = nil
        selectionOriginalShapes = []
        selectionOriginalBounds = nil
        selectionPreview = nil
        marqueeRect = nil
        marqueeSeed = []
        selectionGestureMovesObjects = false
        extractedSubjectDragInfo = nil
        onPreviewAnnotationsChanged?(nil)
    }

    // MARK: - Text Input Overlay

    /// Entry text previews the committed size (bounded so it stays usable) and color.
    private var textInputFontSize: CGFloat {
        min(96, max(11, currentTextStyle.fontSize * pointsPerPixel))
    }

    private var textInputSize: CGSize {
        let font = AnnotationRenderer.textFont(for: {
            var style = currentTextStyle
            style.fontSize = textInputFontSize
            return style
        }())
        let measured = ((textInputContent.isEmpty ? "Type text" : textInputContent) as NSString).size(withAttributes: [.font: font])
        return CGSize(width: min(max(140, measured.width + 28), max(140, displaySize.width - 20)),
                      height: ceil(measured.height) + 10)
    }

    // Issue #16: keep the entry visible. Its top-left sits on the click, where the text will land.
    private var clampedTextInputPosition: CGPoint {
        let origin = textInputPosition.scaled(to: displaySize)
        let size = textInputSize
        let padding: CGFloat = 10
        let x = min(max(origin.x, padding), max(padding, displaySize.width - padding - size.width))
        let y = min(max(origin.y, padding), max(padding, displaySize.height - padding - size.height))
        return CGPoint(x: x + size.width / 2, y: y + size.height / 2)
    }

    private var textInputOverlay: some View {
        let size = textInputSize
        let entryStyle: TextStyle = {
            var style = currentTextStyle
            style.fontSize = textInputFontSize
            return style
        }()
        return TextField("Type text", text: $textInputContent, onCommit: commitTextAnnotation)
            .textFieldStyle(.plain)
            .font(Font(AnnotationRenderer.textFont(for: entryStyle)))
            .foregroundStyle(Color(red: currentTextStyle.textRed, green: currentTextStyle.textGreen,
                                   blue: currentTextStyle.textBlue))
            .padding(.horizontal, 6)
            .frame(width: size.width, height: size.height, alignment: .leading)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentOrange, lineWidth: 1))
            .focused($isTextFieldFocused)
            .onExitCommand {
                isShowingTextInput = false
                textInputContent = ""
            }
            .help("Return or click away to place · Esc cancels")
            .position(clampedTextInputPosition)
            .onAppear {
                // Focus the text field after a brief delay to ensure view is rendered
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTextFieldFocused = true
                }
            }
    }

    private func commitTextAnnotation() {
        guard !textInputContent.isEmpty else {
            isShowingTextInput = false
            return
        }
        lastTextCommit = Date()

        let textShape = AnnotationShape.text(
            id: UUID(),
            position: textInputPosition,
            content: textInputContent,
            style: currentTextStyle
        )

        if let session = editorSession {
            session.execute(.addShape(shape: textShape, layerId: nil), description: "Add Text")
            annotations = session.annotationSet
        } else {
            var updatedAnnotations = annotations
            updatedAnnotations.addShape(textShape)
            annotations = updatedAnnotations
            onAnnotationsChanged?(updatedAnnotations)
        }

        isShowingTextInput = false
        textInputContent = ""
    }

    // MARK: - Sniper Feedback

    // Issue #13: Show pulse animation at click position
    private func showSniperClickFeedback(at position: NormalizedPoint) {
        sniperClickPosition = position
        sniperClickOpacity = 1.0

        // Animate fade out
        withAnimation(.easeOut(duration: 0.5)) {
            sniperClickOpacity = 0
        }

        // Clear position after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            sniperClickPosition = nil
        }
    }

    // MARK: - Helpers

    private func arrowPath(from start: CGPoint, to end: CGPoint, headLength: CGFloat) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        // Calculate arrow head
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headAngle: CGFloat = .pi / 6  // 30 degrees

        let head1 = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let head2 = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )

        path.move(to: end)
        path.addLine(to: head1)
        path.move(to: end)
        path.addLine(to: head2)

        return path
    }

    private func fontWeight(from weight: TextStyle.FontWeight) -> Font.Weight {
        switch weight {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    // MARK: - Eraser Mask Creation

    /// Bounded grayscale stroke mask; the renderer scales its full-canvas bounds to the source.
    private func createEraserMaskData(points: [NormalizedPoint], brushSize: CGFloat) -> Data? {
        MaskBrushRasterizer.pngData(points: points, sourceSize: imageSize, brushSize: brushSize)
    }

}

// MARK: - EraserCursorView

/// Visual cursor for the eraser brush tool
private struct EraserCursorView: View {
    let position: NormalizedPoint
    let brushSize: CGFloat
    let mode: EraserMode
    let displaySize: CGSize
    let imageSize: CGSize

    var body: some View {
        let center = position.scaled(to: displaySize)
        // Convert brush size from image pixels to display points
        let displayBrushSize = brushSize * (displaySize.width / imageSize.width)

        Circle()
            .stroke(mode == .addToMask ? Color.green : Color.red, lineWidth: 2)
            .frame(width: displayBrushSize, height: displayBrushSize)
            .position(center)
            .allowsHitTesting(false)
    }
}

// MARK: - SniperClickFeedbackView

/// Issue #13: Visual feedback pulse when sniper tool clicks
private struct SniperClickFeedbackView: View {
    let position: NormalizedPoint
    let displaySize: CGSize
    let opacity: CGFloat

    var body: some View {
        let center = position.scaled(to: displaySize)

        ZStack {
            // Outer expanding ring
            Circle()
                .stroke(Color.accentOrange, lineWidth: 2)
                .frame(width: 40 * (2 - opacity), height: 40 * (2 - opacity))
                .opacity(opacity * 0.5)

            // Inner solid circle
            Circle()
                .fill(Color.accentOrange)
                .frame(width: 12, height: 12)
                .opacity(opacity)

            // Crosshair
            Path { path in
                path.move(to: CGPoint(x: -20, y: 0))
                path.addLine(to: CGPoint(x: -8, y: 0))
                path.move(to: CGPoint(x: 8, y: 0))
                path.addLine(to: CGPoint(x: 20, y: 0))
                path.move(to: CGPoint(x: 0, y: -20))
                path.addLine(to: CGPoint(x: 0, y: -8))
                path.move(to: CGPoint(x: 0, y: 8))
                path.addLine(to: CGPoint(x: 0, y: 20))
            }
            .stroke(Color.accentOrange, lineWidth: 2)
            .opacity(opacity)
        }
        .position(center)
        .allowsHitTesting(false)
    }
}

// MARK: - DeleteKeyHandler

/// NSViewRepresentable to handle Delete/Backspace key for removing selected annotations.
private struct DeleteKeyHandler: NSViewRepresentable {
    let isEnabled: Bool
    let onDelete: () -> Void

    func makeNSView(context: Context) -> DeleteKeyView {
        let view = DeleteKeyView()
        view.onDelete = onDelete
        view.isDeleteEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: DeleteKeyView, context: Context) {
        nsView.onDelete = onDelete
        nsView.isDeleteEnabled = isEnabled
    }
}

private class DeleteKeyView: NSView {
    var onDelete: (() -> Void)?
    var isDeleteEnabled: Bool = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Delete (forward delete) = keyCode 117
        // Backspace = keyCode 51
        if isDeleteEnabled && (event.keyCode == 117 || event.keyCode == 51) {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct AnnotationOverlay_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color(hex: 0x1a1a1a)

            AnnotationOverlay(
                annotations: .constant(AnnotationSet(shapes: [
                    .rectangle(
                        id: UUID(),
                        rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2),
                        style: .defaultRectangle
                    ),
                    .ellipse(
                        id: UUID(),
                        rect: NormalizedRect(x: 0.5, y: 0.3, width: 0.2, height: 0.2),
                        style: .defaultEllipse
                    ),
                    .arrow(
                        id: UUID(),
                        from: NormalizedPoint(x: 0.2, y: 0.6),
                        to: NormalizedPoint(x: 0.5, y: 0.5),
                        style: .defaultArrow
                    )
                ])),
                imageSize: CGSize(width: 800, height: 600),
                displaySize: CGSize(width: 400, height: 300),
                selectedTool: .constant(.select),
                currentStyle: .constant(.defaultRectangle),
                currentTextStyle: .constant(.default),
                selectedShapeId: .constant(nil),
                eraserMode: .constant(.removeFromMask),
                eraserBrushSize: .constant(30),
                extractedSubjectDragInfo: .constant(nil)
            )
            .frame(width: 400, height: 300)
            .background(Color.gray.opacity(0.3))
        }
        .frame(width: 500, height: 400)
    }
}
#endif
