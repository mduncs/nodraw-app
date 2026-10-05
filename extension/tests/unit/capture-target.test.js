import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import { collectionCaptureBlockReason } from '../../src/runtime/capture-target.js';

const blockedCollections = [
  'https://x.com/home',
  'https://x.com./home',
  'https://x.com/search?q=media',
  'https://x.com/example',
  'https://twitter.com/home',
  'https://mobile.twitter.com/home',
  'https://m.youtube.com/feed/subscriptions',
  'https://www.youtube.com/',
  'https://www.youtube.com/feed/subscriptions',
  'https://bsky.app/',
  'https://bsky.app/profile/example.test',
  'https://www.reddit.com/',
  'https://old.reddit.com/r/example/'
];

const directItems = [
  'https://x.com/example/status/1234567890',
  'https://twitter.com/i/status/1234567890',
  'https://www.youtube.com/watch?v=video-id',
  'https://www.youtube.com/watch?v=video-id&list=playlist-id',
  'https://www.youtube.com/shorts/video-id',
  'https://youtu.be/video-id',
  'https://bsky.app/profile/example.test/post/post-id',
  'https://www.reddit.com/r/example/comments/postid/title/',
  'https://www.reddit.com/gallery/postid',
  'https://example.com/an-ordinary-page'
];

test('known social feeds and collection pages cannot become bulk page captures', () => {
  for (const url of blockedCollections) {
    assert.equal(typeof collectionCaptureBlockReason(url), 'string', url);
  }
});

test('specific posts, videos, and ordinary web pages remain capturable', () => {
  for (const url of directItems) {
    assert.equal(collectionCaptureBlockReason(url), null, url);
  }
});

test('invalid page URLs are rejected', () => {
  assert.equal(typeof collectionCaptureBlockReason('not a URL'), 'string');
  assert.equal(typeof collectionCaptureBlockReason('about:blank'), 'string');
});


test('all new background submissions pass through the pre-persistence guard', async () => {
  const background = await readFile(
    new URL('../../src/background/background.js', import.meta.url),
    'utf8'
  );

  assert.equal((background.match(/captureRuntime\.submit\(/g) || []).length, 1);
  assert.match(background, /return captureRuntime\.submit\(intent, tab\)/);
  assert.match(background, /enrichSubmittedIntent\(request\.intent, tab\)[\s\S]*?submitCaptureSafely\(intent, tab\)/);
  assert.match(background, /await submitCaptureSafely\(intent, tab\)/);
});
