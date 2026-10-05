import Foundation
import CoreGraphics

/// Scene classification result from VisionCore/MonzaV4.
public struct SceneClassification: Sendable, Hashable {
    public let label: String
    public let confidence: Float

    public init(label: String, confidence: Float) {
        self.label = label
        self.confidence = confidence
    }
}

/// Full scene analysis result — multiple heads from a single backbone pass.
public struct SceneResult: Sendable {
    /// Scene labels ranked by confidence (e.g. "Beach", "Golden Hour").
    public let labels: [SceneClassification]
    /// Aesthetic quality score normalized to 0.0–1.0 for display.
    /// Derived from VNCalculateImageAestheticsScoresRequest overallScore.
    public let aestheticsScore: Float
    /// 768-float sceneprint embedding from VNGenerateImageFeaturePrintRequest.
    /// Used for image similarity search (cosine distance).
    public let embedding: [Float]?
    /// Whether the image was classified as junk (poor quality or tragic failure).
    public let isJunk: Bool
    /// Whether the image is utility (screenshot, receipt, document).
    public let isUtility: Bool
    /// Detailed aesthetics breakdown from private VN requests (nil if unavailable).
    public let aestheticsDetail: AestheticsDetail?
    /// Attention saliency bounding box (normalized 0–1 coordinates).
    public let saliencyBox: CGRect?
    /// Number of faces detected in the image.
    public let faceCount: Int

    public init(
        labels: [SceneClassification],
        aestheticsScore: Float = 0,
        embedding: [Float]? = nil,
        isJunk: Bool = false,
        isUtility: Bool = false,
        aestheticsDetail: AestheticsDetail? = nil,
        saliencyBox: CGRect? = nil,
        faceCount: Int = 0
    ) {
        self.labels = labels
        self.aestheticsScore = aestheticsScore
        self.embedding = embedding
        self.isJunk = isJunk
        self.isUtility = isUtility
        self.aestheticsDetail = aestheticsDetail
        self.saliencyBox = saliencyBox
        self.faceCount = faceCount
    }
}

/// Detailed aesthetics breakdown from Apple's private VN aesthetics requests.
public struct AestheticsDetail: Sendable {
    /// Raw overall score from VNCalculateImageAestheticsScoresRequest.
    /// Range roughly -1 to +1 (negative = poor, positive = good).
    public let overallScore: Float
    /// Whether classified as utility (screenshot, receipt, document).
    public let isUtility: Bool
    /// Per-category quality scores from VNCalculateImageAestheticsScoresRequest.
    /// Keys: failureScore, poorQualityScore, nonMemorableScore, screenShotScore, etc.
    public let qualityScores: [String: Float]
    /// Per-attribute aesthetic sub-scores from VNClassifyImageAestheticsRequest.
    /// Keys: wellFramedSubjectScore, pleasantLightingScore, harmoniousColorScore, etc.
    public let subscores: [String: Float]

    public init(
        overallScore: Float = 0,
        isUtility: Bool = false,
        qualityScores: [String: Float] = [:],
        subscores: [String: Float] = [:]
    ) {
        self.overallScore = overallScore
        self.isUtility = isUtility
        self.qualityScores = qualityScores
        self.subscores = subscores
    }

    /// Sub-score property names on VNImageAestheticsObservation.
    public static let subscoreKeys: [String] = [
        "aestheticScore", "wellFramedSubjectScore", "wellChosenBackgroundScore",
        "tastefullyBlurredScore", "sharplyFocusedSubjectScore", "wellTimedShotScore",
        "pleasantLightingScore", "pleasantReflectionsScore", "harmoniousColorScore",
        "livelyColorScore", "pleasantSymmetryScore", "pleasantPatternScore",
        "immersivenessScore", "pleasantPerspectiveScore", "pleasantPostProcessingScore",
        "noiseScore", "failureScore", "pleasantCompositionScore",
        "interestingSubjectScore", "intrusiveObjectPresenceScore",
        "pleasantCameraTiltScore", "lowKeyLightingScore"
    ]

    /// Quality score keys from VNImageAestheticsScoresObservation.
    public static let qualityKeys: [String] = [
        "failureScore", "junkNegativeScore", "junkTragicFailureScore",
        "poorQualityScore", "nonMemorableScore", "screenShotScore",
        "receiptOrDocumentScore", "textDocumentScore"
    ]
}

/// Object recognition domain — Apple's GNN domain categories.
public enum RecognitionDomain: Int, Sendable, Hashable, CaseIterable {
    case unknown = 0
    case art = 1
    case plants = 2
    case landmark = 3
    case cats = 4
    case dogs = 5
    case birds = 8
    case insects = 9
    case naturalLandmark = 10
    case sculpture = 11
    case skyline = 12
    case mammals = 13
    case reptiles = 14
    case food = 16
}

