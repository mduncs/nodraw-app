import Foundation
import CoreGraphics

/// How a search result was matched.
public enum MatchType: String, Sendable, Hashable {
    /// CLIP semantic similarity (text↔image embedding).
    case embedding
    /// Scene label keyword match (e.g. "beach").
    case scene
    /// Object/breed/food/landmark recognition match.
    case object
    /// Face identity match.
    case face
    /// OCR text content match.
    case text
}

/// A unified search result from any combination of modules.
public struct SearchResult: Sendable, Identifiable {
    public let id: String
    public let assetID: String
    public let score: Float
    public let matchType: MatchType
    public let detail: String

    public init(assetID: String, score: Float, matchType: MatchType, detail: String) {
        self.id = "\(assetID)-\(matchType.rawValue)"
        self.assetID = assetID
        self.score = score
        self.matchType = matchType
        self.detail = detail
    }
}

/// Result from indexing a single image across enabled modules.
public struct IndexResult: Sendable {
    /// Number of analysis modules that completed successfully.
    public let modulesSucceeded: Int
    /// Per-module failure descriptions (empty if all succeeded).
    public let failures: [String]
    /// Modules skipped by scene gating (e.g. "face: no faces in scene").
    public let skipped: [String]

    public var allSucceeded: Bool { failures.isEmpty }
}

/// All analysis data for a single indexed asset.
public struct AssetAnalysis: Sendable, Identifiable {
    public let id: String  // assetID
    public let assetID: String
    public let sceneLabels: [SceneClassification]
    public let aestheticsScore: Float
    public let isJunk: Bool
    public let isUtility: Bool
    public let faceCount: Int
    public let textObservations: [TextObservation]
    public let ocrText: String  // joined text for display
    public let objectRecognitions: [Recognition]
    /// OCR quality filter diagnostics. nil if filter was disabled.
    public let ocrRawLineCount: Int?
    public let ocrKeptLineCount: Int?
    /// How many lines the quality filter dropped (0 if filter disabled).
    public var ocrDroppedLineCount: Int {
        guard let raw = ocrRawLineCount, let kept = ocrKeptLineCount else { return 0 }
        return raw - kept
    }
    /// Raw junk confidence from VNClassifyJunkImageRequest (0–1). Higher = better quality.
    /// nil if junk classifier wasn't run.
    public let junkConfidence: Float?
    /// Which junk classification method was used.
    public let junkSource: JunkResult.Source?
    /// Curation score (0–1) using Photos' exact formula. Higher = more highlight-worthy.
    /// nil if curation scoring wasn't run.
    public let curationScore: Float?
    /// Whether the curation score was gated to 0 by low quality.
    public let curationGated: Bool
    /// Image quality assessment (blur, exposure, smudge).
    public let qualityResult: QualityResult?
    /// Meme detection and environment classification.
    public let memeResult: MemeResult?
    /// Content safety classification.
    public let safetyResult: SafetyResult?
    /// Perceptual fingerprint for duplicate detection.
    public let fingerprint: ImageFingerprint?
    /// Per-face attribute analysis (expressions, pose, gaze).
    public let faceAttributes: [FaceAttributeResult]
    /// Human body and hand poses.
    public let bodyPoses: PoseResult?
    /// Animal analysis (heads, faces, poses).
    public let animalAnalysis: AnimalAnalysis?
    /// Whether person segmentation detected people.
    public let personDetected: Bool
    /// Detected documents with corner points.
    public let documents: [DetectedDocument]
    /// Detected barcodes/QR codes.
    public let barcodes: [BarcodeResult]
    /// Horizon angle in radians (nil if no horizon detected).
    public let horizonAngle: Float?
    /// Number of contours detected.
    public let contourCount: Int
    /// Auto-generated caption.
    public let caption: CaptionResult?

    public init(
        assetID: String,
        sceneLabels: [SceneClassification] = [],
        aestheticsScore: Float = 0,
        isJunk: Bool = false,
        isUtility: Bool = false,
        faceCount: Int = 0,
        textObservations: [TextObservation] = [],
        objectRecognitions: [Recognition] = [],
        ocrRawLineCount: Int? = nil,
        ocrKeptLineCount: Int? = nil,
        junkConfidence: Float? = nil,
        junkSource: JunkResult.Source? = nil,
        curationScore: Float? = nil,
        curationGated: Bool = false,
        qualityResult: QualityResult? = nil,
        memeResult: MemeResult? = nil,
        safetyResult: SafetyResult? = nil,
        fingerprint: ImageFingerprint? = nil,
        faceAttributes: [FaceAttributeResult] = [],
        bodyPoses: PoseResult? = nil,
        animalAnalysis: AnimalAnalysis? = nil,
        personDetected: Bool = false,
        documents: [DetectedDocument] = [],
        barcodes: [BarcodeResult] = [],
        horizonAngle: Float? = nil,
        contourCount: Int = 0,
        caption: CaptionResult? = nil
    ) {
        self.id = assetID
        self.assetID = assetID
        self.sceneLabels = sceneLabels
        self.aestheticsScore = aestheticsScore
        self.isJunk = isJunk
        self.isUtility = isUtility
        self.faceCount = faceCount
        self.textObservations = textObservations
        self.ocrText = textObservations.map(\.text).joined(separator: " ")
        self.objectRecognitions = objectRecognitions
        self.ocrRawLineCount = ocrRawLineCount
        self.ocrKeptLineCount = ocrKeptLineCount
        self.junkConfidence = junkConfidence
        self.junkSource = junkSource
        self.curationScore = curationScore
        self.curationGated = curationGated
        self.qualityResult = qualityResult
        self.memeResult = memeResult
        self.safetyResult = safetyResult
        self.fingerprint = fingerprint
        self.faceAttributes = faceAttributes
        self.bodyPoses = bodyPoses
        self.animalAnalysis = animalAnalysis
        self.personDetected = personDetected
        self.documents = documents
        self.barcodes = barcodes
        self.horizonAngle = horizonAngle
        self.contourCount = contourCount
        self.caption = caption
    }
}

/// Statistics about the search index.
public struct IndexStats: Sendable {
    public let totalAssets: Int
    public let embeddingCount: Int
    public let sceneClassificationCount: Int
    public let objectRecognitionCount: Int
    public let faceObservationCount: Int
    public let textObservationCount: Int
    public let storeSizeBytes: UInt64

    public init(
        totalAssets: Int = 0,
        embeddingCount: Int = 0,
        sceneClassificationCount: Int = 0,
        objectRecognitionCount: Int = 0,
        faceObservationCount: Int = 0,
        textObservationCount: Int = 0,
        storeSizeBytes: UInt64 = 0
    ) {
        self.totalAssets = totalAssets
        self.embeddingCount = embeddingCount
        self.sceneClassificationCount = sceneClassificationCount
        self.objectRecognitionCount = objectRecognitionCount
        self.faceObservationCount = faceObservationCount
        self.textObservationCount = textObservationCount
        self.storeSizeBytes = storeSizeBytes
    }
}
