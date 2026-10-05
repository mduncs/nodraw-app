#!/bin/bash
#
# NoDraw Headless Test Runner
#
# The default run copies the checked-in fixtures into a disposable archive and
# gives NoDraw a disposable app-support directory (including SQLite). Nothing
# in the user's configured archive or NoDraw database is opened by default.
#
# Usage:
#   ./scripts/run-headless-tests.sh
#   ./scripts/run-headless-tests.sh --no-build
#   ./scripts/run-headless-tests.sh --ci
#   ./scripts/run-headless-tests.sh --use-archive
#
# --use-archive is an explicit real-data diagnostic. It makes a disposable,
# copy-on-write snapshot beside the configured archive, still uses disposable
# SQLite/preferences, and restores its temporary star mutation in the snapshot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_BINARY="$BUILD_DIR/NoDraw"
TEST_FIXTURES_DIR="$PROJECT_DIR/Tests/Fixtures/TestArchive"
BUILD_LOG_FILE="/tmp/nodraw-headless-test.build.log"
PUBLISHED_LOG_FILE="/tmp/nodraw-headless-test.log"
PUBLISHED_RESULTS_DIR="$HOME/Library/Logs/NoDraw"

NO_BUILD=false
CI_MODE=false
USE_FIXTURES=true
TIMEOUT=120

APP_PID=""
SANDBOX_DIR=""
SANDBOX_PARENT=""
SANDBOX_BASENAME_PREFIX=""
RUN_ARCHIVE_DIR=""
RUN_APP_SUPPORT_DIR=""
RUN_RESULTS_DIR=""
RUN_LOG_FILE=""
RESULTS_FILE=""
JUNIT_FILE=""
ARTIFACTS_PUBLISHED=false

# Resolve the opt-in live archive before replacing the child process's path
# environment with the per-run values. The canonical NODRAW key wins.
LIVE_ARCHIVE_PATH="${NODRAW_ARCHIVE_PATH:-${MEDIAVIEWER_ARCHIVE_PATH:-$HOME/MediaArchive}}"

# Colors for human output.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[test-runner]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[test-runner]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[test-runner]${NC} $1"
}

log_error() {
    echo -e "${RED}[test-runner]${NC} $1"
}

