import Foundation
import Vision
import CoreVideo
import os.log

/// Manages Vision request construction, including runtime probing for private segmentation APIs.
/// Probes for private classes once at init, caches availability, and builds the minimal set
/// of VNRequests needed for a given `Set<SegmentationType>`.
internal final class SegmentationRequests: @unchecked Sendable {

    private static let logger = Logger(
        subsystem: "SubjectIsolation",
        category: "SegmentationRequests"
    )

    // MARK: - Private class references (probed at init)

    /// Single-pass multi-head segmentation (private, macOS 15+).
    /// Stored for availability check; NOT used for orchestration (individual requests only).
    private let compoundRequestClass: AnyClass?

    /// Sky region mask (private/macOS 15+).
    private let skyRequestClass: AnyClass?

    /// Glasses region mask (private/macOS 15+).
    private let glassesRequestClass: AnyClass?

    /// Hair/skin/clothing attribute regions (private/macOS 15+).
    private let humanAttributesRequestClass: AnyClass?

    /// Animal segmentation (private/macOS 15+).
    private let animalRequestClass: AnyClass?

    // MARK: - Init

    init() {
        self.compoundRequestClass = NSClassFromString(
            "VNGenerateSemanticSegmentationCompoundRequest"
        )
        self.skyRequestClass = NSClassFromString(
            "VNGenerateSkySegmentationRequest"
        )
        self.glassesRequestClass = NSClassFromString(
            "VNGenerateGlassesSegmentationRequest"
        )
        self.humanAttributesRequestClass = NSClassFromString(
            "VNGenerateHumanAttributesSegmentationRequest"
        )
        self.animalRequestClass = NSClassFromString(
            "VNGenerateAnimalSegmentationRequest"
        )

        let probeResult = [
            "compound": self.compoundRequestClass != nil,
            "sky": self.skyRequestClass != nil,
            "glasses": self.glassesRequestClass != nil,
            "humanAttributes": self.humanAttributesRequestClass != nil,
            "animal": self.animalRequestClass != nil,
        ].filter(\.value).map(\.key).joined(separator: ", ")
        Self.logger.debug("Private classes found: \(probeResult.isEmpty ? "none" : probeResult)")
    }

    // MARK: - Availability

    /// Whether the compound multi-head request class was found at runtime.
    var hasCompoundRequest: Bool {
        compoundRequestClass != nil
    }

    /// Returns the set of segmentation types available on this OS version.
    /// Public types are always available (macOS 14+). Private types depend on class probing.
    func availableTypes() -> Set<SegmentationType> {
        var available: Set<SegmentationType> = [
            .foregroundInstance,
            .personInstance,
            .personSegmentation,
        ]
        if skyRequestClass != nil { available.insert(.sky) }
        if glassesRequestClass != nil { available.insert(.glasses) }
        if humanAttributesRequestClass != nil { available.insert(.humanAttributes) }
        if animalRequestClass != nil { available.insert(.animal) }
        return available
    }

    // MARK: - Request Building

    /// Build the minimal set of VNRequests for the requested segmentation types.
    ///
    /// Public types always produce a request. Private types are silently skipped
    /// if the runtime class wasn't found (caller should check `availableTypes()` first
    /// if they need to know what will actually run).
    ///
    /// - Parameters:
    ///   - types: Segmentation types to build requests for.
    ///   - quality: Quality level (currently only affects person segmentation).
    /// - Returns: Array of configured VNRequest objects ready for VNImageRequestHandler.
    func buildRequests(
        for types: Set<SegmentationType>,
        quality: SegmentationQuality
    ) -> [VNRequest] {
        var requests: [VNRequest] = []

        for type in types {
            switch type {
            case .foregroundInstance:
                requests.append(VNGenerateForegroundInstanceMaskRequest())

            case .personInstance:
                requests.append(VNGeneratePersonInstanceMaskRequest())

            case .personSegmentation:
                let request = VNGeneratePersonSegmentationRequest()
                request.qualityLevel = mapQuality(quality)
                requests.append(request)

            case .sky:
                if let req = createPrivateRequest(skyRequestClass, label: "Sky") {
                    requests.append(req)
                }

            case .glasses:
                if let req = createPrivateRequest(glassesRequestClass, label: "Glasses") {
                    requests.append(req)
                }

            case .humanAttributes:
                if let req = createPrivateRequest(
                    humanAttributesRequestClass, label: "HumanAttributes"
                ) {
                    requests.append(req)
                }

            case .animal:
                if let req = createPrivateRequest(animalRequestClass, label: "Animal") {
                    requests.append(req)
                }
            }
        }

        Self.logger.debug("Built \(requests.count) request(s) for \(types.count) type(s)")
        return requests
    }

