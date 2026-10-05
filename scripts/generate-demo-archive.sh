#!/usr/bin/env bash
#
# generate-demo-archive.sh — build NoDraw's shippable demo archive.
#
# Produces a folder of procedurally-generated, license-clean media (nothing is
# downloaded — every asset is synthesized here, so provenance is unambiguous)
# paired with per-item `.md` sidecars whose YAML frontmatter matches what
# MetadataParser.swift reads: source, platform, author, date, starred, tags,
# notes. The NoDraw app scans this folder and builds its own DB, thumbnails,
# and (when the vision pipeline is available) captions.
#
# Usage: ./scripts/generate-demo-archive.sh [OUTPUT_DIR]
#   OUTPUT_DIR defaults to Resources/DemoArchive
#
# Idempotent: wipes and regenerates OUTPUT_DIR's media/sidecars each run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO_ROOT/Resources/DemoArchive}"

for tool in magick ffmpeg; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: '$tool' not found (needed to synthesize demo media)" >&2; exit 1; }
done

echo "Generating NoDraw demo archive → $OUT"
mkdir -p "$OUT"
# Clean prior generated assets (leave README.md in place).
find "$OUT" -type f ! -name 'README.md' -delete 2>/dev/null || true

# ---- helpers ---------------------------------------------------------------

# gradient_tile NAME WxH C1 C2 LABEL SUBLABEL
# A two-stop linear gradient with a centered label — distinct + identifiable.
gradient_tile() {
  local name="$1" size="$2" c1="$3" c2="$4" label="$5" sub="${6:-}"
  local w="${size%x*}" h="${size#*x}"
  magick -size "${size}" "gradient:${c1}-${c2}" \
    -gravity center \
    -pointsize $(( w < h ? w/9 : h/9 )) -fill "#ffffffcc" -font Helvetica \
    -annotate 0 "$label" \
    -gravity south -pointsize $(( (w<h?w:h)/22 )) -fill "#ffffff88" \
    -annotate +0+$(( h/12 )) "$sub" \
    "$OUT/${name}.jpg"
}

# plasma_tile NAME WxH LABEL
plasma_tile() {
  local name="$1" size="$2" label="$3"
  local w="${size%x*}" h="${size#*x}"
  magick -size "${size}" plasma:fractal -blur 0x2 \
    -gravity center -pointsize $(( (w<h?w:h)/9 )) -fill "#000000aa" -font Helvetica \
    -annotate +3+3 "$label" -fill "#ffffffee" -annotate 0 "$label" \
    "$OUT/${name}.jpg"
}

# pattern_tile NAME WxH C1 C2 LABEL — checkerboard-ish geometric fill.
pattern_tile() {
  local name="$1" size="$2" c1="$3" c2="$4" label="$5"
  local w="${size%x*}" h="${size#*x}"
  magick -size "${size}" "pattern:checkerboard" \
    -fill "$c1" -opaque white -fill "$c2" -opaque black -scale "${size}!" \
    -gravity center -pointsize $(( (w<h?w:h)/8 )) -fill "#111111dd" -font Helvetica \
    -annotate +2+2 "$label" -fill "#f8f8f8ee" -annotate 0 "$label" \
    "$OUT/${name}.jpg"
}

# clip NAME WxH SECONDS LABEL — short synthetic video (demonstrates scrubber).
# testsrc2 is a synthetic animated test pattern (clearly-generated, license-clean)
# with a moving element + on-frame timer, which reads well under the scrubber.
clip() {
  local name="$1" size="$2" secs="$3" label="$4"  # label kept for call-site clarity
  ffmpeg -nostdin -loglevel error -y \
    -f lavfi -i "testsrc2=size=${size}:rate=24:duration=${secs}" \
    -pix_fmt yuv420p -c:v libx264 -crf 34 -preset medium -movflags +faststart \
    "$OUT/${name}.mp4"
}

