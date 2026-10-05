import SwiftUI
import AppKit

/// The editor's own canvas: the pinned source, the shared source-correct composite, the gesture
/// overlay and the native subject overlay in one zoomable, pannable viewport.
/// Pinch or ⌘/⌥-scroll zooms at the pointer, scrolling pans, and holding Space drags the view.
struct ImageEditorCanvas: View {
    let sourceURL: URL
    @ObservedObject var session: AnnotationEditorSession
    @ObservedObject var viewportModel: EditorViewportModel
    @Binding var selectedTool: AnnotationTool
    @Binding var currentStyle: ShapeStyle
    @Binding var currentTextStyle: TextStyle
    @Binding var selectedShapeID: UUID?
    @Binding var eraserMode: EraserMode
    @Binding var eraserBrushSize: CGFloat
    var subjectMasks: [SubjectMask] = []
    var selectedSubject: SubjectMask? = nil
    let assetStore: AnnotationAssetStore
    var onSubjectSelectClick: (NormalizedPoint) -> Void = { _ in }
    var onSubjectSelectionChanged: (Int?) -> Void = { _ in }
    var onLiftSubject: () -> Void = {}
    var onSourceSizeLoaded: (CGSize) -> Void = { _ in }

    @State private var image: NSImage?
    @State private var pixelSize: CGSize?
    @State private var loadFailed = false
    @State private var gesturePreview: AnnotationSet?
    @State private var extractedDragInfo: (shapeId: UUID, offset: NormalizedPoint)?
    @State private var lastPanLocation: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Clicking the empty workspace clears the object selection, as in the reference.
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { if selectedTool == .select { session.clearSelection() } }
                if let image, let pixelSize, let viewport = viewportModel.viewport {
                    document(image: image, pixelSize: pixelSize, viewport: viewport)
                    if viewportModel.isSpacePanning { panSurface }
                } else if loadFailed {
                    Label("Unable to load image", systemImage: "photo.badge.exclamationmark")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .background(EditorCanvasEventMonitor(model: viewportModel))
            .onAppear { layout(geometry.size) }
            .onChange(of: geometry.size) { _, size in layout(size) }
            .onChange(of: pixelSize) { _, _ in layout(geometry.size) }
        }
        .onDisappear { viewportModel.isSpacePanning = false }
        .task(id: sourceURL) { await load() }
    }

    private func document(image: NSImage, pixelSize: CGSize, viewport: EditorViewport) -> some View {
        let display = viewport.displaySize
        return ZStack {
            EditorRenderedComposition(image: image, annotations: gesturePreview ?? session.annotationSet,
                displaySize: display, assetStore: assetStore, coordinateSize: pixelSize,
                maximumRenderDimension: 4096)
            AnnotationOverlay(
                annotations: Binding(get: { session.annotationSet },
                                     set: { session.replaceDocument($0, description: "Edit Image") }),
                imageSize: pixelSize, displaySize: display,
                selectedTool: $selectedTool, currentStyle: $currentStyle, currentTextStyle: $currentTextStyle,
                selectedShapeId: $selectedShapeID, eraserMode: $eraserMode, eraserBrushSize: $eraserBrushSize,
                editorSession: session, rendersCommittedShapes: false,
                onPreviewAnnotationsChanged: { gesturePreview = $0 },
                onSubjectSelectClick: onSubjectSelectClick,
                extractedSubjectDragInfo: $extractedDragInfo)
            .frame(width: display.width, height: display.height)
            if selectedTool == .subjectSelect && !subjectMasks.isEmpty {
                NativeEditorSubjectOverlay(image: image, masks: subjectMasks, selectedMask: selectedSubject,
                    onSelection: onSubjectSelectionChanged, onLift: onLiftSubject)
                .frame(width: display.width, height: display.height)
            }
        }
        .frame(width: display.width, height: display.height)
        .overlay(Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1).allowsHitTesting(false))
        .position(x: viewport.origin.x + display.width / 2, y: viewport.origin.y + display.height / 2)
    }

    /// Space-drag panning sits above every tool so it never draws, selects or lifts.
    private var panSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let previous = lastPanLocation ?? value.startLocation
                    lastPanLocation = value.location
                    NSCursor.closedHand.set()
                    viewportModel.update {
                        $0.pan(by: CGSize(width: value.location.x - previous.x, height: value.location.y - previous.y))
                    }
                }
                .onEnded { _ in
                    lastPanLocation = nil
                    NSCursor.openHand.set()
                })
    }

    private func layout(_ size: CGSize) {
        guard let pixelSize else { return }
        viewportModel.layout(imageSize: pixelSize, viewportSize: size)
    }

    private func load() async {
        loadFailed = false
        async let metadataSize = ImageEditorSource.dimensions(at: sourceURL)
        let loaded = await ImageCache.shared.loadFullImage(from: sourceURL)
        let dimensions = await metadataSize
        guard !Task.isCancelled else { return }
        let size = dimensions ?? loaded.flatMap { image in
            image.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
        }
        image = loaded
        pixelSize = size
        loadFailed = loaded == nil || size == nil
        if let size { onSourceSizeLoaded(size) }
    }
}

