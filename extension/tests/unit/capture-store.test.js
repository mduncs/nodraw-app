import assert from 'node:assert/strict';
import test from 'node:test';

import {
  CAPTURE_INBOX_KEY,
  CaptureStore,
  CaptureStoreCapacityError
} from '../../src/runtime/capture-store.js';

class FakeStorage {
  constructor(initial = {}) {
    this.values = structuredClone(initial);
    this.setCalls = [];
  }

  async get(defaults) {
    const result = {};
    for (const [key, fallback] of Object.entries(defaults)) {
      result[key] = key in this.values ? structuredClone(this.values[key]) : fallback;
    }
    return result;
  }

  async set(update) {
    const copy = structuredClone(update);
    this.setCalls.push(copy);
    Object.assign(this.values, copy);
  }
}

function intent(captureId, fingerprint = `fingerprint-${captureId}`) {
  return {
    captureId,
    fingerprint,
    kind: 'page',
    targetUrl: `https://example.com/${captureId}`
  };
}

test('capture records survive a new store instance', async () => {
  const storage = new FakeStorage();
  await new CaptureStore(storage).put(intent('capture-1'), 'queued');

  const reloaded = await new CaptureStore(storage).get('capture-1');
  assert.equal(reloaded.state, 'queued');
  assert.equal(reloaded.intent.targetUrl, 'https://example.com/capture-1');
});

test('transitions preserve intent and count explicit attempts', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put(intent('capture-2'), 'draft');
  await store.transition('capture-2', 'failed', {
    error: 'Server unavailable',
    incrementAttempt: true
  });
  await store.transition('capture-2', 'queued', { incrementAttempt: true });

  const record = await store.get('capture-2');
  assert.equal(record.state, 'queued');
  assert.equal(record.attempts, 2);
  assert.equal(record.error, 'Server unavailable');
  assert.equal(record.intent.fingerprint, 'fingerprint-capture-2');
  assert.equal('incrementAttempt' in record, false);
});

test('conditional transition cannot regress a terminal generation', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put(intent('conditional'), 'submitting');
  await store.transition('conditional', 'saved', { filePath: '/archive/conditional.jpg' });

  const preserved = await store.transition(
    'conditional',
    'accepted',
    { jobId: 'late-receipt' },
    { onlyIfStates: ['submitting'] }
  );
  assert.equal(preserved.transitionApplied, false);
  assert.equal(preserved.state, 'saved');
  assert.equal(preserved.filePath, '/archive/conditional.jpg');
  assert.equal(preserved.jobId, undefined);
});

test('put replaces a capture without duplicating it and keeps prior attempts', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put(intent('capture-3'), 'draft');
  await store.transition('capture-3', 'failed', { incrementAttempt: true });
  await store.put({ ...intent('capture-3'), kind: 'selection' }, 'submitting');

  const records = await store.list();
  assert.equal(records.length, 1);
  assert.equal(records[0].attempts, 1);
  assert.equal(records[0].state, 'submitting');
  assert.equal(records[0].intent.kind, 'selection');
});

test('dismiss removes only the selected durable capture', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put(intent('capture-a'));
  await store.put(intent('capture-b'));
  await store.dismiss('capture-a');

  assert.deepEqual((await store.list()).map(record => record.captureId), ['capture-b']);
});

test('malformed persisted inbox data is treated as empty', async () => {
  const store = new CaptureStore(new FakeStorage({ [CAPTURE_INBOX_KEY]: { stale: true } }));
  assert.deepEqual(await store.list(), []);
});

test('put preserves screenshot payloads needed by offline retry', async () => {
  const storage = new FakeStorage();
  const store = new CaptureStore(storage);
  await store.put({
    ...intent('capture-screenshot'),
    options: { screenshot: 'data:image/png;base64,large-payload' }
  });

  assert.equal((await store.get('capture-screenshot')).intent.options.screenshot, 'data:image/png;base64,large-payload');
  assert.equal(storage.values[CAPTURE_INBOX_KEY][0].intent.options.screenshot, 'data:image/png;base64,large-payload');
});

test('list is read-only and preserves legacy queued screenshot payloads', async () => {
  const legacyRecord = {
    captureId: 'legacy-screenshot',
    intent: {
      ...intent('legacy-screenshot'),
      options: { screenshot: 'data:image/png;base64,legacy-payload' }
    },
    state: 'queued'
  };
  const storage = new FakeStorage({ [CAPTURE_INBOX_KEY]: [legacyRecord] });
  const store = new CaptureStore(storage);

  const records = await store.list();
  assert.equal(records[0].intent.options.screenshot, 'data:image/png;base64,legacy-payload');
  assert.equal(storage.values[CAPTURE_INBOX_KEY][0].intent.options.screenshot, 'data:image/png;base64,legacy-payload');
  assert.equal(storage.setCalls.length, 0);
});

