#!/usr/bin/env python3
"""Run via the host heavy wrapper. Requires rsvg-convert and macOS iconutil."""
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
LOGO = ROOT / 'Resources/logo'


def render(size, destination):
    variant = f'refined-{size}.svg' if size in (16, 32) else 'refined.svg'
    subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size),
                    '-o', str(destination), str(LOGO / variant)], check=True)


for base in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        render(base * scale, ROOT / f'Resources/AppIcon.iconset/icon_{base}x{base}{suffix}.png')
for size in (16, 32, 48, 64, 96, 128, 256):
    render(size, ROOT / f'extension/src/assets/icons/icon-{size}.png')
subprocess.run(['iconutil', '-c', 'icns', str(ROOT / 'Resources/AppIcon.iconset'),
                '-o', str(ROOT / 'Resources/AppIcon.icns')], check=True)
shutil.copyfile(ROOT / 'Resources/AppIcon.icns', ROOT / 'Sources/MediaViewer/Resources/AppIcon.icns')
print('Generated 10 app PNGs, 7 extension PNGs, and both identical ICNS files.')
