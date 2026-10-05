import Foundation
import CoreGraphics
import Vision

/// Object recognition wrapping Apple's private domain-specific Vision requests.
///
/// Tries private VNRequest subclasses first (same as Photos.app uses internally):
/// - `VNRecognizeFoodAndDrinkRequest` → food/drink names via RichLabelKV
/// - `VNClassifyPotentialLandmarkRequest` → landmark identification
/// - `VNRecognizeAnimalsRequest` (public) → breed-level animal names
///
/// The private requests go through Apple's full pipeline:
/// model inference → FAISS embedding search → RichLabelKV → localized names.
/// All processing is on-device — no network calls needed for names.
///
/// Falls back to public Vision APIs when private classes aren't available.
///
/// ```swift
/// let recognizer = try ObjectRecognizer()
/// let results = try await recognizer.recognize(image: cgImage)
/// for r in results {
///     print("\(r.domain): \(r.name) [\(r.confidence)]")
/// }
/// ```
public final class ObjectRecognizer: @unchecked Sendable {

    private let loader = FrameworkLoader.shared
    private let queue = DispatchQueue(label: "com.photopipeline.object", qos: .userInitiated)

    // Cached class lookups (nil = not available on this system)
    private let foodRequestClass: AnyClass?
    private let landmarkRequestClass: AnyClass?

    public init() throws {
        // Try loading VisualLookup for the full pipeline (RichLabelKV, FAISS, etc.)
        _ = try? loader.load(.visualLookup)

        // Look up private VNRequest subclasses at runtime
        self.foodRequestClass = NSClassFromString("VNRecognizeFoodAndDrinkRequest")
        self.landmarkRequestClass = NSClassFromString("VNClassifyPotentialLandmarkRequest")
    }

    /// Whether private domain-specific recognition is available.
    public var hasFoodRecognition: Bool { foodRequestClass != nil }
    public var hasLandmarkRecognition: Bool { landmarkRequestClass != nil }

    /// Full recognition pipeline: runs all available domain-specific requests in parallel.
    public func recognize(image: CGImage) async throws -> [Recognition] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let results = try self.recognizeSync(image: image)
                    cont.resume(returning: results)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Unified recognition (private + public)

    private func recognizeSync(image: CGImage) throws -> [Recognition] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var recognitions: [Recognition] = []
        var existingNames = Set<String>()

        // 1. Animals (public API — VNRecognizeAnimalsRequest)
        //    On macOS 14+ this returns breed-level labels (e.g. "Golden Retriever")
        let animalRecognitions = recognizeAnimals(handler: handler)
        for rec in animalRecognitions {
            recognitions.append(rec)
            existingNames.insert(rec.name.lowercased())
        }

        // 2. Food & Drink (private API — VNRecognizeFoodAndDrinkRequest)
        //    Goes through FoodModel → FAISS → RichLabelKV for food names
        let foodRecognitions = recognizeFood(handler: handler)
        for rec in foodRecognitions {
            if !existingNames.contains(rec.name.lowercased()) {
                recognitions.append(rec)
                existingNames.insert(rec.name.lowercased())
            }
        }

        // 3. Landmarks (private API — VNClassifyPotentialLandmarkRequest)
        //    Goes through UnifiedModel → geofence check → RichLabelKV
        let landmarkRecognitions = recognizeLandmarks(handler: handler)
        for rec in landmarkRecognitions {
            if !existingNames.contains(rec.name.lowercased()) {
                recognitions.append(rec)
                existingNames.insert(rec.name.lowercased())
            }
        }

        // 4. General image classification (public API fallback for uncovered domains)
        if recognitions.isEmpty {
            let generalRecognitions = recognizeGeneral(handler: handler)
            recognitions.append(contentsOf: generalRecognitions)
        }

