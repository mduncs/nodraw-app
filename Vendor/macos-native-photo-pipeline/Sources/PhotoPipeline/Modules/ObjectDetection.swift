import Foundation
import CoreGraphics
import Vision

public final class ObjectDetection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.photopipeline.detection", qos: .userInitiated)

    public init() {}

    /// Detect the horizon line in an image.
    public func detectHorizon(image: CGImage) async throws -> HorizonResult? {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.detectHorizonSync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Detect contours (edges/outlines) in an image.
    public func detectContours(image: CGImage) async throws -> ContourResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.detectContoursSync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Detect rectangles in an image.
    public func detectRectangles(image: CGImage, maxCount: Int = 10) async throws -> [DetectedRectangle] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.detectRectanglesSync(image: image, maxCount: maxCount)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func detectHorizonSync(image: CGImage) throws -> HorizonResult? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectHorizonRequest()
        try handler.perform([request])

        guard let result = request.results?.first else { return nil }
        return HorizonResult(angle: Float(result.angle), transform: result.transform)
    }

    private func detectContoursSync(image: CGImage) throws -> ContourResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.0
        try handler.perform([request])

        guard let result = request.results?.first else {
            return ContourResult(contourCount: 0, topLevelContourCount: 0)
        }

        return ContourResult(
            contourCount: result.contourCount,
            topLevelContourCount: result.topLevelContourCount
        )
    }

    private func detectRectanglesSync(image: CGImage, maxCount: Int) throws -> [DetectedRectangle] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = maxCount
        request.minimumConfidence = 0.3
        try handler.perform([request])

        return (request.results ?? []).map { obs in
            DetectedRectangle(
                boundingBox: obs.boundingBox,
                topLeft: obs.topLeft,
                topRight: obs.topRight,
                bottomLeft: obs.bottomLeft,
                bottomRight: obs.bottomRight,
                confidence: obs.confidence
            )
        }
    }
}

public struct HorizonResult: Sendable {
    public let angle: Float  // radians
    public let transform: CGAffineTransform

    /// Angle in degrees.
    public var angleDegrees: Float { angle * 180 / .pi }
}

extension HorizonResult: Codable {
    enum CodingKeys: String, CodingKey {
        case angle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.angle = try c.decode(Float.self, forKey: .angle)
        self.transform = CGAffineTransform(rotationAngle: CGFloat(self.angle))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(angle, forKey: .angle)
    }
}

public struct ContourResult: Codable, Sendable {
    public let contourCount: Int
    public let topLevelContourCount: Int
}
