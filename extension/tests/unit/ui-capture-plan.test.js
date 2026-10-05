import assert from 'node:assert/strict';
import test from 'node:test';
import { CAPTURE_PLAN_CSS, hideCapturePlan, modifierMode, showCapturePlan, watchModifiers } from '../../src/content/ui/capture-plan.js';

function environment(t) {
  const previous = globalThis.document;
  const frames = new Map();
  const listeners = new Map();
  const observers = [];
  let sequence = 0;
  class Node {
    constructor(tag) {
      this.localName = tag;
      this.nodeType = 1;
      this.children = [];
      this.style = {};
      this.attributes = {};
      this.isConnected = true;
      this.rect = { left: 100, top: 100, width: 200, height: 120 };
    }
    appendChild(node) { this.children.push(node); node.parentElement = this; return node; }
    setAttribute(key, value) { this.attributes[key] = String(value); }
    removeAttribute(key) { delete this.attributes[key]; }
    attachShadow(options) { this.shadowOptions = options; this.closedRoot = new Node('shadow'); return this.closedRoot; }
    getBoundingClientRect() { return this.rect; }
    remove() { this.isConnected = false; this.parentElement.children = this.parentElement.children.filter(node => node !== this); }
  }
  class Observer {
    constructor(callback) { this.callback = callback; this.targets = []; this.disconnected = false; observers.push(this); }
    observe(target) { this.targets.push(target); }
    disconnect() { this.disconnected = true; }
  }
  const win = {
    innerWidth: 800, innerHeight: 600, ResizeObserver: Observer, MutationObserver: Observer,
    getComputedStyle: node => ({ backgroundColor: node.background || 'rgb(255, 255, 255)' }),
    requestAnimationFrame(callback) { const id = ++sequence; frames.set(id, callback); return id; },
    cancelAnimationFrame(id) { frames.delete(id); },
    addEventListener(type, callback) { if (!listeners.has(type)) listeners.set(type, new Set()); listeners.get(type).add(callback); },
    removeEventListener(type, callback) { listeners.get(type)?.delete(callback); }
  };
  const doc = { defaultView: win, createElement: tag => new Node(tag), createElementNS: (_ns, tag) => new Node(tag) };
  doc.documentElement = new Node('html');
  doc.body = doc.documentElement.appendChild(new Node('body'));
  globalThis.document = doc;
  const emit = (type, values = {}) => {
    for (const callback of [...(listeners.get(type) || [])]) callback({ type, ...values });
  };
  const flush = () => {
    const pending = [...frames.values()];
    frames.clear();
    pending.forEach(callback => callback());
  };
  const target = (rect = {}) => {
    const node = doc.body.appendChild(new Node('img'));
    Object.assign(node.rect, rect);
    return node;
  };
  const host = () => doc.documentElement.children.find(node => node.attributes['data-nodraw-capture-plan']);
  const nodes = (root, predicate) => [root, ...root.children.flatMap(node => nodes(node, predicate))].filter(predicate);
  t.after(() => {
    hideCapturePlan();
    if (previous === undefined) delete globalThis.document;
    else globalThis.document = previous;
  });
  return { doc, win, frames, listeners, observers, emit, flush, target, host, nodes };
}

test('plan uses one ink overlay with cut-outs and numbered included frames', t => {
  const env = environment(t);
  const elements = [env.target(), env.target({ top: 270 }), env.target({ left: 380 })];
  showCapturePlan(elements.map((element, level) => ({ element, kind: level ? 'image' : 'video', level, included: true })), { mode: 'quoted' });
  const host = env.host();
  assert.equal(host.attributes['data-nodraw-capture-plan'], 'quoted');
  assert.equal(host.style.pointerEvents, 'none');
  assert.deepEqual(host.shadowOptions, { mode: 'closed' });
  assert.equal(env.nodes(host.closedRoot, node => node.localName === 'svg').length, 1);
  const dim = env.nodes(host.closedRoot, node => node.attributes['fill-opacity'])[0];
  assert.equal(dim.attributes.fill, '#11110f');
  assert.equal(dim.attributes['fill-opacity'], '.35');
  assert.equal(env.nodes(host.closedRoot, node => node.attributes.fill === 'black').length, 3);
  assert.deepEqual(env.nodes(host.closedRoot, node => node.className === 'caption').map(node => node.textContent), [
    '1 · VIDEO · THIS POST', '2 · IMAGE · QUOTED POST', '3 · IMAGE · QUOTE IN QUOTE'
  ]);
});

