#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
SERVER_PYTHON="${NODRAW_SERVER_PYTHON:-$ROOT_DIR/server/.venv/bin/python}"
WEB_EXT_BIN="${NODRAW_WEB_EXT_BIN:-$(command -v web-ext || true)}"
CHROME_BIN="${NODRAW_CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [[ -n "${NODRAW_FIREFOX_BIN:-}" ]]; then
  FIREFOX_BIN="$NODRAW_FIREFOX_BIN"
elif [[ -x "/Applications/Firefox Developer Edition.app/Contents/MacOS/firefox" ]]; then
  FIREFOX_BIN="/Applications/Firefox Developer Edition.app/Contents/MacOS/firefox"
else
  FIREFOX_BIN="/Applications/Firefox.app/Contents/MacOS/firefox"
fi
DISCOVERY_PORT=8800
# Browsers the user has open also discover :8800 and heartbeat into the isolated server;
# only a heartbeat carrying this run's user-agent mark proves the staged package.
SMOKE_MARK="NoDrawSmoke/$$"
DONE_FILE="${NODRAW_SMOKE_DONE_FILE:-$DIST_DIR/extension-smoke.status}"
KEEP_WORKDIR="${NODRAW_SMOKE_KEEP_WORKDIR:-0}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nodraw-extension-smoke.XXXXXX")"
WORKERS_FILE="$WORK_DIR/workers.tsv"
SERVER_LOG="$WORK_DIR/server.log"
DISCOVERY_LOG="$WORK_DIR/discovery.log"
CHROME_LOG="$WORK_DIR/chrome.log"
FIREFOX_LOG="$WORK_DIR/firefox.log"
WORKER_PIDS=()
WORKER_LABELS=()
RESULT="FAIL"

mkdir -p "$DIST_DIR" "$(dirname "$DONE_FILE")"
: > "$WORKERS_FILE"
printf 'RUNNING workdir=%s\n' "$WORK_DIR" > "$DONE_FILE"

tick() {
  printf '[extension-smoke] %s\n' "$*"
}

register_worker() {
  local label="$1"
  local pid="$2"
  local command="$3"
  WORKER_LABELS+=("$label")
  WORKER_PIDS+=("$pid")
  printf '%s\t%s\t%s\n' "$label" "$pid" "$command" >> "$WORKERS_FILE"
  tick "worker $label pid=$pid; stop with: kill $pid"
}

