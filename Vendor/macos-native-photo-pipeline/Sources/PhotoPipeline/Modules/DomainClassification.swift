import Foundation
import CoreGraphics
import CoreVideo

/// GNN-based domain classification for routing to specialized models.
///
/// Determines which recognition domain an image belongs to (dogs, cats, food,
/// landmarks, etc.) before routing to the appropriate domain-specific model.
///
/// Maps to VisualLookup's internal gating pipeline:
/// VCPMADVIVisualSearchGatingTask → GNN domain predictor → model routing.
///
/// 21 domains total, with specialized models for breeds (NatureworldModel),
/// food (FoodModel), landmarks (UnifiedModel), etc.
public final class DomainClassifier: @unchecked Sendable {

    private let loader = FrameworkLoader.shared
    private let queue = DispatchQueue(label: "com.photopipeline.domain", qos: .userInitiated)

    public init() throws {
        // VisualLookup contains the domain classification models
        try loader.load(.visualLookup)
    }

    /// Classify the primary domain of an image.
    ///
    /// Returns ranked domains with confidence scores.
    public func classify(image: CGImage) async throws -> [(domain: RecognitionDomain, confidence: Float)] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let results = try self.classifySync(image: image)
                    cont.resume(returning: results)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func classifySync(image: CGImage) throws -> [(domain: RecognitionDomain, confidence: Float)] {
        guard let pixelBuffer = createPixelBuffer(from: image) else {
            throw FrameworkError.invocationFailed("Failed to create pixel buffer")
        }

        // VCPMADVIVisualSearchGatingTask performs domain classification
        if let gatingCls = loader.classNamed("VCPMADVIVisualSearchGatingTask"),
           let task = ObjCBridge.create(gatingCls) {

            let rawResult = ObjCBridge.call(task, "processPixelBuffer:", with: pixelBuffer)

            if let results = rawResult as? [NSDictionary] {
                return results.compactMap { dict -> (RecognitionDomain, Float)? in
                    guard let domainInt = (dict["domain"] as? NSNumber)?.intValue,
                          let confidence = (dict["confidence"] as? NSNumber)?.floatValue,
                          let domain = RecognitionDomain(rawValue: domainInt) else { return nil }
                    return (domain, confidence)
                }.sorted { $0.1 > $1.1 }
            }
        }

        // Try CategoryClassificationModel directly
        if let catCls = loader.classNamed("VLCategoryClassificationModel"),
           let model = ObjCBridge.create(catCls) {

            let rawResult = ObjCBridge.call(model, "classifyImage:", with: pixelBuffer)
            if let results = rawResult as? [NSDictionary] {
                return results.compactMap { dict -> (RecognitionDomain, Float)? in
                    guard let label = dict["category"] as? String,
                          let confidence = (dict["confidence"] as? NSNumber)?.floatValue else { return nil }
                    let domain = domainFromCategory(label)
                    return (domain, confidence)
                }.sorted { $0.1 > $1.1 }
            }
        }

        return [(.unknown, 1.0)]
    }

    private func domainFromCategory(_ category: String) -> RecognitionDomain {
        let lower = category.lowercased()
        let mapping: [(String, RecognitionDomain)] = [
            ("dog", .dogs), ("cat", .cats), ("bird", .birds),
            ("insect", .insects), ("food", .food), ("plant", .plants),
            ("landmark", .landmark), ("sculpture", .sculpture),
            ("skyline", .skyline), ("mammal", .mammals),
            ("reptile", .reptiles), ("art", .art),
            ("natural_landmark", .naturalLandmark),
        ]
        for (key, domain) in mapping {
            if lower.contains(key) { return domain }
        }
        return .unknown
    }

    private func createPixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                           kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
