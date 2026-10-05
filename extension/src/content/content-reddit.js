import { createCaptureButton } from './modules/capture-button.js';
import { renderNativeGlyph } from './modules/native-glyph.js';
import { withArchiverUIHidden } from './modules/capture-hide.js';

function absoluteUrl(url, base = globalThis.window?.location?.href || 'https://www.reddit.com/') {
  if (!url) return '';
  try {
    return new URL(url, base).href;
  } catch {
    return '';
  }
}

function normalizeRedditPermalink(url) {
  const absolute = absoluteUrl(url, 'https://www.reddit.com/');
  if (!absolute) return '';
  try {
    const parsed = new URL(absolute);
    if (parsed.pathname.includes('/comments/')) return absolute;
  } catch {
    return '';
  }
  return '';
}

function isMediaImageUrl(url) {
  const absolute = absoluteUrl(url);
  if (!absolute) return false;

  try {
    const parsed = new URL(absolute);
    const host = parsed.hostname.toLowerCase();
    const path = parsed.pathname.toLowerCase();
    if (host === 'i.redd.it' || host === 'preview.redd.it') return true;
    if (host === 'i.imgur.com') return true;
    return /\.(?:jpe?g|png|gif|webp|avif)(?:$|[?#])/.test(path);
  } catch {
    return false;
  }
}

function isMediaVideoUrl(url) {
  const absolute = absoluteUrl(url);
  if (!absolute) return false;

  try {
    const parsed = new URL(absolute);
    const host = parsed.hostname.toLowerCase();
    const path = parsed.pathname.toLowerCase();
    return host === 'v.redd.it' || /\.(?:mp4|webm|mov)(?:$|[?#])/.test(path);
  } catch {
    return false;
  }
}

function isRedditGalleryUrl(url) {
  const absolute = absoluteUrl(url);
  if (!absolute) return false;

  try {
    const parsed = new URL(absolute);
    return /\/gallery\/[a-z0-9]+/i.test(parsed.pathname);
  } catch {
    return false;
  }
}

function addUniqueUrl(urls, url) {
  let absolute = absoluteUrl(url);
  // Reddit's preview URL is a resized copy of the same i.redd.it original.
  if (absolute && new URL(absolute).hostname === 'preview.redd.it') {
    const original = new URL(absolute);
    original.hostname = 'i.redd.it';
    original.search = '';
    absolute = original.href;
  }
  if (absolute && !urls.includes(absolute)) {
    urls.push(absolute);
  }
}

function bestSrcsetUrl(srcset) {
  if (!srcset) return '';

  return srcset
    .split(',')
    .map(candidate => {
      const parts = candidate.trim().split(/\s+/);
      const descriptor = parts[1] || '';
      const score = Number.parseFloat(descriptor) || 0;
      return { url: parts[0], score };
    })
    .filter(candidate => candidate.url)
    .sort((a, b) => b.score - a.score)[0]?.url || '';
}

function collectImageData(root) {
  const imageUrls = [];
  const imageAlts = [];

  root.querySelectorAll('img').forEach(img => {
    const candidate =
      bestSrcsetUrl(img.getAttribute('srcset') || img.getAttribute('data-srcset')) ||
      img.currentSrc ||
      img.getAttribute('src') ||
      img.getAttribute('data-src') ||
      '';

    if (isMediaImageUrl(candidate)) {
      addUniqueUrl(imageUrls, candidate);
      const alt = img.getAttribute('alt');
      if (alt) imageAlts.push(alt);
    }
  });

  root.querySelectorAll('source[srcset], source[src]').forEach(source => {
    const candidate =
      bestSrcsetUrl(source.getAttribute('srcset')) ||
      source.getAttribute('src') ||
      '';
    if (isMediaImageUrl(candidate)) addUniqueUrl(imageUrls, candidate);
  });

  [
    root.getAttribute?.('content-href'),
    root.getAttribute?.('url'),
    root.getAttribute?.('data-url')
  ].forEach(url => {
    if (isMediaImageUrl(url)) addUniqueUrl(imageUrls, url);
  });

  root.querySelectorAll('a[href]').forEach(link => {
    const href = link.getAttribute('href');
    if (isMediaImageUrl(href)) addUniqueUrl(imageUrls, href);
  });

  return { imageUrls, imageAlts };
}

// New Reddit wraps each visible image in a blurred backdrop copy and a hidden lightbox
// copy, and the author's avatar is an img too. Keep one visible image per media slot.
function postMediaImages(postElement) {
  const slots = new Map();
  for (const img of postElement.querySelectorAll('img')) {
    if (!isMediaImageUrl(img.currentSrc || img.getAttribute('src') || img.getAttribute('data-src'))) continue;
    if (img.closest?.('[slot="authorName"], [slot="credit-bar"]')) continue;
    if (img.classList?.contains('post-background-image-filter')) continue;
    const slot = img.closest?.('[slot]') || img;
    if (!slots.has(slot)) slots.set(slot, img);
  }
  return [...slots.values()];
}

// The direct child of a post's action row that holds the vote pill; the native glyph follows it.
export function redditVoteAnchor(root) {
  const row = root?.querySelector?.('rpl-action-bar > div, div.shreddit-post-container');
  const vote = row?.querySelector('.rpl-vote-button-group, shreddit-post-vote, [data-post-click-location="vote"]');
  if (!vote) return null;
  return [...row.children].find(child => child === vote || child.contains(vote)) || null;
}

export function getRedditPieces(postElement, postData, mode) {
  const pieces = [];
  if (mode !== 'text') {
    if (postData.hasVideo) {
      pieces.push({
        element: postElement.querySelector('video, shreddit-player') || postElement,
        kind: 'video', level: 0, included: true
      });
    }
    // A gallery is one piece: its later pages sit offscreen in the carousel.
    const gallery = postData.hasVideo ? null : postElement.querySelector('gallery-carousel');
    const images = postData.hasVideo || gallery ? [] : postMediaImages(postElement);
    if (gallery) pieces.push({ element: gallery, kind: 'gallery', level: 0, included: true });
    images.forEach(element => pieces.push({ element, kind: 'image', level: 0, included: true }));
    if (!gallery && !images.length && !postData.hasVideo && (postData.hasImage || postData.hasGallery)) {
      pieces.push({ element: postElement, kind: 'image', level: 0, included: true });
    }
  }
  if (mode !== 'quick') {
    pieces.push({ element: postElement, kind: 'text', level: 0, included: true });
  }
  return pieces;
}

// Extract post data from new Reddit
export function extractNewRedditPost(postElement) {
  // New Reddit uses shreddit-post custom elements or article elements
  const isShredditPost = postElement.tagName.toLowerCase() === 'shreddit-post';

  let permalink, subreddit, title, author, score;
  let postId = '';
  let hasVideo = false, hasImage = false, hasGallery = false;
  let imageUrls = [];
  let imageAlts = [];

  if (isShredditPost) {
    const contentHref = postElement.getAttribute('content-href') || '';
    const postType = (postElement.getAttribute('post-type') || '').toLowerCase();

    permalink =
      postElement.getAttribute('permalink') ||
      postElement.querySelector('a[href*="/comments/"]')?.getAttribute('href') ||
      (normalizeRedditPermalink(contentHref) ? contentHref : '');
    subreddit = postElement.getAttribute('subreddit-prefixed-name') || '';
    title = postElement.getAttribute('post-title') || '';
    author = postElement.getAttribute('author') || '';
    score = postElement.getAttribute('score') || '0';
    postId = postElement.getAttribute('post-id') || '';

    // Check for media
    const imageData = collectImageData(postElement);
    imageUrls = imageData.imageUrls;
    imageAlts = imageData.imageAlts;
    hasVideo = postElement.querySelector('shreddit-player, video, [slot="post-media-container"] video') !== null ||
               postType.includes('video') ||
               isMediaVideoUrl(contentHref);
    hasImage = imageUrls.length > 0 ||
               postType.includes('image') ||
               isMediaImageUrl(contentHref);
    hasGallery = postElement.querySelector('[slot="gallery"], gallery-carousel, shreddit-gallery-carousel, [data-gallery-id], a[href*="/gallery/"]') !== null ||
                 postElement.hasAttribute('is-gallery') ||
                 postType.includes('gallery') ||
                 isRedditGalleryUrl(contentHref);
  } else {
    // Fallback for article-based posts
    const linkElement = postElement.querySelector('a[href*="/comments/"]');
    permalink = linkElement?.getAttribute('href') || '';

    const subredditLink = postElement.querySelector('a[href^="/r/"]');
    subreddit = subredditLink?.textContent || '';

    const titleElement = postElement.querySelector('h3, [slot="title"]');
    title = titleElement?.textContent || '';

    const authorLink = postElement.querySelector('a[href^="/user/"]');
    author = authorLink?.textContent?.replace('u/', '') || '';

    const scoreElement = postElement.querySelector('[score], [data-click-id="upvote"]');
    score = scoreElement?.textContent || '0';

    const postUrl =
      postElement.getAttribute('data-url') ||
      postElement.querySelector('a[href*="i.redd.it"], a[href*="preview.redd.it"], a[href*="v.redd.it"], a[href*="/gallery/"]')?.getAttribute('href') ||
      '';
    const imageData = collectImageData(postElement);
    imageUrls = imageData.imageUrls;
    imageAlts = imageData.imageAlts;

    hasVideo = postElement.querySelector('video, shreddit-player, [data-click-id="media"] video') !== null ||
               isMediaVideoUrl(postUrl);
    hasImage = imageUrls.length > 0 || isMediaImageUrl(postUrl);
    hasGallery = postElement.querySelector('[data-gallery-id], a[href*="/gallery/"]') !== null ||
                 isRedditGalleryUrl(postUrl);
  }

  // Ensure permalink is full URL
  permalink = normalizeRedditPermalink(permalink);

  const text = postElement.querySelector('[slot="text-body"], .md, [data-click-id="text"]')?.textContent?.trim() || '';
  const hasMedia = hasVideo || hasImage || hasGallery;
  postId = postId || permalink?.match(/comments\/([a-z0-9]+)/i)?.[1] || '';
  if (!permalink && postId) {
    permalink = `https://www.reddit.com/comments/${postId}`;
  }
  const mediaCount = imageUrls.length + (hasVideo ? 1 : 0) || (hasImage ? 1 : 0) || (hasGallery ? 1 : 0);

  return {
    permalink,
    subreddit,
    title,
    author,
    score,
    postId,
    hasMedia,
    hasVideo,
    hasImage,
    hasGallery,
    imageUrls,
    imageAlts,
    mediaCount,
    text
  };
}

// Extract post data from old Reddit
export function extractOldRedditPost(postElement) {
  const permalink = normalizeRedditPermalink(
    postElement.querySelector('a.comments, a.bylink')?.getAttribute('href') || ''
  );
  const subreddit = postElement.querySelector('.subreddit')?.textContent || '';
  const title = postElement.querySelector('a.title')?.textContent || '';
  const author = postElement.querySelector('.author')?.textContent || '';
  const score = postElement.querySelector('.score.unvoted')?.textContent || '0';

  const postUrl =
    postElement.getAttribute('data-url') ||
    postElement.querySelector('a.title')?.getAttribute('href') ||
    postElement.querySelector('a.thumbnail')?.getAttribute('href') ||
    '';
  const imageData = collectImageData(postElement);
  const imageUrls = imageData.imageUrls;
  if (isMediaImageUrl(postUrl)) addUniqueUrl(imageUrls, postUrl);

  const hasVideo = postElement.classList.contains('video') ||
                   postElement.querySelector('.expando video, video') !== null ||
                   isMediaVideoUrl(postUrl);
  const hasImage = postElement.classList.contains('image') ||
                   imageUrls.length > 0 ||
                   isMediaImageUrl(postUrl);
  const hasGallery = postElement.querySelector('.gallery, a[href*="/gallery/"]') !== null ||
                     isRedditGalleryUrl(postUrl);

  const text = postElement.querySelector('[slot="text-body"], .md, [data-click-id="text"]')?.textContent?.trim() || '';
  const hasMedia = hasVideo || hasImage || hasGallery;
  const postId = postElement.getAttribute('data-fullname')?.replace('t3_', '') || '';
  const mediaCount = imageUrls.length + (hasVideo ? 1 : 0) || (hasGallery ? 1 : 0) || (hasMedia ? 1 : 0);

  return {
    permalink,
    subreddit,
    title,
    author,
    score,
    postId,
    hasMedia,
    hasVideo,
    hasImage,
    hasGallery,
    imageUrls,
    imageAlts: imageData.imageAlts,
    mediaCount,
    text
  };
}


// Reddit-specific content script for nodraw
// Supports both old.reddit.com and new reddit (www.reddit.com)

(function() {
  'use strict';
  if (typeof document === 'undefined') return;

  const browserAPI = (typeof browser !== 'undefined') ? browser : chrome;

  // Monitoring - uses ArchiverMonitor loaded before this script
  const Monitor = typeof ArchiverMonitor !== 'undefined' ? ArchiverMonitor : null;
  const { LeakDetector, Metrics, Memory } = Monitor || { LeakDetector: null, Metrics: null, Memory: null };

  // Action-row glyphs live in each post's shadow root, out of reach of document queries.
  const nativeGlyphs = new Set();

  // SVG icon paths matching Twitter's stroke-based style
  const ICON_PATHS = {
    download: 'M12 3v12m0 0l-4-4m4 4l4-4M5 17v2a2 2 0 002 2h10a2 2 0 002-2v-2',
    quick: 'M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z',
    text: 'M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 012-2h2a2 2 0 012 2M9 5h6',
    loading: null,
    success: 'M5 13l4 4L19 7',
    error: 'M6 18L18 6M6 6l12 12'
  };

  const ICON_SIZE = 18;
  const STROKE_WIDTH = 2;

  // Generate icon SVG with fallback for invalid types
  function getIcon(type, size = ICON_SIZE) {
    if (type === 'loading') {
      return `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="${STROKE_WIDTH}" class="archiver-spin"><circle cx="12" cy="12" r="9" stroke-dasharray="40 20"/></svg>`;
    }
    const path = ICON_PATHS[type] || ICON_PATHS.download; // fallback to download icon
    return `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="${STROKE_WIDTH}" stroke-linecap="round" stroke-linejoin="round"><path d="${path}"/></svg>`;
  }

  // Configuration - Reddit orange theme, more visible
  const BUTTON_STYLES = {
    position: 'absolute',
    right: '8px',
    top: '8px',
    width: '32px',
    height: '32px',
    borderRadius: '50%',
    backgroundColor: 'rgba(255, 69, 0, 0.9)',
    backdropFilter: 'blur(12px)',
    border: 'none',
    cursor: 'pointer',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    zIndex: '10',
    transition: 'all 0.2s ease',
    opacity: '0',
    transform: 'scale(0.9)',
    color: 'white'
  };

  // Track processed posts and their cleanup controllers
  const processedPosts = new WeakSet();
  const downloadingPosts = new Set();
  // Store AbortControllers and timeouts for cleanup on element removal
  const elementControllers = new WeakMap();

  // Register collections for leak detection
  if (LeakDetector) {
    LeakDetector.register('downloadingPosts', downloadingPosts, 50);
    // Note: WeakSet/WeakMap don't expose size, so we track the Set
  }

  // Save modes mirroring Twitter: click=full context+image, shift=image only, alt=context only
  const SAVE_MODES = {
    full: { icon: 'download', label: 'Full save', desc: 'context + media' },
    quick: { icon: 'quick', label: 'Image only', desc: 'media only' },
    text: { icon: 'text', label: 'Context only', desc: 'screenshot + meta' }
  };

  // Create hover menu HTML with SVG icons (safe: hardcoded paths, not user input)
  function createHoverMenu() {
    const menu = document.createElement('div');
    menu.className = 'archiver-menu';
    menu.innerHTML = `
      <div class="archiver-menu-item active" data-mode="full">
        ${getIcon('download', 14)} Full save <kbd>click</kbd>
      </div>
      <div class="archiver-menu-item" data-mode="quick">
        ${getIcon('quick', 14)} Image only <kbd>⇧</kbd>
      </div>
      <div class="archiver-menu-item" data-mode="text">
        ${getIcon('text', 14)} Context only <kbd>⌥</kbd>
      </div>
    `;
    return menu;
  }

  // Detect Reddit version
  function isOldReddit() {
    return window.location.hostname === 'old.reddit.com' ||
           document.querySelector('#header-bottom-left') !== null;
  }

  // Capture element screenshot via background script
  async function captureElement(element) {
    const rect = element.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;

    const bounds = {
      x: Math.round((rect.x + window.scrollX) * dpr),
      y: Math.round(rect.y * dpr),
      width: Math.round(rect.width * dpr),
      height: Math.round(rect.height * dpr),
      viewportY: Math.round(rect.y),
      dpr: dpr
    };

    try {
      const response = await browserAPI.runtime.sendMessage({
        action: 'captureScreenshot',
        bounds: bounds
      });
      return response?.screenshot || null;
    } catch (error) {
      console.error('Screenshot capture failed:', error);
      return null;
    }
  }


  // Keep the site's glyphs and placement; shared capture state drives their rendering.
  const MODE_LABELS = { quick: '⇧ · image only', text: '⌥ · context only' };
  // Reddit's own pill classes from the post's shadow stylesheet; inline styles size the circle.
  const NATIVE_CLASSES = ['media-archiver-native-reddit', 'button', 'button-secondary', 'aspect-square', 'p-0',
    'inline-flex', 'items-center', 'justify-center'];

  // `native` is the always-visible glyph beside the votes; the hover overlay stays as it was.
  function createArchiveButton(postData, postElement, { native = false } = {}) {
    const button = document.createElement('button');
    button.className = native ? NATIVE_CLASSES.join(' ') : 'media-archiver-reddit-btn';
    button.dataset.archiverPostId = postData.postId;
    if (native) {
      Object.assign(button.style, { position: 'relative', width: '32px', height: '32px', minWidth: '32px',
        padding: '0', border: '0', borderRadius: '999px', cursor: 'pointer' });
    } else Object.assign(button.style, BUTTON_STYLES);

    const controller = createCaptureButton({
      button,
      // Resolved on hover: feed images load their src lazily after the button exists.
      target: () => getRedditPieces(postElement, postData, 'full').find(piece => piece.kind !== 'text')?.element || postElement,
      key: postData.postId,
      url: postData.permalink,
      hintUrls: mode => [window.location.href, ...(mode === 'text' ? [] : postData.imageUrls)],
      reservations: downloadingPosts,
      runtime: browserAPI.runtime,
      menu: () => button.querySelector('.archiver-menu'),
      getPieces: mode => getRedditPieces(postElement, postData, mode),
      modeLabels: MODE_LABELS,
      render(state, { mode, error } = {}) {
        if (native) {
          renderNativeGlyph(button, state, { mode, error }, { getIcon, modes: SAVE_MODES, size: 16 });
          return;
        }
        const active = state === 'idle' || state === 'hover';
        const icon = active ? SAVE_MODES[mode || 'full'].icon
          : state === 'saving' ? 'loading'
          : state === 'failed' ? 'error' : 'success';
        button.innerHTML = getIcon(icon);
        if (active) {
          const menu = createHoverMenu();
          menu.querySelectorAll('.archiver-menu-item').forEach(item => {
            item.classList.toggle('active', item.dataset.mode === (mode || 'full'));
          });
          button.appendChild(menu);
        }
        button.style.backgroundColor = active ? 'rgba(255, 69, 0, 0.9)'
          : state === 'saving' ? 'rgba(59, 130, 246, 0.95)'
          : state === 'failed' ? 'rgba(239, 68, 68, 0.9)' : 'rgba(34, 197, 94, 0.9)';
        if (!active) {
          button.style.opacity = '1';
          button.style.transform = 'scale(1)';
        }
        button.title = active ? 'Download post'
          : state === 'saving' ? 'Download in progress'
          : state === 'failed' ? (error || 'Download failed') : 'Archived';
        button.setAttribute('aria-label', button.title);
      },
      async submit(saveMode, event, captureAgain) {
        if (Metrics) Metrics.increment('buttons_clicked');
        let screenshot = null;
        if (saveMode !== 'quick') {
          // Action-row glyphs collapse, so the screenshot shows the row as Reddit draws it.
          screenshot = await withArchiverUIHidden(() => captureElement(postElement), { collapse: nativeGlyphs });
        }
        return NoDrawCapture.submit({
          kind: 'page',
          targetUrl: postData.permalink,
          sourcePageUrl: window.location.href,
          page: { title: postData.title, author: postData.author, description: postData.text || postData.title },
          options: {
            saveMode,
            screenshot,
            captureAgain,
            platform: 'reddit',
            siteData: {
              pageContext: window.location.href,
              mediaType: 'reddit',
              redditContent: {
                subreddit: postData.subreddit,
                title: postData.title,
                text: postData.text,
                author: postData.author,
                score: postData.score,
                hasVideo: postData.hasVideo,
                hasGallery: postData.hasGallery,
                imageUrls: postData.imageUrls,
                imageAlts: postData.imageAlts,
                mediaCount: postData.mediaCount
              }
            }
          }
        });
      }
    });
    button._archiverCleanup = () => controller.destroy();
    return button;
  }

  // Keep the glyph beside the votes; Reddit re-renders the action row and can drop it.
  function ensureNativeGlyph(postElement) {
    const data = elementControllers.get(postElement);
    const anchor = redditVoteAnchor(postElement.shadowRoot);
    if (!data || !anchor) return;
    if (data.native?.isConnected && data.native.previousElementSibling === anchor) return;
    if (!data.native) {
      data.native = createArchiveButton(data.postData, postElement, { native: true });
      nativeGlyphs.add(data.native);
    }
    anchor.after(data.native);
  }

  // Process new Reddit post
  function processNewRedditPost(postElement) {
    if (processedPosts.has(postElement)) {
      ensureNativeGlyph(postElement);
      return;
    }
    const tagName = postElement.tagName.toLowerCase();
    if (tagName === 'article' && postElement.querySelector('shreddit-post')) return;

    const postData = extractNewRedditPost(postElement);
    if (!postData.postId) return;

    // Find suitable container for button
    let container = postElement;
    if (tagName === 'shreddit-post') {
      container = postElement.shadowRoot?.querySelector('[slot="credit-bar"]')?.parentElement || postElement;
    }

    if (
      postElement.querySelector('.media-archiver-reddit-btn') ||
      container.querySelector(':scope > .media-archiver-reddit-btn')
    ) {
      processedPosts.add(postElement);
      return;
    }

    // Ensure container has relative positioning
    const computedStyle = window.getComputedStyle(container);
    if (computedStyle.position === 'static') {
      container.style.position = 'relative';
    }

    // Create AbortController for container event listeners
    const controller = new AbortController();
    const { signal } = controller;

    const archiveBtn = createArchiveButton(postData, postElement);
    container.appendChild(archiveBtn);

    // Track hoverTimeout for cleanup
    const state = { hoverTimeout: null };

    // Show on hover
    postElement.addEventListener('mouseenter', () => {
      clearTimeout(state.hoverTimeout);
      archiveBtn.style.opacity = '0.8';
      archiveBtn.style.transform = 'scale(1)';
    }, { signal });

    postElement.addEventListener('mouseleave', () => {
      state.hoverTimeout = setTimeout(() => {
        if (!downloadingPosts.has(postData.postId) && ['idle', 'hover'].includes(archiveBtn.dataset.archiverState)) {
          archiveBtn.style.opacity = '0';
          archiveBtn.style.transform = 'scale(0.9)';
        }
      }, 100);
    }, { signal });

    // Store controller and state for cleanup
    elementControllers.set(postElement, { controller, button: archiveBtn, state, postId: postData.postId, postData });
    ensureNativeGlyph(postElement);

    processedPosts.add(postElement);
    if (Metrics) Metrics.increment('buttons_created');
  }

  // Process old Reddit post
  function processOldRedditPost(postElement) {
    if (processedPosts.has(postElement)) return;

    const postData = extractOldRedditPost(postElement);
    if (!postData.postId) return;

    // Find the entry element
    const entry = postElement.querySelector('.entry') || postElement;
    if (
      postElement.querySelector('.media-archiver-reddit-btn') ||
      entry.querySelector(':scope > .media-archiver-reddit-btn')
    ) {
      processedPosts.add(postElement);
      return;
    }
    entry.style.position = 'relative';

    // Create AbortController for container event listeners
    const controller = new AbortController();
    const { signal } = controller;

    const archiveBtn = createArchiveButton(postData, postElement);
    entry.appendChild(archiveBtn);

    // Track hoverTimeout for cleanup
    const state = { hoverTimeout: null };

    // Show on hover
    postElement.addEventListener('mouseenter', () => {
      clearTimeout(state.hoverTimeout);
      archiveBtn.style.opacity = '0.8';
      archiveBtn.style.transform = 'scale(1)';
    }, { signal });

    postElement.addEventListener('mouseleave', () => {
      state.hoverTimeout = setTimeout(() => {
        if (!downloadingPosts.has(postData.postId) && ['idle', 'hover'].includes(archiveBtn.dataset.archiverState)) {
          archiveBtn.style.opacity = '0';
          archiveBtn.style.transform = 'scale(0.9)';
        }
      }, 100);
    }, { signal });

    // Store controller and state for cleanup
    elementControllers.set(postElement, { controller, button: archiveBtn, state, postId: postData.postId });

    processedPosts.add(postElement);
    if (Metrics) Metrics.increment('buttons_created');
  }

  // Process all visible posts
  function processAllPosts() {
    if (Memory) Memory.track('process_cycle');
    if (isOldReddit()) {
      const posts = document.querySelectorAll('.thing.link');
      posts.forEach(processOldRedditPost);
    } else {
      // New Reddit - shreddit-post elements
      const shredditPosts = document.querySelectorAll('shreddit-post');
      shredditPosts.forEach(processNewRedditPost);

      // Fallback for article-based layout
      const articlePosts = document.querySelectorAll('article');
      articlePosts.forEach(processNewRedditPost);
    }
  }

  // Cleanup function for removed elements
  function cleanupElement(element) {
    const data = elementControllers.get(element);
    if (data) {
      // Clear any pending hover timeout
      if (data.state?.hoverTimeout) {
        clearTimeout(data.state.hoverTimeout);
      }
      if (data.button?._archiverCleanup) {
        data.button._archiverCleanup();
      }
      if (data.native) {
        data.native._archiverCleanup?.();
        data.native.remove();
        nativeGlyphs.delete(data.native);
      }
      // Abort container listeners
      data.controller.abort();
      // Abort button's own listeners
      if (data.button?._abortController) {
        data.button._abortController.abort();
      }
      if (data.button?.isConnected) {
        data.button.remove();
      }
      elementControllers.delete(element);
    }
  }

  // Debounce processAllPosts to avoid hammering CPU on rapid DOM changes
  let processAllTimeout = null;
  function debouncedProcessAll() {
    if (processAllTimeout) return; // Already scheduled
    processAllTimeout = requestAnimationFrame(() => {
      processAllTimeout = null;
      processAllPosts();
    });
  }

  // MutationObserver for dynamic content with cleanup on removal
  const observer = new MutationObserver((mutations) => {
    // Check for removed nodes and clean up their listeners
    for (const mutation of mutations) {
      for (const node of mutation.removedNodes) {
        if (node.nodeType === Node.ELEMENT_NODE) {
          // Check if this element has a controller
          if (elementControllers.has(node)) {
            cleanupElement(node);
          }
          // Check descendants for post elements
          if (node.querySelectorAll) {
            const posts = node.querySelectorAll('shreddit-post, article, .thing.link');
            for (const post of posts) {
              if (elementControllers.has(post)) {
                cleanupElement(post);
              }
            }
          }
        }
      }
    }
    debouncedProcessAll();
  });

  // Cleanup on page unload
  window.addEventListener('beforeunload', () => {
    observer.disconnect();
    if (processAllTimeout) {
      cancelAnimationFrame(processAllTimeout);
      processAllTimeout = null;
    }
    downloadingPosts.clear();
  });

  // Initialize
  function initialize() {
    const mainContent = document.querySelector('main, #siteTable, .listing-page');
    if (mainContent) {
      observer.observe(mainContent, { childList: true, subtree: true });
      processAllPosts();

      // Periodic leak check (every 60 seconds)
      if (LeakDetector) {
        setInterval(() => LeakDetector.check(), 60000);
      }
    } else {
      setTimeout(initialize, 500);
    }
  }

  // Add styles
  const style = document.createElement('style');
  style.textContent = `
    .media-archiver-reddit-btn {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      -webkit-font-smoothing: antialiased;
      box-shadow: 0 2px 8px rgba(0,0,0,0.3);
    }

    .media-archiver-reddit-btn:hover {
      box-shadow: 0 4px 12px rgba(0,0,0,0.4);
      transform: scale(1.05) !important;
    }

    /* Spinner animation */
    .archiver-spin {
      animation: archiver-spin 1s linear infinite;
    }

    @keyframes archiver-spin {
      from { transform: rotate(0deg); }
      to { transform: rotate(360deg); }
    }

    /* Hover menu */
    .media-archiver-reddit-btn .archiver-menu {
      position: absolute;
      bottom: 100%;
      right: 0;
      margin-bottom: 8px;
      background: rgba(0, 0, 0, 0.9);
      backdrop-filter: blur(12px);
      border-radius: 8px;
      padding: 6px 0;
      min-width: 150px;
      opacity: 0;
      transform: translateY(4px);
      transition: all 0.15s ease;
      pointer-events: none;
      font-size: 12px;
      color: white;
      white-space: nowrap;
    }

    .media-archiver-reddit-btn .archiver-menu.visible {
      opacity: 1;
      transform: translateY(0);
    }

    .archiver-menu-item {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 6px 12px;
      opacity: 0.7;
    }

    .archiver-menu-item.active {
      opacity: 1;
      background: rgba(255, 255, 255, 0.1);
    }

    .archiver-menu-item kbd {
      font-family: inherit;
      font-size: 10px;
      padding: 2px 5px;
      background: rgba(255,255,255,0.15);
      border-radius: 3px;
      margin-left: auto;
    }

    @media print {
      .media-archiver-reddit-btn, .archiver-menu {
        display: none !important;
      }
    }
  `;
  document.head.appendChild(style);

  // Start
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initialize);
  } else {
    initialize();
  }

})();