# context_png NAME WxH LABEL — a fake "source context" screenshot sidecar.
context_png() {
  local name="$1" size="$2" label="$3"
  local w="${size%x*}"
  magick -size "${size}" "gradient:#20232a-#12141a" \
    -gravity north -fill "#8ab4f8" -pointsize $(( w/28 )) -font Helvetica \
    -annotate +0+$(( w/28 )) "context • ${label}" \
    -gravity center -fill "#e8eaed" -pointsize $(( w/34 )) \
    -annotate 0 "captured page context\n(synthetic demo screenshot)" \
    "$OUT/${name}.context.png"
}

# sidecar NAME -- writes NAME.md. Frontmatter fields via env-ish positional:
# sidecar NAME SOURCE PLATFORM AUTHOR DATE STARRED "TAG1,TAG2" NOTES BODY [MEDIA]
sidecar() {
  local name="$1" source="$2" platform="$3" author="$4" date="$5" \
        starred="$6" tags="$7" notes="$8" body="$9" media="${10:-}"
  {
    echo "---"
    echo "source: ${source}"
    echo "platform: ${platform}"
    [ -n "$author" ] && echo "author: \"${author}\""
    echo "date: ${date}"
    echo "archived: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "starred: ${starred}"
    if [ -n "$tags" ]; then
      echo "tags:"
      IFS=',' read -ra _t <<< "$tags"
      for t in "${_t[@]}"; do echo "  - ${t}"; done
    else
      echo "tags: []"
    fi
    [ -n "$notes" ] && echo "notes: \"${notes}\""
    echo "---"
    echo ""
    echo "${body}"
    [ -n "$media" ] && { echo ""; echo "![[${media}]]"; }
  } > "$OUT/${name}.md"
}

# ---- items -----------------------------------------------------------------
# Varied dimensions/orientations (masonry), platforms, tags, starred, dates.

gradient_tile "01-aurora-wide"     1600x600  "#0f2027" "#2c5364" "Aurora"    "wide · landscape"
sidecar "01-aurora-wide" "https://demo.local/aurora" "bluesky" "skywatch.demo" "2025-11-02T08:15:00Z" \
  "true" "demo,gradient,landscape,starred" "Wide banner gradient — good for masonry row spanning." \
  "A cold aurora gradient, wide format. Demonstrates a landscape tile in the grid." "01-aurora-wide.jpg"

gradient_tile "02-ember-portrait" 620x1400  "#ff512f" "#dd2476" "Ember"     "tall · portrait"
sidecar "02-ember-portrait" "https://demo.local/ember" "reddit" "r/gradients" "2025-11-14T19:40:00Z" \
  "false" "demo,gradient,portrait" "Tall portrait gradient to exercise the masonry column height variance." \
  "Ember — a warm vertical gradient. Portrait orientation for the masonry layout." "02-ember-portrait.jpg"

gradient_tile "03-mint-square"    1080x1080 "#134e5e" "#71b280" "Mint"      "square"
sidecar "03-mint-square" "https://demo.local/mint" "import" "" "2025-10-21T12:00:00Z" \
  "false" "demo,gradient,square" "" \
  "Mint — a square gradient tile imported from a local file." "03-mint-square.jpg"

gradient_tile "04-dusk-standard" 1280x960  "#654ea3" "#eaafc8" "Dusk"      "4:3"
sidecar "04-dusk-standard" "https://demo.local/dusk" "twitter" "duskposts" "2025-09-30T22:05:00Z" \
  "true" "demo,gradient,starred" "Starred so it shows in a Starred smart folder." \
  "Dusk — a soft 4:3 gradient. Starred item for the Starred/Favorites view." "04-dusk-standard.jpg"

plasma_tile   "05-plasma-noise"  1200x900  "Plasma"
sidecar "05-plasma-noise" "https://demo.local/plasma" "import" "" "2025-08-18T09:12:00Z" \
  "false" "demo,texture,plasma" "Procedural plasma texture — nice thumbnail contrast." \
  "Plasma — procedural fractal noise. Shows a textured (non-gradient) thumbnail." "05-plasma-noise.jpg"

plasma_tile   "06-plasma-tall"   720x1280  "Signal"
sidecar "06-plasma-tall" "https://demo.local/signal" "youtube" "SignalChannel" "2025-07-04T15:30:00Z" \
  "false" "demo,texture,portrait" "" \
  "Signal — a tall procedural texture. Portrait plasma for layout variety." "06-plasma-tall.jpg"

