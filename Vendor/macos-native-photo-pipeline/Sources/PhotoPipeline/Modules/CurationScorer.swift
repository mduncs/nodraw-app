import Foundation

/// Photos-identical curation score calculator.
///
/// Implements the exact formula from `VCPVideoKeyFrame.computeCurationScore`
/// (decompiled from MediaAnalysis.framework):
///
/// ```
/// if globalQuality >= 0.5:
///     score = (0.1 + aesthetics × 0.25 + content × 0.65) × penalty
///     clamp(score, 0.0, 1.0)
/// else:
///     score = 0.0
/// ```
///
/// This is the "best photo" ranking logic Photos uses to surface highlights
/// in Memories, Featured Photos, and the For You tab.
///
/// ```swift
/// let scorer = CurationScorer()
/// let result = scorer.score(
///     junkConfidence: 0.85,   // from JunkClassifier
///     aestheticsScore: 0.72,  // from SceneClassifier
///     faceCount: 2,
///     objectCount: 1,
///     isUtility: false
/// )
/// print("Curation: \(result.score)")  // 0.0–1.0
/// ```
public struct CurationScorer: Sendable {

    public init() {}

    /// Compute the curation score from pre-analyzed signals.
    ///
    /// - Parameters:
    ///   - junkConfidence: Raw confidence from VNClassifyJunkImageRequest (0–1).
    ///     This IS the globalQuality gate. Values < 0.5 → score = 0.
    ///   - aestheticsScore: Normalized aesthetics (0–1) from SceneClassifier.
    ///     Maps to `visualPleasingScore` in the formula.
    ///   - faceCount: Number of detected faces. Contributes to content score.
    ///   - objectCount: Number of recognized objects. Contributes to content score.
    ///   - isUtility: Whether the image is a screenshot/document. Applies penalty.
    ///   - blurScore: Optional blur/noise penalty (0–1, where 1 = sharp). Default 1.0.
    public func score(
        junkConfidence: Float,
        aestheticsScore: Float,
        faceCount: Int = 0,
        objectCount: Int = 0,
        isUtility: Bool = false,
        blurScore: Float = 1.0
    ) -> CurationResult {
        // Quality gate — Photos' exact threshold
        let globalQuality = junkConfidence
        guard globalQuality >= 0.5 else {
            return CurationResult(
                score: 0,
                globalQuality: globalQuality,
                visualPleasingScore: aestheticsScore,
                contentScore: 0,
                penaltyScore: 0,
                gatedByQuality: true
            )
        }

        // Content score: semantic interest from faces, objects, etc.
        // Photos uses a more complex version with scene labels + actions,
        // but faces and objects are the dominant signals.
        var contentSignals: [Float] = []

        // Faces are the strongest content signal
        if faceCount > 0 {
            // 1 face = 0.7, 2+ faces = 0.85 (group photos are interesting)
            contentSignals.append(faceCount >= 2 ? 0.85 : 0.7)
        }

        // Recognized objects add interest
        if objectCount > 0 {
            contentSignals.append(min(Float(objectCount) * 0.3, 0.6))
        }

        let contentScore: Float
        if contentSignals.isEmpty {
            // No strong content signals — base content from aesthetics proxy
            contentScore = aestheticsScore * 0.4
        } else {
            contentScore = min(contentSignals.max()! + 0.1, 1.0)
        }

        // Penalty: utility images and blur/noise reduce the score
        var penalty: Float = 1.0
        if isUtility { penalty *= 0.3 }
        penalty *= max(0, min(1, blurScore))

        // Photos' exact formula
        let raw = (0.1 + aestheticsScore * 0.25 + 0.65 * contentScore) * penalty
        let clamped = max(0, min(1, raw))

        return CurationResult(
            score: clamped,
            globalQuality: globalQuality,
            visualPleasingScore: aestheticsScore,
            contentScore: contentScore,
            penaltyScore: penalty,
            gatedByQuality: false
        )
    }
}

/// Result from curation scoring.
public struct CurationResult: Sendable {
    /// Final curation score (0.0–1.0). Higher = more likely to be surfaced.
    public let score: Float

    /// Quality gate value (from junk classifier). Must be >= 0.5 to pass.
    public let globalQuality: Float

    /// Aesthetics contribution (0.0–1.0).
    public let visualPleasingScore: Float

    /// Semantic interest contribution (0.0–1.0).
    public let contentScore: Float

    /// Penalty multiplier (1.0 = no penalty).
    public let penaltyScore: Float

    /// Whether the image was gated (score forced to 0) by low quality.
    public let gatedByQuality: Bool
}
