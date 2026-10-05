#!/usr/bin/env python3
"""
Build standalone media-archiver binary using PyInstaller.

Usage:
    python build.py          # build for current platform
    python build.py --clean  # clean previous build first

Output: dist/media-archiver (single executable, ~50-80MB)
"""

import subprocess
import sys
import shutil
from pathlib import Path

ROOT = Path(__file__).parent
DIST = ROOT / "dist"
BUILD = ROOT / "build"
SPEC = ROOT / "media-archiver.spec"


def clean():
    """Remove previous build artifacts."""
    for d in [DIST, BUILD]:
        if d.exists():
            shutil.rmtree(d)
            print(f"Removed {d}")
    if SPEC.exists():
        SPEC.unlink()
        print(f"Removed {SPEC}")


def build():
    """Run PyInstaller to create standalone binary."""
    cmd = [
        sys.executable, "-m", "PyInstaller",
        "--onefile",
        "--name", "media-archiver",
        # uvicorn internals not auto-detected
        "--hidden-import", "uvicorn.logging",
        "--hidden-import", "uvicorn.protocols.http",
        "--hidden-import", "uvicorn.protocols.http.auto",
        "--hidden-import", "uvicorn.protocols.http.h11_impl",
        "--hidden-import", "uvicorn.protocols.websockets",
        "--hidden-import", "uvicorn.protocols.websockets.auto",
        "--hidden-import", "uvicorn.lifespan",
        "--hidden-import", "uvicorn.lifespan.on",
        "--hidden-import", "uvicorn.lifespan.off",
        # multipart for file uploads
        "--hidden-import", "multipart",
        # collect full packages that use dynamic imports
        "--collect-all", "yt_dlp",
        "--collect-all", "gallery_dl",
        # local modules
        "--add-data", f"{ROOT / 'downloaders'}:downloaders",
        "--add-data", f"{ROOT / 'storage'}:storage",
        "--add-data", f"{ROOT / 'database'}:database",
        str(ROOT / "main.py"),
    ]

    print("Building media-archiver...")
    print(f"  Command: {' '.join(cmd)}")
    result = subprocess.run(cmd)

    if result.returncode != 0:
        print("Build FAILED", file=sys.stderr)
        sys.exit(1)

    binary = DIST / "media-archiver"
    if binary.exists():
        size_mb = binary.stat().st_size / (1024 * 1024)
        print(f"\nBuild complete: {binary} ({size_mb:.1f} MB)")
    else:
        print("Build completed but binary not found", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    if "--clean" in sys.argv:
        clean()
    build()
