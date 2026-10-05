import Foundation

/// Available segmentation types.
/// Public types work on macOS 14+. Private types require runtime class probing.
public enum SegmentationType: String, CaseIterable, Sendable {
    /// Per-instance foreground masks (public, macOS 14+).
    /// Primary "Copy Subject" API.
    case foregroundInstance

    /// Per-person instance masks, max 4 people (public, macOS 14+).
    case personInstance

    /// Person vs background segmentation (public, macOS 14+).
    case personSegmentation

    /// Sky region mask (private/macOS 15+).
    case sky

    /// Glasses region mask (private/macOS 15+).
    case glasses

    /// Hair/skin/clothing attribute regions (private/macOS 15+).
    case humanAttributes

    /// Animal segmentation (private/macOS 15+).
    case animal
}

/// Segmentation quality level.
/// Values are mapped explicitly to `VNGeneratePersonSegmentationRequest.QualityLevel`;
/// do not pass raw values through to Vision.
public enum SegmentationQuality: Int, Sendable {
    /// Fast — lightweight model, lower quality.
    case fast = 0
    /// Balanced — routes through multi-head model internally.
    case balanced = 1
    /// Accurate — fast model + learned matting refinement (tiled, fp16).
    case accurate = 2
}

/// Options for the `isolate()` call.
public struct IsolationOptions: Sendable {
    /// Which segmentation types to request.
    public var requestedTypes: Set<SegmentationType>
    /// Whether to generate contour paths (needed for UI glow).
    public var generatePaths: Bool
    /// Contour simplification tolerance (0 = exact, higher = simpler path).
    public var contourSimplification: CGFloat

    public init(
        requestedTypes: Set<SegmentationType> = [.foregroundInstance],
        generatePaths: Bool = true,
        contourSimplification: CGFloat = 0.005
    ) {
        self.requestedTypes = requestedTypes
        self.generatePaths = generatePaths
        self.contourSimplification = contourSimplification
    }

    /// Default: foreground instances with paths.
    public static let `default` = IsolationOptions()

    /// All available segmentation types with paths.
    public static let allTypes = IsolationOptions(
        requestedTypes: Set(SegmentationType.allCases),
        generatePaths: true,
        contourSimplification: 0.005
    )
}
