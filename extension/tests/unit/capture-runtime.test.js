import assert from 'node:assert/strict';
import test from 'node:test';

import { CaptureRuntime } from '../../src/runtime/capture-runtime.js';
import { CaptureStore } from '../../src/runtime/capture-store.js';

class FakeStorage {
  constructor({ failSet = null } = {}) {
    this.values = {};
    this.setCalls = [];
    this.failSet = failSet;
  }
  async get(defaults) {
    return Object.fromEntries(Object.entries(defaults).map(([key, fallback]) => [
      key, key in this.values ? structuredClone(this.values[key]) : fallback
    ]));
  }
  async set(update) {
    if (this.failSet) throw this.failSet;
    const copy = structuredClone(update);
    this.setCalls.push(copy);
    Object.assign(this.values, copy);
  }
}

function rawIntent(captureId) {
  return {
    captureId,
    kind: 'page',
    targetUrl: 'https://example.com/post',
    sourcePageUrl: 'https://example.com/post',
    createdAt: '2026-01-01T00:00:00.000Z'
  };
}

function runtimeWith(overrides = {}) {
  return new CaptureRuntime({
    ...overrides
  });
}

test('metadata patches preserve omitted fields in transport and durable inbox', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put({ ...rawIntent('metadata-1'), user: { tags: ['old'], note: 'keep' } }, 'saved');
  let submitted;
  const runtime = runtimeWith({ store, patchTransport: async (_id, patch) => {
    submitted = patch;
    return { captureId: 'metadata-1', status: 'saved', metadataProjection: 'applied' };
  } });
  const result = await runtime.patch('metadata-1', { tags: ['new'], note: undefined });
  assert.deepEqual(submitted.tags, ['new']);
  assert.equal(typeof submitted.mutationId, 'string');
  assert.equal('note' in submitted, false);
  assert.deepEqual((await store.get('metadata-1')).intent.user, { tags: ['new'], note: 'keep' });
  assert.equal(result.success, true);
});

test('metadata projection failure never reclassifies saved media as failed capture', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put(rawIntent('metadata-1'), 'saved');
  const runtime = runtimeWith({ store, patchTransport: async () => ({
    captureId: 'metadata-1', status: 'saved', metadataProjection: 'failed', metadataError: 'Disk read-only'
  }) });
  const result = await runtime.patch('metadata-1', { note: 'pending' });
  assert.equal(result.success, false);
  assert.equal(result.metadata_pending, true);
  assert.equal(result.error, 'Disk read-only');
  const record = await store.get('metadata-1');
  assert.equal(record.state, 'saved');
  assert.equal(record.intent.user.note, 'pending');
});

test('metadata transports serialize by capture, recover after rejection, and release their lane', async () => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const calls = [];
  const store = new CaptureStore(new FakeStorage());
  await store.put(rawIntent('one'), 'saved');
  await store.put(rawIntent('two'), 'saved');
  let failed = false;
  const runtime = runtimeWith({ store, patchTransport: async (id, patch) => {
    calls.push([id, patch]);
    if (patch.note === 'first' && !failed) { await gate; failed = true; throw new Error('Offline'); }
    return { status: 'saved' };
  } });
  const first = runtime.patch('one', { note: 'first' });
  const second = runtime.patch('one', { note: 'second' });
  await runtime.patch('two', { note: 'independent' });
  assert.deepEqual(calls.map(call => call[1].note), ['first', 'independent']);
  release();
  assert.equal((await first).error, 'Offline');
  assert.equal((await second).success, true);
  assert.deepEqual(calls.map(call => call[1].note), ['first', 'independent', 'first', 'second']);
  assert.equal(calls[0][1].mutationId, calls[2][1].mutationId);
  assert.equal(runtime._metadataPatches.size, 0);
});