stop_worker() {
  local pid="$1"
  local child
  if ! kill -0 "$pid" 2>/dev/null; then
    return
  fi
  while read -r child; do
    [[ -n "$child" ]] && kill "$child" 2>/dev/null || true
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  local exit_code=$?
  local index
  for ((index=${#WORKER_PIDS[@]}-1; index>=0; index--)); do
    stop_worker "${WORKER_PIDS[$index]}"
  done
  if [[ "$RESULT" == "PASS" ]]; then
    if [[ "$KEEP_WORKDIR" == "1" ]]; then
      printf 'PASS chrome=heartbeat firefox=heartbeat contract=selection+patch workdir=%s\n' "$WORK_DIR" > "$DONE_FILE"
    else
      printf 'PASS chrome=heartbeat firefox=heartbeat contract=selection+patch\n' > "$DONE_FILE"
    fi
  else
    printf 'FAIL exit=%s workdir=%s\n' "$exit_code" "$WORK_DIR" > "$DONE_FILE"
  fi
  tick "status: $(cat "$DONE_FILE")"
  if [[ "$KEEP_WORKDIR" != "1" && "$RESULT" == "PASS" ]]; then
    case "$WORK_DIR" in
      "${TMPDIR:-/tmp}"/nodraw-extension-smoke.*)
        find "$WORK_DIR" -depth -delete
        ;;
      *)
        tick "refusing to delete unexpected workdir: $WORK_DIR"
        ;;
    esac
  else
    tick "logs retained at $WORK_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

require_file() {
  [[ -f "$1" ]] || { tick "missing required file: $1"; exit 1; }
}

port_is_free() {
  ! lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | grep -q .
}

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

wait_for_health() {
  local url="$1"
  local attempts="${2:-80}"
  local index
  for ((index=0; index<attempts; index++)); do
    if curl -fsS "$url/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_for_browser_heartbeat() {
  local url="$1"
  local expected="$2"
  local evidence_path="$3"
  local body
  local observed
  local index
  for ((index=0; index<100; index++)); do
    body="$(curl -fsS "$url/health" 2>/dev/null || true)"
    if [[ -n "$body" ]]; then
      observed="$(python3 -c 'import json,sys; e = json.load(sys.stdin).get("extension", {}); print(e.get("browser") or "", sys.argv[1] in (e.get("last_user_agent") or ""))' "$SMOKE_MARK" <<< "$body" 2>/dev/null || true)"
      if [[ "$observed" == "$expected True" ]]; then
        printf '%s\n' "$body" > "$evidence_path"
        return 0
      fi
    fi
    sleep 0.25
  done
  return 1
}

require_file "$SERVER_PYTHON"
require_file "$CHROME_BIN"
require_file "$FIREFOX_BIN"
[[ -n "$WEB_EXT_BIN" ]] || { tick 'web-ext is not installed'; exit 1; }
port_is_free "$DISCOVERY_PORT" || {
  tick "port $DISCOVERY_PORT is in use; refusing to disturb the existing process"
  exit 1
}

tick 'building deterministic Firefox and Chrome packages'
"$ROOT_DIR/scripts/build-extensions.sh"

SERVER_PORT="$(free_port)"
SERVER_URL="http://127.0.0.1:$SERVER_PORT"

tick "starting isolated archive server on $SERVER_PORT"
(
  cd "$ROOT_DIR/server"
  exec env \
    MEDIA_ARCHIVER_DIR="$WORK_DIR/archive" \
    MEDIA_ARCHIVER_PORT="$SERVER_PORT" \
    MEDIA_ARCHIVER_PORT_DIR="$WORK_DIR/ports" \
    PYTHONUNBUFFERED=1 \
    "$SERVER_PYTHON" main.py
) > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
register_worker server "$SERVER_PID" "$SERVER_PYTHON server/main.py"

tick 'starting isolated extension discovery bridge on 8800'
python3 -c '
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json, sys
target_port = int(sys.argv[1])
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/discover/"):
            body = json.dumps({"port": target_port}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)
    def log_message(self, format, *args):
        return
ThreadingHTTPServer(("127.0.0.1", 8800), Handler).serve_forever()
' "$SERVER_PORT" > "$DISCOVERY_LOG" 2>&1 &
DISCOVERY_PID=$!
register_worker discovery "$DISCOVERY_PID" "python discovery bridge :8800 -> :$SERVER_PORT"

wait_for_health "$SERVER_URL" || {
  tick "server did not become healthy; see $SERVER_LOG"
  exit 1
}

tick 'launching staged Chrome extension headlessly with a fresh profile'
"$WEB_EXT_BIN" run \
  --target chromium \
  --source-dir "$DIST_DIR/extension-chrome" \
  --artifacts-dir "$WORK_DIR/chrome-artifacts" \
  --chromium-binary "$CHROME_BIN" \
  --chromium-profile "$WORK_DIR/chrome-profile" \
  --profile-create-if-missing \
  --no-reload \
  --no-input \
  --start-url about:blank \
  --args=--headless=new \
  "--args=--user-agent=Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36 $SMOKE_MARK" \
  > "$CHROME_LOG" 2>&1 &
CHROME_RUNNER_PID=$!
register_worker chrome "$CHROME_RUNNER_PID" "web-ext run --target chromium --headless=new"

wait_for_browser_heartbeat "$SERVER_URL" chrome "$WORK_DIR/chrome-health.json" || {
  tick "Chrome extension did not heartbeat; see $CHROME_LOG"
  exit 1
}
tick 'Chrome package reached the isolated server'
stop_worker "$CHROME_RUNNER_PID"

tick 'launching staged Firefox extension headlessly with a fresh profile'
"$WEB_EXT_BIN" run \
  --target firefox-desktop \
  --source-dir "$DIST_DIR/extension-firefox" \
  --artifacts-dir "$WORK_DIR/firefox-artifacts" \
  --firefox "$FIREFOX_BIN" \
  --firefox-profile "$WORK_DIR/firefox-profile" \
  --profile-create-if-missing \
  --keep-profile-changes \
  --no-reload \
  --no-input \
  --start-url about:blank \
  --pref "general.useragent.override=Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:150.0) Gecko/20100101 Firefox/150.0 $SMOKE_MARK" \
  --args=--headless > "$FIREFOX_LOG" 2>&1 &
FIREFOX_RUNNER_PID=$!
register_worker firefox "$FIREFOX_RUNNER_PID" "web-ext run --target firefox-desktop --headless"

wait_for_browser_heartbeat "$SERVER_URL" firefox "$WORK_DIR/firefox-health.json" || {
  tick "Firefox extension did not heartbeat; see $FIREFOX_LOG"
  exit 1
}
tick 'Firefox package reached the same isolated server'

CAPTURE_ID="smoke-$(date +%s)-$$"
CAPTURE_BODY="$WORK_DIR/capture.json"
printf '%s\n' \
  "{\"intent\":{\"schemaVersion\":1,\"captureId\":\"$CAPTURE_ID\",\"fingerprint\":\"v1-$CAPTURE_ID\",\"kind\":\"selection\",\"targetUrl\":\"https://example.invalid/smoke\",\"sourcePageUrl\":\"https://example.invalid/smoke\",\"createdAt\":\"2026-07-19T00:00:00Z\",\"page\":{\"title\":\"Extension smoke\",\"canonicalUrl\":\"\",\"author\":\"\",\"description\":\"\",\"publishedAt\":\"\",\"siteName\":\"\",\"language\":\"en\",\"image\":\"\",\"schemaTypes\":[]},\"media\":null,\"selection\":{\"text\":\"NoDraw two-browser smoke\",\"html\":\"<p>NoDraw two-browser smoke</p>\"},\"user\":{\"tags\":[],\"note\":\"\"},\"options\":{\"saveMode\":\"text\",\"screenshot\":\"\",\"platform\":\"smoke\"}},\"cookies\":[]}" \
  > "$CAPTURE_BODY"

tick 'submitting a live versioned selection capture to the shared server'
curl -fsS \
  -H 'Content-Type: application/json' \
  --data-binary "@$CAPTURE_BODY" \
  "$SERVER_URL/captures" > "$WORK_DIR/capture-receipt.json"

CAPTURE_STATUS=''
for ((index=0; index<80; index++)); do
  curl -fsS "$SERVER_URL/captures/$CAPTURE_ID" > "$WORK_DIR/capture-status.json"
  CAPTURE_STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status") or "")' < "$WORK_DIR/capture-status.json")"
  [[ "$CAPTURE_STATUS" == 'saved' ]] && break
  sleep 0.25
done
[[ "$CAPTURE_STATUS" == 'saved' ]] || {
  tick "selection capture did not reach saved; status=$CAPTURE_STATUS"
  exit 1
}

tick 'patching capture tags and note through CaptureService'
curl -fsS \
  -X PATCH \
  -H 'Content-Type: application/json' \
  --data '{"tags":["smoke"],"note":"two browser contract"}' \
  "$SERVER_URL/captures/$CAPTURE_ID" > "$WORK_DIR/capture-patch.json"

SIDECAR="$(find "$WORK_DIR/archive" -type f -name '*.md' ! -name 'index.md' -print -quit)"
[[ -n "$SIDECAR" ]] || { tick 'selection sidecar was not created'; exit 1; }
grep -Fq 'tags: ["smoke"]' "$SIDECAR" || { tick 'sidecar tags were not patched'; exit 1; }
grep -Fq 'notes: "two browser contract"' "$SIDECAR" || { tick 'sidecar note was not patched'; exit 1; }

RESULT='PASS'
