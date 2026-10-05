import assert from 'node:assert/strict';
import test from 'node:test';
import { createCaptureButton, modeFromEvent } from '../../src/content/modules/capture-button.js';
import { findCaptureTarget } from '../../src/content/ui/capture-target-hint.js';

function fixture(options = {}) {
  const handlers = new Map();
  const runtimeHandlers = new Set();
  const button = {
    addEventListener: (name, fn) => handlers.set(name, fn),
    removeEventListener: name => handlers.delete(name)
  };
  let now = 0;
  let timerId = 0;
  const timers = new Map();
  const clock = {
    setTimeout(fn, delay) { timers.set(++timerId, { fn, time: now + delay }); return timerId; },
    clearTimeout(id) { timers.delete(id); },
    tick(ms) {
      now += ms;
      for (const [id, timer] of [...timers]) {
        if (timer.time <= now) { timers.delete(id); timer.fn(); }
      }
    }
  };
  const plans = [];
  const marks = [];
  const renders = [];
  const target = { isConnected: true };
  let marksAttached = 0;
  let marksActive = 0;
  let modifierHandler;
  let marksDestroyed = false;
  const reservations = new Set();
  const controller = createCaptureButton({
    button, target, url: 'https://example.test/post', key: 'post', reservations,
    render: (state, info) => renders.push({ state, info }),
    getPieces: mode => [{ mode }],
    submit: async () => ({ success: true, job_id: 'job', status: 'accepted' }),
    runtime: { onMessage: {
      addListener: fn => runtimeHandlers.add(fn), removeListener: fn => runtimeHandlers.delete(fn)
    } },
    presentation: {
      attachMarks: () => {
        marksAttached++;
        marksActive++;
        return { set: (state, info) => marks.push({ state, info }), destroy: () => { marksDestroyed = true; marksActive--; } };
      },
      showCapturePlan: (pieces, info) => plans.push({ pieces, info }),
      hideCapturePlan: () => plans.push(null),
      watchModifiers: fn => { modifierHandler = fn; return () => { modifierHandler = null; }; }
    }, clock, ...options
  });
  return {
    controller, plans, marks, renders, target, reservations, timers, handlers, runtimeHandlers, clock,
    get marksAttached() { return marksAttached; },
    get marksActive() { return marksActive; },
    get marksDestroyed() { return marksDestroyed; },
    modifiers: mode => modifierHandler?.(mode),
    event: (name, event = {}) => handlers.get(name)?.({ preventDefault() {}, stopPropagation() {}, ...event }),
    status: request => runtimeHandlers.forEach(fn => fn({ action: 'archiveJobStatus', jobId: 'job', url: 'https://example.test/post', ...request }))
  };
}

test('modifier mapping: default full, shift quick, option text (also option+shift)', () => {
  assert.equal(modeFromEvent(), 'full');
  assert.equal(modeFromEvent({ shiftKey: true }), 'quick');
  assert.equal(modeFromEvent({ altKey: true }), 'text');
  assert.equal(modeFromEvent({ altKey: true, shiftKey: true }), 'text');
});

test('marks attach only while hovered and are destroyed on leave or cleanup', () => {
  const f = fixture();
  assert.equal(f.marksAttached, 0);
  assert.deepEqual(f.marks, []);
  f.event('mouseenter');
  assert.equal(f.marksAttached, 1);
  assert.equal(f.marksActive, 1);
  assert.equal(f.marks.at(-1).state, 'hover');
  f.event('mouseleave');
  assert.equal(f.marksActive, 0);
  f.event('mouseenter');
  assert.equal(f.marksAttached, 2);
  f.controller.destroy();
  assert.equal(f.marksActive, 0);
});

