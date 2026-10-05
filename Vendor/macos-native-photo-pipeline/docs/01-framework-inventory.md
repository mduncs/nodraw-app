# Framework Inventory

Every private framework used by PhotoPipeline, what it does, and key classes.

## Framework Map

| Framework | Size | Role | Key Classes |
|-----------|------|------|-------------|
| MediaAnalysis | ~250 MB | ML orchestration, embeddings, analysis tasks | MADEmbeddingStore, MADVectorDatabase, VCPPhotoAnalyzer |
| VisualUnderstanding | ~15 MB | Face/person identity, gallery management | VUGallery, VUIndexClusterer, VUStreamingGallery |
| VisualLookUp | ~80 MB | Object recognition, domain classification | VLLookUpService, VLCategoryClassificationModel, FAISS |
| VisionCore | ~3 MB | SceneNet backbone, inference network descriptors | VisionCoreInferenceNetworkDescriptor |
| TextRecognition | ~70 MB | Advanced OCR (6 language models) | CREngineAccurate, CREngineFast, ImageReader |
| Espresso | ~120 MB | ML inference engine (ANE/GPU/CPU) | espresso_plan_*, E5RT* |
| PhotoAnalysis | ~30 MB | Analysis scheduling, worker management | VCPMediaAnalysisService, ActivityManager |
| PhotosIntelligence | ~60 MB | LLMQU, memory/story generation | QueryAnnotatorV2, GenerativeModels |

## Loading Order

Frameworks have interdependencies. Load in this order:

```
1. Espresso          (no dependencies — foundational ML runtime)
2. VisionCore        (depends on Espresso)
3. MediaAnalysis     (depends on Espresso, VisionCore)
4. VisualLookUp      (depends on Vision, TextRecognition, E5RT)
5. VisualUnderstanding (depends on Vision, CoreML)
6. TextRecognition   (depends on Espresso, E5RT)
```

PhotoPipeline handles this automatically — each module loads its required frameworks on init.

## Framework Paths

All at `/System/Library/PrivateFrameworks/{Name}.framework/{Name}`

```
/System/Library/PrivateFrameworks/MediaAnalysis.framework/MediaAnalysis
/System/Library/PrivateFrameworks/VisualUnderstanding.framework/VisualUnderstanding
/System/Library/PrivateFrameworks/VisualLookUp.framework/VisualLookUp
/System/Library/PrivateFrameworks/VisionCore.framework/VisionCore
/System/Library/PrivateFrameworks/TextRecognition.framework/TextRecognition
/System/Library/PrivateFrameworks/Espresso.framework/Espresso
/System/Library/PrivateFrameworks/PhotoAnalysis.framework/PhotoAnalysis
/System/Library/PrivateFrameworks/PhotosIntelligence.framework/PhotosIntelligence
```

Resources (ML models, configs) at:
```
/System/Library/PrivateFrameworks/{Name}.framework/Versions/A/Resources/
```

---

## MediaAnalysis (Detail)

The central ML orchestration framework. Manages the analysis pipeline, embedding store, and vector database.

### Embedding Pipeline

| Class | Address | Role |
|-------|---------|------|
| MADEmbeddingStore | 0x252743544 | Embedding search API |
| MADVectorDatabase | 0x25279b9b4 | IVF vector index backend |
| MADVectorDatabaseManager | 0x25277e8c0 | Singleton manager |
| MADSharedTextEncoder | 0x2529fbe34 | CLIP text encoder |
| MADTextEmbeddingCalibration | 0x2528eba28 | Z-score normalization |
| MADTextEmbeddingThreshold | 0x25281e508 | Threshold computation |
| MADTextEmbeddingSafety | 0x252a0ac78 | Safety filtering |

### Key Methods

