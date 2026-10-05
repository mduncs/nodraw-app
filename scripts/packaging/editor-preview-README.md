# NoDraw Editor Preview

This is the native image-editor feature build, not the installed NoDraw app.
Double-click **NoDraw Editor Preview.app**. No installation is needed.

On first launch, the app creates its own folder at
`~/Library/Application Support/NoDraw Editor Preview`:

- `Archive`: a writable copy of the bundled, procedurally generated demo archive.
- `AppSupport`: preview database, layered edits, imported image assets, caches, and logs.

The preview has its own app identifier/preferences. Its supported `--editor-preview`
mode suppresses automatic enrichment, notification prompts, download-server changes,
and model preload while keeping normal foreground window behavior. Manual editor
subject analysis remains available. It does not copy or open the installed app's
archive, database, or browser profile. Relaunching preserves your preview edits.
You can move the app without moving this preview data.

## Try the editor

1. Open the app and wait for the sample grid. Double-click **Dusk**, **Mint**, or
   another still image. The synthetic videos are not editor targets.
2. Click the pencil-shaped **Edit image** button in the image's top bar, or press
   **A** (also **⌘\\**) from image detail. This opens the left tool rail, centered
   canvas, right inspector/layers, and bottom actions.
3. Choose Rectangle, Ellipse, Arrow, Draw, Highlighter, or Text on the left.
   Drag to draw; for Text, click the image, type, then press Return.
4. Choose Select (arrow). Click/drag an object to move it; use its eight handles
   to resize. Shift-click or drag an empty area for multiple selection. Shift-resize
   preserves proportions. The right inspector changes existing styles/text.
5. Try **Crop** and drag a region/its handles, or use the crop inspector's **Apply Crop**
   button. **Adjustments** changes brightness, contrast, saturation, temperature,
   tint, sharpness, and vignette. Slider changes commit when released.
6. In **Layers**, use the eye/lock controls, opacity/blend controls, and right-click
   a layer for rename, reorder, duplicate, or delete. **Add image** at the bottom
   imports a file as a separate editable image layer.
7. Use **⌘Z / ⇧⌘Z** to undo/redo. **Save & Close** saves the layered edit. Reopen
   the same image's editor to continue. **Export…** writes a separate composite;
   the source image remains unchanged.

The bottom **Add image** imports into the current composition. To use a different
photo as the base image, drag that photo into the library grid to import a copy,
then open that new item and enter the editor. The initial sample images are
synthetic gradients/patterns, so they do not demonstrate subject detection well.
Use a real photo with a clear person/object for **Select Subject**, then click the
highlighted subject and **Lift selected subject**. Remove Background, Isolate
People, and the Erase/Restore mask brush are local tools; generation and generative
inpainting are not part of this preview.

## Files and verification

`Contents/Resources/EditorPreviewBuild.json` records the release build identity,
feature flags, source snapshot, and pre-signing executable hash. The build output's
adjacent `EditorPreviewArtifact.json` records the final signed executable and ZIP
SHA-256 values and sizes. The bundle is ad-hoc signed for this local preview.

To launch from Terminal, execute the wrapper, **not** the inner NoDraw binary:

```sh
"/path/to/NoDraw Editor Preview.app/Contents/MacOS/NoDrawEditorPreview"
```

Quitting and relaunching keeps the preview's edits. To start fresh, quit this
preview and rename `~/Library/Application Support/NoDraw Editor Preview`; the next
launch creates a fresh sample library. This does not affect the installed app.

For a disposable background QA profile, set `NODRAW_EDITOR_PREVIEW_DATA_DIR` to a
new absolute temporary directory and run the native launcher with `--background-qa`.
That explicit override is only for a separate test profile; the normal app launch
always uses the isolated Application Support folder above.
