import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const extensionDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

async function readExtensionFile(relativePath) {
  return readFile(path.join(extensionDir, relativePath), 'utf8');
}

test('Twitter repairs action order through one coalesced observer without per-tweet observers', async () => {
  const source = await readExtensionFile('src/content/content-twitter.js');

  assert.match(source, /const ensureArchiveOrder = \(\) =>/);
  assert.match(source, /currentBookmarkWrapper\?\.nextElementSibling/);
  assert.match(source, /wrapper\.nextElementSibling === currentShareWrapper/);
  assert.match(source, /if \(!alreadyOrdered\)/);
  assert.match(source, /const timelineOrderMaintainers = new WeakMap\(\)/);
  assert.match(source, /timelineOrderMaintainers\.set\(wrapper, ensureArchiveOrder\)/);
  assert.match(source, /timelineOrderMaintainers\.get\(wrapper\)/);
  assert.match(source, /const observer = new MutationObserver\(scheduleTweetProcessing\)/);
  assert.match(source, /if \(processFrame !== null\) return/);
  assert.doesNotMatch(source, /orderObserver/);
});

test('shortcut hint menus cannot trap the pointer on Twitter or Bluesky', async () => {
  const [twitter, bluesky] = await Promise.all([
    readExtensionFile('src/content/content-twitter.js'),
    readExtensionFile('src/content/content-bluesky.js')
  ]);

  assert.match(
    twitter,
    /\.media-archiver-twitter-btn \.archiver-menu\.visible[\s\S]*?pointer-events:\s*none;/
  );
  assert.match(
    bluesky,
    /\.media-archiver-bsky-wrapper \.archiver-menu\.visible\{pointer-events:none\}/
  );
});