test('metadata acceptance followed by quota ACK failure survives restart with the same token then empty projection retry', async () => {
  const storage = new FakeStorage();
  const store = new CaptureStore(storage);
  await store.put(rawIntent('one'), 'saved');
  const calls = [];
  const transport = async (_id, patch) => {
    calls.push(patch);
    if (calls.length === 1) storage.failSet = new Error('Quota after acceptance');
    return { status: 'saved', metadataProjection: 'failed', metadataError: 'Conflicting file note', metadataMutationId: patch.mutationId, metadataRevision: 1 };
  };
  const first = runtimeWith({ store, patchTransport: transport });
  const failed = await first.patch('one', { note: 'wanted' });
  assert.equal(failed.metadata_pending, true);
  assert.match(failed.error, /Quota/);
  assert.equal((await store.get('one')).metadata.pending.fields.note, 'wanted');
  storage.failSet = null;
  const restarted = runtimeWith({ store: new CaptureStore(storage), patchTransport: transport });
  await restarted.patch('one', {});
  assert.deepEqual(calls[0], calls[1]);
  assert.equal((await store.get('one')).metadata.pending, null);
  assert.equal((await store.get('one')).metadata.receipt.metadataProjection, 'failed');
  await restarted.patch('one', {});
  assert.deepEqual(calls[2], {});
  assert.equal((await store.get('one')).state, 'saved');
});

test('metadata quota rejects before network and preserves old saved user values', async () => {
  const storage = new FakeStorage();
  const store = new CaptureStore(storage, { budgetBytes: 1800 });
  await store.put({ ...rawIntent('one'), user: { note: 'original' } }, 'saved');
  let sends = 0;
  const runtime = runtimeWith({ store, patchTransport: async () => { sends++; } });
  await assert.rejects(runtime.patch('one', { note: 'x'.repeat(2000) }), /safe storage budget/);
  assert.equal(sends, 0);
  assert.equal((await store.get('one')).intent.user.note, 'original');
});

test('new draft while accepted mutation is awaiting ACK remains revision-safe and durable', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put(rawIntent('one'), 'saved');
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  let started;
  const ready = new Promise(resolve => { started = resolve; });
  const calls = [];
  const runtime = runtimeWith({ store, patchTransport: async (_id, patch) => {
    calls.push(patch);
    if (calls.length === 1) { started(); await gate; }
    return { status: 'saved', metadataProjection: 'applied', metadataMutationId: patch.mutationId };
  } });
  const sending = runtime.patch('one', { note: 'first' });
  await ready;
  await runtime.stageMetadata('one', { note: 'newest' });
  release();
  await sending;
  assert.deepEqual(calls.map(patch => patch.note), ['first', 'newest']);
  assert.notEqual(calls[0].mutationId, calls[1].mutationId);
  const record = await store.get('one');
  assert.equal(record.intent.user.note, 'newest');
  assert.deepEqual(record.metadata.draft, {});
  assert.equal(record.metadata.pending, null);
});

test('queued captures retry as first submissions because the server has no job yet', async () => {
  const store = new CaptureStore(new FakeStorage());
  const intent = rawIntent('queued-1');
  await store.put(intent, 'queued');
  let submits = 0;
  let retries = 0;
  const runtime = runtimeWith({
    store,
    transport: async submitted => {
      submits += 1;
      return { captureId: submitted.captureId, jobId: 'job-1', disposition: 'accepted', status: 'accepted' };
    },
    retryTransport: async () => { retries += 1; }
  });

  const result = await runtime.retry('queued-1');
  assert.equal(result.success, true);
  assert.equal(submits, 1);
  assert.equal(retries, 0);
});

test('server-failed captures use the explicit retry transport', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put(rawIntent('failed-1'), 'failed');
  await store.transition('failed-1', 'failed', { jobId: 'job-failed' });
  let retries = 0;
  const runtime = runtimeWith({
    store,
    transport: async () => { throw new Error('normal submit should not run'); },
    retryTransport: async captureId => {
      retries += 1;
      return { captureId, jobId: 'job-failed', disposition: 'accepted', status: 'accepted' };
    }
  });

  const result = await runtime.retry('failed-1');
  assert.equal(result.success, true);
  assert.equal(retries, 1);
  assert.equal((await store.get('failed-1')).state, 'accepted');
});