// MARK: - Zoom control

/// Compact corner zoom control, like the reference's workspace zoom, using native menus.
struct EditorZoomControl: View {
    @ObservedObject var model: EditorViewportModel
    let canZoomToSelection: Bool
    let onZoomToSelection: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { model.zoomOut() } label: { Image(systemName: "minus").frame(width: 24, height: 22) }
                .help("Zoom Out (⌘−)")
            Menu {
                Button("Zoom In") { model.zoomIn() }.keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { model.zoomOut() }.keyboardShortcut("-", modifiers: .command)
                Divider()
                Button("Fit in Window") { model.fit() }.keyboardShortcut("0", modifiers: .command)
                Button("Actual Size") { model.actualSize() }.keyboardShortcut("1", modifiers: .command)
                Button("Zoom to Selection", action: onZoomToSelection)
                    .keyboardShortcut("2", modifiers: .command)
                    .disabled(!canZoomToSelection)
                Divider()
                ForEach([0.5, 2.0, 4.0], id: \.self) { scale in
                    Button("\(Int(scale * 100))%") {
                        model.update { $0.zoom(to: scale, anchor: $0.viewportCenter) }
                    }
                }
            } label: {
                Text(model.viewport.map { "\($0.zoomPercent)%" } ?? "–")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .frame(minWidth: 40)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Zoom · pinch or ⌘-scroll to zoom at the pointer, scroll or hold Space to pan")
            Button { model.zoomIn() } label: { Image(systemName: "plus").frame(width: 24, height: 22) }
                .help("Zoom In (⌘+)")
            Divider().frame(height: 14).padding(.horizontal, 2)
            Button { model.fit() } label: {
                Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                    .frame(width: 24, height: 22)
            }
            .help("Fit in Window (⌘0)")
            .disabled(model.viewport?.isFitted ?? true)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.08)))
    }
}

// MARK: - Scroll, pinch and smart-zoom routing

/// Local monitors see trackpad and wheel input even where AppKit subviews (the native subject
/// overlay) sit above the SwiftUI canvas. Only events inside this canvas and window are consumed.
private struct EditorCanvasEventMonitor: NSViewRepresentable {
    let model: EditorViewportModel

    func makeNSView(context: Context) -> EditorCanvasEventView {
        let view = EditorCanvasEventView()
        view.model = model
        return view
    }

    func updateNSView(_ view: EditorCanvasEventView, context: Context) {
        view.model = model
    }

    static func dismantleNSView(_ view: EditorCanvasEventView, coordinator: ()) {
        view.stopMonitoring()
    }
}

private final class EditorCanvasEventView: NSView {
    weak var model: EditorViewportModel?
    private var monitor: Any?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .smartMagnify]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  window.attachedSheet == nil, let model = self.model else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            return self.handle(event, at: point, model: model) ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent, at point: CGPoint, model: EditorViewportModel) -> Bool {
        switch event.type {
        case .magnify:
            model.update { $0.zoom(by: 1 + event.magnification, anchor: point) }
        case .smartMagnify:
            model.update { viewport in
                if viewport.isFitted { viewport.zoom(to: max(1, viewport.fitScale * 2), anchor: point) }
                else { viewport.fit() }
            }
        case .scrollWheel:
            let precise = event.hasPreciseScrollingDeltas
            if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                let factor = exp(event.scrollingDeltaY * (precise ? 0.01 : 0.1))
                model.update { $0.zoom(by: factor, anchor: point) }
            } else {
                let unit: CGFloat = precise ? 1 : 12
                model.update { $0.pan(by: CGSize(width: event.scrollingDeltaX * unit, height: event.scrollingDeltaY * unit)) }
            }
        default:
            return false
        }
        return true
    }
}
