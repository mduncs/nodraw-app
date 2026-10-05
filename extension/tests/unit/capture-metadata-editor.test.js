import assert from 'node:assert/strict';
import test from 'node:test';
import { CaptureMetadataEditor, metadataStatusText } from '../../src/content/capture-metadata-editor.js';
import { CaptureRuntime } from '../../src/runtime/capture-runtime.js';
import { CaptureStore } from '../../src/runtime/capture-store.js';

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

test('editing tags never resubmits a stale note', async () => {
  const calls = [];
  const editor = new CaptureMetadataEditor({ captureId: 'one', user: { note: 'old' }, send: async (id, patch) => {
    calls.push([id, patch]); return { success: true };
  } });
  editor.edit('tags', ['new']);
  await editor.flush();
  assert.deepEqual(calls, [['one', { tags: ['new'] }]]);
  assert.equal(editor.unsettled, false);
});

test('a newer edit during an older save is sent afterwards and not falsely acknowledged', async () => {
  const first = deferred();
  const calls = [];
  const editor = new CaptureMetadataEditor({ captureId: 'one', send: async (_id, patch) => {
    calls.push(patch);
    if (calls.length === 1) return first.promise;
    return { success: true };
  } });
  editor.edit('note', 'first');
  const flush = editor.flush();
  editor.edit('note', 'second');
  assert.equal(editor.flush(), flush);
  assert.equal(editor.unsettled, true);
  first.resolve({ success: true });
  await flush;
  assert.deepEqual(calls, [{ note: 'first' }, { note: 'second' }]);
  assert.equal(editor.state.phase, 'saved');
  assert.equal(editor.draft.note, 'second');
});

test('durably accepted projection failure retries projection without rebasing the edit', async () => {
  const calls = [];
  const editor = new CaptureMetadataEditor({ captureId: 'one', send: async (_id, patch) => {
    calls.push(patch);
    return calls.length === 1
      ? { success: false, metadata_pending: true, error: 'Conflicting note' }
      : { success: true, metadata_pending: false };
  } });
  editor.edit('note', 'wanted');
  await editor.flush();
  assert.equal(editor.state.phase, 'failed');
  assert.equal(editor.state.error, 'Conflicting note');
  assert.equal(editor.unsettled, true);
  await editor.flush();
  assert.deepEqual(calls, [{ note: 'wanted' }, {}]);
  assert.equal(editor.unsettled, false);
});

test('transport failure retains the draft and exact dirty fields for retry', async () => {
  const calls = [];
  const editor = new CaptureMetadataEditor({ captureId: 'one', send: async (id, patch) => {
    calls.push([id, patch]);
    if (calls.length === 1) throw new Error('Offline');
    return { success: true };
  } });
  editor.edit('note', 'do not lose this');
  await editor.flush();
  assert.equal(editor.state.error, 'Offline');
  assert.equal(editor.draft.note, 'do not lose this');
  await editor.flush();
  assert.deepEqual(calls, [
    ['one', { note: 'do not lose this' }], ['one', { note: 'do not lose this' }]
  ]);
});

test('incoming capture updates initialize untouched fields but never replace an edited draft', () => {
  const editor = new CaptureMetadataEditor({ captureId: 'one', send: async () => ({ success: true }) });
  editor.updateSource({ tags: ['initial'], note: 'initial' });
  editor.edit('note', 'local');
  editor.updateSource({ tags: ['updated'], note: 'stale' });
  assert.deepEqual(editor.draft, { tags: ['updated'], note: 'local' });
});

test('card replacement and content restart restore offline drafts and accepted projection failures from the real store', async () => {
  let data = {};
  const storage = { get: async defaults => ({ ...defaults, ...structuredClone(data) }), set: async values => { data = structuredClone(values); } };
  const store = new CaptureStore(storage);
  await store.put({ captureId: 'one', user: { note: 'original', tags: ['keep'] } }, 'saved');
  let offline = true;
  const calls = [];
  const runtime = new CaptureRuntime({ store, patchTransport: async (_id, patch) => {
    calls.push(patch);
    if (offline) throw new Error('Offline');
    return { status: 'saved', metadataProjection: 'failed', metadataError: 'External note conflict', metadataMutationId: patch.mutationId };
  } });
  const makeEditor = () => new CaptureMetadataEditor({ captureId: 'one',
    persist: (id, fields) => runtime.stageMetadata(id, fields), send: (id, patch) => runtime.patch(id, patch) });
  const first = makeEditor();
  first.edit('note', 'offline draft');
  await first.persisting; // Simulate switching cards before debounce/network.
  const second = makeEditor();
  second.restore(await store.get('one'));
  assert.equal(second.draft.note, 'offline draft');
  assert.deepEqual(second.draft.tags, ['keep']);
  assert.equal(second.unsettled, true);
  await second.flush();
  assert.equal(second.state.error, 'Offline');
  offline = false;
  const restarted = makeEditor();
  restarted.restore(await new CaptureStore(storage).get('one'));
  await restarted.flush();
  assert.deepEqual(calls[0], calls[1]);
  const reopened = makeEditor();
  reopened.restore(await store.get('one'));
  assert.equal(reopened.state.error, 'External note conflict');
  assert.equal(reopened.unsettled, true);
  await reopened.flush();
  assert.deepEqual(calls[2], {});
});

test('a later successful draft write cannot hide a failed earlier field write', async () => {
  const saved = {};
  let attempts = 0;
  const editor = new CaptureMetadataEditor({ captureId: 'one', persist: async (_id, fields) => {
    if (++attempts === 1) throw new Error('Transient quota');
    Object.assign(saved, fields);
  }, send: async (_id, patch) => { assert.deepEqual(patch, {}); return { success: true }; } });
  editor.edit('note', 'must survive');
  editor.edit('tags', ['also']);
  await editor.flush();
  assert.deepEqual(saved, { note: 'must survive', tags: ['also'] });
});

test('an untouched capture card shows no save failure', () => {
  assert.equal(metadataStatusText({ phase: 'idle', error: null }), '');
  assert.equal(metadataStatusText({ phase: 'saved', error: null }), 'Changes saved');
  assert.equal(metadataStatusText({ phase: 'failed', error: null }), 'Changes could not be saved');
  assert.equal(metadataStatusText({ phase: 'failed', error: 'offline' }), 'offline');
});
