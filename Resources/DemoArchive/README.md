# NoDraw Demo Archive

A small, self-contained sample archive for demonstrating NoDraw out of the box.
Every asset here is **procedurally generated** (gradients, plasma textures,
geometric patterns, and synthetic `testsrc2` video) — nothing was downloaded, so
the licensing is unambiguous and it's safe to ship with a release.

- **14 items** · ~2 MB total
- 12 images + 2 short videos, in varied dimensions/orientations (wide, tall,
  square, panorama) to show off the masonry grid
- Spread across platforms (`twitter`, `reddit`, `bluesky`, `youtube`, `import`),
  with tags, notes, starred flags, and dates ranging over ~2 years

## How to open it in NoDraw

NoDraw indexes a **folder** of media + `.md` sidecars — it builds its own
database, thumbnails, and (when the vision pipeline is available) captions by
scanning the folder. It does not read a pre-built database, so there's nothing
to import; you just point the app at this folder.

1. Launch **NoDraw**.
2. On first run, the onboarding screen asks you to **Select Media Archive
   Folder** — choose this `DemoArchive` folder.
   (Already past onboarding? Go to **Settings → Downloads → Select Archive
   Folder** and pick this folder, or drop this folder in and use the folder
   picker from the "Archive Folder Not Found" prompt.)
3. NoDraw scans the folder and populates the grid.

## What it demonstrates

- **Masonry grid** — deliberately varied aspect ratios (1600×600 banners,
  620×1400 portraits, 1080×1080 squares, 1920×720 panoramas) so the layout's
  column balancing is visible.
- **Focus / detail view** — each item has body text, `notes`, an author, a
  source URL, and an original date pulled from its `.md` frontmatter.
- **Playback scrubber** — the two `.mp4` items (`13-loop-teal`, `14-loop-mono`)
  are short synthetic clips for exercising video playback and scrubbing. Each
  also ships a `.context.png` "source context" screenshot sidecar.
- **Smart folders** — the metadata is designed to make smart folders trivial to
  build, e.g.
  - **Starred** → 5 items are `starred: true`
  - **Videos** → filter tag `video`
  - **By platform** → `twitter`, `reddit`, `bluesky`, `youtube`, `import`
  - **By shape** → tags `landscape` / `portrait` / `square`
- **Search** — searchable across notes, author, and body text.
- **Vision captions** — `generatedCaption` is produced by NoDraw's local vision
  pipeline when it scans the archive; it is **not** pre-baked into these files.
  Tags, notes, search, and smart folders work immediately on open; captions fill
  in once the vision pipeline runs.

## Archive format (per item)

Each item is a media file plus a companion `.md` sidecar sharing its basename
(e.g. `01-aurora-wide.jpg` ↔ `01-aurora-wide.md`). The sidecar carries YAML
frontmatter that `MetadataParser.swift` reads:

```yaml
---
source: https://demo.local/aurora   # required
platform: bluesky                    # else inferred from source
author: "skywatch.demo"
date: 2025-11-02T08:15:00Z           # also: tweet_date / created / post_date
archived: 2026-07-21T00:00:00Z
starred: true                        # also: favorite
tags: [demo, gradient, landscape, starred]
notes: "…"                           # also: description
---
Body text shown in the detail view.

![[01-aurora-wide.jpg]]
```

## Regenerating

The whole archive is reproducible:

```sh
./scripts/generate-demo-archive.sh            # → Resources/DemoArchive
./scripts/generate-demo-archive.sh /some/dir  # → custom location
```

Requires `magick` (ImageMagick) and `ffmpeg`. The script wipes and rebuilds the
media + sidecars on each run (this README is left untouched).
