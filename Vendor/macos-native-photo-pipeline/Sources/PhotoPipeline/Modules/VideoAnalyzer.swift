import Foundation
import CoreGraphics
import CoreImage
import Vision
import AVFoundation

/// Video analysis — frame extraction, per-frame classification, highlight detection.
///
/// Uses AVFoundation's `AVAssetImageGenerator` for frame extraction and Vision
/// framework requests for per-frame scene classification and saliency scoring.
///
/// ```swift
/// let analyzer = VideoAnalyzer()
/// let analysis = try await analyzer.analyze(videoURL: url, framesPerSecond: 1.0)
/// print("Duration: \(analysis.duration)s, \(analysis.frameCount) frames sampled")
/// for h in analysis.highlights {
///     print("Highlight at \(h.time)s (score: \(h.score))")
/// }
/// ```
public final class VideoAnalyzer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.photopipeline.video", qos: .userInitiated)

    public init() {}

    /// Analyze a video file — extracts key frames and classifies scenes/actions.
    public func analyze(videoURL: URL, framesPerSecond: Double = 1.0) async throws -> VideoAnalysis {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.analyzeSync(videoURL: videoURL, fps: framesPerSecond)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Extract key frames from a video at the given FPS.
    public func extractFrames(videoURL: URL, framesPerSecond: Double = 1.0, maxFrames: Int = 100) async throws -> [VideoFrame] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let frames = try self.extractFramesSync(videoURL: videoURL, fps: framesPerSecond, maxFrames: maxFrames)
                    cont.resume(returning: frames)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Generate a thumbnail for a video (best frame by saliency heuristic).
    public func generateThumbnail(videoURL: URL) async throws -> CGImage {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let thumb = try self.generateThumbnailSync(videoURL: videoURL)
                    cont.resume(returning: thumb)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Detect optical flow between two consecutive frames.
    ///
    /// Returns a CGImage representing the flow field. Useful for motion detection
    /// and action classification between adjacent frames.
    public func opticalFlow(frame1: CGImage, frame2: CGImage) async throws -> CGImage {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let flow = try self.opticalFlowSync(frame1: frame1, frame2: frame2)
                    cont.resume(returning: flow)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Sync implementations

    private func analyzeSync(videoURL: URL, fps: Double) throws -> VideoAnalysis {
        let frames = try extractFramesSync(videoURL: videoURL, fps: fps, maxFrames: 60)
        guard !frames.isEmpty else {
            throw FrameworkError.invocationFailed("No frames extracted from video")
        }

        let asset = AVURLAsset(url: videoURL)
        let duration = CMTimeGetSeconds(asset.duration)

        // Classify each frame
        var frameAnalyses: [FrameAnalysis] = []

        for frame in frames {
            let handler = VNImageRequestHandler(cgImage: frame.image, options: [:])

            // Scene classification
            let classifyRequest = VNClassifyImageRequest()
            try? handler.perform([classifyRequest])

            let labels = (classifyRequest.results ?? [])
                .filter { $0.confidence > 0.2 }
                .sorted { $0.confidence > $1.confidence }
                .prefix(5)
                .map { SceneLabel(label: $0.identifier, confidence: $0.confidence) }

            // Attention saliency as quality proxy
            let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
            try? handler.perform([saliencyRequest])
            let saliencyScore = saliencyRequest.results?.first?.salientObjects?.first?.confidence ?? 0.5

            frameAnalyses.append(FrameAnalysis(
                time: frame.time,
                labels: Array(labels),
                qualityScore: saliencyScore
            ))
        }

        // Find highlights (frames with highest quality scores)
        let sortedByQuality = frameAnalyses.sorted { $0.qualityScore > $1.qualityScore }
        let highlights = Array(sortedByQuality.prefix(5).map { analysis in
            VideoHighlight(time: analysis.time, score: analysis.qualityScore, labels: analysis.labels)
        })

        // Suggest thumbnail (highest quality frame)
        let thumbnailTime = sortedByQuality.first?.time ?? 0

        // Aggregate labels across all frames
        var labelCounts: [String: (total: Float, count: Int)] = [:]
        for analysis in frameAnalyses {
            for label in analysis.labels {
                var existing = labelCounts[label.label] ?? (total: 0, count: 0)
                existing.total += label.confidence
                existing.count += 1
                labelCounts[label.label] = existing
            }
        }

        let aggregatedLabels = Array(
            labelCounts.map { key, value in
                SceneLabel(label: key, confidence: value.total / Float(value.count))
            }
            .sorted { $0.confidence > $1.confidence }
            .prefix(10)
        )

        return VideoAnalysis(
            duration: duration,
            frameCount: frames.count,
            labels: aggregatedLabels,
            highlights: highlights,
            suggestedThumbnailTime: thumbnailTime,
            frameAnalyses: frameAnalyses
        )
    }

    private func extractFramesSync(videoURL: URL, fps: Double, maxFrames: Int) throws -> [VideoFrame] {
        let asset = AVURLAsset(url: videoURL)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

        // Calculate sample times
        let interval = 1.0 / fps
        var times: [Double] = []
        var t = 0.0
        while t < duration && times.count < maxFrames {
            times.append(t)
            t += interval
        }

        var frames: [VideoFrame] = []
        for time in times {
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) {
                frames.append(VideoFrame(image: cgImage, time: time))
            }
        }

        return frames
    }

    private func generateThumbnailSync(videoURL: URL) throws -> CGImage {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        // Sample a few frames and pick the one with highest saliency
        let duration = CMTimeGetSeconds(asset.duration)
        let sampleTimes = [0.1, duration * 0.25, duration * 0.5, duration * 0.75].filter { $0 < duration }

        var bestImage: CGImage?
        var bestScore: Float = -1

        for time in sampleTimes {
            guard let image = try? generator.copyCGImage(
                at: CMTime(seconds: time, preferredTimescale: 600),
                actualTime: nil
            ) else { continue }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let request = VNGenerateAttentionBasedSaliencyImageRequest()
            try? handler.perform([request])
            let score = request.results?.first?.salientObjects?.first?.confidence ?? 0.5

            if score > bestScore {
                bestScore = score
                bestImage = image
            }
        }

        guard let result = bestImage else {
            throw FrameworkError.invocationFailed("Could not extract any video frames")
        }
        return result
    }

    private func opticalFlowSync(frame1: CGImage, frame2: CGImage) throws -> CGImage {
        // VNGenerateOpticalFlowRequest is a VNTargetedImageRequest —
        // the target frame (frame2) goes in the initializer, the reference
        // frame (frame1) goes in the VNImageRequestHandler.
        let request = VNGenerateOpticalFlowRequest(targetedCGImage: frame2, options: [:])
        let handler = VNImageRequestHandler(cgImage: frame1, options: [:])
        try handler.perform([request])

        guard let result = request.results?.first else {
            throw FrameworkError.invocationFailed("No optical flow result")
        }

        let ciImage = CIImage(cvPixelBuffer: result.pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw FrameworkError.invocationFailed("Could not convert optical flow to CGImage")
        }
        return cgImage
    }
}

// MARK: - Result types

public struct VideoFrame: @unchecked Sendable {
    public let image: CGImage
    public let time: Double  // seconds from start

    public init(image: CGImage, time: Double) {
        self.image = image
        self.time = time
    }
}

public struct VideoAnalysis: Sendable {
    public let duration: Double
    public let frameCount: Int
    public let labels: [SceneLabel]           // aggregated across frames
    public let highlights: [VideoHighlight]    // best moments
    public let suggestedThumbnailTime: Double
    public let frameAnalyses: [FrameAnalysis]  // per-frame detail

    public init(
        duration: Double,
        frameCount: Int,
        labels: [SceneLabel],
        highlights: [VideoHighlight],
        suggestedThumbnailTime: Double,
        frameAnalyses: [FrameAnalysis]
    ) {
        self.duration = duration
        self.frameCount = frameCount
        self.labels = labels
        self.highlights = highlights
        self.suggestedThumbnailTime = suggestedThumbnailTime
        self.frameAnalyses = frameAnalyses
    }
}

public struct SceneLabel: Codable, Sendable {
    public let label: String
    public let confidence: Float

    public init(label: String, confidence: Float) {
        self.label = label
        self.confidence = confidence
    }
}

public struct VideoHighlight: Codable, Sendable {
    public let time: Double
    public let score: Float
    public let labels: [SceneLabel]

    public init(time: Double, score: Float, labels: [SceneLabel]) {
        self.time = time
        self.score = score
        self.labels = labels
    }
}

public struct FrameAnalysis: Codable, Sendable {
    public let time: Double
    public let labels: [SceneLabel]
    public let qualityScore: Float

    public init(time: Double, labels: [SceneLabel], qualityScore: Float) {
        self.time = time
        self.labels = labels
        self.qualityScore = qualityScore
    }
}
