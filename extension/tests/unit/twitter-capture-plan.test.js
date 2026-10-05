import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';
import { getCapturePieces, getSaveModeFromEvent } from '../../src/content/twitter-media.js';

const source = await readFile(new URL('../../src/content/content-twitter.js', import.meta.url), 'utf8');

function classes() {
  const names = new Set();
  return { add: name => names.add(name), remove: name => names.delete(name), contains: name => names.has(name) };
}

function loadPreview() {
  const handlers = new Map();
  const timers = new Map();
  const calls = [];
  let callback = null;
  let timerId = 0;
  let unsubscribed = 0;
  const article = { isConnected: true, querySelectorAll: () => [] };
  const button = { isConnected: true, style: {}, closest: () => null,
    addEventListener: (event, handler) => handlers.set(event, handler) };
  const menu = { style: {}, classList: classes(), querySelectorAll: () => [] };
  const context = vm.createContext({
    activeCapturePreview: null, button, article, menu,
    menuTimeout: null, statusHideTimeout: null, currentStatus: null,
    getCapturePieces, getSaveModeFromEvent,
    SAVE_MODES: Object.fromEntries(['full', 'quick', 'text', 'quoted'].map(mode => [mode, { icon: mode }])),
    downloadingPosts: { has: () => false }, getTweetData: () => ({}), getTweetKey: () => 'post',
    setIcon() {}, queueStatusHide() {},
    setTimeout(handler) { timers.set(++timerId, handler); return timerId; },
    clearTimeout(id) { timers.delete(id); },
    showCapturePlan(pieces, { mode }) { calls.push({ mode, pieces }); },
    hideCapturePlan() { calls.push({ hidden: true }); },
    watchModifiers(handler) { callback = handler; return () => { callback = null; unsubscribed++; }; }
  });
  // Execute the shipped lifecycle handlers, matching the admission tests.
  const cleanupStart = source.indexOf('  function clearDetachedCapturePlan()');
  const cleanupEnd = source.indexOf('  const downloadingPosts', cleanupStart);
  const hoverStart = source.indexOf('    // Update button appearance based on modifier keys');
  const hoverEnd = source.indexOf('    async function performDownload', hoverStart);
  vm.runInContext(source.slice(cleanupStart, cleanupEnd) + source.slice(hoverStart, hoverEnd), context);
  return {
    article, button, menu, calls,
    enter(event = {}) { handlers.get('mouseenter')(event); },
    leave() { handlers.get('mouseleave')(); },
    modifier(mode) { callback?.(mode); },
    detach() { context.clearDetachedCapturePlan(); },
    tick() { for (const handler of [...timers.values()]) handler(); timers.clear(); },
    get unsubscribed() { return unsubscribed; }
  };
}

test('X preview appears only on hover and responds immediately to modifier changes', () => {
  const preview = loadPreview();
  assert.equal(preview.calls.length, 0);
  preview.enter({ altKey: true, shiftKey: true });
  assert.equal(preview.calls.at(-1).mode, 'quoted');
  for (const mode of ['full', 'quick', 'text', 'quoted']) {
    preview.modifier(mode);
    assert.equal(preview.calls.at(-1).mode, mode);
  }
  preview.tick();
  assert.equal(preview.menu.classList.contains('visible'), true);
  assert.equal(preview.calls.at(-1).mode, 'quoted');
  preview.leave();
  assert.equal(preview.calls.at(-1).hidden, true);
  assert.equal(preview.unsubscribed, 1);
  const calls = preview.calls.length;
  preview.modifier('text');
  assert.equal(preview.calls.length, calls);
});

for (const target of ['button', 'article']) {
  test(`removing hovered ${target} clears the overlay and modifier subscription without mouseleave`, () => {
    const preview = loadPreview();
    preview.enter();
    preview[target].isConnected = false;
    preview.detach();
    assert.equal(preview.calls.at(-1).hidden, true);
    assert.equal(preview.unsubscribed, 1);
    const calls = preview.calls.length;
    preview.tick();
    preview.modifier('quoted');
    assert.equal(preview.menu.classList.contains('visible'), false);
    assert.equal(preview.calls.length, calls);
  });
}

test('delayed menu cannot restore a capture plan for a disconnected button', () => {
  const preview = loadPreview();
  preview.enter();
  preview.button.isConnected = false;
  preview.tick();
  assert.equal(preview.calls.at(-1).hidden, true);
  assert.equal(preview.menu.classList.contains('visible'), false);
  assert.equal(preview.unsubscribed, 1);
});
