import Foundation
import PhotoPipeline

enum VideoTimelineBuilder {
    static let currentVersion = 1
    static let analysisSource = "native_vision"

    private struct FrameSnapshot {
        let time: Double
        let labels: [VideoSegmentLabel]
        let qualityScore: Double

        var labelSet: Set<String> {
            Set(labels.prefix(4).map(\.label))
        }
    }

    static func buildSegments(
        itemId: UUID,
        mediaFileIndex: Int,
        sourcePath: String,
        analysis: VideoAnalysis
    ) -> [VideoSegment] {
        let snapshots = analysis.frameAnalyses
            .sorted { $0.time < $1.time }
            .map(makeSnapshot)

        guard !snapshots.isEmpty else {
            return buildFallbackSegment(
                itemId: itemId,
                mediaFileIndex: mediaFileIndex,
                sourcePath: sourcePath,
                analysis: analysis
            )
        }

        let interval = typicalInterval(for: snapshots.map(\.time), duration: analysis.duration)
        let maxGap = max(interval * 1.75, 6.0)
        var groups: [[FrameSnapshot]] = []

        for snapshot in snapshots {
            guard var current = groups.popLast(), let previous = current.last else {
                groups.append([snapshot])
                continue
            }

            if shouldMerge(previous: previous, current: snapshot, maxGap: maxGap) {
                current.append(snapshot)
                groups.append(current)
            } else {
                groups.append(current)
                groups.append([snapshot])
            }
        }

        return groups.enumerated().compactMap { index, group in
            guard let first = group.first, let last = group.last else { return nil }
            let nextStart = index + 1 < groups.count ? groups[index + 1].first?.time : nil
            let start = max(0, first.time)
            let naturalEnd = nextStart ?? min(max(analysis.duration, start + interval), last.time + interval)
            let end = max(start + min(interval, 1.0), naturalEnd)
            let labels = aggregateLabels(in: group)
            let summary = summarize(labels: labels)
            let confidence = confidenceScore(group: group, labels: labels)

            return VideoSegment(
                id: UUID(),
                itemId: itemId,
                mediaFileIndex: mediaFileIndex,
                sourcePath: sourcePath,
                startTime: start,
                endTime: end,
                summary: summary,
                labels: labels,
                confidence: confidence,
                analysisSource: analysisSource,
                version: currentVersion
            )
        }
    }

    static func makeSearchCaption(segments: [VideoSegment], duration: Double) -> String? {
        guard !segments.isEmpty else { return nil }

        let topLabels = topLabels(from: segments, limit: 8)
        let labelText = topLabels.isEmpty ? nil : topLabels.joined(separator: ", ")

        let timelineText = segments.prefix(8)
            .map { "\(VideoSegment.formatTime($0.startTime)) \($0.summary)" }
            .joined(separator: "; ")

        var parts: [String] = []
        if let labelText, !labelText.isEmpty {
            parts.append("Video: \(labelText)")
        }
        if !timelineText.isEmpty {
            parts.append("Timeline: \(timelineText)")
        }

        let caption = parts.joined(separator: ". ")
        guard !caption.isEmpty else { return nil }
        return String(caption.prefix(600))
    }

    static func samplingFramesPerSecond(for duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0.2 }
        return min(1.0, max(0.001, 60.0 / duration))
    }

    private static func makeSnapshot(from frame: FrameAnalysis) -> FrameSnapshot {
        let labels = frame.labels
            .filter { $0.confidence >= 0.18 }
            .prefix(5)
            .map {
                VideoSegmentLabel(
                    label: cleanLabel($0.label),
                    confidence: Double($0.confidence)
                )
            }

        return FrameSnapshot(
            time: frame.time,
            labels: Array(labels),
            qualityScore: Double(frame.qualityScore)
        )
    }

    private static func shouldMerge(previous: FrameSnapshot, current: FrameSnapshot, maxGap: Double) -> Bool {
        guard current.time - previous.time <= maxGap else { return false }

        let previousLabels = previous.labelSet
        let currentLabels = current.labelSet
        if previousLabels.isEmpty || currentLabels.isEmpty {
            return previousLabels.isEmpty && currentLabels.isEmpty
        }
        return !previousLabels.intersection(currentLabels).isEmpty
    }

    private static func aggregateLabels(in group: [FrameSnapshot]) -> [VideoSegmentLabel] {
        struct Stats {
            var total: Double
            var count: Int
        }

        var stats: [String: Stats] = [:]
        for frame in group {
            for label in frame.labels {
                var current = stats[label.label] ?? Stats(total: 0, count: 0)
                current.total += label.confidence
                current.count += 1
                stats[label.label] = current
            }
        }

        return stats.map { label, value in
            VideoSegmentLabel(label: label, confidence: value.total / Double(max(value.count, 1)))
        }
        .sorted {
            if abs($0.confidence - $1.confidence) > 0.001 {
                return $0.confidence > $1.confidence
            }
            return $0.label < $1.label
        }
        .prefix(4)
        .map { $0 }
    }

    private static func confidenceScore(group: [FrameSnapshot], labels: [VideoSegmentLabel]) -> Double {
        let labelScore = labels.first?.confidence ?? 0
        let quality = group.map(\.qualityScore).reduce(0, +) / Double(max(group.count, 1))
        return min(1.0, max(0, (labelScore * 0.75) + (quality * 0.25)))
    }

    private static func summarize(labels: [VideoSegmentLabel]) -> String {
        let names = labels.prefix(3).map(\.label).filter { !$0.isEmpty }
        guard !names.isEmpty else { return "visual scene" }
        return names.joined(separator: ", ")
    }

    private static func topLabels(from segments: [VideoSegment], limit: Int) -> [String] {
        struct Stats {
            var total: Double
            var count: Int
        }

        var stats: [String: Stats] = [:]
        for segment in segments {
            for label in segment.labels {
                var current = stats[label.label] ?? Stats(total: 0, count: 0)
                current.total += label.confidence
                current.count += 1
                stats[label.label] = current
            }
        }

        return stats.map { label, value in
            (label: label, count: value.count, average: value.total / Double(max(value.count, 1)))
        }
        .sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if abs($0.average - $1.average) > 0.001 { return $0.average > $1.average }
            return $0.label < $1.label
        }
        .prefix(limit)
        .map(\.label)
    }

    private static func buildFallbackSegment(
        itemId: UUID,
        mediaFileIndex: Int,
        sourcePath: String,
        analysis: VideoAnalysis
    ) -> [VideoSegment] {
        let labels = analysis.labels.prefix(4).map {
            VideoSegmentLabel(label: cleanLabel($0.label), confidence: Double($0.confidence))
        }
        guard !labels.isEmpty else { return [] }

        return [
            VideoSegment(
                id: UUID(),
                itemId: itemId,
                mediaFileIndex: mediaFileIndex,
                sourcePath: sourcePath,
                startTime: 0,
                endTime: max(analysis.duration, 1),
                summary: summarize(labels: labels),
                labels: Array(labels),
                confidence: labels.first?.confidence ?? 0,
                analysisSource: analysisSource,
                version: currentVersion
            )
        ]
    }

    private static func typicalInterval(for times: [Double], duration: Double) -> Double {
        let gaps = zip(times, times.dropFirst())
            .map { $1 - $0 }
            .filter { $0.isFinite && $0 > 0 }
            .sorted()

        if !gaps.isEmpty {
            return gaps[gaps.count / 2]
        }

        if duration.isFinite, duration > 0 {
            return max(1.0, duration / Double(max(times.count, 1)))
        }

        return 1.0
    }

    private static func cleanLabel(_ label: String) -> String {
        label
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
