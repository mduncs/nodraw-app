import AppKit
import Combine
import UniformTypeIdentifiers
import ImageIO

/// One immutable document/source pair owns every asynchronous editor operation.
@MainActor
final class ImageEditorWorkflow: ObservableObject {
    let session: AnnotationEditorSession
    let sourceURL: URL
    let ai: AnnotationAIService
    @Published private(set) var subjectMasks: [SubjectMask] = []
    @Published var selectedSubject: SubjectMask?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    /// Increments when lift/import/paste lands new image objects, which are then selected so
    /// the host can switch to Select and let them be moved immediately.
    @Published private(set) var placedObjectRevision = 0
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var acceptsEdits = true
    private let assetStore: AnnotationAssetStore
    private let openedSourceStamp: String
    var isActive: Bool { acceptsEdits }

    init(session: AnnotationEditorSession, sourceURL: URL, assetStore: AnnotationAssetStore = .shared) {
        self.session = session
        self.sourceURL = sourceURL
        self.assetStore = assetStore
        self.ai = AnnotationAIService(assetStore: assetStore)
        self.openedSourceStamp = Self.stamp(sourceURL)
    }

    func cancel() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        ai.cancel()
        isWorking = false
    }

    func activate() { acceptsEdits = true }
    func deactivate() { acceptsEdits = false; cancel() }

    /// A human edit or a changed source invalidates pending image operations.
    func runEdit(_ description: String, selectsPlacedObjects: Bool = false,
                 produce: @escaping () async throws -> AnnotationCommand) {
        guard acceptsEdits else { return }
        guard Self.stamp(sourceURL) == openedSourceStamp else {
            cancel()
            errorMessage = ExportError.sourceChanged.localizedDescription
            return
        }
        cancel()
        let token = generation
        let revision = session.revision
        let sourceStamp = Self.stamp(sourceURL)
        isWorking = true
        errorMessage = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.isWorking = false } }
            do {
                let command = try await produce()
                try Task.checkCancellation()
                guard self.generation == token else { return }
                guard self.session.revision == revision, Self.stamp(self.sourceURL) == sourceStamp else {
                    self.errorMessage = "The image or edits changed while processing. Run the tool again."
                    return
                }
                guard self.session.execute(command, description: description) else { return }
                let placed = Self.placedImageObjects(in: command)
                if selectsPlacedObjects, !placed.isEmpty {
                    self.session.selectedShapeIds = placed
                    self.placedObjectRevision += 1
                }
            } catch is CancellationError {
            } catch {
                guard self.generation == token else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func analyzeSubjects() {
        guard acceptsEdits else { return }
        guard Self.stamp(sourceURL) == openedSourceStamp else {
            cancel()
            subjectMasks = []
            selectedSubject = nil
            errorMessage = ExportError.sourceChanged.localizedDescription
            return
        }
        guard subjectMasks.isEmpty, !isWorking else { return }
        cancel()
        let token = generation
        let sourceStamp = Self.stamp(sourceURL)
        isWorking = true
        errorMessage = nil
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.isWorking = false } }
            do {
                let masks = try await self.ai.analyzeSubjects(from: self.sourceURL)
                try Task.checkCancellation()
                guard self.generation == token, Self.stamp(self.sourceURL) == sourceStamp else { return }
                self.subjectMasks = masks
                if masks.isEmpty { self.errorMessage = "No separate subjects were detected in this image." }
            } catch is CancellationError {
            } catch {
                if self.generation == token { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func removeBackground(feather: CGFloat) {
        runEdit("Remove Background") { [ai, sourceURL] in
            try await ai.removeBackground(from: sourceURL, featherRadius: feather)
        }
    }

    func isolatePerson(feather: CGFloat) {
        runEdit("Isolate Person") { [ai, sourceURL] in
            try await ai.isolatePerson(from: sourceURL, featherRadius: feather)
        }
    }

    func liftSelectedSubject() {
        guard let mask = selectedSubject else {
            analyzeSubjects()
            return
        }
        let document = session.annotationSet
        runEdit("Lift Subject", selectsPlacedObjects: true) { [ai, sourceURL] in
            guard let source = await ImageEditorSource.decode(at: sourceURL) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let result = try await ai.liftSubject(source: source, subjectMask: mask, existingAnnotations: document)
            return result.command
        }
        selectedSubject = nil
    }

    func importImages(_ urls: [URL]) {
        runEdit("Add Images", selectsPlacedObjects: true) { [assetStore, sourceURL] in
            guard let sourceSize = await ImageEditorSource.dimensions(at: sourceURL), sourceSize.height > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var commands: [AnnotationCommand] = []
            for url in urls {
                try Task.checkCancellation()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let cgImage = await ImageEditorSource.decode(at: url) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let key = try await assetStore.saveCGImage(cgImage)
                let aspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
                let sourceAspect = sourceSize.width / sourceSize.height
                let width = min(0.8, 0.8 * aspect / sourceAspect)
                let height = width * sourceAspect / aspect
                let layerID = UUID()
                let shape = AnnotationShape.extractedSubject(id: UUID(), assetKey: key,
                    bounds: NormalizedRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height),
                    opacity: 1, transform: .identity, sourceSubjectId: nil)
                commands += [.addLayer(name: url.deletingPathExtension().lastPathComponent, id: layerID),
                             .addShape(shape: shape, layerId: layerID), .setActiveLayer(layerId: layerID)]
            }
            return .group(commands)
        }
    }

    func pasteImage(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errorMessage = "The clipboard image could not be read."
            return
        }
        runEdit("Paste Image", selectsPlacedObjects: true) { [assetStore, sourceURL] in
            guard let sourceSize = await ImageEditorSource.dimensions(at: sourceURL), sourceSize.height > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let key = try await assetStore.saveCGImage(cgImage)
            let aspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
            let sourceAspect = sourceSize.width / sourceSize.height
            let width = min(0.8, 0.8 * aspect / sourceAspect)
            let height = width * sourceAspect / aspect
            let layerID = UUID()
            let shape = AnnotationShape.extractedSubject(id: UUID(), assetKey: key,
                bounds: NormalizedRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height),
                opacity: 1, transform: .identity, sourceSubjectId: nil)
            return .group([.addLayer(name: "Pasted image", id: layerID), .addShape(shape: shape, layerId: layerID),
                .setActiveLayer(layerId: layerID)])
        }
    }

    func export(to destination: URL) async throws {
        let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let destinationAttributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        let sourceInode = sourceAttributes?[.systemFileNumber] as? NSNumber
        let destinationInode = destinationAttributes?[.systemFileNumber] as? NSNumber
        guard destination.resolvingSymlinksInPath().standardizedFileURL != sourceURL.resolvingSymlinksInPath().standardizedFileURL,
              sourceInode == nil || sourceInode != destinationInode else { throw ExportError.overwriteOriginal }
        let sourceStamp = Self.stamp(sourceURL)
        let rendered = try await renderedImage()
        guard let image = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let ext = destination.pathExtension.lowercased()
        let type: UTType = ["jpg", "jpeg"].contains(ext) ? .jpeg : ["tiff", "tif"].contains(ext) ? .tiff : .png
        let data = try await ImageEditorSource.encode(image, typeIdentifier: type.identifier)
        guard Self.stamp(sourceURL) == sourceStamp else { throw ExportError.sourceChanged }
        try Task.checkCancellation()
        try await ImageEditorSource.write(data, to: destination)
    }

    func renderedImage() async throws -> NSImage {
        guard Self.stamp(sourceURL) == openedSourceStamp else { throw ExportError.sourceChanged }
        let snapshot = session.annotationSet
        let sourceStamp = Self.stamp(sourceURL)
        guard let source = await ImageEditorSource.decode(at: sourceURL),
              let rendered = await AnnotationRenderer.render(annotations: snapshot, onto: source, assetStore: assetStore) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        guard Self.stamp(sourceURL) == sourceStamp else { throw ExportError.sourceChanged }
        return rendered
    }

    enum ExportError: LocalizedError {
        case overwriteOriginal, sourceChanged
        var errorDescription: String? {
            switch self {
            case .overwriteOriginal: return "Choose another filename. The editor keeps your original image unchanged."
            case .sourceChanged: return "The original image changed on disk. Reopen the editor before using this tool or exporting."
            }
        }
    }

    nonisolated static func placedImageObjects(in command: AnnotationCommand) -> Set<UUID> {
        switch command {
        case .group(let commands): return commands.reduce(into: []) { $0.formUnion(placedImageObjects(in: $1)) }
        case .addShape(let shape, _) where shape.isExtractedSubject: return [shape.id]
        default: return []
        }
    }

    private static func stamp(_ url: URL) -> String {
        // Read filesystem attributes afresh: URL resource caches and size/mtime alone
        // cannot distinguish an atomic replacement that preserves timestamps.
        let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (values?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(values?[.systemFileNumber] ?? "missing"):\(modified):\(values?[.size] ?? -1)"
    }
}
