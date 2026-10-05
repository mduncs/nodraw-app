import assert from 'node:assert/strict';
import test from 'node:test';
import { attachMarks, MARKS_CSS, pageUsesPaper } from '../../src/content/ui/marks.js';

function fakeDOM() {
  const listeners = new Map();
  const frames = new Map();
  const observers = [];
  let sequence = 0;
  class Node {
    constructor(tagName = '') {
      this.tagName = tagName.toUpperCase();
      this.nodeType = 1;
      this.children = [];
      this.style = { setProperty(name, value) { this[name] = value; } };
      this.attributes = {};
      this.listeners = {};
      this.isConnected = true;
      this.rect = { left: 20, top: 30, width: 400, height: 240 };
      this.background = 'rgba(0, 0, 0, 0)';
      this.ownerDocument = doc;
    }
    appendChild(node) {
      node.parentElement = this;
      this.children.push(node);
      return node;
    }
    replaceChildren(...children) { this.children = children; for (const child of children) child.parentElement = this; }
    get firstChild() { return this.children[0]; }
    setAttribute(key, value) { this.attributes[key] = value; }
    hasAttribute(key) { return key in this.attributes; }
    addEventListener(name, callback) { this.listeners[name] = callback; }
    attachShadow(options) {
      this.shadowMode = options.mode;
      this.closedRoot = new Node();
      return this.closedRoot;
    }
    getBoundingClientRect() { return this.rect; }
    remove() {
      this.isConnected = false;
      if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(node => node !== this);
    }
    click() { this.listeners.click?.({ stopPropagation() {} }); }
  }
  class Observer {
    constructor(callback) { this.callback = callback; this.disconnected = false; observers.push(this); }
    observe(node, options) { this.observed = node; this.options = options; }
    disconnect() { this.disconnected = true; }
  }
  const view = {
    addEventListener(name, callback) {
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name).add(callback);
    },
    removeEventListener(name, callback) { listeners.get(name)?.delete(callback); },
    requestAnimationFrame(callback) { const id = ++sequence; frames.set(id, callback); return id; },
    cancelAnimationFrame(id) { frames.delete(id); },
    getComputedStyle(node) { return { backgroundColor: node.background }; },
    ResizeObserver: Observer,
    MutationObserver: Observer
  };
  const doc = { defaultView: view, createElement: tag => new Node(tag) };
  doc.documentElement = new Node('html');
  doc.documentElement.background = 'rgb(246, 244, 239)';
  doc.body = doc.documentElement.appendChild(new Node('body'));
  const target = doc.body.appendChild(new Node('img'));
  target.naturalWidth = 1600;
  target.naturalHeight = 877;
  target.src = 'https://example.test/photo.jpg';
  function flushFrame() {
    const pending = [...frames];
    frames.clear();
    for (const [, callback] of pending) callback();
  }
  return { doc, view, target, listeners, frames, observers, flushFrame,
    host: () => doc.documentElement.children.find(node => node.attributes['data-nodraw-marks']) };
}

function descendants(node) { return [node, ...node.children.flatMap(descendants)]; }
function textOf(node) { return descendants(node).map(item => item.textContent || '').filter(Boolean).join(' '); }
function caption(dom) { return dom.host().closedRoot.children.find(node => node.className?.startsWith('caption')); }
function frame(dom) { return dom.host().closedRoot.children.find(node => node.className?.startsWith('frame')); }

