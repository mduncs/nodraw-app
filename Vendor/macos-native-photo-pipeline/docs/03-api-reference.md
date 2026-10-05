# API Reference

Every public type and method in PhotoPipeline.

---

## Bridge Layer

### FrameworkLoader

Singleton that loads Apple's private frameworks via dlopen.

```swift
public final class FrameworkLoader {
    public static let shared: FrameworkLoader

    public enum Framework: String, CaseIterable {
        case mediaAnalysis, visualUnderstanding, visualLookup,
             visionCore, textRecognition, espresso,
             photoAnalysis, photosIntelligence

        public var path: String          // absolute filesystem path
        public var resourcesPath: String // Resources dir (ML models)
    }

    // Load a framework (thread-safe, cached)
    @discardableResult
    public func load(_ framework: Framework) throws -> FrameworkHandle

    // Look up an ObjC class across all loaded frameworks
    public func classNamed(_ name: String) -> AnyClass?

    // Load framework + look up class in one call
    public func requireClass(_ name: String, from: Framework) throws -> AnyClass

    // Check all frameworks without loading
    public static func availability() -> [Framework: FrameworkStatus]

    // Release all loaded frameworks
    public func unloadAll()
}
```

### FrameworkHandle

```swift
public final class FrameworkHandle {
    public let name: String
    public func classNamed(_ name: String) -> AnyClass?
    public func requireClass(_ name: String) throws -> AnyClass
}
```

### FrameworkStatus

```swift
public enum FrameworkStatus {
    case available
    case missing
    case loadError(String)

    public var isAvailable: Bool
}
```

### FrameworkError

```swift
public enum FrameworkError: Error {
    case frameworkNotFound(String, path: String)
    case classNotFound(String, framework: String)
    case methodNotFound(String, className: String)
    case invocationFailed(String)
    case unsupportedOS(current: String, minimum: String)
}
```

### ObjCBridge

Static methods for calling ObjC methods on dynamically loaded classes.

```swift
public enum ObjCBridge {
    // Object creation
    static func create(_ cls: AnyClass) -> NSObject?
    static func create(_ cls: AnyClass, url: URL) -> NSObject?

    // Method invocation (0, 1, 2 args)
    static func call(_ target: AnyObject, _ sel: String) -> Any?
    static func call(_ target: AnyObject, _ sel: String, with: Any?) -> Any?
    static func call(_ target: AnyObject, _ sel: String, with: Any?, with: Any?) -> Any?

    // Class method invocation
    static func callClass(_ cls: AnyClass, _ sel: String) -> Any?
    static func callClass(_ cls: AnyClass, _ sel: String, with: Any?) -> Any?

    // KVC property access
    static func getValue(_ target: AnyObject, forKey: String) -> Any?
    static func setValue(_ target: AnyObject, value: Any?, forKey: String)

    // Introspection
    static func responds(_ target: AnyObject, to: String) -> Bool
    static func classResponds(_ cls: AnyClass, to: String) -> Bool
    static func methodNames(of: AnyClass) -> [String]
    static func propertyNames(of: AnyClass) -> [String]
}

// NSError** out-parameter helper
public func objcTry<T>(_ body: (UnsafeMutablePointer<NSError?>) -> T?) -> Result<T, Error>
```

### Diagnostics

```swift
public enum Diagnostics {
    // Quick compatibility check
    static func isCompatible() -> Bool

    // Full system report
    static func systemReport() -> SystemReport

    // Check model files on disk
    static func checkModelAvailability() -> [String: Bool]
}

public struct SystemReport: CustomStringConvertible {
    public let macOSVersion: String
    public let architecture: String
    public let sipEnabled: Bool
    public let frameworkAvailability: [FrameworkLoader.Framework: FrameworkStatus]
    public let modelAvailability: [String: Bool]
    public let issues: [String]
}
```

---

## Modules

### EmbeddingSearch

CLIP-style semantic search. Wraps MADEmbeddingStore + MADVectorDatabase.

```swift
public final class EmbeddingSearch {
    // Init with your own silo path
    public init(storePath: URL, version: EmbeddingVersion = .md7v2) throws

    // Index an image — extract CLIP embedding and store
    public func index(image: CGImage, assetID: String) async throws

    // Search by text query (e.g. "golden hour", "dog at beach")
    public func search(text: String, limit: Int = 20) async throws -> [SearchResult]

    // Search by image similarity
    public func search(image: CGImage, limit: Int = 20) async throws -> [SearchResult]

    // Prewarm IVF index into memory (reduces first-search latency)
    public func prewarm() async throws

    // Remove an asset from the index
    public func remove(assetID: String) throws

    // Rebuild IVF index (call after bulk inserts)
    public func rebuild() async throws
}
```

