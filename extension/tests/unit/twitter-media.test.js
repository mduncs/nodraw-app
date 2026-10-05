import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';

import { collectTweetMedia, detectTweetMedia, extractQuotedPosts, extractTweetContent, findQuotedPostContainers,
  getCapturePieces, getGifURL, getQuoteLevel, getSaveModeFromEvent, isInsideQuotedTweet, mergeTweetData } from '../../src/content/twitter-media.js';
import { createCaptureIntent } from '../../src/runtime/capture-intent.js';

// Minimal fake-DOM node: supports getAttribute, parentElement, matches(sel).
function node({ attrs = {}, matchTags = [], children = [], text = '', tag = 'div' } = {}) {
  const el = {
    attrs,
    tagName: tag.toUpperCase(),
    innerText: text,
    src: attrs.src || '',
    href: attrs.href || '',
    alt: attrs.alt || '',
    parentElement: null,
    getAttribute: name => (name in attrs ? attrs[name] : null),
    _matchTags: matchTags,
    matches: selector => selector.split(',').some(token => {
      token = token.trim();
      if (matchTags.includes(token)) return true;
      if (token === 'div[role="link"]') return tag === 'div' && attrs.role === 'link';
      if (token === 'a[href*="/status/"]') return tag === 'a' && attrs.href?.includes('/status/');
      const attribute = token.match(/^\[([^=]+)="([^"]+)"\]$/);
      return attribute ? attrs[attribute[1]] === attribute[2] : token === tag;
    }),
  };
  for (const child of children) child.parentElement = el;
  el._children = children;
  el.querySelectorAll = selector => {
    const result = [];
    const walk = current => {
      for (const child of current._children || []) {
        if (child.matches(selector)) result.push(child);
        walk(child);
      }
    };
    walk(el);
    return result;
  };
  el.querySelector = selector => el.querySelectorAll(selector)[0] || null;
  el.closest = selector => {
    for (let parent = el; parent; parent = parent.parentElement) {
      if (parent.matches?.(selector)) return parent;
    }
    return null;
  };
  return el;
}

// Fake article: querySelector/querySelectorAll match against a flat descendant
// list by simple selector tokens we care about.
function article(descendants) {
  return node({ tag: 'article', children: descendants });
}

function quote(children) {
  return node({ attrs: { role: 'link' }, children: [node({ tag: 'time' }), ...children] });
}

test('standalone video with no /video/ permalink is detected (regression 37c80d0)', () => {
  const video = node({ matchTags: ['video', '[data-testid="videoPlayer"]'] });
  const art = article([video]);
  const result = detectTweetMedia(art, { tweetId: '123', hasScopedVideoLink: false });
  assert.equal(result.hasVideo, true);
  assert.equal(result.hasGif, false);
});

test('scoped /video/ permalink alone still yields hasVideo', () => {
  const art = article([]);
  const result = detectTweetMedia(art, { tweetId: '123', hasScopedVideoLink: true });
  assert.equal(result.hasVideo, true);
});

test('quoted-tweet video is NOT attributed to the current tweet', () => {
  const quotedVideo = node({ matchTags: ['video', '[data-testid="videoPlayer"]'] });
  const quotedCard = quote([quotedVideo]);
  const art = article([quotedCard]);
  const result = detectTweetMedia(art, { tweetId: '123', hasScopedVideoLink: false });
  assert.equal(result.hasVideo, false, 'video inside a role="link" quoted card must be ignored');
});

test('own gif player is detected', () => {
  const gif = node({ attrs: { 'data-testid': 'gifPlayer' } });
  const art = article([gif]);
  const result = detectTweetMedia(art, { tweetId: '123', hasScopedVideoLink: false });
  assert.equal(result.hasGif, true);
});

test('X looping blob video is detected as GIF from its tweet_video_thumb poster', () => {
  const gif = node({
    attrs: { src: 'blob:https://x.com/abc', poster: 'https://pbs.twimg.com/tweet_video_thumb/ABC123.jpg' },
    matchTags: ['video']
  });
  const result = detectTweetMedia(article([gif]), { tweetId: '123' });
  assert.equal(result.hasGif, true);
  assert.equal(result.hasVideo, false);
});

test('quoted gif is ignored, own video still wins in a mixed tweet', () => {
  const ownVideo = node({ matchTags: ['video', '[data-testid="videoPlayer"]'] });
  const quotedGif = node({ attrs: { 'data-testid': 'gifPlayer' } });
  const quotedCard = quote([quotedGif]);
  const art = article([ownVideo, quotedCard]);
  const result = detectTweetMedia(art, { tweetId: '123', hasScopedVideoLink: false });
  assert.equal(result.hasVideo, true);
  assert.equal(result.hasGif, false);
});

test('no tweetId falls back to plain element presence', () => {
  const video = node({ matchTags: ['video', '[data-testid="videoPlayer"]'] });
  const art = article([video]);
  const result = detectTweetMedia(art, { tweetId: '', hasScopedVideoLink: false });
  assert.equal(result.hasVideo, true);
});

