# macOS Native Subject Isolation

Swift Package wrapping Apple's Vision segmentation APIs (public + private) with VisionKit-style subject glow animation. macOS 14+, non-sandboxed, no App Store.

## Quick Start

```swift
let isolator = SubjectIsolator()
let result = try await isolator.isolate(image: cgImage)
for subject in result.subjects {
    let cutout = subject.cutout(from: cgImage)  // subject on transparent bg
    let path = subject.contourPath              // for glow animation
}
```

## Critical Settings

| Setting | Value | Why |
|---------|-------|-----|
| `contourSimplification` | **0.005** | epsilon in [0,1] normalized space. 1.0 destroys all contour detail (reduces to degenerate 2-point segments). 0.005 balances quality vs point count for glow animation |
| Mask API | `generateScaledMaskForImage(forInstances:from:)` | returns binary mask (white=subject). NOT `generateMaskedImage()` which returns the actual RGB cutout — using that as a mask produces garbage |
| `maskShapeLayer.frame` | must match parent bounds | CAShapeLayer used as CALayer.mask needs its frame set, otherwise renders nothing (zero bounds = empty mask) |
| Subject indices | Vision instance labels are **1-based** | `observation.allInstances` returns IndexSet with labels 1..N. Never use as array indices — filter by `.index` property |

## API Surface

### SubjectIsolator (ML)
- `isolate(image:options:)` → `IsolationResult` — per-instance masks + contours + optional semantic masks
- `removeBackground(image:quality:)` → `CGImage` — person-only background removal using a soft segmentation matte
- `foregroundMask(image:)` → `CGImage` — combined binary mask of all subjects
- `segmentPersons(image:quality:)` → `PersonSegmentationResult` — person-only soft matte

### SubjectHighlightView (UI)
- `image` / `isolationResult` / `highlightedSubjects` — set these to activate
- `beginGlow(for:)` / `endGlow()` — control animation
- `subjectIndex(at:)` — hit testing
- `onSubjectTapped` — click handler
- `copyHighlightedSubjects()` → `NSImage` — subject on transparent bg

## Segmentation APIs

| API | Scope | Output | Notes |
|-----|-------|--------|-------|
| `VNGenerateForegroundInstanceMaskRequest` | Any foreground subject | Per-instance binary mask | Primary "Copy Subject" path |
| `VNGeneratePersonSegmentationRequest` | People only | Soft alpha matte | 3 quality levels (fast/balanced/accurate) |
| `VNGeneratePersonInstanceMaskRequest` | People only | Per-person mask (max 4) | Public, macOS 14+ |
| `VNGenerateSemanticSegmentationCompoundRequest` | Multi-head | person+sky+glasses+attributes | **Private**, single backbone pass, much faster |
| `VNGenerateSkySegmentationRequest` | Sky regions | Binary mask | Private/macOS 15+ |
| `VNGenerateGlassesSegmentationRequest` | Glasses on faces | Binary mask | Private/macOS 15+ |
| `VNGenerateHumanAttributesSegmentationRequest` | Hair/skin/clothing | Semantic map | Private/macOS 15+ |
| `VNGenerateAnimalSegmentationRequest` | Animals | Binary mask | Private/macOS 15+ |

Private APIs probed via `NSClassFromString` with graceful nil fallback.

## Thresholds (from Ghidra RE)

Apple applies **no additional confidence thresholds** on top of `VNGenerateForegroundInstanceMaskRequest`. The neural network output is used directly with argmax merging (max confidence wins per pixel, labels 1-N for instances, 0 for background). No post-processing filters, hole filling, or area minimums at runtime — those are baked into the model.

Quality levels for person segmentation are mapped explicitly to Vision constants:
- **fast**: lightweight model, lower quality
- **balanced**: routes through compound request internally (single backbone)
- **accurate**: fast model + learned matting refinement (tiled fp16 with Metal GPU stitching)

## Glow Animation (from Ghidra RE of VisionKitCore)

Layer tree matches `VKCImageSubjectBaseView`:
```
root → imageLayer → colorLayer (dimming) → highlightContainer → highlightShadow → highlightLayer (masked)
     → glowLayer (thin + thick animated strokes)
```

Key constants (from VKCGlowParameters decompilation):
- **Thin strokes**: 6/8/12 by DPI, thickness 0.5-1.5×viewScale, blur 1.5×viewScale, opacity 1.0
- **Thick strokes**: 3 strokes, thickness 4-16×viewScale, blur 20×viewScale, opacity 0.3-0.5
- **Duration**: `clamp(pathLength / 600, 4.5, 6.0)` seconds
- **Fade-in**: 2.0s, opacity transition: 0.35s
- **Color matrix**: R+0.5 bias, G+0.15, B from alpha +0.4, A+0.3 (warm blue-white)
- **CAFilter** (private): gaussianBlur + colorMatrix on glow containers
- **Compositing**: screenBlendMode on containers

## Architecture

```
Sources/SubjectIsolation/
├── Bridge/ObjCRuntime.swift          Minimal ObjCBridge (create, call, KVC)
├── ML/
│   ├── SubjectIsolator.swift         Main entry point, async/DispatchQueue
│   ├── SegmentationRequests.swift    Request construction + private API probing
│   ├── MaskProcessor.swift           CVPixelBuffer↔CGImage, CIBlendWithMask
│   └── ContourTracer.swift           Mask → CGPath via VNDetectContoursRequest
├── UI/
│   ├── SubjectHighlightView.swift    Drop-in NSView with dimming + glow
│   ├── GlowLayer.swift              Animated shimmer (thin+thick strokes)
│   ├── GlowParameters.swift         Constants from RE decompilation
│   ├── SubjectMaskLayer.swift        Mask shape + dimming layer management
│   └── PathUtilities.swift           Path length, reversal, transforms
└── Models/
    ├── IsolationResult.swift         subjects[], foregroundMask, semanticMasks
    ├── SubjectInstance.swift          mask, boundingBox, contourPath, cutout()
    └── SegmentationType.swift         Enum + IsolationOptions
```

## Demos

- `swift run Demo <image> [output.png]` — CLI: prints subject info, saves cutout
- `swift run DemoUI [image]` — GUI: SubjectHighlightView with glow, click to toggle subjects

## Related

- Photo pipeline: `../macos-native-photo-pipeline/`

The segmentation thresholds and model behavior noted above were worked out
against the shipping frameworks. Those working notes are not part of this
package.
