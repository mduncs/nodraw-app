# Model Catalog

Every ML model used by Apple's photo analysis pipeline, with paths, sizes, and I/O specs.

---

## Vision.framework Models

Location: `/System/Library/Frameworks/Vision.framework/Versions/A/Resources/`

Total: ~154 MB across 35 Espresso + 3 CoreML models.

### Person Segmentation / Subject Lifting

| Model | Size | Input | Output |
|-------|------|-------|--------|
| personsegmentation-si-01.espresso | 6.9 MB | RGB image | L008 pixel buffer (per-person confidence) |
| subject_lifting_gen1_rev5_*.espresso | 15 MB | RGB image | Instance masks (multi-head, int8) |
| learned-matting-1512x2016.espresso | 393 KB | High-res RGB | Alpha matte |
| learnedmatting-f16-v2.espresso | 1.2 MB | RGB image | Alpha matte (v2) |

### Face Recognition

| Model | Size | Input | Output |
|-------|------|-------|--------|
| facerec_fp3.1.3b_fa1.3.espresso | 10 MB | Aligned face 224x224 | Embedding vector (128/256-dim) |
| facerec_fa1.3_lightweight_fp16.espresso | 3.4 MB | Aligned face | Lightweight screening embedding |
| face_quality_v1.0_fp16.espresso | 1.1 MB | Face crop | Quality score 0-1 |
| face_quality_v2.0_fp16.espresso | 1.4 MB | Face crop | Quality score v2 |
| facequality_regression-*_fp16.espresso | 2.0 MB | Face crop | Quality regression v3 |
| landmarksflow-*_quantized.espresso | 3.1 MB | Aligned face | 76-point landmark constellation |
| solo_landmarks_*_opt.espresso | 748 KB | Aligned face | Lightweight landmarks |
| faceSemantics_v1_15class_quant.espresso | 1.4 MB | Face crop | 15-class semantic segmentation |

### Body & Animal Detection

| Model | Size | Input | Output |
|-------|------|-------|--------|
| bodynet_v1.0.espresso | 1.8 MB | RGB image | Body detection boxes |
| torso_v3_md2_fp16.espresso | 4.4 MB | RGB image | Torso detection v3 |
| torso_v4_md2.espresso | 7.1 MB | RGB image | Torso detection v4 |
| torso_v5_md2.espresso | 5.9 MB | RGB image | Torso detection v5 |
| pet_v1_md2_fp16.espresso | 4.4 MB | RGB image | Pet detection v1 |
| pet_v2_md3_fp16.espresso | 4.9 MB | RGB image | Pet detection v2 |
| anodv3_drop3.espresso | 5.2 MB | RGB image | Animal detection v3 |
| anodv4_drop6_fp16.espresso | 4.9 MB | RGB image | Animal detection v4 (FP16) |
| anodv5_drop1_8b.espresso | 2.6 MB | RGB image | Animal detection v5 (INT8) |

### Scene & Saliency

| Model | Size | Input | Output |
|-------|------|-------|--------|
| SCL_v0.3.1_*.espresso | 8.8 MB | RGB image | 44 scene class probabilities |
| saliency_attention_box_head_*_fp16.espresso | 157 KB | Image features | Attention heatmap |
| saliency_objectness_boxes_head_*_fp16.espresso | 160 KB | Image features | Objectness heatmap |
| NeuralHashv3b_fp16-current.espresso | 3.7 MB | RGB image | 128-bit perceptual hash |
| gazefollowingflow-*_fp16.espresso | 2.4 MB | RGB image | Gaze following vector |

### Document & Tracking

| Model | Size | Input | Output |
|-------|------|-------|--------|
| docseg_segflow-*_512x288_finalFC.espresso | 1.6 MB | Document image | Document segmentation mask |
| rpn_template_v5.espresso | 10 MB | Template image | RPN tracker template features |
| rpn_track_v5.espresso | 1.9 MB | Search region | RPN tracking output |

### Binary Data Files

| File | Size | Purpose |
|------|------|---------|
| faceBoxPoseAligner-current.bin | 3.0 MB | Face box-to-pose alignment |
| faceRegionMap-current.bin | 264 KB | Face region mapping |
| landmarkRefinerAndPupil_v2.bin | 11 MB | Landmark + pupil refinement |
| neuralhash_128x96_seed1.dat | 49 KB | NeuralHash seed matrix |
| fc-svm-sv.dat | 3.5 MB | Face clustering SVM support vectors |

### E5RT (MIL) Models