test('transitions preserve screenshot payloads until runtime records acceptance', async () => {
  const storage = new FakeStorage();
  const store = new CaptureStore(storage);
  await store.put(intent('capture-transition'), 'queued');
  await store.transition('capture-transition', 'failed', {
    intent: {
      ...intent('capture-transition'),
      options: { screenshot: 'data:image/png;base64,reintroduced-payload' }
    }
  });

  assert.equal(storage.values[CAPTURE_INBOX_KEY][0].intent.options.screenshot, 'data:image/png;base64,reintroduced-payload');
});

test('concurrent stores serialize whole-inbox mutations without lost updates', async () => {
  const storage = new FakeStorage();
  const firstStore = new CaptureStore(storage);
  const secondStore = new CaptureStore(storage);

  await Promise.all(Array.from({ length: 40 }, (_, index) => (
    (index % 2 === 0 ? firstStore : secondStore).put(intent(`parallel-${index}`), 'queued')
  )));

  const records = await firstStore.list();
  assert.equal(records.length, 40);
  assert.equal(new Set(records.map(record => record.captureId)).size, 40);
});

test('atomic user updates preserve a concurrent terminal state', async () => {
  const storage = new FakeStorage();
  const store = new CaptureStore(storage);
  await store.put({
    ...intent('capture-user'),
    user: { tags: [], note: '' }
  }, 'accepted');

  await Promise.all([
    store.updateUser('capture-user', { tags: ['kept'], note: 'operator note' }),
    store.transition('capture-user', 'saved', { filePath: '/archive/item.jpg' })
  ]);

  const record = await store.get('capture-user');
  assert.equal(record.state, 'saved');
  assert.deepEqual(record.intent.user, { tags: ['kept'], note: 'operator note' });
  assert.equal(record.filePath, '/archive/item.jpg');
});

test('rekey collision preserves canonical truth and merges richer retry context', async () => {
  const storage = new FakeStorage();
  const store = new CaptureStore(storage);
  await store.put({
    ...intent('canonical', 'shared-fingerprint'),
    page: { title: 'Canonical title' },
    user: { tags: ['canonical'], note: 'canonical note' },
    options: {
      saveMode: 'quick',
      screenshot: '',
      siteData: { canonicalField: 'kept' },
      download: { canonicalLimit: 1 }
    }
  }, 'failed');
  await store.transition('canonical', 'failed', {
    jobId: 'canonical-job',
    error: 'canonical failure',
    retryable: true,
    incrementAttempt: true
  });
  await store.put({
    ...intent('incoming', 'shared-fingerprint'),
    page: { title: 'Incoming title' },
    user: { tags: ['incoming'], note: 'incoming note' },
    options: {
      saveMode: 'full',
      screenshot: 'data:image/png;base64,full-context',
      siteData: { richerField: 'added' },
      download: { preferredWidth: 2048 }
    }
  }, 'submitting');

  const incomingWithoutScreenshot = {
    ...intent('canonical', 'shared-fingerprint'),
    options: { saveMode: 'full', screenshot: '', siteData: {}, download: {} }
  };
  const richRetryIntent = {
    ...incomingWithoutScreenshot,
    page: { title: 'Incoming title' },
    user: { tags: ['incoming'], note: 'incoming note' },
    options: {
      saveMode: 'full',
      screenshot: 'data:image/png;base64,full-context',
      siteData: { richerField: 'added' },
      download: { preferredWidth: 2048 }
    }
  };
  const merged = await store.rekey('incoming', incomingWithoutScreenshot, 'duplicate', {
    jobId: 'incoming-job',
    receipt: { disposition: 'duplicate', status: 'failed' },
    retryIntent: richRetryIntent,
    incrementAttempt: true
  });

  assert.equal((await store.list()).length, 1);
  assert.equal(merged.captureId, 'canonical');
  assert.equal(merged.state, 'failed');
  assert.equal(merged.jobId, 'canonical-job');
  assert.equal(merged.error, 'canonical failure');
  assert.equal(merged.retryable, true);
  assert.equal(merged.attempts, 2);
  assert.equal(merged.intent.page.title, 'Canonical title');
  assert.deepEqual(merged.intent.user.tags, ['canonical', 'incoming']);
  assert.equal(merged.intent.user.note, 'canonical note');
  assert.equal(merged.intent.options.saveMode, 'full');
  assert.equal(merged.intent.options.screenshot, 'data:image/png;base64,full-context');
  assert.deepEqual(merged.intent.options.siteData, {
    canonicalField: 'kept',
    richerField: 'added'
  });
  assert.deepEqual(merged.intent.options.download, {
    canonicalLimit: 1,
    preferredWidth: 2048
  });
  assert.equal('retryIntent' in merged, false);
});

