import Foundation
import CoreGraphics
import Vision

/// Perceptual duplicate detection using VNGenerateImageFeaturePrintRequest.
///
/// Uses Apple's neural feature print (same 768-float sceneprint used by
/// Photos.app for similarity search) to fingerprint images and compare them.
///
/// Two modes:
/// - `fingerprint(image:)` → extract a storable fingerprint for batch comparison
/// - `areDuplicates(image1:image2:)` → direct pairwise comparison using
///   VNFeaturePrintObservation's built-in distance computation
///
/// ```swift
/// let detector = DuplicateDetector()
/// let isDup = try await detector.areDuplicates(image1: img1, image2: img2)
/// // or batch:
/// let fp = try await detector.fingerprint(image: img)
/// print("Elements: \(fp.elementCount), bytes: \(fp.data.count)")
/// ```
public final class DuplicateDetector: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.photopipeline.dedup", qos: .userInitiated)

    public init() {}

    /// Extract a storable fingerprint from an image.
    public func fingerprint(image: CGImage) async throws -> ImageFingerprint {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.fingerprintSync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Compare two images directly for duplication.
    ///
    /// - Parameter threshold: Similarity threshold (0.0–1.0). Default 0.95.
    ///   Higher = stricter matching (near-exact duplicates only).
    /// - Returns: `true` if images are considered duplicates.
    public func areDuplicates(image1: CGImage, image2: CGImage, threshold: Float = 0.95) async throws -> Bool {
        let distance = try await computeDistance(image1: image1, image2: image2)
        // VNFeaturePrintObservation.computeDistance returns euclidean distance.
        // Lower distance = more similar. Threshold maps to max acceptable distance.
        // Empirically, near-duplicates have distance < ~5.0, different images > 20.0.
        let maxDistance = (1.0 - threshold) * 100.0
        return distance < maxDistance
    }

    /// Compute raw distance between two images.
    ///
    /// Uses VNFeaturePrintObservation.computeDistance for proper comparison
    /// (same metric Photos.app uses internally).
    /// - Returns: Euclidean distance. Lower = more similar.
    public func computeDistance(image1: CGImage, image2: CGImage) async throws -> Float {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let distance = try self.computeDistanceSync(image1: image1, image2: image2)
                    cont.resume(returning: distance)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Sync implementations

    private func fingerprintSync(image: CGImage) throws -> ImageFingerprint {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateImageFeaturePrintRequest()
        try handler.perform([request])

        guard let result = request.results?.first else {
            throw FrameworkError.invocationFailed("VNGenerateImageFeaturePrintRequest returned no results")
        }

        return ImageFingerprint(
            data: result.data,
            elementCount: result.elementCount,
            elementType: result.elementType.rawValue
        )
    }

    private func computeDistanceSync(image1: CGImage, image2: CGImage) throws -> Float {
        let handler1 = VNImageRequestHandler(cgImage: image1, options: [:])
        let handler2 = VNImageRequestHandler(cgImage: image2, options: [:])
        let req1 = VNGenerateImageFeaturePrintRequest()
        let req2 = VNGenerateImageFeaturePrintRequest()

        try handler1.perform([req1])
        try handler2.perform([req2])

        guard let fp1 = req1.results?.first,
              let fp2 = req2.results?.first else {
            throw FrameworkError.invocationFailed("VNGenerateImageFeaturePrintRequest returned no results for distance computation")
        }

        var distance: Float = 0
        try fp1.computeDistance(&distance, to: fp2)
        return distance
    }
}

// MARK: - Result types

/// Storable image fingerprint extracted from VNFeaturePrintObservation.
///
/// Contains the raw feature print data that can be serialized and compared
/// later without re-running inference.
public struct ImageFingerprint: Codable, Sendable {
    /// Raw feature print bytes.
    public let data: Data
    /// Number of elements in the feature vector (typically 768).
    public let elementCount: Int
    /// VNElementType raw value (typically .float = 1).
    public let elementType: UInt
}