/// A single recognized object/entity in an image.
public struct Recognition: Sendable {
    public let domain: RecognitionDomain
    public let name: String
    public let confidence: Float
    public let embedding: [Float]?
    public let boundingBox: CGRect?

    public init(
        domain: RecognitionDomain,
        name: String,
        confidence: Float,
        embedding: [Float]? = nil,
        boundingBox: CGRect? = nil
    ) {
        self.domain = domain
        self.name = name
        self.confidence = confidence
        self.embedding = embedding
        self.boundingBox = boundingBox
    }
}

/// Text observation from OCR.
public struct TextObservation: Sendable {
    public let text: String
    public let boundingBox: CGRect
    public let confidence: Float
    public let language: String?

    public init(text: String, boundingBox: CGRect, confidence: Float, language: String? = nil) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.language = language
    }
}

// MARK: - Text Layout Types

/// How to group recognized text lines into higher-level structures.
public enum TextGrouping: Sendable {
    /// Raw per-line observations, no grouping. Fastest.
    case line
    /// Spatial proximity grouping into paragraphs/text blocks.
    /// Groups lines that are vertically adjacent with similar horizontal alignment.
    case block
    /// Column-aware layout: detects columns first, then groups within each column.
    /// Use for multi-column documents, newspapers, side-by-side text.
    case column
    /// Full document layout: columns + reading order + structural roles
    /// (header, body, caption, sidebar). Most expensive spatial heuristic.
    case document
    /// Apple's neural text detection pipeline (CRTextDetectionPipeline).
    /// Uses the same cr_td_model_v3 neural network that Photos.app uses to
    /// detect text blocks before OCR. Block boundaries come from the model,
    /// not spatial heuristics. Falls back to `.document` if unavailable.
    case neural
}

/// A block of grouped text lines forming a logical unit (paragraph, heading, etc.).
public struct TextBlock: Sendable, Identifiable {
    public let id: String
    /// Combined text of all lines in this block.
    public let text: String
    /// Individual line observations that make up this block.
    public let lines: [TextObservation]
    /// Bounding box enclosing all lines.
    public let boundingBox: CGRect
    /// Average confidence across all lines.
    public let confidence: Float
    /// Structural role (only populated with `.document` grouping).
    public let role: TextRole
    /// Column index (0-based, only populated with `.column`/`.document` grouping).
    public let columnIndex: Int

    public init(
        id: String = UUID().uuidString,
        text: String,
        lines: [TextObservation],
        boundingBox: CGRect,
        confidence: Float,
        role: TextRole = .body,
        columnIndex: Int = 0
    ) {
        self.id = id
        self.text = text
        self.lines = lines
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.role = role
        self.columnIndex = columnIndex
    }
}

/// Structural role of a text block within a document.
public enum TextRole: String, Sendable {
    /// Main body text.
    case body
    /// Heading/title (larger text, top of page or section).
    case heading
    /// Caption or footnote (smaller text, near image or bottom).
    case caption
    /// Sidebar or marginal note.
    case sidebar
    /// Table cell content.
    case tableCell
    /// Form field label.
    case formLabel
    /// Form field value.
    case formValue
}

/// Full document layout result from `.document` grouping.
public struct DocumentLayout: Sendable {
    /// All text blocks in reading order.
    public let blocks: [TextBlock]
    /// Detected number of columns.
    public let columnCount: Int
    /// Detected reading direction.
    public let readingDirection: ReadingDirection
    /// Whether form/table structure was detected.
    public let hasFormStructure: Bool
    /// Whether table structure was detected.
    public let hasTableStructure: Bool

    public init(
        blocks: [TextBlock],
        columnCount: Int = 1,
        readingDirection: ReadingDirection = .leftToRight,
        hasFormStructure: Bool = false,
        hasTableStructure: Bool = false
    ) {
        self.blocks = blocks
        self.columnCount = columnCount
        self.readingDirection = readingDirection
        self.hasFormStructure = hasFormStructure
        self.hasTableStructure = hasTableStructure
    }
}

/// Text reading direction.
public enum ReadingDirection: String, Sendable {
    case leftToRight
    case rightToLeft
    case topToBottom
}

/// Face match from the gallery.
public struct FaceMatch: Sendable {
    public let identityID: String
    public let identityName: String?
    public let confidence: Float
    public let boundingBox: CGRect

    public init(identityID: String, identityName: String? = nil, confidence: Float, boundingBox: CGRect) {
        self.identityID = identityID
        self.identityName = identityName
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// A known person/pet identity in the face gallery.
public struct Identity: Sendable, Identifiable {
    public let id: String
    public var name: String?
    public let observationCount: Int
    public let isHuman: Bool

    public init(id: String, name: String? = nil, observationCount: Int = 0, isHuman: Bool = true) {
        self.id = id
        self.name = name
        self.observationCount = observationCount
        self.isHuman = isHuman
    }
}
