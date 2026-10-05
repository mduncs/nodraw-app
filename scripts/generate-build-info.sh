#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="$ROOT_DIR/Sources/MediaViewer/Services/BuildInfo.generated.swift"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || echo "0.1")"
GIT_HASH="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
if [[ "$GIT_HASH" != "unknown" ]] && [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
    GIT_HASH="${GIT_HASH}-dirty"
fi
BUILD_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "$OUT_FILE" <<EOF
import Foundation

enum BuildInfoGenerated {
    static let version = "$VERSION"
    static let gitHash = "$GIT_HASH"
    static let buildDate = "$BUILD_DATE"
}
EOF

echo "[generate-build-info] Wrote $OUT_FILE"
