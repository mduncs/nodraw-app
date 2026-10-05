// NoDraw's own glyphs, menus and bubbles must never appear in a context screenshot.
// One stylesheet rule hides them and also turns their transitions off: the hover menus
// animate `transition: all`, which keeps a visible -> hidden change painted for the whole
// fade, so a capture two frames later still caught a half-faded menu (2026-10-04).
export const CAPTURE_HIDE_RULE =
  '[class*="archiver"]{visibility:hidden!important;transition:none!important;animation:none!important}';

// Two frames: the hide has been committed and painted before captureVisibleTab runs.
export function nextPaint(win = globalThis) {
  return new Promise(resolve => {
    if (typeof win.requestAnimationFrame !== 'function') { resolve(); return; }
    win.requestAnimationFrame(() => win.requestAnimationFrame(() => resolve()));
  });
}

// Runs `capture` with NoDraw's UI hidden. `collapse` takes elements a document rule
// cannot reach (glyphs inside a site's shadow roots); they leave the layout instead.
export async function withArchiverUIHidden(capture, { doc = globalThis.document, win = globalThis, collapse = [] } = {}) {
  const style = doc.createElement('style');
  style.setAttribute('data-nodraw-capture-hide', '');
  style.textContent = CAPTURE_HIDE_RULE;
  (doc.head || doc.documentElement).appendChild(style);
  const collapsed = [...collapse].map(el => [el, el.style.display]);
  for (const [el] of collapsed) el.style.display = 'none';
  try {
    await nextPaint(win);
    return await capture();
  } finally {
    style.remove();
    for (const [el, display] of collapsed) el.style.display = display;
  }
}
