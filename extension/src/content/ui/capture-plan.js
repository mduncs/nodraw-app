import { pageUsesPaper } from './marks.js';

export const CAPTURE_PLAN_CSS = `
  :host { all:initial !important; position:fixed !important; inset:0 !important;
    display:block !important; z-index:2147483646 !important; pointer-events:none !important; }
  *, *::before, *::after { box-sizing:border-box; pointer-events:none; }
  svg { position:absolute; inset:0; width:100%; height:100%; }
  .piece { position:absolute; color:#d87d0b; }
  .corner { position:absolute; width:30px; height:30px; border:0 solid currentColor; }
  .tl { top:-9px; left:-9px; border-width:4px 0 0 4px; }
  .tr { top:-9px; right:-9px; border-width:4px 4px 0 0; }
  .bl { bottom:-9px; left:-9px; border-width:0 0 4px 4px; }
  .br { bottom:-9px; right:-9px; border-width:0 4px 4px 0; }
  .piece.linked { color:#11110f; outline:1.5px dashed currentColor; outline-offset:9px; }
  .piece.linked.paper { color:#eeeae2; }
  .linked .corner { display:none; }
  .caption { position:absolute; left:-9px; top:calc(100% + 14px); padding:5px 7px;
    background:#11110f; color:#eeeae2; border:1px solid #3a3833; white-space:nowrap;
    font:600 11px/1 "SF Mono",SFMono-Regular,Menlo,monospace; letter-spacing:.08em; }
  .piece:not(.linked) .caption { background:#d87d0b; color:#11110f; border-color:#d87d0b; }
  /* The hovered piece's own marks caption hangs below it, so its plan label sits above. */
  .caption[data-place="above"] { top:auto; bottom:calc(100% + 14px); }
  .caption[data-place="inside"] { top:10px; left:10px; }
  .caption[data-place="inside-low"] { top:auto; bottom:10px; left:10px; }
`;

const SVG_NS = 'http://www.w3.org/2000/svg';
let visiblePlan = null;
let maskSequence = 0;

function svgNode(doc, tag, attributes) {
  const node = doc.createElementNS(SVG_NS, tag);
  for (const [key, value] of Object.entries(attributes || {})) node.setAttribute(key, String(value));
  return node;
}

// Carousels and scrollers clip their children: frame only the part a reader can see.
function visibleRect(element, doc, win) {
  const rect = element.getBoundingClientRect();
  let left = rect.left, top = rect.top, right = rect.left + rect.width, bottom = rect.top + rect.height;
  for (let node = element.parentElement; node && node !== doc.body && node !== doc.documentElement; node = node.parentElement) {
    const style = win.getComputedStyle?.(node);
    const clipsX = style?.overflowX && style.overflowX !== 'visible';
    const clipsY = style?.overflowY && style.overflowY !== 'visible';
    if (!clipsX && !clipsY) continue;
    const bounds = node.getBoundingClientRect();
    if (clipsX) { left = Math.max(left, bounds.left); right = Math.min(right, bounds.left + bounds.width); }
    if (clipsY) { top = Math.max(top, bounds.top); bottom = Math.min(bottom, bounds.top + bounds.height); }
  }
  return { left, top, width: Math.max(0, right - left), height: Math.max(0, bottom - top) };
}

function pieceLabel(piece, number) {
  if (piece.label) return piece.label;
  const scope = piece.scope || (piece.level > 1 ? 'QUOTE IN QUOTE' : piece.level === 1 ? 'QUOTED POST' : 'THIS POST');
  const kind = !piece.kind || piece.kind === 'post' ? 'SCREENSHOT' : piece.kind.toUpperCase();
  return piece.included === false ? `LINKED · ${scope}` : `${number} · ${kind} · ${scope}`;
}

