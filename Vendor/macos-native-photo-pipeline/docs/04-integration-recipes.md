# Integration Recipes

End-to-end code examples for common tasks.

---

## Recipe 1: Index a Folder of Photos

```swift
import PhotoPipeline
import ImageIO

let storePath = URL(fileURLWithPath: "/tmp/my-photo-index")
let index = try SearchIndex(configuration: .full, storePath: storePath)
let manager = IndexManager(searchIndex: index)

let photosDir = URL(fileURLWithPath: "/Users/me/Photos")
let report = try await manager.indexDirectory(photosDir, recursive: true) { done, total in
    print("Progress: \(done)/\(total)")
}

print("Indexed \(report.succeeded)/\(report.totalProcessed) in \(report.duration)s")
if !report.errors.isEmpty {
    for (id, err) in report.errors.prefix(5) {
        print("  Failed: \(id) — \(err)")
    }
}
```

---

## Recipe 2: Search by Text

```swift
import PhotoPipeline

let index = try SearchIndex(configuration: .full, storePath: storePath)

// Semantic search — uses CLIP embeddings + keyword matching
let results = try await index.search("sunset at the beach", limit: 10)

for result in results {
    print("""
    Asset: \(result.assetID)
    Score: \(result.score)
    Match: \(result.matchType.rawValue)
    Detail: \(result.detail)
    """)
}
```

---

## Recipe 3: Find Similar Images

```swift
import PhotoPipeline
import ImageIO

let search = try EmbeddingSearch(storePath: embeddingsURL)

// Index some images first
for (id, url) in imagePairs {
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    try await search.index(image: image, assetID: id)
}

// Find images similar to a query image
let querySource = CGImageSourceCreateWithURL(queryURL as CFURL, nil)!
let queryImage = CGImageSourceCreateImageAtIndex(querySource, 0, nil)!
let similar = try await search.search(image: queryImage, limit: 5)

for result in similar {
    print("\(result.assetID): similarity=\(result.score)")
}
```

---

## Recipe 4: Classify Scenes

```swift
import PhotoPipeline

let classifier = try SceneClassifier()

let result = try await classifier.classify(image: myImage)

// Top scene labels
for label in result.labels.prefix(5) {
    print("\(label.label): \(label.confidence)")
}
// e.g. "Beach: 0.92", "Ocean: 0.85", "Golden Hour: 0.73"

// Aesthetics score (0.0 = poor, 1.0 = excellent)
print("Aesthetics: \(result.aestheticsScore)")

// Junk/screenshot detection
if result.isJunk {
    print("This looks like a screenshot or junk image")
}
```

---

## Recipe 5: Identify Breeds, Food, Landmarks

```swift
import PhotoPipeline

let recognizer = try ObjectRecognizer()
let recognitions = try await recognizer.recognize(image: myImage)

for rec in recognitions {
    switch rec.domain {
    case .dogs:
        print("Dog breed: \(rec.name) [\(rec.confidence)]")
    case .cats:
        print("Cat breed: \(rec.name) [\(rec.confidence)]")
    case .food:
        print("Food: \(rec.name) [\(rec.confidence)]")
    case .landmark:
        print("Landmark: \(rec.name) [\(rec.confidence)]")
    case .birds:
        print("Bird: \(rec.name) [\(rec.confidence)]")
    default:
        print("\(rec.domain): \(rec.name) [\(rec.confidence)]")
    }

    if let box = rec.boundingBox {
        print("  at (\(box.origin.x), \(box.origin.y)) \(box.width)x\(box.height)")
    }
}
```

---

## Recipe 6: Face Identity Gallery

```swift
import PhotoPipeline
import ImageIO

let gallery = try FaceGallery(galleryPath: galleryURL)

// Enroll faces
let faceImage1 = loadImage("/photos/alice_1.jpg")
let id1 = try await gallery.addObservation(
    faceImage: faceImage1,
    assetID: "alice-1",
    identityHint: "Alice"
)

let faceImage2 = loadImage("/photos/alice_2.jpg")
let id2 = try await gallery.addObservation(
    faceImage: faceImage2,
    assetID: "alice-2",
    identityHint: "Alice"
)

// Identify faces in a new photo
let testImage = loadImage("/photos/group.jpg")
let matches = try await gallery.identify(image: testImage)

for match in matches {
    print("Found \(match.identityName ?? "unknown") at \(match.boundingBox)")
    print("  confidence: \(match.confidence)")
}

// List all identities
let identities = try gallery.identities()
for identity in identities {
    print("\(identity.name ?? identity.id): \(identity.observationCount) observations")
}

// Merge if two identities are the same person
try gallery.merge(id1, id2)

func loadImage(_ path: String) -> CGImage {
    let url = URL(fileURLWithPath: path)
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}
```

