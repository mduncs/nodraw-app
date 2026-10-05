import CoreGraphics

/// Full isolation result with per-instance subject data and optional semantic masks.
public struct IsolationResult: @unchecked Sendable {
    /// All detected subject instances with masks and contour paths.
    public let subjects: [SubjectInstance]
    /// Combined foreground mask (all subjects merged). nil if no subjects found.
    public let foregroundMask: CGImage?
    /// Optional masks keyed by requested type (sky, person matte, person instances, animal, etc.).
    public let semanticMasks: [SegmentationType: CGImage]
    /// Source image dimensions.
    public let imageSize: CGSize

    public init(
        subjects: [SubjectInstance],
        foregroundMask: CGImage?,
        semanticMasks: [SegmentationType: CGImage],
        imageSize: CGSize
    ) {
        self.subjects = subjects
        self.foregroundMask = foregroundMask
        self.semanticMasks = semanticMasks
        self.imageSize = imageSize
    }

    /// Number of detected subjects.
    public var subjectCount: Int { subjects.count }

    /// Whether any subjects were detected.
    public var hasSubjects: Bool { !subjects.isEmpty }
}

/// Person-specific segmentation result.
public struct PersonSegmentationResult: @unchecked Sendable {
    /// Soft alpha matte (grayscale, 0..1 range). nil if no person detected.
    public let mask: CGImage?
    /// Whether any person was detected.
    public let personDetected: Bool
    /// Quality level used.
    public let quality: SegmentationQuality

    public init(mask: CGImage?, personDetected: Bool, quality: SegmentationQuality) {
        self.mask = mask
        self.personDetected = personDetected
        self.quality = quality
    }
}
