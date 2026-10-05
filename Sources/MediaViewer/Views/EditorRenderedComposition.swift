import SwiftUI
import AppKit
import SubjectIsolation

/// Display-sized rendering uses exactly the same composition as full-resolution export.
/// Cancellation and a generation token prevent a late frame replacing newer edits.
struct EditorRenderedComposition: View {
    let image: NSImage
    let annotations: AnnotationSet
    let displaySize: CGSize
    var assetStore: AnnotationAssetStore? = nil
    var coordinateSize: CGSize? = nil
    var applyCrop = false
    /// The zoomable editor raises this; the viewer keeps its lighter default.
    var maximumRenderDimension: CGFloat = 2048
    @State private var rendered: NSImage?
    @State private var renderTask: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var failed = false

    var body: some View {
        ZStack {
            Image(nsImage: rendered ?? image)
                .resizable()
                .frame(width: displaySize.width, height: displaySize.height)
            if failed {
                Label("An image layer could not be rendered", systemImage: "exclamationmark.triangle")
                    .font(.caption).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .allowsHitTesting(false)
        .onAppear { scheduleRender() }
        .onChange(of: annotations) { _, _ in scheduleRender() }
        .onChange(of: ObjectIdentifier(image)) { _, _ in rendered = nil; scheduleRender() }
        .onChange(of: displaySize) { _, _ in scheduleRender() }
        .onDisappear { renderTask?.cancel(); generation = UUID() }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        let token = UUID()
        generation = token
        let snapshot = annotations
        if snapshot.isEmpty {
            rendered = nil
            failed = false
            return
        }
        let limit = min(maximumRenderDimension, max(displaySize.width, displaySize.height) * (NSScreen.main?.backingScaleFactor ?? 2))
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { failed = true; return }
        renderTask = Task {
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            let result = await AnnotationRenderer.render(annotations: snapshot, onto: source,
                assetStore: assetStore, maximumDimension: limit, applyCrop: applyCrop, coordinateSize: coordinateSize)
            guard !Task.isCancelled, generation == token else { return }
            failed = result == nil
            if let result { rendered = result }
        }
    }
}

/// Native hover, contour glow, click selection, lift animation, and image dragging.
/// Vision analysis is supplied by the source-pinned workflow; this view never starts analysis.
struct NativeEditorSubjectOverlay: NSViewRepresentable {
    let image: NSImage
    let masks: [SubjectMask]
    let selectedMask: SubjectMask?
    var onSelection: ((Int?) -> Void)?
    var onLift: (() -> Void)?

    func makeNSView(context: Context) -> SubjectHighlightView {
        let view = SubjectHighlightView(frame: .zero)
        view.showsSourceImage = false
        view.isSubjectInteractionEnabled = true
        view.allowsMultipleSelection = false
        view.allowsSubjectDragging = true
        return view
    }

    func updateNSView(_ view: SubjectHighlightView, context: Context) {
        // Avoid callbacks from programmatic snapshot invalidation during a SwiftUI update.
        view.onSelectionChanged = nil
        view.image = image
        view.isolationResult = IsolationResult(subjects: masks.enumerated().map { index, mask in
            SubjectInstance(index: index + 1, mask: mask.mask, boundingBox: mask.bounds,
                contourPath: mask.contourPath, outerContourPath: mask.outerContourPath)
        }, foregroundMask: nil, semanticMasks: [:], imageSize: image.size)
        view.selectedSubjects = selectedMask.flatMap { selected in
            masks.firstIndex(where: { $0.id == selected.id }).map { IndexSet(integer: $0 + 1) }
        } ?? []
        view.onSelectionChanged = { ids in onSelection?(ids.first.map { $0 - 1 }) }
        view.onSubjectLiftRequested = { ids in
            onSelection?(ids.first.map { $0 - 1 })
            onLift?()
        }
    }
}
