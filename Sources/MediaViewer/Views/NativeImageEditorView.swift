import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Native editor host. The source/session stay pinned while its tools are active.
struct NativeImageEditorView: View {
    @ObservedObject var session: AnnotationEditorSession
    let sourceURL: URL
    @Binding var isPresented: Bool
    let onDocumentChanged: (AnnotationSet) -> Void
    let assetStore: AnnotationAssetStore
    @StateObject private var workflow: ImageEditorWorkflow
    @StateObject private var viewportModel = EditorViewportModel()
    @State private var tool: AnnotationTool = .select
    @State private var style: ShapeStyle = .defaultFreeform
    @State private var textStyle: TextStyle = .default
    @State private var eraserMode: EraserMode = .removeFromMask
    @State private var brushSize: CGFloat = 30
    @State private var feather: CGFloat = 2
    @State private var selectedShapeID: UUID?
    @State private var isFinishing = false
    @State private var dropTask: Task<Void, Never>?
    /// Source-pixel defaults follow the document once; see `EditorDocumentScale`.
    @State private var documentScale: CGFloat = 1
    @State private var appliedDocumentScale = false

    init(session: AnnotationEditorSession, sourceURL: URL, isPresented: Binding<Bool>,
         initialStyle: ShapeStyle = .defaultFreeform,
         onDocumentChanged: @escaping (AnnotationSet) -> Void, assetStore: AnnotationAssetStore = .shared) {
        self.session = session
        self.sourceURL = sourceURL
        self._isPresented = isPresented
        self.onDocumentChanged = onDocumentChanged
        self.assetStore = assetStore
        self._style = State(initialValue: initialStyle)
        self._workflow = StateObject(wrappedValue: ImageEditorWorkflow(session: session, sourceURL: sourceURL, assetStore: assetStore))
    }

