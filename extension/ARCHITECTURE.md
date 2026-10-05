# NoDraw Capture Architecture

NoDraw has one capture system with two public boundaries:

- `CaptureRuntime` is the browser extension boundary. Content scripts and browser UI describe an intended capture; the runtime normalizes it, persists it, sends it, tracks its state, and exposes retry, dismissal, and metadata editing.
- `CaptureService` is the server boundary. HTTP routes translate into the versioned contract; the service owns idempotency, durable receipts, dispatch to downloaders, and capture metadata.

The files underneath these boundaries are private implementation modules. They are not separate capture systems and should not be called directly from new product code.

## Capture flow

1. A site script, toolbar action, keyboard command, or context menu describes a page, media, link, or selection capture.
2. `CaptureRuntime` creates a version 1 `CaptureIntent`, including a stable capture ID and an intent fingerprint.
3. The browser capture store records the complete request before network submission. Offline, timed-out, crash-interrupted `submitting`, and failed requests remain reviewable instead of expiring from a short-lived URL queue, and screenshot context remains durable so retries are equivalent to the original attempt. Inbox mutations are serialized because `browser.storage.local` has no atomic read/modify/write primitive. Once the server returns a durable non-retryable receipt, the browser copy strips its screenshot payload; failed/stalled canonical captures retain richer context for retry. If local storage cannot preserve the complete request, submission stops and reports that storage failure instead of silently degrading the capture.
4. The runtime submits `{ intent, cookies }` to `POST /captures`. Cookies are captured immediately before transport and are never persisted in the intent or inbox.
5. `CaptureService` checks capture ID and its own SHA-256 identity of the normalized requested content before creating a job. The client fingerprint is advisory, not proof of equality. A repeated operation returns its durable receipt without another download. Legacy fingerprint hits are reused only after full stored-intent comparison.
6. The existing downloader implementations do the media work. Capture kind and versioned intent metadata stay attached to the job.
7. The browser polls the existing job endpoint and projects state into the universal capture card and durable inbox.
8. Tags and the note are patched through `PATCH /captures/{capture_id}`.

Metadata edits have a separate durable lifecycle from saved media. Each input stages only its changed field in the existing bounded inbox. Before dispatch, the runtime freezes that draft under a random `mutationId`; network failure or a lost local acknowledgement retains the exact token and fields. The server commits each token's canonical payload hash and accepted revision in the same transaction as metadata intent. Replaying the same token returns acceptance evidence without applying or rebasing it again, even after newer mutations; reusing a token for different fields returns HTTP 409. Receipts are retained without time-based pruning. Legacy tokenless patches remain supported, and an empty patch only retries pending projection. Newer drafts wait behind unresolved dispatch evidence and receive a new token. The card and inbox restore drafts, pending projection, and actionable errors after restart while saved media stays saved. These tokens do not change CaptureIntent v1, capture IDs, or fingerprints.

Capture POST/retry requests have one 30-second end-to-end deadline covering server health/discovery, cookie lookup, fetch, and response-body decoding; metadata patches have a 10-second fetch-and-body deadline. A timeout returns to durable queued/retryable state rather than remaining `submitting` indefinitely. Recovery settles records independently, so one malformed legacy entry cannot prevent later queued or crash-interrupted `submitting` captures from retrying.

The capture inbox has a four-MiB serialized-data budget, leaving headroom within common browser storage limits for job pointers and settings. This is not an eviction budget: any enlarging mutation that exceeds it fails before writing, preserves every existing queued/submitting/accepted record, and produces an explicit user-visible storage error. A legacy over-budget inbox may still shrink or be dismissed. Native storage quota failures propagate through the same fail-closed path.

The server fingerprint covers normalized page/media/selection/user/options context, including full screenshot content, notes/tags, save mode, platform, site data and download controls. Quick, Full and distinct context remain independent. Twitter/Bluesky reserve a post before their first asynchronous lookup or prompt, across widgets. Confirmed fresh-copy requests carry `options.captureAgain`; their capture ID then participates in identity, allowing a deliberate new copy while retries of that same operation remain idempotent. The compact client fingerprint remains for compatibility and local bookkeeping, never server authority. If a legacy fingerprint still collides, the existing canonical record wins equally authoritative durable state, receipt/job/file truth, and its non-empty note; tags are unioned, richer retry options/context fill the failed or stalled canonical payload, and newer terminal server truth may advance an older non-terminal state.

Background health and job requests use abortable deadlines. Active-job restoration and mutations share one serialized barrier, each polling generation has an identity token, and terminal inbox state must commit before its reconciliation pointer can be durably removed. A stale response cannot delete a replacement generation, and either storage failure leaves the pointer in place for another reconciliation. If the server accepts a capture but the active-job pointer cannot be stored, the inbox keeps the capture queued with its job ID and the periodic recovery pass retries reconciliation. The first poll starts only after `CaptureRuntime` has durably committed the accepted inbox state, and conditional state transitions prevent a faster terminal poll from being overwritten by the original response. Polling uses bounded parallelism, and the last server-confirmed status is persisted periodically. Total job runtime is not a failure signal: even an old or restored job is queried first and remains tracked while the server reports it pending or downloading. It becomes a visible retryable `stalled` capture only when the server reports it stalled or missing, or when server truth has remained unavailable for the explicit five-minute unconfirmed window.

