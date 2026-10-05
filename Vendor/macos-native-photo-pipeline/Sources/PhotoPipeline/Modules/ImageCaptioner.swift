import Foundation
import CoreGraphics
import Vision

public final class ImageCaptioner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.photopipeline.caption", qos: .userInitiated)

    public init() {}

    /// Generate a text caption/description of an image.
    public func caption(image: CGImage) async throws -> CaptionResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.captionSync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func captionSync(image: CGImage) throws -> CaptionResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        // Gather scene labels
        let sceneRequest = VNClassifyImageRequest()
        try? handler.perform([sceneRequest])
        let sceneLabels = (sceneRequest.results ?? [])
            .filter { $0.confidence > 0.3 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)
            .map { $0.identifier }

        // Detect faces
        let faceRequest = VNDetectFaceRectanglesRequest()
        try? handler.perform([faceRequest])
        let faceCount = faceRequest.results?.count ?? 0

        // Detect animals
        let animalRequest = VNRecognizeAnimalsRequest()
        try? handler.perform([animalRequest])
        let animals = (animalRequest.results ?? []).flatMap { obs in
            obs.labels.map { $0.identifier }
        }

        // Detect text
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        try? handler.perform([textRequest])
        let hasText = !(textRequest.results ?? []).isEmpty

        // Build descriptive caption from components
        var parts: [String] = []

        if !sceneLabels.isEmpty {
            let cleanLabels = sceneLabels.map { $0.replacingOccurrences(of: "_", with: " ") }
            parts.append(cleanLabels.joined(separator: ", "))
        }

        if faceCount > 0 {
            parts.append(faceCount == 1 ? "1 person" : "\(faceCount) people")
        }

        if !animals.isEmpty {
            parts.append(animals.joined(separator: ", "))
        }

        if hasText {
            parts.append("contains text")
        }

        let caption = parts.isEmpty ? "Image" : parts.joined(separator: " \u{2014} ")

        return CaptionResult(
            caption: caption,
            sceneLabels: Array(sceneLabels),
            faceCount: faceCount,
            animals: animals,
            hasText: hasText,
            source: .composed
        )
    }
}

public struct CaptionResult: Codable, Sendable {
    public let caption: String
    public let sceneLabels: [String]
    public let faceCount: Int
    public let animals: [String]
    public let hasText: Bool
    public let source: Source

    public enum Source: String, Codable, Sendable {
        case composed    // built from scene + face + animal + text detection
        case neural      // from Apple's captioning model (future)
    }
}
