import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import { CAPTURE_INTENT_VERSION, createCaptureIntent } from '../../src/runtime/capture-intent.js';

const fixtureUrl = new URL('../fixtures/capture-intents.json', import.meta.url);
const fixtures = JSON.parse(await readFile(fixtureUrl, 'utf8'));

for (const fixture of fixtures) {
  test(`normalizes ${fixture.name} capture`, () => {
    const intent = createCaptureIntent(fixture.input, {
      captureId: `fixture-${fixture.name}`,
      createdAt: '2026-01-01T00:00:00.000Z'
    });
    assert.equal(intent.schemaVersion, CAPTURE_INTENT_VERSION);
    assert.equal(intent.captureId, `fixture-${fixture.name}`);
    assert.equal(intent.kind, fixture.input.kind);
    assert.match(intent.fingerprint, /^v1-[a-f0-9]{8}$/);
  });
}

test('selection fingerprints preserve distinct selections on one page', () => {
  const base = { kind: 'selection', targetUrl: 'https://example.com/post' };
  const first = createCaptureIntent({ ...base, selection: { text: 'first' } });
  const second = createCaptureIntent({ ...base, selection: { text: 'second' } });
  assert.notEqual(first.fingerprint, second.fingerprint);
});

test('tags are trimmed and de-duplicated', () => {
  const intent = createCaptureIntent({
    targetUrl: 'https://example.com',
    user: { tags: [' art ', 'art', '', 'reference'] }
  });
  assert.deepEqual(intent.user.tags, ['art', 'reference']);
});

test('site-specific data and download controls survive normalization', () => {
  const intent = createCaptureIntent({
    kind: 'media',
    targetUrl: 'https://example.com/art.jpg',
    media: { type: 'image' },
    options: {
      platform: 'googlearts',
      siteData: { assetId: 'asset-42', dateTaken: '1888' },
      download: { max_width: null }
    }
  });

  assert.deepEqual(intent.options.siteData, { assetId: 'asset-42', dateTaken: '1888' });
  assert.deepEqual(intent.options.download, { max_width: null });
});

test('fingerprints distinguish save semantics and richer download payloads', () => {
  const base = {
    kind: 'media',
    targetUrl: 'https://example.com/art.jpg',
    media: { url: 'https://example.com/art.jpg', type: 'image' }
  };
  const quick = createCaptureIntent({ ...base, options: { saveMode: 'quick' } });
  const full = createCaptureIntent({
    ...base,
    options: { saveMode: 'full', screenshot: 'data:image/png;base64,context' }
  });
  const resized = createCaptureIntent({
    ...base,
    options: { saveMode: 'full', screenshot: 'data:image/png;base64,context', download: { width: 2048 } }
  });

  assert.notEqual(quick.fingerprint, full.fingerprint);
  assert.notEqual(full.fingerprint, resized.fingerprint);
});

test('fingerprints distinguish screenshot content, not only screenshot presence', () => {
  const first = createCaptureIntent({
    kind: 'page',
    targetUrl: 'https://example.com/visual-state',
    options: { saveMode: 'full', screenshot: 'data:image/png;base64,first-state' }
  });
  const second = createCaptureIntent({
    kind: 'page',
    targetUrl: 'https://example.com/visual-state',
    options: { saveMode: 'full', screenshot: 'data:image/png;base64,second-state' }
  });

  assert.notEqual(first.fingerprint, second.fingerprint);
});

test('fingerprints are stable across site-data and download key order', () => {
  const first = createCaptureIntent({
    targetUrl: 'https://example.com/post',
    options: {
      siteData: { b: 2, a: { d: 4, c: 3 } },
      download: { quality: 'best', width: 2048 }
    }
  });
  const second = createCaptureIntent({
    targetUrl: 'https://example.com/post',
    options: {
      siteData: { a: { c: 3, d: 4 }, b: 2 },
      download: { width: 2048, quality: 'best' }
    }
  });

  assert.equal(first.fingerprint, second.fingerprint);
});

test('explicit capture-again survives normalization and preserves retry identity', () => {
  const base = { targetUrl: 'https://example.com/post', options: { saveMode: 'quick', captureAgain: true } };
  const first = createCaptureIntent({ ...base, captureId: 'deliberate-first' });
  const second = createCaptureIntent({ ...base, captureId: 'deliberate-second' });
  const replay = createCaptureIntent(first);
  assert.equal(first.options.captureAgain, true);
  assert.notEqual(first.fingerprint, second.fingerprint);
  assert.equal(first.fingerprint, replay.fingerprint);
  assert.equal(first.captureId, replay.captureId);
});
