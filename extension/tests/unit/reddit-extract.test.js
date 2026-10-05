import assert from 'node:assert/strict';
import test from 'node:test';
import { extractNewRedditPost, extractOldRedditPost, getRedditPieces } from '../../src/content/content-reddit.js';
import { modeFromEvent } from '../../src/content/modules/capture-button.js';

// Flat descendants match just the selector tokens used by the extractor.
function node({ attrs = {}, tags = [], text = '', tagName = 'DIV', children = [], classes = [] } = {}) {
  const matches = (el, selector) => selector.split(',').some(token => el.tags.includes(token.trim()));
  return {
    tagName, tags, textContent: text,
    getAttribute: name => attrs[name] ?? null,
    hasAttribute: name => name in attrs,
    classList: { contains: name => classes.includes(name) },
    querySelector: selector => children.find(el => matches(el, selector)) || null,
    querySelectorAll: selector => children.filter(el => matches(el, selector))
  };
}

function image(url, extra = {}) {
  return node({ attrs: { src: url, alt: 'Photo description', ...extra }, tags: ['img'] });
}

function fixture(layout, kind) {
  const urls = ['https://i.redd.it/one.jpg', 'https://i.redd.it/two.png'];
  const contentUrl = kind === 'video' ? 'https://v.redd.it/clip'
    : kind === 'gallery' ? 'https://www.reddit.com/gallery/abc123'
    : kind === 'image' ? urls[0] : '/r/example/comments/abc123/title/';
  const children = [];
  if (kind === 'image' || kind === 'gallery') children.push(image(urls[0]));
  if (kind === 'gallery') children.push(image(urls[1]), node({ tags: ['gallery-carousel', '.gallery'] }));
  if (kind === 'video') children.push(node({ tags: ['video', '.expando video'] }));
  if (kind === 'text') children.push(node({ tags: ['[slot="text-body"]', '.md'], text: '  A text-only post body.  ' }));
  if (layout === 'new') {
    return node({ tagName: 'SHREDDIT-POST', attrs: {
      permalink: '/r/example/comments/abc123/title/', 'content-href': contentUrl,
      'post-type': kind, 'post-id': 'abc123', 'post-title': 'A post title',
      author: 'alice', 'subreddit-prefixed-name': 'r/example', score: '42'
    }, children });
  }
  children.push(
    node({ tags: ['a.comments'], attrs: { href: '/r/example/comments/abc123/title/' } }),
    node({ tags: ['a.title'], attrs: { href: contentUrl }, text: 'A post title' }),
    node({ tags: ['.author'], text: 'alice' }),
    node({ tags: ['.subreddit'], text: 'r/example' }),
    node({ tags: ['.score.unvoted'], text: '42' })
  );
  return node({ attrs: { 'data-fullname': 't3_abc123', 'data-url': contentUrl }, children });
}

for (const layout of ['new', 'old']) {
  for (const kind of ['image', 'gallery', 'video', 'text']) {
    test(`${layout} Reddit ${kind} fixture preserves post identity and media`, () => {
      const post = fixture(layout, kind);
      const data = (layout === 'new' ? extractNewRedditPost : extractOldRedditPost)(post);
      assert.equal(data.permalink, 'https://www.reddit.com/r/example/comments/abc123/title/');
      assert.equal(data.postId, 'abc123');
      assert.equal(data.author, 'alice');
      assert.equal(data.title, 'A post title');
      assert.equal(data.hasMedia, kind !== 'text');
      assert.equal(data.hasVideo, kind === 'video');
      assert.equal(data.hasGallery, kind === 'gallery');
      assert.deepEqual(data.imageUrls, kind === 'image' ? ['https://i.redd.it/one.jpg']
        : kind === 'gallery' ? ['https://i.redd.it/one.jpg', 'https://i.redd.it/two.png'] : []);
      assert.equal(data.text, kind === 'text' ? 'A text-only post body.' : '');
      assert.equal(data.mediaCount, kind === 'gallery' ? 2 : kind === 'text' ? 0 : 1);
    });
  }
}