test('isInsideQuotedTweet walks ancestors up to the article', () => {
  const inner = node({});
  const link = quote([inner]);
  const art = article([link]);
  assert.equal(isInsideQuotedTweet(inner, art), true);

  const loose = node({});
  const art2 = article([loose]);
  assert.equal(isInsideQuotedTweet(loose, art2), false);
});

function fixturePost(post, quoted = false) {
  const children = [
    node({ attrs: { 'data-testid': 'User-Name' }, text: `${post.handle.toUpperCase()}\n@${post.handle}` }),
    node({ tag: 'a', attrs: { href: `https://x.com/${post.handle}/status/${post.id}` }, children: [
      node({ tag: 'time', attrs: { datetime: '2026-07-03T12:00:00Z' } })
    ] }),
    node({ attrs: { 'data-testid': 'tweetText' }, text: post.text }),
    ...post.media.map(name => node({ tag: 'img', attrs: { src: `https://pbs.twimg.com/media/${name}?name=small`, alt: name } }))
  ];
  for (const gif of [].concat(post.gif || [])) children.push(node({ attrs: { 'data-testid': 'videoPlayer' }, children: [
    node({ tag: 'video', attrs: { src: 'blob:https://x.com/gif', poster: `https://pbs.twimg.com/tweet_video_thumb/${gif}.jpg` } })
  ] }));
  if (post.quote) children.push(fixturePost(post.quote, true));
  return node({ tag: quoted ? 'div' : 'article', attrs: quoted ? { role: 'link' } : {}, children });
}

const fixtures = JSON.parse(await readFile(new URL('../fixtures/twitter-quotes.json', import.meta.url), 'utf8'));
for (const fixture of fixtures) {
  test(`${fixture.name}: extraction scopes each post and records every quote`, () => {
    const art = fixturePost(fixture.post);
    assert.deepEqual(collectTweetMedia(art).map(piece => piece.level), fixture.mediaLevels);
    const data = extractTweetContent(art);
    assert.equal(data.text, fixture.post.text);
    assert.equal(data.tweetId, fixture.post.id);
    assert.equal(data.hasImage, fixture.post.media.length > 0);
    assert.equal(data.imageUrls.length, fixture.post.media.length);
    assert.equal(data.hasGif, false, 'nested GIF must not be attributed to the outer post');
    let post = fixture.post.quote;
    for (const [index, recorded] of data.quotes.entries()) {
      assert.equal(recorded.level, index + 1);
      assert.equal(recorded.text, post.text);
      assert.equal(recorded.author, post.handle.toUpperCase());
      assert.equal(recorded.handle, `@${post.handle}`);
      assert.equal(recorded.url, `https://x.com/${post.handle}/status/${post.id}`);
      assert.equal(recorded.media.length, post.media.length + Number(Boolean(post.gif)));
      if (post.gif) assert.deepEqual(recorded.media[0], { kind: 'gif', url: `https://video.twimg.com/tweet_video/${post.gif}.mp4` });
      post = post.quote;
    }
    assert.equal(post, undefined, 'quote chain is complete');
  });

  for (const mode of ['full', 'quick', 'text', 'quoted']) {
    test(`${fixture.name}: ${mode} capture plan follows gesture table`, () => {
      const art = fixturePost(fixture.post);
      const pieces = getCapturePieces(art, mode);
      const includedMedia = pieces.filter(piece => piece.included && ['image', 'video', 'gif'].includes(piece.kind));
      const expectedLevels = fixture.mediaLevels.filter(level => mode !== 'text' && (level === 0 || mode === 'quoted'));
      assert.deepEqual(includedMedia.map(piece => piece.level), expectedLevels);
      assert.equal(pieces.some(piece => piece.element === art && piece.included), mode !== 'quick');
      for (const container of findQuotedPostContainers(art)) {
        const quoteHasMedia = collectTweetMedia(art).some(piece => piece.level === getQuoteLevel(container, art));
        const recorded = pieces.filter(piece => piece.element === container && !piece.included);
        assert.equal(recorded.length, mode === 'quoted' && quoteHasMedia ? 0 : 1);
        if (recorded.length) assert.equal(recorded[0].kind, 'post');
      }
      assert.equal(pieces.filter(piece => piece.kind === 'text').length, Number(mode === 'text'));
    });
  }
}

test('ordinary role=link media cards are own media; headerless quote wrappers add no depth', () => {
  const ownVideo = node({ tag: 'video' });
  const ownLink = node({ attrs: { role: 'link' }, children: [ownVideo] });
  const quotedVideo = node({ tag: 'video' });
  const realQuote = quote([quotedVideo]);
  const wrapper = node({ attrs: { role: 'link' }, children: [realQuote] });
  const art = article([ownLink, wrapper]);
  assert.deepEqual(findQuotedPostContainers(art), [realQuote]);
  assert.equal(getQuoteLevel(ownVideo, art), 0);
  assert.equal(getQuoteLevel(quotedVideo, art), 1);
  assert.equal(detectTweetMedia(art).hasVideo, true);
});