test('Q1 states use two or four brackets and only caption chips', () => {
  const dom = fakeDOM();
  const marks = attachMarks(dom.target);
  assert.equal(dom.host().shadowMode, 'closed');
  assert.equal(dom.host().shadowRoot, undefined);
  assert.equal(dom.host().style.display, 'none');
  marks.set('hover');
  assert.equal(textOf(caption(dom)), '1600×877 JPG click · save');
  marks.set('hover', { modeLabel: '⇧ · image only' });
  assert.equal(textOf(caption(dom)), '1600×877 JPG ⇧ · image only');
  assert.equal(frame(dom).children.filter(node => node.style.display !== 'none').length, 2);
  marks.set('saving', { progress: 62 });
  assert.equal(frame(dom).className, 'frame saving');
  assert.equal(textOf(caption(dom)), 'SAVING 62%');
  marks.set('saving');
  assert.equal(textOf(caption(dom)), 'SAVING');
  marks.set('kept');
  assert.equal(textOf(caption(dom)), 'KEPT ✓ open · tag');
  assert.equal(frame(dom).children.filter(node => node.style.display !== 'none').length, 4);
  marks.set('already', { savedAt: '2026-09-30T12:00:00Z' });
  assert.equal(textOf(caption(dom)), 'KEPT Sep 30 save again');
  assert.equal(frame(dom).className, 'frame already');
  assert.doesNotMatch(MARKS_CSS, /ruler|gradient|animation:/);
  assert.match(MARKS_CSS, /\.saving \{ inset: 10px; \}/);
  assert.match(MARKS_CSS, /prefers-reduced-motion: reduce[\s\S]*transition: none/);
  marks.destroy();
});

test('an unloaded video and a player wrapper both read as VIDEO, not MEDIA', () => {
  const dom = fakeDOM();
  const video = dom.doc.createElement('video');
  attachMarks(video).set('hover');
  assert.equal(textOf(caption(dom)), 'VIDEO click · save');
  const player = dom.doc.createElement('div');
  player.querySelector = selector => selector === 'video' ? video : null;
  const marks = attachMarks(player);
  marks.set('hover');
  assert.match(textOf(dom.doc.documentElement.children.at(-1).closedRoot.children.find(node => node.className?.startsWith('caption'))), /^VIDEO /);
  marks.destroy();
});

test('the caption moves inside rather than cover the control in use, and only takes the pointer for actions', () => {
  const dom = fakeDOM();
  const glyph = { isConnected: true, rect: { left: 40, right: 72, top: 280, bottom: 312, width: 32, height: 32 } };
  glyph.getBoundingClientRect = () => glyph.rect;
  const marks = attachMarks(dom.target, { avoid: glyph });
  marks.set('hover');
  dom.flushFrame();
  assert.equal(caption(dom).className, 'caption inside', 'the action-row glyph just under the media stays visible');
  assert.equal(caption(dom).style.pointerEvents, 'none', 'a hover caption never steals hover or clicks');
  glyph.rect = { left: 40, right: 72, top: 600, bottom: 632, width: 32, height: 32 };
  dom.flushFrame();
  assert.equal(caption(dom).className, 'caption', 'a distant control leaves the caption below');
  marks.set('kept', { onOpen() {}, onTag() {} });
  assert.equal(caption(dom).style.pointerEvents, '', 'open · tag stay clickable');
  marks.destroy();
});

test('failure remains red through hover/idle until retry and exposes the error', () => {
  const dom = fakeDOM();
  const marks = attachMarks(dom.target);
  let retries = 0;
  marks.set('failed', { error: 'site refused download', onRetry() { retries++; } });
  marks.set('idle');
  marks.set('hover');
  assert.equal(frame(dom).className, 'frame failed');
  assert.equal(textOf(caption(dom)), 'NOT SAVED retry');
  assert.equal(descendants(caption(dom)).find(node => node.textContent === 'NOT SAVED').title, 'site refused download');
  descendants(caption(dom)).find(node => node.textContent === 'retry').click();
  assert.equal(retries, 1);
  marks.set('saving');
  assert.equal(frame(dom).className, 'frame saving');
  marks.destroy();
});

