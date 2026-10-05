import assert from 'node:assert/strict';
import test from 'node:test';
import { installPageAgent } from '../../src/content/page-agent.js';
import { captureSkin, xTheme, X_CARD_CSS } from '../../src/content/ui/card-skins.js';
import { rememberCaptureTarget } from '../../src/content/ui/capture-target-hint.js';

function fakePage(hostname = 'example.test', record = {}) {
  const calls = [];
  const frames = [];
  const timers = new Map();
  const events = {};
  let listener;
  let timerId = 0;
  class Node {
    constructor(tag) {
      this.tagName = tag.toUpperCase(); this.children = []; this.attributes = {}; this.events = {};
      this.className = ''; this.value = ''; this.isConnected = true; this.style = {};
      this.classList = { toggle: (name, enabled) => {
        const classes = new Set(this.className.split(' ').filter(Boolean));
        enabled ? classes.add(name) : classes.delete(name);
        this.className = [...classes].join(' ');
      } };
    }
    setAttribute(name, value) { this.attributes[name] = value; }
    append(...nodes) {
      for (const node of nodes) {
        if (node.parent) node.parent.children = node.parent.children.filter(child => child !== node);
        node.parent = this; this.children.push(node);
      }
    }
    replaceChildren(...nodes) { this.children = []; this.append(...nodes); }
    remove() { this.isConnected = false; if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this); }
    addEventListener(name, fn) { this.events[name] = fn; }
    removeEventListener(name) { delete this.events[name]; }
    attachShadow({ mode }) { this.mode = mode; this.closedRoot = new Node('shadow'); return this.closedRoot; }
    querySelector(selector) {
      return descendants(this).find(node => selector.startsWith('[')
        ? selector.slice(1, -1) in node.attributes : node.className.split(' ').includes(selector.slice(1)));
    }
    click() { this.events.click?.({ target: this }); }
    input(value) { this.value = value; this.events.input?.({ target: this }); }
    focus() { this.focused = true; }
    contains(target) { return target === this || descendants(this).includes(target); }
    setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end; }
  }
  const document = { location: { hostname }, createElement: tag => new Node(tag), querySelectorAll: () => [],
    addEventListener(name, fn) { events[name] = fn; }, removeEventListener(name) { delete events[name]; } };
  document.documentElement = new Node('html'); document.body = new Node('body');
  const browserAPI = { runtime: {
    onMessage: { addListener: fn => { listener = fn; }, removeListener: () => { listener = null; } },
    sendMessage: async message => {
      calls.push(message);
      if (message.action === 'capture.get') return { capture: record };
      return { success: true };
    }
  } };
  const window = { innerWidth: 1024, innerHeight: 768, getComputedStyle: () => ({ backgroundColor: 'rgb(21, 32, 43)' }) };
  const marks = (target, options) => {
    const frame = { target, options, destroyed: false, set(state, info) { this.state = state; this.info = info; }, destroy() { this.destroyed = true; } };
    frames.push(frame); return frame;
  };
  const originalSet = globalThis.setTimeout;
  const originalClear = globalThis.clearTimeout;
  globalThis.setTimeout = (fn, delay) => { const id = ++timerId; timers.set(id, { fn, delay }); return id; };
  globalThis.clearTimeout = id => timers.delete(id);
  const agent = installPageAgent({ document, browserAPI, window, marks });
  const restore = () => { agent.destroy(); globalThis.setTimeout = originalSet; globalThis.clearTimeout = originalClear; };
  return { document, browserAPI, window, frames, calls, timers, restore, key: key => events.keydown?.({ key }),
    update: update => listener({ action: 'captureCard.update', captureId: 'one', kind: 'page', ...update }),
    message: message => listener(message), card: () => document.documentElement.children[0]?.closedRoot };
}
function descendants(node) { return node.children.flatMap(child => [child, ...descendants(child)]); }
async function settle() { for (let i = 0; i < 12; i++) await Promise.resolve(); }

