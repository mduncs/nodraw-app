# Architecture

## Layer Diagram

```
┌─────────────────────────────────────────────────┐
│              Your macOS App                      │
├─────────────────────────────────────────────────┤
│         PhotoPipeline (this library)             │
│                                                  │
│  ┌──────────┐ ┌──────────┐ ┌────────────────┐  │
│  │ Search   │ │  Index   │ │    Storage     │  │
│  │ Index    │ │ Manager  │ │  (your silo)   │  │
│  └────┬─────┘ └────┬─────┘ └───────┬────────┘  │
│       │             │               │           │
│  ┌────┴─────────────┴───────────────┴────────┐  │
│  │           Module Layer                     │  │
│  │  ┌────────┐ ┌──────┐ ┌──────┐ ┌────────┐ │  │
│  │  │Embeddi │ │Scene │ │Object│ │  Face  │ │  │
│  │  │Search  │ │Class.│ │Recog.│ │Gallery │ │  │
│  │  └───┬────┘ └──┬───┘ └──┬───┘ └───┬────┘ │  │
│  │  ┌───┴──┐ ┌────┴───┐    │    ┌────┴────┐ │  │
│  │  │ OCR/ │ │Domain  │    │    │  Vector │ │  │
│  │  │ Text │ │Classify│    │    │  Store  │ │  │
│  │  └───┬──┘ └────┬───┘    │    └────┬────┘ │  │
│  └──────┼─────────┼────────┼─────────┼──────┘  │
│         │         │        │         │          │
├─────────┼─────────┼────────┼─────────┼──────────┤
│  ┌──────┴─────────┴────────┴─────────┴────────┐ │
│  │         FrameworkBridge (dlopen)             │ │
│  └──────────────────┬──────────────────────────┘ │
└─────────────────────┼────────────────────────────┘
                      │ dlopen / NSClassFromString
┌─────────────────────┼────────────────────────────┐
│  Apple Private Frameworks (on every Mac)          │
│  MediaAnalysis · VisualUnderstanding · VisionCore │
│  VisualLookup · TextRecognition · Espresso · E5RT │
└──────────────────────────────────────────────────┘
```

## Data Flow

### Indexing

```
CGImage + assetID
    │
    ▼
SearchIndex.index()
    │
    ├─── Phase 1: Foundation (concurrent) ─────────────────┐
    │                                                       │
    │   EmbeddingSearch.index()                             │
    │     → pixel buffer → backbone CNN → embedding vector  │
    │     → MADVectorDatabase.insertOrReplace               │
    │                                                       │
    │   SceneClassifier.classify()                          │
    │     → VNClassifyImageRequest + VNCalculateImageAestheticsScoresRequest
    │     → labels + aesthetics + faceCount + isUtility     │
    │     → MetadataStore.storeSceneResult()                │
    │                                                       │
    └───────────────────────────────────────────────────────┘
    │
    ▼ Scene results gate phase 2
    │   • faces: skip if faceCount == 0
    │   • objects: skip if isUtility (screenshot/document)
    │   • OCR: always runs
    │
    ├─── Phase 2: Gated analysis (concurrent) ─────────────┐
    │                                                       │
    │   ObjectRecognizer.recognize()                        │
    │     → VNRecognizeFoodAndDrinkRequest (private)        │
    │     → VNClassifyPotentialLandmarkRequest (private)    │
    │     → VNRecognizeAnimalsRequest (public)              │
    │     → MetadataStore.storeRecognitions()               │
    │                                                       │
    │   FaceGallery.identify()                              │
    │     → VNDetectFaceRectanglesRequest → VUGallery match │
    │                                                       │
    │   TextRecognizer.recognize()                          │
    │     → CREngineAccurate / VNRecognizeTextRequest       │
    │     → OCRQualityFilter.partition()                    │
    │     → MetadataStore.storeTextObservations()           │
    │                                                       │
    └───────────────────────────────────────────────────────┘
    │
    ▼ Phase 3: Scoring (sequential)
    │
    │   JunkClassifier.classify()
    │     → VNClassifyJunkImageRequest (private, 17 categories)
    │     → MetadataStore.storeJunkResult()
    │
    │   CurationScorer.score()
    │     → Photos' formula: (0.1 + aesthetics×0.25 + content×0.65) × penalty
    │     → MetadataStore.storeCurationResult()
```

### Searching