test('server-side retry preserves legacy screenshot context until acceptance', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put({
    ...rawIntent('failed-with-screenshot'),
    options: { screenshot: 'data:image/png;base64,legacy-server-retry' }
  }, 'failed');
  await store.transition('failed-with-screenshot', 'failed', { jobId: 'job-with-screenshot' });
  let retryScreenshot = null;
  const runtime = runtimeWith({
    store,
    transport: async () => { throw new Error('normal submit should not run'); },
    retryTransport: async (captureId, retryIntent) => {
      retryScreenshot = retryIntent.options.screenshot;
      assert.equal(
        (await store.get(captureId)).intent.options.screenshot,
        'data:image/png;base64,legacy-server-retry'
      );
      return { captureId, jobId: 'job-with-screenshot', disposition: 'accepted', status: 'accepted' };
    }
  });

  const result = await runtime.retry('failed-with-screenshot');
  assert.equal(result.success, true);
  assert.equal(retryScreenshot, 'data:image/png;base64,legacy-server-retry');
  assert.equal((await store.get('failed-with-screenshot')).intent.options.screenshot, '');
});

test('fingerprint duplicates adopt the server capture identity and retain failed state', async () => {
  const store = new CaptureStore(new FakeStorage());
  const runtime = runtimeWith({
    store,
    transport: async () => ({
      captureId: 'capture-original',
      jobId: 'job-original',
      disposition: 'duplicate',
      status: 'failed'
    })
  });

  const result = await runtime.submit(rawIntent('capture-new'));
  assert.equal(result.success, false);
  assert.equal(result.status, 'failed');
  assert.equal(result.retryable, true);
  assert.match(result.error, /capture failed/i);
  assert.equal(await store.get('capture-new'), null);
  const canonical = await store.get('capture-original');
  assert.equal(canonical.state, 'failed');
  assert.equal(canonical.retryable, true);
  assert.equal(canonical.jobId, 'job-original');
});

test('screenshots remain durable until transport acceptance, then are stripped', async () => {
  const storage = new FakeStorage();
  const store = new CaptureStore(storage);
  let transportedScreenshot = null;
  const runtime = runtimeWith({
    store,
    transport: async submitted => {
      transportedScreenshot = submitted.options.screenshot;
      assert.equal(
        storage.values.captureInboxV1[0].intent.options.screenshot,
        'data:image/png;base64,very-large-payload',
        'the retry payload must be durable while the first POST is in flight'
      );
      return {
        captureId: submitted.captureId,
        jobId: 'job-screenshot',
        disposition: 'accepted',
        status: 'accepted'
      };
    }
  });

  await runtime.submit({
    ...rawIntent('capture-screenshot'),
    options: { screenshot: 'data:image/png;base64,very-large-payload' }
  });

  assert.equal(transportedScreenshot, 'data:image/png;base64,very-large-payload');
  assert.equal((await store.get('capture-screenshot')).intent.options.screenshot, '');
  assert.equal(storage.setCalls[0].captureInboxV1[0].intent.options.screenshot, 'data:image/png;base64,very-large-payload');
  assert.equal(storage.setCalls.at(-1).captureInboxV1[0].intent.options.screenshot, '');
  assert.equal(storage.setCalls.length, 2, 'submit writes the initial record and final state only');
});

test('a terminal state observed before the receipt cannot regress to accepted', async () => {
  const store = new CaptureStore(new FakeStorage());
  const runtime = runtimeWith({
    store,
    transport: async submitted => {
      await store.transition(submitted.captureId, 'saved', {
        filePath: '/archive/fast-result.jpg',
        retryable: false
      });
      return {
        captureId: submitted.captureId,
        jobId: 'fast-job',
        disposition: 'accepted',
        status: 'accepted'
      };
    }
  });

  const result = await runtime.submit(rawIntent('fast-terminal'));
  const record = await store.get('fast-terminal');
  assert.equal(result.success, true);
  assert.equal(result.status, 'saved');
  assert.equal(record.state, 'saved');
  assert.equal(record.filePath, '/archive/fast-result.jpg');
});

