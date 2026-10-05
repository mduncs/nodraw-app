// nodraw - Background Script
// Server discovery is handled by discover.js (loaded before this file).

import { CaptureRuntime } from '../runtime/capture-runtime.js';
import { CaptureStore } from '../runtime/capture-store.js';
import { collectionCaptureBlockReason } from '../runtime/capture-target.js';
import {
  createEndpointBootstrap,
  DEFAULT_SERVER_ENDPOINT,
  isManualPortStorageChange
} from '../runtime/endpoint-bootstrap.js';
import {
  allSettledBounded,
  fetchWithTimeout,
  normalizeRestoredJobs,
  reconcileTrackedJob
} from '../runtime/async-control.js';
import {
  HealthLifecycle,
  isCurrentHealthProbe,
  singleFlight
} from '../runtime/health-lifecycle.js';
import {
  commitTerminalGeneration,
  createSerializedExecutor
} from '../runtime/active-job-lifecycle.js';
import { getServerURL, invalidateDiscoveryCache } from './discover.js';

const extensionGlobal = typeof globalThis !== 'undefined' ? globalThis : self;
const browser = extensionGlobal.browser || extensionGlobal.chrome;
const actionApi = browser.action || browser.browserAction;
const manifestVersion = browser.runtime?.getManifest?.().manifest_version || 2;
// Chrome MV3 needs alarms to wake its suspended service worker. Firefox's MV2
// background page is persistent and deliberately uses the interval fallback so
// upgrading 1.2.4 does not request a new permission.
const alarmsApi = manifestVersion >= 3 ? (browser.alarms || null) : null;
const scriptingApi = browser.scripting || null;
const captureStore = new CaptureStore(browser.storage.local);
let SERVER_URL = null;
let serverEndpointGeneration = 0;
let serverAvailable = false;
const HEARTBEAT_INTERVAL_MS = 60 * 1000;
const HEARTBEAT_MIN_GAP_MS = 20 * 1000;
let lastHeartbeatSentAt = 0;

// Active job tracking for polling and badge
const activeJobs = new Map(); // job_id -> { url, timer, startTime, tabId }
const JOB_POLL_INTERVAL_MS = 2500;
const JOB_UNCONFIRMED_TIMEOUT_MS = 5 * 60 * 1000;
const JOB_CONFIRMATION_PERSIST_INTERVAL_MS = 30 * 1000;
const JOB_STATUS_REQUEST_TIMEOUT_MS = 10 * 1000;
const JOB_POLL_CONCURRENCY = 4;
const CAPTURE_REQUEST_TIMEOUT_MS = 30 * 1000;
const CAPTURE_PATCH_REQUEST_TIMEOUT_MS = 10 * 1000;
const HEALTH_REQUEST_TIMEOUT_MS = 5 * 1000;
const HEARTBEAT_REQUEST_TIMEOUT_MS = 5 * 1000;
const ENDPOINT_BOOTSTRAP_TIMEOUT_MS = 7 * 1000;
const ACTIVE_JOBS_KEY = 'activeArchiveJobs';
const RECENT_FAILURES_KEY = 'recentDownloadFailures';
const HEALTH_LIFECYCLE_KEY = 'serverHealthLifecycleV1';
const DEBUG_STORAGE_KEYS = ['debugMode', 'archiver_debug_mode'];
const DEBUG_DEFAULT_ENABLED = false;
const MAX_RECENT_FAILURES = 20;
const HEALTH_ALARM_NAME = 'nodraw-health-check';
const HEARTBEAT_ALARM_NAME = 'nodraw-heartbeat';
const JOB_POLL_ALARM_NAME = 'nodraw-job-poll';
const pollingJobIds = new Set();
const reportedStalledJobIds = new Set();
let jobPollTimer = null;
let fallbackHealthTimer = null;
let fallbackHeartbeatTimer = null;
let alarmListenerInstalled = false;
const alarmMutationTails = new Map();
let activeJobsRestorePromise = null;
let activeJobsRestoreComplete = false;
let healthLifecycleRestorePromise = null;
let activeJobGeneration = 0;
const withActiveJobsMutation = createSerializedExecutor();
const withHealthLifecyclePersistence = createSerializedExecutor();

// Badge colors
const BADGE_COLOR_DOWNLOADING = '#E87A20'; // orange
const BADGE_COLOR_SUCCESS = '#22C55E';      // green
const BADGE_COLOR_ERROR = '#EF4444';        // red

function markServerEndpointUnknown() {
  serverEndpointGeneration += 1;
  serverAvailable = false;
  updateIcon(false);
}

function setServerURL(url) {
  if (!url || url === SERVER_URL) return;
  SERVER_URL = url;
  // Availability belongs to the endpoint generation that established it. A
  // newly selected port is unknown until its own health probe succeeds.
  markServerEndpointUnknown();
}

const serverEndpointBootstrap = createEndpointBootstrap({
  resolveEndpoint: getServerURL,
  applyEndpoint: setServerURL,
  invalidateEndpoint: markServerEndpointUnknown,
  fallbackEndpoint: DEFAULT_SERVER_ENDPOINT,
  timeoutMs: ENDPOINT_BOOTSTRAP_TIMEOUT_MS
});

function ensureServerEndpointBootstrapped() {
  return serverEndpointBootstrap.ensure();
}

function detectBrowserLabel() {
  const ua = navigator?.userAgent?.toLowerCase() || '';
  if (ua.includes('firefox')) return 'firefox';
  if (ua.includes('edg/')) return 'edge';
  if (ua.includes('chrome')) return 'chrome';
  if (ua.includes('safari')) return 'safari';
  return 'unknown';
}

function ignoreRuntimePromise(result) {
  if (result && typeof result.catch === 'function') {
    result.catch(() => {});
  }
}

async function createAlarm(name, alarmInfo) {
  if (!alarmsApi?.create) return false;
  try {
    const result = alarmsApi.create(name, alarmInfo);
    if (result && typeof result.then === 'function') await result;
    return true;
  } catch (error) {
    console.warn(`[nodraw] Could not schedule alarm ${name}:`, error?.message || error);
    return false;
  }
}

function withAlarmMutation(name, operation) {
  const previous = alarmMutationTails.get(name) || Promise.resolve();
  const run = previous.catch(() => {}).then(operation);
  const tail = run.then(() => undefined, () => undefined);
  alarmMutationTails.set(name, tail);
  void tail.finally(() => {
    if (alarmMutationTails.get(name) === tail) alarmMutationTails.delete(name);
  });
  return run;
}

function ensureAlarm(name, alarmInfo) {
  if (!alarmsApi?.create) return Promise.resolve(false);
  return withAlarmMutation(name, async () => {
    try {
      if (alarmsApi.get) {
        const existing = await alarmsApi.get(name);
        if (existing) return true;
      }
      return createAlarm(name, alarmInfo);
    } catch (error) {
      console.warn(`[nodraw] Could not inspect alarm ${name}:`, error?.message || error);
      return false;
    }
  });
}

function clearAlarm(name) {
  if (!alarmsApi?.clear) return Promise.resolve(false);
  return withAlarmMutation(name, async () => {
    try {
      const result = alarmsApi.clear(name);
      return result && typeof result.then === 'function' ? await result : Boolean(result);
    } catch {
      return false;
    }
  });
}

