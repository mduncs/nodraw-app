import Foundation
import AVFoundation
import SoundAnalysis

/// Audio classification using Apple's SoundAnalysis framework.
///
/// Uses the built-in `SNClassifySoundRequest` (`.version1`) classifier to identify
/// sounds in audio files or video audio tracks. Processes audio in windowed chunks
/// and aggregates per-window classifications into an overall analysis.
///
/// ```swift
/// let classifier = AudioClassifier()
/// let analysis = try await classifier.classify(audioURL: url)
/// print("Duration: \(analysis.duration)s, speech: \(analysis.hasSpeech), music: \(analysis.hasMusic)")
/// for label in analysis.labels.prefix(5) {
///     print("  \(label.label): \(label.confidence)")
/// }
/// ```
public final class AudioClassifier: @unchecked Sendable {

    public init() {}

    /// Classify sounds in an audio file.
    public func classify(audioURL: URL, windowDuration: Double = 1.0) async throws -> AudioAnalysis {
        try await withCheckedThrowingContinuation { cont in
            let analyzerQueue = DispatchQueue(label: "com.photopipeline.audio", qos: .userInitiated)
            analyzerQueue.async {
                do {
                    let result = try self.classifySync(audioURL: audioURL, windowDuration: windowDuration)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Classify audio track of a video file.
    ///
    /// Convenience wrapper — SoundAnalysis can read audio tracks from video
    /// containers directly via AVAudioFile.
    public func classifyVideoAudio(videoURL: URL, windowDuration: Double = 1.0) async throws -> AudioAnalysis {
        try await classify(audioURL: videoURL, windowDuration: windowDuration)
    }

    // MARK: - Sync implementation

    private func classifySync(audioURL: URL, windowDuration: Double) throws -> AudioAnalysis {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let format = audioFile.processingFormat
        let duration = Double(audioFile.length) / format.sampleRate

        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)

        let delegate = AudioResultsDelegate()
        try analyzer.add(request, withObserver: delegate)

        // Process in chunks
        let bufferSize = AVAudioFrameCount(format.sampleRate * windowDuration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else {
            throw FrameworkError.invocationFailed("Could not allocate audio buffer")
        }

        while audioFile.framePosition < audioFile.length {
            let framesToRead = min(bufferSize, AVAudioFrameCount(audioFile.length - audioFile.framePosition))
            let positionBeforeRead = audioFile.framePosition
            buffer.frameLength = framesToRead
            try audioFile.read(into: buffer, frameCount: framesToRead)

            try analyzer.analyze(buffer, atAudioFramePosition: positionBeforeRead)
        }

        analyzer.completeAnalysis()

        // Aggregate results
        let timeSegments = delegate.results

        // Find dominant labels across all windows
        var labelCounts: [String: (total: Double, count: Int)] = [:]
        for segment in timeSegments {
            for label in segment.labels {
                var existing = labelCounts[label.label] ?? (total: 0, count: 0)
                existing.total += Double(label.confidence)
                existing.count += 1
                labelCounts[label.label] = existing
            }
        }

        let dominantLabels = labelCounts
            .map { AudioLabel(label: $0.key, confidence: Float($0.value.total / Double($0.value.count)), timeRange: nil) }
            .sorted { $0.confidence > $1.confidence }

        // Detect speech/music segments
        let hasSpeech = dominantLabels.contains { $0.label.lowercased().contains("speech") && $0.confidence > 0.3 }
        let hasMusic = dominantLabels.contains { $0.label.lowercased().contains("music") && $0.confidence > 0.3 }

        return AudioAnalysis(
            duration: duration,
            labels: Array(dominantLabels.prefix(20)),
            hasSpeech: hasSpeech,
            hasMusic: hasMusic,
            timeSegments: timeSegments
        )
    }
}

// MARK: - Internal delegate for collecting results

private class AudioResultsDelegate: NSObject, SNResultsObserving {
    var results: [AudioTimeSegment] = []

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }

        let labels = classification.classifications
            .filter { $0.confidence > 0.1 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)
            .map { AudioLabel(label: $0.identifier, confidence: Float($0.confidence), timeRange: nil) }

        let timeRange = classification.timeRange
        let start = CMTimeGetSeconds(timeRange.start)
        let end = CMTimeGetSeconds(CMTimeAdd(timeRange.start, timeRange.duration))

        results.append(AudioTimeSegment(
            startTime: start,
            endTime: end,
            labels: Array(labels)
        ))
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        // Classification failure for a window is non-fatal — we just skip it
    }

    func requestDidComplete(_ request: SNRequest) {
        // No-op — results already collected per-window
    }
}

// MARK: - Result types

public struct AudioAnalysis: Sendable {
    public let duration: Double
    public let labels: [AudioLabel]              // aggregated dominant sounds
    public let hasSpeech: Bool
    public let hasMusic: Bool
    public let timeSegments: [AudioTimeSegment]  // per-window detail

    public init(
        duration: Double,
        labels: [AudioLabel],
        hasSpeech: Bool,
        hasMusic: Bool,
        timeSegments: [AudioTimeSegment]
    ) {
        self.duration = duration
        self.labels = labels
        self.hasSpeech = hasSpeech
        self.hasMusic = hasMusic
        self.timeSegments = timeSegments
    }
}

public struct AudioLabel: Codable, Sendable {
    public let label: String
    public let confidence: Float
    public let timeRange: ClosedRange<Double>?

    public init(label: String, confidence: Float, timeRange: ClosedRange<Double>?) {
        self.label = label
        self.confidence = confidence
        self.timeRange = timeRange
    }

    // Custom Codable — ClosedRange isn't Codable by default
    enum CodingKeys: String, CodingKey {
        case label, confidence, timeStart, timeEnd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        confidence = try c.decode(Float.self, forKey: .confidence)
        let start = try c.decodeIfPresent(Double.self, forKey: .timeStart)
        let end = try c.decodeIfPresent(Double.self, forKey: .timeEnd)
        if let s = start, let e = end { timeRange = s...e } else { timeRange = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(confidence, forKey: .confidence)
        try c.encodeIfPresent(timeRange?.lowerBound, forKey: .timeStart)
        try c.encodeIfPresent(timeRange?.upperBound, forKey: .timeEnd)
    }
}

public struct AudioTimeSegment: Codable, Sendable {
    public let startTime: Double
    public let endTime: Double
    public let labels: [AudioLabel]

    public init(startTime: Double, endTime: Double, labels: [AudioLabel]) {
        self.startTime = startTime
        self.endTime = endTime
        self.labels = labels
    }
}