test('new Reddit article fallback extracts image and metadata', () => {
  const post = node({ tagName: 'ARTICLE', children: [
    node({ tags: ['a[href*="/comments/"]'], attrs: { href: '/r/example/comments/fallback/title/' } }),
    node({ tags: ['h3'], text: 'Article title' }),
    node({ tags: ['a[href^="/user/"]'], text: 'u/bob' }),
    image('https://i.redd.it/article.jpg')
  ] });
  const result = extractNewRedditPost(post);
  assert.equal(result.postId, 'fallback');
  assert.equal(result.title, 'Article title');
  assert.equal(result.author, 'bob');
  assert.deepEqual(result.imageUrls, ['https://i.redd.it/article.jpg']);
});

test('Reddit srcset uses the original full-size image and deduplicates its link', () => {
  const post = node({ tagName: 'SHREDDIT-POST', attrs: {
    'post-id': 'fullsize', 'content-href': 'https://i.redd.it/original.jpg'
  }, children: [image('https://preview.redd.it/original.jpg?width=320', {
    srcset: 'https://preview.redd.it/original.jpg?width=320 320w, https://preview.redd.it/original.jpg?width=1600 1600w'
  })] });
  const result = extractNewRedditPost(post);
  assert.deepEqual(result.imageUrls, ['https://i.redd.it/original.jpg']);
  assert.deepEqual(result.imageAlts, ['Photo description']);
});

test('Reddit gestures show exactly media, context or both in the capture plan', () => {
  const post = fixture('new', 'gallery');
  const data = extractNewRedditPost(post);
  assert.equal(modeFromEvent({}), 'full');
  assert.equal(modeFromEvent({ shiftKey: true }), 'quick');
  assert.equal(modeFromEvent({ altKey: true }), 'text');
  assert.deepEqual(getRedditPieces(post, data, 'full').map(piece => piece.kind), ['gallery', 'text']);
  assert.deepEqual(getRedditPieces(post, data, 'quick').map(piece => piece.kind), ['gallery']);
  const textPieces = getRedditPieces(post, data, 'text');
  assert.equal(textPieces.length, 1);
  assert.equal(textPieces[0].kind, 'text');
  assert.equal(textPieces[0].label, undefined, 'numbered like every other piece');
  assert.equal(textPieces[0].element, post);
});

test('Reddit image plan skips the avatar, the blurred backdrop and the hidden lightbox copy', () => {
  const slot = name => ({ getAttribute: () => name });
  const media = slot('post-media-container');
  const img = (src, { slotEl = media, classes = [], author = false } = {}) => ({
    tags: ['img'], getAttribute: name => name === 'src' ? src : null,
    classList: { contains: name => classes.includes(name) },
    closest: selector => selector.includes('authorName') ? (author ? slot('authorName') : null) : slotEl
  });
  const avatar = img('https://cf.redditstatic.com/avatars/defaults/v2/avatar_default_0.png', { slotEl: slot('authorName'), author: true });
  const backdrop = img('https://preview.redd.it/trail-v0-abc.jpeg?width=640', { classes: ['post-background-image-filter'] });
  const visible = img('https://preview.redd.it/trail-v0-abc.jpeg?width=640');
  const lightbox = img('https://i.redd.it/abc.jpeg');
  const post = node({ tagName: 'SHREDDIT-POST', attrs: { 'post-type': 'image', 'post-id': 'abc' } });
  post.querySelectorAll = selector => selector === 'img' ? [avatar, backdrop, visible, lightbox] : [];
  const pieces = getRedditPieces(post, { hasImage: true }, 'full');
  assert.deepEqual(pieces.map(piece => piece.kind), ['image', 'text']);
  assert.equal(pieces[0].element, visible);
});

test('Reddit video plan excludes the video poster from separate image downloads', () => {
  const post = fixture('new', 'video');
  assert.deepEqual(getRedditPieces(post, extractNewRedditPost(post), 'full').map(piece => piece.kind), ['video', 'text']);
});
