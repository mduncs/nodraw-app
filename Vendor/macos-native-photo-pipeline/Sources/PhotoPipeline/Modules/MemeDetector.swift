import Foundation
import CoreGraphics
import Vision

/// Meme image detection and indoor/outdoor (city/nature) classification
/// using private VNRequest subclasses.
///
/// - `VNClassifyMemeImageRequest` → meme confidence score
/// - `VNClassifyCityNatureImageRequest` → urban vs nature environment
///
/// Both are private API — gracefully returns defaults when unavailable.
///
/// ```swift
/// let detector = MemeDetector()
/// let result = try await detector.detect(image: cgImage)
/// print("Is meme: \(result.isMeme) (\(result.memeConfidence))")
/// print("Environment: \(result.environment)")
/// ```
public final class MemeDetector: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.photopipeline.meme", qos: .userInitiated)
    private let memeRequestClass: AnyClass?
    private let cityNatureRequestClass: AnyClass?

    public init() {
        self.memeRequestClass = NSClassFromString("VNClassifyMemeImageRequest")
        self.cityNatureRequestClass = NSClassFromString("VNClassifyCityNatureImageRequest")
    }

    /// Whether meme detection is available on this system.
    public var isMemeAvailable: Bool { memeRequestClass != nil }

    /// Whether city/nature classification is available on this system.
    public var isCityNatureAvailable: Bool { cityNatureRequestClass != nil }

    /// Detect meme content and classify environment.
    public func detect(image: CGImage) async throws -> MemeResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.detectSync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Sync implementation

    private func detectSync(image: CGImage) throws -> MemeResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        // Try meme detection
        var isMeme = false
        var memeConfidence: Float = 0
        if let cls = memeRequestClass, let req = createVNRequest(cls) {
            try? handler.perform([req])
            if let results = req.results {
                for obs in results {
                    // Try VNClassificationObservation first
                    if let c = obs as? VNClassificationObservation {
                        if c.identifier.lowercased().contains("meme") && c.confidence > memeConfidence {
                            memeConfidence = c.confidence
                            isMeme = c.confidence > 0.5
                        }
                    } else {
                        // KVC fallback for unknown observation types
                        let nsObj = obs as NSObject
                        let label = nsObj.value(forKey: "identifier") as? String
                            ?? nsObj.value(forKey: "label") as? String
                        let conf = (nsObj.value(forKey: "confidence") as? NSNumber)?.floatValue ?? 0
                        if let label, label.lowercased().contains("meme"), conf > memeConfidence {
                            memeConfidence = conf
                            isMeme = conf > 0.5
                        }
                    }
                }
            }
        }

        // Try city/nature classification
        var environment: MemeResult.Environment = .unknown
        if let cls = cityNatureRequestClass, let req = createVNRequest(cls) {
            try? handler.perform([req])
            if let results = req.results {
                var bestLabel = ""
                var bestConf: Float = 0
                for obs in results {
                    if let c = obs as? VNClassificationObservation {
                        if c.confidence > bestConf {
                            bestLabel = c.identifier
                            bestConf = c.confidence
                        }
                    } else {
                        // KVC fallback
                        let nsObj = obs as NSObject
                        let label = nsObj.value(forKey: "identifier") as? String
                            ?? nsObj.value(forKey: "label") as? String ?? ""
                        let conf = (nsObj.value(forKey: "confidence") as? NSNumber)?.floatValue ?? 0
                        if conf > bestConf {
                            bestLabel = label
                            bestConf = conf
                        }
                    }
                }
                let lower = bestLabel.lowercased()
                if lower.contains("city") || lower.contains("indoor") || lower.contains("urban") {
                    environment = .urban
                } else if lower.contains("nature") || lower.contains("outdoor") {
                    environment = .nature
                }
            }
        }

        return MemeResult(isMeme: isMeme, memeConfidence: memeConfidence, environment: environment)
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

public struct MemeResult: Codable, Sendable {
    /// Whether the image is classified as a meme.
    public let isMeme: Bool
    /// Raw meme confidence (0.0–1.0). 0 if private API unavailable.
    public let memeConfidence: Float
    /// Environment classification (urban/nature/unknown).
    public let environment: Environment

    public enum Environment: String, Codable, Sendable {
        case urban
        case nature
        case unknown
    }
}
