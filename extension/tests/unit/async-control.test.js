import assert from 'node:assert/strict';
import test from 'node:test';

import {
  allSettledBounded,
  fetchWithTimeout,
  normalizeRestoredJobs,
  reconcileTrackedJob
} from '../../src/runtime/async-control.js';

test('fetchWithTimeout aborts a hung request at its deadline', async () => {
  let observedSignal = null;
  const hangingFetch = (_input, init) => new Promise((_resolve, reject) => {
    observedSignal = init.signal;
    init.signal.addEventListener('abort', () => {
      const genericAbort = new Error('The operation was aborted');
      genericAbort.name = 'AbortError';
      reject(genericAbort);
    }, { once: true });
  });

  await assert.rejects(
    fetchWithTimeout(hangingFetch, 'http://localhost/health', {}, 5),
    error => error?.name === 'TimeoutError'
  );
  assert.equal(observedSignal.aborted, true);
});

test('fetchWithTimeout forwards caller cancellation and clears the deadline', async () => {
  const source = new AbortController();
  const cancelledFetch = (_input, init) => new Promise((_resolve, reject) => {
    init.signal.addEventListener('abort', () => reject(init.signal.reason), { once: true });
  });
  const request = fetchWithTimeout(cancelledFetch, 'http://localhost/jobs/1', { signal: source.signal }, 1000);
  source.abort(new Error('caller cancelled'));

  await assert.rejects(request, /caller cancelled/);
});

test('fetchWithTimeout applies its deadline while the response body is consumed', async () => {
  let responseReturned = false;
  await assert.rejects(
    fetchWithTimeout(
      async () => {
        responseReturned = true;
        return { ok: true };
      },
      'http://localhost/jobs/body-hang',
      {},
      5,
      async () => new Promise(() => {})
    ),
    error => error?.name === 'TimeoutError'
  );
  assert.equal(responseReturned, true);
});

test('job polling bounds a hung response body and leaves the job retryable', async () => {
  const result = await reconcileTrackedJob({
    fetchImplementation: async () => ({
      ok: true,
      status: 200,
      json: async () => new Promise(() => {})
    }),
    requestUrl: 'http://localhost:8847/jobs/hung-body',
    requestTimeoutMs: 5,
    trackedJob: { jobId: 'hung-body', startTime: 0, lastConfirmedAt: 350_000 },
    now: 400_000,
    unconfirmedTimeoutMs: 300_000
  });

  assert.equal(result.action, 'retain');
  assert.equal(result.confirmed, false);
  assert.match(result.reason, /timed out/i);
});

test('allSettledBounded starts independent work without exceeding its limit', async () => {
  let active = 0;
  let peak = 0;
  const started = [];
  const releases = [];
  const gate = () => new Promise(resolve => releases.push(resolve));

  const work = allSettledBounded([1, 2, 3, 4, 5], 2, async value => {
    active += 1;
    peak = Math.max(peak, active);
    started.push(value);
    await gate();
    active -= 1;
    if (value === 3) throw new Error('isolated failure');
    return value * 2;
  });

  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(started, [1, 2]);
  while (releases.length > 0 || started.length < 5) {
    releases.shift()?.();
    await new Promise(resolve => setImmediate(resolve));
  }
  const results = await work;

  assert.equal(peak, 2);
  assert.equal(results.length, 5);
  assert.equal(results[2].status, 'rejected');
  assert.deepEqual(started, [1, 2, 3, 4, 5]);
});

test('normalizeRestoredJobs restores old jobs for server reconciliation', () => {
  const now = 10_000;
  const result = normalizeRestoredJobs([
    { jobId: 'current', url: 'https://example.com/current', startTime: 9_000 },
    { jobId: 'expired', url: 'https://example.com/expired', startTime: 1_000, captureId: 'capture-expired' },
    { jobId: 'missing-url', startTime: 9_500 }
  ], now);

  assert.deepEqual(result.restorable.map(job => job.jobId), ['current', 'expired']);
  assert.equal(result.restorable[1].lastConfirmedAt, 1_000);
  assert.equal(result.restorable[1].captureId, 'capture-expired');
  assert.equal(result.invalid.length, 1);
});