```objc
// Embedding search
+[MADEmbeddingStore searchWithEmbeddings:photoLibraryURL:options:error:]
+[MADEmbeddingStore fetchEmbeddingsWithAssetUUIDs:photoLibraryURL:options:error:]
+[MADEmbeddingStore prewarmSearchWithConcurrencyLimit:photoLibraryURL:error:]

// Vector database
-[MADVectorDatabase insertOrReplaceAssetsEmbeddings:error:]
-[MADVectorDatabase removeAssetsWithUUIDs:]
-[MADVectorDatabase rebuildWithForce:cancelBlock:extendTimeoutBlock:totalEmbeddingCount:]

// Text encoding
-[MADSharedTextEncoder loadResources]
-[MADSharedTextEncoder runOnInput:output:error:]
+[MADSharedTextEncoder computeBackend]
```

### Analysis Tasks

| Class | Purpose |
|-------|---------|
| VCPPhotoAnalyzer | Full image analysis orchestrator |
| VCPMovieAnalyzer | Video analysis pipeline |
| VCPMADVISceneClassificationTask | Scene classification |
| VCPMADImageEmbeddingTask | Image embedding extraction |
| VCPMADImageCaptionTask | Image captioning |
| VCPMADVIFaceTask | Face analysis subtask |
| VCPMADImageSafetyClassificationTask | Content safety filtering |
| VCPMADVIVisualSearchTask | Object/entity recognition |
| VCPMADVIVisualSearchGatingTask | Domain routing (GNN) |

---

## VisualUnderstanding (Detail)

Face/person identity management. CoreData-backed gallery with IVF vector search.

### Gallery System

| Class | Role |
|-------|------|
| VUGallery | Main gallery (init with client + database URL) |
| VUPersistedIndex | CoreData persistence layer |
| VUIndexCoreDataStore | CoreData entities (Observation, Mapping, Partition) |
| VUIndexClusterer | Label propagation on neighbor graph |
| VUStreamingGallery | Real-time face recognition (video) |
| VUEnrollmentGallery | Face enrollment flow |
| VUFaceRepresentation | Face encoder (face_encoder.mlmodelc) |

### CoreData Entities

```
VUIndexObservation:
  - identifier: Int64
  - embedding: Data              (face/animal/scene vector)
  - contextualEmbedding: Data    (scene-context-aware)
  - embeddingConfidence: Float
  - isPrimary: Bool
  - quality: Float
  - type: Int                    (0=person, 1=animal, 2=scene)
  - asset: UUID?

VUIndexMapping:
  - label: Int                   (cluster ID, -1 = unassigned)
  - partition: Int               (IVF partition)
  - density: Float
  - partner: Int                 (nearest in cluster)

VUIndexPartition:
  - centroid: Data               (centroid vector)
  - type: Int
```

### Clustering Parameters

```
clusteringThreshold: Float         (similarity cutoff)
numClusteringNeighbors: Int        (KNN count)
numClusteringProbes: Int           (IVF probes)
classificationThreshold: Float     (tag assignment)
contextualScalingFactor: Float     (contextual embedding weight)
```

### Multi-Biometric Support

Three observation types with independent confidence thresholds:
- Face embeddings (`minFaceprintConfidence`)
- Torso embeddings (`minTorsoprintConfidence`)
- Animal embeddings (`minAnimalprintConfidence`)

---

## VisualLookUp (Detail)

Object recognition with domain-specific models and FAISS vector search.

### Architecture

```
Image → EfficientDet (108 classes) → GNN Domain Router (21 domains)
                                          │
    ┌─────────────────────────────────────┤
    │                │                    │
    ▼                ▼                    ▼
NatureworldModel   FoodModel        UnifiedModel
(dogs/cats/birds)  (EfficientNet)   (landmarks)
    │                │                    │
    ▼                ▼                    ▼
FAISS embedding    Classification    Classification
search             + embedding       + embedding
    │                │                    │
    ▼                ▼                    ▼
RichLabelKV (localized entity names, 16 languages)
```

### Domain Prediction GNN

```
Model: DomainPredictionModel
Input:  node_feature[1, 20, 132]  (20 objects, 132-dim features)
        edge_attr[1, 20, 20, 1]   (spatial relationships)
Output: 21-class domain probabilities
```