    var body: some View {
        ImageEditorWorkspace(session: session, selectedTool: $tool, currentStyle: $style,
            currentTextStyle: $textStyle, eraserMode: $eraserMode, eraserBrushSize: $brushSize,
            featherRadius: $feather, isProcessing: workflow.isWorking,
            hasSelectedSubject: workflow.selectedSubject != nil,
            documentScale: documentScale,
            onDone: finish, onExport: exportImage, onImportImage: importImages,
            onRemoveBackground: { workflow.removeBackground(feather: feather) },
            onIsolatePerson: { workflow.isolatePerson(feather: feather) },
            onLiftSubjects: {
                tool = .subjectSelect
                workflow.liftSelectedSubject()
            }) {
                ImageEditorCanvas(sourceURL: sourceURL, session: session, viewportModel: viewportModel,
                    selectedTool: $tool, currentStyle: $style, currentTextStyle: $textStyle,
                    selectedShapeID: $selectedShapeID, eraserMode: $eraserMode, eraserBrushSize: $brushSize,
                    subjectMasks: workflow.subjectMasks, selectedSubject: workflow.selectedSubject,
                    assetStore: assetStore,
                    onSubjectSelectClick: selectSubject,
                    onSubjectSelectionChanged: { index in
                        workflow.selectedSubject = index.flatMap { workflow.subjectMasks.indices.contains($0) ? workflow.subjectMasks[$0] : nil }
                    },
                    onLiftSubject: { workflow.liftSelectedSubject() },
                    onSourceSizeLoaded: applyDocumentScale)
                .overlay(alignment: .top) {
                    VStack(spacing: 8) {
                        if tool == .subjectSelect { subjectActionBar }
                        if let error = workflow.errorMessage { errorToast(error) }
                    }
                    .padding(.top, 12)
                    .animation(.easeOut(duration: 0.15), value: workflow.selectedSubject?.id)
                }
                .overlay(alignment: .bottomLeading) {
                    // Subject analysis and lifting report progress in the subject bar instead.
                    if workflow.isWorking && tool != .subjectSelect {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Processing…").font(.system(size: 11)).foregroundStyle(.secondary)
                            Button("Cancel") { workflow.cancel() }.controlSize(.small)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(12)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    EditorZoomControl(model: viewportModel, canZoomToSelection: !session.selectedShapeIds.isEmpty,
                                      onZoomToSelection: zoomToSelection)
                        .padding(12)
                }
            }
            .onChange(of: tool) { _, value in
                if value == .subjectSelect { workflow.analyzeSubjects() }
                else { workflow.selectedSubject = nil }
            }
            // A lifted, imported or pasted image arrives selected; Select lets it be moved at once.
            .onChange(of: workflow.placedObjectRevision) { _, _ in tool = .select }
            .onReceive(session.$annotationSet) { onDocumentChanged($0) }
            .onAppear { workflow.activate() }
            .onDisappear { dropTask?.cancel(); workflow.deactivate() }
            .allowsHitTesting(!isFinishing)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                let target = workflow
                dropTask?.cancel()
                dropTask = Task {
                    do {
                        var urls: [URL] = []
                        for provider in providers {
                            let data: Data = try await withCheckedThrowingContinuation { continuation in
                                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                                    if let data { continuation.resume(returning: data) }
                                    else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
                                }
                            }
                            try Task.checkCancellation()
                            guard let url = URL(dataRepresentation: data, relativeTo: nil) else { throw CocoaError(.fileReadCorruptFile) }
                            urls.append(url)
                        }
                        if !urls.isEmpty { target.importImages(urls) }
                    } catch is CancellationError {
                    } catch {
                        guard !Task.isCancelled else { return }
                        target.errorMessage = "Could not import dropped image: \(error.localizedDescription)"
                    }
                }
                return !providers.isEmpty
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportAnnotatedImage)) { _ in exportImage() }
            .onReceive(NotificationCenter.default.publisher(for: ImageEditorMenuAction.notification)) { notification in
                guard !isFinishing, let action = notification.object as? ImageEditorMenuAction else { return }
                action.perform(on: session, pasteImage: pasteImage)
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyImageToClipboard)) { _ in
                Task {
                    do {
                        let rendered = try await workflow.renderedImage()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([rendered])
                    } catch { workflow.errorMessage = error.localizedDescription }
                }
            }
            .modifier(EditorKeyboardModifier(session: session, onDone: escape, onPasteImage: pasteImage,
                                             onCommand: perform))
            .modifier(AnnotationToolShortcutModifier(selectedTool: $tool,
                isAnnotationModeActive: Binding(get: { isPresented }, set: { if !$0 { finish() } }),
                // [ and ] step the app-wide brush size in reference units; scale them to this document.
                eraserBrushSize: Binding(get: { brushSize / documentScale }, set: { brushSize = $0 * documentScale }),
                isCurrentMediaVideo: false,
                onRemoveBackground: { workflow.removeBackground(feather: feather) },
                onIsolatePerson: { workflow.isolatePerson(feather: feather) }))
    }

    // MARK: - Subject lifting

    /// Contextual preview/apply/cancel bar, like the reference's mode pill: the highlight is the
    /// preview, Lift applies one undoable edit, Cancel or Esc clears the pending selection.
    @ViewBuilder private var subjectActionBar: some View {
        HStack(spacing: 10) {
            if workflow.isWorking {
                ProgressView().controlSize(.small)
                Text(workflow.subjectMasks.isEmpty ? "Finding subjects…" : "Processing…")
                Button("Cancel") { workflow.cancel() }
            } else if workflow.selectedSubject != nil {
                Image(systemName: "person.crop.rectangle.badge.plus").foregroundStyle(Color.accentOrange)
                Text("Subject selected")
                Button { workflow.liftSelectedSubject() } label: { Text("Lift to Layer  ↩") }
                    .buttonStyle(.borderedProminent).tint(Color.accentOrange)
                    .help("Add the subject as its own image layer. The original stays untouched.")
                Button("Cancel") { workflow.selectedSubject = nil }
                    .help("Clear the pending subject (Esc)")
            } else if workflow.subjectMasks.isEmpty {
                Image(systemName: "scope").foregroundStyle(.secondary)
                Text("No separate subjects found")
                Button("Remove Background") { workflow.removeBackground(feather: feather) }
                Button("Done") { tool = .select }
            } else {
                Image(systemName: "scope").foregroundStyle(Color.accentOrange)
                Text("Click a subject · \(workflow.subjectMasks.count) found")
                Text("Double-click lifts · drag out to copy").foregroundStyle(.secondary)
                Button("Done") { tool = .select }
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    private func errorToast(_ error: String) -> some View {
        // Same type size and material as the subject bar it can stack under.
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Button("Dismiss") { workflow.errorMessage = nil }
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .frame(maxWidth: 520)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    private func selectSubject(_ point: NormalizedPoint) {
        workflow.selectedSubject = workflow.subjectMasks.first {
            $0.isPixelSet(x: Int(point.x * CGFloat($0.mask.width)), y: Int(point.y * CGFloat($0.mask.height)))
        }
        if workflow.subjectMasks.isEmpty { workflow.analyzeSubjects() }
    }

    // MARK: - Commands

    /// Esc steps back one level at a time; only an idle editor saves and closes.
    private func escape() {
        if workflow.isWorking { workflow.cancel() }
        else if workflow.selectedSubject != nil { workflow.selectedSubject = nil }
        else if tool != .select { tool = .select }
        else { finish() }
    }

    private func perform(_ command: EditorKeyCommand) -> Bool {
        switch command {
        case .zoomIn: viewportModel.zoomIn()
        case .zoomOut: viewportModel.zoomOut()
        case .zoomToFit: viewportModel.fit()
        case .actualSize: viewportModel.actualSize()
        case .zoomToSelection: zoomToSelection()
        case .confirm:
            guard tool == .subjectSelect, workflow.selectedSubject != nil, !workflow.isWorking else { return false }
            workflow.liftSelectedSubject()
        case .selectTool(let next):
            tool = next
        case .spacePan(let active):
            viewportModel.isSpacePanning = active
        }
        return true
    }

    private func zoomToSelection() {
        guard let size = viewportModel.viewport?.imageSize else { return }
        let bounds = session.selectedShapes.map { EditorShapeGeometry.bounds(of: $0, imageSize: size) }
        if let rect = EditorShapeGeometry.union(bounds) { viewportModel.zoom(toFit: rect) }
        else { viewportModel.fit() }
    }

    private func applyDocumentScale(_ size: CGSize) {
        guard !appliedDocumentScale else { return }
        appliedDocumentScale = true
        let factor = EditorDocumentScale.factor(for: size)
        documentScale = factor
        guard factor != 1 else { return }
        style = EditorDocumentScale.scaled(style, by: factor)
        textStyle = EditorDocumentScale.scaled(textStyle, by: factor)
        brushSize = (brushSize * factor).rounded()
    }

    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        dropTask?.cancel()
        workflow.cancel()
        Task {
            defer { isFinishing = false }
            do {
                try await session.saveNow()
                if workflow.isActive && !session.isDirty { isPresented = false }
            }
            catch { workflow.errorMessage = error.localizedDescription }
        }
    }

    private func pasteImage() {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            workflow.importImages(urls)
        } else if let image = NSImage(pasteboard: .general) {
            workflow.pasteImage(image)
        }
    }

    private func importImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { workflow.importImages(panel.urls) }
    }

    private func exportImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-edited.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await workflow.export(to: url) }
            catch { workflow.errorMessage = error.localizedDescription }
        }
    }
}
