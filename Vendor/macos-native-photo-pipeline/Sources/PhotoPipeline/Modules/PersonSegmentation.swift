import Foundation
import CoreGraphics
import Vision
import CoreImage

/// Person/background segmentation and background removal using public Vision APIs.
///
/// - `VNGeneratePersonSegmentationRequest` — person mask at configurable quality levels.
/// - `VNGenerateForegroundInstanceMaskRequest` — per-instance subject masks (macOS 14+).
///
/// ```swift
/// let segmenter = PersonSegmentation()
/// let result = try await segmenter.generateMask(image: cgImage, quality: .balanced)
/// if let mask = result.mask {
///     // mask is a grayscale CGImage — white = person, black = background
/// }
///
/// let cutout = try await segmenter.removeBackground(image: cgImage)
/// // cutout has transparent background
/// ```
public final class PersonSegmentation: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.photopipeline.segmentation", qos: .userInitiated)

    public enum Quality: Int, Sendable {
        case fast = 0       // VNGeneratePersonSegmentationRequest.QualityLevel.fast
        case balanced = 1   // .balanced
        case accurate = 2   // .accurate
    }

    public init() {}

    /// Generate a person mask for the image.
    public func generateMask(image: CGImage, quality: Quality = .balanced) async throws -> SegmentationResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.generateMaskSync(image: image, quality: quality)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Remove background — returns subject on transparent background.
    public func removeBackground(image: CGImage, quality: Quality = .accurate) async throws -> CGImage {
        let result = try await generateMask(image: image, quality: quality)
        guard let mask = result.mask else {
            throw FrameworkError.invocationFailed("No mask generated")
        }
        return applyMask(image: image, mask: mask)
    }

    /// Generate foreground instance masks (Copy Subject feature, macOS 14+).
    public func generateInstanceMasks(image: CGImage) async throws -> [InstanceMask] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.generateInstanceMasksSync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Sync implementations

    private func generateMaskSync(image: CGImage, quality: Quality) throws -> SegmentationResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = VNGeneratePersonSegmentationRequest.QualityLevel(rawValue: UInt(quality.rawValue)) ?? .balanced
        try handler.perform([request])

        guard let result = request.results?.first else {
            return SegmentationResult(mask: nil, personCount: 0, quality: quality)
        }

        let maskImage = result.pixelBuffer
        let ciImage = CIImage(cvPixelBuffer: maskImage)
        let context = CIContext()
        let cgMask = context.createCGImage(ciImage, from: ciImage.extent)

        return SegmentationResult(mask: cgMask, personCount: 1, quality: quality)
    }

    private func generateInstanceMasksSync(image: CGImage) throws -> [InstanceMask] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])

        guard let result = request.results?.first else { return [] }

        var masks: [InstanceMask] = []
        let allInstances = result.allInstances

        for instance in allInstances {
            if let maskBuffer = try? result.generateMaskedImage(ofInstances: [instance], from: handler, croppedToInstancesExtent: false) {
                let ciImage = CIImage(cvPixelBuffer: maskBuffer)
                let context = CIContext()
                if let cgMask = context.createCGImage(ciImage, from: ciImage.extent) {
                    masks.append(InstanceMask(instanceIndex: instance, mask: cgMask))
                }
            }
        }

        return masks
    }

    // MARK: - Mask application

    private func applyMask(image: CGImage, mask: CGImage) -> CGImage {
        let ciImage = CIImage(cgImage: image)
        let ciMask = CIImage(cgImage: mask)
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(image.width) / CGFloat(mask.width),
                y: CGFloat(image.height) / CGFloat(mask.height)
            ))

        let filter = CIFilter(name: "CIBlendWithMask")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        filter.setValue(ciMask, forKey: kCIInputMaskImageKey)

        let context = CIContext()
        return context.createCGImage(filter.outputImage!, from: ciImage.extent)!
    }
}

// MARK: - Result types

/// Result of person segmentation — mask is nil if no person detected.
public struct SegmentationResult: @unchecked Sendable {
    public let mask: CGImage?
    public let personCount: Int
    public let quality: PersonSegmentation.Quality
}

/// A single foreground instance mask from VNGenerateForegroundInstanceMaskRequest.
public struct InstanceMask: @unchecked Sendable {
    public let instanceIndex: Int
    public let mask: CGImage
}

/// Storable metadata from segmentation (excludes the mask CGImage).
public struct SegmentationMetadata: Codable, Sendable {
    public let personDetected: Bool
    public let qualityLevel: Int  // PersonSegmentation.Quality raw value

    public init(personDetected: Bool, qualityLevel: Int) {
        self.personDetected = personDetected
        self.qualityLevel = qualityLevel
    }
}