test('accepted receipt with failed pointer persistence remains durably retryable', async () => {
  const store = new CaptureStore(new FakeStorage());
  const runtime = runtimeWith({
    store,
    transport: async submitted => ({
      captureId: submitted.captureId,
      jobId: 'untracked-job',
      disposition: 'accepted',
      status: 'accepted',
      trackingPending: true,
      trackingError: 'Server accepted the capture, but durable job tracking could not be saved'
    })
  });

  const result = await runtime.submit({
    ...rawIntent('untracked-accepted'),
    options: { screenshot: 'data:image/png;base64,reconcile-me' }
  });
  const record = await store.get('untracked-accepted');
  assert.equal(result.success, false);
  assert.equal(result.queued, true);
  assert.equal(result.retryable, true);
  assert.match(result.error, /job tracking could not be saved/i);
  assert.equal(record.state, 'queued');
  assert.equal(record.jobId, 'untracked-job');
  assert.equal(record.intent.options.screenshot, 'data:image/png;base64,reconcile-me');
});

test('queued captures retry with the original screenshot and strip it after acceptance', async () => {
  const store = new CaptureStore(new FakeStorage());
  const offline = new TypeError('fetch failed');
  const transportedScreenshots = [];
  let offlineAttempt = true;
  const runtime = runtimeWith({
    store,
    transport: async submitted => {
      transportedScreenshots.push(submitted.options.screenshot);
      if (offlineAttempt) {
        offlineAttempt = false;
        throw offline;
      }
      return {
        captureId: submitted.captureId,
        jobId: 'job-retried-screenshot',
        disposition: 'accepted',
        status: 'accepted'
      };
    }
  });

  const first = await runtime.submit({
    ...rawIntent('queued-screenshot'),
    options: { screenshot: 'data:image/png;base64,retry-payload' }
  });

  assert.equal(first.queued, true);
  assert.equal(
    (await store.get('queued-screenshot')).intent.options.screenshot,
    'data:image/png;base64,retry-payload'
  );

  const retried = await runtime.retry('queued-screenshot');
  assert.equal(retried.success, true);
  assert.deepEqual(transportedScreenshots, [
    'data:image/png;base64,retry-payload',
    'data:image/png;base64,retry-payload'
  ]);
  assert.equal((await store.get('queued-screenshot')).intent.options.screenshot, '');
});

test('durable storage failure is surfaced and prevents a non-retryable submission', async () => {
  const storage = new FakeStorage({ failSet: new Error('QUOTA_BYTES exceeded') });
  const store = new CaptureStore(storage);
  let transports = 0;
  const states = [];
  const runtime = runtimeWith({
    store,
    transport: async () => { transports += 1; },
    onState: update => states.push(update)
  });

  const result = await runtime.submit({
    ...rawIntent('quota-screenshot'),
    options: { screenshot: 'data:image/png;base64,too-large' }
  });

  assert.equal(result.success, false);
  assert.equal(result.queued, false);
  assert.equal(result.storage_error, true);
  assert.match(result.error, /durable inbox.*QUOTA_BYTES exceeded/i);
  assert.equal(transports, 0);
  assert.equal(states.at(-1).state, 'failed');
  assert.match(states.at(-1).error, /durable inbox/i);
});

