# Refined icon

Option 1 from `docs/archive/round-25/extension-1.3.0/logo-sheet.png`.

- `refined.svg`: exact copy of the supplied `opt1-refined.svg`, used at 48px and larger.
- `refined-16.svg`: hand-tuned 16px mark, with 1px white brackets/stems and orange gaps.
- `refined-32.svg`: hand-tuned 32px mark, with 2px white brackets/stems and orange gaps.

Selection uses physical PNG dimensions: app 16@2x uses the 32px variant; app 32@2x
uses the full 64px mark. Every variant keeps the original 1024 viewBox, 824-unit
body inset by 100, corner radius 184, and the original NoDraw orange: a radial glow from `#ff8900`
at the centre to `#f68103` (md, 2026-10-04: the muted `#d87d0b` of the dev tile was not "the same orange"). The mark is white;
the new icons contain no black. All sources are font independent. The old dev-tile
sources remain in Git history and round-25; `outline-label.swift` is its historical
caption exporter and is not used by this pipeline.

From the repository root on macOS, with `rsvg-convert` and Pillow installed:

```sh
python3 Resources/logo/regenerate.py
python3 Resources/logo/verify.py
```

Regeneration writes ten app PNGs, seven extension icons, and both identical ICNS
copies using `iconutil -c icns`. No color-profile conversion is applied.
Toolbar `archive-*.png` and `archive-offline-*.png` glyphs are never regenerated.

Verification checks all 17 dimensions, both ICNS copies, six unchanged toolbar
glyphs, and all ten `iconutil -c iconset` round-trips (dimensions, alpha, and opaque
pixels). It samples four interior tile pixels in every export and round-trip and
requires opaque pixels inside the `#ff8900`–`#f68103` range, rejects `#11110f` and dark opaque pixels, and
checks that no ICC/gamma/chromaticity conversion metadata is present. At 16/32px,
it checks three separate white components, pixel-snapped strokes, and orange gaps.
App and extension outputs of the same physical size must match pixel for pixel.
macOS's legacy 16/32px ICNS encoder can change partially transparent edge RGB;
alpha and opaque pixels must still match exactly.

The verifier writes `Resources/logo/logo-refined-sheet.png`: all 17 outputs beside
the dev tile, at 1:1 and 4× nearest-neighbour, on light and dark backgrounds.
Baseline icons and toolbar glyphs are read from commit
`c4eca55a3dd0a310915a07c42d4bcd43540a437a`, so the checks and comparison remain
repeatable after integration. The sheet streams one scanline at a time to keep
memory low. Round-trip files and small inspection crops go in ignored `.verification/`.

Some macOS sandboxes make `iconutil` report "Invalid Iconset" because it cannot
access image services. The command may need headless execution outside the sandbox;
no app build, installation, GUI window, or audio device is involved.