show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --no-build     Skip building; use $APP_BINARY"
    echo "  --ci           Write JUnit XML and exit with the test status"
    echo "  --use-archive  Test a disposable snapshot of the configured archive"
    echo "  --timeout N    Timeout in seconds (default: 120)"
    echo "  --help         Show this help message"
    echo ""
    echo "Isolation policy:"
    echo "  Default: copy $TEST_FIXTURES_DIR into a new /tmp sandbox."
    echo "  SQLite, app support, preferences, result staging, and the lock file are"
    echo "  isolated in that same sandbox. Existing NoDraw processes are left alone."
    echo "  NODRAW_ARCHIVE_PATH and MEDIAVIEWER_ARCHIVE_PATH are set to the exact"
    echo "  same disposable archive path. The sandbox is deleted on exit."
    echo ""
    echo "Real-archive snapshot diagnostic:"
    echo "  --use-archive resolves NODRAW_ARCHIVE_PATH first, then"
    echo "  MEDIAVIEWER_ARCHIVE_PATH, then $HOME/MediaArchive. It makes an APFS"
    echo "  copy-on-write snapshot beside that archive; the source is never opened for"
    echo "  writing. SQLite and preferences remain isolated. The star-key test also"
    echo "  restores and flushes its original state inside the disposable snapshot."
    echo ""
    echo "Published artifacts:"
    echo "  $PUBLISHED_RESULTS_DIR/test-results.txt"
    echo "  $PUBLISHED_RESULTS_DIR/test-results.xml (CI mode)"
    echo "  $PUBLISHED_LOG_FILE"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)
            NO_BUILD=true
            shift
            ;;
        --ci)
            CI_MODE=true
            shift
            ;;
        --use-archive)
            USE_FIXTURES=false
            shift
            ;;
        --timeout)
            if [[ $# -lt 2 || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                log_error "--timeout requires a positive integer number of seconds"
                exit 2
            fi
            TIMEOUT="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Run '$0 --help' for usage."
            exit 2
            ;;
    esac
done

check_prerequisites() {
    log "Checking prerequisites..."
    local errors=0

    if ! command -v swift &>/dev/null; then
        log_error "Swift toolchain not found"
        errors=$((errors + 1))
    else
        log_success "Swift toolchain: $(swift --version 2>&1 | head -1)"
    fi

    if ! command -v osascript &>/dev/null; then
        log_error "osascript not found; the GUI smoke requires macOS"
        errors=$((errors + 1))
    fi

    if command -v sw_vers &>/dev/null; then
        log "macOS version: $(sw_vers -productVersion)"
    fi

    if [[ "$USE_FIXTURES" == "true" ]]; then
        if [[ -d "$TEST_FIXTURES_DIR" ]]; then
            local fixture_count
            fixture_count="$(find "$TEST_FIXTURES_DIR" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')"
            if [[ "$fixture_count" -gt 0 ]]; then
                log_success "Fixture source: $fixture_count items in $TEST_FIXTURES_DIR"
            else
                log_warning "Fixture source has no .md files; the app will inject in-memory items"
            fi
        else
            log_warning "Fixture source is absent; the app will inject in-memory items"
        fi
    elif [[ -d "$LIVE_ARCHIVE_PATH" ]]; then
        LIVE_ARCHIVE_PATH="$(cd "$LIVE_ARCHIVE_PATH" && pwd -P)"
        local item_count
        item_count="$(find "$LIVE_ARCHIVE_PATH" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')"
        log_success "Live archive selected explicitly: $item_count items in $LIVE_ARCHIVE_PATH"
    else
        log_error "Live archive not found: $LIVE_ARCHIVE_PATH"
        log "Set NODRAW_ARCHIVE_PATH (preferred) or MEDIAVIEWER_ARCHIVE_PATH."
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        log_error "Prerequisites check failed with $errors error(s)"
        exit 1
    fi
}

check_accessibility() {
    log "Checking Accessibility permissions..."

    if ! osascript -e 'tell application "System Events" to return name of first process' &>/dev/null; then
        log_error "Accessibility permissions are not granted"
        echo ""
        echo "Enable Accessibility for this terminal/script runner in:"
        echo "System Settings > Privacy & Security > Accessibility"
        exit 1
    fi

    log_success "Accessibility permissions OK"
}

build_app() {
    if [[ "$NO_BUILD" == "true" ]]; then
        if [[ ! -x "$APP_BINARY" ]]; then
            log_error "Executable not found at $APP_BINARY"
            log_error "Run without --no-build to build it first"
            exit 1
        fi
        log "Skipping build (--no-build)"
        return
    fi

    log "Building NoDraw in release mode..."
    if (cd "$PROJECT_DIR" && swift build -c release --product NoDraw 2>&1 | tee "$BUILD_LOG_FILE"); then
        log_success "Build successful"
    else
        log_error "Build failed; see $BUILD_LOG_FILE"
        exit 1
    fi
}

is_expected_sandbox_path() {
    if [[ -z "$SANDBOX_DIR" || -z "$SANDBOX_PARENT" || -z "$SANDBOX_BASENAME_PREFIX" ]]; then
        return 1
    fi

    local actual_parent actual_basename
    actual_parent="$(dirname "$SANDBOX_DIR")"
    actual_basename="$(basename "$SANDBOX_DIR")"
    [[ "$actual_parent" == "$SANDBOX_PARENT" &&
       "$actual_basename" == "$SANDBOX_BASENAME_PREFIX"* &&
       "$actual_basename" != "$SANDBOX_BASENAME_PREFIX" ]]
}

prepare_isolated_environment() {
    local sandbox_template
    if [[ "$USE_FIXTURES" == "true" ]]; then
        SANDBOX_PARENT="/tmp"
        SANDBOX_BASENAME_PREFIX="nodraw-headless."
        sandbox_template="$SANDBOX_PARENT/${SANDBOX_BASENAME_PREFIX}XXXXXX"
    else
        # A sibling directory keeps source and snapshot on the same filesystem,
        # which is required for clonefile(2)'s copy-on-write semantics.
        SANDBOX_PARENT="$(dirname "$LIVE_ARCHIVE_PATH")"
        SANDBOX_BASENAME_PREFIX=".nodraw-headless."
        sandbox_template="$SANDBOX_PARENT/${SANDBOX_BASENAME_PREFIX}XXXXXX"
    fi
    SANDBOX_DIR="$(mktemp -d "$sandbox_template")"

    if ! is_expected_sandbox_path; then
        log_error "Refusing unexpected sandbox path: $SANDBOX_DIR"
        exit 1
    fi

    RUN_ARCHIVE_DIR="$SANDBOX_DIR/archive"
    RUN_APP_SUPPORT_DIR="$SANDBOX_DIR/app-support"
    RUN_RESULTS_DIR="$SANDBOX_DIR/results"
    RUN_LOG_FILE="$SANDBOX_DIR/app.log"
    RESULTS_FILE="$RUN_RESULTS_DIR/test-results.txt"
    JUNIT_FILE="$RUN_RESULTS_DIR/test-results.xml"

    mkdir -p \
        "$RUN_ARCHIVE_DIR" \
        "$RUN_APP_SUPPORT_DIR" \
        "$RUN_RESULTS_DIR" \
        "$SANDBOX_DIR/home/Library/Preferences" \
        "$SANDBOX_DIR/tmp"

    if [[ "$USE_FIXTURES" == "true" ]]; then
        if [[ -d "$TEST_FIXTURES_DIR" ]]; then
            cp -R "$TEST_FIXTURES_DIR/." "$RUN_ARCHIVE_DIR/"
        fi
        export NODRAW_ARCHIVE_PATH="$RUN_ARCHIVE_DIR"
        export MEDIAVIEWER_ARCHIVE_PATH="$RUN_ARCHIVE_DIR"
        export MEDIAVIEWER_TEST_ARCHIVE="$RUN_ARCHIVE_DIR"
        export MEDIAVIEWER_TEST_FIXTURES=1
        unset NODRAW_HEADLESS_ALLOW_LIVE_ARCHIVE || true
        log_success "Archive isolation: disposable fixture copy"
    else
        log "Creating copy-on-write archive snapshot..."
        if ! cp -cR "$LIVE_ARCHIVE_PATH/." "$RUN_ARCHIVE_DIR/"; then
            log_error "Could not create a copy-on-write snapshot; refusing to copy or use the source in place"
            exit 1
        fi
        export NODRAW_ARCHIVE_PATH="$RUN_ARCHIVE_DIR"
        export MEDIAVIEWER_ARCHIVE_PATH="$RUN_ARCHIVE_DIR"
        export NODRAW_HEADLESS_ALLOW_LIVE_ARCHIVE=1
        unset MEDIAVIEWER_TEST_ARCHIVE || true
        unset MEDIAVIEWER_TEST_FIXTURES || true
        log_success "Archive isolation: disposable snapshot of $LIVE_ARCHIVE_PATH"
    fi

    export NODRAW_APP_SUPPORT_DIR="$RUN_APP_SUPPORT_DIR"
    export MEDIAVIEWER_APP_SUPPORT_DIR="$RUN_APP_SUPPORT_DIR"
    export NODRAW_HEADLESS_RESULTS_DIR="$RUN_RESULTS_DIR"
    export NODRAW_HEADLESS_DISPOSABLE_ROOT="$SANDBOX_DIR"
    export MEDIAVIEWER_HEADLESS_TESTS=1
    export CFFIXED_USER_HOME="$SANDBOX_DIR/home"
    export TMPDIR="$SANDBOX_DIR/tmp"

    log "Disposable root: $SANDBOX_DIR"
    log "Archive path: $NODRAW_ARCHIVE_PATH"
    log "App support / SQLite: $NODRAW_APP_SUPPORT_DIR"
    log "Staged results: $NODRAW_HEADLESS_RESULTS_DIR"
    log "Single-instance policy: bypassed only for PID-targeted harness process"
}

launch_app() {
    local args=("--headless-tests" "--disable-single-instance")
    if [[ "$CI_MODE" == "true" ]]; then
        args+=("--ci")
    fi
    if [[ "$USE_FIXTURES" == "true" ]]; then
        args+=("--test-fixtures")
    else
        args+=("--headless-live-archive")
    fi

    log "Launching isolated NoDraw harness"
    log "Launch args: ${args[*]}"

    "$APP_BINARY" "${args[@]}" &>"$RUN_LOG_FILE" &
    APP_PID=$!

    log "Harness PID: $APP_PID (existing NoDraw processes were not touched)"
    log "Waiting for tests (timeout: ${TIMEOUT}s)..."
}

wait_for_tests() {
    local elapsed=0

    while [[ $elapsed -lt $TIMEOUT ]]; do
        # String.write(atomically:) publishes the complete result in one rename,
        # so existence means there is no partial-write sleep to guess at.
        if [[ -f "$RESULTS_FILE" ]]; then
            return 0
        fi

        if ! kill -0 "$APP_PID" 2>/dev/null; then
            log_warning "Harness process ended before publishing text results"
            return 1
        fi

        sleep 1
        elapsed=$((elapsed + 1))
        if [[ $((elapsed % 10)) -eq 0 ]]; then
            log "Still waiting... ($elapsed/$TIMEOUT seconds)"
        fi
    done

    log_warning "Timeout reached after ${TIMEOUT}s"
    return 1
}

stop_app() {
    if [[ -z "$APP_PID" ]] || ! kill -0 "$APP_PID" 2>/dev/null; then
        APP_PID=""
        return
    fi

    log "Stopping harness PID $APP_PID"
    kill "$APP_PID" 2>/dev/null || true

    local polls=0
    while kill -0 "$APP_PID" 2>/dev/null && [[ $polls -lt 30 ]]; do
        sleep 0.1
        polls=$((polls + 1))
    done

    if kill -0 "$APP_PID" 2>/dev/null; then
        log_warning "Harness did not terminate promptly; force-stopping PID $APP_PID"
        kill -9 "$APP_PID" 2>/dev/null || true
    fi

    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
}

publish_artifacts() {
    if [[ "$ARTIFACTS_PUBLISHED" == "true" || -z "$SANDBOX_DIR" ]]; then
        return
    fi
    ARTIFACTS_PUBLISHED=true

    mkdir -p "$PUBLISHED_RESULTS_DIR"
    if [[ -f "$RESULTS_FILE" ]]; then
        cp "$RESULTS_FILE" "$PUBLISHED_RESULTS_DIR/test-results.txt"
    fi
    if [[ -f "$JUNIT_FILE" ]]; then
        cp "$JUNIT_FILE" "$PUBLISHED_RESULTS_DIR/test-results.xml"
    fi
    if [[ -f "$RUN_LOG_FILE" ]]; then
        cp "$RUN_LOG_FILE" "$PUBLISHED_LOG_FILE"
    fi
}

show_results() {
    echo ""
    echo "============================================"
    echo "         HEADLESS TEST RESULTS"
    echo "============================================"
    echo ""

    if [[ ! -f "$RESULTS_FILE" ]]; then
        log_error "Results were not published by the app"
        log "Staged app log: $RUN_LOG_FILE"
        if [[ -f "$RUN_LOG_FILE" ]]; then
            echo ""
            echo "Last 50 app-log lines:"
            tail -50 "$RUN_LOG_FILE"
        fi
        return 1
    fi

    cat "$RESULTS_FILE"
    echo ""

    local total passed failed
    total="$(awk '/^Total:/{print $2; exit}' "$RESULTS_FILE")"
    passed="$(awk '/^Passed:/{print $2; exit}' "$RESULTS_FILE")"
    failed="$(awk '/^Failed:/{print $2; exit}' "$RESULTS_FILE")"

    if [[ -z "$total" || -z "$passed" || -z "$failed" ]]; then
        log_error "Could not parse the result summary"
        return 1
    fi
    if [[ "$failed" -gt 0 ]]; then
        log_error "Tests FAILED: $passed/$total passed, $failed failed"
        return 1
    fi

    log_success "All tests PASSED: $passed/$total"
}

cleanup_sandbox() {
    if [[ -z "$SANDBOX_DIR" || ! -d "$SANDBOX_DIR" ]]; then
        return
    fi

    if ! is_expected_sandbox_path; then
        log_error "Refusing to remove unexpected path: $SANDBOX_DIR"
        return
    fi

    log "Removing exact disposable root: $SANDBOX_DIR"
    rm -rf -- "$SANDBOX_DIR"
}

cleanup() {
    local exit_code=$?
    trap - EXIT
    stop_app || true
    publish_artifacts || true
    cleanup_sandbox || true
    exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

main() {
    echo ""
    echo "============================================"
    echo "       NoDraw Headless Test Runner"
    echo "============================================"
    echo ""

    check_prerequisites
    check_accessibility
    build_app
    prepare_isolated_environment
    launch_app

    local wait_succeeded=true
    if ! wait_for_tests; then
        wait_succeeded=false
    fi

    stop_app
    publish_artifacts

    if [[ "$wait_succeeded" != "true" ]]; then
        show_results || true
        return 1
    fi
    show_results
}

main
