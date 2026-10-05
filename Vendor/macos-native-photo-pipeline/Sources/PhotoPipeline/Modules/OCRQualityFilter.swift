import Foundation

/// Post-OCR quality filter to remove garbled/noise text from recognition results.
///
/// **This is a library addition, not Apple behavior.** Photos.app stores ALL OCR
/// results with non-empty transcripts — no per-line confidence filtering. The only
/// upstream gate is a scene-level "contains text" check at 0.11 confidence, which
/// lets almost everything through.
///
/// This filter sits between OCR output and your storage/UI layer. It removes
/// low-confidence noise that would pollute search indices: texture patterns
/// misread as characters, bokeh circles → "OOO", wood grain → "lll", etc.
///
/// ```swift
/// let recognizer = try TextRecognizer(qualityFilter: .default)
/// // garbled lines are already filtered out
/// let clean = try await recognizer.recognize(image: cgImage)
///
/// // or apply manually:
/// let filter = OCRQualityFilter.strict
/// let cleaned = filter.apply(rawObservations)
/// ```
public struct OCRQualityFilter: Sendable, Codable {

    /// Minimum per-line confidence from VNRecognizeTextRequest.
    ///
    /// VNRecognizeTextRequest in `.accurate` mode returns a float confidence per
    /// recognized line. Real text typically scores > 0.5. Garbled noise from
    /// textures/patterns typically scores < 0.2.
    ///
    /// Default: 0.25 — catches the worst noise while keeping borderline text.
    public var minimumConfidence: Float

    /// Minimum text length (characters) to keep.
    ///
    /// Single-character detections from texture patterns, dots, or edge artifacts
    /// are almost never useful. Default: 2.
    public var minimumLength: Int

    /// Maximum ratio of non-alphanumeric, non-space characters.
    ///
    /// Catches things like "|||///\\\---" from fences, blinds, barcodes read as
    /// text. A line that's 70%+ symbols is probably not meaningful text.
    ///
    /// Default: 0.7 (allows things like "C++ Programming" or "$19.99").
    public var maximumSymbolRatio: Float

    /// Minimum ratio of word-like tokens in the line.
    ///
    /// A "word-like" token is 2+ letters, optionally with an apostrophe.
    /// "aX 3 qW zz" has 0/4 word-like tokens → ratio 0.0.
    /// "Hello World 3" has 2/3 word-like tokens → ratio 0.67.
    ///
    /// Set to 0 to disable. Default: 0.0 (disabled — confidence handles most cases).
    public var minimumWordRatio: Float

    // MARK: - Presets

    /// Default filter. Catches obvious noise, keeps most real text.
    public static let `default` = OCRQualityFilter()

    /// Strict filter for clean search indices. Drops borderline text.
    public static let strict = OCRQualityFilter(
        minimumConfidence: 0.5,
        minimumLength: 3,
        maximumSymbolRatio: 0.5,
        minimumWordRatio: 0.3
    )

    /// Permissive filter. Only drops the most egregious garbage.
    public static let permissive = OCRQualityFilter(
        minimumConfidence: 0.1,
        minimumLength: 1,
        maximumSymbolRatio: 0.9,
        minimumWordRatio: 0.0
    )

    /// No filtering — matches Apple's behavior (store everything).
    public static let none = OCRQualityFilter(
        minimumConfidence: 0.0,
        minimumLength: 0,
        maximumSymbolRatio: 1.0,
        minimumWordRatio: 0.0
    )

    // MARK: - Init

    public init(
        minimumConfidence: Float = 0.25,
        minimumLength: Int = 2,
        maximumSymbolRatio: Float = 0.7,
        minimumWordRatio: Float = 0.0
    ) {
        self.minimumConfidence = minimumConfidence
        self.minimumLength = minimumLength
        self.maximumSymbolRatio = maximumSymbolRatio
        self.minimumWordRatio = minimumWordRatio
    }

    // MARK: - Filtering

    /// Filter an array of observations, removing low-quality lines.
    public func apply(_ observations: [TextObservation]) -> [TextObservation] {
        observations.filter { passes($0) }
    }

    /// Check whether a single observation passes the quality filter.
    public func passes(_ obs: TextObservation) -> Bool {
        // Confidence gate
        guard obs.confidence >= minimumConfidence else { return false }

        // Length gate
        let text = obs.text
        guard text.count >= minimumLength else { return false }

        // Symbol ratio gate
        let alnumOrSpace = text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }.count
        let symbolRatio = 1.0 - Float(alnumOrSpace) / Float(max(text.count, 1))
        guard symbolRatio <= maximumSymbolRatio else { return false }

        // Word ratio gate (if enabled)
        if minimumWordRatio > 0 {
            let tokens = text.split(separator: " ")
            guard !tokens.isEmpty else { return false }
            let wordLike = tokens.filter { token in
                let letters = token.filter { $0.isLetter }
                return letters.count >= 2
            }
            let ratio = Float(wordLike.count) / Float(tokens.count)
            guard ratio >= minimumWordRatio else { return false }
        }

        return true
    }

    /// Filter and return both kept and rejected observations (for diagnostics).
    public func partition(_ observations: [TextObservation]) -> (kept: [TextObservation], rejected: [TextObservation]) {
        var kept: [TextObservation] = []
        var rejected: [TextObservation] = []
        for obs in observations {
            if passes(obs) {
                kept.append(obs)
            } else {
                rejected.append(obs)
            }
        }
        return (kept, rejected)
    }
}