### SceneClassifier

Scene labels + aesthetics from VisionCore's multi-head backbone.

```swift
public final class SceneClassifier {
    public init() throws

    // Classify scene — returns labels, aesthetics, embedding
    public func classify(image: CGImage) async throws -> SceneResult
}
```

### ObjectRecognizer

Domain-routed object recognition (breeds, food, landmarks).

```swift
public final class ObjectRecognizer {
    public init() throws

    // Full pipeline: detect → domain classify → recognize
    public func recognize(image: CGImage) async throws -> [Recognition]
}
```

### FaceGallery

Face identity management with clustering.

```swift
public final class FaceGallery {
    // Init with your own gallery database path
    public init(galleryPath: URL) throws

    // Detect and identify faces in an image
    public func identify(image: CGImage) async throws -> [FaceMatch]

    // Add a face observation to the gallery
    public func addObservation(
        faceImage: CGImage,
        assetID: String,
        identityHint: String?
    ) async throws -> String  // returns identity ID

    // List all known identities
    public func identities() throws -> [Identity]

    // Merge two identities (same person)
    public func merge(_ a: String, _ b: String) throws
}
```

### TextRecognizer

Dual-engine OCR with optional quality filtering and layout analysis.

```swift
public final class TextRecognizer: @unchecked Sendable {
    public enum Engine: Sendable {
        case standard   // public Vision API (VNRecognizeTextRequest)
        case advanced   // private CREngineAccurate (non-sandboxed only)
    }

    /// Post-OCR quality filter (library addition, not Apple behavior).
    /// Set to nil to match Apple's store-everything behavior.
    public let qualityFilter: OCRQualityFilter?

    public init(
        engine: Engine = .standard,
        languages: [String] = ["en-US"],
        qualityFilter: OCRQualityFilter? = .default
    ) throws

    /// Recognize text in an image. Results filtered by qualityFilter if set.
    public func recognize(image: CGImage) async throws -> [TextObservation]

    /// Recognize and group text using the specified layout strategy.
    public func recognizeGrouped(image: CGImage, grouping: TextGrouping = .block) async throws -> [TextBlock]

    /// Full document layout analysis (columns, reading order, form/table detection).
    public func recognizeDocument(image: CGImage) async throws -> DocumentLayout
}
```

### DomainClassifier

GNN domain prediction (internal routing, typically used via ObjectRecognizer).

```swift
public final class DomainClassifier {
    public init() throws

    // Classify image into recognition domains
    public func classify(image: CGImage) async throws -> [(RecognitionDomain, Float)]
}
```

### JunkClassifier

Junk image classification using the same `VNClassifyJunkImageRequest` that Photos.app uses internally. Falls back to saliency + classification heuristics on systems without the private API.

```swift
public final class JunkClassifier: @unchecked Sendable {
    public init()

    /// Whether VNClassifyJunkImageRequest is available on this system.
    public var isAvailable: Bool

    /// Classify an image for junk/quality.
    /// Uses VNClassifyJunkImageRequest when available, falls back to
    /// heuristic quality estimation (saliency + classification).
    public func classify(image: CGImage) async throws -> JunkResult
}
```

### CurationScorer

Photos-identical curation score calculator. Implements the exact formula from `VCPVideoKeyFrame.computeCurationScore` (decompiled from MediaAnalysis.framework). This is the "best photo" ranking logic Photos uses to surface highlights in Memories, Featured Photos, and the For You tab.

```swift
public struct CurationScorer: Sendable {
    public init()

    /// Compute the curation score from pre-analyzed signals.
    ///
    /// Photos' exact formula:
    ///   if globalQuality >= 0.5:
    ///       score = (0.1 + aesthetics * 0.25 + content * 0.65) * penalty
    ///       clamp(score, 0.0, 1.0)
    ///   else:
    ///       score = 0.0
    public func score(
        junkConfidence: Float,       // raw from JunkClassifier (0-1)
        aestheticsScore: Float,      // from SceneClassifier (0-1)
        faceCount: Int = 0,
        objectCount: Int = 0,
        isUtility: Bool = false,
        blurScore: Float = 1.0       // 0-1, where 1 = sharp
    ) -> CurationResult
}
```