test('a caption with no room below its frame moves above it, or inside at the top edge', t => {
  const env = environment(t);
  const tall = env.target({ top: 100, height: 700 });
  const top = env.target({ top: 10, height: 700 });
  const short = env.target({ top: 100, height: 120 });
  showCapturePlan([tall, top, short].map(element => ({ element, kind: 'image', level: 0, included: true })));
  env.flush();
  const captions = env.nodes(env.host().closedRoot, node => node.className === 'caption');
  assert.deepEqual(captions.map(node => node.attributes['data-place']), ['above', 'inside', undefined]);
  hideCapturePlan();
  const player = env.target({ top: 100, height: 120 });
  showCapturePlan([
    { element: player, kind: 'video', level: 0, included: true, captionAbove: true },
    { element: player, kind: 'transcripts', level: 0, included: true }
  ]);
  env.flush();
  assert.deepEqual(env.nodes(env.host().closedRoot, node => node.className === 'caption').map(node => node.attributes['data-place']),
    ['above', 'inside-low'], 'a second piece of the same element never stacks on the first caption');
  hideCapturePlan();
  showCapturePlan([tall, top, short].map(element => ({ element, kind: 'image', level: 0, included: true })));
  env.flush();
  captions.splice(0, captions.length, ...env.nodes(env.host().closedRoot, node => node.className === 'caption'));
  tall.rect.height = 120;
  env.emit('scroll');
  env.flush();
  assert.equal(captions[0].attributes['data-place'], undefined, 'returns below once there is room');
});

test('a piece inside a clipping carousel is framed only where it shows', t => {
  const env = environment(t);
  const carousel = env.doc.body.appendChild(new (env.doc.createElement('div').constructor)('div'));
  carousel.rect = { left: 100, top: 100, width: 300, height: 200 };
  carousel.overflow = 'hidden';
  const first = carousel.appendChild(env.doc.createElement('img'));
  first.rect = { left: 100, top: 100, width: 240, height: 200 };
  const second = carousel.appendChild(env.doc.createElement('img'));
  second.rect = { left: 350, top: 100, width: 240, height: 200 };
  const hidden = carousel.appendChild(env.doc.createElement('img'));
  hidden.rect = { left: 600, top: 100, width: 240, height: 200 };
  env.win.getComputedStyle = node => ({ backgroundColor: 'rgb(255, 255, 255)',
    overflowX: node.overflow || 'visible', overflowY: node.overflow || 'visible' });
  showCapturePlan([first, second, hidden].map(element => ({ element, kind: 'gif', level: 0, included: true })));
  env.flush();
  const frames = env.nodes(env.host().closedRoot, node => typeof node.className === 'string' && node.className.startsWith('piece'));
  assert.deepEqual(frames.map(frame => [frame.style.left, frame.style.width, frame.style.display]),
    [['100px', '240px', ''], ['350px', '50px', ''], [undefined, undefined, 'none']]);
  const captions = env.nodes(env.host().closedRoot, node => node.className === 'caption');
  assert.deepEqual(captions.map(caption => caption.textContent),
    ['1 · GIF · THIS POST', '2 · GIF · THIS POST · +1 OFF-SCREEN', '3 · GIF · THIS POST'],
    'the scrolled-out third GIF is still announced');
});

