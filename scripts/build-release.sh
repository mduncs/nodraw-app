#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT_DIR/.build/release/NoDraw"
RESOURCE_BUNDLE="$ROOT_DIR/.build/release/NoDraw_MediaViewer.bundle"
BUILD_INFO_SCRIPT="$ROOT_DIR/scripts/generate-build-info.sh"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
APP_ICON="$ROOT_DIR/Sources/MediaViewer/Resources/AppIcon.icns"
APP_ICON_FALLBACK="$ROOT_DIR/Resources/AppIcon.icns"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/NoDraw.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "0.1")"
ZIP_PATH="$DIST_DIR/NoDraw-$VERSION-macOS.zip"

if [[ -x "$BUILD_INFO_SCRIPT" ]]; then
  "$BUILD_INFO_SCRIPT"
fi

echo "[build-release] Building NoDraw (release)..."
cd "$ROOT_DIR"
# Map the checkout path to "." so #file strings, debug info and object paths in the
# binary don't carry the absolute path of whoever built it.
swift build -c release --product NoDraw -Xswiftc -DBUILD_INFO_GENERATED \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=." \
  -Xcc "-ffile-prefix-map=$ROOT_DIR=." \
  -Xlinker -oso_prefix -Xlinker "$ROOT_DIR"

if [[ ! -f "$BINARY" ]]; then
  echo "[build-release] Build succeeded but binary not found at $BINARY" >&2
  exit 1
fi

echo "[build-release] Packaging NoDraw.app..."
rm -rf "$APP_BUNDLE" "$ZIP_PATH"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"

cp "$BINARY" "$APP_MACOS/NoDraw"
chmod +x "$APP_MACOS/NoDraw"
# SwiftPM release binaries retain a large local-symbol table by default. It is
# not needed at runtime and adds substantial cold-I/O/package weight. Keep
# externally visible symbols intact while removing only local symbols before
# signing the bundle.
/usr/bin/strip -x "$APP_MACOS/NoDraw"
# The linker records toolchain library folders from the build machine as rpaths.
# The app loads nothing through @rpath, so drop every absolute one except the OS
# Swift runtime folder; they only leak the builder's paths.
otool -l "$APP_MACOS/NoDraw" | awk '/LC_RPATH/ { getline; getline; print $2 }' \
  | { grep -v -e '^/usr/lib/swift$' -e '^@' || true; } \
  | while IFS= read -r rpath; do
      install_name_tool -delete_rpath "$rpath" "$APP_MACOS/NoDraw"
    done
cp "$INFO_PLIST" "$APP_CONTENTS/Info.plist"
if [[ -f "$APP_ICON" ]]; then
  cp "$APP_ICON" "$APP_RESOURCES/AppIcon.icns"
elif [[ -f "$APP_ICON_FALLBACK" ]]; then
  cp "$APP_ICON_FALLBACK" "$APP_RESOURCES/AppIcon.icns"
else
  echo "[build-release] AppIcon.icns not found in Sources/MediaViewer/Resources or Resources" >&2
  exit 1
fi

if [[ -d "$RESOURCE_BUNDLE" ]]; then
  rm -rf "$APP_RESOURCES/$(basename "$RESOURCE_BUNDLE")"
  cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/"
else
  echo "[build-release] SwiftPM resource bundle not found at $RESOURCE_BUNDLE; app resources may be incomplete." >&2
fi

if [[ -x "$ROOT_DIR/server/dist/media-archiver" ]]; then
  cp "$ROOT_DIR/server/dist/media-archiver" "$APP_RESOURCES/media-archiver"
  chmod +x "$APP_RESOURCES/media-archiver"
elif [[ -x "$DIST_DIR/media-archiver" ]]; then
  cp "$DIST_DIR/media-archiver" "$APP_RESOURCES/media-archiver"
  chmod +x "$APP_RESOURCES/media-archiver"
else
  echo "[build-release] media-archiver server binary not bundled; first-run setup can install it."
fi

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP_BUNDLE" 2>/dev/null || true
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "[build-release] Signing app bundle with $CODESIGN_IDENTITY..."
  codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
else
  echo "[build-release] Ad-hoc signing app bundle; set CODESIGN_IDENTITY for Developer ID release builds."
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "[build-release] Creating $ZIP_PATH..."
(
  cd "$DIST_DIR"
  COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "NoDraw.app" "$ZIP_PATH"
)

echo "[build-release] Packaging browser extension..."
EXTENSION_XPI="$("$ROOT_DIR/scripts/build-extensions.sh" firefox | tail -1)"

echo "[build-release] Done:"
echo "  App: $APP_BUNDLE"
echo "  Zip: $ZIP_PATH"
echo "  XPI: $EXTENSION_XPI"
