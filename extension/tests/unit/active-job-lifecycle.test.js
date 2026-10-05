import assert from 'node:assert/strict';
import test from 'node:test';

import {
  commitTerminalGeneration,
  createSerializedExecutor
} from '../../src/runtime/active-job-lifecycle.js';

test('stale terminal response cannot remove a replacement generation', async () => {
  const original = { generation: 1 };
  const replacement = { generation: 2 };
  let current = original;
  let finishMark;
  let removals = 0;
  let pointerWrites = 0;
  const committing = commitTerminalGeneration({
    isCurrent: () => current === original,
    markTerminal: () => new Promise(resolve => { finishMark = resolve; }),
    removePointer: () => { removals += 1; current = null; },
    persistPointers: async () => { pointerWrites += 1; },
    restorePointer: () => { current = original; },
    pointerExists: () => current !== null
  });

  await new Promise(resolve => setImmediate(resolve));
  current = replacement;
  finishMark({ state: 'saved' });
  const result = await committing;

  assert.equal(result.reason, 'stale-generation');
  assert.equal(current, replacement);
  assert.equal(removals, 0);
  assert.equal(pointerWrites, 0);
});

test('terminal inbox failure retains the reconciliation pointer', async () => {
  const entry = { generation: 1 };
  let current = entry;
  const result = await commitTerminalGeneration({
    isCurrent: () => current === entry,
    markTerminal: async () => { throw new Error('storage unavailable'); },
    removePointer: () => { current = null; },
    persistPointers: async () => {},
    restorePointer: () => { current = entry; },
    pointerExists: () => current !== null
  });

  assert.equal(result.reason, 'terminal-write-failed');
  assert.equal(current, entry);
});

test('pointer persistence failure restores terminal reconciliation', async () => {
  const entry = { generation: 1 };
  let current = entry;
  const result = await commitTerminalGeneration({
    isCurrent: () => current === entry,
    markTerminal: async () => ({ state: 'saved' }),
    removePointer: () => { current = null; },
    persistPointers: async () => { throw new Error('pointer write failed'); },
    restorePointer: () => { current = entry; },
    pointerExists: () => current !== null
  });

  assert.equal(result.reason, 'pointer-write-failed');
  assert.equal(current, entry);
});

test('terminal commit orders inbox before pointer deletion', async () => {
  const entry = { generation: 1 };
  let current = entry;
  const events = [];
  const result = await commitTerminalGeneration({
    isCurrent: () => current === entry,
    markTerminal: async () => { events.push('inbox'); return { state: 'saved' }; },
    removePointer: () => { events.push('remove'); current = null; },
    persistPointers: async () => { events.push('pointer'); },
    restorePointer: () => { current = entry; },
    pointerExists: () => current !== null
  });

  assert.equal(result.committed, true);
  assert.deepEqual(events, ['inbox', 'remove', 'pointer']);
});

test('serialized restore finishes before a newer start mutation', async () => {
  const execute = createSerializedExecutor();
  const jobs = new Map();
  let releaseRestore;
  const restore = execute(async () => {
    await new Promise(resolve => { releaseRestore = resolve; });
    if (!jobs.has('same-job')) jobs.set('same-job', { generation: 'restored' });
  });
  const start = execute(async () => {
    jobs.set('same-job', { generation: 'new' });
  });

  await new Promise(resolve => setImmediate(resolve));
  assert.equal(jobs.size, 0);
  releaseRestore();
  await Promise.all([restore, start]);
  assert.equal(jobs.get('same-job').generation, 'new');
});
