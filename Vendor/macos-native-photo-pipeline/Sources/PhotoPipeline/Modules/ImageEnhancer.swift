import Foundation
import CoreGraphics
import CoreImage
import Vision

public final class ImageEnhancer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.photopipeline.enhance", qos: .userInitiated)
    private let context = CIContext()

    public init() {}

    /// Auto-enhance an image using CoreImage filters.
    public func autoEnhance(image: CGImage) async throws -> CGImage {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.autoEnhanceSync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Upscale an image by a given factor (2x, 3x, 4x).
    /// Uses CILanczosScaleTransform for quality upscaling.
    public func upscale(image: CGImage, factor: Float = 2.0) async throws -> CGImage {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.upscaleSync(image: image, factor: factor)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Adjust white balance automatically.
    public func autoWhiteBalance(image: CGImage) async throws -> CGImage {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.autoWhiteBalanceSync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func autoEnhanceSync(image: CGImage) throws -> CGImage {
        var ciImage = CIImage(cgImage: image)

        // Use CoreImage's auto-enhancement
        let adjustments = ciImage.autoAdjustmentFilters()
        for filter in adjustments {
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            if let output = filter.outputImage {
                ciImage = output
            }
        }

        guard let result = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw FrameworkError.invocationFailed("Failed to render enhanced image")
        }
        return result
    }

    private func upscaleSync(image: CGImage, factor: Float) throws -> CGImage {
        let ciImage = CIImage(cgImage: image)

        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            throw FrameworkError.invocationFailed("CILanczosScaleTransform not available")
        }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(factor, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let output = filter.outputImage,
              let result = context.createCGImage(output, from: output.extent) else {
            throw FrameworkError.invocationFailed("Failed to upscale image")
        }
        return result
    }

    private func autoWhiteBalanceSync(image: CGImage) throws -> CGImage {
        let ciImage = CIImage(cgImage: image)

        guard let filter = CIFilter(name: "CITemperatureAndTint") else {
            throw FrameworkError.invocationFailed("CITemperatureAndTint not available")
        }

        // Use auto-neutral as target
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")       // daylight neutral
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")

        guard let output = filter.outputImage,
              let result = context.createCGImage(output, from: output.extent) else {
            throw FrameworkError.invocationFailed("Failed to adjust white balance")
        }
        return result
    }
}