test('linked pieces use dashed neutral frames and labels can be overridden', t => {
  const env = environment(t);
  const linked = env.target();
  linked.background = 'rgb(17, 17, 15)';
  showCapturePlan([
    { element: env.target(), kind: 'text', level: 0, included: true, label: 'TEXT · THIS POST' },
    { element: linked, kind: 'image', level: 1, included: false }
  ]);
  const root = env.host().closedRoot;
  assert.equal(env.nodes(root, node => node.className?.includes('linked'))[0].className, 'piece linked paper');
  assert.deepEqual(env.nodes(root, node => node.className === 'caption').map(node => node.textContent), ['TEXT · THIS POST', 'LINKED · QUOTED POST']);
  assert.match(CAPTURE_PLAN_CSS, /\.piece\.linked \{[^}]*outline:1\.5px dashed currentColor; outline-offset:9px/);
  assert.match(CAPTURE_PLAN_CSS, /\.linked \.corner \{ display:none; \}/);
});

test('dim layer fills the SVG viewport without scaling CSS-pixel holes on resize', t => {
  const env = environment(t);
  showCapturePlan([{ element: env.target({ left: 40, top: 50, width: 200, height: 120 }), included: true }]);
  const root = env.host().closedRoot;
  const svg = env.nodes(root, node => node.localName === 'svg')[0];
  const mask = env.nodes(root, node => node.localName === 'mask')[0];
  const background = env.nodes(root, node => node.attributes.fill === 'white')[0];
  const dim = env.nodes(root, node => node.attributes['fill-opacity'])[0];
  const hole = env.nodes(root, node => node.attributes.fill === 'black')[0];
  const check = () => {
    assert.equal(svg.attributes.viewBox, undefined);
    for (const node of [mask, background, dim]) {
      assert.equal(node.attributes.width, '100%');
      assert.equal(node.attributes.height, '100%');
    }
    assert.equal(mask.attributes.x, '0');
    assert.equal(mask.attributes.y, '0');
    assert.equal(hole.attributes.x, '40');
    assert.equal(hole.attributes.y, '50');
    assert.equal(hole.attributes.width, '200');
    assert.equal(hole.attributes.height, '120');
  };
  check();
  env.win.innerWidth = 1200;
  env.win.innerHeight = 900;
  env.emit('resize');
  env.flush();
  check();
});

test('linked pieces do not consume included numbers, including label overrides', t => {
  const env = environment(t);
  showCapturePlan([
    { element: env.target(), kind: 'video', level: 0, included: true },
    { element: env.target(), kind: 'image', level: 1, included: false },
    { element: env.target(), kind: 'image', level: 2, included: true },
    { element: env.target(), included: false, label: 'LINKED · OTHER POST' },
    { element: env.target(), included: true, label: 'TEXT · THIS POST' },
    { element: env.target(), kind: 'image', included: true }
  ]);
  assert.deepEqual(env.nodes(env.host().closedRoot, node => node.className === 'caption').map(node => node.textContent), [
    '1 · VIDEO · THIS POST', 'LINKED · QUOTED POST', '2 · IMAGE · QUOTE IN QUOTE',
    'LINKED · OTHER POST', 'TEXT · THIS POST', '4 · IMAGE · THIS POST'
  ]);
});

test('included post pieces are labeled SCREENSHOT while linked posts retain their scope', t => {
  const env = environment(t);
  showCapturePlan([
    { element: env.target(), kind: 'image', level: 0, included: true },
    { element: env.target(), kind: 'post', level: 0, included: true },
    { element: env.target(), kind: 'post', level: 1, included: false }
  ]);
  assert.deepEqual(env.nodes(env.host().closedRoot, node => node.className === 'caption').map(node => node.textContent), [
    '1 · IMAGE · THIS POST', '2 · SCREENSHOT · THIS POST', 'LINKED · QUOTED POST'
  ]);
});