async function sendExtensionHeartbeat(trigger = 'interval', force = false) {
  await ensureServerEndpointBootstrapped();
  if (!serverAvailable || !SERVER_URL) return false;

  const now = Date.now();
  if (!force && (now - lastHeartbeatSentAt) < HEARTBEAT_MIN_GAP_MS) {
    return false;
  }

  try {
    const manifest = browser.runtime?.getManifest ? browser.runtime.getManifest() : null;
    const response = await fetchWithTimeout(fetch, `${SERVER_URL}/extension/heartbeat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        extension_id: browser.runtime?.id || null,
        extension_version: manifest?.version || null,
        browser: detectBrowserLabel(),
        trigger
      })
    }, HEARTBEAT_REQUEST_TIMEOUT_MS);
    if (response.ok) {
      lastHeartbeatSentAt = now;
      return true;
    }
  } catch (error) {
    // Heartbeat is best-effort and should not impact archive flow.
  }

  return false;
}

async function loadRecentFailures() {
  try {
    const result = await browser.storage.local.get(RECENT_FAILURES_KEY);
    const failures = Array.isArray(result[RECENT_FAILURES_KEY])
      ? result[RECENT_FAILURES_KEY]
      : [];
    bgMetrics.recentFailures = failures.map((failure) => ({
      jobId: failure.jobId ?? null,
      url: failure.url || '',
      error: failure.error || 'Download failed',
      category: failure.category || failure.errorCategory || null,
      errorCategory: failure.errorCategory || failure.category || null,
      message: failure.message || friendlyError(failure.error, failure.category || failure.errorCategory),
      actionHint: failure.actionHint || failureActionHint(failure.error, failure.category || failure.errorCategory),
      retryable: typeof failure.retryable === 'boolean'
        ? failure.retryable
        : isRetryableFailure(failure.error, failure.category || failure.errorCategory),
      time: failure.time || failure.timestamp || Date.now(),
      timestamp: failure.timestamp || failure.time || Date.now()
    }));
  } catch {
    bgMetrics.recentFailures = [];
  }
}

// Retry the single-flight health controller during the server/app boot race.
async function runStartupHealthRetries() {
  const STARTUP_RETRIES = 5;
  const STARTUP_DELAY_MS = 3000;
  for (let i = 0; i < STARTUP_RETRIES; i++) {
    if (await checkServer()) return;
    if (i < STARTUP_RETRIES - 1) {
      await new Promise(r => setTimeout(r, STARTUP_DELAY_MS));
      if (typeof invalidateDiscoveryCache === 'function') invalidateDiscoveryCache();
    }
  }
  // The maintenance scheduler keeps trying after this bounded startup window.
}

// Re-resolve both when a manual override is set and when it is removed in
// favor of automatic discovery. Refresh generations suppress any older result.
browser.storage.onChanged.addListener((changes, areaName) => {
  if (!isManualPortStorageChange(changes, areaName)) return;
  invalidateDiscoveryCache();
  void serverEndpointBootstrap.refresh()
    .then(() => checkServer())
    .catch(error => {
      console.warn('[nodraw] Could not refresh server endpoint:', error?.message || error);
    });
});

// --- Badge management ---

async function updateBadge() {
  let queuedCaptures = 0;
  try {
    queuedCaptures = (await captureStore.list())
      .filter(record => ['queued', 'submitting'].includes(record.state)).length;
  } catch {}

  const count = activeJobs.size + queuedCaptures;
  if (!actionApi) return;

  if (count > 0) {
    actionApi.setBadgeText({ text: String(count) });
    actionApi.setBadgeBackgroundColor({ color: BADGE_COLOR_DOWNLOADING });
  } else {
    actionApi.setBadgeText({ text: '' });
  }
}

function flashBadge(color, text, durationMs = 2000) {
  if (!actionApi) return;

  actionApi.setBadgeText({ text });
  actionApi.setBadgeBackgroundColor({ color });
  setTimeout(() => {
    void updateBadge();
  }, durationMs);
}

// --- Error message mapping ---

function friendlyError(errorStr, errorCategory) {
  // Use server-side error_category if available (avoids re-parsing raw strings)
  if (errorCategory) {
    const categoryMessages = {
      'rate_limited': 'Rate limited -- try again in a few minutes',
      'not_found': 'Download failed -- content no longer available',
      'access_denied': 'Access denied -- content may be private or restricted',
      'timeout': 'Network timeout -- server could not reach the URL',
      'unsupported': 'URL not supported -- no handler for this site',
      'no_media': 'No downloadable media found at this URL',
      'storage': 'Server storage full -- check disk space',
      'server_error': 'Server error -- check server logs for details',
    };
    if (categoryMessages[errorCategory]) {
      return categoryMessages[errorCategory];
    }
  }

  // Fallback: parse raw error string
  if (!errorStr) return 'Unknown error';
  const lower = errorStr.toLowerCase();

  if (lower.includes('rate limit') || lower.includes('429') || lower.includes('too many requests')) {
    return 'Rate limited -- try again in a few minutes';
  }
  if (lower.includes('no handler') || lower.includes('unsupported') || lower.includes('no suitable')) {
    return 'URL not supported -- no handler for this site';
  }
  if (lower.includes('404') || lower.includes('not found') || lower.includes('no longer available') || lower.includes('deleted')) {
    return 'Download failed -- content no longer available';
  }
  if (lower.includes('403') || lower.includes('forbidden') || lower.includes('private')) {
    return 'Access denied -- content may be private or restricted';
  }
  if (lower.includes('timeout') || lower.includes('timed out') || lower.includes('connect')) {
    return 'Network timeout -- server could not reach the URL';
  }
  if (lower.includes('no video') || lower.includes('no media') || lower.includes('no audio')) {
    return 'No downloadable media found at this URL';
  }
  if (lower.includes('disk') || lower.includes('space') || lower.includes('quota')) {
    return 'Server storage full -- check disk space';
  }

  // Truncate long error messages
  if (errorStr.length > 120) {
    return errorStr.substring(0, 117) + '...';
  }
  return errorStr;
}

function failureActionHint(errorStr, errorCategory) {
  const lower = (errorStr || '').toLowerCase();

  if (errorCategory === 'rate_limited' || lower.includes('rate limit') || lower.includes('429')) {
    return 'Wait a few minutes, then retry from the page.';
  }
  if (
    errorCategory === 'access_denied' ||
    lower.includes('auth') ||
    lower.includes('cookie') ||
    lower.includes('forbidden') ||
    lower.includes('private')
  ) {
    return 'Open the post while logged in, then retry.';
  }
  if (errorCategory === 'no_media' || lower.includes('no media') || lower.includes('no video')) {
    return 'Try Full archive or screenshot/text mode.';
  }
  if (lower.includes('server not installed') || lower.includes('connection refused')) {
    return 'Open NoDraw Downloads settings and start the server.';
  }
  if (lower.includes('no screenshot available')) {
    return 'Retry from the page so the extension can send page context.';
  }
  return 'Click the page button again to retry; check Downloads settings if it repeats.';
}

function isRetryableFailure(errorStr, errorCategory) {
  const lower = (errorStr || '').toLowerCase();
  if (errorCategory === 'not_found' || lower.includes('deleted') || lower.includes('no longer available')) {
    return false;
  }
  return true;
}

async function recordRecentFailure({ jobId, url, error, errorCategory }) {
  const category = errorCategory || null;
  const retryable = isRetryableFailure(error, category);
  const timestamp = Date.now();
  const failure = {
    jobId: jobId ?? null,
    url: url || '',
    error: error || 'Download failed',
    category,
    errorCategory: category,
    message: friendlyError(error, category),
    actionHint: failureActionHint(error, category),
    retryable,
    time: timestamp,
    timestamp
  };

  bgMetrics.recentFailures.unshift(failure);
  if (bgMetrics.recentFailures.length > MAX_RECENT_FAILURES) {
    bgMetrics.recentFailures.length = MAX_RECENT_FAILURES;
  }

  try {
    const result = await browser.storage.local.get(RECENT_FAILURES_KEY);
    const failures = Array.isArray(result[RECENT_FAILURES_KEY])
      ? result[RECENT_FAILURES_KEY]
      : [];
    failures.unshift(failure);
    await browser.storage.local.set({
      [RECENT_FAILURES_KEY]: failures.slice(0, MAX_RECENT_FAILURES)
    });
  } catch (error) {
    console.warn('[archiver-bg] Failed to persist recent failure:', error.message);
  }
}

function sendJobStatusToTab(tabId, payload) {
  if (!Number.isInteger(tabId)) return;
  try {
    const result = browser.tabs.sendMessage(tabId, {
      action: 'archiveJobStatus',
      ...payload
    });
    if (result && typeof result.catch === 'function') {
      result.catch(() => {});
    }
  } catch {
    // The originating tab may have navigated away. The browser notification
    // and persisted failure list still preserve the terminal state.
  }
}

// --- Job status polling ---

function startJobPollInterval() {
  if (jobPollTimer !== null || activeJobs.size === 0) return;
  jobPollTimer = setInterval(() => {
    void pollActiveJobs();
  }, JOB_POLL_INTERVAL_MS);
}

// The alarm wakes a suspended service worker; while the worker is alive the
// interval reports a finished job within JOB_POLL_INTERVAL_MS rather than the
// alarm's 30 s period, so a button doesn't keep saying "saving" after the save.
async function scheduleJobPollingAlarm() {
  if (activeJobs.size === 0) return false;
  const scheduled = await ensureAlarm(
    JOB_POLL_ALARM_NAME,
    { delayInMinutes: 0.5, periodInMinutes: 0.5 }
  );
  startJobPollInterval();
  return scheduled;
}

async function stopJobPollingAlarmIfIdle() {
  if (activeJobs.size === 0) {
    await clearAlarm(JOB_POLL_ALARM_NAME);
    if (activeJobs.size === 0 && jobPollTimer !== null) {
      clearInterval(jobPollTimer);
      jobPollTimer = null;
    }
  }
}

function activeJobsSnapshot() {
  return Array.from(activeJobs.entries()).map(([jobId, job]) => ({
    jobId,
    url: job.url,
    startTime: job.startTime,
    lastConfirmedAt: job.lastConfirmedAt,
    lastStatus: job.lastStatus || null,
    tabId: Number.isInteger(job.tabId) ? job.tabId : null,
    captureId: job.captureId || null
  }));
}

async function writeActiveJobsSnapshot() {
  await browser.storage.local.set({ [ACTIVE_JOBS_KEY]: activeJobsSnapshot() });
}

function isCurrentJobGeneration(jobId, entry) {
  return activeJobs.get(jobId) === entry;
}

function hasReplacementJobGeneration(jobId, entry) {
  const current = activeJobs.get(jobId);
  return Boolean(current && current !== entry);
}

function nextActiveJobGeneration() {
  activeJobGeneration += 1;
  return activeJobGeneration;
}

async function reportStalledJob(jobId, job, error) {
  if (hasReplacementJobGeneration(jobId, job)) return;
  if (reportedStalledJobIds.has(jobId)) return;
  reportedStalledJobIds.add(jobId);
  const captureId = job?.captureId || null;
  const url = job?.url || '';
  const tabId = Number.isInteger(job?.tabId) ? job.tabId : null;

  await recordRecentFailure({
    jobId,
    url,
    error,
    errorCategory: 'timeout'
  });
  if (hasReplacementJobGeneration(jobId, job)) return;

  sendJobStatusToTab(tabId, {
    jobId,
    captureId,
    url,
    status: 'stalled',
    error,
    message: 'Download may have stalled',
    actionHint: 'Check Downloads settings, then retry from the page if it does not finish.',
    retryable: true
  });

  browser.notifications.create(`job-stall-${jobId}`, {
    type: 'basic',
    iconUrl: 'icons/archive-48.png',
    title: 'Download may have stalled',
    message: url
      ? `${shortUrl(url)} was still pending after the polling window. Check the archive server, then retry if needed.`
      : 'A restored download was still pending after the polling window. Check the archive server, then retry if needed.'
  });
}

async function restoreActiveJobsState() {
  const result = await browser.storage.local.get({ [ACTIVE_JOBS_KEY]: [] });
  const jobs = Array.isArray(result[ACTIVE_JOBS_KEY]) ? result[ACTIVE_JOBS_KEY] : [];
  const restored = normalizeRestoredJobs(jobs, Date.now());

  await withActiveJobsMutation(async () => {
    for (const job of restored.restorable) {
      if (activeJobs.has(job.jobId)) continue;
      activeJobs.set(job.jobId, {
        url: job.url,
        startTime: job.startTime,
        lastConfirmedAt: job.lastConfirmedAt,
        lastPersistedConfirmationAt: job.lastConfirmedAt,
        lastStatus: job.lastStatus || null,
        tabId: Number.isInteger(job.tabId) ? job.tabId : null,
        captureId: job.captureId || null,
        generation: nextActiveJobGeneration()
      });
    }

    if (restored.invalid.length > 0) {
      try {
        await writeActiveJobsSnapshot();
      } catch (error) {
        // Valid restored pointers are still durable in the original snapshot.
        // A best-effort cleanup failure must not suppress their polling.
        console.warn('[archiver-bg] Could not clean invalid active-job pointers:', error?.message || error);
      }
    }
  });
}

function ensureActiveJobsRestored() {
  if (!activeJobsRestorePromise) {
    const restore = restoreActiveJobsState().then(() => {
      activeJobsRestoreComplete = true;
    });
    activeJobsRestorePromise = restore.catch(error => {
      activeJobsRestoreComplete = false;
      activeJobsRestorePromise = null;
      throw error;
    });
  }
  return activeJobsRestorePromise;
}

async function restoreActiveJobs() {
  try {
    await ensureActiveJobsRestored();

    if (activeJobs.size > 0) {
      await scheduleJobPollingAlarm();
      void pollActiveJobs();
      void updateBadge();
    } else {
      await stopJobPollingAlarmIfIdle();
    }
  } catch (error) {
    console.warn('[archiver-bg] Failed to restore active jobs:', error.message);
  }
}

function retryActiveJobsRestoreIfNeeded() {
  if (!activeJobsRestoreComplete) void restoreActiveJobs();
}

async function updateConfirmedJob(jobId, entry, result) {
  return withActiveJobsMutation(async () => {
    if (!isCurrentJobGeneration(jobId, entry)) return false;
    entry.lastConfirmedAt = result.observedAt;
    entry.lastStatus = result.payload?.status || entry.lastStatus;
    const lastPersisted = entry.lastPersistedConfirmationAt || entry.startTime;
    if (result.observedAt - lastPersisted >= JOB_CONFIRMATION_PERSIST_INTERVAL_MS) {
      entry.lastPersistedConfirmationAt = result.observedAt;
      try {
        await writeActiveJobsSnapshot();
      } catch (error) {
        entry.lastPersistedConfirmationAt = lastPersisted;
        console.warn(`[archiver-bg] Could not persist confirmation for ${jobId}:`, error?.message || error);
      }
      if (!isCurrentJobGeneration(jobId, entry)) return false;
    }
    return true;
  });
}

async function commitTerminalJob(jobId, entry, state, detail) {
  return withActiveJobsMutation(async () => {
    const outcome = await commitTerminalGeneration({
      isCurrent: () => isCurrentJobGeneration(jobId, entry),
      markTerminal: () => captureRuntime.mark(entry.captureId, state, {
        ...detail,
        jobId
      }),
      removePointer: () => activeJobs.delete(jobId),
      persistPointers: writeActiveJobsSnapshot,
      restorePointer: () => activeJobs.set(jobId, entry),
      pointerExists: () => activeJobs.has(jobId)
    });
    if (!outcome.committed) {
      console.warn(
        `[archiver-bg] Retaining terminal job ${jobId}: ${outcome.reason}`,
        outcome.error?.message || outcome.error || ''
      );
    }
    return outcome.committed;
  });
}

async function pollJobStatusOnce(jobId) {
  await ensureServerEndpointBootstrapped();
  const entry = activeJobs.get(jobId);
  if (!entry) return;

  const { url, tabId, captureId } = entry;
  const result = await reconcileTrackedJob({
    fetchImplementation: fetch,
    requestUrl: `${SERVER_URL}/jobs/${jobId}`,
    requestTimeoutMs: JOB_STATUS_REQUEST_TIMEOUT_MS,
    trackedJob: { ...entry, jobId },
    now: Date.now(),
    unconfirmedTimeoutMs: JOB_UNCONFIRMED_TIMEOUT_MS
  });
  if (!isCurrentJobGeneration(jobId, entry)) return;

  if (result.action === 'retain') {
    if (result.confirmed) {
      await updateConfirmedJob(jobId, entry, result);
      if (!isCurrentJobGeneration(jobId, entry)) return;
    } else {
      console.warn(`[archiver-bg] Job status unconfirmed for ${jobId}:`, result.reason);
    }
    return;
  }

  if (result.action === 'stalled') {
    const committed = await commitTerminalJob(jobId, entry, 'stalled', {
      error: result.reason,
      retryable: true
    });
    if (!committed) return;
    await stopJobPollingAlarmIfIdle();
    if (hasReplacementJobGeneration(jobId, entry)) return;
    void updateBadge();
    await reportStalledJob(jobId, entry, result.reason);
    return;
  }

  const job = result.payload;
  try {
    if (result.action === 'completed') {
      const committed = await commitTerminalJob(jobId, entry, 'saved', {
        filePath: job.file_path || null,
        error: null,
        retryable: false
      });
      if (!committed) return;
      await stopJobPollingAlarmIfIdle();
      if (hasReplacementJobGeneration(jobId, entry)) return;
      void updateBadge();

      bgMetrics.requests.success++;
      const filename = job.file_path ? job.file_path.split('/').pop() : '';

      flashBadge(BADGE_COLOR_SUCCESS, '\u2713');
      sendJobStatusToTab(tabId, {
        jobId,
        captureId,
        url,
        status: 'completed',
        filePath: job.file_path || null,
        filename
      });
      browser.notifications.create(`job-done-${jobId}`, {
        type: 'basic',
        iconUrl: 'icons/archive-48.png',
        title: 'Archived!',
        message: filename || shortUrl(url)
      });
    } else if (result.action === 'failed') {
      const committed = await commitTerminalJob(jobId, entry, 'failed', {
        error: job.error || 'Download failed',
        retryable: isRetryableFailure(job.error, job.error_category)
      });
      if (!committed) return;
      await stopJobPollingAlarmIfIdle();
      if (hasReplacementJobGeneration(jobId, entry)) return;
      void updateBadge();

      bgMetrics.requests.failed++;
      recordError('capture', job.error || 'Download failed');
      void recordRecentFailure({
        jobId,
        url,
        error: job.error,
        errorCategory: job.error_category
      });

      const errorMessage = friendlyError(job.error, job.error_category);
      const actionHint = failureActionHint(job.error, job.error_category);

      flashBadge(BADGE_COLOR_ERROR, '!');
      sendJobStatusToTab(tabId, {
        jobId,
        captureId,
        url,
        status: 'failed',
        error: job.error || 'Download failed',
        errorCategory: job.error_category || null,
        message: errorMessage,
        actionHint,
        retryable: isRetryableFailure(job.error, job.error_category)
      });
      browser.notifications.create(`job-fail-${jobId}`, {
        type: 'basic',
        iconUrl: 'icons/archive-48.png',
        title: 'Download failed',
        message: `${errorMessage}. ${actionHint}`
      });
    }
  } catch (e) {
    console.warn(`[archiver-bg] Could not apply terminal state for ${jobId}:`, e.message);
  }
}

async function pollJobStatus(jobId) {
  if (pollingJobIds.has(jobId)) return;
  pollingJobIds.add(jobId);
  try {
    return await pollJobStatusOnce(jobId);
  } finally {
    pollingJobIds.delete(jobId);
  }
}

async function pollActiveJobs() {
  await allSettledBounded(
    Array.from(activeJobs.keys()),
    JOB_POLL_CONCURRENCY,
    jobId => pollJobStatus(jobId)
  );
}

async function startJobPolling(jobId, url, context = {}) {
  await ensureActiveJobsRestored();
  const startTime = Date.now();
  const tabId = Number.isInteger(context.tabId) ? context.tabId : null;
  const captureId = context.captureId || null;

  const entry = {
    url,
    startTime,
    lastConfirmedAt: startTime,
    lastPersistedConfirmationAt: startTime,
    lastStatus: 'accepted',
    tabId,
    captureId,
    generation: nextActiveJobGeneration()
  };

  await withActiveJobsMutation(async () => {
    const previous = activeJobs.get(jobId);
    activeJobs.set(jobId, entry);
    try {
      await writeActiveJobsSnapshot();
    } catch (error) {
      if (previous) activeJobs.set(jobId, previous);
      else activeJobs.delete(jobId);
      throw error;
    }
    if (!isCurrentJobGeneration(jobId, entry)) {
      throw new Error(`Job ${jobId} changed while its polling pointer was being persisted`);
    }
    // A retry may reuse the server's job ID. It is a new polling generation and
    // is allowed one new terminal notification if it later stalls again.
    reportedStalledJobIds.delete(jobId);
  });
  void updateBadge();

  void scheduleJobPollingAlarm();
}

function shortUrl(url) {
  try {
    const u = new URL(url);
    const path = u.pathname.length > 30 ? u.pathname.substring(0, 27) + '...' : u.pathname;
    return u.hostname + path;
  } catch {
    return url.substring(0, 60);
  }
}

// Metrics tracking for debug panel
const bgMetrics = {
  requests: { total: 0, success: 0, failed: 0 },
  timing: { capture: [], screenshot: [], server: [] },
  errors: {},
  recentFailures: [],
  recentRequests: [], // Last 50 requests for debugging
  startTime: Date.now()
};

void loadRecentFailures();

// Helper to record timing
function recordTiming(category, duration) {
  const arr = bgMetrics.timing[category] || (bgMetrics.timing[category] = []);
  arr.push(duration);
  // Keep last 100 measurements
  if (arr.length > 100) arr.shift();
}

// Helper to record error
function recordError(type, message) {
  if (!bgMetrics.errors[type]) {
    bgMetrics.errors[type] = { count: 0, lastMessage: '', lastTime: null };
  }
  bgMetrics.errors[type].count++;
  bgMetrics.errors[type].lastMessage = message;
  bgMetrics.errors[type].lastTime = Date.now();
}

// Helper to record request
function recordRequest(url, success, duration, type = 'capture') {
  bgMetrics.recentRequests.unshift({
    url: url?.substring(0, 100),
    success,
    duration: Math.round(duration),
    type,
    timestamp: Date.now()
  });
  // Keep last 50
  if (bgMetrics.recentRequests.length > 50) bgMetrics.recentRequests.pop();
}

// Filter cookies to essential auth-related ones to avoid HTTP 413 errors
// When there are too many cookies (100+), we filter to auth essentials only
const ESSENTIAL_COOKIE_PATTERNS = [
  // Common auth patterns
  /^(session|auth|token|jwt|sid|csrf|xsrf)/i,
  /(_session|_token|_auth|_csrf)$/i,
  // Platform-specific auth cookies
  /^ct0$/,           // Twitter auth token
  /^auth_token$/,    // Twitter
  /^twid$/,          // Twitter
  /^ds_user_id$/,    // Instagram
  /^sessionid$/,     // Instagram, Reddit
  /^reddit_session/, // Reddit
  /^loid$/,          // Reddit
  /^token$/,         // Generic
  /^access_token$/,  // OAuth
  /^refresh_token$/, // OAuth
];

function filterEssentialCookies(cookies) {
  // If under 50 cookies, send all (no risk of 413)
  if (cookies.length < 50) {
    return cookies;
  }

  // Filter to essential auth cookies only
  const essential = cookies.filter(c =>
    ESSENTIAL_COOKIE_PATTERNS.some(pattern => pattern.test(c.name))
  );

  // Debug: console.log(`[archiver-bg] Filtered ${cookies.length} cookies to ${essential.length} essential auth cookies`);
  return essential;
}

async function captureCookies(url) {
  try {
    const urlObj = new URL(url);
    let cookies = await browser.cookies.getAll({ domain: urlObj.hostname });
    const parts = urlObj.hostname.split('.');
    if (parts.length > 2) {
      cookies.push(...await browser.cookies.getAll({ domain: parts.slice(-2).join('.') }));
    }
    return filterEssentialCookies(cookies).map(cookie => ({
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain,
      path: cookie.path || '/'
    }));
  } catch {
    return [];
  }
}

async function submitCaptureIntent(intent, tab) {
  const start = performance.now();
  const targetUrl = intent.targetUrl || intent.sourcePageUrl;
  bgMetrics.requests.total++;

  try {
    const { response, receipt: serverReceipt } = await fetchWithTimeout(async (_input, { signal }) => {
      if (!serverAvailable && !(await checkServer())) {
        const error = new Error('Archive server is offline');
        error.code = 'server_offline';
        throw error;
      }
      if (signal.aborted) throw signal.reason || new Error('Capture request cancelled');
      const cookies = await captureCookies(targetUrl);
      if (signal.aborted) throw signal.reason || new Error('Capture request cancelled');
      return fetch(`${SERVER_URL}/captures`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ intent, cookies }),
        signal
      });
    }, `${SERVER_URL}/captures`, {}, CAPTURE_REQUEST_TIMEOUT_MS, async response => ({
      response,
      receipt: response.ok ? await response.json() : null
    }));
    if (!response.ok) {
      throw new Error(`Capture server returned HTTP ${response.status}`);
    }
    let receipt = serverReceipt;
    const duration = performance.now() - start;
    recordTiming('capture', duration);
    recordRequest(targetUrl, true, duration);
    const terminal = ['saved', 'completed', 'failed', 'stalled'].includes(
      String(receipt.status || '').toLowerCase()
    );
    if (receipt.jobId && !terminal) {
      try {
        await startJobPolling(receipt.jobId, targetUrl, {
          tabId: tab?.id,
          captureId: receipt.captureId || intent.captureId
        });
      } catch (error) {
        const trackingError = `Server accepted the capture, but durable job tracking could not be saved: ${error?.message || error}`;
        recordError('job-tracking', trackingError);
        receipt = { ...receipt, trackingPending: true, trackingError };
      }
    } else if (receipt.status === 'saved') {
      bgMetrics.requests.success++;
    } else if (receipt.status === 'failed') {
      bgMetrics.requests.failed++;
    }
    return receipt;
  } catch (error) {
    const duration = performance.now() - start;
    bgMetrics.requests.failed++;
    recordTiming('capture', duration);
    recordError('capture', error.message);
    recordRequest(targetUrl, false, duration);
    throw error;
  }
}

async function patchCaptureIntent(captureId, user) {
  await ensureServerEndpointBootstrapped();
  const { response, receipt } = await fetchWithTimeout(fetch, `${SERVER_URL}/captures/${encodeURIComponent(captureId)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(user)
  }, CAPTURE_PATCH_REQUEST_TIMEOUT_MS, async response => ({
    response,
    receipt: response.ok ? await response.json() : null
  }));
  if (!response.ok) throw new Error(`Could not update capture (HTTP ${response.status})`);
  return receipt;
}

async function retryCaptureIntent(captureId, intent, tab) {
  const targetUrl = intent.targetUrl || intent.sourcePageUrl;
  const { response, receipt: serverReceipt } = await fetchWithTimeout(async (_input, { signal }) => {
    if (!serverAvailable && !(await checkServer())) {
      const error = new Error('Archive server is offline');
      error.code = 'server_offline';
      throw error;
    }
    if (signal.aborted) throw signal.reason || new Error('Retry request cancelled');
    const cookies = await captureCookies(targetUrl);
    if (signal.aborted) throw signal.reason || new Error('Retry request cancelled');
    return fetch(`${SERVER_URL}/captures/${encodeURIComponent(captureId)}/retry`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cookies }),
      signal
    });
  }, `${SERVER_URL}/captures/${encodeURIComponent(captureId)}/retry`, {}, CAPTURE_REQUEST_TIMEOUT_MS, async response => {
    try {
      return { response, receipt: await response.json() };
    } catch (error) {
      if (response.ok) throw error;
      return { response, receipt: {} };
    }
  });
  if (!response.ok) {
    throw new Error(serverReceipt.detail || `Could not retry capture (HTTP ${response.status})`);
  }
  let receipt = serverReceipt;
  const terminal = ['saved', 'completed', 'failed', 'stalled'].includes(
    String(receipt.status || '').toLowerCase()
  );
  if (receipt.jobId && !terminal) {
    try {
      await startJobPolling(receipt.jobId, targetUrl, {
        tabId: tab?.id,
        captureId: receipt.captureId || captureId
      });
    } catch (error) {
      const trackingError = `Server accepted the retry, but durable job tracking could not be saved: ${error?.message || error}`;
      recordError('job-tracking', trackingError);
      receipt = { ...receipt, trackingPending: true, trackingError };
    }
  }
  return receipt;
}

