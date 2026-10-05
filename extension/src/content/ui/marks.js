const INK = '#11110f';
const PAPER = '#eeeae2';
const STATES = new Set(['idle', 'hover', 'saving', 'kept', 'already', 'failed']);

export const MARKS_CSS = `
:host { all: initial; position: fixed !important; display: block;
  pointer-events: none !important; z-index: 2147483646 !important; }
* { box-sizing: border-box; }
.frame { position: absolute; inset: -9px; pointer-events: none; transition: inset 150ms ease; }
.bracket { position: absolute; width: 30px; height: 30px; border: 0 solid #d87d0b; }
.tl { left: 0; top: 0; border-width: 4px 0 0 4px; }
.tr { right: 0; top: 0; border-width: 4px 4px 0 0; }
.bl { left: 0; bottom: 0; border-width: 0 0 4px 4px; }
.br { right: 0; bottom: 0; border-width: 0 4px 4px 0; }
.saving { inset: 10px; }
.failed .bracket { border-color: #e5484d; }
.already .bracket { border-color: var(--nd-neutral, #11110f); }
.caption { position: absolute; left: -9px; top: calc(100% + 14px); display: flex;
  flex-direction: column; align-items: flex-start; pointer-events: auto;
  font: 600 11px/1 "SF Mono", SFMono-Regular, Menlo, monospace; letter-spacing: .08em; }
.caption.inside { top: auto; bottom: 10px; left: 10px; }
.chips { display: flex; white-space: nowrap; text-transform: uppercase; }
.chip { padding: 5px 7px; background: #11110f; color: #eeeae2; border: 1px solid #3a3833; }
.chip + .chip { border-left: 0; color: #b9b3a6; }
.chip.orange { background: #d87d0b; color: #11110f; border-color: #d87d0b; }
.chip.red { background: #e5484d; color: #fff; border-color: #e5484d; }
.chip.kept { color: #d87d0b; }
.actions { display: flex; align-items: center; gap: 5px; }
button { all: unset; cursor: pointer; font: inherit; letter-spacing: inherit; color: inherit; }
button:focus-visible { outline: 1px solid #d87d0b; outline-offset: 2px; }
.editor { pointer-events: auto; margin-top: 0; max-width: min(520px, calc(100vw - 24px)); }
@media (prefers-reduced-motion: reduce) { .frame { transition: none; } }
`;