---

## Recipe 7: Extract Text (OCR)

```swift
import PhotoPipeline

// Standard engine (works everywhere, including sandboxed apps)
let standardOCR = try TextRecognizer(engine: .standard, languages: ["en-US"])
let texts = try await standardOCR.recognize(image: screenshotImage)

for obs in texts {
    print("\"\(obs.text)\" confidence=\(obs.confidence)")
    print("  bounds: \(obs.boundingBox)")
}

// Advanced engine (non-sandboxed, 6 language models, better accuracy)
let advancedOCR = try TextRecognizer(
    engine: .advanced,
    languages: ["en-US", "ja-JP", "zh-Hans"]
)
let advancedTexts = try await advancedOCR.recognize(image: documentImage)
```

---

## Recipe 8: Check System Compatibility

```swift
import PhotoPipeline

// Quick check
if Diagnostics.isCompatible() {
    print("Full private framework support available")
} else {
    print("Running in fallback mode (public APIs only)")
}

// Detailed report
let report = Diagnostics.systemReport()
print(report)
// Output:
// PhotoPipeline System Report
// macOS: 14.2.1
// Architecture: arm64
// SIP: enabled
// Frameworks:
//   MediaAnalysis: available
//   VisualUnderstanding: available
//   ...
// Models:
//   MonzaV4_1.mlmodelc: true
//   mubb_md7.mlmodelc: true
//   ...

// Check specific frameworks
let availability = FrameworkLoader.availability()
for (fw, status) in availability.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
    print("\(fw.rawValue): \(status)")
}
```

---

## Recipe 9: Custom Configuration

```swift
import PhotoPipeline

// Search-optimized: embeddings + scene + text, skip face/object
let config = IndexConfiguration(
    enableEmbeddingSearch: true,
    enableSceneClassification: true,
    enableObjectRecognition: false,
    enableFaceGallery: false,
    enableTextRecognition: true,
    embeddingVersion: .md7v2,
    ocrLanguages: ["en-US", "de-DE", "fr-FR"],
    ocrQualityFilter: .default,        // filter OCR noise
    enableSceneGating: true             // skip irrelevant modules per-image
)

let index = try SearchIndex(configuration: config, storePath: storePath)
```

---

## Recipe 10: Prewarm + Batch Index

```swift
import PhotoPipeline

let search = try EmbeddingSearch(storePath: embeddingsURL)

// Prewarm loads IVF partitions into memory (reduces first-search latency)
try await search.prewarm()

// Batch index
for (id, image) in imageBatch {
    try await search.index(image: image, assetID: id)
}

// Rebuild IVF index after bulk inserts (optimizes search quality)
try await search.rebuild()
```

---

## Recipe 11: Vector Store (Low-Level)

For direct vector operations without the full embedding pipeline:

```swift
import PhotoPipeline

let store = try VectorStore(storePath: vectorsURL)

// Insert vectors
try store.upsert(assetID: "img-001", vector: [1.0, 0.0, 0.0, ...])
try store.upsert(assetID: "img-002", vector: [0.0, 1.0, 0.0, ...])

// Search by cosine similarity
let results = store.search(query: [0.9, 0.1, 0.0, ...], limit: 5)
for r in results {
    print("\(r.assetID): \(r.score)")
}

// Persist to disk
try store.flush()

print("Stored \(store.count) vectors")
```

---

## Recipe 12: Manage Storage

```swift
import PhotoPipeline

let store = try PipelineStore(rootPath: storePath)

// Check storage size
let bytes = try store.totalSizeBytes()
print("Storage: \(bytes / 1024 / 1024) MB")

// Check indexed count
let count = try store.indexedAssetCount()
print("Indexed assets: \(count)")

// Save/load configuration
let config = IndexConfiguration.full
try store.saveConfig(config)
let loaded = store.loadConfig()

// Nuclear option: wipe everything
try store.reset()
```

---

## Recipe 13: Junk Classification