21 Domains: UNKNOWN, ART, NATURE, LANDMARK, CATS, DOGS, BOOK, ALBUM, BIRD, INSECTS, NATURAL_LANDMARK, SCULPTURE, SKYLINE, MAMMAL, REPTILE, APPAREL, FOOD, STOREFRONT, LAUNDRY_CARE_SYMBOL, AUTO_SYMBOL, ACCESSORIES

### Category Models

| Model | Input | Output | Domain |
|-------|-------|--------|--------|
| NatureworldModel | 360x360 RGB | 6 heads (animals, dog, cat, coat, plants, embedding) | Dogs, Cats, Birds, Plants |
| FoodModel | 360x360 RGB | classification + embedding | Food |
| UnifiedModel | 360x360 RGB | 2D landmark + skyline + embedding | Landmarks, Skyline |
| SignSymbolModel | 360x360 RGB | classification + embedding | Signs, Symbols |
| ObjectDetectionModel | 512x512 RGB | up to 50 boxes, 108 classes | General detection |

### FAISS Integration

Embedded FAISS library for fast vector similarity search:
- IndexFlatIP (inner product / cosine)
- IndexFlatL2 (Euclidean)
- IVFPQScanner (inverted file + product quantization)

---

## Vision Private VNRequest Classes

The library accesses these undocumented VNRequest subclasses via `NSClassFromString`. They live in the public Vision.framework but aren't declared in public headers.

### Used by ObjectRecognizer

| Class | Purpose | Output |
|-------|---------|--------|
| `VNRecognizeFoodAndDrinkRequest` | Food/drink identification | VNClassificationObservation (food names from RichLabelKV) |
| `VNClassifyPotentialLandmarkRequest` | Landmark identification | VNClassificationObservation (landmark names, sentinel "VNPotentialLandmarkIdentifier" filtered) |

### Used by JunkClassifier

| Class | Purpose | Output |
|-------|---------|--------|
| `VNClassifyJunkImageRequest` | Image quality classification | VNClassificationObservation (17 hierarchical categories) |

Junk categories returned:
`hier_non_memorable`, `hier_poor_quality`, `hier_text_document`, `receipt_or_document`, `hier_tragic_failure`, `screenshot`, `blurry`, `bad_lighting`, `bad_framing`, `negative`, `shopping_reference`, `medical_reference`, `utility_reference`, `repair_reference`, `food_or_drink`, `hier_negative`

### Used by SceneClassifier

| Class | Purpose | Output |
|-------|---------|--------|
| `VNCalculateImageAestheticsScoresRequest` | Aesthetics scoring | VNImageAestheticsScoresObservation (overallScore, isUtility, failure/quality subscores) |
| `VNClassifyImageAestheticsRequest` | Detailed aesthetic attributes | Per-attribute scores (framing, lighting, color, etc.) |
| `VNGenerateAttentionBasedSaliencyImageRequest` | Attention saliency | VNSaliencyImageObservation (salientObjects bounding boxes) |

### Other Interesting Private VNRequests (not yet used)

| Class | Purpose | Notes |
|-------|---------|-------|
| `VNRecognizeAnimalHeadsRequest` | Animal head detection + breed | Returns VNRecognizedObjectObservation with breed labels |
| `VNRecognizeAnimalFacesRequest` | Animal face detection | Separate from heads -- face-only bounding boxes |
| `VNClassifyMemeImageRequest` | Meme/text-overlay detection | Binary classification |
| `VNGenerateImageFingerprint` | Perceptual hash | 128-bit NeuralHash for duplicate detection |
| `VNDetectLensSmudgeRequest` | Lens smudge detection | Binary classification |

---

## TextRecognition (Detail)

Multi-stage OCR pipeline with 6 language-specific models.

### Pipeline Stages

```
Image → Orientation Correction → Text Detection → Script Classification
      → Language Routing → Neural Recognition → CTC + LM Decoding
      → Post-Processing → Data Detection (phones, URLs, dates)
```

### Language Models

