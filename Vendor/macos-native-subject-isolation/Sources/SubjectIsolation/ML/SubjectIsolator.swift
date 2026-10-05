import Foundation
import CoreGraphics
import Vision
import CoreImage

/// Main entry point for subject isolation.
///
/// Wraps Vision segmentation APIs (public + private) behind a clean async interface.
/// Uses compound request for efficiency when available, falls back to individual requests.
///
/// ```swift
/// let isolator = SubjectIsolator()
/// let result = try await isolator.isolate(image: cgImage)
/// for subject in result.subjects {
///     let cutout = subject.cutout(from: cgImage)
///     let path = subject.contourPath  // for glow UI
/// }
/// ```
public final class SubjectIsolator: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.subjectisolation.isolator", qos: .userInitiated)
    private let requests = SegmentationRequests()
    private let processor = MaskProcessor.shared
    private let tracer = ContourTracer()
    private static let personDetectionMaskThreshold: UInt8 = 15

    public init() {}

    /// Whether the system supports subject isolation (macOS 14+).
    public static var isAvailable: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    /// Whether the private compound request is available (single-pass efficiency).
    public var hasCompoundRequest: Bool {
        requests.hasCompoundRequest
    }

    /// Which segmentation types are available on this system.
    public var availableTypes: Set<SegmentationType> {
        requests.availableTypes()
    }

    // MARK: - Full isolation

    /// Isolate all subjects in the image.
    /// Returns per-instance masks, contour paths, and optional semantic masks.
    public func isolate(
        image: CGImage,
        options: IsolationOptions = .default
    ) async throws -> IsolationResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.isolateSync(image: image, options: options)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Convenience methods

    /// Person-only segmentation at a specific quality level.
    public func segmentPersons(
        image: CGImage,
        quality: SegmentationQuality = .balanced
    ) async throws -> PersonSegmentationResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.segmentPersonsSync(image: image, quality: quality)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Quick foreground mask (all subjects combined, no per-instance breakdown).
    public func foregroundMask(image: CGImage) async throws -> CGImage {
        let result = try await isolate(image: image, options: IsolationOptions(
            requestedTypes: [.foregroundInstance],
            generatePaths: false
        ))
        guard let mask = result.foregroundMask else {
            throw IsolationError.noSubjectsDetected
        }
        return mask
    }

    /// Remove background around people — returns people on transparent background.
    public func removeBackground(
        image: CGImage,
        quality: SegmentationQuality = .accurate
    ) async throws -> CGImage {
        let personResult = try await segmentPersons(image: image, quality: quality)
        guard let mask = personResult.mask else {
            throw IsolationError.noSubjectsDetected
        }
        guard personResult.personDetected else {
            throw IsolationError.noSubjectsDetected
        }
        guard let cutout = processor.applyMask(image: image, mask: mask) else {
            throw IsolationError.maskGenerationFailed("Failed to apply mask to image")
        }
        return cutout
    }

    // MARK: - Sync implementations

    private func isolateSync(image: CGImage, options: IsolationOptions) throws -> IsolationResult {
        let imageSize = CGSize(width: image.width, height: image.height)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        // 1. Run foreground instance mask (primary path)
        let fgRequest = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([fgRequest])

        guard let observation = fgRequest.results?.first else {
            return IsolationResult(
                subjects: [],
                foregroundMask: nil,
                semanticMasks: [:],
                imageSize: imageSize
            )
        }

        // 2. Build per-instance subjects
        var subjects: [SubjectInstance] = []
        for instanceIdx in observation.allInstances {
            guard let maskBuffer = try? observation.generateScaledMaskForImage(
                forInstances: IndexSet(integer: instanceIdx),
                from: handler
            ) else { continue }

            guard let maskImage = processor.pixelBufferToCGImage(maskBuffer) else { continue }

            var contourPath: CGPath?
            var outerPath: CGPath?
            var bbox = CGRect.zero

            if options.generatePaths {
                let contours = tracer.traceContours(
                    mask: maskImage,
                    simplification: options.contourSimplification
                )
                contourPath = contours.full
                outerPath = contours.outer
            }

            bbox = tracer.boundingBox(of: maskImage)

            subjects.append(SubjectInstance(
                index: instanceIdx,
                mask: maskImage,
                boundingBox: bbox,
                contourPath: contourPath,
                outerContourPath: outerPath
            ))
        }

        // 3. Build combined foreground mask
        let foregroundMask = processor.combineMasks(subjects.map(\.mask))

        // 4. Run semantic masks if requested
        var semanticMasks: [SegmentationType: CGImage] = [:]
        let semanticTypes = options.requestedTypes.subtracting([.foregroundInstance])
        if !semanticTypes.isEmpty {
            let vnRequests = requests.buildRequests(for: semanticTypes, quality: .balanced)
            if !vnRequests.isEmpty {
                try? handler.perform(vnRequests)
                if semanticTypes.contains(.personInstance),
                   let personInstanceMask = extractPersonInstanceMask(
                    from: vnRequests,
                    handler: handler
                   ) {
                    semanticMasks[.personInstance] = personInstanceMask
                }

                let buffers = requests.extractSemanticMasks(from: vnRequests, types: semanticTypes)
                for (type, buffer) in buffers {
                    if let cgImage = processor.pixelBufferToCGImage(buffer) {
                        semanticMasks[type] = cgImage
                    }
                }
            }
        }

        return IsolationResult(
            subjects: subjects,
            foregroundMask: foregroundMask,
            semanticMasks: semanticMasks,
            imageSize: imageSize
        )
    }

    private func extractPersonInstanceMask(
        from vnRequests: [VNRequest],
        handler: VNImageRequestHandler
    ) -> CGImage? {
        for request in vnRequests {
            guard request is VNGeneratePersonInstanceMaskRequest,
                  let observation = request.results?.first as? VNInstanceMaskObservation,
                  !observation.allInstances.isEmpty else {
                continue
            }

            guard let maskBuffer = try? observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            ) else {
                continue
            }

            return processor.pixelBufferToCGImage(maskBuffer)
        }

        return nil
    }

    private func segmentPersonsSync(image: CGImage, quality: SegmentationQuality) throws -> PersonSegmentationResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = mapPersonSegmentationQuality(quality)
        try handler.perform([request])

        guard let result = request.results?.first else {
            return PersonSegmentationResult(mask: nil, personDetected: false, quality: quality)
        }

        let ciImage = CIImage(cvPixelBuffer: result.pixelBuffer)
        let cgMask = processor.ciContext.createCGImage(ciImage, from: ciImage.extent)

        return PersonSegmentationResult(
            mask: cgMask,
            personDetected: cgMask.map {
                processor.containsForeground($0, threshold: Self.personDetectionMaskThreshold)
            } ?? false,
            quality: quality
        )
    }

    private func mapPersonSegmentationQuality(
        _ quality: SegmentationQuality
    ) -> VNGeneratePersonSegmentationRequest.QualityLevel {
        switch quality {
        case .fast: return .fast
        case .balanced: return .balanced
        case .accurate: return .accurate
        }
    }
}