pattern_tile  "07-check-cyan"    1400x1050 "#0891b2" "#0f172a" "Grid"
sidecar "07-check-cyan" "https://demo.local/grid" "reddit" "r/patterns" "2025-06-11T11:11:00Z" \
  "false" "demo,pattern,geometric" "Geometric checker pattern." \
  "Grid — a cyan checkerboard pattern. Demonstrates a geometric, high-frequency thumbnail." "07-check-cyan.jpg"

pattern_tile  "08-check-amber"   1000x1000 "#f59e0b" "#1c1917" "Weave"
sidecar "08-check-amber" "https://demo.local/weave" "import" "" "2025-05-27T17:45:00Z" \
  "true" "demo,pattern,geometric,starred" "" \
  "Weave — an amber checkerboard. Starred geometric tile." "08-check-amber.jpg"

gradient_tile "09-slate-pano"    1920x720  "#232526" "#414345" "Slate"     "panorama"
sidecar "09-slate-pano" "https://demo.local/slate" "bluesky" "mono.demo" "2025-04-15T06:20:00Z" \
  "false" "demo,gradient,landscape,panorama" "Ultra-wide panorama to stress the row layout." \
  "Slate — a near-monochrome panorama. Very wide aspect ratio." "09-slate-pano.jpg"

gradient_tile "10-rose-portrait" 700x1250  "#ee9ca7" "#ffdde1" "Rose"      "tall"
sidecar "10-rose-portrait" "https://demo.local/rose" "twitter" "roseposts" "2025-03-08T13:37:00Z" \
  "false" "demo,gradient,portrait" "Light, high-key gradient — tests thumbnail on light content." \
  "Rose — a soft high-key portrait gradient." "10-rose-portrait.jpg"

gradient_tile "11-ocean-square"  900x900   "#2b5876" "#4e4376" "Ocean"     "square"
sidecar "11-ocean-square" "https://demo.local/ocean" "import" "" "2025-02-19T20:00:00Z" \
  "false" "demo,gradient,square" "" \
  "Ocean — a deep square gradient." "11-ocean-square.jpg"

gradient_tile "12-solar-wide"    1500x560  "#f12711" "#f5af19" "Solar"     "wide"
sidecar "12-solar-wide" "https://demo.local/solar" "reddit" "r/wallpapers" "2025-01-25T10:05:00Z" \
  "true" "demo,gradient,landscape,starred" "Bright starred banner." \
  "Solar — a hot wide gradient. Starred banner tile." "12-solar-wide.jpg"

# --- video items (playback scrubber) + context screenshots ---
clip "13-loop-teal"  1280x720 6 "Loop · Teal"
context_png "13-loop-teal" 1280x720 "Loop Teal"
sidecar "13-loop-teal" "https://demo.local/video/teal" "twitter" "motionposts" "2024-12-30T18:00:00Z" \
  "true" "demo,video,starred" "Short synthetic clip — demonstrates the playback scrubber and a .context.png sidecar." \
  "Loop Teal — a 6-second synthetic test clip. Use it to exercise the video scrubber." "13-loop-teal.mp4"

clip "14-loop-mono"  960x960  5 "Loop · Mono"
context_png "14-loop-mono" 960x960 "Loop Mono"
sidecar "14-loop-mono" "https://demo.local/video/mono" "youtube" "LoopLab" "2024-11-12T09:00:00Z" \
  "false" "demo,video,square" "Square synthetic clip with a context screenshot." \
  "Loop Mono — a 5-second square synthetic clip." "14-loop-mono.mp4"

# ---- report ----------------------------------------------------------------
echo ""
echo "Done. Items generated in $OUT:"
count_md=$(find "$OUT" -name '*.md' ! -name 'README.md' | wc -l | tr -d ' ')
count_media=$(find "$OUT" \( -name '*.jpg' -o -name '*.mp4' \) | wc -l | tr -d ' ')
total_size=$(du -sh "$OUT" | cut -f1)
echo "  items:  $count_md"
echo "  media:  $count_media (jpg + mp4)"
echo "  size:   $total_size"