### OCRQualityFilter

Post-OCR quality filter to remove garbled/noise text from recognition results. **Library addition, not Apple behavior** -- Photos.app stores all OCR results regardless of quality.

```swift
public struct OCRQualityFilter: Sendable, Codable {
    /// Minimum per-line confidence (default: 0.25).
    public var minimumConfidence: Float
    /// Minimum text length in characters (default: 2).
    public var minimumLength: Int
    /// Maximum ratio of non-alphanumeric, non-space characters (default: 0.7).
    public var maximumSymbolRatio: Float
    /// Minimum ratio of word-like tokens (default: 0.0 = disabled).
    public var minimumWordRatio: Float

    // Presets
    public static let `default`: OCRQualityFilter    // catches obvious noise
    public static let strict: OCRQualityFilter       // drops borderline text
    public static let permissive: OCRQualityFilter   // only drops worst garbage
    public static let none: OCRQualityFilter         // matches Apple's behavior

    /// Filter observations, removing low-quality lines.
    public func apply(_ observations: [TextObservation]) -> [TextObservation]

    /// Check whether a single observation passes.
    public func passes(_ obs: TextObservation) -> Bool

    /// Split into kept and rejected (for diagnostics).
    public func partition(_ observations: [TextObservation]) -> (kept: [TextObservation], rejected: [TextObservation])
}
```

---

## Index Layer

### SearchIndex

Unified orchestrator combining all modules.

```swift
public final class SearchIndex {
    public let configuration: IndexConfiguration
    public let storePath: URL

    public init(configuration: IndexConfiguration, storePath: URL) throws

    // Index image through all enabled modules (concurrent).
    // Scene classification gates downstream modules (phase 1 → phase 2).
    // Returns per-module success/failure/skip info.
    @discardableResult
    public func index(
        image: CGImage,
        assetID: String,
        metadata: AssetMetadata? = nil
    ) async throws -> IndexResult

    // Multi-modal search across all enabled modules
    public func search(_ query: String, limit: Int = 20) async throws -> [SearchResult]

    // Remove from all indices
    public func remove(assetID: String) async throws

    // Rebuild all indices
    public func rebuild() async throws

    // All analysis data for every indexed asset
    public func allAnalysis() -> [AssetAnalysis]

    // Current statistics
    public func stats() throws -> IndexStats
}
```

### IndexManager

Bulk indexing operations.

```swift
public final class IndexManager {
    public init(searchIndex: SearchIndex)

    // Index all images in a directory
    public func indexDirectory(
        _ url: URL,
        recursive: Bool = true,
        progress: ((Int, Int) -> Void)?
    ) async throws -> IndexReport
}
```

### IndexConfiguration

```swift
public struct IndexConfiguration: Codable, Sendable {
    public var enableEmbeddingSearch: Bool
    public var enableSceneClassification: Bool
    public var enableObjectRecognition: Bool
    public var enableFaceGallery: Bool
    public var enableTextRecognition: Bool
    public var embeddingVersion: EmbeddingVersion
    public var ocrLanguages: [String]

    /// Post-OCR quality filter. Library addition — not Apple behavior.
    /// Set to nil to store all OCR results (matching Apple's behavior).
    public var ocrQualityFilter: OCRQualityFilter?

    /// Scene-aware gating of downstream analysis (default: true).
    /// When enabled, scene classification gates face gallery (skipped if no faces)
    /// and object recognition (skipped for utility images).
    /// Matches Apple's VCPPreAnalyzer pattern.
    public var enableSceneGating: Bool

    public static let full: IndexConfiguration          // all modules + scene gating
    public static let minimal: IndexConfiguration       // embeddings + scene only
    public static let searchFocused: IndexConfiguration // embeddings + scene + text
}
```

---

## Storage Layer

### PipelineStore

```swift
public final class PipelineStore {
    public let rootPath: URL
    public var embeddingsPath: URL
    public var galleryPath: URL
    public var classificationsPath: URL
    public var textPath: URL
    public var configPath: URL

    public init(rootPath: URL) throws
    public static func defaultStore() throws -> PipelineStore

    public func totalSizeBytes() throws -> UInt64
    public func indexedAssetCount() throws -> Int
    public func reset() throws
    public func saveConfig(_ config: IndexConfiguration) throws
    public func loadConfig() -> IndexConfiguration?
}
```

