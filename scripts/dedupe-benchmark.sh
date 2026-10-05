#!/bin/bash
# Synthetic fixtures and measurements stay in a fresh worktree-local directory.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
case "${1:-}" in
  ""|--skip-build) ;;
  *) echo "Usage: scripts/dedupe-benchmark.sh [--skip-build]" >&2; exit 2 ;;
esac
# Optional wrappers: `heavy` serializes heavy jobs, a slot script caps parallel Swift builds.
heavy=(); slot=()
[ -n "${NODRAW_HEAVY:-}" ] && [ -x "$NODRAW_HEAVY" ] && heavy=("$NODRAW_HEAVY")
[ -n "${NODRAW_SWIFT_SLOT:-}" ] && [ -x "$NODRAW_SWIFT_SLOT" ] && slot=("$NODRAW_SWIFT_SLOT")
mkdir -p "$repo/.scratch"
export CLANG_MODULE_CACHE_PATH="$repo/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo/.build/swift-module-cache"
output="$(mktemp -d "$repo/.scratch/dedupe-bench.XXXXXX")"
mkdir -p "$output/support" "$output/archive" "$output/tmp"
export TMPDIR="$output/tmp/"
export NODRAW_APP_SUPPORT_DIR="$output/support"
export NODRAW_ARCHIVE_PATH="$output/archive"
export NODRAW_DEDUPE_BENCH_ROOT="$output"
export NODRAW_DEDUPE_BENCH_WORKTREE="$repo"
export NODRAW_DEDUPE_BENCH_REVISION="$(git rev-parse HEAD)"
configuration="${NODRAW_DEDUPE_BENCH_CONFIGURATION:-debug}"
export NODRAW_DEDUPE_BENCH_CONFIGURATION="$configuration"
package="${NODRAW_DEDUPE_PACKAGE_PATH:-$repo}"
echo "Duplicate benchmark output: $output"
build_flags=()
if [ "${NODRAW_DEDUPE_BENCH_LOW_MEMORY_BUILD:-0}" = 1 ]; then
  build_flags=(-Xswiftc -no-whole-module-optimization -Xswiftc -driver-batch-count -Xswiftc 8)
fi
if [ "${1:-}" != --skip-build ]; then
  "${heavy[@]}" "${slot[@]}" swift build --disable-sandbox --build-system native --cache-path "$repo/.build/cache" --package-path "$package" --scratch-path "$repo/.build" -c "$configuration" --build-tests --jobs 1 "${build_flags[@]}" 2>&1 | tee "$output/build.log"
  python3 - "$repo" "$package" "$configuration" <<'PY'
import datetime, hashlib, json, os, pathlib, subprocess, sys
repo, package, configuration = sys.argv[1:]
root = pathlib.Path(repo)
binary = root / '.build' / configuration / 'NoDrawPackageTests.xctest/Contents/MacOS/NoDrawPackageTests'
def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()
info = dict(revision=subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    configuration=configuration, packagePath=package, binaryPath=str(binary), binarySHA256=digest(binary),
    lowMemoryBuild=os.environ.get("NODRAW_DEDUPE_BENCH_LOW_MEMORY_BUILD") == "1",
    dirtyFiles=subprocess.check_output(['git', 'status', '--short'], text=True).strip(),
    builtAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
for key, path in [('detectorSHA256', 'Sources/MediaViewer/Services/DuplicateDetector.swift'),
                  ('evidenceSHA256', 'Sources/MediaViewer/Services/DuplicateEvidence.swift'),
                  ('benchmarkSHA256', 'Tests/MediaViewerTests/DuplicateScanBenchmarkTests.swift'),
                  ('scriptSHA256', 'scripts/dedupe-benchmark.sh')]:
    info[key] = digest(root / path)
(root / '.build/dedupe-benchmark-build.json').write_text(json.dumps(info, indent=2) + '\n')
PY
fi
test -s "$repo/.build/dedupe-benchmark-build.json"
cp "$repo/.build/dedupe-benchmark-build.json" "$output/build.json"
python3 - "$output/build.json" "$configuration" <<'PY'
import hashlib, json, pathlib, sys
info = json.loads(pathlib.Path(sys.argv[1]).read_text())
with pathlib.Path(info['binaryPath']).open('rb') as stream:
    actual = hashlib.file_digest(stream, 'sha256').hexdigest()
if info['configuration'] != sys.argv[2] or info['binarySHA256'] != actual:
    raise SystemExit('Benchmark build receipt does not match the executable/configuration; rerun without --skip-build')
PY
export NODRAW_DEDUPE_BENCH_BUILD_INFO="$output/build.json"
export NODRAW_DEDUPE_BENCH_REVISION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["revision"])' "$output/build.json")"
export NODRAW_DEDUPE_BENCH=1
"${heavy[@]}" swift test --disable-sandbox --build-system native --cache-path "$repo/.build/cache" --package-path "$package" --scratch-path "$repo/.build" -c "$configuration" --skip-build --filter DuplicateScanBenchmarkTests.testDuplicateScanBenchmark 2>&1 | tee "$output/test.log"
test -s "$output/results.json"
echo "JSON: $output/results.json"