test('server acceptance remains successful but warns when local cleanup cannot be persisted', async () => {
  const storage = new FakeStorage();
  const normalSet = storage.set.bind(storage);
  let writes = 0;
  storage.set = async update => {
    writes += 1;
    if (writes === 2) throw new Error('local cleanup failed');
    return normalSet(update);
  };
  const store = new CaptureStore(storage);
  const runtime = runtimeWith({
    store,
    transport: async submitted => ({
      captureId: submitted.captureId,
      jobId: 'job-accepted-storage-warning',
      disposition: 'accepted',
      status: 'accepted'
    })
  });

  const result = await runtime.submit({
    ...rawIntent('accepted-storage-warning'),
    options: { screenshot: 'data:image/png;base64,preserved-until-cleanup' }
  });

  assert.equal(result.success, true);
  assert.equal(result.storage_error, true);
  assert.match(result.warning, /server accepted.*local inbox state/i);
  assert.equal(
    (await store.get('accepted-storage-warning')).intent.options.screenshot,
    'data:image/png;base64,preserved-until-cleanup'
  );
});

test('offline response is not labeled queued when its retry state cannot be stored', async () => {
  const storage = new FakeStorage();
  const normalSet = storage.set.bind(storage);
  let writes = 0;
  storage.set = async update => {
    writes += 1;
    if (writes === 2) throw new Error('state write failed');
    return normalSet(update);
  };
  const store = new CaptureStore(storage);
  const states = [];
  const runtime = runtimeWith({
    store,
    transport: async () => { throw new TypeError('server offline'); },
    onState: update => states.push(update)
  });

  const result = await runtime.submit({
    ...rawIntent('offline-state-storage-failure'),
    options: { screenshot: 'data:image/png;base64,still-durable' }
  });

  assert.equal(result.success, false);
  assert.equal(result.queued, false);
  assert.equal(result.storage_error, true);
  assert.match(result.error, /server offline.*durable inbox/i);
  assert.equal(states.at(-1).state, 'failed');
  assert.equal(
    (await store.get('offline-state-storage-failure')).intent.options.screenshot,
    'data:image/png;base64,still-durable'
  );
});

test('capture timeout becomes a durable queued retry instead of indefinite submitting', async () => {
  const store = new CaptureStore(new FakeStorage());
  const timeout = new Error('Capture request timed out after 30000ms');
  timeout.name = 'TimeoutError';
  const runtime = runtimeWith({
    store,
    transport: async () => { throw timeout; }
  });

  const result = await runtime.submit({
    ...rawIntent('capture-timeout'),
    options: { screenshot: 'data:image/png;base64,timeout-context' }
  });

  assert.equal(result.success, false);
  assert.equal(result.queued, true);
  assert.match(result.error, /timed out.*inbox for retry/i);
  const stored = await store.get('capture-timeout');
  assert.equal(stored.state, 'queued');
  assert.equal(stored.retryable, true);
  assert.equal(stored.intent.options.screenshot, 'data:image/png;base64,timeout-context');
});

test('timed-out server retry remains queued and uses the retry endpoint again', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put({
    ...rawIntent('retry-timeout'),
    options: { screenshot: 'data:image/png;base64,retry-timeout-context' }
  }, 'failed');
  await store.transition('retry-timeout', 'failed', { jobId: 'retry-timeout-job' });
  let attempts = 0;
  const runtime = runtimeWith({
    store,
    transport: async () => { throw new Error('initial transport must not run'); },
    retryTransport: async captureId => {
      attempts += 1;
      if (attempts === 1) {
        const timeout = new Error('Retry timed out after 30000ms');
        timeout.name = 'TimeoutError';
        throw timeout;
      }
      return { captureId, jobId: 'retry-timeout-job', status: 'saved' };
    }
  });

  const timedOut = await runtime.retry('retry-timeout');
  assert.equal(timedOut.queued, true);
  assert.equal((await store.get('retry-timeout')).state, 'queued');
  const recovered = await runtime.retry('retry-timeout');
  assert.equal(recovered.success, true);
  assert.equal(attempts, 2);
  assert.equal((await store.get('retry-timeout')).state, 'saved');
});

