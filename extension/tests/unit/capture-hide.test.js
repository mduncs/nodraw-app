import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { CAPTURE_HIDE_RULE, withArchiverUIHidden } from '../../src/content/modules/capture-hide.js';

function fakePage() {
  const head = { children: [], appendChild(el) { this.children.push(el); el.parent = this; } };
  const doc = {
    head,
    createElement: () => ({
      attrs: {}, textContent: '',
      setAttribute(name, value) { this.attrs[name] = value; },
      remove() { this.parent.children.splice(this.parent.children.indexOf(this), 1); }
    })
  };
  const frames = [];
  const win = { requestAnimationFrame: fn => frames.push(fn) };
  const flushFrame = () => frames.splice(0).forEach(fn => fn());
  return { doc, win, head, flushFrame };
}

test('the capture runs two frames after the hide rule lands, then the rule goes', async () => {
  const { doc, win, head, flushFrame } = fakePage();
  const glyph = { style: { display: 'flex' } };
  const seen = [];
  const done = withArchiverUIHidden(() => {
    seen.push({ rules: head.children.map(el => el.textContent), glyph: glyph.style.display });
    return 'png';
  }, { doc, win, collapse: new Set([glyph]) });

  assert.deepEqual(head.children.map(el => el.textContent), [CAPTURE_HIDE_RULE]);
  assert.equal(glyph.style.display, 'none');
  await Promise.resolve();
  assert.equal(seen.length, 0);
  flushFrame();
  await Promise.resolve();
  assert.equal(seen.length, 0, 'one frame is not enough');
  flushFrame();
  assert.equal(await done, 'png');
  assert.deepEqual(seen, [{ rules: [CAPTURE_HIDE_RULE], glyph: 'none' }]);
  assert.equal(head.children.length, 0);
  assert.equal(glyph.style.display, 'flex');
});

test('a failed capture still brings the UI back', async () => {
  const { doc, win, head, flushFrame } = fakePage();
  const glyph = { style: { display: '' } };
  const done = withArchiverUIHidden(() => { throw new Error('tab hidden'); }, { doc, win, collapse: [glyph] });
  flushFrame();
  await Promise.resolve();
  flushFrame();
  await assert.rejects(done, /tab hidden/);
  assert.equal(head.children.length, 0);
  assert.equal(glyph.style.display, '');
});

test('hidden UI cannot fade into the screenshot', () => {
  // The menus animate `transition: all`, which would keep a visibility change painted for the fade.
  assert.match(CAPTURE_HIDE_RULE, /visibility:hidden!important/);
  assert.match(CAPTURE_HIDE_RULE, /transition:none!important/);
  assert.match(CAPTURE_HIDE_RULE, /animation:none!important/);
});

test('every site with a screenshot capture uses the shared hide', () => {
  for (const site of ['twitter', 'bluesky', 'reddit', 'youtube']) {
    const source = readFileSync(new URL(`../../src/content/content-${site}.js`, import.meta.url), 'utf8');
    assert.match(source, /withArchiverUIHidden\(\(\) => captureElement\(/, site);
    assert.doesNotMatch(source, /function (hide|show)ArchiverUI/, site);
  }
});