function handleCaptureRuntimeState({ intent, state, tabId, receipt, error, metadata }) {
  void updateBadge();
  // startJobPolling durably registers the reconciliation pointer, but this
  // first request waits until CaptureRuntime has committed its accepted state.
  // Otherwise a very fast terminal poll can be overwritten back to accepted.
  if (receipt?.jobId && activeJobs.has(receipt.jobId)) {
    void pollJobStatus(receipt.jobId);
  }
  const durableFailure = state === 'failed'
    && /durable inbox|safe storage budget|quota_bytes|capture_inbox_capacity/i.test(error || '');
  if (durableFailure) {
    flashBadge(BADGE_COLOR_ERROR, '!');
    ignoreRuntimePromise(browser.notifications.create(`capture-inbox-${intent.captureId}`, {
      type: 'basic',
      iconUrl: 'icons/archive-48.png',
      title: 'Capture not submitted',
      message: error
    }));
  }
  if (!Number.isInteger(tabId)) return;
  void ensureCaptureAgent(tabId).then(() => {
    const result = browser.tabs.sendMessage(tabId, {
      action: metadata ? 'captureMetadata.update' : 'captureCard.update',
      captureId: receipt?.captureId || intent.captureId,
      state,
      kind: intent.kind,
      title: intent.page?.title || intent.targetUrl,
      tags: intent.user?.tags || [],
      note: intent.user?.note || '',
      disposition: receipt?.disposition,
      savedAt: receipt?.savedAt,
      error,
      metadata
    });
    if (result?.catch) result.catch(() => {});
  }).catch(() => {});
}

