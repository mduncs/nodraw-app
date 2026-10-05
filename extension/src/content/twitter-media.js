// Pure DOM helpers shared by extraction and the capture plan.
const POST_MARKERS = 'time, [data-testid="User-Name"]';
const PLAYERS = 'video, [data-testid="videoPlayer"], [data-testid="gifPlayer"]';
const IMAGE_BACKGROUNDS = '[style*="background-image"], [data-testid="tweetPhoto"], [data-testid="card.wrapper"], [data-testid="tweetMultiPhoto"]';

function select(root, selector) {
  return Array.from(root?.querySelectorAll?.(selector) || []);
}

function nearestContainer(node, containers, boundary) {
  for (let el = node; el && el !== boundary; el = el.parentElement) {
    if (containers.has(el)) return el;
  }
  return boundary;
}

export function findQuotedPostContainers(article) {
  const candidates = new Set(select(article, 'div[role="link"]'));
  // A wrapper containing only another quote's header is not another post.
  return [...candidates].filter(container => select(container, POST_MARKERS)
    .some(marker => nearestContainer(marker, candidates, article) === container));
}

export function getQuoteLevel(node, article, containers = findQuotedPostContainers(article)) {
  const quotes = new Set(containers);
  let level = 0;
  for (let el = node; el && el !== article; el = el.parentElement) {
    if (quotes.has(el)) level += 1;
  }
  return level;
}

export function isInsideQuotedTweet(node, article) {
  return getQuoteLevel(node, article) > 0;
}

function ownNodes(root, selector, article, containers) {
  const level = getQuoteLevel(root, article, containers);
  return select(root, selector).filter(node => getQuoteLevel(node, article, containers) === level);
}