| Model | Purpose |
|-------|---------|
| screengaze_ek_iphone_fp16.mil | Screen gaze (iPhone) |
| screengaze_ek_ipad_fp16.mil | Screen gaze (iPad) |
| faceliveliness_ek_fp16.mil | Face liveness detection |
| faceprint_ek_fp16.mil | Face identity print |
| torsoprint_ek_fp16.mil | Torso identity print |

---

## MediaAnalysis.framework Models

Location: `/System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/Resources/`

Total: ~250+ MB across 50+ models.

### Scene & Embedding (Key Models)

| Model | Format | Input | Output | Notes |
|-------|--------|-------|--------|-------|
| MonzaV4_1.mlmodelc | CoreML | 224x224 BGR | 224 scene classes | 53-layer CNN backbone |
| mubb_md7.mlmodelc | CoreML | Image | Multi-modal embedding | MD7 unified backbone |

### Text Embedding Pipeline

| Model | Size | Purpose | Versions |
|-------|------|---------|----------|
| bpe_ranks.json | 1.0 MB | BPE tokenization pairs | All versions |
| bytes_to_unicode.json | 3.8 KB | Byte-to-unicode mapping | All versions |
| text_calibration_md3.espresso.* | — | Z-score normalization | Shared by MD3-MD7 |
| text_threshold_md3.espresso.* | — | Threshold computation | MD3 |
| text_threshold_md4.espresso.* | — | Threshold computation | MD4 |
| text_threshold_md5_v2.espresso.* | — | Threshold computation | MD5 |
| text_threshold_md6_v1.espresso.* | — | Threshold computation | MD6 |
| text_threshold_md7_v1.espresso.* | — | Threshold computation | MD7 |
| text_safety_md3-7.espresso.* | — | Content safety (7 versions) | MD3-MD7 |

### Analysis Models

| Model | Purpose |
|-------|---------|
| cnn_blur.espresso / cnn_blurV2.espresso | Image blur detection |
| cnn_blink.espresso | Eye blink detection |
| cnn_smile.espresso | Smile detection |
| cnn_human_pose.espresso | Multi-person pose estimation |
| cnn_human_pose_single.espresso | Single-person pose |
| cnn_human_pose_lite_v2.espresso | Lightweight pose |
| cnn_image_human_action.espresso | Image action classification |
| cnn_pets.espresso / cnn_pets_detector_v2.espresso | Pet detection |
| cnn_pet_pose.espresso | Pet pose estimation |
| video_backbone.espresso | Video CNN feature extraction |
| action_recognition_head.espresso | 35-class video action |
| flow_estimation_2-6.espresso | Optical flow (6 scale levels) |
| highlight_head.espresso | Video highlight detection |
| autoplay_head.espresso | Autoplay scoring |
| quality_head.espresso | Image quality scoring |
| feature_extraction.espresso | Feature embedding (MD7) |
| pissarro.espresso | Image enhancement |

### Additional Bundles

```
md4_text_model.bundle    — Text embedding model V4
md5_text_model.bundle    — Text embedding model V5
t5_base.model            — T5 base model (captioning)
omnie_t0_50k.model       — OmniE model (captioning)
action_taxonomy.plist    — Action classification taxonomy (35 categories)
```

---

## VisualLookup.framework Models

Location: `/System/Library/PrivateFrameworks/VisualLookUp.framework/Versions/A/Resources/`

### assets_581/ (Domain + Object + Food + Signs)

| Model | URN | Input | Output | Size |
|-------|-----|-------|--------|------|
| DomainPredictionModel | argos/domain_prediction/4vuak7p44f | node_feature[1,20,132] + edge_attr[1,20,20,1] | 21-class domain probs | GNN |
| DomainPredictionGroundingModel | argos/domain_prediction/iwfgi6ct63 | node_feature[1,20,182] + edge_attr[1,20,20,1] | 21-class (with text) | GNN |
| ObjectDetectionModel | argos/detector_cc/ew2qte4dud | 512x512 RGB | nmsBoxes[1,50,4] + nmsScores[1,50,108] | EfficientDet |
| FoodModel | argos/food/distill_efnb2_v2_2 | 360x360 RGB | classification + embedding | EfficientNet-B2 |
| UnifiedModel | argos/landmark2d/98z23s2jux | 360x360 RGB | 2D landmark + skyline + embedding | — |
| SignSymbolModel | argos/sign_symbol/nic8v72m9a | 360x360 RGB | classification + embedding | — |

### assets_582/ (Natureworld)

| Model | URN | Input | Output Heads |
|-------|-----|-------|--------------|
| NatureworldModel | argos/natureworld/earth-embedding-ahj4i4hdg2 | 360x360 RGB | animals, dog, cat, coat_pattern, plants, embedding |