// Transparent media inherit the page surface rather than their image pixels.
export function pageUsesPaper(target, doc = target?.ownerDocument || globalThis.document) {
  const view = doc?.defaultView || globalThis.window;
  let element = target?.nodeType === 1 ? target : doc?.body;
  let opacity = 0;
  const surface = [0, 0, 0];
  while (element && opacity < 1) {
    const color = view?.getComputedStyle?.(element)?.backgroundColor || '';
    const components = color.match(/[\d.]+/g)?.map(Number);
    if (components?.length >= 3) {
      const alpha = Math.max(0, Math.min(1, components[3] ?? 1));
      const contribution = alpha * (1 - opacity);
      surface.forEach((value, index) => { surface[index] = value + components[index] * contribution; });
      opacity += contribution;
    }
    element = element.parentElement;
  }
  const rgb = surface.map(value => {
    const channel = (value + 255 * (1 - opacity)) / 255;
    return channel <= 0.04045 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2] < 0.179;
}

function defaultCaption(target, kind) {
  const width = target?.naturalWidth || target?.videoWidth;
  const height = target?.naturalHeight || target?.videoHeight;
  const extension = (target?.currentSrc || target?.src || '').split(/[?#]/)[0].match(/\.([a-z0-9]+)$/i)?.[1];
  // A player wrapper (YouTube's) reads as the video it holds.
  const element = { VIDEO: 'VIDEO', IMG: 'IMAGE', AUDIO: 'AUDIO' }[target?.tagName]
    || (target?.querySelector?.('video') ? 'VIDEO' : undefined);
  if (width && height) return `${width}×${height} ${(extension || element || 'IMAGE').toUpperCase()}`;
  // A video that has not loaded metadata yet still reads as a video, not "MEDIA".
  return element || kind.toUpperCase();
}

function savedDate(value) {
  if (!value) return '';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? String(value) : date.toLocaleDateString('en-US', {
    month: 'short', day: 'numeric', timeZone: 'UTC'
  });
}

export function attachMarks(target, { kind = 'media', avoid = null } = {}) {
  const doc = target?.ownerDocument || globalThis.document;
  const view = doc.defaultView || globalThis.window;
  const elementTarget = target?.nodeType === 1;
  const host = doc.createElement('div');
  host.setAttribute('data-nodraw-marks', kind);
  host.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483646;display:none;';
  const root = host.attachShadow({ mode: 'closed' });
  const style = doc.createElement('style');
  style.textContent = MARKS_CSS;
  root.appendChild(style);
  const frame = doc.createElement('div');
  const corners = ['tl', 'tr', 'bl', 'br'].map(position => {
    const corner = doc.createElement('i');
    corner.className = `bracket ${position}`;
    frame.appendChild(corner);
    return corner;
  });
  root.appendChild(frame);
  const caption = doc.createElement('div');
  const insideByKind = kind === 'page' || kind === 'link';
  let captionInside = insideByKind;
  caption.className = `caption${insideByKind ? ' inside' : ''}`;
  root.appendChild(caption);
  const row = doc.createElement('div');
  row.className = 'chips';
  caption.appendChild(row);
  const editorContainer = doc.createElement('div');
  editorContainer.className = 'editor';
  caption.appendChild(editorContainer);
  (doc.documentElement || doc.body).appendChild(host);
  let state = 'idle';
  let info = {};
  let destroyed = false;
  let frameId = null;
  let failureActedOn = false;
  const requestFrame = callback => view.requestAnimationFrame(callback);
  const resizeObserver = view.ResizeObserver ? new view.ResizeObserver(schedule) : null;
  const mutationObserver = view.MutationObserver ? new view.MutationObserver(records => {
    if (elementTarget && !target.isConnected) destroy();
    // Position updates write host styles; ignore every marks host to avoid polling
    // ourselves (or another frame) through attribute notifications.
    else if (!records || records.some(record => record.target !== host
      && !record.target?.hasAttribute?.('data-nodraw-marks'))) schedule();
  }) : null;

  function updatePosition() {
    if (destroyed) return;
    if (elementTarget && !target.isConnected) { destroy(); return; }
    const rect = typeof target === 'function' ? target() : target.getBoundingClientRect();
    if (!rect) { host.style.display = 'none'; return; }
    host.style.left = `${rect.left}px`;
    host.style.top = `${rect.top}px`;
    host.style.width = `${Math.max(0, rect.width ?? rect.right - rect.left)}px`;
    host.style.height = `${Math.max(0, rect.height ?? rect.bottom - rect.top)}px`;
    host.style.display = state === 'idle' ? 'none' : 'block';
    // The caption hangs below the media unless it would cover the control in use there
    // (Reddit's action-row glyph sits just under the post's media); then it moves inside.
    if (!insideByKind) {
      const bottom = rect.top + (rect.height ?? rect.bottom - rect.top);
      const left = rect.left - 9;
      const width = Math.max(caption.getBoundingClientRect?.().width || 0, 160);
      const clear = avoid?.isConnected === false ? null : avoid?.getBoundingClientRect?.();
      const inside = !!clear && clear.width > 0 && clear.left < left + width && clear.right > left
        && clear.top < bottom + 44 && clear.bottom > bottom;
      if (inside !== captionInside) {
        captionInside = inside;
        caption.className = `caption${inside ? ' inside' : ''}`;
      }
    }
  }

  function tick() {
    frameId = null;
    updatePosition();
    // Position-only layout shifts do not notify ResizeObserver.
    if (state === 'hover' || state === 'saving') schedule();
  }

  function schedule() {
    if (!destroyed && frameId === null) frameId = requestFrame(tick);
  }

  function chip(row, text, cls = '') {
    const node = doc.createElement('span');
    node.className = `chip${cls ? ` ${cls}` : ''}`;
    node.textContent = text;
    row.appendChild(node);
    return node;
  }

  let interactive = false;

  function action(node, text, callback, userAction = false) {
    interactive = true;
    const button = doc.createElement('button');
    button.type = 'button';
    button.textContent = text;
    button.addEventListener('click', event => {
      event.stopPropagation();
      if (userAction) failureActedOn = true;
      callback?.(event);
    });
    node.appendChild(button);
  }

  function render() {
    interactive = false;
    frame.className = `frame ${state}`;
    corners.forEach((corner, index) => {
      corner.style.display = state === 'kept' || state === 'already' || index === 0 || index === 3 ? '' : 'none';
    });
    row.replaceChildren();
    if (state === 'hover') {
      chip(row, info.caption || defaultCaption(target, kind));
      chip(row, info.modeLabel || 'click · save');
    } else if (state === 'saving') {
      chip(row, 'SAVING', 'orange');
      if (Number.isFinite(info.progress)) chip(row, `${Math.round(Math.max(0, Math.min(100, info.progress)))}%`);
    } else if (state === 'kept') {
      chip(row, 'KEPT ✓', 'kept');
      const actions = chip(row, '');
      actions.className += ' actions';
      action(actions, 'open', info.onOpen);
      const separator = doc.createElement('span');
      separator.textContent = '·';
      actions.appendChild(separator);
      action(actions, 'tag', info.onTag);
    } else if (state === 'already') {
      chip(row, `KEPT${info.savedAt ? ` ${savedDate(info.savedAt)}` : ''}`);
      action(chip(row, ''), 'save again', info.onSaveAgain, true);
    } else if (state === 'failed') {
      chip(row, 'NOT SAVED', 'red').title = info.error || '';
      action(chip(row, ''), 'retry', info.onRetry, true);
    }
    if (state !== 'idle' && info.onDismiss) action(chip(row, ''), '×', info.onDismiss, true);
    // A caption without actions never takes the pointer from the control beneath it.
    caption.style.pointerEvents = interactive || (info.editor && state !== 'idle') ? '' : 'none';
    if (info.editor && state !== 'idle') {
      if (editorContainer.firstChild !== info.editor) editorContainer.replaceChildren(info.editor);
      editorContainer.style.display = '';
    } else {
      editorContainer.replaceChildren();
      editorContainer.style.display = 'none';
    }
  }

  function set(nextState, nextInfo = {}) {
    if (destroyed) return;
    if (!STATES.has(nextState)) throw new TypeError(`Unknown marks state: ${nextState}`);
    if (state === 'failed' && !failureActedOn && (nextState === 'idle' || nextState === 'hover')) return;
    state = nextState;
    info = nextInfo;
    if (state === 'failed') failureActedOn = false;
    host.style.setProperty('--nd-neutral', pageUsesPaper(target, doc) ? PAPER : INK);
    render();
    updatePosition();
    if (frameId !== null) view.cancelAnimationFrame(frameId);
    frameId = null;
    if (state === 'hover' || state === 'saving') schedule();
  }

  function destroy() {
    if (destroyed) return;
    destroyed = true;
    if (frameId !== null) view.cancelAnimationFrame(frameId);
    frameId = null;
    resizeObserver?.disconnect();
    mutationObserver?.disconnect();
    view.removeEventListener('scroll', schedule, true);
    view.removeEventListener('resize', schedule);
    host.remove();
  }

  caption.addEventListener('mouseenter', event => info.onEnter?.(event));
  caption.addEventListener('mouseleave', event => info.onLeave?.(event));
  view.addEventListener('scroll', schedule, true);
  view.addEventListener('resize', schedule);
  if (elementTarget) resizeObserver?.observe(target);
  mutationObserver?.observe(doc.documentElement, { childList: true, subtree: true, attributes: true });
  updatePosition();
  return { set, destroy };
}
