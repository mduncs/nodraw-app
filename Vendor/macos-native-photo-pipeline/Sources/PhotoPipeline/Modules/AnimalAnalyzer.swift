import Foundation
import CoreGraphics
import Vision

/// Enhanced animal analysis beyond basic object recognition.
///
/// Wraps private Vision requests for detailed animal detection:
/// - `VNRecognizeAnimalHeadsRequest` -> breed-level head detection
/// - `VNRecognizeAnimalFacesRequest` -> animal face bounding boxes
/// - `VNDetectAnimalBodyPoseRequest` -> joint/skeleton estimation
/// - `VNCreateAnimalprintRequest` -> animal identity embeddings
///
/// All private requests use NSClassFromString + alloc/init at runtime.
/// Falls back gracefully when classes aren't available.
///
/// ```swift
/// let analyzer = AnimalAnalyzer()
/// let result = try await analyzer.analyze(image: cgImage)
/// for head in result.heads {
///     print("\(head.breed) [\(head.confidence)]")
/// }
/// ```
public final class AnimalAnalyzer: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.photopipeline.animal", qos: .userInitiated)

    // Cached class lookups (nil = not available on this system)
    private let animalHeadsClass: AnyClass?
    private let animalFacesClass: AnyClass?
    private let animalPoseClass: AnyClass?
    private let animalprintClass: AnyClass?

    public init() {
        self.animalHeadsClass = NSClassFromString("VNRecognizeAnimalHeadsRequest")
        self.animalFacesClass = NSClassFromString("VNRecognizeAnimalFacesRequest")
        self.animalPoseClass = NSClassFromString("VNDetectAnimalBodyPoseRequest")
        self.animalprintClass = NSClassFromString("VNCreateAnimalprintRequest")
    }

    /// Whether private animal head detection is available.
    public var hasHeadDetection: Bool { animalHeadsClass != nil }
    /// Whether private animal face detection is available.
    public var hasFaceDetection: Bool { animalFacesClass != nil }
    /// Whether private animal body pose estimation is available.
    public var hasPoseDetection: Bool { animalPoseClass != nil }
    /// Whether private animalprint embedding is available.
    public var hasAnimalprintGeneration: Bool { animalprintClass != nil }

    /// Run all available animal analysis on an image.
    public func analyze(image: CGImage) async throws -> AnimalAnalysis {
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

    private func analyzeSync(image: CGImage) throws -> AnimalAnalysis {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var heads: [AnimalHead] = []
        var faces: [AnimalFace] = []
        var poses: [AnimalPose] = []

        // 1. Animal heads (returns VNRecognizedObjectObservation with breed labels)
        if let cls = animalHeadsClass, let req = createVNRequest(cls) {
            try? handler.perform([req])
            if let results = req.results {
                for obs in results {
                    if let recObs = obs as? VNRecognizedObjectObservation {
                        let breed = recObs.labels.first?.identifier ?? "Unknown"
                        let confidence = recObs.labels.first?.confidence ?? 0
                        heads.append(AnimalHead(
                            breed: breed,
                            confidence: confidence,
                            boundingBox: recObs.boundingBox
                        ))
                    }
                }
            }
        }

        // 2. Animal faces
        if let cls = animalFacesClass, let req = createVNRequest(cls) {
            try? handler.perform([req])
            if let results = req.results {
                for obs in results {
                    if let recObs = obs as? VNRecognizedObjectObservation {
                        faces.append(AnimalFace(
                            label: recObs.labels.first?.identifier ?? "animal",
                            confidence: recObs.labels.first?.confidence ?? 0,
                            boundingBox: recObs.boundingBox
                        ))
                    } else {
                        // Fallback: try as VNDetectedObjectObservation via KVC
                        let nsObj = obs as NSObject
                        if let bbox = nsObj.value(forKey: "boundingBox") as? CGRect {
                            faces.append(AnimalFace(
                                label: "animal",
                                confidence: 1.0,
                                boundingBox: bbox
                            ))
                        }
                    }
                }
            }
        }

        // 3. Animal body pose (VNAnimalBodyPoseObservation has recognizedPoints)
        if let cls = animalPoseClass, let req = createVNRequest(cls) {
            try? handler.perform([req])
            if let results = req.results {
                for obs in results {
                    var joints: [String: JointPosition] = [:]
                    let nsObj = obs as NSObject

                    // Try as VNRecognizedPointsObservation (public superclass)
                    if let pointsObs = obs as? VNRecognizedPointsObservation,
                       let allPoints = try? pointsObs.recognizedPoints(forGroupKey: .all) {
                        for (key, point) in allPoints {
                            joints[key.rawValue] = JointPosition(
                                x: Float(point.x),
                                y: Float(point.y),
                                confidence: point.confidence
                            )
                        }
                    }

                    let confidence = (nsObj.value(forKey: "confidence") as? NSNumber)?.floatValue ?? 1.0
                    poses.append(AnimalPose(joints: joints, confidence: confidence))
                }
            }
        }

        return AnimalAnalysis(heads: heads, faces: faces, poses: poses)
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

public struct AnimalAnalysis: Codable, Sendable {
    public let heads: [AnimalHead]
    public let faces: [AnimalFace]
    public let poses: [AnimalPose]

    public var hasAnimals: Bool { !heads.isEmpty || !faces.isEmpty }

    public init(heads: [AnimalHead], faces: [AnimalFace], poses: [AnimalPose]) {
        self.heads = heads
        self.faces = faces
        self.poses = poses
    }
}

public struct AnimalHead: Codable, Sendable {
    public let breed: String
    public let confidence: Float
    public let boundingBox: CGRect

    public init(breed: String, confidence: Float, boundingBox: CGRect) {
        self.breed = breed
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public struct AnimalFace: Codable, Sendable {
    public let label: String
    public let confidence: Float
    public let boundingBox: CGRect

    public init(label: String, confidence: Float, boundingBox: CGRect) {
        self.label = label
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

public struct AnimalPose: Codable, Sendable {
    public let joints: [String: JointPosition]
    public let confidence: Float

    public init(joints: [String: JointPosition], confidence: Float) {
        self.joints = joints
        self.confidence = confidence
    }
}

/// A recognized joint/keypoint position in normalized image coordinates.
///
/// Shared between animal and human pose estimation.
public struct JointPosition: Codable, Sendable {
    public let x: Float
    public let y: Float
    public let confidence: Float

    public init(x: Float, y: Float, confidence: Float) {
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}