test('archived precheck updates the resting glyph but shows already marks only on hover', async () => {
  const calls = [];
  const f = fixture({
    getArchiveStatus: async () => ({ archived: true, savedAt: '2026-09-30' }),
    submit: async (mode, event, again) => {
      calls.push({ mode, event, again });
      return { success: true, status: 'saved' };
    }
  });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.controller.state, 'already');
  assert.equal(f.marksAttached, 0);
  f.event('mouseenter', { shiftKey: true });
  assert.equal(f.marks.at(-1).state, 'already');
  assert.equal(f.marks.at(-1).info.savedAt, '2026-09-30');
  await f.marks.at(-1).info.onSaveAgain();
  assert.deepEqual(calls, [{ mode: 'quick', event: {}, again: true }]);
  assert.equal(f.marksActive, 0);
  f.controller.destroy();
});

test('archive precheck completing during hover updates hover marks', async () => {
  let resolve;
  const f = fixture({ getArchiveStatus: () => new Promise(r => { resolve = r; }) });
  await Promise.resolve();
  f.event('mouseenter');
  resolve({ archived: true, savedAt: '2026-09-29' });
  await new Promise(done => setImmediate(done));
  assert.equal(f.marks.at(-1).state, 'already');
  assert.equal(f.marks.at(-1).info.savedAt, '2026-09-29');
  f.event('mouseleave');
  assert.equal(f.marksActive, 0);
  f.controller.destroy();
});

test('mousemove does not rebuild the plan until the mode changes', () => {
  const f = fixture();
  f.event('mouseenter');
  f.event('mousemove');
  f.event('mousemove');
  f.modifiers('full');
  assert.equal(f.plans.length, 1);
  f.event('mousemove', { shiftKey: true });
  f.event('mousemove', { shiftKey: true });
  f.modifiers('quick');
  assert.equal(f.plans.length, 2);
  f.modifiers('full');
  assert.equal(f.plans.length, 3);
  f.event('mouseleave');
  f.event('mouseenter');
  assert.equal(f.plans.length, 5);
  f.controller.destroy();
});

test('capture and extra URL hints exist before submit and hover marks hand off on click', async () => {
  const mediaUrl = 'https://example.test/media.jpg';
  let calls = 0;
  const f = fixture({
    hintUrls: mode => { assert.equal(mode, 'quick'); return [mediaUrl]; },
    submit: async () => {
      calls++;
      assert.equal(findCaptureTarget(['https://example.test/post']), f.target);
      assert.equal(findCaptureTarget([mediaUrl]), f.target);
      assert.equal(f.marksActive, 0);
      return { success: true, status: 'saved' };
    }
  });
  f.event('mouseenter');
  f.event('click', { shiftKey: true });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls, 1);
  assert.equal(f.controller.state, 'kept');
  f.controller.destroy();
});

test('module never draws saving, kept, already-after-save or failed marks', async () => {
  for (const status of ['saved', 'duplicate', 'failed']) {
    const f = fixture({ submit: async () => ({ success: true, status }) });
    f.event('mouseenter');
    await f.controller.start();
    assert.equal(f.marksActive, 0);
    assert.deepEqual(f.marks.map(mark => mark.state), ['hover']);
    f.event('mouseleave');
    f.event('mouseenter');
    assert.deepEqual(f.marks.map(mark => mark.state), ['hover', 'hover']);
    f.controller.destroy();
  }
});

test('plans appear only on hover and update on modifier press/release without mouse movement', () => {
  const f = fixture();
  assert.equal(f.plans.length, 0);
  f.event('mouseenter');
  f.modifiers('quick');
  assert.equal(f.plans.at(-1).info.mode, 'quick');
  f.modifiers('text');
  assert.equal(f.plans.at(-1).pieces[0].mode, 'text');
  f.modifiers('full');
  assert.equal(f.plans.at(-1).info.mode, 'full');
  f.event('mouseleave');
  assert.equal(f.plans.at(-1), null);
  f.modifiers('quick');
  assert.equal(f.controller.state, 'idle');
  f.controller.destroy();
});