test('tracks resize, scroll and position-only layout shifts in a coalesced frame', () => {
  const dom = fakeDOM();
  const marks = attachMarks(dom.target);
  marks.set('hover');
  dom.listeners.get('scroll').forEach(callback => callback());
  dom.listeners.get('resize').forEach(callback => callback());
  dom.observers[0].callback();
  assert.equal(dom.frames.size, 1);
  dom.target.rect = { left: 40, top: 10, width: 500, height: 300 };
  dom.flushFrame();
  assert.equal(dom.host().style.left, '40px');
  assert.equal(dom.host().style.top, '10px');
  assert.equal(dom.host().style.width, '500px');
  dom.target.rect.top = 70;
  dom.flushFrame();
  assert.equal(dom.host().style.top, '70px');
  marks.destroy();
  assert.equal(dom.host(), undefined);
  assert.equal(dom.frames.size, 0);
  assert.ok(dom.observers.every(observer => observer.disconnected));
  assert.equal(dom.listeners.get('scroll').size, 0);
  assert.equal(dom.listeners.get('resize').size, 0);
  marks.destroy();
  marks.set('kept');
  assert.equal(dom.host(), undefined);
});

test('DOM removal cleans up listeners, observers and pending animation frames', () => {
  const dom = fakeDOM();
  const marks = attachMarks(dom.target);
  marks.set('failed');
  dom.target.remove();
  dom.observers[1].callback();
  assert.equal(dom.host(), undefined);
  assert.ok(dom.observers.every(observer => observer.disconnected));
  assert.equal(dom.frames.size, 0);
  assert.equal(dom.listeners.get('scroll').size, 0);
});

test('uses page surface luminance and follows a selection or viewport rect provider', () => {
  const dom = fakeDOM();
  assert.equal(pageUsesPaper(dom.target), false);
  dom.doc.body.background = 'rgb(21, 32, 43)';
  assert.equal(pageUsesPaper(dom.target), true);
  dom.target.background = 'rgba(255, 255, 255, 0.1)';
  assert.equal(pageUsesPaper(dom.target), true);
  const marks = attachMarks(dom.target);
  marks.set('already');
  assert.equal(dom.host().style['--nd-neutral'], '#eeeae2');
  marks.destroy();
  let rect = { left: 0, top: 0, width: 1024, height: 768 };
  const provider = () => rect;
  provider.ownerDocument = dom.doc;
  const pageMarks = attachMarks(provider, { kind: 'page' });
  pageMarks.set('kept');
  assert.equal(caption(dom).className, 'caption inside');
  rect = { ...rect, height: 640 };
  dom.listeners.get('resize').forEach(callback => callback());
  dom.flushFrame();
  assert.equal(dom.host().style.height, '640px');
  pageMarks.destroy();
});

test('only hover and saving poll frames; persistent states track events without looping', () => {
  const dom = fakeDOM();
  const marks = attachMarks(dom.target);
  for (const state of ['hover', 'saving']) {
    marks.set(state);
    assert.equal(dom.frames.size, 1);
    dom.flushFrame();
    assert.equal(dom.frames.size, 1);
  }
  for (const state of ['kept', 'already', 'failed']) {
    marks.set(state);
    assert.equal(dom.frames.size, 0, `${state} cancels the polling frame`);
    const triggers = [
      () => dom.listeners.get('scroll').forEach(callback => callback()),
      () => dom.listeners.get('resize').forEach(callback => callback()),
      () => dom.observers[0].callback(),
      () => dom.observers[1].callback()
    ];
    for (const trigger of triggers) {
      dom.target.rect.top += 10;
      trigger();
      trigger();
      assert.equal(dom.frames.size, 1);
      dom.flushFrame();
      assert.equal(dom.host().style.top, `${dom.target.rect.top}px`);
      assert.equal(dom.frames.size, 0, `${state} event schedules only one update`);
    }
  }
  marks.set('saving');
  assert.equal(dom.frames.size, 1);
  marks.set('idle');
  assert.equal(dom.frames.size, 0);
  marks.destroy();
});