export function getPostURL(root, article = root, containers = findQuotedPostContainers(article)) {
  const timeLink = ownNodes(root, 'time', article, containers)[0]?.closest?.('a[href*="/status/"]');
  const links = ownNodes(root, 'a[href*="/status/"]', article, containers);
  const href = timeLink?.href || links.find(link => /\/status\/\d+(?:$|[?#])/.test(link.href))?.href || links[0]?.href || '';
  return href.match(/^https?:\/\/[^/]+\/[^/]+\/status\/\d+/)?.[0] || '';
}

export function getGifURL(poster) {
  const id = poster?.match(/^(?:https?:)?\/\/pbs\.twimg\.com\/tweet_video_thumb\/([\w-]+)(?:\.[\w]+)?(?:[?:]|$)/)?.[1];
  return id ? `https://video.twimg.com/tweet_video/${id}.mp4` : '';
}

function playerKind(element) {
  const video = element.tagName === 'VIDEO' || element.matches?.('video') ? element : element.querySelector?.('video');
  const poster = video?.poster || video?.getAttribute?.('poster') || '';
  const gifUrl = getGifURL(poster);
  const gif = gifUrl || element.getAttribute?.('data-testid') === 'gifPlayer'
    || video?.closest?.('[data-testid="gifPlayer"]');
  return { kind: gif ? 'gif' : 'video', video, gifUrl };
}

function imageURL(element) {
  const srcset = element.srcset || element.getAttribute?.('srcset') || '';
  const sources = srcset.split(',').map(source => {
    const [url, descriptor = '1x'] = source.trim().split(/\s+/);
    return { url, size: parseFloat(descriptor) || 0 };
  }).sort((a, b) => b.size - a.size);
  const background = element.style?.backgroundImage || element.getAttribute?.('style') || '';
  const raw = sources[0]?.url || element.dataset?.src || element.dataset?.imageSrc || element.dataset?.lazySrc
    || element.currentSrc || element.src || background.match(/url\((['"]?)(.*?)\1\)/)?.[2] || '';
  try {
    const url = new URL(raw.replace(/&amp;/g, '&'), 'https://x.com');
    if (url.hostname !== 'pbs.twimg.com' || !/^\/(media|card_img)\//.test(url.pathname)) return '';
    url.searchParams.set('name', 'orig');
    return url.href;
  } catch {
    return '';
  }
}

export function collectTweetMedia(article) {
  const containers = findQuotedPostContainers(article);
  const media = [];
  const seen = new Set();
  for (const element of select(article, `img, ${IMAGE_BACKGROUNDS}`)) {
    const url = imageURL(element);
    const level = getQuoteLevel(element, article, containers);
    const key = `${level}:${url}`;
    if (!url || seen.has(key)) continue;
    seen.add(key);
    media.push({ element, kind: 'image', level, url, alt: element.alt || element.getAttribute?.('aria-label') || '' });
  }
  const players = select(article, PLAYERS);
  for (const element of players) {
    // Frame each player once, even when X wraps it in two player blocks.
    if (players.some(parent => parent !== element && nearestContainer(element.parentElement, new Set([parent]), article) === parent)) continue;
    const level = getQuoteLevel(element, article, containers);
    const { kind, video, gifUrl } = playerKind(element);
    const source = video?.currentSrc || video?.src || video?.getAttribute?.('src') || video?.querySelector?.('source')?.src || '';
    const container = nearestContainer(element, new Set(containers), article);
    const url = gifUrl || (/^https?:\/\//.test(source) ? source : getPostURL(container, article, containers));
    media.push({ element, kind, level, url, alt: '' });
  }
  return media;
}

export function extractQuotedPosts(article) {
  const containers = findQuotedPostContainers(article);
  const media = collectTweetMedia(article);
  return containers.map(container => {
    const level = getQuoteLevel(container, article, containers);
    const url = getPostURL(container, article, containers);
    const name = ownNodes(container, '[data-testid="User-Name"]', article, containers)[0]?.innerText || '';
    const urlHandle = url.match(/\/([^/]+)\/status\//)?.[1];
    return {
      level, url,
      author: name.split(/\n|@/)[0].trim(),
      handle: name.match(/@[\w]+/)?.[0] || (urlHandle ? `@${urlHandle}` : ''),
      text: ownNodes(container, '[data-testid="tweetText"]', article, containers).map(node => node.innerText || '').join('\n'),
      postedAt: ownNodes(container, 'time', article, containers)[0]?.getAttribute?.('datetime') || '',
      media: media.filter(piece => nearestContainer(piece.element, new Set(containers), article) === container)
        .map(({ kind, url }) => ({ kind, url }))
    };
  }).sort((a, b) => a.level - b.level);
}

export function detectTweetMedia(article, { hasScopedVideoLink = false } = {}) {
  const ownMedia = collectTweetMedia(article).filter(piece => piece.level === 0);
  const hasGif = ownMedia.some(piece => piece.kind === 'gif');
  return {
    hasVideo: ownMedia.some(piece => piece.kind === 'video') || (Boolean(hasScopedVideoLink) && !hasGif),
    hasGif
  };
}

export function extractTweetContent(article) {
  const containers = findQuotedPostContainers(article);
  const own = selector => ownNodes(article, selector, article, containers);
  const media = collectTweetMedia(article).filter(piece => piece.level === 0);
  const images = media.filter(piece => piece.kind === 'image');
  const tweetUrl = getPostURL(article, article, containers);
  const tweetId = tweetUrl.match(/status\/(\d+)/)?.[1] || '';
  const hasScopedVideoLink = own('a[href*="/status/"]').some(link =>
    link.href?.includes(`/status/${tweetId}/video/`));
  const { hasVideo, hasGif } = detectTweetMedia(article, { hasScopedVideoLink });
  return {
    text: own('[data-testid="tweetText"]').map(node => node.innerText || '').join('\n'),
    userName: own('[data-testid="User-Name"]')[0]?.innerText || '',
    timestamp: own('time')[0]?.getAttribute('datetime') || '',
    tweetId, tweetUrl,
    hasMedia: images.length > 0 || hasVideo || hasGif,
    hasImage: images.length > 0,
    hasVideo, hasGif,
    imageUrls: images.map(piece => piece.url),
    imageAlts: images.map(piece => piece.alt).filter(Boolean),
    gifUrl: media.find(piece => piece.kind === 'gif')?.url || '',
    media: media.map(({ kind, url }) => ({ kind, url })),
    quotes: extractQuotedPosts(article),
    // Every photo, video and GIF counts; a video known only from its status link counts once.
    mediaCount: media.length + Number(hasVideo && !media.some(piece => piece.kind === 'video'))
  };
}

export function getSaveModeFromEvent(event) {
  if (event.altKey && event.shiftKey) return 'quoted';
  if (event.shiftKey) return 'quick';
  if (event.altKey) return 'text';
  return 'full';
}

export function mergeTweetData(baseData, liveData) {
  // Refresh owns the media boundaries: a newly hydrated quote header can move
  // a previously unclassified photo/video out of level 0.
  return {
    ...baseData,
    ...liveData,
    userName: liveData.userName || baseData.userName,
    timestamp: liveData.timestamp || baseData.timestamp,
    tweetId: liveData.tweetId || baseData.tweetId,
    tweetUrl: liveData.tweetUrl || baseData.tweetUrl
  };
}

export function getCapturePieces(article, mode) {
  const containers = findQuotedPostContainers(article);
  const media = collectTweetMedia(article);
  const pieces = media.filter(piece => mode !== 'text' && (piece.level === 0 || mode === 'quoted'))
    .map(({ element, kind, level }) => ({ element, kind, level, included: true }));
  // Every mode except Quick keeps the post screenshot (1.2.6 behaviour, kept for ⌥⇧).
  if (mode === 'full' || mode === 'quoted') pieces.push({ element: article, kind: 'post', level: 0, included: true });
  if (mode === 'text') {
    const text = ownNodes(article, '[data-testid="tweetText"]', article, containers)[0] || article;
    pieces.push({ element: article, kind: 'post', level: 0, included: true });
    if (text !== article) pieces.push({ element: text, kind: 'text', level: 0, included: true });
  }
  for (const element of containers) {
    const level = getQuoteLevel(element, article, containers);
    if (mode !== 'quoted' || !media.some(piece => nearestContainer(piece.element, new Set(containers), article) === element)) {
      pieces.push({ element, kind: 'post', level, included: false });
    }
  }
  return pieces;
}
