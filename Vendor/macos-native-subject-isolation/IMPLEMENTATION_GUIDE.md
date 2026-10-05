# Subject Isolation Implementation Guide (Apple Native)

## Summary
Use Vision to get per-subject masks, trace contours for hit-testing/shape effects, and render a layered AppKit view with dimming + glow + parallax pop-out ("jump off screen"). This guide targets private-parity visuals first, with runtime fallback where private APIs are unavailable.

## Prereqs and Constraints
- Platform: macOS 14+
- Frameworks: Vision, CoreImage, CoreGraphics, QuartzCore, AppKit
- Private parity path: `CAFilter` (`gaussianBlur`, `colorMatrix`) and private Vision request probing are non-App-Store safe.
- Subject labels from Vision instance masks are 1-based.

## Data Contracts

```swift
struct SubjectInstance {
    let index: Int                  // 1-based Vision label
    let mask: CGImage               // white=subject, black=background
    let boundingBox: CGRect         // normalized [0,1]
    let contourPath: CGPath?        // full contours
    let outerContourPath: CGPath?   // top-level contour only
}

struct IsolationResult {
    let subjects: [SubjectInstance]
    let foregroundMask: CGImage?
    let semanticMasks: [SegmentationType: CGImage]
    let imageSize: CGSize
}
```

## Step 1: Acquire Subject Masks (Working Mask)
1. Create `VNGenerateForegroundInstanceMaskRequest`.
2. Run with `VNImageRequestHandler(cgImage: image, options: [:])`.
3. Read first `VNInstanceMaskObservation`.
4. For each `instanceIdx` in `observation.allInstances`, call:
   - `generateScaledMaskForImage(forInstances: IndexSet(integer: instanceIdx), from: handler)`
5. Convert `CVPixelBuffer` to `CGImage` using shared `CIContext`.
6. Optional combined mask:
   - Merge masks with per-pixel max (`CIMaximumCompositing`).

Critical correctness rules:
- Use `generateScaledMaskForImage(...)` for mask extraction.
- Do not treat cutout-output APIs as binary masks.
- Keep instance IDs as labels, never array positions.

## Step 2: Build Contours and Bounding Boxes
1. Run `VNDetectContoursRequest` on each mask image.
2. Build:
   - `contourPath`: full contour set.
   - `outerContourPath`: top-level contours only.
3. Default simplification: `0.005`.
4. Compute normalized bounding box by scanning non-zero mask pixels.

## Step 3: Compose Layer Tree
Use this order:
1. `imageLayer` (source image)
2. `colorLayer` (dimming overlay)
3. `highlightContainer`
4. `highlightLayer` (same image, masked by `CAShapeLayer`)
5. `glowLayer` (animated strokes)

Mandatory layout rule:
- Set `maskShapeLayer.frame = parent bounds` every layout pass, or masking can render empty.

## Step 4: Jump-Off-Screen (Parallax Pop-Out)
When subject activates:
1. Build combined subject path from highlighted subjects.
2. Apply to mask layer.
3. Animate selected subject presentation:
   - scale up slightly (`~1.03` to `1.08`)
   - screen-space translation toward pointer/focus (small `x/y` offset)
   - increase shadow radius/opacity
   - raise highlight container opacity
4. Dim non-subject background (`colorLayer.opacity`).
5. While active, update translation continuously from pointer delta for micro-parallax.
6. On deactivate, animate all transforms/shadows/opacity back to baseline.

Success criteria:
- Subject appears lifted above image.
- No path drift during resize or focus updates.
- Entry/exit transitions are smooth and reversible.

## Step 5: Glow Animation
1. Reverse contour path before stroke animation.
2. Create thin and thick stroke sets:
   - Thin: 6/8/12 strokes based on screen scale.
   - Thick: 3 strokes.
3. Animate `strokeEnd` leading and `strokeStart` trailing in looping groups.
4. Duration:
   - `cycle = clamp(pathLength / 600, 4.5, 6.0)`
5. Fade-in: `2.0s`, opacity transition: `0.35s`.
6. Private parity styling:
   - `CAFilter("gaussianBlur")`
   - `CAFilter("colorMatrix")`
   - `compositingFilter = "screenBlendMode"`

Fallback:
- If private filters unavailable, keep white strokes + opacity animation; do not fail.

## Step 6: Interaction and Hit Testing
1. Convert click point to normalized view coordinates.
2. Test against subject contour paths.
3. Return matching subject `index` or `nil`.
4. Toggle `highlightedSubjects` set by label value.

## Step 7: Export/Copy Cutout
1. Collect masks for highlighted subjects.
2. Combine masks.
3. Apply with `CIBlendWithMask` over transparent background.
4. Return `CGImage`/`NSImage` preserving alpha.

## Troubleshooting Matrix
- Symptom: Highlight invisible.
  - Cause: Mask layer frame not set to bounds.
  - Fix: Assign frame each layout pass.
- Symptom: Wrong subject toggles.
  - Cause: Treated labels as 0-based indices.
  - Fix: Use Vision labels directly.
- Symptom: Jagged or collapsed contour.
  - Cause: Simplification too high.
  - Fix: Default to `0.005`.
- Symptom: Glow missing on some systems.
  - Cause: Private filters unavailable.
  - Fix: Public stroke fallback.
- Symptom: Cutout halo/incorrect alpha.
  - Cause: Mask/image scale mismatch.
  - Fix: Scale mask to image dimensions before blend.

## Validation Checklist
- Mask extraction uses `generateScaledMaskForImage`.
- Multiple subjects isolate correctly and independently.
- Hit-testing maps to correct 1-based labels.
- Pop-out visibly lifts subject and tracks pointer subtly.
- Glow runs continuously with no flicker.
- Resize keeps mask/path alignment.
- Cutout export has transparent background.