test('User-Name identifies quotes without time; own text stays empty when only quote has text', () => {
  const quoted = node({ attrs: { role: 'link' }, children: [
    node({ attrs: { 'data-testid': 'User-Name' }, text: 'A\n@a' }),
    node({ attrs: { 'data-testid': 'tweetText' }, text: 'Quoted text' }),
    node({ tag: 'a', attrs: { href: 'https://x.com/a/status/101' } })
  ] });
  const art = article([quoted]);
  assert.equal(extractTweetContent(art).text, '');
  assert.equal(extractQuotedPosts(art)[0].text, 'Quoted text');
});

test('image fallback selects full-size srcset and background photos by level', () => {
  const own = node({ tag: 'img', attrs: { src: 'https://pbs.twimg.com/media/fallback.jpg' } });
  own.srcset = 'https://pbs.twimg.com/media/small.jpg 100w, https://pbs.twimg.com/media/large.jpg 1000w';
  const background = node({ attrs: { 'data-testid': 'tweetPhoto' } });
  background.style = { backgroundImage: 'url("https://pbs.twimg.com/media/quoted.jpg?name=small")' };
  const art = article([own, quote([background])]);
  assert.deepEqual(extractTweetContent(art).imageUrls, ['https://pbs.twimg.com/media/large.jpg?name=orig']);
  assert.equal(collectTweetMedia(art)[1].level, 1);
});

test('every photo and GIF of a post counts, not one per kind', () => {
  const art = fixturePost({ id: '600', handle: 'kar__lee', text: 'Four loops', media: [], gif: ['Gif_1', 'Gif_2', 'Gif_3', 'Gif_4'] });
  assert.equal(extractTweetContent(art).mediaCount, 4);
  const mixed = fixturePost({ id: '601', handle: 'outer', text: 'Two photos', media: ['a.jpg', 'b.jpg'] });
  assert.equal(extractTweetContent(mixed).mediaCount, 2);
});

test('GIF extraction produces a downloadable MP4 and survives the v1 page capture contract', () => {
  const art = fixturePost({ id: '500', handle: 'outer', text: 'A GIF', media: [], gif: 'Gif_123' });
  const data = extractTweetContent(art);
  assert.equal(data.hasGif, true);
  assert.equal(data.hasVideo, false);
  assert.equal(data.mediaCount, 1);
  assert.equal(data.gifUrl, 'https://video.twimg.com/tweet_video/Gif_123.mp4');
  assert.equal(getCapturePieces(art, 'quick')[0].kind, 'gif');
  const intent = createCaptureIntent({ kind: 'page', targetUrl: data.tweetUrl, options: {
    platform: 'twitter', siteData: { mediaType: 'gif', tweetContent: data, quotes: data.quotes }
  } });
  assert.equal(intent.schemaVersion, 1);
  assert.equal(intent.options.siteData.tweetContent.gifUrl, data.gifUrl);
  assert.equal(intent.options.siteData.mediaType, 'gif');
});

test('GIF derivation accepts poster formats and refuses unrelated hosts or posters', () => {
  for (const poster of ['https://pbs.twimg.com/tweet_video_thumb/ABC-123.jpg?name=small', '//pbs.twimg.com/tweet_video_thumb/ABC-123?format=jpg']) {
    assert.equal(getGifURL(poster), 'https://video.twimg.com/tweet_video/ABC-123.mp4');
  }
  assert.equal(getGifURL('https://evil.test/tweet_video_thumb/ABC.jpg'), '');
  assert.equal(getGifURL('https://pbs.twimg.com/ext_tw_video_thumb/ABC.jpg'), '');
});

test('all four gestures select the packet modes', () => {
  assert.equal(getSaveModeFromEvent({}), 'full');
  assert.equal(getSaveModeFromEvent({ shiftKey: true }), 'quick');
  assert.equal(getSaveModeFromEvent({ altKey: true }), 'text');
  assert.equal(getSaveModeFromEvent({ altKey: true, shiftKey: true }), 'quoted');
});

test('refresh discards media reclassified as quoted when its header hydrates', () => {
  const photo = node({ tag: 'img', attrs: { src: 'https://pbs.twimg.com/media/quoted.jpg' } });
  const card = node({ attrs: { role: 'link' }, children: [photo] });
  const art = article([card]);
  const initial = extractTweetContent(art);
  assert.equal(initial.hasImage, true);
  const header = node({ attrs: { 'data-testid': 'User-Name' }, text: 'A\n@a' });
  header.parentElement = card;
  card._children.unshift(header);
  const refreshed = mergeTweetData(initial, extractTweetContent(art));
  assert.equal(refreshed.hasImage, false);
  assert.equal(refreshed.hasMedia, false);
  assert.equal(refreshed.mediaCount, 0);
  assert.deepEqual(refreshed.imageUrls, []);
  assert.deepEqual(refreshed.media, []);
  assert.equal(refreshed.quotes[0].media.length, 1);
});
