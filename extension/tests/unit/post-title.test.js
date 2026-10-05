import assert from 'node:assert/strict';
import test from 'node:test';
import { postTitle } from '../../src/content/modules/post-title.js';

test('a feed post is titled like its permalink page, not the feed tab', () => {
  assert.equal(postTitle('sampledev\n@sampledev\n·\n2h', 'Pocket-sized gadgets are\nfinally having a moment.', 'X'),
    'sampledev on X: "Pocket-sized gadgets are finally having a moment."');
  assert.equal(postTitle('alice.bsky.social', '', 'Bluesky'), 'alice.bsky.social on Bluesky');
  assert.equal(postTitle('', 'just text', 'X'), '"just text"');
  assert.equal(postTitle('', '  ', 'X'), '', 'nothing to name it by: the page-title fallback applies');
  const long = postTitle('a', 'x'.repeat(200), 'X');
  assert.ok(long.endsWith('…"') && long.length < 100);
});