        return recognitions
    }

    // MARK: - Animal Recognition (public VNRecognizeAnimalsRequest)

    private func recognizeAnimals(handler: VNImageRequestHandler) -> [Recognition] {
        let request = VNRecognizeAnimalsRequest()
        try? handler.perform([request])

        var results: [Recognition] = []
        guard let observations = request.results else { return results }

        for obs in observations {
            for label in obs.labels {
                let domain: RecognitionDomain
                let id = label.identifier.lowercased()
                if id.contains("cat") || id == "cat" {
                    domain = .cats
                } else if id.contains("dog") || id == "dog" {
                    domain = .dogs
                } else {
                    // Could be other animals in newer macOS versions
                    domain = .mammals
                }
                results.append(Recognition(
                    domain: domain,
                    name: label.identifier,
                    confidence: label.confidence,
                    boundingBox: obs.boundingBox
                ))
            }
        }
        return results
    }

    // MARK: - Food & Drink Recognition (private VNRecognizeFoodAndDrinkRequest)

    private func recognizeFood(handler: VNImageRequestHandler) -> [Recognition] {
        guard let cls = foodRequestClass else { return [] }

        guard let request = createVNRequest(cls) else { return [] }
        try? handler.perform([request])

        return parseClassificationObservations(request, domain: .food)
    }

    // MARK: - Landmark Recognition (private VNClassifyPotentialLandmarkRequest)

    private func recognizeLandmarks(handler: VNImageRequestHandler) -> [Recognition] {
        guard let cls = landmarkRequestClass else { return [] }

        guard let request = createVNRequest(cls) else { return [] }
        try? handler.perform([request])

        // Filter out sentinel values — "VNPotentialLandmarkIdentifier" means
        // "might be a landmark but needs server confirmation", not an actual name
        return parseClassificationObservations(request, domain: .landmark)
            .filter { !$0.name.hasPrefix("VN") }
    }

    // MARK: - General Classification (public VNClassifyImageRequest fallback)

    private func recognizeGeneral(handler: VNImageRequestHandler) -> [Recognition] {
        let request = VNClassifyImageRequest()
        try? handler.perform([request])

        guard let observations = request.results else { return [] }
        return observations
            .filter { $0.confidence > 0.3 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(10)
            .map { obs in
                Recognition(
                    domain: domainFromLabel(obs.identifier),
                    name: obs.identifier,
                    confidence: obs.confidence
                )
            }
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

    /// Parse results from a VNRequest, trying multiple observation formats.
    ///
    /// Private VN requests may return:
    /// - VNClassificationObservation (identifier + confidence)
    /// - VNRecognizedObjectObservation (labels + boundingBox)
    /// - Custom observation types with KVC-accessible properties
    private func parseClassificationObservations(_ request: VNRequest, domain: RecognitionDomain) -> [Recognition] {
        guard let results = request.results, !results.isEmpty else { return [] }
        var recognitions: [Recognition] = []

        for obs in results {
            // Try VNClassificationObservation first (most common)
            if let classObs = obs as? VNClassificationObservation {
                guard classObs.confidence > 0.1 else { continue }
                recognitions.append(Recognition(
                    domain: domain,
                    name: classObs.identifier,
                    confidence: classObs.confidence
                ))
                continue
            }

            // Try VNRecognizedObjectObservation (has labels array + bounding box)
            if let recObs = obs as? VNRecognizedObjectObservation {
                for label in recObs.labels {
                    guard label.confidence > 0.1 else { continue }
                    recognitions.append(Recognition(
                        domain: domain,
                        name: label.identifier,
                        confidence: label.confidence,
                        boundingBox: recObs.boundingBox
                    ))
                }
                continue
            }

            // Fallback: try KVC on unknown observation types
            let nsObj = obs as NSObject
            let name = nsObj.value(forKey: "identifier") as? String
                ?? nsObj.value(forKey: "label") as? String
                ?? nsObj.value(forKey: "name") as? String
            if let name {
                let confidence = (nsObj.value(forKey: "confidence") as? NSNumber)?.floatValue ?? 0
                guard confidence > 0.1 else { continue }
                var bbox: CGRect?
                if let bboxValue = nsObj.value(forKey: "boundingBox") as? CGRect {
                    bbox = bboxValue
                }
                recognitions.append(Recognition(
                    domain: domain,
                    name: name,
                    confidence: confidence,
                    boundingBox: bbox
                ))
            }
        }

        return recognitions.sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Helpers

    private func domainFromLabel(_ label: String) -> RecognitionDomain {
        let lower = label.lowercased()
        if lower.contains("dog") || lower.contains("puppy") { return .dogs }
        if lower.contains("cat") || lower.contains("kitten") { return .cats }
        if lower.contains("bird") { return .birds }
        if lower.contains("food") || lower.contains("dish") || lower.contains("meal") { return .food }
        if lower.contains("plant") || lower.contains("flower") || lower.contains("tree") { return .plants }
        if lower.contains("insect") || lower.contains("butterfly") || lower.contains("bee") { return .insects }
        if lower.contains("landmark") || lower.contains("monument") { return .landmark }
        return .unknown
    }
}