// Update extension icon based on server status
function updateIcon(available) {
  if (!actionApi) return;

  const path = available ? 'icons/archive' : 'icons/archive-offline';
  const result = actionApi.setIcon({
    path: {
      "16": `${path}-16.png`,
      "48": `${path}-48.png`,
      "128": `${path}-128.png`
    }
  });
  if (result && typeof result.catch === 'function') {
    result.catch(() => actionApi.setIcon({
      path: {
        "16": 'icons/icon-16.png',
        "48": 'icons/icon-48.png',
        "128": 'icons/icon-128.png'
      }
    }));
  }
}

const captureRuntime = new CaptureRuntime({
  transport: submitCaptureIntent,
  retryTransport: retryCaptureIntent,
  patchTransport: patchCaptureIntent,
  store: captureStore,
  onState: handleCaptureRuntimeState
});
extensionGlobal.CaptureRuntime = captureRuntime;

function retryDurableCaptures(states) {
  void captureRuntime.retryPending({ states }).catch(error => {
    console.warn('[nodraw] Durable capture recovery pass failed:', error?.message || error);
  });
}

async function handleServerAvailable(
  trigger,
  {
    notify = true,
    recoveryStates = ['queued', 'submitting'],
    endpointGeneration = serverEndpointGeneration
  } = {}
) {
  let queuedCaptures = 0;
  try {
    queuedCaptures = (await captureStore.list())
      .filter(record => recoveryStates.includes(record.state)).length;
  } catch {}
  // Listing the durable inbox is asynchronous. A port change during that read
  // invalidates the probe just as surely as a change during the network fetch:
  // do not announce a reconnect or submit captures to an unverified endpoint.
  if (endpointGeneration !== serverEndpointGeneration) return false;
  if (notify) {
    browser.notifications.create('server-back', {
      type: 'basic',
      iconUrl: 'icons/archive-48.png',
      title: 'Server reconnected',
      message: queuedCaptures > 0
        ? `Retrying ${queuedCaptures} saved capture(s)…`
        : 'Archive server is back online'
    });
  }
  retryDurableCaptures(recoveryStates);
  void updateBadge();
  void sendExtensionHeartbeat(trigger, true);
  return true;
}

