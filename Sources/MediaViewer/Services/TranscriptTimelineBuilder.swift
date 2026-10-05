import Foundation

struct TranscriptToken: Hashable, Sendable {
    let token: String
    let startTime: Double
    let endTime: Double
    let confidence: Double
}

struct TranscriptWord: Hashable, Sendable {
    let text: String
    let startTime: Double
    let endTime: Double
    let confidence: Double
}

enum TranscriptTimelineBuilder {
    static let currentVersion = 1
    static let defaultModelName = "parakeet-tdt-0.6b-v3"

    private static let maxSegmentDuration: Double = 8
    private static let hardMaxSegmentDuration: Double = 12
    private static let maxPauseBetweenSegments: Double = 2
    private static let maxWordsPerSegment = 24
    private static let searchCaptionLimit = 900

    static func mergeTokensIntoWords(_ tokens: [TranscriptToken]) -> [TranscriptWord] {
        guard !tokens.isEmpty else { return [] }

        var words: [TranscriptWord] = []
        var currentText = ""
        var currentStart: Double?
        var currentEnd = 0.0
        var confidences: [Double] = []

        func flush() {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let start = currentStart else {
                currentText = ""
                currentStart = nil
                currentEnd = 0
                confidences = []
                return
            }

            let averageConfidence = confidences.isEmpty
                ? 0
                : confidences.reduce(0, +) / Double(confidences.count)
            words.append(
                TranscriptWord(
                    text: text,
                    startTime: start,
                    endTime: max(currentEnd, start + 0.001),
                    confidence: averageConfidence
                )
            )
            currentText = ""
            currentStart = nil
            currentEnd = 0
            confidences = []
        }

        for timing in tokens.sorted(by: { $0.startTime < $1.startTime }) {
            let normalizedToken = timing.token.replacingOccurrences(of: "▁", with: " ")
            let trimmedToken = normalizedToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedToken.isEmpty else {
                flush()
                continue
            }

            let startsNewWord = normalizedToken.first?.isWhitespace == true
            if startsNewWord {
                flush()
                currentText = trimmedToken
            } else {
                currentText += trimmedToken
            }

            if currentStart == nil {
                currentStart = timing.startTime
            }
            currentEnd = max(currentEnd, timing.endTime)
            confidences.append(timing.confidence)
        }

        flush()
        return words
    }

    static func buildSegments(
        itemId: UUID,
        mediaFileIndex: Int,
        sourcePath: String,
        transcriptText: String,
        transcriptConfidence: Double,
        tokens: [TranscriptToken],
        duration: Double,
        language: String?,
        model: String = defaultModelName
    ) -> [TranscriptSegment] {
        let words = mergeTokensIntoWords(tokens)
        if words.isEmpty {
            return buildFallbackSegment(
                itemId: itemId,
                mediaFileIndex: mediaFileIndex,
                sourcePath: sourcePath,
                transcriptText: transcriptText,
                transcriptConfidence: transcriptConfidence,
                duration: duration,
                language: language,
                model: model
            )
        }

        var segments: [TranscriptSegment] = []
        var current: [TranscriptWord] = []

        func flushCurrent() {
            guard let first = current.first, let last = current.last else { return }
            let text = joinWords(current)
            guard !text.isEmpty else {
                current.removeAll(keepingCapacity: true)
                return
            }

            let confidence = current.map(\.confidence).reduce(0, +) / Double(max(current.count, 1))
            segments.append(
                TranscriptSegment(
                    id: UUID(),
                    itemId: itemId,
                    mediaFileIndex: mediaFileIndex,
                    sourcePath: sourcePath,
                    startTime: max(0, first.startTime),
                    endTime: max(last.endTime, first.startTime + 0.1),
                    text: text,
                    confidence: confidence,
                    language: language,
                    model: model,
                    version: currentVersion
                )
            )
            current.removeAll(keepingCapacity: true)
        }

        for word in words {
            if let previous = current.last,
               word.startTime - previous.endTime >= maxPauseBetweenSegments {
                flushCurrent()
            }

            current.append(word)
            guard let first = current.first else { continue }
            let segmentDuration = word.endTime - first.startTime
            let sentenceEnded = hasSentenceEnding(word.text)
            let shouldBreak = current.count >= maxWordsPerSegment
                || segmentDuration >= hardMaxSegmentDuration
                || (segmentDuration >= maxSegmentDuration && sentenceEnded)
            if shouldBreak {
                flushCurrent()
            }
        }
        flushCurrent()

        return segments
    }

    static func makeSearchCaption(
        segments: [TranscriptSegment],
        existingCaption: String?
    ) -> String? {
        let speechText = segments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speechText.isEmpty else {
            let caption = existingCaption
                .flatMap { captionBeforeSpeechMarker($0) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return caption?.isEmpty == false ? caption : nil
        }

        let speechCaption = "Speech: \(speechText)"
        let baseCaption = existingCaption
            .flatMap { captionBeforeSpeechMarker($0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let combined: String
        if let baseCaption, !baseCaption.isEmpty {
            combined = "\(baseCaption). \(speechCaption)"
        } else {
            combined = speechCaption
        }

        return String(combined.prefix(searchCaptionLimit))
    }

    private static func buildFallbackSegment(
        itemId: UUID,
        mediaFileIndex: Int,
        sourcePath: String,
        transcriptText: String,
        transcriptConfidence: Double,
        duration: Double,
        language: String?,
        model: String
    ) -> [TranscriptSegment] {
        let text = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        return [
            TranscriptSegment(
                id: UUID(),
                itemId: itemId,
                mediaFileIndex: mediaFileIndex,
                sourcePath: sourcePath,
                startTime: 0,
                endTime: max(duration, 0.1),
                text: text,
                confidence: transcriptConfidence,
                language: language,
                model: model,
                version: currentVersion
            )
        ]
    }

    private static func joinWords(_ words: [TranscriptWord]) -> String {
        var result = ""
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if result.isEmpty || shouldAttachToPrevious(text) {
                result += text
            } else {
                result += " \(text)"
            }
        }
        return result
    }

    private static func hasSentenceEnding(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".!?".contains(last)
    }

    private static func shouldAttachToPrevious(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return ".,!?;:%)]}\"'".contains(first)
    }

    private static func captionBeforeSpeechMarker(_ caption: String) -> String? {
        guard let range = caption.range(of: "Speech:", options: [.caseInsensitive]) else {
            return caption
        }

        let before = String(caption[..<range.lowerBound])
        return before.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }
}
