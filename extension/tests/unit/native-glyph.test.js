import assert from 'node:assert/strict';
import test from 'node:test';
import { renderNativeGlyph } from '../../src/content/modules/native-glyph.js';
import { createCaptureButton } from '../../src/content/modules/capture-button.js';
import { borrowedButtonClasses } from '../../src/content/content-youtube.js';
import { redditVoteAnchor } from '../../src/content/content-reddit.js';

const MODES = {
  full: { icon: 'download', label: 'Video' },
  quick: { icon: 'audio', label: 'Audio' },
  text: { icon: 'archive', label: 'Full archive' }
};

function glyph() {
  const animations = [];
  const attrs = {};
  return {
    animations, attrs, style: {}, innerHTML: '', title: '',
    setAttribute(name, value) { attrs[name] = value; },
    querySelector: () => ({ animate: (...args) => animations.push(args) })
  };
}

test('a native glyph keeps the site colour at rest and shows capture state in its icon only', () => {
  const button = glyph();
  const getIcon = (type, size) => `${type}@${size}`;
  renderNativeGlyph(button, 'hover', { mode: 'quick' }, { getIcon, modes: MODES, size: 24 });
  assert.equal(button.innerHTML, 'audio@24');
  assert.equal(button.style.color, '');
  assert.equal(button.title, 'Save to NoDraw — click Video · ⇧ Audio · ⌥ Full archive');
  assert.equal(button.attrs['aria-label'], button.title);

  renderNativeGlyph(button, 'saving', {}, { getIcon, modes: MODES, size: 24 });
  assert.equal(button.innerHTML, 'loading@24');
  assert.equal(button.style.color, '#d87d0b');
  assert.equal(button.animations.length, 1, 'the loader spins without page CSS (shadow roots)');

  renderNativeGlyph(button, 'kept', {}, { getIcon, modes: MODES, size: 24 });
  assert.equal(button.innerHTML, 'success@24');
  assert.equal(button.style.color, '#d87d0b');

  renderNativeGlyph(button, 'failed', { error: 'site refused download' }, { getIcon, modes: MODES, size: 24 });
  assert.equal(button.innerHTML, 'error@24');
  assert.equal(button.style.color, '#e5484d');
  assert.equal(button.title, 'Not saved: site refused download');

  renderNativeGlyph(button, 'idle', {}, { getIcon, modes: MODES, size: 24 });
  assert.equal(button.style.color, '', 'back to the site colour after the kept timer');
});

test('the YouTube glyph borrows the bar’s tonal icon-button classes without segment or label variants', () => {
  const button = names => ({ classList: names.split(' ') });
  const like = button('ytSpecButtonShapeNextHost ytSpecButtonShapeNextTonal ytSpecButtonShapeNextMono ytSpecButtonShapeNextSizeM ytSpecButtonShapeNextIconLeading ytSpecButtonShapeNextSegmentedStart other');
  const dislike = button('ytSpecButtonShapeNextHost ytSpecButtonShapeNextTonal ytSpecButtonShapeNextMono ytSpecButtonShapeNextSizeM ytSpecButtonShapeNextIconButton ytSpecButtonShapeNextSegmentedEnd');
  assert.deepEqual(borrowedButtonClasses([like, dislike]), [
    'ytSpecButtonShapeNextHost', 'ytSpecButtonShapeNextTonal', 'ytSpecButtonShapeNextMono',
    'ytSpecButtonShapeNextSizeM', 'ytSpecButtonShapeNextIconButton'
  ]);
  assert.deepEqual(borrowedButtonClasses([like]), [
    'ytSpecButtonShapeNextHost', 'ytSpecButtonShapeNextTonal', 'ytSpecButtonShapeNextMono',
    'ytSpecButtonShapeNextSizeM', 'ytSpecButtonShapeNextIconButton'
  ], 'a labelled pill becomes an icon button');
  assert.deepEqual(borrowedButtonClasses([button('plain')]), [], 'no YouTube shape classes, CSS fallback only');
});

test('the Reddit glyph anchors on the action-row child that holds the vote pill', () => {
  const vote = { tag: 'vote' };
  const wrapper = { contains: node => node === vote };
  const comments = { contains: () => false };
  const row = {
    children: [wrapper, comments],
    querySelector: selector => selector.includes('rpl-vote-button-group') ? vote : null
  };
  const root = { querySelector: selector => selector.includes('shreddit-post-container') ? row : null };
  assert.equal(redditVoteAnchor(root), wrapper);
  assert.equal(redditVoteAnchor({ querySelector: () => null }), null, 'no action row, no glyph');
  assert.equal(redditVoteAnchor(null), null, 'closed or missing shadow root');
});

test('the hover caption names the held modifier’s mode', () => {
  const sets = [];
  let modifierHandler;
  const button = new EventTarget();
  button.dataset = {};
  createCaptureButton({
    button, target: { id: 'media' }, submit: async () => ({ success: true }), url: 'https://example.test/v',
    getPieces: () => [], modeLabels: { quick: '⇧ · audio only', text: '⌥ · full archive' },
    presentation: {
      attachMarks: () => ({ set: (state, info) => sets.push([state, info.modeLabel]), destroy() {} }),
      showCapturePlan() {}, hideCapturePlan() {},
      watchModifiers: fn => { modifierHandler = fn; return () => {}; }
    },
    runtime: null, clock: { setTimeout: () => 0, clearTimeout() {} }
  });
  button.dispatchEvent(Object.assign(new Event('mouseenter'), { shiftKey: false, altKey: false }));
  modifierHandler('quick');
  modifierHandler('text');
  modifierHandler('full');
  assert.deepEqual(sets, [['hover', undefined], ['hover', '⇧ · audio only'], ['hover', '⌥ · full archive'], ['hover', undefined]]);
});