```swift
import PhotoPipeline

let classifier = JunkClassifier()

if classifier.isAvailable {
    let result = try await classifier.classify(image: myImage)

    print("Quality: \(result.confidence)")  // 0=junk, 1=excellent
    print("Source: \(result.source)")        // .privateAPI or .heuristic

    if result.isJunk {
        print("This is a low-quality or utility image")
    }
} else {
    print("VNClassifyJunkImageRequest not available — using heuristic fallback")
    let result = try await classifier.classify(image: myImage)  // auto-fallback
    print("Quality (heuristic): \(result.confidence)")
}
```

---

## Recipe 14: Curation Scoring (Photos' Highlight Formula)

```swift
import PhotoPipeline

let scorer = CurationScorer()

// Score using analysis results from other modules
let result = scorer.score(
    junkConfidence: 0.85,     // from JunkClassifier
    aestheticsScore: 0.72,    // from SceneClassifier
    faceCount: 2,             // from SceneClassifier
    objectCount: 3,           // from ObjectRecognizer
    isUtility: false          // from SceneClassifier
)

print("Curation: \(result.score)")          // 0.0–1.0
print("Quality gate: \(result.gatedByQuality)")  // true if quality too low

// Use in a pipeline: sort photos by curation score
let analysis = index.allAnalysis()
let highlights = analysis
    .filter { !$0.curationGated }
    .sorted { ($0.curationScore ?? 0) > ($1.curationScore ?? 0) }
    .prefix(20)

for a in highlights {
    print("\(a.assetID): curation=\(a.curationScore ?? 0)")
}
```

---

## Recipe 15: Scene-Gated Pipeline

```swift
import PhotoPipeline

// Scene gating matches Apple's VCPPreAnalyzer pattern:
// Phase 1: scene + embedding (always)
// Phase 2: objects/faces/OCR (gated by scene content)

let config = IndexConfiguration(
    enableObjectRecognition: true,
    enableFaceGallery: true,
    enableTextRecognition: true,
    enableSceneGating: true    // the default
)
let index = try SearchIndex(configuration: config, storePath: storePath)

let result = try await index.index(image: screenshotImage, assetID: "screenshot-001")

// Check what got skipped
for skip in result.skipped {
    print("Skipped: \(skip)")
    // "object: utility image (screenshot/document)"
    // — ObjectRecognizer was skipped because scene detected utility image
}

print("Succeeded: \(result.modulesSucceeded), Skipped: \(result.skipped.count)")

// Disable gating to force everything
var bruteForceConfig = IndexConfiguration.full
bruteForceConfig.enableSceneGating = false
```

---

## Recipe 16: OCR Quality Filter

```swift
import PhotoPipeline

// Default filter removes watermarks, overlay noise, low-confidence junk
let config = IndexConfiguration(ocrQualityFilter: .default)

// Custom filter
let strictFilter = OCRQualityFilter(
    minConfidence: 0.7,      // reject low confidence
    minTextLength: 3,        // reject tiny fragments
    maxRepeatRatio: 0.5,     // reject "AAAA" style noise
    rejectPatterns: ["©", "shutterstock", "getty"]
)
var customConfig = IndexConfiguration.full
customConfig.ocrQualityFilter = strictFilter

// Disable filter entirely (match Apple's behavior — keep everything)
var rawConfig = IndexConfiguration.full
rawConfig.ocrQualityFilter = nil

// Check filter diagnostics in analysis results
let analysis = index.allAnalysis()
for a in analysis where a.ocrDroppedLineCount > 0 {
    print("\(a.assetID): kept \(a.ocrKeptLineCount ?? 0)/\(a.ocrRawLineCount ?? 0) OCR lines")
}
```

---

## Recipe 17: Text Layout Analysis

```swift
import PhotoPipeline

let recognizer = try TextRecognizer(languages: ["en-US"])

// Simple line-by-line
let lines = try await recognizer.recognize(image: documentImage)

// Group into paragraphs
let blocks = try await recognizer.recognizeBlocks(image: documentImage, grouping: .block)
for block in blocks {
    print("[\(block.role)] \(block.text)")
}

// Full document layout (columns + reading order)
let layout = try await recognizer.recognizeLayout(image: documentImage, grouping: .document)
print("Columns: \(layout.columnCount)")
print("Has tables: \(layout.hasTableStructure)")
for block in layout.blocks {
    print("  [\(block.role), col \(block.columnIndex)] \(block.text)")
}
```
