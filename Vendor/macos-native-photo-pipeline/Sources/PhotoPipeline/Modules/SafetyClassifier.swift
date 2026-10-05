import Foundation
import CoreGraphics
import Vision

/// Content safety classification using public VNClassifyImageRequest.
///
/// Scans classification results for safety-relevant labels (violence, nudity,
/// drugs, etc.) and returns a structured safety assessment.
///
/// Uses public Vision API only — no private classes needed. The taxonomy
/// from VNClassifyImageRequest includes labels that overlap with content
/// safety concerns.
///
/// ```swift
/// let classifier = SafetyClassifier()
/// let result = try await classifier.classify(image: cgImage)
/// print("Safe: \(result.isSafe)")
/// for cat in result.categories {
///     print("  \(cat.label): \(cat.confidence)")
/// }
/// ```
public final class SafetyClassifier: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.photopipeline.safety", qos: .userInitiated)

    /// Labels from Apple's classification taxonomy that indicate sensitive content.
    /// Lowercased, spaces replaced with underscores for matching.
    private let sensitiveLabels: Set<String> = [
        "adult_content", "graphic_violence", "drugs", "weapons",
        "gambling", "hate_symbols", "self_harm", "nudity",
        "suggestive", "violence", "gore"
    ]

    public init() {}

    /// Classify an image for content safety.
    public func classify(image: CGImage) async throws -> SafetyResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.classifySync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Sync implementation

    private func classifySync(image: CGImage) throws -> SafetyResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let request = VNClassifyImageRequest()
        try handler.perform([request])

        guard let results = request.results else {
            return SafetyResult(isSafe: true, categories: [])
        }

        var categories: [SafetyCategory] = []

        for obs in results where obs.confidence > 0.1 {
            let normalized = obs.identifier.lowercased().replacingOccurrences(of: " ", with: "_")
            let isSensitive = sensitiveLabels.contains(normalized)
                || normalized.contains("nsfw")
                || normalized.contains("explicit")
                || normalized.contains("adult")
                || normalized.contains("violen")
                || normalized.contains("nudity")
            if isSensitive {
                categories.append(SafetyCategory(label: obs.identifier, confidence: obs.confidence))
            }
        }

        let sorted = categories.sorted { $0.confidence > $1.confidence }
        let isSafe = sorted.allSatisfy { $0.confidence < 0.5 }
        return SafetyResult(isSafe: isSafe, categories: sorted)
    }
}

// MARK: - Result types

public struct SafetyResult: Codable, Sendable {
    /// Whether the image is considered safe (all sensitive categories below threshold).
    public let isSafe: Bool
    /// Detected sensitive categories sorted by confidence (highest first).
    /// Empty if no sensitive content detected above 0.1 threshold.
    public let categories: [SafetyCategory]
}

public struct SafetyCategory: Codable, Sendable {
    /// The classification label (e.g. "violence", "nudity").
    public let label: String
    /// Confidence score (0.0–1.0).
    public let confidence: Float
}