test('rekey collision advances nonterminal canonical state but never downgrades saved truth', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put({
    ...intent('accepted-canonical', 'advance-fingerprint'),
    options: { screenshot: 'data:image/png;base64,accepted-context' }
  }, 'accepted');
  await store.transition('accepted-canonical', 'accepted', { jobId: 'accepted-job' });
  await store.put(intent('incoming-saved', 'advance-fingerprint'), 'submitting');

  const saved = await store.rekey(
    'incoming-saved',
    intent('accepted-canonical', 'advance-fingerprint'),
    'saved',
    { jobId: 'accepted-job', filePath: '/archive/saved.jpg' }
  );
  assert.equal(saved.state, 'saved');
  assert.equal(saved.filePath, '/archive/saved.jpg');
  assert.equal(saved.intent.options.screenshot, '');

  await store.put(intent('incoming-failure', 'advance-fingerprint'), 'submitting');
  const stillSaved = await store.rekey(
    'incoming-failure',
    intent('accepted-canonical', 'advance-fingerprint'),
    'failed',
    { jobId: 'replacement-job', error: 'stale failure', retryable: true }
  );
  assert.equal(stillSaved.state, 'saved');
  assert.equal(stillSaved.jobId, 'accepted-job');
  assert.equal(stillSaved.filePath, '/archive/saved.jpg');
  assert.equal(stillSaved.error, null);
  assert.equal(stillSaved.retryable, false);
  assert.equal(stillSaved.intent.options.screenshot, '');
});

test('rekey collision keeps an accepted canonical capture retryable when pointer persistence failed', async () => {
  const store = new CaptureStore(new FakeStorage());
  await store.put({
    ...intent('canonical-untracked', 'tracking-fingerprint'),
    options: { screenshot: '' }
  }, 'accepted');
  await store.transition('canonical-untracked', 'accepted', { jobId: 'untracked-job' });
  await store.put({
    ...intent('incoming-untracked', 'tracking-fingerprint'),
    options: { screenshot: 'data:image/png;base64,retry-context' }
  }, 'submitting');

  const result = await store.rekey(
    'incoming-untracked',
    {
      ...intent('canonical-untracked', 'tracking-fingerprint'),
      options: { screenshot: 'data:image/png;base64,retry-context' }
    },
    'queued',
    {
      jobId: 'untracked-job',
      error: 'durable job tracking could not be saved',
      retryable: true,
      receipt: {
        jobId: 'untracked-job',
        status: 'accepted',
        trackingPending: true
      }
    }
  );

  assert.equal(result.state, 'queued');
  assert.equal(result.retryable, true);
  assert.match(result.error, /tracking could not be saved/i);
  assert.equal(result.intent.options.screenshot, 'data:image/png;base64,retry-context');
});

test('inbox capacity fails closed without evicting an existing unsent capture', async () => {
  const existing = ['queued', 'submitting', 'accepted'].map(state => ({
    captureId: `existing-${state}`,
    fingerprint: `existing-${state}-fingerprint`,
    intent: intent(`existing-${state}`),
    state
  }));
  const storage = new FakeStorage({ [CAPTURE_INBOX_KEY]: existing });
  const store = new CaptureStore(storage, { budgetBytes: 2048 });

  await assert.rejects(
    store.put({
      ...intent('oversized'),
      options: { screenshot: `data:image/png;base64,${'x'.repeat(4096)}` }
    }, 'submitting'),
    error => error instanceof CaptureStoreCapacityError
      && error.code === 'capture_inbox_capacity'
      && /safe storage budget/i.test(error.message)
      && /No capture was evicted/i.test(error.message)
  );

  assert.deepEqual(storage.values[CAPTURE_INBOX_KEY], existing);
  assert.equal(storage.setCalls.length, 0);
});

test('record count is not an eviction policy', async () => {
  const records = Array.from({ length: 501 }, (_, index) => ({
    captureId: `legacy-${index}`,
    fingerprint: `legacy-fingerprint-${index}`,
    intent: intent(`legacy-${index}`),
    state: 'saved'
  }));
  const storage = new FakeStorage({ [CAPTURE_INBOX_KEY]: records });
  const store = new CaptureStore(storage);

  await store.put(intent('new-unsent'), 'queued');
  const persisted = await store.list();
  assert.equal(persisted.length, 502);
  assert.ok(persisted.some(record => record.captureId === 'legacy-500'));
  assert.ok(persisted.some(record => record.captureId === 'new-unsent'));
});
