import Foundation
import CoreGraphics
import AppKit

// MARK: - AIJob

/// Tracks a single AI operation's lifecycle.
struct AIJob: Identifiable {
    enum Status: Equatable {
        case running
        case completed
        case failed(String)
        case cancelled

        static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.running, .running), (.completed, .completed), (.cancelled, .cancelled):
                return true
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    let id: UUID
    let operation: String
    let startTime: Date
    var status: Status
}

// MARK: - AIServiceError

enum AIServiceError: LocalizedError {
    case requiresMacOS14
    case noResult(String)
    case extractionFailed
    case assetSaveFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .requiresMacOS14: return "This feature requires macOS 14+"
        case .noResult(let detail): return detail
        case .extractionFailed: return "Failed to extract subject image"
        case .assetSaveFailed: return "Failed to save extracted subject"
        case .cancelled: return "Operation was cancelled"
        }
    }
}

// MARK: - AnnotationAIService

/// Consolidates all AI annotation operations.
/// Each method returns AnnotationCommand(s) — views call session.execute().
/// Owns job lifecycle (progress/cancellation) so views just observe `currentJob`.
@MainActor
final class AnnotationAIService: ObservableObject {

    @Published private(set) var currentJob: AIJob?

    private var cancelRunningOperation: (() -> Void)?
    private let assetStore: AnnotationAssetStore
    private let backgroundMaskProvider: (URL) async throws -> CGImage?
    private let personMaskProvider: (URL) async throws -> CGImage?

    init(
        assetStore: AnnotationAssetStore = .shared,
        backgroundMaskProvider: @escaping (URL) async throws -> CGImage? = { try await VisionProcessor.removeBackground(from: $0) },
        personMaskProvider: @escaping (URL) async throws -> CGImage? = { try await VisionProcessor.segmentPerson(from: $0, quality: .balanced) }
    ) {
        self.assetStore = assetStore
        self.backgroundMaskProvider = backgroundMaskProvider
        self.personMaskProvider = personMaskProvider
    }

    /// Whether an AI operation is currently running
    var isProcessing: Bool {
        if case .running = currentJob?.status { return true }
        return false
    }

    /// Start time of current operation (for elapsed display)
    var processingStartTime: Date? {
        if case .running = currentJob?.status { return currentJob?.startTime }
        return nil
    }

    // MARK: - Job Lifecycle

