import Foundation
import CoreGraphics
import Vision

/// Human body and hand pose estimation using public Vision APIs.
///
/// Uses VNDetectHumanBodyPoseRequest (macOS 12+) and VNDetectHumanHandPoseRequest
/// (macOS 12+) to detect joint positions for bodies and hands.
///
/// No private APIs needed -- these are fully public Vision requests.
/// Reuses `JointPosition` from AnimalAnalyzer (same module).
///
/// ```swift
/// let estimator = BodyPoseEstimator()
/// let result = try await estimator.detectAll(image: cgImage)
/// for body in result.bodies {
///     print("\(body.joints.count) joints detected")
/// }
/// for hand in result.hands {
///     print("\(hand.chirality) hand: \(hand.joints.count) joints")
/// }
/// ```
public final class BodyPoseEstimator: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.photopipeline.pose", qos: .userInitiated)

    public init() {}

    /// Detect human body poses in an image.
    public func detectBodies(image: CGImage) async throws -> [BodyPose] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let results = try self.detectBodiesSync(image: image)
                    cont.resume(returning: results)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Detect human hand poses in an image.
    public func detectHands(image: CGImage) async throws -> [HandPose] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let results = try self.detectHandsSync(image: image)
                    cont.resume(returning: results)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Detect both body and hand poses in a single pass.
    ///
    /// Runs both requests on the same VNImageRequestHandler for efficiency.
    public func detectAll(image: CGImage) async throws -> PoseResult {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.detectAllSync(image: image)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Sync implementations

    private func detectBodiesSync(image: CGImage) throws -> [BodyPose] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectHumanBodyPoseRequest()
        try handler.perform([request])

        return (request.results ?? []).map { obs in
            parseBodyJoints(obs)
        }
    }

    private func detectHandsSync(image: CGImage) throws -> [HandPose] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 4
        try handler.perform([request])

        return (request.results ?? []).map { obs in
            parseHandJoints(obs)
        }
    }

    private func detectAllSync(image: CGImage) throws -> PoseResult {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let handRequest = VNDetectHumanHandPoseRequest()
        handRequest.maximumHandCount = 4

        // Run both requests in a single perform call for efficiency
        try handler.perform([bodyRequest, handRequest])

        let bodies = (bodyRequest.results ?? []).map { parseBodyJoints($0) }
        let hands = (handRequest.results ?? []).map { parseHandJoints($0) }

        return PoseResult(bodies: bodies, hands: hands)
    }

    // MARK: - Joint parsing helpers

    private func parseBodyJoints(_ obs: VNHumanBodyPoseObservation) -> BodyPose {
        var joints: [String: JointPosition] = [:]
        if let allPoints = try? obs.recognizedPoints(.all) {
            for (key, point) in allPoints where point.confidence > 0.1 {
                joints[key.rawValue.rawValue] = JointPosition(
                    x: Float(point.location.x),
                    y: Float(point.location.y),
                    confidence: point.confidence
                )
            }
        }
        return BodyPose(joints: joints, confidence: obs.confidence)
    }

    private func parseHandJoints(_ obs: VNHumanHandPoseObservation) -> HandPose {
        var joints: [String: JointPosition] = [:]
        if let allPoints = try? obs.recognizedPoints(.all) {
            for (key, point) in allPoints where point.confidence > 0.1 {
                joints[key.rawValue.rawValue] = JointPosition(
                    x: Float(point.location.x),
                    y: Float(point.location.y),
                    confidence: point.confidence
                )
            }
        }
        let chirality: HandPose.Chirality
        switch obs.chirality {
        case .left:
            chirality = .left
        case .right:
            chirality = .right
        @unknown default:
            chirality = .unknown
        }
        return HandPose(joints: joints, chirality: chirality, confidence: obs.confidence)
    }
}

// MARK: - Result types
// Note: JointPosition is defined in AnimalAnalyzer.swift (same module, no import needed)

public struct BodyPose: Codable, Sendable {
    /// Joint positions keyed by VNHumanBodyPoseObservation.JointName raw values.
    public let joints: [String: JointPosition]
    public let confidence: Float

    public init(joints: [String: JointPosition], confidence: Float) {
        self.joints = joints
        self.confidence = confidence
    }
}

public struct HandPose: Codable, Sendable {
    /// Joint positions keyed by VNHumanHandPoseObservation.JointName raw values.
    public let joints: [String: JointPosition]
    /// Which hand (left/right/unknown).
    public let chirality: Chirality
    public let confidence: Float

    public enum Chirality: String, Codable, Sendable {
        case left, right, unknown
    }

    public init(joints: [String: JointPosition], chirality: Chirality, confidence: Float) {
        self.joints = joints
        self.chirality = chirality
        self.confidence = confidence
    }
}

public struct PoseResult: Codable, Sendable {
    public let bodies: [BodyPose]
    public let hands: [HandPose]

    /// Whether any human bodies were detected.
    public var hasPeople: Bool { !bodies.isEmpty }

    public init(bodies: [BodyPose], hands: [HandPose]) {
        self.bodies = bodies
        self.hands = hands
    }
}