### VectorStore

In-memory + file-based vector storage with brute-force cosine similarity.

```swift
public final class VectorStore {
    public init(storePath: URL) throws

    public var count: Int

    public func upsert(assetID: String, vector: [Float]) throws
    public func remove(assetID: String)
    public func search(query: [Float], limit: Int = 20) -> [VectorSearchResult]
    public func flush() throws
}

public struct VectorSearchResult {
    public let assetID: String
    public let score: Float
}
```

### MetadataStore

JSON file-based metadata cache.

```swift
public final class MetadataStore: @unchecked Sendable {
    public init(storePath: URL) throws

    // Scene classifications
    public func storeSceneResult(assetID: String, result: SceneResult) throws
    public func loadSceneResult(assetID: String) -> SceneResult?

    // Object recognitions
    public func storeRecognitions(assetID: String, recognitions: [Recognition]) throws
    public func loadRecognitions(assetID: String) -> [Recognition]?

    // Text observations (with optional quality filter diagnostics)
    public func storeTextObservations(assetID: String, observations: [TextObservation], rawLineCount: Int? = nil) throws
    public func loadTextObservations(assetID: String) -> [TextObservation]?
    public func loadTextFilterDiagnostics(assetID: String) -> (rawLineCount: Int, keptLineCount: Int)?

    // Junk classification
    public func storeJunkResult(assetID: String, result: JunkResult) throws
    public func loadJunkResult(assetID: String) -> JunkResult?

    // Curation scores
    public func storeCurationResult(assetID: String, result: CurationResult) throws
    public func loadCurationResult(assetID: String) -> CurationResult?

    // Embeddings
    public func loadEmbedding(assetID: String) -> [Float]?
    public func allEmbeddings() -> [(String, [Float])]

    // Bulk operations
    public func removeAll(assetID: String) throws
    public func assetCount() -> Int
    public func allAssetIDs() -> Set<String>
}
```

---

## Model Types

### Embedding

```swift
public enum EmbeddingVersion: String, Codable, CaseIterable {
    case md4, md5, md6, md7v2
}

public struct Embedding {
    public let vector: [Float]
    public let version: EmbeddingVersion
    public let dimension: Int

    public func cosineSimilarity(to other: Embedding) -> Float
}
```

### Classification Types

```swift
public struct SceneClassification: Hashable {
    public let label: String
    public let confidence: Float
}

public struct SceneResult: Sendable {
    public let labels: [SceneClassification]
    public let aestheticsScore: Float
    public let embedding: [Float]?
    public let isJunk: Bool
    public let isUtility: Bool
    public let aestheticsDetail: AestheticsDetail?
    public let saliencyBox: CGRect?
    public let faceCount: Int
}

public struct AestheticsDetail: Sendable {
    public let overallScore: Float
    public let isUtility: Bool
    public let qualityScores: [String: Float]
    public let subscores: [String: Float]

    public static let subscoreKeys: [String]   // 22 known sub-score property names
    public static let qualityKeys: [String]     // 8 known quality score keys
}

public enum RecognitionDomain: Int, CaseIterable {
    case unknown = 0, art = 1, plants = 2, landmark = 3,
         cats = 4, dogs = 5, birds = 8, insects = 9,
         naturalLandmark = 10, sculpture = 11, skyline = 12,
         mammals = 13, reptiles = 14, food = 16
}

public struct Recognition {
    public let domain: RecognitionDomain
    public let name: String
    public let confidence: Float
    public let embedding: [Float]?
    public let boundingBox: CGRect?
}

public struct TextObservation {
    public let text: String
    public let boundingBox: CGRect
    public let confidence: Float
    public let language: String?
}

public struct FaceMatch {
    public let identityID: String
    public let identityName: String?
    public let confidence: Float
    public let boundingBox: CGRect
}

public struct Identity: Identifiable {
    public let id: String
    public var name: String?
    public let observationCount: Int
    public let isHuman: Bool
}
```

### Junk & Curation Types

