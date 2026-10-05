#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .scratch
run=$(mktemp -d "$PWD/.scratch/memory-XXXXXXXX")
mkdir -p "$run/home" "$run/support" "$run/archive" "$run/tmp" "$run/evidence"
export CFFIXED_USER_HOME="$run/home" NODRAW_APP_SUPPORT_DIR="$run/support"
export NODRAW_ARCHIVE_PATH="$run/archive" TMPDIR="$run/tmp"
export NODRAW_MEMORY_BENCHMARK=1 NODRAW_MEMORY_OUTPUT="$run/evidence"
export NODRAW_MEMORY_FIXTURE_ROOT="$run/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.scratch/clang-cache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.scratch/swift-cache"
heavy="${NODRAW_HEAVY_RUNNER:-env}"
slot="${NODRAW_SWIFT_BUILD_SLOT:?Set NODRAW_SWIFT_BUILD_SLOT to the shared build gate}"
echo "Evidence: $run"
if [ -n "${NODRAW_MEMORY_ASR_FIXTURE:-}" ]; then
    models="$run/home/Library/Application Support/FluidAudio/Models"
    export NODRAW_MEMORY_ASR_CACHE="$models/parakeet-tdt-0.6b-v3-coreml"
    mkdir -p "$models"
    "$heavy" cp -cR "$NODRAW_MEMORY_ASR_FIXTURE" "$models/parakeet-tdt-0.6b-v3-coreml"
fi
if [ "${1:-}" != "--skip-build" ]; then
    "$heavy" "$slot" python3 scripts/guard-memory.py /usr/bin/time -l swift build --build-tests --jobs 1 --disable-index-store > "$run/build.log" 2>&1
fi
filter=${NODRAW_MEMORY_TEST_FILTER:-IdleMemoryBenchmarkTests/testSyntheticLibraryIdleMemory}
"$heavy" python3 scripts/guard-memory.py /usr/bin/time -l swift test --skip-build --filter "$filter" > "$run/test.log" 2>&1
if [ -f "$run/evidence/results.json" ]; then cat "$run/evidence/results.json"; fi
