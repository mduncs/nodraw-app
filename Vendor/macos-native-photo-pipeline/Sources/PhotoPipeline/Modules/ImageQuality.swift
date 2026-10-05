import Foundation
import CoreGraphics
import Vision

/// Image quality assessment — blur, exposure, and lens smudge detection.
///
/// Tries private VNRequest subclasses first (same as Photos.app):
/// - `VNImageBlurScoreRequest` → blur/sharpness score
/// - `VNImageExposureScoreRequest` → exposure level
/// - `VNDetectLensSmudgeRequest` → lens smudge detection
///
/// Falls back to public Vision APIs (saliency-based heuristics) when
/// private classes aren't available.
///
/// ```swift
/// let quality = ImageQuality()
/// let result = try await quality.assess(image: cgImage)
/// print("Sharp: \(result.isSharp), blur: \(result.blurScore ?? -1)")
/// print("Well exposed: \(result.isWellExposed)")
/// ```
public final class ImageQuality: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.photopipeline.quality", qos: .userInitiated)
    private let blurRequestClass: AnyClass?
    private let exposureRequestClass: AnyClass?
    private let smudgeRequestClass: AnyClass?

    public init() {
        self.blurRequestClass = NSClassFromString("VNImageBlurScoreRequest")
        self.exposureRequestClass = NSClassFromString("VNImageExposureScoreRequest")
        self.smudgeRequestClass = NSClassFromString("VNDetectLensSmudgeRequest")
    }

    /// Whether blur scoring is available via private API.
    public var hasBlurScoring: Bool { blurRequestClass != nil }

    /// Whether exposure scoring is available via private API.
    public var hasExposureScoring: Bool { exposureRequestClass != nil }

    /// Whether lens smudge detection is available via private API.
    public var hasSmudgeDetection: Bool { smudgeRequestClass != nil }

    /// Assess image quality across all available dimensions.
    public func assess(image: CGImage) async throws -> QualityResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.assessSync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Sync implementation

    private func assessSync(image: CGImage) throws -> QualityResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        var blurScore: Float?
        var exposureScore: Float?
        var hasSmudge: Bool?

        // Blur (try private API, fall back to saliency heuristic)
        if let cls = blurRequestClass, let req = createVNRequest(cls) {
            try? handler.perform([req])
            if let results = req.results, let first = results.first {
                // Try VNClassificationObservation
                if let classObs = first as? VNClassificationObservation {
                    blurScore = classObs.confidence
                } else {
                    // KVC fallback — private observations may use various property names
                    // Must check responds(to:) first to avoid NSUnknownKeyException crashes
                    blurScore = safeFloatFromObservation(first, keys: ["score", "blurScore", "confidence"])
                }
            }
        }
        if blurScore == nil {
            blurScore = computeBlurFallback(image: image, handler: handler)
        }

        // Exposure (private API only, nil if unavailable)
        if let cls = exposureRequestClass, let req = createVNRequest(cls) {
            try? handler.perform([req])
            if let results = req.results, let first = results.first {
                if let classObs = first as? VNClassificationObservation {
                    exposureScore = classObs.confidence
                } else {
                    exposureScore = safeFloatFromObservation(first, keys: ["score", "exposureScore", "confidence"])
                }
            }
        }

        // Lens smudge (private API only, nil if unavailable)
        if let cls = smudgeRequestClass, let req = createVNRequest(cls) {
            try? handler.perform([req])
            if let results = req.results, let first = results.first {
                if let classObs = first as? VNClassificationObservation {
                    hasSmudge = classObs.identifier.lowercased().contains("smudge") && classObs.confidence > 0.5
                } else {
                    // KVC fallback — check for boolean or confidence-based result
                    let nsObj = first as NSObject
                    if nsObj.responds(to: Selector(("detected"))),
                       let detected = nsObj.value(forKey: "detected") as? Bool {
                        hasSmudge = detected
                    } else if let conf = safeFloatFromObservation(first, keys: ["confidence"]) {
                        hasSmudge = conf > 0.5
                    } else if nsObj.responds(to: Selector(("identifier"))),
                              let label = nsObj.value(forKey: "identifier") as? String {
                        hasSmudge = label.lowercased().contains("smudge")
                    }
                }
            }
        }

        let isSharp = (blurScore ?? 0.5) < 0.5
        let isWellExposed = exposureScore.map { $0 > 0.3 && $0 < 0.8 } ?? true

        return QualityResult(
            blurScore: blurScore,
            exposureScore: exposureScore,
            hasLensSmudge: hasSmudge,
            isSharp: isSharp,
            isWellExposed: isWellExposed
        )
    }

    // MARK: - Fallback blur estimation

    /// Estimate blur using objectness saliency as a proxy.
    /// Sharp images produce more confident, well-defined salient regions.
    /// Blurry images produce diffuse, low-confidence saliency.
    private func computeBlurFallback(image: CGImage, handler: VNImageRequestHandler) -> Float {
        let req = VNGenerateObjectnessBasedSaliencyImageRequest()
        try? handler.perform([req])

        guard let result = req.results?.first,
              let salientObjects = result.salientObjects, !salientObjects.isEmpty else {
            return 0.5  // unknown — return midpoint
        }

        // Higher max saliency confidence = sharper image (heuristic)
        let maxConf = salientObjects.map(\.confidence).max() ?? 0
        // Invert: high saliency confidence → low blur score
        return 1.0 - maxConf
    }

    // MARK: - Safe KVC helpers

    /// Safely extract a Float from a private VNObservation by trying multiple key names.
    /// Uses `responds(to:)` to avoid NSUnknownKeyException crashes.
    private func safeFloatFromObservation(_ observation: VNObservation, keys: [String]) -> Float? {
        let nsObj = observation as NSObject
        for key in keys {
            if nsObj.responds(to: Selector((key))),
               let num = nsObj.value(forKey: key) as? NSNumber {
                return num.floatValue
            }
        }
        return nil
    }

    // MARK: - Private VNRequest helpers

    /// Create a VNRequest from a private class via alloc/init.
    private func createVNRequest(_ cls: AnyClass) -> VNRequest? {
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("init")

        guard cls.responds(to: allocSel),
              let allocated = (cls as AnyObject).perform(allocSel)?.takeUnretainedValue(),
              let request = allocated.perform(initSel)?.takeUnretainedValue() as? VNRequest else {
            return nil
        }
        return request
    }
}

// MARK: - Result types

public struct QualityResult: Codable, Sendable {
    /// Blur score (0.0 = sharp, 1.0 = blurry). nil if unavailable.
    public let blurScore: Float?
    /// Exposure score (0.0 = dark, 1.0 = bright). nil if unavailable.
    public let exposureScore: Float?
    /// Whether lens smudge was detected. nil if unavailable.
    public let hasLensSmudge: Bool?
    /// Derived: image is considered sharp (blurScore < 0.5 or unknown).
    public let isSharp: Bool
    /// Derived: image is considered well-exposed (exposure 0.3–0.8 or unknown).
    public let isWellExposed: Bool
}
