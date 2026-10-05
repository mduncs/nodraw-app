import Foundation
import CoreGraphics
import CoreImage
import CoreVideo
import Vision

public final class ImageTracking: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.photopipeline.tracking", qos: .userInitiated)

    public init() {}

    /// Track a rectangle across frames.
    public func trackRectangle(
        observation: VNRectangleObservation,
        in image: CGImage
    ) async throws -> VNRectangleObservation? {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.trackRectangleSync(observation: observation, in: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Track a detected object across frames.
    public func trackObject(
        observation: VNDetectedObjectObservation,
        in image: CGImage
    ) async throws -> VNDetectedObjectObservation? {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.trackObjectSync(observation: observation, in: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Compute optical flow between two frames.
    public func opticalFlow(from frame1: CGImage, to frame2: CGImage) async throws -> OpticalFlowResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.opticalFlowSync(from: frame1, to: frame2)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Register (align) two images using translational model.
    public func alignImages(reference: CGImage, floating: CGImage) async throws -> CGAffineTransform {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let transform = try self.alignSync(reference: reference, floating: floating)
                    cont.resume(returning: transform)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func trackRectangleSync(observation: VNRectangleObservation, in image: CGImage) throws -> VNRectangleObservation? {
        let request = VNTrackRectangleRequest(rectangleObservation: observation)
        request.trackingLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return request.results?.first as? VNRectangleObservation
    }

    private func trackObjectSync(observation: VNDetectedObjectObservation, in image: CGImage) throws -> VNDetectedObjectObservation? {
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return request.results?.first as? VNDetectedObjectObservation
    }

    private func opticalFlowSync(from frame1: CGImage, to frame2: CGImage) throws -> OpticalFlowResult {
        let request = VNGenerateOpticalFlowRequest(targetedCGImage: frame2, options: [:])
        let handler = VNImageRequestHandler(cgImage: frame1, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first else {
            throw FrameworkError.invocationFailed("No optical flow result")
        }

        let pixelBuffer = result.pixelBuffer
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let cgImage = context.createCGImage(ciImage, from: ciImage.extent)

        return OpticalFlowResult(
            flowImage: cgImage,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
    }

    private func alignSync(reference: CGImage, floating: CGImage) throws -> CGAffineTransform {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: floating, options: [:])
        let handler = VNImageRequestHandler(cgImage: reference, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first as? VNImageTranslationAlignmentObservation else {
            throw FrameworkError.invocationFailed("No alignment result")
        }

        return result.alignmentTransform
    }
}

public struct OpticalFlowResult: @unchecked Sendable {
    public let flowImage: CGImage?  // 2-channel flow visualization
    public let width: Int
    public let height: Int
}
