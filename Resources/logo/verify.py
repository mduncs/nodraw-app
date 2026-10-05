#!/usr/bin/env python3
"""Validate icons and stream the comparison sheet without a giant image buffer."""
from pathlib import Path
from io import BytesIO
import shutil
import struct
import subprocess
import zlib
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
BASELINE = 'c4eca55a3dd0a310915a07c42d4bcd43540a437a'
# The tile is a radial glow from #ff8900 (centre) to #f68103 (edge), so samples are checked against that range.
def is_orange(pixel):
    r, g, b, a = pixel
    return a == 255 and 246 <= r <= 255 and 129 <= g <= 137 and b <= 3
WORK = ROOT / 'Resources/logo/.verification'
WORK.mkdir(exist_ok=True)
shutil.rmtree(WORK / 'roundtrip.iconset', ignore_errors=True)
subprocess.run(['iconutil', '-c', 'iconset', str(ROOT / 'Resources/AppIcon.icns'),
                '-o', str(WORK / 'roundtrip.iconset')], check=True)
app = sorted((ROOT / 'Resources/AppIcon.iconset').glob('*.png'),
             key=lambda p: (Image.open(p).width, p.name))
extension = [ROOT / f'extension/src/assets/icons/icon-{n}.png' for n in (16, 32, 48, 64, 96, 128, 256)]
assert len(app) == 10
exact = 0


def check_colors(icon, label):
    n = icon.width
    # These four samples are fully inside the tile, away from the white mark.
    for x, y in ((.5, .25), (.25, .5), (.75, .5), (.5, .75)):
        point = (int(n * x), int(n * y))
        assert is_orange(icon.getpixel(point)), (label, point, icon.getpixel(point))
    for r, g, b, a in icon.getdata():
        assert (r, g, b) != (17, 17, 15), (label, 'forbidden black')
        if a == 255:
            assert r >= 246 and g >= 129, (label, 'dark opaque pixel')


def check_small_mark(icon, label):
    n = icon.width
    # Eight-neighbour connectivity catches even diagonal joins between the three marks.
    white = {(x, y) for y in range(n) for x in range(n)
             if icon.getpixel((x, y))[2] > 128 and icon.getpixel((x, y))[3] == 255}
    components = 0
    while white:
        components += 1
        pending = [white.pop()]
        while pending:
            x, y = pending.pop()
            neighbours = {(x + dx, y + dy) for dx in (-1, 0, 1) for dy in (-1, 0, 1)} & white
            white.difference_update(neighbours)
            pending.extend(neighbours)
    assert components == 3, (label, 'brackets and n must be separate', components)
    scale = n // 16
    for x, y in ((4, 4), (11, 11), (6, 9), (9, 9)) if n == 16 else ((8, 8), (23, 23), (13, 19), (19, 19)):
        assert icon.getpixel((x, y)) == (255, 255, 255, 255), (label, 'snapped stroke', x, y)
    for y in range(5 * scale, 6 * scale):
        assert is_orange(icon.getpixel((6 * scale, y))), (label, 'upper gap')
    for y in range(10 * scale, 11 * scale):
        assert is_orange(icon.getpixel((9 * scale, y))), (label, 'lower gap')


def check_png(p):
    with Image.open(p) as png:
        assert not ({'icc_profile', 'gamma', 'chromaticity'} & png.info.keys()), (p, 'color profile')
        icon = png.convert('RGBA')
    check_colors(icon, p)
    if icon.width in (16, 32):
        check_small_mark(icon, p)
    return icon


for p in app:
    expected = int(p.stem.split('x')[0].split('_')[1]) * (2 if '@2x' in p.stem else 1)
    original = check_png(p)
    returned = check_png(WORK / 'roundtrip.iconset' / p.name)
    assert original.size == (expected, expected), p
    assert returned.size == original.size, p
    assert original.getchannel('A').tobytes() == returned.getchannel('A').tobytes(), p
    if original.tobytes() == returned.tobytes():
        exact += 1
    else:
        assert p.name in ('icon_16x16.png', 'icon_32x32.png'), p
        opaque = [(original.getpixel((x, y)), returned.getpixel((x, y)))
                  for y in range(expected) for x in range(expected)
                  if original.getpixel((x, y))[3] == 255]
        assert all(a == b for a, b in opaque), p
        print(f'NOTE: {p.name}: legacy iconutil partially transparent edge RGB differences; opaque pixels and alpha exact.')
for p in extension:
    n = int(p.stem.split('-')[1])
    icon = check_png(p)
    assert icon.size == (n, n), p
    for app_path in app:
        with Image.open(app_path) as app_icon:
            if app_icon.width == n:
                assert icon.tobytes() == app_icon.convert('RGBA').tobytes(), (p, app_path)