test('a job older than five minutes is queried and retained when still downloading', async () => {
  let requests = 0;
  const result = await reconcileTrackedJob({
    fetchImplementation: async () => {
      requests += 1;
      return {
        ok: true,
        status: 200,
        json: async () => ({ status: 'downloading', progress: 0.72 })
      };
    },
    requestUrl: 'http://localhost:8847/jobs/long-running',
    requestTimeoutMs: 50,
    trackedJob: {
      jobId: 'long-running',
      startTime: 0,
      lastConfirmedAt: 0
    },
    now: 600_001,
    unconfirmedTimeoutMs: 300_000
  });

  assert.equal(requests, 1);
  assert.equal(result.action, 'retain');
  assert.equal(result.confirmed, true);
  assert.equal(result.observedAt, 600_001);
  assert.equal(result.payload.status, 'downloading');
});

test('an old unreachable job becomes stalled after the unconfirmed window', async () => {
  let requests = 0;
  const result = await reconcileTrackedJob({
    fetchImplementation: async () => {
      requests += 1;
      throw new TypeError('server unreachable');
    },
    requestUrl: 'http://localhost:8847/jobs/unreachable',
    requestTimeoutMs: 50,
    trackedJob: {
      jobId: 'unreachable',
      startTime: 0,
      lastConfirmedAt: 100_000
    },
    now: 400_000,
    unconfirmedTimeoutMs: 300_000
  });

  assert.equal(requests, 1);
  assert.equal(result.action, 'stalled');
  assert.equal(result.confirmed, false);
  assert.equal(result.unconfirmedForMs, 300_000);
  assert.match(result.reason, /server unreachable.*unconfirmed/i);
});

test('recently confirmed jobs survive a transient status outage', async () => {
  const result = await reconcileTrackedJob({
    fetchImplementation: async () => { throw new TypeError('temporary outage'); },
    requestUrl: 'http://localhost:8847/jobs/recent',
    requestTimeoutMs: 50,
    trackedJob: {
      jobId: 'recent',
      startTime: 0,
      lastConfirmedAt: 350_000
    },
    now: 400_000,
    unconfirmedTimeoutMs: 300_000
  });

  assert.equal(result.action, 'retain');
  assert.equal(result.confirmed, false);
  assert.equal(result.unconfirmedForMs, 50_000);
});

test('terminal server completion and failure are reconciled exactly', async () => {
  async function observe(status) {
    return reconcileTrackedJob({
      fetchImplementation: async () => ({
        ok: true,
        status: 200,
        json: async () => ({ status, file_path: status === 'completed' ? '/archive/item.jpg' : null })
      }),
      requestUrl: `http://localhost:8847/jobs/${status}`,
      requestTimeoutMs: 50,
      trackedJob: { jobId: status, startTime: 0, lastConfirmedAt: 0 },
      now: 600_001,
      unconfirmedTimeoutMs: 300_000
    });
  }

  const [completed, failed] = await Promise.all([observe('completed'), observe('failed')]);
  assert.equal(completed.action, 'completed');
  assert.equal(completed.payload.file_path, '/archive/item.jpg');
  assert.equal(failed.action, 'failed');
});

test('an explicit missing server job stalls without waiting for the outage window', async () => {
  const result = await reconcileTrackedJob({
    fetchImplementation: async () => ({ ok: false, status: 404 }),
    requestUrl: 'http://localhost:8847/jobs/missing',
    requestTimeoutMs: 50,
    trackedJob: { jobId: 'missing', startTime: 390_000, lastConfirmedAt: 390_000 },
    now: 400_000,
    unconfirmedTimeoutMs: 300_000
  });

  assert.equal(result.action, 'stalled');
  assert.equal(result.confirmed, true);
  assert.match(result.reason, /no longer has job missing/i);
});