test('only X domains select Direction A and theme follows the page background', () => {
  for (const host of ['x.com', 'twitter.com', 'mobile.twitter.com']) assert.equal(captureSkin(host), 'x');
  for (const host of ['example.com', 'notx.com', 'x.com.example.com']) assert.equal(captureSkin(host), 'marks');
  const document = { body: {}, documentElement: {} };
  assert.equal(xTheme(document, () => ({ backgroundColor: 'rgb(255, 255, 255)' })), 'light');
  assert.equal(xTheme(document, () => ({ backgroundColor: 'rgb(21, 32, 43)' })), 'dim');
  assert.equal(xTheme(document, () => ({ backgroundColor: 'rgb(0, 0, 0)' })), 'dark');
  assert.match(X_CARD_CSS, /TwitterChirp/);
  assert.match(X_CARD_CSS, /\.add-tag \{ border-style:dashed/);
});

test('non-X marks keep state, retry/dismiss, metadata staging and empty idle status', async () => {
  const page = fakePage();
  try {
    page.update({ state: 'saving' }); await settle();
    assert.equal(page.frames[0].state, 'saving');
    assert.equal(page.card(), undefined);
    page.update({ state: 'saved', tags: ['reference'] });
    const frame = page.frames[0];
    assert.equal(frame.state, 'kept');
    assert.equal(frame.info.editor.hidden, true);
    frame.info.onTag();
    const editor = frame.info.editor;
    assert.equal(editor.hidden, false);
    assert.equal(editor.querySelector('[data-metadata-status]').textContent, '');
    const tags = editor.querySelector('[data-tags]');
    tags.input('reference, moss'); tags.events.change();
    await settle();
    assert.deepEqual(page.calls.find(call => call.action === 'capture.metadata.stage').fields, { tags: ['reference', 'moss'] });
    assert.deepEqual(page.calls.find(call => call.action === 'capture.patch'), { action: 'capture.patch', captureId: 'one' });
    assert.equal(editor.querySelector('[data-metadata-status]').textContent, 'Changes saved');
    page.update({ state: 'failed', error: 'Offline' });
    assert.equal(frame.state, 'failed');
    assert.equal(page.timers.size, 0);
    frame.info.onRetry();
    assert.equal(page.calls.at(-1).action, 'capture.retry');
    frame.info.onDismiss();
    assert.equal(frame.destroyed, true);
    page.update({ state: 'saved' });
    assert.equal(page.frames.length, 1, 'dismissed captures stay dismissed');
  } finally { page.restore(); }
});

test('X uses a closed card with pill tags, Add tag, Open and Done; editing uses durable staging', async () => {
  const page = fakePage('x.com');
  try {
    page.update({ state: 'saved', tags: ['gamedev'], title: 'Sample post' }); await settle();
    const card = page.card();
    assert.equal(page.document.documentElement.children[0].mode, 'closed');
    assert.equal(card.querySelector('.card').className, 'card dim');
    const nodes = descendants(card);
    assert.ok(nodes.some(node => node.className === 'tag' && node.textContent === 'gamedev'));
    nodes.find(node => node.textContent === 'Add tag').click();
    card.querySelector('[data-tags]').input('gamedev, reference');
    card.querySelector('[data-tags]').events.change(); await settle();
    assert.ok(page.calls.some(call => call.action === 'capture.metadata.stage'));
    assert.ok(page.calls.some(call => call.action === 'capture.patch' && !('tags' in call)));
    nodes.find(node => node.textContent === 'Open in NoDraw').click();
    assert.equal(page.calls.at(-1).action, 'capture.open');
    nodes.find(node => node.textContent === 'Done').click();
    assert.equal(page.card(), undefined);
    assert.equal(page.frames.length, 0);
  } finally { page.restore(); }
});

test('durable restored metadata failures expand the editor and prevent auto-close', async () => {
  const page = fakePage('example.test', { metadata: { draft: { note: 'offline draft' }, error: 'Offline' } });
  try {
    page.update({ state: 'saved' }); await settle();
    const editor = page.frames[0].info.editor;
    assert.equal(editor.hidden, false);
    assert.equal(editor.querySelector('[data-note]').value, 'offline draft');
    assert.equal(editor.querySelector('[data-metadata-status]').textContent, 'Offline');
    assert.equal(editor.querySelector('[data-metadata-retry]').hidden, false);
    assert.equal(page.timers.size, 0);
  } finally { page.restore(); }
});

test('capture.get resolves media targets and viewport frames resize with the page', async () => {
  const page = fakePage('example.test', { intent: { media: { url: 'https://example.test/image.jpg' } } });
  try {
    const media = { isConnected: true, src: 'https://example.test/image.jpg' };
    page.document.querySelectorAll = () => [media];
    page.update({ kind: 'media', state: 'saving' }); await settle();
    assert.equal(page.frames.at(-1).target, media);
    assert.equal(page.frames[0].destroyed, true);
    page.update({ captureId: 'two', kind: 'page', state: 'saved' }); await settle();
    const rect = page.frames.at(-1).target.getBoundingClientRect();
    assert.equal(rect.width, 1006);
    assert.equal(page.frames.at(-1).options.kind, 'page');
  } finally { page.restore(); }
});

test('marks retain six-second auto-close and three-second pointer-leave timing', async () => {
  const page = fakePage();
  try {
    page.update({ state: 'saved' }); await settle();
    assert.equal([...page.timers.values()][0].delay, 6000);
    const frame = page.frames[0];
    frame.info.onEnter();
    assert.equal(page.timers.size, 0);
    frame.info.onLeave();
    const timer = [...page.timers.values()][0];
    assert.equal(timer.delay, 3000);
    timer.fn();
    assert.equal(frame.destroyed, true);
  } finally { page.restore(); }
});

test('X background metadata updates restore focus and text selection', async () => {
  const page = fakePage('twitter.com');
  try {
    page.update({ state: 'saved' }); await settle();
    const card = page.card();
    const tags = card.querySelector('[data-tags]');
    card.activeElement = tags;
    tags.selectionStart = 1; tags.selectionEnd = 3;
    page.message({ action: 'captureMetadata.update', captureId: 'one', tags: ['updated'], note: '' });
    assert.equal(page.card().querySelector('[data-tags]'), tags);
    assert.equal(tags.focused, true);
    assert.equal(tags.selectionStart, 1);
    assert.equal(tags.selectionEnd, 3);
  } finally { page.restore(); }
});

test('a saved receipt with a duplicate disposition reads as already kept, through later polls', async () => {
  const page = fakePage('example.test');
  try {
    page.update({ state: 'saved', disposition: 'duplicate', savedAt: '2026-09-30' }); await settle();
    assert.equal(page.frames[0].state, 'already');
    assert.equal(page.frames[0].info.savedAt, '2026-09-30');
    page.message({ action: 'archiveJobStatus', captureId: 'one', status: 'completed' }); await settle();
    assert.equal(page.frames.at(-1).state, 'already');
    page.update({ state: 'saved', disposition: 'accepted' }); await settle();
    assert.equal(page.frames.at(-1).state, 'kept');
  } finally { page.restore(); }
});

test('fresh-copy screenshot failure stays actionable and cannot affect a newer capture', async () => {
  const page = fakePage('example.test', { intent: { captureId: 'one', createdAt: '2026-09-30T12:00:00Z', options: { saveMode: 'full' } } });
  try {
    page.update({ state: 'duplicate' }); await settle();
    assert.equal(page.frames[0].info.savedAt, '2026-09-30T12:00:00Z');
    const originalSend = page.browserAPI.runtime.sendMessage;
    page.browserAPI.runtime.sendMessage = async message => {
      if (message.action === 'captureScreenshot') throw new Error('Screenshot unavailable');
      return originalSend(message);
    };
    await page.frames[0].info.onSaveAgain();
    assert.equal(page.frames[0].state, 'failed');
    assert.equal(page.frames[0].info.error, 'Screenshot unavailable');
    let resolve;
    page.browserAPI.runtime.sendMessage = message => message.action === 'captureScreenshot'
      ? new Promise(done => { resolve = done; }) : originalSend(message);
    const retry = page.frames[0].info.onRetry();
    page.update({ captureId: 'two', state: 'saved' }); await settle();
    resolve({ screenshot: null }); await retry;
    assert.equal(page.frames.at(-1).state, 'kept');
  } finally { page.restore(); }
});

test('Escape ignores an absent presentation and closes visible marks or an X card', async () => {
  for (const hostname of ['example.test', 'x.com']) {
    const page = fakePage(hostname);
    try {
      page.key('Escape');
      page.message({ action: 'captureCard.update', kind: 'page', state: 'saving' });
      assert.ok(hostname === 'x.com' ? page.card() : page.frames.length, 'initial Escape does not dismiss a later capture');
      page.key('Enter');
      assert.ok(hostname === 'x.com' ? page.card() : !page.frames[0].destroyed);
      page.key('Escape');
      assert.equal(page.card(), undefined);
      if (hostname !== 'x.com') assert.equal(page.frames[0].destroyed, true);
      page.message({ action: 'captureCard.update', state: 'saved' });
      assert.equal(page.card(), undefined);
      assert.equal(page.frames.length, hostname === 'x.com' ? 0 : 1);
    } finally { page.restore(); }
  }
  const page = fakePage('x.com');
  try {
    page.update({ state: 'saving' }); await settle();
    page.document.documentElement.children[0].remove();
    page.key('Escape');
    page.update({ state: 'saved' });
    assert.ok(page.card(), 'Escape with a disconnected root does not suppress updates for the current capture');
  } finally { page.restore(); }
});

test('failed, stalled and queued transitions reappear after dismissal in both skins', async () => {
  for (const hostname of ['example.test', 'x.com']) {
    for (const state of ['failed', 'stalled', 'queued']) {
      const page = fakePage(hostname);
      try {
        page.update({ state: 'saving' }); await settle();
        page.key('Escape');
        page.update({ state: 'processing' });
        assert.equal(page.card(), undefined);
        if (hostname !== 'x.com') assert.equal(page.frames.length, 1);
        page.message({ action: 'archiveJobStatus', captureId: 'one', status: state, error: 'Needs retry' });
        assert.equal(page.timers.size, 0);
        if (hostname === 'x.com') {
          assert.ok(page.card());
          assert.ok(descendants(page.card()).some(node => node.textContent === 'Retry'));
        } else {
          assert.equal(page.frames.length, 2);
          assert.equal(page.frames.at(-1).state, 'failed');
          assert.equal(page.frames.at(-1).info.error, 'Needs retry');
        }
        page.key('Escape');
        page.update({ state });
        assert.equal(page.card(), undefined, 'same-state update respects dismissal');
        if (hostname !== 'x.com') assert.equal(page.frames.length, 2);
        page.update({ state: 'saving' });
        page.update({ state });
        assert.ok(hostname === 'x.com' ? page.card() : !page.frames.at(-1).destroyed, 'a new retryable transition reappears');
      } finally { page.restore(); }
    }
  }
});

test('capture.get resolves hints by media, target or source URL and pins the connected element', async t => {
  const previous = globalThis.__nodrawCaptureTargets;
  globalThis.__nodrawCaptureTargets = new Map();
  t.after(() => {
    if (previous === undefined) delete globalThis.__nodrawCaptureTargets;
    else globalThis.__nodrawCaptureTargets = previous;
  });
  for (const field of ['media', 'targetUrl', 'sourcePageUrl']) {
    const url = `https://example.test/${field}`;
    const intent = field === 'media' ? { media: { url } } : { [field]: url };
    const hinted = { isConnected: true };
    const competing = { isConnected: true, src: url };
    rememberCaptureTarget(url, hinted);
    const page = fakePage('example.test', { intent });
    try {
      page.document.querySelectorAll = () => [competing];
      page.update({ kind: 'media', state: 'saving' }); await settle();
      const frame = page.frames.at(-1);
      assert.equal(frame.target, hinted, `${field} hint wins over the URL scan`);
      rememberCaptureTarget(url, competing);
      page.update({ kind: 'media', state: 'saved' });
      assert.equal(page.frames.at(-1), frame, 'the cached connected element never jumps to a new hint');
      hinted.isConnected = false;
      page.update({ kind: 'media', state: 'duplicate' });
      assert.equal(page.frames.at(-1).target, competing);
      assert.equal(frame.destroyed, true);
    } finally { page.restore(); }
  }
});

test('a site post capture frames the post its button left, not the whole viewport', async t => {
  const previous = globalThis.__nodrawCaptureTargets;
  globalThis.__nodrawCaptureTargets = new Map();
  t.after(() => {
    if (previous === undefined) delete globalThis.__nodrawCaptureTargets;
    else globalThis.__nodrawCaptureTargets = previous;
  });
  const permalink = 'https://www.reddit.com/r/example/comments/abc/title/';
  const feed = 'https://www.reddit.com/r/example/';
  const post = { isConnected: true };
  const glyph = { isConnected: true };
  rememberCaptureTarget([permalink, feed], post, glyph);
  const page = fakePage('www.reddit.com', { intent: { targetUrl: permalink, sourcePageUrl: feed } });
  try {
    page.update({ kind: 'page', state: 'saving' }); await settle();
    assert.equal(page.frames.at(-1).target, post);
    assert.equal(page.frames.at(-1).options.avoid, glyph, 'saving and kept captions keep off the glyph');
    assert.equal(globalThis.__nodrawCaptureTargets.size, 0, 'claimed, so a later toolbar capture frames the page');
  } finally { page.restore(); }
});

test('disconnected hints are ignored and the existing media URL scan remains available', async t => {
  const previous = globalThis.__nodrawCaptureTargets;
  globalThis.__nodrawCaptureTargets = new Map();
  t.after(() => {
    if (previous === undefined) delete globalThis.__nodrawCaptureTargets;
    else globalThis.__nodrawCaptureTargets = previous;
  });
  const url = 'https://example.test/original.jpg';
  rememberCaptureTarget(url, { isConnected: false });
  const page = fakePage('example.test', { intent: { media: { url } } });
  try {
    const media = { isConnected: true, currentSrc: url };
    page.document.querySelectorAll = () => [media];
    page.update({ kind: 'media', state: 'saving' }); await settle();
    assert.equal(page.frames.at(-1).target, media);
    assert.equal(globalThis.__nodrawCaptureTargets.has(url), false);
  } finally { page.restore(); }
});
