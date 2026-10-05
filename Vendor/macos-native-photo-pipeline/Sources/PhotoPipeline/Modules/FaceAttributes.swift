import Foundation
import CoreGraphics
import Vision

/// Facial attribute analysis -- expressions, head pose, attributes, gaze.
///
/// Wraps private Vision requests for detailed face analysis:
/// - `VNDetectFaceExpressionsRequest` -> expression classification (smile, surprise, etc.)
/// - `VNDetectFacePoseRequest` -> head orientation (roll/pitch/yaw)
/// - `VNClassifyFaceAttributesRequest` -> attributes (glasses, hat, age, etc.)
/// - `VNDetectFaceGazeRequest` -> gaze direction
///
/// Uses public VNDetectFaceRectanglesRequest + VNDetectFaceCaptureQualityRequest
/// as baseline, augmented by private requests when available.
///
/// ```swift
/// let attrs = FaceAttributeAnalyzer()
/// let results = try await attrs.analyze(image: cgImage)
/// for face in results {
///     print("quality: \(face.faceQuality ?? 0), expressions: \(face.expressions)")
/// }
/// ```
public final class FaceAttributeAnalyzer: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.photopipeline.faceattr", qos: .userInitiated)

    // Cached class lookups (nil = not available on this system)
    private let expressionClass: AnyClass?
    private let poseClass: AnyClass?
    private let attributesClass: AnyClass?
    private let gazeClass: AnyClass?

    public init() {
        self.expressionClass = NSClassFromString("VNDetectFaceExpressionsRequest")
        self.poseClass = NSClassFromString("VNDetectFacePoseRequest")
        self.attributesClass = NSClassFromString("VNClassifyFaceAttributesRequest")
        self.gazeClass = NSClassFromString("VNDetectFaceGazeRequest")
    }

    /// Whether private expression detection is available.
    public var hasExpressions: Bool { expressionClass != nil }
    /// Whether private face pose detection is available.
    public var hasPose: Bool { poseClass != nil }
    /// Whether private attribute classification is available.
    public var hasAttributes: Bool { attributesClass != nil }
    /// Whether private gaze detection is available.
    public var hasGaze: Bool { gazeClass != nil }

    /// Analyze all detected faces in an image for attributes, expressions, and pose.
    public func analyze(image: CGImage) async throws -> [FaceAttributeResult] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let results = try self.analyzeSync(image: image)
                    cont.resume(returning: results)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Sync implementation

    private func analyzeSync(image: CGImage) throws -> [FaceAttributeResult] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        // Baseline: detect face rectangles
        let faceRequest = VNDetectFaceRectanglesRequest()
        try handler.perform([faceRequest])
        guard let faces = faceRequest.results, !faces.isEmpty else { return [] }

        let faceCount = faces.count

        // Face capture quality (public API -- includes roll/yaw)
        var qualityResults: [VNFaceObservation] = []
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        try? handler.perform([qualityRequest])
        qualityResults = qualityRequest.results ?? []

        // Expressions (private)
        var expressionsByFace: [[String: Float]] = Array(repeating: [:], count: faceCount)
        if let cls = expressionClass, let req = createVNRequest(cls) {
            try? handler.perform([req])
            if let results = req.results {
                for (i, obs) in results.enumerated() where i < faceCount {
                    let nsObj = obs as NSObject
                    // Try known expression keys via KVC
                    for key in ["smile", "surprise", "anger", "sadness", "disgust",
                                "fear", "neutral", "happy", "contempt"] {
                        if let val = nsObj.value(forKey: key) as? NSNumber {
                            expressionsByFace[i][key] = val.floatValue
                        }
                    }
                    // Also try as VNClassificationObservation
                    if let classObs = obs as? VNClassificationObservation {
                        expressionsByFace[i][classObs.identifier] = classObs.confidence
                    }
                }
            }
        }

        // Face pose from quality results (roll/yaw are public, pitch via KVC)
        var posesByFace: [FacePose?] = Array(repeating: nil, count: faceCount)
        for (i, obs) in qualityResults.enumerated() where i < faceCount {
            let roll = obs.roll?.floatValue
            let yaw = obs.yaw?.floatValue
            let pitch = (obs as NSObject).value(forKey: "pitch") as? NSNumber
            posesByFace[i] = FacePose(roll: roll, yaw: yaw, pitch: pitch?.floatValue)
        }

        // Try dedicated pose request if available (may give better results)
        if let cls = poseClass, let req = createVNRequest(cls) {
            try? handler.perform([req])
            if let results = req.results {
                for (i, obs) in results.enumerated() where i < faceCount {
                    let nsObj = obs as NSObject
                    let roll = (nsObj.value(forKey: "roll") as? NSNumber)?.floatValue
                    let yaw = (nsObj.value(forKey: "yaw") as? NSNumber)?.floatValue
                    let pitch = (nsObj.value(forKey: "pitch") as? NSNumber)?.floatValue
                    // Override with dedicated pose data if we got anything
                    if roll != nil || yaw != nil || pitch != nil {
                        posesByFace[i] = FacePose(roll: roll, yaw: yaw, pitch: pitch)
                    }
                }
            }
        }

        // Attributes (private)
        var attributesByFace: [[String: String]] = Array(repeating: [:], count: faceCount)
        if let cls = attributesClass, let req = createVNRequest(cls) {
            try? handler.perform([req])
            if let results = req.results {
                for (i, obs) in results.enumerated() where i < faceCount {
                    let nsObj = obs as NSObject
                    for key in ["hasGlasses", "hasHat", "hasMask", "hairColor",
                                "facialHair", "age", "gender", "hasSunglasses",
                                "isSmiling", "eyesOpen"] {
                        if let val = nsObj.value(forKey: key) {
                            attributesByFace[i][key] = "\(val)"
                        }
                    }
                }
            }
        }

        // Gaze (private)
        var gazeByFace: [GazeDirection?] = Array(repeating: nil, count: faceCount)
        if let cls = gazeClass, let req = createVNRequest(cls) {
            try? handler.perform([req])
            if let results = req.results {
                for (i, obs) in results.enumerated() where i < faceCount {
                    let nsObj = obs as NSObject
                    let horizontal = (nsObj.value(forKey: "horizontalAngle") as? NSNumber)?.floatValue
                        ?? (nsObj.value(forKey: "yaw") as? NSNumber)?.floatValue
                    let vertical = (nsObj.value(forKey: "verticalAngle") as? NSNumber)?.floatValue
                        ?? (nsObj.value(forKey: "pitch") as? NSNumber)?.floatValue
                    if horizontal != nil || vertical != nil {
                        gazeByFace[i] = GazeDirection(
                            horizontalAngle: horizontal,
                            verticalAngle: vertical
                        )
                    }
                }
            }
        }

        // Assemble results
        return faces.enumerated().map { i, face in
            FaceAttributeResult(
                boundingBox: face.boundingBox,
                faceQuality: qualityResults[safe: i]?.faceCaptureQuality,
                expressions: expressionsByFace[i],
                pose: posesByFace[i],
                attributes: attributesByFace[i],
                gaze: gazeByFace[i]
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
}

// MARK: - Result types

public struct FaceAttributeResult: Codable, Sendable {
    /// Face bounding box in normalized image coordinates (0-1).
    public let boundingBox: CGRect
    /// Face capture quality score (0-1, from public API).
    public let faceQuality: Float?
    /// Expression scores keyed by name, e.g. "smile": 0.8, "neutral": 0.2.
    public let expressions: [String: Float]
    /// Head pose (roll/pitch/yaw).
    public let pose: FacePose?
    /// Attribute strings keyed by name, e.g. "hasGlasses": "true", "age": "30".
    public let attributes: [String: String]
    /// Gaze direction if available.
    public let gaze: GazeDirection?

    public init(
        boundingBox: CGRect,
        faceQuality: Float? = nil,
        expressions: [String: Float] = [:],
        pose: FacePose? = nil,
        attributes: [String: String] = [:],
        gaze: GazeDirection? = nil
    ) {
        self.boundingBox = boundingBox
        self.faceQuality = faceQuality
        self.expressions = expressions
        self.pose = pose
        self.attributes = attributes
        self.gaze = gaze
    }
}

public struct FacePose: Codable, Sendable {
    /// Head tilt (rotation around the axis going through the face).
    public let roll: Float?
    /// Looking left/right (rotation around the vertical axis).
    public let yaw: Float?
    /// Looking up/down (rotation around the horizontal axis).
    public let pitch: Float?

    public init(roll: Float? = nil, yaw: Float? = nil, pitch: Float? = nil) {
        self.roll = roll
        self.yaw = yaw
        self.pitch = pitch
    }
}

public struct GazeDirection: Codable, Sendable {
    /// Horizontal gaze angle in radians (negative = left, positive = right).
    public let horizontalAngle: Float?
    /// Vertical gaze angle in radians (negative = down, positive = up).
    public let verticalAngle: Float?

    public init(horizontalAngle: Float? = nil, verticalAngle: Float? = nil) {
        self.horizontalAngle = horizontalAngle
        self.verticalAngle = verticalAngle
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
