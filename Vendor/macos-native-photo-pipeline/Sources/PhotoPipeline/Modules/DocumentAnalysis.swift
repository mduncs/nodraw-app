import Foundation
import CoreGraphics
import Vision

/// Document detection and rectangle finding using public Vision APIs.
///
/// - `VNDetectDocumentSegmentationRequest` — precise document boundary detection.
/// - `VNDetectRectanglesRequest` — general rectangle/card detection.
///
/// ```swift
/// let analyzer = DocumentAnalysis()
/// let docs = try await analyzer.detectDocuments(image: cgImage)
/// for doc in docs {
///     print("Document at \(doc.boundingBox) confidence=\(doc.confidence)")
/// }
///
/// let rects = try await analyzer.detectRectangles(image: cgImage, maxCount: 5)
/// // rects include corner points for perspective correction
/// ```
public final class DocumentAnalysis: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.photopipeline.document", qos: .userInitiated)

    public init() {}

    /// Detect document boundaries in an image.
    public func detectDocuments(image: CGImage) async throws -> [DetectedDocument] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let results = try self.detectDocumentsSync(image: image)
                    cont.resume(returning: results)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Detect rectangles (for documents, cards, etc.).
    public func detectRectangles(image: CGImage, maxCount: Int = 10) async throws -> [DetectedRectangle] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let results = try self.detectRectanglesSync(image: image, maxCount: maxCount)
                    cont.resume(returning: results)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Sync implementations

    private func detectDocumentsSync(image: CGImage) throws -> [DetectedDocument] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectDocumentSegmentationRequest()
        try handler.perform([request])

        return (request.results ?? []).map { obs in
            DetectedDocument(
                boundingBox: obs.boundingBox,
                topLeft: obs.topLeft,
                topRight: obs.topRight,
                bottomLeft: obs.bottomLeft,
                bottomRight: obs.bottomRight,
                confidence: obs.confidence
            )
        }
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

// MARK: - Result types

/// A detected document with corner points in Vision normalized coordinates (0-1, origin bottom-left).
public struct DetectedDocument: Codable, Sendable {
    public let boundingBox: CGRect
    public let topLeft: CGPoint
    public let topRight: CGPoint
    public let bottomLeft: CGPoint
    public let bottomRight: CGPoint
    public let confidence: Float
}

/// A detected rectangle with corner points in Vision normalized coordinates.
public struct DetectedRectangle: Codable, Sendable {
    public let boundingBox: CGRect
    public let topLeft: CGPoint
    public let topRight: CGPoint
    public let bottomLeft: CGPoint
    public let bottomRight: CGPoint
    public let confidence: Float
}
