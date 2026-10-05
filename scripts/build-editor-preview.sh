#!/usr/bin/env bash
# Release-build and package the editor preview. Does not install, launch, or build browser extensions.
set -euo pipefail

PREVIEW_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREVIEW_DIST="$PREVIEW_ROOT/dist"
PREVIEW_APP="$PREVIEW_DIST/NoDraw Editor Preview.app"
PREVIEW_ZIP="$PREVIEW_DIST/NoDraw-Editor-Preview-macOS.zip"
PREVIEW_JOBS="${NODRAW_PREVIEW_BUILD_JOBS:-4}"
PREVIEW_BUNDLE_ID="com.nodraw.editor-preview"
PREVIEW_PACKAGE_ONLY=false
PREVIEW_KEEP_BUILD_INFO=false
if [[ "${1:-}" == "--package-only" && $# == 1 ]]; then
  PREVIEW_PACKAGE_ONLY=true
elif [[ "${1:-}" == "--keep-build-info" && $# == 1 ]]; then
  PREVIEW_KEEP_BUILD_INFO=true
elif [[ $# != 0 ]]; then
  echo "Usage: $0 [--package-only | --keep-build-info]" >&2
  exit 64
fi

cd "$PREVIEW_ROOT"
python3 - "$PREVIEW_ROOT" <<'PY'
from pathlib import Path
import re, sys
root=Path(sys.argv[1])
flags=(root/'Sources/MediaViewer/Services/FeatureFlags.swift').read_text()
assert re.search(r'static\s+let\s+annotate\s*=\s*true\b', flags), 'Editor feature must be enabled in release source'
qa=(root/'Sources/MediaViewer/Services/BackgroundQAConfiguration.swift').read_text()
assert '--editor-preview' in qa, 'Supported --editor-preview runtime mode is required before packaging'
assert (root/'Resources/DemoArchive/03-mint-square.jpg').is_file(), 'Bundled sample media is missing'
PY

if [[ "$PREVIEW_PACKAGE_ONLY" == true ]]; then
  python3 - "$PREVIEW_ROOT" "$PREVIEW_APP" <<'PY'
from pathlib import Path
import hashlib, json, sys
root,app=map(Path,sys.argv[1:3])
info=json.loads((app/'Contents/Resources/EditorPreviewBuild.json').read_text())
source_hash=hashlib.sha256()
for path in sorted((root/'Sources').rglob('*.swift')):
    source_hash.update(str(path.relative_to(root)).encode()+b'\0'+path.read_bytes()+b'\0')
assert source_hash.hexdigest() == info['swiftSourcesSHA256'], 'Swift sources changed; a full release rebuild is required'
PY
  echo "[editor-preview] Repackaging verified unchanged release sources..."
else
  if [[ "$PREVIEW_KEEP_BUILD_INFO" == true ]]; then
    [[ -f "$PREVIEW_ROOT/Sources/MediaViewer/Services/BuildInfo.generated.swift" ]] || {
      echo "--keep-build-info requires existing BuildInfo.generated.swift" >&2
      exit 1
    }
  else
    "$PREVIEW_ROOT/scripts/generate-build-info.sh"
  fi
  echo "[editor-preview] Building native release executable ($PREVIEW_JOBS jobs)..."
  swift build -c release --product NoDraw --jobs "$PREVIEW_JOBS" -Xswiftc -DBUILD_INFO_GENERATED
fi
PREVIEW_BIN_DIR="$(swift build -c release --show-bin-path)"
[[ -x "$PREVIEW_BIN_DIR/NoDraw" ]] || { echo "Missing release executable" >&2; exit 1; }
[[ -d "$PREVIEW_BIN_DIR/NoDraw_MediaViewer.bundle" ]] || { echo "Missing SwiftPM app resources" >&2; exit 1; }

mkdir -p "$PREVIEW_DIST"
PREVIEW_STAGE="$(mktemp -d "$PREVIEW_DIST/.editor-preview-stage.XXXXXX")"
trap 'rm -rf "$PREVIEW_STAGE"' EXIT
PREVIEW_STAGED_APP="$PREVIEW_STAGE/NoDraw Editor Preview.app"
PREVIEW_CONTENTS="$PREVIEW_STAGED_APP/Contents"
mkdir -p "$PREVIEW_CONTENTS/MacOS" "$PREVIEW_CONTENTS/Resources"
cp "$PREVIEW_BIN_DIR/NoDraw" "$PREVIEW_CONTENTS/MacOS/NoDraw"
/usr/bin/strip -x "$PREVIEW_CONTENTS/MacOS/NoDraw"
if [[ "$PREVIEW_PACKAGE_ONLY" == true ]]; then
  python3 - "$PREVIEW_APP" "$PREVIEW_CONTENTS/MacOS/NoDraw" <<'PY'
from pathlib import Path
import hashlib, json, sys
app,binary=map(Path,sys.argv[1:3])
info=json.loads((app/'Contents/Resources/EditorPreviewBuild.json').read_text())
assert hashlib.sha256(binary.read_bytes()).hexdigest() == info['unsignedExecutableSHA256'], 'Release binary changed; a full release rebuild is required'
PY
fi
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -framework Foundation -mmacosx-version-min=14.0 \
  "$PREVIEW_ROOT/scripts/packaging/EditorPreviewLauncher.m" -o "$PREVIEW_CONTENTS/MacOS/NoDrawEditorPreview"
chmod +x "$PREVIEW_CONTENTS/MacOS/NoDraw" "$PREVIEW_CONTENTS/MacOS/NoDrawEditorPreview"
cp "$PREVIEW_ROOT/Resources/Info.plist" "$PREVIEW_CONTENTS/Info.plist"
cp "$PREVIEW_ROOT/Sources/MediaViewer/Resources/AppIcon.icns" "$PREVIEW_CONTENTS/Resources/AppIcon.icns"
cp "$PREVIEW_ROOT/scripts/packaging/editor-preview-README.md" "$PREVIEW_CONTENTS/Resources/README.md"
/usr/bin/ditto "$PREVIEW_ROOT/Resources/DemoArchive" "$PREVIEW_CONTENTS/Resources/DemoArchive"
# The archive scanner treats every .md as an item sidecar; keep usage docs outside the sample vault.
rm -f "$PREVIEW_CONTENTS/Resources/DemoArchive/README.md"
for PREVIEW_RESOURCE in "$PREVIEW_BIN_DIR"/*.bundle; do
  [[ -d "$PREVIEW_RESOURCE" ]] || continue
  /usr/bin/ditto "$PREVIEW_RESOURCE" "$PREVIEW_CONTENTS/Resources/$(basename "$PREVIEW_RESOURCE")"
done

python3 - "$PREVIEW_ROOT" "$PREVIEW_CONTENTS" "$PREVIEW_BUNDLE_ID" <<'PY'
from pathlib import Path
import hashlib, json, plistlib, platform, re, subprocess, sys
root, contents=map(Path,sys.argv[1:3]); bundle_id=sys.argv[3]
plist_path=contents/'Info.plist'
plist=plistlib.loads(plist_path.read_bytes())
plist.update(CFBundleIdentifier=bundle_id, CFBundleName='NoDraw Editor Preview',
             CFBundleDisplayName='NoDraw Editor Preview', CFBundleExecutable='NoDrawEditorPreview')
plist_path.write_bytes(plistlib.dumps(plist))
flags_path=root/'Sources/MediaViewer/Services/FeatureFlags.swift'
flags={key: value == 'true' for key,value in re.findall(r'static\s+let\s+(\w+)\s*=\s*(true|false)', flags_path.read_text())}
assert flags['annotate'] is True
source_hash=hashlib.sha256()
for path in sorted((root/'Sources').rglob('*.swift')):
    source_hash.update(str(path.relative_to(root)).encode()+b'\0'+path.read_bytes()+b'\0')
binary=contents/'MacOS/NoDraw'
build_info=(root/'Sources/MediaViewer/Services/BuildInfo.generated.swift').read_text()
info={
    'name':'NoDraw Editor Preview', 'bundleIdentifier':bundle_id, 'configuration':'release',
    'architecture':platform.machine(), 'version':plist['CFBundleShortVersionString'],
    'gitRevision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
    'workingTreeDirty':bool(subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip()),
    'buildDate':re.search(r'buildDate = "([^"]+)"',build_info).group(1),
    'featureFlags':flags, 'featureFlagsSourceSHA256':hashlib.sha256(flags_path.read_bytes()).hexdigest(),
    'swiftSourcesSHA256':source_hash.hexdigest(),
    'unsignedExecutableSHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),
    'launcherSourceSHA256':hashlib.sha256((root/'scripts/packaging/EditorPreviewLauncher.m').read_bytes()).hexdigest(),
    'runtimeMode':'--editor-preview', 'dataFolder':'~/Library/Application Support/NoDraw Editor Preview',
    'dataFolderOverrideEnvironment':'NODRAW_EDITOR_PREVIEW_DATA_DIR',
    'sampleArchive':'Resources/DemoArchive', 'sampleProvenance':'Existing procedural repository demo; no external media or live data copied'
}
(contents/'Resources/EditorPreviewBuild.json').write_text(json.dumps(info,indent=2)+'\n')
PY

# A local-only preview identity, independent of the installed NoDraw bundle and defaults domain.
xattr -cr "$PREVIEW_STAGED_APP" 2>/dev/null || true
codesign --force --deep --sign - "$PREVIEW_STAGED_APP"
codesign --verify --deep --strict "$PREVIEW_STAGED_APP"
plutil -lint "$PREVIEW_CONTENTS/Info.plist"

# Preview data lives in its isolated Application Support directory; only replace generated artifacts.
rm -rf "$PREVIEW_APP"
mv "$PREVIEW_STAGED_APP" "$PREVIEW_APP"
cp "$PREVIEW_ROOT/scripts/packaging/editor-preview-README.md" "$PREVIEW_DIST/Editor Preview — Read Me.md"
rm -f "$PREVIEW_ZIP"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --keepParent "$PREVIEW_APP" "$PREVIEW_ZIP"

python3 - "$PREVIEW_APP" "$PREVIEW_ZIP" <<'PY'
from pathlib import Path
import hashlib, json, sys
app,zip_path=map(Path,sys.argv[1:3])
binary=app/'Contents/MacOS/NoDraw'
launcher=app/'Contents/MacOS/NoDrawEditorPreview'
identity={
  'app':str(app), 'zip':str(zip_path),
  'executableSHA256':hashlib.sha256(binary.read_bytes()).hexdigest(), 'executableBytes':binary.stat().st_size,
  'launcherSHA256':hashlib.sha256(launcher.read_bytes()).hexdigest(), 'launcherBytes':launcher.stat().st_size,
  'zipSHA256':hashlib.sha256(zip_path.read_bytes()).hexdigest(), 'zipBytes':zip_path.stat().st_size,
  'bundleBytes':sum(p.stat().st_size for p in app.rglob('*') if p.is_file())
}
(app.parent/'EditorPreviewArtifact.json').write_text(json.dumps(identity,indent=2)+'\n')
print(json.dumps(identity,indent=2))
PY
echo "[editor-preview] Ready; no app was launched or installed."