test('debug mode is disabled by default and manifests use lifecycle-appropriate permissions', async () => {
  const [monitor, background, firefoxManifest, chromeManifest] = await Promise.all([
    readExtensionFile('src/content/utils/monitor.js'),
    readExtensionFile('src/background/background.js'),
    readExtensionFile('manifests/firefox.json').then(JSON.parse),
    readExtensionFile('manifests/chrome.json').then(JSON.parse)
  ]);

  assert.match(monitor, /const DEBUG_STORAGE_KEY = ['"]debugMode['"]/);
  assert.match(monitor, /const DEBUG_DEFAULT_ENABLED = false/);
  assert.match(background, /const DEBUG_STORAGE_KEYS = \[['"]debugMode['"], ['"]archiver_debug_mode['"]\]/);
  assert.ok(firefoxManifest.permissions.includes('http://127.0.0.1/*'));
  assert.equal(firefoxManifest.manifest_version, 2);
  assert.notEqual(firefoxManifest.background?.persistent, false);
  assert.ok(!firefoxManifest.permissions.includes('alarms'));
  assert.equal(chromeManifest.manifest_version, 3);
  assert.ok(chromeManifest.permissions.includes('alarms'));
  assert.match(background, /const alarmsApi = manifestVersion >= 3/);
  assert.equal(firefoxManifest.version, '1.3.6');
  assert.equal(chromeManifest.version, '1.3.6');
});

test('background polling uses server-first reconciliation and bounded concurrency', async () => {
  const background = await readExtensionFile('src/background/background.js');

  assert.match(background, /reconcileTrackedJob\(\{[\s\S]*?`\$\{SERVER_URL\}\/jobs\/\$\{jobId\}`/);
  assert.match(background, /allSettledBounded\([\s\S]*?JOB_POLL_CONCURRENCY/);
  assert.match(background, /async function updateConfirmedJob[\s\S]*?entry\.lastConfirmedAt = result\.observedAt/);
  assert.match(background, /if \(result\.action === 'retain'\)[\s\S]*?await updateConfirmedJob/);
  assert.match(background, /if \(result\.action === 'stalled'\)[\s\S]*?await reportStalledJob/);
  assert.doesNotMatch(background, /Date\.now\(\) - startTime > JOB_/);
  assert.match(background, /commitTerminalGeneration\(\{/);
  assert.match(background, /markTerminal: \(\) => captureRuntime\.mark\(entry\.captureId, state/);
  assert.match(background, /if \(reportedStalledJobIds\.has\(jobId\)\) return/);
  assert.match(background, /reportedStalledJobIds\.delete\(jobId\)/);
  assert.match(background, /await ensureActiveJobsRestored\(\)/);
  assert.match(background, /let activeJobsRestoreComplete = false/);
  assert.match(background, /retryActiveJobsRestoreIfNeeded\(\)/);
  assert.match(background, /Could not clean invalid active-job pointers/);
  assert.match(background, /generation: nextActiveJobGeneration\(\)/);
  assert.match(background, /hasReplacementJobGeneration\(jobId, entry\)/);
  assert.match(background, /if \(receipt\?\.jobId && activeJobs\.has\(receipt\.jobId\)\)[\s\S]*?pollJobStatus\(receipt\.jobId\)/);
  assert.match(background, /\[healthAlarmScheduled, heartbeatAlarmScheduled\] = scheduled/);
  assert.match(background, /startFallbackMaintenanceTimers\(\{ health: true, heartbeat: false \}\)/);
  assert.match(background, /startFallbackMaintenanceTimers\(\{ health: false, heartbeat: true \}\)/);
  assert.doesNotMatch(background, /if \(!alarmsScheduled\)[\s\S]*?clearAlarm\(HEALTH_ALARM_NAME\)/);
});

test('capture requests have deadlines and retry polling respects terminal receipts', async () => {
  const background = await readExtensionFile('src/background/background.js');

  assert.match(background, /fetchWithTimeout\(async \(_input, \{ signal \}\) => \{[\s\S]*?return fetch\(`\$\{SERVER_URL\}\/captures`[\s\S]*?signal[\s\S]*?CAPTURE_REQUEST_TIMEOUT_MS/);
  assert.match(background, /fetchWithTimeout\(fetch, `\$\{SERVER_URL\}\/captures\/\$\{encodeURIComponent\(captureId\)\}`,[\s\S]*?CAPTURE_PATCH_REQUEST_TIMEOUT_MS/);
  assert.match(background, /return fetch\(`\$\{SERVER_URL\}\/captures\/\$\{encodeURIComponent\(captureId\)\}\/retry`[\s\S]*?signal[\s\S]*?CAPTURE_REQUEST_TIMEOUT_MS/);
  assert.match(background, /const terminal = \['saved', 'completed', 'failed', 'stalled'\]\.includes/);
  assert.match(background, /if \(receipt\.jobId && !terminal\)[\s\S]*?await startJobPolling/);
  assert.match(background, /safe storage budget\|quota_bytes\|capture_inbox_capacity/);
  assert.match(background, /title: 'Capture not submitted'/);
});

test('job polling keeps its short interval while the alarm is the wake-up backstop', async () => {
  const background = await readExtensionFile('src/background/background.js');
  const schedule = background.match(/async function scheduleJobPollingAlarm\(\) \{[\s\S]*?\n\}/)?.[0] || '';

  assert.match(background, /const JOB_POLL_INTERVAL_MS = 2500;/);
  assert.match(schedule, /ensureAlarm\(\s*JOB_POLL_ALARM_NAME/);
  assert.match(schedule, /startJobPollInterval\(\);\n  return scheduled;/, 'the interval starts whether or not the alarm was scheduled');
  assert.doesNotMatch(schedule, /clearInterval/, 'a scheduled 30 s alarm must not replace the 2.5 s poll');
});

test('health checks are single-flight and existing alarms are not recreated', async () => {
  const background = await readExtensionFile('src/background/background.js');

  assert.match(background, /const checkServer = singleFlight\(performServerCheck\)/);
  assert.match(
    background,
    /let SERVER_URL = null;[\s\S]*?createEndpointBootstrap\(\{[\s\S]*?resolveEndpoint: getServerURL/
  );
  assert.match(background, /async function performServerCheck\(\) \{\s*await ensureServerEndpointBootstrapped\(\)/);
  assert.match(background, /isManualPortStorageChange\(changes, areaName\)[\s\S]*?serverEndpointBootstrap\.refresh\(\)[\s\S]*?checkServer\(\)/);
  assert.match(background, /healthLifecycleRestorePromise = null;[\s\S]*?return false/);
  assert.match(background, /if \(!\(await ensureHealthLifecycleRestored\(\)\)\) return serverAvailable/);
  assert.doesNotMatch(background, /await persistHealthLifecycle\(\)/);
  assert.match(background, /void persistHealthLifecycle\(healthLifecycle\.snapshot\(\), probe\.endpointGeneration\)/);
  assert.match(
    background,
    /queuedCaptures = \(await captureStore\.list\(\)\)[\s\S]*?if \(endpointGeneration !== serverEndpointGeneration\) return false;[\s\S]*?browser\.notifications\.create\('server-back'/
  );
  assert.match(
    background,
    /handleServerAvailable\([\s\S]*?endpointGeneration: probe\.endpointGeneration[\s\S]*?if \(!recoveryApplied\)[\s\S]*?scheduleFreshServerCheck\(\)/
  );
  assert.match(background, /if \(probe\.endpointGeneration !== serverEndpointGeneration\)[\s\S]*?scheduleFreshServerCheck\(\)/);
  assert.match(background, /lifecycle\.transition === 'initial-up'[\s\S]*?notify: false/);
  assert.match(background, /if \(lifecycle\.notifyDown\)/);
  assert.match(background, /const existing = await alarmsApi\.get\(name\)/);
  assert.match(background, /if \(existing\) return true/);
  assert.match(background, /ensureAlarm\(HEARTBEAT_ALARM_NAME/);
  assert.match(background, /retryDurableCaptures\(\['queued', 'submitting'\]\)/);
  assert.match(background, /retryPending\(\{ states \}\)\.catch/);
});

test('diagnostics exposes crash-interrupted submitting captures for manual retry', async () => {
  const debugPage = await readExtensionFile('src/pages/debug.js');
  assert.match(debugPage, /\['queued', 'submitting', 'failed', 'stalled'\]\.includes\(record\.state\)/);
});

test('Twitter reports durable-inbox quota failures before generic screenshot errors', async () => {
  const twitter = await readExtensionFile('src/content/content-twitter.js');
  const durableBranch = twitter.indexOf("message.includes('durable inbox')");
  const offlineBranch = twitter.indexOf("message.includes('queued for retry')");
  const screenshotBranch = twitter.indexOf("message.includes('capture') || message.includes('screenshot')");

  assert.ok(durableBranch >= 0);
  assert.ok(offlineBranch > durableBranch);
  assert.ok(screenshotBranch > durableBranch);
  assert.match(twitter, /shortLabel: 'Capture not queued'/);
});
