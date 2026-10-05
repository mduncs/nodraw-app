import Foundation
import CoreGraphics
import Vision

/// Junk image classification using the same VNClassifyJunkImageRequest that
/// Photos.app uses internally.
///
/// Returns a raw confidence float (0.0–1.0) where higher = more likely junk.
/// Photos uses this as the `globalQuality` gate in curation scoring:
/// if junkConfidence < 0.5, the image is considered junk and gets a curation
/// score of 0.0.
///
/// ```swift
/// let classifier = JunkClassifier()
/// let result = try await classifier.classify(image: cgImage)
/// print("Junk confidence: \(result.confidence)")  // 0.0–1.0
/// print("Is junk: \(result.isJunk)")               // confidence < 0.5
/// ```
public final class JunkClassifier: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.photopipeline.junk", qos: .userInitiated)
    private let junkRequestClass: AnyClass?

    public init() {
        // VNClassifyJunkImageRequest — exists in Vision.framework on macOS 14+
        // Not in public headers but accessible at runtime
        self.junkRequestClass = NSClassFromString("VNClassifyJunkImageRequest")
    }

    /// Whether the junk classifier is available on this system.
    public var isAvailable: Bool { junkRequestClass != nil }

    /// Classify an image for junk/quality.
    ///
    /// Returns a `JunkResult` with the raw confidence and derived flags.
    /// Uses VNClassifyJunkImageRequest when available, falls back to
    /// heuristic quality estimation.
    public func classify(image: CGImage) async throws -> JunkResult {
        if junkRequestClass != nil {
            return try await classifyPrivate(image: image)
        }
        return try await classifyFallback(image: image)
    }

    // MARK: - Private API path (VNClassifyJunkImageRequest)

    private func classifyPrivate(image: CGImage) async throws -> JunkResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.classifyPrivateSync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func classifyPrivateSync(image: CGImage) throws -> JunkResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        // Create VNClassifyJunkImageRequest via runtime
        guard let cls = junkRequestClass else {
            throw FrameworkError.classNotFound("VNClassifyJunkImageRequest", framework: "Vision")
        }

        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("init")

        guard cls.responds(to: allocSel),
              let allocated = (cls as AnyObject).perform(allocSel)?.takeUnretainedValue(),
              let request = allocated.perform(initSel)?.takeUnretainedValue() as? VNRequest else {
            throw FrameworkError.invocationFailed("Failed to create VNClassifyJunkImageRequest")
        }

        // Match Photos' internal behavior
        if request.responds(to: NSSelectorFromString("setPreferBackgroundProcessing:")) {
            request.setValue(true, forKey: "preferBackgroundProcessing")
        }

        try handler.perform([request])

        // Expect exactly 1 VNClassificationObservation
        guard let results = request.results as? [VNClassificationObservation],
              let observation = results.first else {
            // No result = assume not junk
            return JunkResult(confidence: 1.0, source: .privateAPI)
        }

        return JunkResult(confidence: observation.confidence, source: .privateAPI)
    }

    // MARK: - Fallback (public API heuristics)

    /// Approximate junk detection using public Vision APIs:
    /// - Face capture quality (blurry/occluded faces → lower quality)
    /// - Image classification (screenshots, documents → utility)
    /// - Saliency (no salient regions → likely junk)
    private func classifyFallback(image: CGImage) async throws -> JunkResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.classifyFallbackSync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func classifyFallbackSync(image: CGImage) throws -> JunkResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var qualitySignals: [Float] = []

        // Signal 1: Saliency — images with no salient objects are more likely junk
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([saliencyRequest])
        if let saliencyResult = saliencyRequest.results?.first {
            // Has salient region = probably not junk
            let hasAttention = saliencyResult.salientObjects?.isEmpty == false
            qualitySignals.append(hasAttention ? 0.7 : 0.3)
        }

        // Signal 2: Classification labels — screenshots/docs are utility, not junk per se
        let classifyRequest = VNClassifyImageRequest()
        try? handler.perform([classifyRequest])
        if let observations = classifyRequest.results {
            let topConf = observations.prefix(3).map(\.confidence).max() ?? 0
            // High-confidence classification = image has recognizable content = not junk
            qualitySignals.append(min(topConf + 0.3, 1.0))
        }

        // Combine signals (simple average)
        let avgQuality: Float
        if qualitySignals.isEmpty {
            avgQuality = 0.5 // Unknown — assume borderline
        } else {
            avgQuality = qualitySignals.reduce(0, +) / Float(qualitySignals.count)
        }

        return JunkResult(confidence: avgQuality, source: .heuristic)
    }
}

/// Result from junk classification.
public struct JunkResult: Sendable {
    /// Quality confidence (0.0–1.0). Higher = better quality.
    ///
    /// From VNClassifyJunkImageRequest: this is the raw observation confidence.
    /// From heuristic fallback: averaged quality signals.
    public let confidence: Float

    /// Whether this image is considered junk.
    ///
    /// Uses Photos' threshold: quality < 0.5 = junk.
    public var isJunk: Bool { confidence < 0.5 }

    /// Which classification method was used.
    public let source: Source

    public enum Source: String, Sendable {
        /// VNClassifyJunkImageRequest (same as Photos.app)
        case privateAPI
        /// Public API heuristic approximation
        case heuristic
    }
}
