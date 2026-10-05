import Foundation
import CoreGraphics
import Vision

/// Scene classification wrapping VisionCore's SceneNet + public Vision API.
///
/// The MonzaV4_1 backbone (53-layer CNN, 224×224 BGR input) produces
/// multiple heads in a single forward pass: scene labels, aesthetics,
/// sceneprint embedding, and saliency attention.
///
/// Falls back to public `VNClassifyImageRequest` when private frameworks
/// are unavailable.
///
/// ```swift
/// let classifier = try SceneClassifier()
/// let result = try await classifier.classify(image: cgImage)
/// print(result.labels.prefix(5))  // top 5 scene labels
/// ```
public final class SceneClassifier: @unchecked Sendable {

    private let loader = FrameworkLoader.shared
    private let usePrivateAPI: Bool
    private let queue = DispatchQueue(label: "com.photopipeline.scene", qos: .userInitiated)

    public init() throws {
        // Try loading private frameworks; fall back to public Vision API
        do {
            try loader.load(.mediaAnalysis)
            try loader.load(.visionCore)
            usePrivateAPI = true
        } catch {
            usePrivateAPI = false
        }
    }

    /// Classify a scene — returns labels, aesthetics, and optionally embedding.
    ///
    /// With private API: single forward pass through MonzaV4_1 backbone.
    /// With public API: VNClassifyImageRequest + VNClassifyImageAestheticsRequest.
    public func classify(image: CGImage) async throws -> SceneResult {
        if usePrivateAPI {
            return try await classifyPrivate(image: image)
        }
        return try await classifyPublic(image: image)
    }

    // MARK: - Private API path (MonzaV4_1 + mubb_md7)

    private func classifyPrivate(image: CGImage) async throws -> SceneResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.classifyPrivateSync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func classifyPrivateSync(image: CGImage) throws -> SceneResult {
        // VCPMADVISceneClassificationTask path
        guard let taskCls = loader.classNamed("VCPMADVISceneClassificationTask") else {
            throw FrameworkError.classNotFound("VCPMADVISceneClassificationTask", framework: "MediaAnalysis")
        }

        guard let task = ObjCBridge.create(taskCls) else {
            throw FrameworkError.invocationFailed("Failed to create scene classification task")
        }

        // Create pixel buffer for the backbone
        guard let pixelBuffer = createPixelBuffer(from: image) else {
            throw FrameworkError.invocationFailed("Failed to create pixel buffer for scene classification")
        }

        // Run backbone + scene classification heads
        // The task expects a pixel buffer and produces scene labels + sceneprint
        let rawResult = ObjCBridge.call(task, "processPixelBuffer:", with: pixelBuffer)

        if let resultDict = rawResult as? NSDictionary {
            return parseSceneResult(resultDict)
        }

        // Try alternate path: VNSceneClassificationRequest (private Vision API)
        return try classifyViaVisionPrivate(image: image)
    }

    private func classifyViaVisionPrivate(image: CGImage) throws -> SceneResult {
        // VNSceneClassificationRequest is a private Vision request
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var labels: [SceneClassification] = []

        // Try private scene classification
        if let reqCls = NSClassFromString("VNSceneClassificationRequest"),
           let request = ObjCBridge.create(reqCls) as? VNRequest {
            try handler.perform([request])
            if let observations = request.results as? [VNClassificationObservation] {
                labels = observations.prefix(20).map {
                    SceneClassification(label: $0.identifier, confidence: $0.confidence)
                }
            }
        }

        // Fallback to VNClassifyImageRequest
        if labels.isEmpty,
           let reqCls = NSClassFromString("VNClassifyImageRequest"),
           let request = ObjCBridge.create(reqCls) as? VNRequest {
            try handler.perform([request])
            if let observations = request.results as? [VNClassificationObservation] {
                labels = observations.prefix(20).map {
                    SceneClassification(label: $0.identifier, confidence: $0.confidence)
                }
            }
        }

        guard !labels.isEmpty else {
            throw FrameworkError.invocationFailed("Scene classification failed via private API")
        }

        // Run private aesthetics requests
        let aesthetics = runAestheticsRequests(image: image)
        let embedding = extractFeaturePrint(image: image)
        let saliencyBox = extractSaliency(image: image)
        let faceCount = detectFaceCount(image: image)

        return SceneResult(
            labels: labels,
            aestheticsScore: aesthetics.score,
            embedding: embedding,
            isJunk: aesthetics.isJunk,
            isUtility: aesthetics.isUtility,
            aestheticsDetail: aesthetics.detail,
            saliencyBox: saliencyBox,
            faceCount: faceCount
        )
    }

    // MARK: - Public API path

    private func classifyPublic(image: CGImage) async throws -> SceneResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        // Scene/image classification
        let classifyRequest = VNClassifyImageRequest()
        try handler.perform([classifyRequest])