Size: 13 MB weights

### assets_588/ (Text Lookup)

```
LSHProjectionMatrix.json   (16 KB)
Tokenizer.index            (5.2 KB)
```

### Storefront Models

| Model | Input | Output |
|-------|-------|--------|
| CategoryClassificationModel.mlmodelc | 512x512 RGB + OCR text | 920 categories |
| TitleClassificationModel.mlmodelc | 512x512 RGB + OCR text | 1,167 named brands |

### Mapping Files (vienc-encrypted JSON)

```
NatureworldAnimalsMapping.json     (212 KB)
NatureworldDogMapping.json         (2.2 KB)
NatureworldCatMapping.json         (605 B)
NatureworldCoatMapping.json        (148 B)
NatureworldNatureMapping.json      (434 KB)
FoodMapping.json                   (99 KB)
SignSymbolMapping.json              (21 KB)
ObjectDetectionMapping.json
DomainKnowledgeIdsMapping.json     (95 KB)
StorefrontCategoryLabelMapping.json (55 KB)
StorefrontTitleLabelMapping.json   (26 KB)
```

### RichLabelKV (Localized Names)

LZFSE-compressed knowledge base files for 16 languages:

```
RichLabelKgCommonNameEn.lzfse   (347 KB)
RichLabelKgCommonNameDe.lzfse
RichLabelKgCommonNameFr.lzfse
RichLabelKgCommonNameEs.lzfse
... (16 total)
RichLabelThresholdConfig.lzfse  (12 KB)
```

---

## TextRecognition.framework Models

Location: `/System/Library/Frameworks/TextRecognition.framework/Resources/`

### Detection

| Model | Size | Purpose |
|-------|------|---------|
| cr_td_model_v3_e5.mlmodelc.bundle | 5.4 MB | E5 runtime text detection (ANE-optimized) |
| cr_td_model_v3_eir.mlmodelc.bundle | 5.6 MB | EIR fallback detection |
| cr_orientation_model_v1.mlmodelc.bundle | 5.7 MB | Text orientation correction |

### Recognition (per-script)

| Model | Size | Scripts |
|-------|------|---------|
| cr_tr_model_latincyrillic_v3 | 7.4 MB | Latin + Cyrillic (28 locales) |
| cr_tr_model_chinese_v3 | 16 MB | Simplified + Traditional Chinese |
| cr_tr_model_japanese_v3 | 14 MB | Japanese |
| cr_tr_model_korean_v3 | 11 MB | Korean |
| cr_tr_model_arabic_v3 | 7.4 MB | Arabic |
| cr_tr_model_thai_v3 | 4.5 MB | Thai |

### Document Analysis

| Model | Size | Purpose |
|-------|------|---------|
| cr_form_detector.mlmodelc.bundle | 4.1 MB | Form field detection |
| cr_form_ct_v2.mlmodelc.bundle | 788 KB | Form content type |
| tsr_encoder.mlmodelc.bundle | 4.4 MB | Table structure encoder |
| tsr_decoder.mlmodelc.bundle | 1.8 MB | Table structure decoder |

---

## VisualUnderstanding.framework Models

Location: embedded in framework binary

| Model | Purpose |
|-------|---------|
| face_encoder.mlmodelc | Face embedding (subject_embedding output) |
| _conditioning_producer.mlmodelc | Image generation conditioning |
| personalized_conditioning_producer.mlmodelc | Personalized image generation |

---

## Embedding Version History

| Version | Backbone | Calibration | Text Threshold | Safety | Context |
|---------|----------|-------------|----------------|--------|---------|
| MD1 | Base | — | — | — | Default |
| MD2 | Base | — | — | — | Default |
| MD3 | Base | text_calibration_md3 | text_threshold_md3 | — | Default |
| MD4 | Base | text_calibration_md3 | text_threshold_md4 | — | Default |
| MD5 | Upgraded | text_calibration_md3 | text_threshold_md5_v2/v3 | text_safety_md5 | Default + Extended |
| MD6 | Upgraded | text_calibration_md3 | text_threshold_md6_v1 | text_safety_md6_v1 | Default + Extended |
| **MD7v2** | mubb_md7 | text_calibration_md3 | text_threshold_md7_v1 | text_safety_md7_v1..v4 | Default + Extended |

Current unified version: **MD7** (`SearchUnifiedEmbeddingMD7`)

All versions MD3+ share the same calibration model (`text_calibration_md3`) — Z-score normalization with model-specific mean and standard deviation.