const healthLifecycle = new HealthLifecycle({ downNotificationThreshold: 2 });

function ensureHealthLifecycleRestored() {
  if (!healthLifecycleRestorePromise) {
    const restore = browser.storage.local.get({ [HEALTH_LIFECYCLE_KEY]: null })
      .then(result => {
        healthLifecycle.restore(result[HEALTH_LIFECYCLE_KEY]);
        return true;
      });
    healthLifecycleRestorePromise = restore
      .catch(error => {
        console.warn('[nodraw] Could not restore health lifecycle:', error?.message || error);
        healthLifecycleRestorePromise = null;
        return false;
      });
  }
  return healthLifecycleRestorePromise;
}

function persistHealthLifecycle(
  snapshot = healthLifecycle.snapshot(),
  endpointGeneration = serverEndpointGeneration
) {
  return withHealthLifecyclePersistence(async () => {
    if (endpointGeneration !== serverEndpointGeneration) return false;
    try {
      await browser.storage.local.set({ [HEALTH_LIFECYCLE_KEY]: snapshot });
      return endpointGeneration === serverEndpointGeneration;
    } catch (error) {
      console.warn('[nodraw] Could not persist health lifecycle:', error?.message || error);
      return false;
    }
  });
}

async function probeServerHealth() {
  let lastError = null;
  for (let endpointAttempt = 0; endpointAttempt < 2; endpointAttempt += 1) {
    const initialUrl = SERVER_URL;
    const endpointGeneration = serverEndpointGeneration;
    try {
      const response = await fetchWithTimeout(
        fetch,
        `${initialUrl}/health`,
        {},
        HEALTH_REQUEST_TIMEOUT_MS
      );
      if (endpointGeneration !== serverEndpointGeneration) continue;
      if (!response.ok) throw new Error(`Health check returned HTTP ${response.status}`);
      return {
        available: true,
        rediscovered: false,
        endpointGeneration,
        error: null
      };
    } catch (error) {
      lastError = error;
      if (endpointGeneration !== serverEndpointGeneration) continue;
    }

    invalidateDiscoveryCache();
    try {
      const newUrl = await getServerURL();
      if (endpointGeneration !== serverEndpointGeneration) continue;
      if (newUrl !== initialUrl) {
        const response = await fetchWithTimeout(
          fetch,
          `${newUrl}/health`,
          {},
          HEALTH_REQUEST_TIMEOUT_MS
        );
        if (endpointGeneration !== serverEndpointGeneration) continue;
        if (!response.ok) throw new Error(`Health check returned HTTP ${response.status}`);
        setServerURL(newUrl);
        return {
          available: true,
          rediscovered: true,
          endpointGeneration: serverEndpointGeneration,
          error: null
        };
      }
    } catch (error) {
      lastError = error;
      if (endpointGeneration !== serverEndpointGeneration) continue;
    }
    return {
      available: false,
      rediscovered: false,
      endpointGeneration,
      error: lastError
    };
  }
  return {
    available: false,
    rediscovered: false,
    stale: true,
    error: lastError || new Error('Server endpoint changed during health check')
  };
}

