# PhotoPipeline

A Swift library that wraps Apple's private on-device photo analysis frameworks — the same ML models and vector databases that power Photos.app search — into a reusable API for any macOS app.

## What It Does

Photos.app runs 35+ neural network models for every photo: scene classification, CLIP embeddings, object/breed recognition, face identity, OCR, aesthetics scoring. All on-device, all using private frameworks that ship on every Mac.

PhotoPipeline wraps these private frameworks via `dlopen` and exposes them through a clean Swift API with its own isolated storage (no dependency on Photos.app data).

## Quick Start

```swift
import PhotoPipeline

// Create an index with all modules enabled
let index = try SearchIndex(configuration: .full, storePath: myAppSiloURL)

// Index images
let image: CGImage = /* load your image */
try await index.index(image: image, assetID: "photo-001")

// Multi-modal search — queries embeddings, scenes, objects, and OCR simultaneously
let results = try await index.search("dog at the beach")
for result in results {
    print("\(result.assetID): \(result.detail) [\(result.matchType)] score=\(result.score)")
}
```

## Modules

| Module | What | Private Framework | Public Fallback |
|--------|------|-------------------|-----------------|
| **EmbeddingSearch** | CLIP text↔image semantic search | MADEmbeddingStore + MADVectorDatabase | VNFeaturePrintObservation |
| **SceneClassifier** | Scene labels + aesthetics + junk detection | VCPMADVISceneClassificationTask | VNClassifyImageRequest |
| **ObjectRecognizer** | Breeds, food, landmarks (21 domains) | VisualLookup + GNN domain router | VNClassifyImageRequest |
| **FaceGallery** | Face identity with clustering | VUGallery + VUIndexClusterer | VNDetectFaceRectanglesRequest |
| **TextRecognizer** | OCR with dual engine | CREngineAccurate (6 language models) | VNRecognizeTextRequest |

Each module works independently or combined through `SearchIndex`.

## Requirements

- **macOS 14+** (Sonoma)
- **Non-sandboxed** (private framework dlopen requires it)
- **Swift 5.9+**
- **Not App Store compatible** (private framework usage)

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(path: "/path/to/macos-native-photo-pipeline")
]
```

## Configuration Presets

```swift
// Everything enabled
let full = IndexConfiguration.full

// Just embeddings + scene labels (fastest)
let minimal = IndexConfiguration.minimal

// Embeddings + scene + OCR (no face/object)
let search = IndexConfiguration.searchFocused

// Custom
let custom = IndexConfiguration(
    enableEmbeddingSearch: true,
    enableSceneClassification: true,
    enableObjectRecognition: false,
    enableFaceGallery: false,
    enableTextRecognition: true,
    embeddingVersion: .md7v2,
    ocrLanguages: ["en-US", "de-DE"]
)
```

## Diagnostics

Check what's available on the current system:

```swift
// Framework availability
let availability = FrameworkLoader.availability()
for (fw, status) in availability {
    print("\(fw.rawValue): \(status)")
}

// Full system report
let report = Diagnostics.systemReport()
print(report)

// Model availability
let models = Diagnostics.checkModelAvailability()
```

## Documentation

| Doc | Content |
|-----|---------|
| [00-guide.md](docs/00-guide.md) | Requirements, constraints, quick start |
| [01-framework-inventory.md](docs/01-framework-inventory.md) | Every private framework, what it does, version compatibility |
| [02-architecture.md](docs/02-architecture.md) | Library design, module relationships, data flow |
| [03-api-reference.md](docs/03-api-reference.md) | Every public API with usage examples |
| [04-integration-recipes.md](docs/04-integration-recipes.md) | End-to-end "how do I..." guides |
| [05-model-catalog.md](docs/05-model-catalog.md) | All ML models, paths, I/O specs |
| [06-storage-guide.md](docs/06-storage-guide.md) | Database silos, index management |

## Project Structure

```
Sources/PhotoPipeline/
├── Bridge/           # dlopen + ObjC runtime wrappers
│   ├── FrameworkLoader.swift
│   ├── ObjCRuntime.swift
│   └── Diagnostics.swift
├── Modules/          # Each independently usable
│   ├── EmbeddingSearch.swift
│   ├── SceneClassification.swift
│   ├── ObjectRecognition.swift
│   ├── FaceGallery.swift
│   ├── TextRecognition.swift
│   └── DomainClassification.swift
├── Index/            # Orchestration layer
│   ├── SearchIndex.swift
│   ├── IndexManager.swift
│   └── IndexConfiguration.swift
├── Storage/          # Isolated data silos
│   ├── PipelineStore.swift
│   ├── VectorStore.swift
│   └── MetadataStore.swift
└── Models/           # Shared types
    ├── Asset.swift
    ├── Embedding.swift
    ├── Classification.swift
    └── SearchResult.swift
```

## How It Works

1. **dlopen** loads private frameworks from `/System/Library/PrivateFrameworks/`
2. **NSClassFromString** resolves ObjC classes (MADEmbeddingStore, VUGallery, etc.)
3. **ObjC runtime** calls methods on dynamically loaded classes
4. **Your silo** stores all data independently from Photos.app
5. **Public Vision API** provides fallback when private frameworks are unavailable

## License

Research project. Not affiliated with Apple. Private framework usage is unsupported and may break between macOS versions.
