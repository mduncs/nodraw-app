#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTENSION_DIR="$ROOT_DIR/extension"
SRC_DIR="$EXTENSION_DIR/src"
MANIFEST_DIR="$EXTENSION_DIR/manifests"
DIST_DIR="$ROOT_DIR/dist"
TARGET="${1:-all}"

case "$TARGET" in
  all|firefox|chrome) ;;
  *)
    echo "usage: $0 [all|firefox|chrome]" >&2
    exit 2
    ;;
esac

extension_version() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["version"])
PY
}

stage_extension() {
  local browser_name="$1"
  local manifest_path="$2"
  local output_dir="$DIST_DIR/extension-$browser_name"

  rm -rf "$output_dir"
  mkdir -p "$output_dir"

  node "$EXTENSION_DIR/build.mjs" "$output_dir" "$browser_name"
  cp "$SRC_DIR/pages/"*.html "$output_dir/"
  rsync -a "$SRC_DIR/assets/icons/" "$output_dir/icons/"

  cp "$manifest_path" "$output_dir/manifest.json"

  printf '%s\n' "$output_dir"
}

package_extension() {
  local browser_name="$1"
  local output_dir="$2"
  local version="$3"
  local artifact_path

  if [[ "$browser_name" == "firefox" ]]; then
    artifact_path="$DIST_DIR/nodraw-$version.xpi"
  else
    artifact_path="$DIST_DIR/nodraw-$version-chrome.zip"
  fi

  rm -f "$artifact_path"
  find "$output_dir" -exec touch -t 198001010000 {} +
  (
    cd "$output_dir"
    find . -type f -print | LC_ALL=C sort | zip -X -q "$artifact_path" -@
  )

  printf '%s\n' "$artifact_path"
}

build_firefox() {
  local output_dir
  local version

  output_dir="$(stage_extension firefox "$MANIFEST_DIR/firefox.json")"
  version="$(extension_version "$MANIFEST_DIR/firefox.json")"
  package_extension firefox "$output_dir" "$version"
}

build_chrome() {
  local output_dir
  local version

  output_dir="$(stage_extension chrome "$MANIFEST_DIR/chrome.json")"
  version="$(extension_version "$MANIFEST_DIR/chrome.json")"
  package_extension chrome "$output_dir" "$version"
}

mkdir -p "$DIST_DIR"

if [[ "$TARGET" == "all" || "$TARGET" == "firefox" ]]; then
  build_firefox
fi

if [[ "$TARGET" == "all" || "$TARGET" == "chrome" ]]; then
  build_chrome
fi