```swift
public struct JunkResult: Sendable {
    /// Quality confidence (0.0-1.0). Higher = better quality.
    public let confidence: Float
    /// Whether this image is considered junk (confidence < 0.5).
    public var isJunk: Bool
    /// Which classification method was used.
    public let source: Source

    public enum Source: String, Sendable {
        case privateAPI    // VNClassifyJunkImageRequest (same as Photos.app)
        case heuristic     // public API saliency + classification fallback
    }
}

public struct CurationResult: Sendable {
    public let score: Float            // 0.0-1.0 (higher = more highlight-worthy)
    public let globalQuality: Float    // from junk confidence; must be >= 0.5 to pass
    public let visualPleasingScore: Float  // aesthetics contribution
    public let contentScore: Float     // semantic interest (faces, objects)
    public let penaltyScore: Float     // penalty multiplier (1.0 = no penalty)
    public let gatedByQuality: Bool    // true if quality < 0.5 forced score to 0
}
```

### Text Layout Types

```swift
/// How to group recognized text lines into higher-level structures.
public enum TextGrouping: Sendable {
    case line       // raw per-line observations, no grouping
    case block      // spatial paragraph grouping (vertically adjacent, aligned)
    case column     // column detection + block grouping within each column
    case document   // full layout: columns + reading order + structural roles
    case neural     // Apple's CRTextDetectionPipeline neural block detection;
                    // falls back to .document if unavailable
}

/// A block of grouped text lines forming a logical unit.
public struct TextBlock: Sendable, Identifiable {
    public let id: String
    public let text: String                 // combined text of all lines
    public let lines: [TextObservation]     // individual line observations
    public let boundingBox: CGRect          // enclosing all lines
    public let confidence: Float            // average across lines
    public let role: TextRole               // structural role (.document only)
    public let columnIndex: Int             // 0-based (.column/.document only)
}

/// Structural role of a text block within a document.
public enum TextRole: String, Sendable {
    case body, heading, caption, sidebar, tableCell, formLabel, formValue
}

/// Full document layout result.
public struct DocumentLayout: Sendable {
    public let blocks: [TextBlock]
    public let columnCount: Int
    public let readingDirection: ReadingDirection
    public let hasFormStructure: Bool
    public let hasTableStructure: Bool
}

/// Text reading direction.
public enum ReadingDirection: String, Sendable {
    case leftToRight, rightToLeft, topToBottom
}
```

### Asset & Search

```swift
public struct Asset: Identifiable, Hashable {
    public let id: String
    public let sourceURL: URL?
    public let metadata: AssetMetadata?
}

public struct AssetMetadata: Hashable {
    public let dateCreated: Date?
    public let width: Int?
    public let height: Int?
    public let mediaType: MediaType
    public let location: Location?

    public enum MediaType: Int { case image, video, livePhoto }
    public struct Location: Hashable {
        public let latitude: Double
        public let longitude: Double
    }
}

public enum MatchType: String, Sendable {
    case embedding, scene, object, face, text
}

public struct SearchResult: Sendable, Identifiable {
    public let id: String
    public let assetID: String
    public let score: Float
    public let matchType: MatchType
    public let detail: String
}

public struct IndexResult: Sendable {
    public let modulesSucceeded: Int   // modules that completed successfully
    public let failures: [String]      // per-module failure descriptions
    public let skipped: [String]       // modules skipped by scene gating
    public var allSucceeded: Bool      // failures.isEmpty
}

public struct AssetAnalysis: Sendable, Identifiable {
    public let id: String              // same as assetID
    public let assetID: String
    public let sceneLabels: [SceneClassification]
    public let aestheticsScore: Float
    public let isJunk: Bool
    public let isUtility: Bool
    public let faceCount: Int
    public let textObservations: [TextObservation]
    public let ocrText: String         // joined text for display
    public let objectRecognitions: [Recognition]

    // OCR quality filter diagnostics (nil if filter disabled)
    public let ocrRawLineCount: Int?
    public let ocrKeptLineCount: Int?
    public var ocrDroppedLineCount: Int // computed: raw - kept (0 if filter disabled)

    // Junk classification (nil if classifier wasn't run)
    public let junkConfidence: Float?
    public let junkSource: JunkResult.Source?

    // Curation scoring (nil if scorer wasn't run)
    public let curationScore: Float?
    public let curationGated: Bool     // true if quality gated score to 0
}

public struct IndexStats: Sendable {
    public let totalAssets: Int
    public let embeddingCount: Int
    public let sceneClassificationCount: Int
    public let objectRecognitionCount: Int
    public let faceObservationCount: Int
    public let textObservationCount: Int
    public let storeSizeBytes: UInt64
}

public struct IndexReport {
    public let totalProcessed: Int
    public let succeeded: Int
    public let failed: Int
    public let duration: TimeInterval
    public let errors: [String: String]
    public var successRate: Double
}
```
