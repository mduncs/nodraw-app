# PhotoPipeline Guide

## What This Is

A Swift library that wraps Apple's private on-device photo analysis frameworks into a reusable API. The same ML pipeline that powers Photos.app — CLIP semantic search, scene classification, breed/food/landmark recognition, face identity, and OCR — made accessible to any macOS app.

## What This Is NOT

- A replacement for Photos.app
- A reimplementation of Apple's ML models
- Something you can ship on the Mac App Store
- An iOS library (different framework paths)
- A way to read Photos.app's data (we create our own silos)

## Requirements

| Requirement | Detail |
|-------------|--------|
| macOS | 14.0+ (Sonoma) |
| Swift | 5.9+ |
| Xcode | 15+ |
| Sandbox | **Non-sandboxed** (required for dlopen) |
| SIP | Standard (no SIP modifications needed) |
| TCC | None for your own images. Full Disk Access for Photos library. |
| Distribution | Direct download, Homebrew, or SPM only. No App Store. |

## Why Non-Sandboxed?

The private frameworks live at `/System/Library/PrivateFrameworks/`. Sandboxed apps cannot `dlopen` these paths. The library detects this and falls back to public Vision APIs where possible, but the full feature set requires non-sandboxed execution.

## Architecture Overview

```
Your App
    │
    ▼
SearchIndex (orchestrator — scene-gated pipeline)
    │
    ├── Phase 1 (always)
    │   ├── EmbeddingSearch     → MADEmbeddingStore (MediaAnalysis)
    │   └── SceneClassifier     → MonzaV4_1 backbone (VisionCore)
    │
    ├── Phase 2 (gated by scene)
    │   ├── ObjectRecognizer    → Private VNRequests (Vision)
    │   ├── FaceGallery         → VUGallery (VisualUnderstanding)
    │   └── TextRecognizer      → CREngineAccurate (TextRecognition)
    │
    ├── Phase 3 (scoring)
    │   ├── JunkClassifier      → VNClassifyJunkImageRequest (Vision)
    │   └── CurationScorer      → Photos' exact highlight formula
    │
    ▼
FrameworkBridge (dlopen + ObjC runtime)
    │
    ▼
Apple Private Frameworks (on every Mac)
```

## Quick Start

### 1. Add the dependency

```swift
// Package.swift
dependencies: [
    .package(path: "/path/to/macos-native-photo-pipeline")
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: ["PhotoPipeline"]
    )
]
```

### 2. Check system compatibility

```swift
import PhotoPipeline

let report = Diagnostics.systemReport()
print(report)  // shows macOS version, frameworks, models
```

### 3. Create an index

```swift
let storePath = URL(fileURLWithPath: "/tmp/my-photo-index")
let index = try SearchIndex(configuration: .full, storePath: storePath)
```

### 4. Index images

```swift
import ImageIO

let imageURL = URL(fileURLWithPath: "/path/to/photo.jpg")
let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil)!
let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)!

try await index.index(image: cgImage, assetID: "photo-001")
```

### 5. Search

```swift
let results = try await index.search("sunset at the beach")
for r in results {
    print("\(r.assetID): \(r.detail) [\(r.matchType)] score=\(r.score)")
}
```

## Graceful Degradation

Every module has a fallback path:

| Module | Full (private API) | Fallback (public API) |
|--------|--------------------|-----------------------|
| Embeddings | MADEmbeddingStore IVF search | VNFeaturePrintObservation |
| Scenes | MonzaV4_1 multi-head | VNClassifyImageRequest |
| Objects | GNN + domain models | VNClassifyImageRequest |
| Faces | VUGallery + clustering | VNDetectFaceRectanglesRequest |
| Text | CREngineAccurate (6 langs) | VNRecognizeTextRequest |
| Junk | VNClassifyJunkImageRequest | Saliency + classification heuristics |
| Curation | Photos' exact formula | N/A (always available) |

The fallback produces less detailed results but works in sandboxed apps and on systems where private frameworks are unavailable.

## Thread Safety

All module classes are marked `@unchecked Sendable` with internal serial dispatch queues. Safe to call from any actor/thread. SearchIndex.index() runs a two-phase gated pipeline: phase 1 (scene + embedding) runs concurrently, then scene results gate phase 2 (object, face, text). Phase 3 (junk + curation scoring) runs sequentially after phase 2 completes.

## Error Handling

All errors are `FrameworkError` cases:

```swift
public enum FrameworkError: Error {
    case frameworkNotFound(String, path: String)
    case classNotFound(String, framework: String)
    case methodNotFound(String, className: String)
    case invocationFailed(String)
    case unsupportedOS(current: String, minimum: String)
}
```

Framework loading errors are non-fatal — modules that can't load their private frameworks switch to public API fallbacks.

## Version Coupling

Private framework internals change between macOS versions. Known coupling points:

- **Embedding versions**: MD4 → MD7v2. Library defaults to MD7v2 (macOS 14+).
- **Model files**: paths may shift between framework versions. `Diagnostics.checkModelAvailability()` verifies at runtime.
- **Class names**: Private ObjC classes can be renamed/removed. The `classNamed()` pattern handles this gracefully — returns nil instead of crashing.

## Constraints

1. **No code signing entitlements needed** — dlopen of system frameworks works for non-sandboxed processes
2. **No SIP bypass needed** — these frameworks are in the dyld shared cache and loadable by any non-sandboxed process
3. **No root access needed** — everything runs as the current user
4. **No network access** — all ML inference is 100% on-device
5. **Storage scales linearly** — roughly 2-5 KB per indexed image (embeddings + metadata)
6. **OCR quality filtering** — configurable post-OCR noise filter removes watermarks, overlay text, and low-quality detections