test('accepted job remains saving; nonterminal status never clears pending handlers', async () => {
  const f = fixture();
  await f.controller.start();
  assert.equal(f.controller.state, 'saving');
  f.status({ status: 'downloading', progress: 62 });
  assert.equal(f.controller.state, 'saving');
  assert.equal(f.renders.at(-1).info.progress, 62);
  assert.deepEqual(f.marks, []);
  assert.equal(f.runtimeHandlers.size, 1);
  f.clock.tick(600000);
  assert.equal(f.controller.state, 'saving');
  f.status({ status: 'completed' });
  assert.equal(f.controller.state, 'kept');
  assert.equal(f.runtimeHandlers.size, 0);
  assert.equal(f.reservations.size, 0);
  f.clock.tick(3499);
  assert.equal(f.controller.state, 'kept');
  f.clock.tick(1);
  assert.equal(f.controller.state, 'idle');
  f.controller.destroy();
});

test('glyph failure persists through fake time and mouseleave; retry remains actionable', async () => {
  const f = fixture();
  await f.controller.start('quick');
  f.status({ status: 'failed', error: 'Network error' });
  assert.equal(f.controller.state, 'failed');
  assert.equal(f.renders.at(-1).info.error, 'Network error');
  f.event('mouseenter');
  f.event('mouseleave');
  f.clock.tick(600000);
  assert.equal(f.controller.state, 'failed');
  await f.controller.start('quick');
  assert.equal(f.controller.state, 'saving');
  f.status({ status: 'completed' });
  f.controller.destroy();
});

test('early status is buffered until job identity is known and unrelated job is ignored', async () => {
  let resolve;
  const f = fixture({ submit: () => new Promise(r => { resolve = r; }) });
  const pending = f.controller.start();
  f.status({ jobId: 'other', status: 'failed' });
  f.status({ status: 'completed' });
  resolve({ success: true, job_id: 'job' });
  await pending;
  assert.equal(f.controller.state, 'kept');
  f.controller.destroy();
});

test('queued URL tracking survives until a later job completes', async () => {
  const f = fixture({ submit: async () => ({ success: false, queued: true, error: 'Offline' }) });
  await f.controller.start();
  assert.equal(f.controller.state, 'saving');
  assert.equal(f.renders.at(-1).info.caption, 'QUEUED');
  f.status({ status: 'completed' });
  assert.equal(f.controller.state, 'kept');
  f.controller.destroy();
});

test('duplicates remain already and save-again requests a fresh capture', async () => {
  const calls = [];
  const f = fixture({ submit: async (mode, event, again) => {
    calls.push(again); return { success: true, status: 'duplicate' };
  } });
  await f.controller.start();
  assert.equal(f.controller.state, 'already');
  f.clock.tick(100000);
  assert.equal(f.controller.state, 'already');
  await f.controller.start('full', {}, true);
  assert.deepEqual(calls, [false, true]);
  f.controller.destroy();
});

test('cleanup removes UI handlers, modifier subscription, marks, plan and reset timers', async () => {
  const f = fixture({ submit: async () => ({ success: true, status: 'saved' }) });
  f.event('mouseenter');
  await f.controller.start();
  f.controller.destroy();
  f.controller.destroy();
  assert.equal(f.handlers.size, 0);
  assert.equal(f.timers.size, 0);
  assert.equal(f.runtimeHandlers.size, 0);
  assert.equal(f.marksDestroyed, true);
  f.clock.tick(100000);
  assert.equal(f.controller.state, 'kept');
});

test('removing a widget preserves its in-flight reservation until terminal truth', async () => {
  const f = fixture();
  await f.controller.start();
  f.controller.destroy();
  assert.equal(f.reservations.has('post'), true);
  const count = f.marks.length;
  f.status({ status: 'completed' });
  assert.equal(f.reservations.size, 0);
  assert.equal(f.runtimeHandlers.size, 0);
  assert.equal(f.marks.length, count);
  assert.equal(f.timers.size, 0);
});