test('retry terminal receipts map to saved or failed without false accepted state', async () => {
  async function exercise(status) {
    const store = new CaptureStore(new FakeStorage());
    await store.put({
      ...rawIntent(`terminal-${status}`),
      options: { screenshot: `data:image/png;base64,${status}` }
    }, 'failed');
    await store.transition(`terminal-${status}`, 'failed', { jobId: `job-${status}` });
    const runtime = runtimeWith({
      store,
      transport: async () => { throw new Error('initial transport must not run'); },
      retryTransport: async captureId => ({ captureId, jobId: `job-${status}`, status })
    });
    const response = await runtime.retry(`terminal-${status}`);
    return { response, record: await store.get(`terminal-${status}`) };
  }

  const saved = await exercise('saved');
  const failed = await exercise('failed');
  assert.equal(saved.response.success, true);
  assert.equal(saved.response.status, 'saved');
  assert.equal(saved.record.state, 'saved');
  assert.equal(saved.record.intent.options.screenshot, '');
  assert.equal(failed.response.success, false);
  assert.equal(failed.response.status, 'failed');
  assert.equal(failed.response.retryable, true);
  assert.match(failed.response.error, /capture failed/i);
  assert.equal(failed.record.state, 'failed');
  assert.equal(failed.record.retryable, true);
  assert.equal(failed.record.intent.options.screenshot, 'data:image/png;base64,failed');
});

test('startup recovery retries orphaned submitting records', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put(rawIntent('orphaned-submitting'), 'submitting');
  let submissions = 0;
  const runtime = runtimeWith({
    store,
    transport: async intent => {
      submissions += 1;
      return { captureId: intent.captureId, jobId: 'recovered-job', status: 'accepted' };
    }
  });

  const results = await runtime.retryPending();
  assert.equal(results.length, 1);
  assert.equal(submissions, 1);
  assert.equal((await store.get('orphaned-submitting')).state, 'accepted');
});

test('one malformed legacy capture cannot starve later startup recovery', async () => {
  const storage = new FakeStorage();
  storage.values.captureInboxV1 = [
    {
      captureId: 'malformed-first',
      state: 'submitting',
      intent: { captureId: 'malformed-first', kind: 'page', targetUrl: '' }
    },
    {
      captureId: 'healthy-second',
      state: 'submitting',
      intent: rawIntent('healthy-second')
    }
  ];
  const store = new CaptureStore(storage);
  let submissions = 0;
  const runtime = runtimeWith({
    store,
    transport: async intent => {
      submissions += 1;
      return { captureId: intent.captureId, jobId: 'healthy-job', status: 'accepted' };
    }
  });

  const results = await runtime.retryPending();
  assert.equal(results.length, 2);
  assert.equal(results[0].success, false);
  assert.equal(results[1].success, true);
  assert.equal(submissions, 1);
  assert.equal((await store.get('malformed-first')).state, 'failed');
  assert.equal((await store.get('healthy-second')).state, 'accepted');
});

test('recovery does not duplicate a submitting capture still in flight', async () => {
  const store = new CaptureStore(new FakeStorage());
  let releaseTransport;
  let submissions = 0;
  const runtime = runtimeWith({
    store,
    transport: async intent => {
      submissions += 1;
      await new Promise(resolve => { releaseTransport = resolve; });
      return { captureId: intent.captureId, jobId: 'in-flight-job', status: 'accepted' };
    }
  });

  const submitting = runtime.submit(rawIntent('still-in-flight'));
  while (!releaseTransport) await new Promise(resolve => setImmediate(resolve));
  const recovery = await runtime.retryPending();
  assert.deepEqual(recovery, []);
  assert.equal(submissions, 1);
  releaseTransport();
  await submitting;
});

test('retry rechecks durable state and cannot regress a completed capture', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put(rawIntent('already-saved'), 'saved');
  let submissions = 0;
  let retries = 0;
  const runtime = runtimeWith({
    store,
    transport: async () => { submissions += 1; },
    retryTransport: async () => { retries += 1; }
  });

  const result = await runtime.retry('already-saved');
  assert.equal(result.success, false);
  assert.equal(result.retryable, false);
  assert.equal(result.status, 'saved');
  assert.equal(submissions, 0);
  assert.equal(retries, 0);
  assert.equal((await store.get('already-saved')).state, 'saved');
});

