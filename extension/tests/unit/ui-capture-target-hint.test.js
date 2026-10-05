import assert from 'node:assert/strict';
import test from 'node:test';
import { findCaptureHint, findCaptureTarget, rememberCaptureTarget } from '../../src/content/ui/capture-target-hint.js';

function resetHints(t) {
  const previous = globalThis.__nodrawCaptureTargets;
  delete globalThis.__nodrawCaptureTargets;
  t.after(() => {
    if (previous === undefined) delete globalThis.__nodrawCaptureTargets;
    else globalThis.__nodrawCaptureTargets = previous;
  });
}

test('hints accept a URL or URL list, skip empty URLs and match in requested order', t => {
  resetHints(t);
  const first = { isConnected: true };
  const second = { isConnected: true };
  rememberCaptureTarget(['media', 'source', null, undefined, ''], first);
  rememberCaptureTarget('target', second);
  assert.equal(globalThis.__nodrawCaptureTargets.size, 3);
  assert.equal(findCaptureTarget('source'), first);
  assert.equal(findCaptureTarget([undefined, 'target', 'media']), second);
  assert.equal(findCaptureTarget(['media', 'target']), first);
  assert.equal(findCaptureTarget(['missing', null]), null);
});

test('remember refreshes a URL hint and lookup shares the global isolated-world map', t => {
  resetHints(t);
  const first = { isConnected: true };
  const second = { isConnected: true };
  globalThis.__nodrawCaptureTargets = new Map([['shared', { element: first, at: Date.now() }]]);
  assert.equal(findCaptureTarget('shared'), first);
  rememberCaptureTarget('shared', second);
  assert.equal(findCaptureTarget('shared'), second);
  assert.equal(globalThis.__nodrawCaptureTargets.size, 1);
});

test('lookup prunes expired hints after sixty seconds, including URLs not requested', t => {
  resetHints(t);
  let now = 1000;
  t.mock.method(Date, 'now', () => now);
  const element = { isConnected: true };
  rememberCaptureTarget(['media', 'source'], element);
  now += 60000;
  assert.equal(findCaptureTarget('media'), element);
  now++;
  assert.equal(findCaptureTarget('media'), null);
  assert.equal(globalThis.__nodrawCaptureTargets.size, 0);
});

test('lookup prunes disconnected and missing elements without dropping connected hints', t => {
  resetHints(t);
  const element = { isConnected: true };
  rememberCaptureTarget('connected', element);
  rememberCaptureTarget('removed', { isConnected: false });
  rememberCaptureTarget('missing', null);
  assert.equal(findCaptureTarget('connected'), element);
  assert.deepEqual([...globalThis.__nodrawCaptureTargets.keys()], ['connected']);
  element.isConnected = false;
  assert.equal(findCaptureTarget('connected'), null);
  assert.equal(globalThis.__nodrawCaptureTargets.size, 0);
});

test('a taken hint is gone for every URL it was left under', () => {
  globalThis.__nodrawCaptureTargets = new Map();
  const post = { isConnected: true };
  rememberCaptureTarget(['https://example.test/post', 'https://example.test/feed'], post);
  assert.equal(findCaptureTarget(['https://example.test/post'], { take: true }), post);
  assert.equal(findCaptureTarget(['https://example.test/feed']), null);
  delete globalThis.__nodrawCaptureTargets;
});

test('a hint carries the control the capture came from', t => {
  resetHints(t);
  const post = { isConnected: true };
  const glyph = { isConnected: true };
  rememberCaptureTarget(['https://www.reddit.com/r/a/comments/1/x/'], post, glyph);
  const hint = findCaptureHint(['https://www.reddit.com/r/a/comments/1/x/'], { take: true });
  assert.equal(hint.element, post);
  assert.equal(hint.avoid, glyph);
  assert.equal(findCaptureTarget(['https://www.reddit.com/r/a/comments/1/x/']), null, 'taken');
});