test('one active operation per key and thrown submission releases it', async () => {
  let calls = 0;
  const f = fixture({ submit: async () => { calls++; throw new Error('failed'); } });
  const first = f.controller.start();
  await f.controller.start();
  await first;
  assert.equal(calls, 1);
  assert.equal(f.controller.state, 'failed');
  assert.equal(f.reservations.size, 0);
  f.controller.destroy();
});

test('two widgets reserve before asynchronous archive lookup and confirmation', async () => {
  let lookupResolve, promptResolve;
  const shared = new Set();
  let lookups = 0, prompts = 0, submissions = 0;
  const lookup = new Promise(resolve => { lookupResolve = resolve; });
  const prompt = new Promise(resolve => { promptResolve = resolve; });
  const options = {
    reservations: shared,
    getArchiveStatus: () => { lookups++; return lookup; },
    confirmAgain: () => { prompts++; return prompt; },
    submit: async () => { submissions++; return { success: true, job_id: 'job' }; }
  };
  const first = fixture(options), second = fixture(options);
  // Let initial archive probes run before measuring click lookups.
  await Promise.resolve();
  const initialLookups = lookups;
  const pending = first.controller.start();
  await second.controller.start();
  assert.equal(lookups, initialLookups + 1);
  lookupResolve({ archived: true });
  await Promise.resolve();
  await Promise.resolve();
  await second.controller.start();
  assert.equal(prompts, 1);
  promptResolve(true);
  await pending;
  await second.controller.start();
  assert.equal(submissions, 1);
  first.status({ status: 'completed' });
  await second.controller.start();
  assert.equal(submissions, 2);
  second.status({ status: 'completed' });
  first.controller.destroy(); second.controller.destroy();
});

test('cancelled confirmation and lookup/prompt errors release admission', async () => {
  for (const stage of ['cancel', 'lookup', 'prompt']) {
    let calls = 0;
    const f = fixture({
      getArchiveStatus: async () => {
        if (stage === 'lookup') throw new Error('Lookup error');
        return { archived: true };
      },
      confirmAgain: async () => {
        if (stage === 'prompt') throw new Error('Prompt error');
        return false;
      },
      submit: async () => { calls++; }
    });
    await f.controller.start();
    assert.equal(f.reservations.size, 0);
    assert.equal(calls, 0);
    assert.equal(f.controller.state, stage === 'cancel' ? 'already' : 'failed');
    f.controller.destroy();
  }
});

test('retry uses the durable capture ID instead of resubmitting extraction', async () => {
  let submissions = 0;
  const messages = [];
  const handlers = new Set();
  const f = fixture({
    submit: async () => { submissions++; return { success: false, status: 'failed', capture_id: 'capture', error: 'Failure' }; },
    runtime: {
      onMessage: { addListener: fn => handlers.add(fn), removeListener: fn => handlers.delete(fn) },
      sendMessage: async message => { messages.push(message); return { success: true, status: 'saved', capture_id: 'capture' }; }
    }
  });
  await f.controller.start();
  await f.controller.start();
  assert.equal(submissions, 1);
  assert.deepEqual(messages, [{ action: 'capture.retry', captureId: 'capture' }]);
  assert.equal(f.controller.state, 'kept');
  f.controller.destroy();
});

test('resolution-warning cancellation returns idle and clears all pending handlers', async () => {
  let submissions = 0;
  const f = fixture({ beforeSubmit: () => false, submit: async () => { submissions++; } });
  await f.controller.start();
  assert.equal(submissions, 0);
  assert.equal(f.controller.state, 'idle');
  assert.equal(f.reservations.size, 0);
  assert.equal(f.runtimeHandlers.size, 0);
  f.controller.destroy();
});

