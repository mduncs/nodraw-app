import CoreGraphics

/// Glow rendering configuration.
/// Values reverse-engineered from VKCGlowParameters in VisionKitCore.
///
/// Two parameter sets produce the characteristic subject glow:
/// - **Thin**: crisp outline, 6-12 strokes depending on screen DPI, full opacity
/// - **Thick**: diffuse bloom, 3 strokes, lower opacity with gaussian blur
internal struct GlowParameters {
    /// Minimum stroke thickness (points).
    let minThickness: CGFloat
    /// Maximum stroke thickness (points).
    let maxThickness: CGFloat
    /// Gaussian blur radius for the glow container.
    let blurRadius: CGFloat
    /// Fraction of the path length each stroke segment covers (0.25 = 25%).
    let strokeLengthFraction: CGFloat
    /// Taper length at stroke endpoints (points).
    let strokeTaperLength: CGFloat
    /// Minimum opacity across stroke variations.
    let minOpacity: CGFloat
    /// Maximum opacity across stroke variations.
    let maxOpacity: CGFloat
    /// Number of animated stroke layers.
    let strokeCount: Int

    /// Thin glow: crisp outline with full opacity.
    /// Stroke count varies by screen DPI: 1x=6, 2x=8, 3x=12.
    static func thin(viewScale: CGFloat, screenScale: CGFloat) -> GlowParameters {
        let strokeCount: Int
        switch screenScale {
        case 1.0: strokeCount = 6
        case 2.0: strokeCount = 8
        default:  strokeCount = 12
        }

        return GlowParameters(
            minThickness: viewScale * 0.5,
            maxThickness: viewScale * 1.5,
            blurRadius: viewScale * 1.5,
            strokeLengthFraction: 0.25,
            strokeTaperLength: viewScale * 200.0,
            minOpacity: 1.0,
            maxOpacity: 1.0,
            strokeCount: strokeCount
        )
    }

    /// Thick glow: diffuse bloom with lower opacity.
    /// Always 3 strokes regardless of DPI.
    static func thick(viewScale: CGFloat) -> GlowParameters {
        GlowParameters(
            minThickness: viewScale * 4.0,
            maxThickness: viewScale * 16.0,
            blurRadius: viewScale * 20.0,
            strokeLengthFraction: 0.25,
            strokeTaperLength: viewScale * 200.0,
            minOpacity: 0.3,
            maxOpacity: 0.5,
            strokeCount: 3
        )
    }

    /// Calculate glow animation cycle duration from path length.
    /// Formula: clamp(pathLength / 600, 4.5, 6.0) seconds.
    /// Full ping-pong cycle is 2x this value (9-12 seconds).
    static func cycleDuration(pathLength: CGFloat) -> CGFloat {
        min(max(pathLength / 600.0, 4.5), 6.0)
    }

    /// Glow fade-in duration (seconds). Matches Apple's 2.0s constant.
    static let fadeInDuration: CGFloat = 2.0

    /// Opacity transition duration for highlight toggle (~0.35s).
    static let opacityTransitionDuration: CGFloat = 0.35

    /// Color matrix for glow tint (warm blue-white).
    /// Applied via CAFilter("colorMatrix") on glow containers.
    ///
    /// Matrix (row-major, 5x4):
    /// ```
    ///      R      G      B      A      Bias
    /// R  [ 1.0    0.0    0.0    0.0    0.5  ]   // red pass-through + heavy bias
    /// G  [ 0.0    1.0    0.0    0.0    0.15 ]   // green + slight bias
    /// B  [ 0.0    0.0    1.0    0.4   -0.05 ]   // blue from alpha + slight negative
    /// A  [ 0.0    0.0    0.0    1.0    0.3  ]   // alpha boost
    /// ```
    static let colorMatrixValues: [[CGFloat]] = [
        [1.0, 0.0, 0.0, 0.0, 0.5],
        [0.0, 1.0, 0.0, 0.0, 0.15],
        [0.0, 0.0, 1.0, 0.4, -0.05],
        [0.0, 0.0, 0.0, 1.0, 0.3],
    ]
}