    /// A task belongs to exactly one job generation. Cancelling/replacing it prevents a
    /// late provider result from returning an edit or changing the newer job's status.
    private func performJob<Value>(
        _ name: String,
        operation: @escaping () async throws -> Value
    ) async throws -> Value {
        cancelRunningOperation?()
        let id = UUID()
        currentJob = AIJob(id: id, operation: name, startTime: Date(), status: .running)
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await operation()
        }
        cancelRunningOperation = { task.cancel() }
        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard currentJob?.id == id, currentJob?.status == .running, !task.isCancelled else {
                throw CancellationError()
            }
            currentJob?.status = .completed
            cancelRunningOperation = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                if self?.currentJob?.id == id, self?.currentJob?.status == .completed {
                    self?.currentJob = nil
                }
            }
            return value
        } catch {
            let cancelled = error is CancellationError || task.isCancelled || Task.isCancelled
            if currentJob?.id == id {
                currentJob?.status = cancelled ? .cancelled : .failed(error.localizedDescription)
                cancelRunningOperation = nil
            }
            if cancelled { throw CancellationError() }
            throw error
        }
    }

    /// Cancel the running operation; its command can no longer be committed by a caller.
    func cancel() {
        cancelRunningOperation?()
        cancelRunningOperation = nil
        if currentJob?.status == .running { currentJob?.status = .cancelled }
    }

    // MARK: - Remove Background

    /// Remove background → retain the foreground-white mask with blendMode .maskKeep
    func removeBackground(
        from url: URL,
        featherRadius: CGFloat
    ) async throws -> AnnotationCommand {
        try await maskOperation(
            jobName: "Remove Background",
            blendMode: .maskKeep,
            featherRadius: featherRadius,
            requiresMacOS14: true,
            noResultMessage: "Background removal returned no mask"
        ) {
            try await self.backgroundMaskProvider(url)
        }
    }

    // MARK: - Isolate Person

    /// Isolate person → returns .addShape(mask) command with blendMode .maskKeep
    func isolatePerson(
        from url: URL,
        featherRadius: CGFloat
    ) async throws -> AnnotationCommand {
        try await maskOperation(
            jobName: "Isolate Person",
            blendMode: .maskKeep,
            featherRadius: featherRadius,
            noResultMessage: "Person segmentation returned no mask"
        ) {
            try await self.personMaskProvider(url)
        }
    }

    private func maskOperation(
        jobName: String,
        blendMode: BlendMode,
        featherRadius: CGFloat,
        requiresMacOS14: Bool = false,
        noResultMessage: String,
        maskProvider: @escaping () async throws -> CGImage?
    ) async throws -> AnnotationCommand {
        try await performJob(jobName) {
            if requiresMacOS14 {
                guard #available(macOS 14.0, *) else { throw AIServiceError.requiresMacOS14 }
            }
            guard let maskImage = try await maskProvider() else {
                throw AIServiceError.noResult(noResultMessage)
            }
            try Task.checkCancellation()
            // Feather once in the shared renderer so preview and export use the same mask.
            let maskData = ImageMasking.cgImageToPNGData(maskImage)
            guard !maskData.isEmpty else { throw AIServiceError.extractionFailed }
            let shape = AnnotationShape.mask(
                id: UUID(), maskData: maskData,
                bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                blendMode: blendMode, opacity: 1.0, featherRadius: featherRadius
            )
            return .addShape(shape: shape, layerId: nil)
        }
    }

    // MARK: - Analyze Subjects

    /// Analyze all subjects → returns [SubjectMask]. No command — just cache population.
    /// Checks SubjectMaskCache first for instant return.
    func analyzeSubjects(
        from url: URL,
        subjectProvider: @escaping (URL) async throws -> [SubjectMask] = { try await VisionProcessor.analyzeAllSubjects(from: $0) }
    ) async throws -> [SubjectMask] {
        try await performJob("Analyze Subjects") {
            guard #available(macOS 14.0, *) else { throw AIServiceError.requiresMacOS14 }
            if let cached = await SubjectMaskCache.shared.get(for: url) { return cached }
            // Bind these masks to the bytes about to be analyzed, not the file occupying
            // this path when Vision eventually finishes. URL metadata may itself be cached.
            guard let sourceVersion = SubjectMaskCache.sourceVersion(for: url) else {
                throw AIServiceError.noResult("The source image is no longer available.")
            }
            let allMasks = try await subjectProvider(url)
            try Task.checkCancellation()
            guard SubjectMaskCache.sourceVersion(for: url) == sourceVersion else {
                throw AIServiceError.noResult("The source image changed during subject analysis. Analyze it again.")
            }
            let masks = Array(allMasks.prefix(SubjectMaskCache.maxSubjectsPerEntry))
            await SubjectMaskCache.shared.set(masks, for: url, expectedVersion: sourceVersion)
            return masks
        }
    }

    // MARK: - Lift Subject

    /// Lift subject → returns command group (addLayer, addShape × 2, setActiveLayer)
    /// and the extractedSubjectId for selection.
    func liftSubject(
        source: CGImage,
        subjectMask: SubjectMask,
        existingAnnotations: AnnotationSet
    ) async throws -> (command: AnnotationCommand, extractedSubjectId: UUID) {
        try await performJob("Lift Subject") {
            // Vision bounds are normalized bottom-left. Annotation bounds and CGImage
            // cropping are top-left. Align to source pixels, then store that exact rect
            // so a small subject is neither shrunk nor vertically mirrored on placement.
            let vision = subjectMask.bounds
            guard [vision.minX, vision.minY, vision.width, vision.height].allSatisfy(\.isFinite),
                  vision.width > 0, vision.height > 0 else { throw AIServiceError.extractionFailed }
            let size = CGSize(width: source.width, height: source.height)
            let imageRect = CGRect(origin: .zero, size: size)
            let cropRect = CGRect(x: vision.minX * size.width,
                                  y: (1 - vision.maxY) * size.height,
                                  width: vision.width * size.width,
                                  height: vision.height * size.height).integral.intersection(imageRect)
            guard !cropRect.isEmpty,
                  let fullCutout = ImageMasking.extractWithTransparency(source: source, mask: subjectMask.mask),
                  let extracted = fullCutout.cropping(to: cropRect) else {
                throw AIServiceError.extractionFailed
            }
            try Task.checkCancellation()
            let assetKey = try await self.assetStore.saveCGImage(extracted)
            try Task.checkCancellation()
            let maskData = ImageMasking.cgImageToPNGData(subjectMask.mask)
            guard !maskData.isEmpty else { throw AIServiceError.extractionFailed }
            let bounds = NormalizedRect.normalized(from: cropRect, in: size)
            let extractedSubjectId = UUID()
            let extractedSubject = AnnotationShape.extractedSubject(
                id: extractedSubjectId, assetKey: assetKey, bounds: bounds,
                opacity: 1, transform: .identity, sourceSubjectId: nil
            )
            let cutoutMask = AnnotationShape.mask(
                id: UUID(), maskData: maskData,
                bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                blendMode: .maskRemove, opacity: 1, featherRadius: 0
            )
            var commands: [AnnotationCommand] = []
            let masksLayerId: UUID
            if let existing = existingAnnotations.layers.first(where: {
                $0.name == "Background Masks" && !$0.isLocked && $0.isVisible
                    && $0.opacity == 1 && $0.blendMode == .normal
            }) {
                masksLayerId = existing.id
            } else {
                masksLayerId = UUID()
                commands.append(.addLayer(name: "Background Masks", id: masksLayerId))
            }
            commands.append(.addShape(shape: cutoutMask, layerId: masksLayerId))
            let layerName = "Subject \(existingAnnotations.layers.filter { $0.name.hasPrefix("Subject ") }.count + 1)"
            let subjectLayerId = UUID()
            commands.append(.addLayer(name: layerName, id: subjectLayerId))
            commands.append(.addShape(shape: extractedSubject, layerId: subjectLayerId))
            commands.append(.setActiveLayer(layerId: subjectLayerId))
            return (command: .group(commands), extractedSubjectId: extractedSubjectId)
        }
    }
}