test('new extraction failure cannot retry the previous saved capture ID', async () => {
  let calls = 0;
  const messages = [];
  const f = fixture({
    submit: async () => {
      calls++;
      if (calls === 1) return { success: true, status: 'saved', capture_id: 'old-capture' };
      throw new Error('New extraction failed');
    },
    runtime: { onMessage: { addListener() {}, removeListener() {} }, sendMessage: async message => messages.push(message) }
  });
  await f.controller.start();
  await f.controller.start();
  assert.equal(f.controller.state, 'failed');
  await f.controller.start();
  assert.equal(calls, 3);
  assert.equal(messages.length, 0);
  f.controller.destroy();
});

test('click mode is frozen during asynchronous archive lookup', async () => {
  let resolve;
  const lookup = new Promise(r => { resolve = r; });
  const modes = [];
  const f = fixture({
    getArchiveStatus: () => lookup,
    submit: async mode => { modes.push(mode); return { success: true, status: 'saved' }; }
  });
  const pending = f.controller.start('quick');
  f.event('mouseenter', { altKey: true });
  f.modifiers('text');
  resolve({ archived: false });
  await pending;
  assert.deepEqual(modes, ['quick']);
  f.controller.destroy();
});

test('retry and save-again accept the same resolution modifiers', async () => {
  const events = [];
  const f = fixture({
    submit: async (mode, event) => {
      events.push(event);
      if (events.length === 1) throw new Error('Failed before receipt');
      return { success: true, status: 'saved' };
    }
  });
  await f.controller.start('full', { altKey: true, target: { bulky: true } });
  await f.controller.start('full', { altKey: true });
  assert.equal(events[1].altKey, true);
  assert.equal(events[1].target, undefined);
  await f.controller.start('full', { altKey: true }, true);
  assert.equal(events[2].altKey, true);
  f.controller.destroy();
});

test('changing mode after a failed capture submits a new intent instead of retrying old intent', async () => {
  const modes = [];
  const f = fixture({
    submit: async mode => { modes.push(mode); return { success: false, status: 'failed', capture_id: 'failed-capture' }; },
    runtime: { onMessage: { addListener() {}, removeListener() {} }, sendMessage: async () => { throw new Error('Unexpected retry'); } }
  });
  await f.controller.start('quick');
  await f.controller.start('text', { altKey: true });
  assert.deepEqual(modes, ['quick', 'text']);
  f.controller.destroy();
});

test('changing resolution modifiers after a failure creates a new capture', async () => {
  const events = [];
  const f = fixture({
    submit: async (mode, event) => { events.push(event); return { success: false, status: 'failed', capture_id: 'original-capture' }; },
    runtime: { onMessage: { addListener() {}, removeListener() {} }, sendMessage: async () => { throw new Error('Unexpected retry'); } }
  });
  await f.controller.start('full', { altKey: true });
  await f.controller.start('full', {});
  assert.equal(events.length, 2);
  assert.equal(!!events[1].altKey, false);
  f.controller.destroy();
});

test('the hovered piece hands its plan label to the marks caption below it', () => {
  const plans = [];
  const target = { id: 'media' };
  const button = new EventTarget();
  button.dataset = {};
  createCaptureButton({
    button, target, submit: async () => ({ success: true }), url: 'https://example.test/a.png',
    getPieces: () => [{ element: target, kind: 'image', level: 0, included: true }, { element: { id: 'post' }, kind: 'text', level: 0, included: true },
      { element: target, kind: 'transcripts', level: 0, included: true }],
    presentation: { attachMarks: () => ({ set() {}, destroy() {} }), showCapturePlan: pieces => plans.push(pieces),
      hideCapturePlan() {}, watchModifiers: () => () => {} },
    runtime: null, clock: { setTimeout: () => 0, clearTimeout() {} }
  });
  button.dispatchEvent(Object.assign(new Event('mouseenter'), { shiftKey: false, altKey: false }));
  assert.equal(plans.at(-1)[0].captionAbove, true);
  assert.equal(plans.at(-1)[1].captionAbove, undefined);
  assert.equal(plans.at(-1)[2].captionAbove, undefined, 'only the first piece of the hovered element');
});