| Script | Model | Size | Languages |
|--------|-------|------|-----------|
| Latin + Cyrillic | cr_tr_model_latincyrillic_v3 | 7.4 MB | en, de, fr, es, it, pt, ru, uk, tr, cs, ... |
| Chinese | cr_tr_model_chinese_v3 | 16 MB | zh-Hans, zh-Hant |
| Japanese | cr_tr_model_japanese_v3 | 14 MB | ja-JP |
| Korean | cr_tr_model_korean_v3 | 11 MB | ko-KR |
| Arabic | cr_tr_model_arabic_v3 | 7.4 MB | ar-SA |
| Thai | cr_tr_model_thai_v3 | 4.5 MB | th-TH |

### Key Classes

| Class | Role |
|-------|------|
| CREngineAccurate | Full pipeline (detection + recognition) |
| CREngineFast | Lightweight pipeline |
| CRTextDetectionPipeline | Stage 2: text region detection |
| CRConcurrentRecognitionPipeline | Parallel recognition |
| CRCTCTextDecoderV3 | CTC beam search + language model |
| CRTextOrientationCorrector | Auto-rotation |

### Optional Capabilities

- **Form detection**: `cr_form_detector.mlmodelc.bundle` (4.1 MB)
- **Table structure**: `tsr_encoder.mlmodelc.bundle` (4.4 MB) + `tsr_decoder.mlmodelc.bundle` (1.8 MB)
- **Data detection**: Phones, URLs, emails, dates, addresses via DataDetectorsCore

---

## Espresso / E5RT (Detail)

Apple's internal ML inference engine. Two active generations coexist.

### Espresso v1 (Classic)

```c
espresso_context_t ctx = espresso_create_context(engine, device_id);
espresso_plan_t plan = espresso_create_plan(ctx, priority);
espresso_plan_add_network(plan, model_path, storage_type, &network);
espresso_plan_build(plan);
espresso_network_bind_buffer(network, &buffer, blob_name, BIND_INPUT);
espresso_plan_execute_sync(plan);
```

Model format: `.espresso.net` (JSON topology) + `.espresso.weights` (binary)

### E5RT (Modern)

```c
e5rt_e5_compiler_t compiler = e5rt_e5_compiler_create(opts);
e5rt_program_t compiled = e5rt_e5_compiler_compile(compiler, mil_source);
e5rt_program_library_t lib = e5rt_program_library_create(compiled);
e5rt_execution_stream_t stream = e5rt_execution_stream_create();
e5rt_execution_stream_execute_sync(stream);
```

Model format: `.mil` bundle (Machine Learning Intermediate Language)

### Compute Backends

| Backend | Engine ID | Used When |
|---------|-----------|-----------|
| ANE (Neural Engine) | 0x2717 | Primary — fastest, most efficient |
| GPU (Metal/MPS) | 5 | Fallback when ANE unavailable |
| CPU (BNNS/Accelerate) | 0 | Last resort |

Automatic fallback chain: ANE → GPU → CPU

### Buffer Binding Modes

| Mode | Source | Zero-Copy? |
|------|--------|------------|
| bind_buffer | Raw pointer | Depends |
| bind_cvpixelbuffer | CVPixelBuffer | Yes (GPU/ANE) |
| bind_input_vimagebuffer_bgra8 | vImage BGRA8 | CPU-side |
| e5rt bind_buffer_object | E5RT buffer | Backend-managed |
| e5rt bind_surface_object | IOSurface | Yes (GPU/ANE) |

---

## Version Compatibility

| Framework | macOS 13 | macOS 14 | macOS 15 |
|-----------|----------|----------|----------|
| MediaAnalysis | Present | Present (MD7v2) | Present |
| VisualUnderstanding | Present | Present | Present |
| VisualLookUp | Present | Present (21 domains) | Present |
| VisionCore | Present | Present (SceneNetV3) | Present |
| TextRecognition | Present (V2) | Present (V3) | Present |
| Espresso | Present | Present + E5RT | Present |

The library targets macOS 14+ to ensure consistent APIs. Older versions may work with reduced functionality.