test('scroll and observer events coalesce, track geometry and clamp cut-outs to the viewport', t => {
  const env = environment(t);
  const element = env.target();
  showCapturePlan([{ element, kind: 'image', level: 0, included: true }]);
  const root = env.host().closedRoot;
  const frame = env.nodes(root, node => node.className === 'piece')[0];
  const hole = env.nodes(root, node => node.attributes.fill === 'black')[0];
  assert.equal(frame.style.top, '100px');
  element.rect = { left: -25, top: 40, width: 200, height: 120 };
  env.emit('scroll');
  env.emit('resize');
  env.observers[0].callback();
  env.observers[1].callback();
  assert.equal(env.frames.size, 1);
  env.flush();
  assert.equal(frame.style.left, '-25px');
  assert.equal(frame.style.top, '40px');
  assert.equal(hole.attributes.x, '0');
  assert.equal(hole.attributes.width, '175');
  assert.equal(env.frames.size, 0);
  element.rect.top = 900;
  env.emit('scroll');
  env.flush();
  const dim = env.nodes(root, node => node.attributes['fill-opacity'])[0];
  assert.equal(dim.style.display, 'none');
});

test('hide cancels pending frames, disconnects observers and removes every tracking listener', t => {
  const env = environment(t);
  showCapturePlan([{ element: env.target(), kind: 'image', level: 0, included: true }]);
  env.emit('scroll');
  assert.equal(env.frames.size, 1);
  hideCapturePlan();
  hideCapturePlan();
  assert.equal(env.host(), undefined);
  assert.equal(env.frames.size, 0);
  assert.ok(env.observers.every(observer => observer.disconnected));
  assert.ok([...env.listeners.values()].every(callbacks => callbacks.size === 0));
});

test('removed pieces lose their hole and the last removal destroys the plan', t => {
  const env = environment(t);
  const first = env.target();
  const second = env.target();
  showCapturePlan([first, second].map(element => ({ element, kind: 'image', level: 0, included: true })));
  const root = env.host().closedRoot;
  first.remove();
  env.observers[1].callback();
  env.flush();
  assert.equal(env.nodes(root, node => node.className === 'piece')[0].style.display, 'none');
  assert.equal(env.nodes(root, node => node.attributes.fill === 'black')[0].attributes.width, '0');
  second.remove();
  env.observers[1].callback();
  env.flush();
  assert.equal(env.host(), undefined);
  assert.ok(env.observers.every(observer => observer.disconnected));
  assert.ok([...env.listeners.values()].every(callbacks => callbacks.size === 0));
});

test('show replaces and cleans up the previous plan; empty pieces clear it', t => {
  const env = environment(t);
  const piece = { element: env.target(), kind: 'post', level: 0, included: true };
  showCapturePlan([piece]);
  const old = env.host();
  showCapturePlan([piece], { mode: 'quick' });
  assert.notEqual(env.host(), old);
  assert.equal(old.isConnected, false);
  assert.ok(env.observers.slice(0, 2).every(observer => observer.disconnected));
  assert.equal(env.listeners.get('scroll').size, 1);
  showCapturePlan([]);
  assert.equal(env.host(), undefined);
});

test('modifier mapping and live changes cover press, release, hover and focus loss', t => {
  const env = environment(t);
  assert.equal(modifierMode(), 'full');
  assert.equal(modifierMode({ shiftKey: true }), 'quick');
  assert.equal(modifierMode({ altKey: true }), 'text');
  assert.equal(modifierMode({ shiftKey: true, altKey: true }), 'quoted');
  const modes = [];
  const unsubscribe = watchModifiers(mode => modes.push(mode));
  env.emit('pointermove', { altKey: true });
  env.emit('keydown', { altKey: true });
  env.emit('keydown', { altKey: true, shiftKey: true });
  env.emit('keyup', { shiftKey: true });
  env.emit('keyup');
  env.emit('keydown', { altKey: true });
  env.emit('blur');
  assert.deepEqual(modes, ['text', 'quoted', 'quick', 'full', 'text', 'full']);
  unsubscribe();
  unsubscribe();
  env.emit('keydown', { shiftKey: true });
  assert.equal(modes.length, 6);
  assert.ok([...env.listeners.values()].every(callbacks => callbacks.size === 0));
});