// Check server availability and retry durable captures on a real state change.
function scheduleFreshServerCheck() {
  setTimeout(() => { void checkServer(); }, 0);
}

async function performServerCheck() {
  await ensureServerEndpointBootstrapped();
  if (!(await ensureHealthLifecycleRestored())) return serverAvailable;
  const start = performance.now();
  const probe = await probeServerHealth();
  if (!isCurrentHealthProbe(probe, serverEndpointGeneration)) {
    scheduleFreshServerCheck();
    return serverAvailable;
  }
  const lifecycle = healthLifecycle.record(probe.available);
  // Apply the guarded result without opening another await gap. Persistence is
  // serialized by endpoint generation; a later fresh probe always writes last.
  void persistHealthLifecycle(healthLifecycle.snapshot(), probe.endpointGeneration);
  serverAvailable = probe.available;
  updateIcon(serverAvailable);
  recordTiming('server', performance.now() - start);

  if (probe.available) {
    if (lifecycle.transition === 'initial-up') {
      const recoveryApplied = await handleServerAvailable(
        probe.rediscovered ? 'startup-rediscover' : 'startup',
        { notify: false, endpointGeneration: probe.endpointGeneration }
      );
      if (!recoveryApplied) {
        scheduleFreshServerCheck();
        return serverAvailable;
      }
    } else if (lifecycle.transition === 'reconnected') {
      const recoveryApplied = await handleServerAvailable(
        probe.rediscovered ? 'rediscover' : 'reconnect',
        { endpointGeneration: probe.endpointGeneration }
      );
      if (!recoveryApplied) {
        scheduleFreshServerCheck();
        return serverAvailable;
      }
    } else if (probe.rediscovered) {
      void sendExtensionHeartbeat('rediscover', true);
    } else {
      // A server receipt can arrive just before a browser.storage write fails.
      // Periodic health success repairs that orphaned `submitting` record even
      // when there is no reconnect transition to trigger the broader queue.
      retryDurableCaptures(['queued', 'submitting']);
    }
    if (probe.endpointGeneration !== serverEndpointGeneration) {
      scheduleFreshServerCheck();
    }
    return true;
  }

  recordError('server', probe.error?.message || 'Connection failed');
  if (lifecycle.notifyDown) {
    browser.notifications.create('server-down', {
      type: 'basic',
      iconUrl: 'icons/archive-48.png',
      title: 'Server offline',
      message: `Archive server at ${SERVER_URL} is not responding. Captures will stay in the durable inbox.`
    });
    flashBadge(BADGE_COLOR_ERROR, '!');
  }
  return false;
}

const checkServer = singleFlight(performServerCheck);
void runStartupHealthRetries();

function handleAlarm(alarm) {
  if (alarm.name === HEALTH_ALARM_NAME) {
    retryActiveJobsRestoreIfNeeded();
    void checkServer();
  } else if (alarm.name === HEARTBEAT_ALARM_NAME) {
    void sendExtensionHeartbeat('interval');
  } else if (alarm.name === JOB_POLL_ALARM_NAME) {
    retryActiveJobsRestoreIfNeeded();
    void pollActiveJobs();
  }
}

function startFallbackMaintenanceTimers({ health = true, heartbeat = true } = {}) {
  if (health && fallbackHealthTimer === null) {
    fallbackHealthTimer = setInterval(() => {
      retryActiveJobsRestoreIfNeeded();
      void checkServer();
    }, 30000);
  }
  if (heartbeat && fallbackHeartbeatTimer === null) {
    fallbackHeartbeatTimer = setInterval(() => {
      void sendExtensionHeartbeat('interval');
    }, HEARTBEAT_INTERVAL_MS);
  }
}

async function startBackgroundMaintenance() {
  // Begin the restore before any scheduling await. New jobs share the same
  // barrier, so neither side can overwrite the other's active-job snapshot.
  const restoringJobs = restoreActiveJobs();
  let healthAlarmScheduled = false;
  let heartbeatAlarmScheduled = false;
  if (alarmsApi?.onAlarm && alarmsApi?.create) {
    try {
      if (!alarmListenerInstalled) {
        alarmsApi.onAlarm.addListener(handleAlarm);
        alarmListenerInstalled = true;
      }
      const scheduled = await Promise.all([
        ensureAlarm(HEALTH_ALARM_NAME, { periodInMinutes: 0.5 }),
        ensureAlarm(HEARTBEAT_ALARM_NAME, { periodInMinutes: 1 })
      ]);
      [healthAlarmScheduled, heartbeatAlarmScheduled] = scheduled;
    } catch (error) {
      console.warn('[nodraw] Alarm scheduling unavailable; using foreground timers:', error?.message || error);
    }
  }

  // A transient sibling failure must never clear an existing valid MV3 wake
  // alarm. Fall back only for the missing capability; either surviving alarm
  // will wake a suspended worker and give startup another chance to repair it.
  if (!healthAlarmScheduled) {
    startFallbackMaintenanceTimers({ health: true, heartbeat: false });
  }
  if (!heartbeatAlarmScheduled) {
    startFallbackMaintenanceTimers({ health: false, heartbeat: true });
  }

  void checkServer();
  await restoringJobs;
  void updateBadge();
}