test('page luminance is computed once per set and never during position updates', () => {
  const dom = fakeDOM();
  let reads = 0;
  const getStyle = dom.view.getComputedStyle;
  dom.view.getComputedStyle = node => { reads++; return getStyle(node); };
  const marks = attachMarks(dom.target);
  assert.equal(reads, 0);
  marks.set('hover');
  assert.equal(reads, 3, 'one walk from transparent media through body to html');
  dom.doc.body.background = 'rgb(21, 32, 43)';
  dom.flushFrame();
  dom.flushFrame();
  assert.equal(reads, 3);
  assert.equal(dom.host().style['--nd-neutral'], '#11110f');
  marks.set('already');
  assert.equal(reads, 5, 'one new walk stops at the opaque body');
  assert.equal(dom.host().style['--nd-neutral'], '#eeeae2');
  dom.listeners.get('scroll').forEach(callback => callback());
  dom.flushFrame();
  assert.equal(reads, 5);
  marks.destroy();
});

test('persistent marks follow page attributes while ignoring every marks host mutation', () => {
  const dom = fakeDOM();
  const marks = attachMarks(dom.target);
  marks.set('kept');
  const observer = dom.observers[1];
  assert.deepEqual(observer.options, { childList: true, subtree: true, attributes: true });
  const otherHost = dom.doc.createElement('div');
  otherHost.setAttribute('data-nodraw-marks', 'media');
  const ownMutation = { type: 'attributes', target: dom.host(), attributeName: 'style' };
  observer.callback([ownMutation, { type: 'attributes', target: otherHost, attributeName: 'style' }]);
  assert.equal(dom.frames.size, 0);
  dom.target.rect.left = 90;
  observer.callback([ownMutation, { type: 'attributes', target: dom.doc.body, attributeName: 'class' }]);
  assert.equal(dom.frames.size, 1);
  dom.flushFrame();
  assert.equal(dom.host().style.left, '90px');
  observer.callback([ownMutation]);
  assert.equal(dom.frames.size, 0);
  marks.destroy();
});

test('persistent selection providers follow page mutations without polling', () => {
  const dom = fakeDOM();
  let rect = { left: 20, top: 30, width: 200, height: 40 };
  const provider = () => rect;
  provider.ownerDocument = dom.doc;
  const marks = attachMarks(provider, { kind: 'selection' });
  marks.set('failed');
  const observer = dom.observers[1];
  assert.equal(observer.observed, dom.doc.documentElement);
  rect = { ...rect, top: 100 };
  observer.callback([{ type: 'attributes', target: dom.doc.body, attributeName: 'style' }]);
  dom.flushFrame();
  assert.equal(dom.host().style.top, '100px');
  assert.equal(dom.frames.size, 0);
  marks.destroy();
  assert.ok(observer.disconnected);
});

test('chip callbacks and inline editor keep interaction in the caption', () => {
  const dom = fakeDOM();
  const marks = attachMarks(dom.target);
  const calls = [];
  const editor = dom.doc.createElement('section');
  editor.textContent = 'tags and note';
  marks.set('kept', {
    editor, onOpen: () => calls.push('open'), onTag: () => calls.push('tag'),
    onDismiss: () => calls.push('dismiss'), onEnter: () => calls.push('enter'), onLeave: () => calls.push('leave')
  });
  const cap = caption(dom);
  for (const label of ['open', 'tag', '×']) descendants(cap).find(node => node.textContent === label).click();
  cap.listeners.mouseenter({});
  cap.listeners.mouseleave({});
  assert.deepEqual(calls, ['open', 'tag', 'dismiss', 'enter', 'leave']);
  assert.ok(descendants(cap).includes(editor));
  const editorContainer = cap.children[1];
  editorContainer.replaceChildren = () => assert.fail('unchanged inline editor must not be detached');
  marks.set('kept', { editor });
  assert.ok(descendants(cap).includes(editor));
  assert.match(MARKS_CSS, /\.caption[\s\S]*pointer-events: auto/);
  assert.throws(() => marks.set('unknown'), /Unknown marks state/);
  marks.destroy();
});