test('retry staging cannot overwrite a terminal state that wins after its read', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put(rawIntent('saved-during-retry-read'), 'failed');
  await store.transition('saved-during-retry-read', 'failed', { jobId: 'stale-job' });
  const originalGet = store.get.bind(store);
  const originalTransition = store.transition.bind(store);
  let injectTerminal = true;
  store.get = async captureId => {
    const stale = await originalGet(captureId);
    if (injectTerminal) {
      injectTerminal = false;
      await originalTransition(captureId, 'saved', { filePath: '/archive/winner.jpg' });
    }
    return stale;
  };
  let retries = 0;
  const runtime = runtimeWith({
    store,
    transport: async () => { throw new Error('submit must not run'); },
    retryTransport: async () => { retries += 1; }
  });

  const result = await runtime.retry('saved-during-retry-read');
  assert.equal(result.success, true);
  assert.equal(result.status, 'saved');
  assert.equal(retries, 0);
  assert.equal((await originalGet('saved-during-retry-read')).state, 'saved');
});

test('transport timeout cannot overwrite terminal truth observed during the request', async () => {
  const store = new CaptureStore(new FakeStorage());
  const runtime = runtimeWith({
    store,
    transport: async submitted => {
      await store.transition(submitted.captureId, 'saved', { filePath: '/archive/during-timeout.jpg' });
      const timeout = new Error('Capture request timed out after 30000ms');
      timeout.name = 'TimeoutError';
      throw timeout;
    }
  });

  const result = await runtime.submit(rawIntent('saved-during-timeout'));
  assert.equal(result.success, true);
  assert.equal(result.status, 'saved');
  assert.equal(result.queued, undefined);
  assert.equal((await store.get('saved-during-timeout')).filePath, '/archive/during-timeout.jpg');
});

test('retry timeout cannot overwrite terminal truth observed during the request', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put(rawIntent('saved-during-retry-timeout'), 'failed');
  await store.transition('saved-during-retry-timeout', 'failed', { jobId: 'retry-race-job' });
  const runtime = runtimeWith({
    store,
    transport: async () => { throw new Error('submit must not run'); },
    retryTransport: async captureId => {
      await store.transition(captureId, 'saved', { filePath: '/archive/retry-winner.jpg' });
      const timeout = new Error('Retry timed out after 30000ms');
      timeout.name = 'TimeoutError';
      throw timeout;
    }
  });

  const result = await runtime.retry('saved-during-retry-timeout');
  assert.equal(result.success, true);
  assert.equal(result.status, 'saved');
  assert.equal((await store.get('saved-during-retry-timeout')).filePath, '/archive/retry-winner.jpg');
});

test('an immediate saved receipt with a local transition failure is recoverable', async () => {
  const storage = new FakeStorage();
  const normalSet = storage.set.bind(storage);
  let failNextTransition = true;
  storage.set = async update => {
    if (failNextTransition && storage.setCalls.length === 1) {
      failNextTransition = false;
      throw new Error('temporary local transition failure');
    }
    return normalSet(update);
  };
  const store = new CaptureStore(storage);
  let submissions = 0;
  const runtime = runtimeWith({
    store,
    transport: async intent => {
      submissions += 1;
      return { captureId: intent.captureId, status: 'saved', disposition: submissions > 1 ? 'duplicate' : 'accepted' };
    }
  });

  const first = await runtime.submit(rawIntent('saved-transition-recovery'));
  assert.equal(first.success, true);
  assert.equal(first.storage_error, true);
  assert.equal((await store.get('saved-transition-recovery')).state, 'submitting');

  const recovered = await runtime.retryPending();
  assert.equal(recovered.length, 1);
  assert.equal(submissions, 2);
  assert.equal((await store.get('saved-transition-recovery')).state, 'saved');
});