void startBackgroundMaintenance();

// Create context menus for right-click saving and generic downloader toggle
browser.runtime.onInstalled.addListener(() => {
  // The retired downloadQueue used URL-only records with a ten-minute TTL.
  // Its shape cannot be safely promoted to versioned CaptureIntent records.
  ignoreRuntimePromise(browser.storage.local.remove('downloadQueue'));

  browser.contextMenus.create({
    id: "save-media",
    title: "Archive this media",
    contexts: ["image", "link", "selection", "page"]
  });

  browser.contextMenus.create({
    id: "toggle-generic-downloader",
    title: "Enable image downloader for this site",
    contexts: ["page"]
  });
});

// Update context menu title based on current site's enabled status
async function updateGenericDownloaderMenu(tab) {
  if (!tab?.url) return;

  try {
    const url = new URL(tab.url);
    const host = url.hostname.replace(/^www\./, '');

    const result = await browser.storage.local.get('genericDownloaderSites');
    const sites = result.genericDownloaderSites || {};
    const isEnabled = sites[host] === true;

    browser.contextMenus.update("toggle-generic-downloader", {
      title: isEnabled
        ? `Disable image downloader for ${host}`
        : `Enable image downloader for ${host}`
    });
  } catch (e) {
    // Invalid URL or other error - hide/disable the menu
    // Silently ignore - menu update is optional
  }
}

async function injectScriptIntoTab(tabId, file) {
  if (scriptingApi?.executeScript) {
    await scriptingApi.executeScript({
      target: { tabId },
      files: [file]
    });
    return;
  }

  const executeScript = browser.tabs?.executeScript;
  if (typeof executeScript !== 'function') {
    throw new Error('Script injection is not supported by this browser');
  }
  await executeScript.call(browser.tabs, tabId, { file });
}

async function ensureCaptureAgent(tabId) {
  await injectScriptIntoTab(tabId, 'page-agent.js');
}

async function extractTabContext(tab) {
  if (!Number.isInteger(tab?.id)) return null;
  try {
    await ensureCaptureAgent(tab.id);
    return await browser.tabs.sendMessage(tab.id, { action: 'capture.extract' });
  } catch {
    return null;
  }
}

async function buildCaptureIntent(kind, targetUrl, tab, detail = {}) {
  const extracted = await extractTabContext(tab);
  const sourcePageUrl = extracted?.sourcePageUrl || tab?.url || targetUrl;
  return {
    kind,
    targetUrl,
    sourcePageUrl,
    page: {
      ...(extracted?.page || {}),
      title: detail.title || extracted?.page?.title || tab?.title || ''
    },
    media: detail.media || null,
    selection: detail.selection || (kind === 'selection' ? extracted?.selection : null),
    user: {
      tags: detail.tags || [],
      note: detail.note || ''
    },
    options: {
      saveMode: detail.saveMode || 'full',
      screenshot: detail.screenshot || '',
      platform: detail.platform || 'web'
    }
  };
}

async function enrichSubmittedIntent(rawIntent, tab) {
  const raw = rawIntent || {};
  const base = await buildCaptureIntent(raw.kind || 'page', raw.targetUrl, tab, {
    ...raw.options,
    title: raw.page?.title,
    media: raw.media,
    selection: raw.selection,
    tags: raw.user?.tags,
    note: raw.user?.note
  });
  return {
    ...base,
    ...raw,
    page: { ...base.page, ...(raw.page || {}) },
    user: { ...base.user, ...(raw.user || {}) },
    options: { ...base.options, ...(raw.options || {}) }
  };
}

// Update menu when tab changes
browser.tabs.onActivated.addListener(async (activeInfo) => {
  const tab = await browser.tabs.get(activeInfo.tabId);
  updateGenericDownloaderMenu(tab);
});

function shouldInjectGenericDownloader(tabId, changeInfo, tab, sites = {}) {
  if (!Number.isInteger(tabId) || tabId < 0 || changeInfo?.status !== 'complete') return false;

  try {
    const url = new URL(tab?.url);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;
    return sites[url.hostname.replace(/^www\./, '')] === true;
  } catch {
    return false;
  }
}

async function restoreGenericDownloader(tabId, changeInfo, tab) {
  if (changeInfo?.status !== 'complete') return;
  try {
    const result = await browser.storage.local.get('genericDownloaderSites');
    if (shouldInjectGenericDownloader(tabId, changeInfo, tab, result.genericDownloaderSites || {})) {
      await injectScriptIntoTab(tabId, 'content-generic.js');
    }
  } catch {
    // Restricted pages or a tab closed during navigation cannot be injected.
  }
}

browser.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === 'complete') {
    updateGenericDownloaderMenu(tab);
    void restoreGenericDownloader(tabId, changeInfo, tab);
  }
});

// Toggle generic downloader for a site
async function toggleGenericDownloader(tab) {
  if (!tab?.url) return;

  try {
    const url = new URL(tab.url);
    const host = url.hostname.replace(/^www\./, '');

    // Get current state
    const result = await browser.storage.local.get('genericDownloaderSites');
    const sites = result.genericDownloaderSites || {};
    const wasEnabled = sites[host] === true;
    const nowEnabled = !wasEnabled;

    // Update storage
    sites[host] = nowEnabled;
    await browser.storage.local.set({ genericDownloaderSites: sites });


    // Inject script if enabling, or notify if already injected
    if (nowEnabled) {
      // Try to inject the content script
      try {
        await injectScriptIntoTab(tab.id, 'content-generic.js');
      } catch (e) {
        // Script may already be injected - this is fine
      }
    }

    // Notify content script of state change
    try {
      await browser.tabs.sendMessage(tab.id, {
        action: 'genericDownloaderToggle',
        enabled: nowEnabled
      });
    } catch (e) {
      // Content script may not be listening - this is fine
    }

    // Update context menu
    updateGenericDownloaderMenu(tab);

    // Show notification
    browser.notifications.create({
      type: 'basic',
      iconUrl: 'icons/archive-48.png',
      title: 'Image Downloader',
      message: nowEnabled
        ? `Enabled for ${host}`
        : `Disabled for ${host}`
    });

  } catch (e) {
    console.error('[archiver-bg] Error toggling generic downloader:', e);
  }
}

async function submitCaptureSafely(intent, tab) {
  const reason = ['page', 'link'].includes(intent?.kind)
    ? collectionCaptureBlockReason(intent.targetUrl || intent.sourcePageUrl)
    : null;
  if (reason) {
    flashBadge(BADGE_COLOR_ERROR, '!');
    await browser.notifications.create('nodraw-specific-item-required', {
      type: 'basic',
      iconUrl: 'icons/archive-48.png',
      title: 'Open one item first',
      message: reason
    });
    return { success: false, blocked: true, error: reason };
  }

  return captureRuntime.submit(intent, tab);
}

async function submitDirectPageCapture(tab) {
  const intent = await buildCaptureIntent('page', tab.url, tab);
  return submitCaptureSafely(intent, tab);
}

browser.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === 'toggle-generic-downloader') {
    await toggleGenericDownloader(tab);
    return;
  }

  const kind = info.selectionText ? 'selection' : info.srcUrl ? 'media' : info.linkUrl ? 'link' : 'page';
  if (kind === 'page') {
    await submitDirectPageCapture(tab);
    return;
  }
  const targetUrl = info.srcUrl || info.linkUrl || info.pageUrl || tab.url;
  const intent = await buildCaptureIntent(kind, targetUrl, tab, {
    media: info.srcUrl ? { url: info.srcUrl, type: 'image', alt: '' } : null,
    selection: info.selectionText ? {
      text: info.selectionText,
      html: (await extractTabContext(tab))?.selection?.html || ''
    } : null
  });
  await submitCaptureSafely(intent, tab);
});