// A carousel's scrolled-out pieces are still saved. The visible piece before them (or the
// first visible one, when they lead) says how many, so the numbering has no silent gap.
function labelOffscreen(entries) {
  const extra = new Map();
  let previous = null;
  let leading = 0;
  for (const entry of entries) {
    if (entry.piece.included === false) continue;
    if (!entry.offscreen) {
      if (leading) extra.set(entry, leading);
      leading = 0;
      previous = entry;
    } else if (previous) extra.set(previous, (extra.get(previous) || 0) + 1);
    else leading++;
  }
  for (const entry of entries) {
    const count = extra.get(entry);
    entry.caption.textContent = count ? `${entry.label} · +${count} OFF-SCREEN` : entry.label;
  }
}

export function hideCapturePlan() {
  if (!visiblePlan) return;
  const plan = visiblePlan;
  visiblePlan = null;
  plan.destroy();
}

export function showCapturePlan(pieces, { mode = 'full' } = {}) {
  hideCapturePlan();
  const doc = globalThis.document;
  const win = doc?.defaultView || globalThis.window;
  const targets = (pieces || []).filter(piece => piece.element?.isConnected !== false
    && typeof piece.element?.getBoundingClientRect === 'function');
  if (!doc || !win || !targets.length) return;

  const host = doc.createElement('div');
  host.setAttribute('data-nodraw-capture-plan', mode);
  host.setAttribute('aria-hidden', 'true');
  host.style.pointerEvents = 'none';
  const shadow = host.attachShadow({ mode: 'closed' });
  const style = doc.createElement('style');
  style.textContent = CAPTURE_PLAN_CSS;
  shadow.appendChild(style);

  const maskId = `nodraw-plan-mask-${++maskSequence}`;
  const svg = svgNode(doc, 'svg');
  const defs = svgNode(doc, 'defs');
  const mask = svgNode(doc, 'mask', { id: maskId, x: 0, y: 0, width: '100%', height: '100%', maskUnits: 'userSpaceOnUse', maskContentUnits: 'userSpaceOnUse' });
  const background = svgNode(doc, 'rect', { width: '100%', height: '100%', fill: 'white' });
  mask.appendChild(background);
  defs.appendChild(mask);
  svg.appendChild(defs);
  const dim = svgNode(doc, 'rect', { width: '100%', height: '100%', fill: '#11110f', 'fill-opacity': '.35', mask: `url(#${maskId})` });
  svg.appendChild(dim);
  shadow.appendChild(svg);

  let includedCount = 0;
  const entries = targets.map(piece => {
    if (piece.included !== false) includedCount++;
    const hole = svgNode(doc, 'rect', { fill: 'black' });
    mask.appendChild(hole);
    const frame = doc.createElement('div');
    frame.className = `piece${piece.included === false ? ' linked' : ''}`;
    for (const corner of ['tl', 'tr', 'bl', 'br']) {
      const mark = doc.createElement('span');
      mark.className = `corner ${corner}`;
      frame.appendChild(mark);
    }
    const caption = doc.createElement('span');
    caption.className = 'caption';
    const label = pieceLabel(piece, includedCount);
    caption.textContent = label;
    frame.appendChild(caption);
    shadow.appendChild(frame);
    // A second piece of the same element (YouTube's video + transcripts) keeps its caption
    // inside the frame, clear of the first piece's caption and the hover marks below.
    const shared = targets.slice(0, targets.indexOf(piece)).some(other => other.element === piece.element);
    return { piece, frame, hole, caption, shared, label };
  });

  let frameId = null;
  let destroyed = false;
  const update = () => {
    frameId = null;
    if (destroyed) return;
    const width = win.innerWidth || doc.documentElement.clientWidth;
    const height = win.innerHeight || doc.documentElement.clientHeight;
    let connected = 0;
    let shown = 0;
    for (const entry of entries) {
      const { piece, frame, hole, caption, shared } = entry;
      const attached = piece.element.isConnected !== false;
      const rect = attached ? visibleRect(piece.element, doc, win) : null;
      if (attached) connected++;
      const valid = rect && [rect.left, rect.top, rect.width, rect.height].every(Number.isFinite)
        && rect.width > 0 && rect.height > 0;
      entry.offscreen = attached && !valid;
      frame.style.display = valid ? '' : 'none';
      hole.setAttribute('width', '0');
      hole.setAttribute('height', '0');
      if (!valid) continue;
      frame.className = `piece${piece.included === false ? ` linked${pageUsesPaper(piece.element, doc) ? ' paper' : ''}` : ''}`;
      Object.assign(frame.style, { left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.width}px`, height: `${rect.height}px` });
      // Captions sit below their frame unless the hovered marks own that spot or a tall
      // piece runs past the viewport; then above, or inside when the frame starts at the top.
      const below = !piece.captionAbove && rect.top + rect.height + 40 <= height;
      if (shared) caption.setAttribute('data-place', 'inside-low');
      else if (below) caption.removeAttribute?.('data-place');
      else caption.setAttribute('data-place', rect.top < 40 ? 'inside' : 'above');
      const left = Math.max(0, rect.left);
      const top = Math.max(0, rect.top);
      const right = Math.min(width, rect.left + rect.width);
      const bottom = Math.min(height, rect.top + rect.height);
      hole.setAttribute('x', String(left));
      hole.setAttribute('y', String(top));
      hole.setAttribute('width', String(Math.max(0, right - left)));
      hole.setAttribute('height', String(Math.max(0, bottom - top)));
      if (right > left && bottom > top) shown++;
    }
    labelOffscreen(entries);
    // A scrolled-out plan must not leave an unbroken dim layer over the page.
    dim.style.display = shown ? '' : 'none';
    if (!connected) hideCapturePlan();
  };
  const schedule = () => {
    if (destroyed || frameId !== null) return;
    frameId = win.requestAnimationFrame(update);
  };
  const Resize = win.ResizeObserver || globalThis.ResizeObserver;
  const Mutation = win.MutationObserver || globalThis.MutationObserver;
  const resizeObserver = Resize ? new Resize(schedule) : null;
  const observed = new Set();
  for (const { element } of targets) {
    for (let node = element; node; node = node.parentElement) {
      if (observed.has(node)) continue;
      observed.add(node);
      resizeObserver?.observe(node);
    }
  }
  const mutationObserver = Mutation ? new Mutation(schedule) : null;
  mutationObserver?.observe(doc.documentElement, { childList: true, subtree: true, attributes: true });
  win.addEventListener('scroll', schedule, true);
  win.addEventListener('resize', schedule);
  visiblePlan = {
    destroy() {
      destroyed = true;
      if (frameId !== null) win.cancelAnimationFrame(frameId);
      resizeObserver?.disconnect();
      mutationObserver?.disconnect();
      win.removeEventListener('scroll', schedule, true);
      win.removeEventListener('resize', schedule);
      host.remove();
    }
  };
  (doc.documentElement || doc.body).appendChild(host);
  update();
}

export function modifierMode({ shiftKey = false, altKey = false } = {}) {
  return altKey ? (shiftKey ? 'quoted' : 'text') : (shiftKey ? 'quick' : 'full');
}

export function watchModifiers(onModeChange) {
  const win = globalThis.document?.defaultView || globalThis.window;
  if (!win) return () => {};
  let mode = 'full';
  const update = event => {
    const next = event.type === 'blur' ? 'full' : modifierMode(event);
    if (next === mode) return;
    mode = next;
    onModeChange(mode, event);
  };
  win.addEventListener('keydown', update, true);
  win.addEventListener('keyup', update, true);
  win.addEventListener('blur', update);
  // Pointer events give the correct initial state when a modifier was held before hover.
  win.addEventListener('pointermove', update, true);
  return () => {
    win.removeEventListener('keydown', update, true);
    win.removeEventListener('keyup', update, true);
    win.removeEventListener('blur', update);
    win.removeEventListener('pointermove', update, true);
  };
}