        var labels: [SceneClassification] = []
        if let observations = classifyRequest.results {
            labels = observations
                .filter { $0.confidence > 0.1 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(20)
                .map { SceneClassification(label: $0.identifier, confidence: $0.confidence) }
        }

        // Run private aesthetics requests (orthogonal to scene classification)
        let aesthetics = runAestheticsRequests(image: image)
        let embedding = extractFeaturePrint(image: image)
        let saliencyBox = extractSaliency(image: image)
        let faceCount = detectFaceCount(image: image)

        return SceneResult(
            labels: labels,
            aestheticsScore: aesthetics.score,
            embedding: embedding,
            isJunk: aesthetics.isJunk,
            isUtility: aesthetics.isUtility,
            aestheticsDetail: aesthetics.detail,
            saliencyBox: saliencyBox,
            faceCount: faceCount
        )
    }

    // MARK: - Feature Print / Sceneprint (public VN API)

    /// Extract 768-float sceneprint embedding via VNGenerateImageFeaturePrintRequest.
    /// Used for image similarity search.
    private func extractFeaturePrint(image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }

        // VNFeaturePrintObservation.data contains raw floats
        let count = observation.elementCount
        guard observation.elementType == .float else { return nil }

        return observation.data.withUnsafeBytes { ptr -> [Float] in
            let buffer = ptr.bindMemory(to: Float.self)
            return Array(buffer.prefix(count))
        }
    }

    // MARK: - Saliency (public VN API)

    /// Extract attention saliency bounding box.
    private func extractSaliency(image: CGImage) -> CGRect? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        return observation.salientObjects?.first?.boundingBox
    }

    // MARK: - Face Detection (public VN API)

    /// Count faces in the image.
    private func detectFaceCount(image: CGImage) -> Int {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.count ?? 0
    }

    // MARK: - Private Aesthetics Requests

    /// Run VNCalculateImageAestheticsScoresRequest + VNClassifyImageAestheticsRequest
    /// via KVC on private observation types. Works through standard Vision pipeline.
    private func runAestheticsRequests(image: CGImage) -> (score: Float, isUtility: Bool, isJunk: Bool, detail: AestheticsDetail?) {
        var aestheticsScore: Float = 0
        var isUtility = false
        var isJunk = false
        var overallScore: Float = 0
        var qualityScores: [String: Float] = [:]

        // VNCalculateImageAestheticsScoresRequest → VNImageAestheticsScoresObservation
        // Gives: overallScore, isUtility, and quality/junk category scores
        if let scoresCls = NSClassFromString("VNCalculateImageAestheticsScoresRequest"),
           let scoresReq = ObjCBridge.create(scoresCls) as? VNRequest {
            let scoresHandler = VNImageRequestHandler(cgImage: image, options: [:])
            try? scoresHandler.perform([scoresReq])
            if let obs = scoresReq.results?.first as? NSObject {
                overallScore = (obs.value(forKey: "overallScore") as? NSNumber)?.floatValue ?? 0
                isUtility = (obs.value(forKey: "isUtility") as? NSNumber)?.boolValue ?? false

                // Normalize overallScore from ~[-1,1] to [0,1]
                aestheticsScore = max(0, min(1, (overallScore + 1) / 2))

                for key in AestheticsDetail.qualityKeys {
                    if obs.responds(to: NSSelectorFromString(key)),
                       let val = obs.value(forKey: key) as? NSNumber {
                        qualityScores[key] = val.floatValue
                    }
                }

                let poorQuality = qualityScores["poorQualityScore"] ?? 0
                let junkTragic = qualityScores["junkTragicFailureScore"] ?? 0
                isJunk = poorQuality > 0.5 || junkTragic > 0.5
            }
        }

        // VNClassifyImageAestheticsRequest → VNImageAestheticsObservation
        // Gives: 22 per-attribute sub-scores (framing, lighting, color, etc.)
        var subscores: [String: Float] = [:]
        if let detailCls = NSClassFromString("VNClassifyImageAestheticsRequest"),
           let detailReq = ObjCBridge.create(detailCls) as? VNRequest {
            let detailHandler = VNImageRequestHandler(cgImage: image, options: [:])
            try? detailHandler.perform([detailReq])
            if let obs = detailReq.results?.first as? NSObject {
                for key in AestheticsDetail.subscoreKeys {
                    if obs.responds(to: NSSelectorFromString(key)),
                       let val = obs.value(forKey: key) as? NSNumber {
                        subscores[key] = val.floatValue
                    }
                }
            }
        }

        let detail = (!qualityScores.isEmpty || !subscores.isEmpty)
            ? AestheticsDetail(overallScore: overallScore, isUtility: isUtility, qualityScores: qualityScores, subscores: subscores)
            : nil

        return (score: aestheticsScore, isUtility: isUtility, isJunk: isJunk, detail: detail)
    }

    // MARK: - Helpers

    private func parseSceneResult(_ dict: NSDictionary) -> SceneResult {
        var labels: [SceneClassification] = []
        if let rawLabels = dict["sceneLabels"] as? [[String: Any]] {
            labels = rawLabels.compactMap { entry in
                guard let label = entry["label"] as? String,
                      let conf = entry["confidence"] as? Float else { return nil }
                return SceneClassification(label: label, confidence: conf)
            }
        }

        let aesthetics = (dict["aestheticsScore"] as? NSNumber)?.floatValue ?? 0
        let embedding = dict["sceneprint"] as? [Float]
        let isJunk = (dict["isJunk"] as? NSNumber)?.boolValue ?? false

        return SceneResult(
            labels: labels,
            aestheticsScore: aesthetics,
            embedding: embedding,
            isJunk: isJunk
        )
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