// Handle clicking the extension icon
if (actionApi?.onClicked) {
  actionApi.onClicked.addListener(async (tab) => {
    await submitDirectPageCapture(tab);
  });
}

// Handle keyboard shortcuts
browser.commands.onCommand.addListener(async (command) => {
  if (command === "quick-save") {
    const [tab] = await browser.tabs.query({active: true, currentWindow: true});
    if (tab) {
      await submitDirectPageCapture(tab);
    }
  }
});

async function blobToDataUrl(blob) {
  if (typeof FileReader !== 'undefined') {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onerror = () => reject(reader.error || new Error('Failed to read screenshot blob'));
      reader.onloadend = () => resolve(reader.result);
      reader.readAsDataURL(blob);
    });
  }

  const bytes = new Uint8Array(await blob.arrayBuffer());
  const chunkSize = 0x8000;
  let binary = '';
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return `data:${blob.type || 'application/octet-stream'};base64,${btoa(binary)}`;
}

// Capture and crop screenshot to specified bounds. captureVisibleTab(null) shoots the last
// focused window, which may be a different window from the post being saved (an X save on
// 2026-10-02 got a YouTube tab from another window), so aim at the sender's own window and
// give up rather than attach another tab's picture.
async function captureScreenshot(tabId, bounds) {
  const start = performance.now();
  try {
    if (tabId == null) throw new Error('screenshot request has no sender tab');
    const tab = await browser.tabs.get(tabId);
    if (!tab.active) throw new Error('sender tab is not the visible tab in its window');
    const dataUrl = await browser.tabs.captureVisibleTab(tab.windowId, {
      format: 'png'
    });
    const after = await browser.tabs.get(tabId);
    if (!after.active || after.windowId !== tab.windowId) throw new Error('sender tab changed during capture');

    if (!bounds) {
      recordTiming('screenshot', performance.now() - start);
      return dataUrl;
    }

    const img = await createImageBitmap(await (await fetch(dataUrl)).blob());
    const canvas = new OffscreenCanvas(bounds.width, bounds.height);
    const ctx = canvas.getContext('2d');
    const sourceY = bounds.viewportY * (bounds.dpr || 1);

    ctx.drawImage(
      img,
      bounds.x, sourceY, bounds.width, bounds.height,
      0, 0, bounds.width, bounds.height
    );
    img.close(); // Release GPU memory

    const blob = await canvas.convertToBlob({ type: 'image/png' });
    const result = await blobToDataUrl(blob);

    recordTiming('screenshot', performance.now() - start);
    return result;
  } catch (error) {
    recordError('screenshot', error.message);
    console.error('Screenshot capture error:', error);
    return null;
  }
}

// Message handler for content scripts
browser.runtime.onMessage.addListener((request, sender, sendResponse) => {

  if (request.action === 'captureScreenshot') {
    captureScreenshot(sender.tab?.id, request.bounds)
      .then(screenshot => sendResponse({ screenshot }))
      .catch(error => sendResponse({ screenshot: null, error: error.message }));
    return true;
  }

  if (request.action === 'capture.submit') {
    const tab = sender.tab || request.tab;
    enrichSubmittedIntent(request.intent, tab)
      .then(intent => submitCaptureSafely(intent, tab))
      .then(sendResponse)
      .catch(error => sendResponse({ success: false, error: error.message }));
    return true;
  }

  if (request.action === 'capture.patch') {
    captureRuntime.patch(request.captureId, { tags: request.tags, note: request.note }, sender.tab)
      .then(sendResponse)
      .catch(error => sendResponse({ success: false, error: error.message }));
    return true;
  }

  if (request.action === 'capture.metadata.stage') {
    captureRuntime.stageMetadata(request.captureId, request.fields)
      .then(() => sendResponse({ success: true }))
      .catch(error => sendResponse({ success: false, error: error.message }));
    return true;
  }

  if (request.action === 'capture.get') {
    captureRuntime.get(request.captureId).then(capture => sendResponse({ capture }))
      .catch(error => sendResponse({ success: false, error: error.message }));
    return true;
  }

  if (request.action === 'capture.list') {
    captureRuntime.list().then(captures => sendResponse({ captures }));
    return true;
  }

  if (request.action === 'capture.retry') {
    captureRuntime.retry(request.captureId, sender.tab)
      .then(sendResponse)
      .catch(error => sendResponse({ success: false, error: error.message }));
    return true;
  }

  if (request.action === 'capture.dismiss') {
    captureRuntime.dismiss(request.captureId).then(() => sendResponse({ success: true }));
    return true;
  }

  if (request.action === 'capture.open') {
    ensureServerEndpointBootstrapped()
      .then(url => browser.tabs.create({ url: `${url}/dashboard` }))
      .then(() => sendResponse({ success: true }))
      .catch(error => sendResponse({ success: false, error: error.message }));
    return true;
  }

  if (request.action === 'checkServer') {
    checkServer()
      .then(available => sendResponse({ available }))
      .catch(error => sendResponse({ available: false, error: error.message }));
    return true;
  }

  if (request.action === 'getJobs') {
    ensureServerEndpointBootstrapped()
      .then(url => fetch(`${url}/jobs?limit=50`))
      .then(r => r.json())
      .then(sendResponse)
      .catch(error => sendResponse({error: error.message}));
    return true;
  }

  if (request.action === 'checkArchived') {
    ensureServerEndpointBootstrapped()
      .then(url => fetch(`${url}/check-archived`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          url: request.url,
          check_file_exists: true
        })
      }))
      .then(r => r.json())
      .then(sendResponse)
      .catch(error => sendResponse({ archived: false, error: error.message }));
    return true;
  }

  // Debug panel handlers
  if (request.action === 'getMetrics') {
    // Calculate averages for timing data
    const calcAvg = arr => arr.length ? Math.round(arr.reduce((a, b) => a + b, 0) / arr.length) : 0;
    const calcMax = arr => arr.length ? Math.round(Math.max(...arr)) : 0;
    const calcMin = arr => arr.length ? Math.round(Math.min(...arr)) : 0;

    const timingStats = {};
    for (const [key, values] of Object.entries(bgMetrics.timing)) {
      timingStats[key] = {
        count: values.length,
        avg: calcAvg(values),
        min: calcMin(values),
        max: calcMax(values)
      };
    }

    sendResponse({
      metrics: {
        requests: bgMetrics.requests,
        timing: timingStats,
        errors: bgMetrics.errors,
        recentFailures: bgMetrics.recentFailures,
        recentRequests: bgMetrics.recentRequests
      },
      uptime: Date.now() - bgMetrics.startTime,
      serverAvailable: serverAvailable
    });
    return true;
  }

  if (request.action === 'resetMetrics') {
    bgMetrics.requests = { total: 0, success: 0, failed: 0 };
    bgMetrics.timing = { capture: [], screenshot: [], server: [] };
    bgMetrics.errors = {};
    bgMetrics.recentFailures = [];
    bgMetrics.recentRequests = [];
    bgMetrics.startTime = Date.now();
    browser.storage.local.remove(RECENT_FAILURES_KEY).catch(() => {});
    sendResponse({ success: true });
    return true;
  }

  if (request.action === 'getActiveJobs') {
    const jobs = [];
    for (const [id, job] of activeJobs) {
      jobs.push({
        id,
        url: job.url,
        elapsed: Math.round((Date.now() - job.startTime) / 1000)
      });
    }
    sendResponse({ activeJobs: jobs });
    return true;
  }

  if (request.action === 'getDebugMode') {
    browser.storage.local.get(DEBUG_STORAGE_KEYS).then(result => {
      const debugMode = typeof result.debugMode === 'boolean'
        ? result.debugMode
        : typeof result.archiver_debug_mode === 'boolean'
          ? result.archiver_debug_mode
          : DEBUG_DEFAULT_ENABLED;
      sendResponse({ debugMode });
    });
    return true;
  }

  if (request.action === 'setDebugMode') {
    const enabled = request.enabled === true;
    browser.storage.local.set({
      debugMode: enabled,
      archiver_debug_mode: enabled
    }).then(() => {
      sendResponse({ success: true, debugMode: enabled });
    });
    return true;
  }
});
