#!/bin/bash
# Hidden-window benchmark: 7,600 synthetic items, eight columns, real JPEG thumbnails,
# wheel/Page Down/End/middle autoscroll at 120/144 Hz. No window is shown or made key.
# All app data, logs, temporary files and results use a fresh worktree scratch directory.
# Build through the shared slot, then test through the shared heavy-command gate.
# Set NODRAW_SWIFT_BUILD_SLOT to the host's swift-slot.sh. Benchmarks also hold it
# so another worker's Swift compilation cannot contaminate frame measurements.
# NODRAW_GRID_BENCH_PACKAGE_PATH supports an isolated package/dependency copy.
# Optional: NODRAW_GRID_BENCH_HZ=144, NODRAW_GRID_BENCH_MODES=wheel.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"
heavy="${NODRAW_HEAVY_RUNNER:-env}"
package="${NODRAW_GRID_BENCH_PACKAGE_PATH:-$repo}"
slot="${NODRAW_SWIFT_BUILD_SLOT:?Set NODRAW_SWIFT_BUILD_SLOT to the shared build gate}"
swift_paths=(--cache-path "$repo/.scratch/swift-cache" --config-path "$repo/.scratch/swift-config" --security-path "$repo/.scratch/swift-security")
mkdir -p "$repo/.scratch"
output="$(mktemp -d "$repo/.scratch/grid-bench.XXXXXX")"
mkdir -p "$output/home" "$output/data" "$output/archive" "$output/tmp"
export CFFIXED_USER_HOME="$output/home"
export NODRAW_APP_SUPPORT_DIR="$output/data"
export NODRAW_ARCHIVE_PATH="$output/archive"
export TMPDIR="$output/tmp"
export NODRAW_GRID_BENCH=1
export NODRAW_GRID_BENCH_OUT="$output/results.json"
export NODRAW_GRID_BENCH_PHASE="$output/phase.txt"
export NODRAW_GRID_BENCH_REVISION="${NODRAW_GRID_BENCH_REVISION:-$(git rev-parse HEAD)}"
echo "Grid benchmark output: $output"
case "${1:-}" in
  "") "$heavy" python3 "$repo/scripts/grid-benchmark-monitor.py" "$slot" swift build --package-path "$package" "${swift_paths[@]}" --build-tests -j 1 ;;
  --skip-build) ;;
  *) echo "Usage: scripts/grid-benchmark.sh [--skip-build]" >&2; exit 2 ;;
esac
# The monitor stops any child above 2.5 GiB physical footprint and samples cold wheel.
"$heavy" python3 "${NODRAW_GRID_BENCH_GUARD:-$repo/scripts/grid-benchmark-monitor.py}" "$slot" swift test --package-path "$package" "${swift_paths[@]}" --skip-build --filter GridScrollBenchmarkTests.testGridScrollBenchmark 2>&1 | tee "$output/test.log"
test -s "$NODRAW_GRID_BENCH_OUT"
echo "JSON: $NODRAW_GRID_BENCH_OUT"
