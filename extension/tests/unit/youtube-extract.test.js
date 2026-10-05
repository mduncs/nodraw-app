import assert from 'node:assert/strict';
import test from 'node:test';
import {
  extractVideoId, getWatchUrl, extractPlayerMetadata, extractThumbnailMetadata, getYouTubePieces
} from '../../src/content/content-youtube.js';
import { modeFromEvent } from '../../src/content/modules/capture-button.js';

function node({ text = '', attrs = {}, tags = [] } = {}) {
  return { textContent: text, tags, getAttribute: name => attrs[name] ?? null };
}
function root(children = [], title = '') {
  return {
    title,
    querySelector: selector => children.find(child => selector.split(',').some(token => child.tags.includes(token.trim()))) || null
  };
}

test('watch-page URLs normalize the video independently of query order and playlists', () => {
  for (const url of [
    'https://www.youtube.com/watch?v=abc123&list=playlist',
    'https://www.youtube.com/watch?list=playlist&v=abc123&t=25',
    '/watch?v=abc123', 'https://youtu.be/abc123?t=25', 'https://www.youtube.com/embed/abc123'
  ]) {
    assert.equal(extractVideoId(url), 'abc123');
    assert.equal(getWatchUrl(extractVideoId(url)), 'https://www.youtube.com/watch?v=abc123');
  }
});

test('shorts URLs use the same canonical one-video target', () => {
  assert.equal(extractVideoId('https://www.youtube.com/shorts/short123?feature=share'), 'short123');
  assert.equal(extractVideoId('/shorts/short123'), 'short123');
  assert.equal(getWatchUrl('short123'), 'https://www.youtube.com/watch?v=short123');
});

test('non-video and lookalike hosts do not produce a capture target', () => {
  for (const url of [null, '', 'https://www.youtube.com/', 'https://notyoutube.com/watch?v=bad', 'https://example.com/youtube.com/watch?v=bad']) {
    assert.equal(extractVideoId(url), null);
  }
});

test('watch-page DOM fixture extracts title, channel, views and duration', () => {
  const page = root([
    node({ tags: ['h1.ytd-watch-metadata yt-formatted-string'], text: '  Watch title  ' }),
    node({ tags: ['#channel-name a'], text: ' Channel ' }),
    node({ tags: ['#count .view-count'], text: ' 1,234 views ' }),
    node({ tags: ['.ytp-time-duration'], text: '4:32' })
  ]);
  assert.deepEqual(extractPlayerMetadata(page), { title: 'Watch title', channel: 'Channel', viewCount: '1,234 views', duration: '4:32' });
});

test('watch-page metadata falls back to the document title while controls load', () => {
  assert.deepEqual(extractPlayerMetadata(root([], 'Fallback title - YouTube')),
    { title: 'Fallback title', channel: '', viewCount: '', duration: '' });
});

test('shorts-page DOM fixture scopes metadata to the active reel', () => {
  const reel = root([
    node({ tags: ['.ytShortsVideoTitleViewModelShortsVideoTitle'], text: '  Active short title  ' }),
    node({ tags: ['.ytReelChannelBarViewModelChannelName a'], text: ' @shorts-author ' })
  ]);
  reel.tags = ['ytd-reel-video-renderer[is-active]'];
  const page = root([
    node({ tags: ['#title h1'], text: 'Inactive video title' }), reel
  ], 'Stale page title - YouTube');
  assert.deepEqual(extractPlayerMetadata(page), { title: 'Active short title', channel: '@shorts-author', viewCount: '', duration: '' });
});

test('short thumbnail DOM fixture extracts its available metadata', () => {
  const thumbnail = root([
    node({ tags: ['[id="video-title"]'], attrs: { title: 'Short title' } }),
    node({ tags: ['ytd-channel-name a'], text: ' Shorts channel ' }),
    node({ tags: ['#metadata-line span'], text: ' 321 views ' }),
    node({ tags: ['ytd-thumbnail-overlay-time-status-renderer span'], text: ' 0:32 ' })
  ]);
  assert.deepEqual(extractThumbnailMetadata(thumbnail), { title: 'Short title', channel: 'Shorts channel', viewCount: '321 views', duration: '0:32' });
});

test('YouTube modifiers select best video, audio, or video with transcripts and context', () => {
  assert.equal(modeFromEvent({}), 'full');
  assert.equal(modeFromEvent({ shiftKey: true }), 'quick');
  assert.equal(modeFromEvent({ altKey: true }), 'text');
  const video = node({ tags: ['video'] });
  const player = root([video]);
  const videoPlan = getYouTubePieces(player, 'full');
  assert.equal(videoPlan.length, 1);
  assert.equal(videoPlan[0].element, video);
  assert.equal(videoPlan[0].kind, 'video');
  assert.equal(getYouTubePieces(player, 'quick')[0].kind, 'audio');
  const watchPlayer = { ...root([video]), matches: selector => selector.includes('#movie_player') };
  assert.equal(getYouTubePieces(watchPlayer, 'full')[0].element, watchPlayer, 'the watch player, not its moving <video>');
  const textPlan = getYouTubePieces(player, 'text');
  assert.deepEqual(textPlan.map(piece => piece.kind), ['video', 'transcripts']);
  assert.ok(textPlan.every(piece => piece.scope === 'THIS VIDEO' && !piece.label));
});
