#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_FILE="$ROOT_DIR/dist/appcast.xml"
APPCAST_TITLE="${APPCAST_TITLE:-NoDraw Updates}"
APPCAST_DESCRIPTION="${APPCAST_DESCRIPTION:-NoDraw update feed}"
APPCAST_PUBDATE="${APPCAST_PUBDATE:-$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")}"
APPCAST_DOWNLOAD_URL="${APPCAST_DOWNLOAD_URL:-}"
APPCAST_VERSION="${APPCAST_VERSION:-}"
APPCAST_SHORT_VERSION="${APPCAST_SHORT_VERSION:-}"
APPCAST_EDDSA_SIGNATURE="${APPCAST_EDDSA_SIGNATURE:-}"
APPCAST_LENGTH="${APPCAST_LENGTH:-0}"

mkdir -p "$(dirname "$OUT_FILE")"

missing=()
[[ -n "$APPCAST_DOWNLOAD_URL" ]] || missing+=("APPCAST_DOWNLOAD_URL")
[[ -n "$APPCAST_VERSION" ]] || missing+=("APPCAST_VERSION")
[[ -n "$APPCAST_SHORT_VERSION" ]] || missing+=("APPCAST_SHORT_VERSION")
[[ -n "$APPCAST_EDDSA_SIGNATURE" ]] || missing+=("APPCAST_EDDSA_SIGNATURE")

if (( ${#missing[@]} > 0 )); then
  echo "[generate-appcast] Missing required environment variables: ${missing[*]}" >&2
  echo "[generate-appcast] Refusing to write a placeholder Sparkle feed." >&2
  exit 1
fi

cat > "$OUT_FILE" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>__APPCAST_TITLE__</title>
    <description>__APPCAST_DESCRIPTION__</description>
    <language>en</language>
    <item>
      <title>NoDraw __APPCAST_SHORT_VERSION__</title>
      <pubDate>__APPCAST_PUBDATE__</pubDate>
      <enclosure
        url="__APPCAST_DOWNLOAD_URL__"
        sparkle:version="__APPCAST_VERSION__"
        sparkle:shortVersionString="__APPCAST_SHORT_VERSION__"
        sparkle:edSignature="__APPCAST_EDDSA_SIGNATURE__"
        length="__APPCAST_LENGTH__"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF

python3 - "$OUT_FILE" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
content = path.read_text()
replacements = {
    "__APPCAST_TITLE__": os.environ["APPCAST_TITLE"],
    "__APPCAST_DESCRIPTION__": os.environ["APPCAST_DESCRIPTION"],
    "__APPCAST_PUBDATE__": os.environ["APPCAST_PUBDATE"],
    "__APPCAST_DOWNLOAD_URL__": os.environ["APPCAST_DOWNLOAD_URL"],
    "__APPCAST_VERSION__": os.environ["APPCAST_VERSION"],
    "__APPCAST_SHORT_VERSION__": os.environ["APPCAST_SHORT_VERSION"],
    "__APPCAST_EDDSA_SIGNATURE__": os.environ["APPCAST_EDDSA_SIGNATURE"],
    "__APPCAST_LENGTH__": os.environ["APPCAST_LENGTH"],
}
for needle, value in replacements.items():
    content = content.replace(needle, value)
path.write_text(content)
PY

echo "[generate-appcast] Wrote signed appcast template to $OUT_FILE"