```
Query string "dog at the beach"
    │
    ▼
SearchIndex.search()
    │
    ├─── [Task Group: concurrent] ──────────────────────────┐
    │                                                        │
    │   EmbeddingSearch.search(text:)                        │
    │     → BPE tokenize → CLIP text tower → calibration    │
    │     → IVF search → cosine similarity → results        │
    │                                                        │
    │   searchSceneLabels()                                  │
    │     → keyword match against stored scene labels        │
    │                                                        │
    │   searchObjectNames()                                  │
    │     → keyword match against stored recognitions        │
    │                                                        │
    │   searchTextContent()                                  │
    │     → substring match against stored OCR text          │
    │                                                        │
    └────────────────────────────────────────────────────────┘
    │
    ▼
mergeResults()
    → group by assetID
    → multi-modal boost (+0.1 per additional module match)
    → sort by combined score
    → return top N
```

## Module Independence

Each module is independently usable. You don't need SearchIndex:

```swift
// Just embeddings
let search = try EmbeddingSearch(storePath: url)
try await search.index(image: img, assetID: "001")
let results = try await search.search(text: "sunset")

// Just scenes
let classifier = try SceneClassifier()
let scene = try await classifier.classify(image: img)

// Just OCR
let ocr = try TextRecognizer(engine: .advanced, languages: ["en-US", "ja-JP"])
let text = try await ocr.recognize(image: img)

// Just faces
let gallery = try FaceGallery(galleryPath: url)
let matches = try await gallery.identify(image: img)

// Just junk detection
let junk = JunkClassifier()
let result = try await junk.classify(image: img)
print("Quality: \(result.confidence) via \(result.source)")

// Just curation scoring
let scorer = CurationScorer()
let curation = scorer.score(junkConfidence: 0.8, aestheticsScore: 0.7, faceCount: 2)
print("Curation: \(curation.score)")
```

## Threading Model

```
Main thread (caller)
    │
    ▼ async/await
SearchIndex.index()
    │
    ▼ withThrowingTaskGroup
    ├── EmbeddingSearch (serial queue: com.photopipeline.embedding)
    ├── SceneClassifier (serial queue: com.photopipeline.scene)
    ├── ObjectRecognizer (serial queue: com.photopipeline.object)
    ├── FaceGallery (serial queue: com.photopipeline.face)
    ├── TextRecognizer (dispatch_global_queue)
    ├── JunkClassifier (serial queue: com.photopipeline.junk — after phase 2)
    └── CurationScorer (sync — uses cached scene + junk results)
```

Each module has its own serial dispatch queue for thread safety. The SearchIndex orchestrates concurrent execution via Swift structured concurrency (task groups).

Apple's private frameworks have their own internal queues:
- `com.apple.espresso.mainqueue` (serialized Espresso inference)
- `com.apple.VN.requestAsyncTasksQueue` (Vision request dispatch)
- Per-detector queues (`com.apple.VN.detectorAsyncTasksQueue.{type}`)

## Storage Architecture

```
{storePath}/
├── embeddings/
│   └── meta/
│       ├── img-001.emb          (raw float32 embedding data)
│       ├── img-002.emb
│       └── ...
├── gallery/
│   └── faces/
│       ├── img-001_identity-A.json
│       └── ...
├── classifications/
│   ├── scene/
│   │   ├── img-001.json         (SceneResult)
│   │   └── ...
│   ├── object/
│   │   ├── img-001.json         (Recognition[])
│   │   └── ...
│   ├── text/
│   │   ├── img-001.json         (TextObservation[])
│   │   └── ...
│   ├── junk/                    (JunkResult per asset)
│   │   ├── img-001.json
│   │   └── ...
│   └── curation/                (CurationResult per asset)
│       ├── img-001.json
│       └── ...
├── text/                        (reserved for full-text index)
└── config.json                  (IndexConfiguration)
```

Each app gets a completely isolated silo. No shared state.

## Error Recovery

The library is designed to degrade gracefully:

1. **Framework load failure**: Module switches to public Vision API fallback
2. **Class not found**: Returns nil, module produces partial results
3. **Method invocation failure**: Logs error, continues with fallback path
4. **Storage corruption**: `PipelineStore.reset()` clears and recreates
5. **Model unavailable**: `Diagnostics.checkModelAvailability()` identifies missing models

No single failure takes down the entire pipeline.

## Dependencies

External: none. PhotoPipeline depends only on Apple system frameworks:

```
CoreGraphics    — CGImage, pixel buffers
CoreImage       — CIImage bridge
CoreML          — MLModel (for category-specific models)
Vision          — VN* request types (public API fallback)
CoreData        — VUGallery persistence
Foundation      — FileManager, JSONEncoder, etc.
CoreVideo       — CVPixelBuffer
ImageIO         — CGImageSource for EXIF metadata
ObjectiveC      — Runtime introspection (class_copyMethodList, etc.)
```

Private frameworks are loaded dynamically — they're optional at build time.
