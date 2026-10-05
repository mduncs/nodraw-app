import Foundation

/// Configuration for which analysis modules to enable in the pipeline.
///
/// Controls the tradeoff between analysis completeness and performance.
/// Disable modules you don't need to save CPU/memory.
public struct IndexConfiguration: Codable, Sendable {
    /// Enable CLIP semantic embedding search (text↔image).
    public var enableEmbeddingSearch: Bool
    /// Enable scene label classification (beach, sunset, etc.).
    public var enableSceneClassification: Bool
    /// Enable object/breed/food/landmark recognition.
    public var enableObjectRecognition: Bool
    /// Enable face identity gallery.
    public var enableFaceGallery: Bool
    /// Enable OCR text extraction.
    public var enableTextRecognition: Bool
    /// Which CLIP embedding version to use.
    public var embeddingVersion: EmbeddingVersion
    /// Languages for OCR.
    public var ocrLanguages: [String]
    /// Post-OCR quality filter. Library addition — not Apple behavior.
    /// Set to nil to store all OCR results (matching Apple's behavior).
    public var ocrQualityFilter: OCRQualityFilter?
    /// Enable scene-aware gating of downstream analysis.
    ///
    /// When true (default), scene classification runs first and gates:
    /// - Face gallery: skipped if no faces detected in scene analysis
    /// - Object recognition: skipped for utility images (screenshots, documents)
    ///
    /// Matches Apple's VCPPreAnalyzer → sceneConfidenceThresholdForTask pattern.
    /// Disable to brute-force all enabled modules on every image.
    public var enableSceneGating: Bool
    /// Enable image quality assessment (blur, exposure, lens smudge).
    public var enableImageQuality: Bool
    /// Enable meme detection and city/nature classification.
    public var enableMemeDetection: Bool
    /// Enable content safety classification.
    public var enableSafetyClassification: Bool
    /// Enable perceptual duplicate fingerprinting.
    public var enableDuplicateDetection: Bool
    /// Enable detailed face attribute analysis (expressions, pose, gaze).
    public var enableFaceAttributes: Bool
    /// Enable human body and hand pose estimation.
    public var enableBodyPoseEstimation: Bool
    /// Enable animal head/face/pose analysis.
    public var enableAnimalAnalysis: Bool
    /// Enable person segmentation (mask generation).
    public var enablePersonSegmentation: Bool
    /// Enable document boundary detection.
    public var enableDocumentAnalysis: Bool
    /// Enable barcode and QR code scanning.
    public var enableBarcodeScanning: Bool
    /// Enable horizon and contour detection.
    public var enableHorizonContourDetection: Bool
    /// Enable auto-captioning from analysis results.
    public var enableImageCaptioning: Bool

    /// All modules enabled with scene gating (default).
    public static let full = IndexConfiguration(
        enableEmbeddingSearch: true,
        enableSceneClassification: true,
        enableObjectRecognition: true,
        enableFaceGallery: true,
        enableTextRecognition: true,
        embeddingVersion: .md7v2,
        ocrLanguages: ["en-US"],
        ocrQualityFilter: .default,
        enableSceneGating: true,
        enableImageQuality: true,
        enableMemeDetection: true,
        enableSafetyClassification: true,
        enableDuplicateDetection: true,
        enableFaceAttributes: true,
        enableBodyPoseEstimation: true,
        enableAnimalAnalysis: true,
        enablePersonSegmentation: true,
        enableDocumentAnalysis: true,
        enableBarcodeScanning: true,
        enableHorizonContourDetection: true,
        enableImageCaptioning: true
    )

    /// Minimal: embeddings + scene classification only.
    public static let minimal = IndexConfiguration(
        enableEmbeddingSearch: true,
        enableSceneClassification: true,
        enableObjectRecognition: false,
        enableFaceGallery: false,
        enableTextRecognition: false,
        embeddingVersion: .md7v2,
        ocrLanguages: ["en-US"],
        ocrQualityFilter: .default,
        enableSceneGating: true,
        enableImageQuality: false,
        enableMemeDetection: false,
        enableSafetyClassification: false,
        enableDuplicateDetection: false,
        enableFaceAttributes: false,
        enableBodyPoseEstimation: false,
        enableAnimalAnalysis: false,
        enablePersonSegmentation: false,
        enableDocumentAnalysis: false,
        enableBarcodeScanning: false,
        enableHorizonContourDetection: false,
        enableImageCaptioning: false
    )

    /// Search-focused: embeddings + scene + text (no face/object).
    public static let searchFocused = IndexConfiguration(
        enableEmbeddingSearch: true,
        enableSceneClassification: true,
        enableObjectRecognition: false,
        enableFaceGallery: false,
        enableTextRecognition: true,
        embeddingVersion: .md7v2,
        ocrLanguages: ["en-US"],
        ocrQualityFilter: .default,
        enableSceneGating: true,
        enableImageQuality: false,
        enableMemeDetection: false,
        enableSafetyClassification: false,
        enableDuplicateDetection: false,
        enableFaceAttributes: false,
        enableBodyPoseEstimation: false,
        enableAnimalAnalysis: false,
        enablePersonSegmentation: false,
        enableDocumentAnalysis: false,
        enableBarcodeScanning: false,
        enableHorizonContourDetection: false,
        enableImageCaptioning: false
    )

    public init(
        enableEmbeddingSearch: Bool = true,
        enableSceneClassification: Bool = true,
        enableObjectRecognition: Bool = true,
        enableFaceGallery: Bool = true,
        enableTextRecognition: Bool = true,
        embeddingVersion: EmbeddingVersion = .md7v2,
        ocrLanguages: [String] = ["en-US"],
        ocrQualityFilter: OCRQualityFilter? = .default,
        enableSceneGating: Bool = true,
        enableImageQuality: Bool = true,
        enableMemeDetection: Bool = true,
        enableSafetyClassification: Bool = true,
        enableDuplicateDetection: Bool = true,
        enableFaceAttributes: Bool = true,
        enableBodyPoseEstimation: Bool = true,
        enableAnimalAnalysis: Bool = true,
        enablePersonSegmentation: Bool = true,
        enableDocumentAnalysis: Bool = true,
        enableBarcodeScanning: Bool = true,
        enableHorizonContourDetection: Bool = true,
        enableImageCaptioning: Bool = true
    ) {
        self.enableEmbeddingSearch = enableEmbeddingSearch
        self.enableSceneClassification = enableSceneClassification
        self.enableObjectRecognition = enableObjectRecognition
        self.enableFaceGallery = enableFaceGallery
        self.enableTextRecognition = enableTextRecognition
        self.embeddingVersion = embeddingVersion
        self.ocrLanguages = ocrLanguages
        self.ocrQualityFilter = ocrQualityFilter
        self.enableSceneGating = enableSceneGating
        self.enableImageQuality = enableImageQuality
        self.enableMemeDetection = enableMemeDetection
        self.enableSafetyClassification = enableSafetyClassification
        self.enableDuplicateDetection = enableDuplicateDetection
        self.enableFaceAttributes = enableFaceAttributes
        self.enableBodyPoseEstimation = enableBodyPoseEstimation
        self.enableAnimalAnalysis = enableAnimalAnalysis
        self.enablePersonSegmentation = enablePersonSegmentation
        self.enableDocumentAnalysis = enableDocumentAnalysis
        self.enableBarcodeScanning = enableBarcodeScanning
        self.enableHorizonContourDetection = enableHorizonContourDetection
        self.enableImageCaptioning = enableImageCaptioning
    }
}