assert (ROOT / 'Resources/AppIcon.icns').read_bytes() == (ROOT / 'Sources/MediaViewer/Resources/AppIcon.icns').read_bytes()
toolbar = sorted((ROOT / 'extension/src/assets/icons').glob('archive-*.png'))
assert len(toolbar) == 6
for p in toolbar:
    old = subprocess.check_output(['git', 'show', f'{BASELINE}:{p.relative_to(ROOT)}'], cwd=ROOT)
    assert p.read_bytes() == old, p
sources = sorted((ROOT / 'Resources/logo').glob('*.svg'))
assert len(sources) == 3
for p in sources:
    assert '<text' not in p.read_text(), p
    assert '#11110f' not in p.read_text().lower(), p
    assert '#ff8900' in p.read_text().lower() and '#f68103' in p.read_text().lower(), p
    assert '#d87d0b' not in p.read_text().lower(), p
assert not list((ROOT / 'Resources/logo').glob('devtile*.svg'))
print(f'PASS: {exact}/10 pixel-exact entries; 17 PNG dimensions, 10/10 ICNS dimensions/alpha/opaque-pixel round-trips, identical ICNS copies, 6 unchanged toolbar glyphs, 3 font-independent SVGs.')
print('PASS: 27 PNGs (17 exports + 10 round-trips), each with 4 tile samples in the original #ff8900-#f68103 orange, no #11110f pixels or color-profile conversion metadata; 8 small PNGs have 3 separate white marks and snapped strokes/gaps; matching app/extension pixels.')

# Each size gets light and dark rows: old 1:1, new 1:1, old 4x, new 4x.
# Rows use their own compact spacing; the 1024px source determines total width.
paths = app + extension
width = 10 * 1024 + 100
height = sum(2 * (4 * Image.open(p).width + 52) for p in paths)
destination = ROOT / 'Resources/logo/logo-refined-sheet.png'
compressor = zlib.compressobj(6)
with destination.open('wb') as output:
    output.write(b'\x89PNG\r\n\x1a\n')
    def chunk(kind, data):
        output.write(struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data)))
    chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    for p in paths:
        old = Image.open(BytesIO(subprocess.check_output(['git', 'show', f'{BASELINE}:{p.relative_to(ROOT)}'], cwd=ROOT))).convert('RGBA')
        new = Image.open(p).convert('RGBA')
        n = new.width
        for bg, fg, theme in [('#eeeae2', '#11110f', 'light'), ('#11110f', '#eeeae2', 'dark')]:
            strip = Image.new('RGB', (width, 42), bg)
            draw = ImageDraw.Draw(strip)
            draw.text((12, 5), f'{p.relative_to(ROOT)} | {n}px | {theme}', fill=fg)
            x = 12
            columns = []
            for label, icon, scale in [('dev tile 1:1', old, 1), ('Refined 1:1', new, 1), ('dev tile 4x nearest', old, 4), ('Refined 4x nearest', new, 4)]:
                draw.text((x, 22), label, fill=fg)
                composed = Image.new('RGB', icon.size, bg)
                composed.paste(icon, (0, 0), icon)
                columns.append((x, composed, scale))
                x += max(n * scale, 128) + 16
            for y in range(strip.height):
                data = compressor.compress(b'\0' + strip.crop((0, y, width, y + 1)).tobytes())
                if data:
                    chunk(b'IDAT', data)
            crop = Image.new('RGB', (x, 4 * n + 52), bg) if n <= 64 else None
            if crop is not None:
                crop.paste(strip.crop((0, 0, x, 42)), (0, 0))
            # Expand one scanline at a time; even the 1024px comparison stays small.
            for y in range(4 * n + 10):
                row = Image.new('RGB', (width, 1), bg)
                for column_x, icon, scale in columns:
                    if y < n * scale:
                        scanline = icon.crop((0, y // scale, n, y // scale + 1))
                        row.paste(scanline.resize((n * scale, 1), Image.Resampling.NEAREST), (column_x, 0))
                if crop is not None:
                    crop.paste(row.crop((0, 0, x, 1)), (0, y + 42))
                data = compressor.compress(b'\0' + row.tobytes())
                if data:
                    chunk(b'IDAT', data)
            if crop is not None:
                crop.save(WORK / f'{p.stem}-{theme}.png')
            del strip
    chunk(b'IDAT', compressor.flush())
    chunk(b'IEND', b'')
print(f'Contact sheet: {destination.relative_to(ROOT)} ({width} x {height}, streamed one scanline at a time).')