    // MARK: - Result Extraction

    /// Maps request class name to SegmentationType for result extraction.
    private static let classNameToType: [String: SegmentationType] = [
        "VNGenerateSkySegmentationRequest": .sky,
        "VNGenerateGlassesSegmentationRequest": .glasses,
        "VNGenerateHumanAttributesSegmentationRequest": .humanAttributes,
        "VNGenerateAnimalSegmentationRequest": .animal,
    ]

    /// Extract semantic pixel buffer masks from completed Vision requests.
    ///
    /// Walks each request's results looking for `VNPixelBufferObservation` and maps
    /// it back to the originating `SegmentationType`.
    ///
    /// Person segmentation results are included (as `VNPixelBufferObservation`).
    /// Foreground/person instance masks use `VNInstanceMaskObservation` and are
    /// extracted by `SubjectIsolator` because they require the original image handler.
    ///
    /// - Parameters:
    ///   - requests: Completed VNRequest array (after `perform()`).
    ///   - types: The types that were originally requested, for filtering.
    /// - Returns: Dictionary mapping type to raw CVPixelBuffer mask.
    func extractSemanticMasks(
        from requests: [VNRequest],
        types: Set<SegmentationType>
    ) -> [SegmentationType: CVPixelBuffer] {
        var masks: [SegmentationType: CVPixelBuffer] = [:]

        for request in requests {
            guard let results = request.results, !results.isEmpty else { continue }

            let segType = resolveType(for: request)
            guard let segType, types.contains(segType) else { continue }

            // VNPixelBufferObservation is the standard result type for semantic masks.
            if let observation = results.first as? VNPixelBufferObservation {
                masks[segType] = observation.pixelBuffer
            }
        }

        Self.logger.debug("Extracted \(masks.count) semantic mask(s)")
        return masks
    }

    // MARK: - Private Helpers

    /// Create a VNRequest from a private class via ObjCBridge.
    /// Returns nil if the class is nil or creation fails.
    private func createPrivateRequest(_ cls: AnyClass?, label: String) -> VNRequest? {
        guard let cls else {
            Self.logger.debug("\(label) request class not available, skipping")
            return nil
        }
        guard let obj = ObjCBridge.create(cls), let request = obj as? VNRequest else {
            Self.logger.warning("Failed to create \(label) request from \(String(describing: cls))")
            return nil
        }
        return request
    }

    /// Map SegmentationQuality to VNGeneratePersonSegmentationRequest.QualityLevel.
    private func mapQuality(
        _ quality: SegmentationQuality
    ) -> VNGeneratePersonSegmentationRequest.QualityLevel {
        switch quality {
        case .fast:     return .fast
        case .balanced: return .balanced
        case .accurate: return .accurate
        }
    }

    /// Resolve which SegmentationType a completed VNRequest corresponds to.
    private func resolveType(for request: VNRequest) -> SegmentationType? {
        // Public types: match on concrete Swift type.
        switch request {
        case is VNGeneratePersonSegmentationRequest:
            return .personSegmentation
        case is VNGenerateForegroundInstanceMaskRequest:
            return .foregroundInstance
        case is VNGeneratePersonInstanceMaskRequest:
            return .personInstance
        default:
            break
        }

        // Private types: match on ObjC class name.
        let className = NSStringFromClass(type(of: request))
        return Self.classNameToType[className]
    }
}