Health probes are single-flight and use explicit unknown/up/down lifecycle state, so a fresh worker does not emit a false reconnect and an older failure cannot overwrite a newer result. Endpoint generations guard both persisted health snapshots and post-probe asynchronous effects: a port change while reading the inbox cannot trigger a stale reconnect notification or submit queued work to an unverified endpoint. Non-OK responses count toward one outage notification after two consecutive failures, including a cold-start outage; later success is called a reconnect only if that persisted lifecycle had previously observed the server up. Existing alarms are reused rather than recreated, which prevents routine worker starts from postponing the heartbeat. Chrome MV3 declares the alarms capability so its service worker can wake after suspension. Firefox MV2 keeps its background page persistent and uses in-memory timers, avoiding a new upgrade permission. Chrome installs independent health and heartbeat timer fallbacks for whichever alarm could not be scheduled, so one transient sibling failure cannot remove the other valid wake alarm.

The background begins without a usable server URL and gates health, heartbeat, restored-job polling, capture metadata, and direct dashboard/query routes on one bounded, single-flight endpoint bootstrap. An explicitly saved manual port has first priority; otherwise the bootstrap uses service discovery and finally `http://localhost:8847` as its seven-second fail-safe. This prevents a healthy fallback server from winning before an advertised or manually selected alternate is resolved. Setting or removing the manual port starts a new bootstrap generation, immediately invalidates prior availability, and prevents a late older resolution from replacing the new route.

The current retry API refreshes cookies for the server's already-durable intent; it does not accept client-side intent overrides. New semantic fingerprints keep Quick, Full, screenshot, and download-option changes from colliding. If a legacy fingerprint collision is recovered locally, richer context remains available in the inbox, but applying that changed intent to the existing server capture requires a future retry-contract revision or a deliberate new submission.

The public state vocabulary is `saving`, `accepted`, `processing`, `saved`, `duplicate`, `queued`, `failed`, and `stalled`. Browser presentation may label `accepted` as “Downloading” and `failed` or `stalled` as “Needs attention.”

## Versioned contract

`CaptureIntent` version 1 is defined in `src/runtime/capture-intent.js` and mirrored by the Pydantic models in `server/capture_service.py`.

Its durable identity fields are:

- `schemaVersion`
- `captureId`
- `fingerprint`
- `kind`: `page`, `media`, `link`, or `selection`
- `targetUrl` and `sourcePageUrl`
- `createdAt`

Its context is grouped under `page`, `media`, `selection`, `user`, and `options`. Context-menu captures must preserve their kind. Two selections from one page are distinct because selection content participates in the fingerprint; save mode, screenshot content, and semantic option changes are also distinct. The client fingerprint stays compact; the server computes a collision-resistant SHA-256 identity from the complete normalized content. `options.captureAgain` defaults to false for older clients.

Contract changes require all of the following in the same change:

- update the browser normalizer and server model;
- increment the schema version when old readers cannot interpret the new shape;
- add or update fixtures under `extension/tests/fixtures/`;
- add server coverage for acceptance, duplicates, and migration behavior;
- keep an explicit compatibility translation if an installed older extension can still send the previous request shape.

## Source and build layout

There is one extension source tree and two manifests:

```text
extension/
  manifests/              Firefox MV2 and Chrome MV3 manifests
  src/
    entries/               thin bundle entrypoints
    runtime/               CaptureRuntime, CaptureIntent, durable store
    background/            browser orchestration and server transport
    content/               site extractors and the universal page agent
    pages/                 options and diagnostics UI
    assets/
  tests/
    fixtures/
    unit/
    manual/
```

`extension/build.mjs` bundles every browser context as an IIFE. `scripts/build-extensions.sh` stages the appropriate manifest and produces deterministic packages:

```bash
# First checkout, or after package-lock.json changes
npm ci --prefix extension

# Both browsers
./scripts/build-extensions.sh

# One browser while iterating
./scripts/build-extensions.sh firefox
./scripts/build-extensions.sh chrome
```

Outputs are `dist/extension-firefox/`, `dist/extension-chrome/`, `dist/nodraw-<version>.xpi`, and `dist/nodraw-<version>-chrome.zip`.

Do not add browser-specific source forks. A difference should live in a manifest, a thin entrypoint, or a small capability check in shared code.

## Validation

Fast checks:

```bash
npm test --prefix extension
server/.venv/bin/python -m pytest server/tests -q
./scripts/build-extensions.sh
```

Package checks:

```bash
web-ext lint --source-dir dist/extension-firefox --output json
node -e "JSON.parse(require('fs').readFileSync('dist/extension-chrome/manifest.json'))"
```

The browser packages must target the same running server and version 1 capture API. Passing unit tests is not a substitute for loading each unpacked build and exercising page, image, link, selection, duplicate, offline, retry, and metadata-edit flows.

## Compatibility and deletion rules

Version 1.2.0 completed the cutover. The old `/archive` and `/archive-image`
routes, `archive`/`archiveImage` messages, URL-only queue, and its helper modules
are deleted. On extension update, the obsolete ten-minute `downloadQueue` key is
removed because its records cannot be safely promoted into versioned intents.

Do not reintroduce a second transport. Contract evolution belongs in
`CaptureIntent`, `CaptureRuntime`, and `CaptureService`, with migrations and
fixtures in the same commit.

## Ownership boundary

Site scripts own volatile page-local discovery: selectors, media candidates, post metadata, and site-specific buttons. They do not own server discovery, cookies, idempotency, retry policy, job polling, or durable failure state.

`CaptureRuntime` owns browser capture semantics. `CaptureService` owns server capture semantics. Downloader modules remain specialized mechanics behind the service. This keeps the system wrapped in one custom capture pipeline without turning its internal modules into one giant file.
