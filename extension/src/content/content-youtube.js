import { createCaptureButton } from './modules/capture-button.js';
import { renderNativeGlyph } from './modules/native-glyph.js';
import { withArchiverUIHidden } from './modules/capture-hide.js';

// Extract video ID from various URL formats
export function extractVideoId(url) {
  if (!url) return null;
  try {
    const parsed = new URL(url, 'https://www.youtube.com/');
    if (parsed.hostname === 'youtu.be') return parsed.pathname.split('/')[1] || null;
    if (!/(^|\.)youtube\.com$/.test(parsed.hostname)) return null;
    if (parsed.pathname === '/watch') return parsed.searchParams.get('v') || null;
    return parsed.pathname.match(/^\/(?:shorts|embed|v)\/([^/]+)/)?.[1] || null;
  } catch {
    return null;
  }
}

// Get canonical watch URL
export function getWatchUrl(videoId) {
  return `https://www.youtube.com/watch?v=${videoId}`;
}

export function getYouTubePieces(captureTarget, mode) {
  // The watch player frames itself: YouTube moves its <video> element around inside it.
  const player = captureTarget.matches?.('#movie_player, .html5-video-player');
  const pieces = [{
    element: player ? captureTarget
      : captureTarget.querySelector('video') || captureTarget.querySelector('ytd-thumbnail, #thumbnail') || captureTarget,
    kind: mode === 'quick' ? 'audio' : 'video', level: 0, included: true, scope: 'THIS VIDEO'
  }];
  if (mode === 'text') {
    pieces.push({ element: captureTarget, kind: 'transcripts', level: 0, included: true, scope: 'THIS VIDEO' });
  }
  return pieces;
}

// YouTube hashes its colour tokens, so the action-bar glyph borrows the class list of the bar's
// own tonal button instead: background, hover and light/dark theme then follow YouTube exactly.
export function borrowedButtonClasses(buttons) {
  const shape = [...buttons].map(button => [...button.classList].filter(name => name.startsWith('ytSpec')))
    .filter(names => names.length);
  const source = shape.find(names => names.some(name => name.endsWith('IconButton'))) || shape[0];
  if (!source) return [];
  const host = source.find(name => name.endsWith('Host'));
  const iconButton = host ? host.replace(/Host$/, 'IconButton') : null;
  const kept = source.filter(name => !/Segmented|IconLeading|IconTrailing/.test(name));
  return iconButton && !kept.includes(iconButton) ? [...kept, iconButton] : kept;
}

// Extract metadata from main video player page
export function extractPlayerMetadata(root = document) {
  root = root.querySelector('ytd-reel-video-renderer[is-active]') || root;
  const title = root.querySelector('h1.ytd-video-primary-info-renderer yt-formatted-string')?.textContent
    || root.querySelector('h1.ytd-watch-metadata yt-formatted-string')?.textContent
    || root.querySelector('#title h1')?.textContent
    || root.querySelector('h2.title yt-formatted-string, .ytShortsVideoTitleViewModelShortsVideoTitle')?.textContent
    || (root.title || '').replace(' - YouTube', '');

  const channel = root.querySelector('#channel-name a')?.textContent
    || root.querySelector('ytd-channel-name yt-formatted-string a')?.textContent
    || root.querySelector('.ytd-channel-name a')?.textContent
    || root.querySelector('.ytReelChannelBarViewModelChannelName a, #channel-name yt-formatted-string')?.textContent
    || '';

  const viewCount = root.querySelector('#count .view-count')?.textContent
    || root.querySelector('ytd-video-view-count-renderer span')?.textContent
    || '';

  const duration = root.querySelector('.ytp-time-duration')?.textContent || '';

  return { title: title.trim(), channel: channel.trim(), viewCount: viewCount.trim(), duration };
}

// Extract metadata from thumbnail element
export function extractThumbnailMetadata(container) {
  // Title from various possible locations
  const title = container.querySelector('#video-title')?.textContent
    || container.querySelector('a#video-title')?.textContent
    || container.querySelector('[id="video-title"]')?.getAttribute('title')
    || '';

  // Channel name
  const channel = container.querySelector('#channel-name a')?.textContent
    || container.querySelector('ytd-channel-name a')?.textContent
    || container.querySelector('.ytd-channel-name')?.textContent
    || '';

  // View count
  const viewCount = container.querySelector('#metadata-line span')?.textContent || '';

  // Duration from overlay
  const duration = container.querySelector('ytd-thumbnail-overlay-time-status-renderer span')?.textContent
    || container.querySelector('.ytd-thumbnail-overlay-time-status-renderer')?.textContent
    || '';

  return { title: title.trim(), channel: channel.trim(), viewCount: viewCount.trim(), duration: duration.trim() };
}


// YouTube specific content script with minimally invasive UI

(function() {
  'use strict';
  if (typeof document === 'undefined') return;

  // Firefox compatibility
  const browserAPI = (typeof browser !== 'undefined') ? browser : chrome;

  // Monitoring - uses ArchiverMonitor loaded before this script
  const Monitor = typeof ArchiverMonitor !== 'undefined' ? ArchiverMonitor : null;
  const { LeakDetector, Metrics, Memory } = Monitor || { LeakDetector: null, Metrics: null, Memory: null };

  // SVG icon paths matching Twitter's stroke-based style
  const ICON_PATHS = {
    download: 'M12 3v12m0 0l-4-4m4 4l4-4M5 17v2a2 2 0 002 2h10a2 2 0 002-2v-2',
    audio: 'M9 18V5l12-2v13M9 18c0 1.657-1.343 3-3 3s-3-1.343-3-3 1.343-3 3-3 3 1.343 3 3zm12-2c0 1.657-1.343 3-3 3s-3-1.343-3-3 1.343-3 3-3 3 1.343 3 3z',
    archive: 'M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10',
    loading: null, // special case - spinning circle
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

  // Configuration - YouTube red theme, more visible by default
  const BUTTON_STYLES = {
    position: 'absolute',
    width: '32px',
    height: '32px',
    borderRadius: '50%',
    backgroundColor: 'rgba(255, 0, 0, 0.85)',
    backdropFilter: 'blur(12px)',
    border: 'none',
    cursor: 'pointer',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    zIndex: '2000',
    transition: 'all 0.2s ease',
    opacity: '0',
    transform: 'scale(0.9)',
    color: 'white'
  };

  // Track processed elements and their cleanup controllers. YouTube reuses
  // renderer nodes during SPA navigation, so store the bound video ID too.
  const processedVideos = new WeakMap();
  const processedThumbnails = new WeakMap();
  const downloadingVideos = new Set();
  // Store AbortControllers for cleanup on element removal
  const elementControllers = new WeakMap();

  // Register collections for leak detection
  if (LeakDetector) {
    LeakDetector.register('downloadingVideos', downloadingVideos, 50);
    // Note: WeakSet/WeakMap don't expose size, so we track the Set
  }

  // Save modes: click=video, shift=audio, alt=full archive with transcriptions
  const SAVE_MODES = {
    full: { icon: 'download', label: 'Video', desc: 'max quality' },
    quick: { icon: 'audio', label: 'Audio', desc: 'audio only' },
    text: { icon: 'archive', label: 'Full archive', desc: 'video + transcripts' }
  };

  // Capture element screenshot via background script
  async function captureElement(element) {
    const rect = element.getBoundingClientRect();
    const scrollX = window.scrollX;
    const scrollY = window.scrollY;
    const dpr = window.devicePixelRatio || 1;

    const bounds = {
      x: Math.round((rect.x + scrollX) * dpr),
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


  // Create hover menu HTML with SVG icons
  function createHoverMenu() {
    const menu = document.createElement('div');
    menu.className = 'archiver-menu';
    // Safe: using hardcoded SVG icon paths, not user input
    menu.innerHTML = `
      <div class="archiver-menu-item active" data-mode="full">
        ${getIcon('download', 14)} Video <kbd>click</kbd>
      </div>
      <div class="archiver-menu-item" data-mode="quick">
        ${getIcon('audio', 14)} Audio <kbd>⇧</kbd>
      </div>
      <div class="archiver-menu-item" data-mode="text">
        ${getIcon('archive', 14)} Full archive <kbd>⌥</kbd>
      </div>
    `;
    return menu;
  }

  function getDirectArchiveButtons(element) {
    if (!element?.children) return [];
    return Array.from(element.children).filter(child =>
      child.classList?.contains('media-archiver-youtube-btn')
    );
  }

  function removeDirectArchiveButtons(element) {
    getDirectArchiveButtons(element).forEach(button => {
      if (button._archiverCleanup) button._archiverCleanup();
      if (button._abortController) button._abortController.abort();
      button.remove();
    });
  }

  const MODE_LABELS = { quick: '⇧ · audio only', text: '⌥ · full archive' };

  // Keep the site's glyphs and placement; shared capture state drives their rendering.
  // `native` is the always-visible action-bar glyph; the player overlay stays as it was.
  function createArchiveButton(videoId, getMetadata, captureTarget, { native = false } = {}) {
    const button = document.createElement('button');
    button.className = native ? 'media-archiver-native-youtube' : 'media-archiver-youtube-btn';
    button.dataset.archiverVideoId = videoId;
    if (!native) Object.assign(button.style, BUTTON_STYLES);

    const controller = createCaptureButton({
      button,
      target: getYouTubePieces(captureTarget, 'full')[0].element,
      key: videoId,
      url: getWatchUrl(videoId),
      hintUrls: () => [window.location.href],
      reservations: downloadingVideos,
      runtime: browserAPI.runtime,
      menu: () => button.querySelector('.archiver-menu'),
      getPieces: mode => getYouTubePieces(captureTarget, mode),
      modeLabels: MODE_LABELS,
      render(state, { mode, error } = {}) {
        if (native) {
          renderNativeGlyph(button, state, { mode, error }, { getIcon, modes: SAVE_MODES, size: 24 });
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
        button.style.backgroundColor = active ? 'rgba(255, 0, 0, 0.85)'
          : state === 'saving' ? 'rgba(59, 130, 246, 0.95)'
          : state === 'failed' ? 'rgba(239, 68, 68, 0.9)' : 'rgba(34, 197, 94, 0.9)';
        if (!active) {
          button.style.opacity = '1';
          button.style.transform = 'scale(1)';
        }
        button.title = active ? 'Download video'
          : state === 'saving' ? 'Download in progress'
          : state === 'failed' ? (error || 'Download failed') : 'Archived';
        button.setAttribute('aria-label', button.title);
      },
      async submit(saveMode, event, captureAgain) {
        if (Metrics) Metrics.increment('buttons_clicked');
        let screenshot = null;
        if (saveMode === 'text') {
          screenshot = await withArchiverUIHidden(() => captureElement(captureTarget));
        }
        const metadata = getMetadata();
        return NoDrawCapture.submit({
          kind: 'page',
          targetUrl: getWatchUrl(videoId),
          sourcePageUrl: window.location.href,
          page: { title: metadata.title, author: metadata.channel },
          options: {
            saveMode,
            screenshot,
            captureAgain,
            platform: 'youtube',
            siteData: {
              pageContext: window.location.href,
              mediaType: 'youtube',
              videoContent: { videoId, ...metadata }
            }
          }
        });
      }
    });
    button._archiverCleanup = () => controller.destroy();
    return button;
  }

  // Add button to main video player
  function processVideoPlayer() {
    const reel = document.querySelector('ytd-reel-video-renderer[is-active]');
    const player = (reel || document).querySelector('#movie_player');
    if (!player) return;

    const videoId = extractVideoId(window.location.href);
    if (!videoId) {
      if (processedVideos.has(player)) cleanupElement(player);
      removeDirectArchiveButtons(player);
      return;
    }

    const processed = processedVideos.get(player);
    if (processed?.videoId === videoId && processed.button?.isConnected) return;
    if (processed) cleanupElement(player);
    removeDirectArchiveButtons(player);

    // Find the controls area
    const controls = player.querySelector('.ytp-chrome-bottom');
    if (!controls) return;

    // Create AbortController for container event listeners
    const controller = new AbortController();
    const { signal } = controller;

    const button = createArchiveButton(videoId, extractPlayerMetadata, player);
    button.style.position = 'absolute';
    button.style.right = '12px';
    button.style.bottom = '60px';

    player.style.position = 'relative';
    player.appendChild(button);

    // Show on player hover
    player.addEventListener('mouseenter', () => {
      button.style.opacity = '0.9';
      button.style.transform = 'scale(1)';
    }, { signal });

    player.addEventListener('mouseleave', () => {
      if (!downloadingVideos.has(videoId)) {
        button.style.opacity = '0';
        button.style.transform = 'scale(0.9)';
      }
    }, { signal });

    // Store controller for cleanup
    elementControllers.set(player, { controller, button, videoId });

    processedVideos.set(player, { videoId, button });
    if (Metrics) Metrics.increment('buttons_created');
  }

  // Always-visible glyph left of the like/dislike pill on a watch page.
  let actionGlyph = null;

  function removeActionGlyph() {
    actionGlyph?.button._archiverCleanup?.();
    actionGlyph?.button.remove();
    actionGlyph = null;
  }

  function processWatchActions() {
    const videoId = location.pathname === '/watch' ? extractVideoId(location.href) : null;
    const bar = document.querySelector('ytd-watch-metadata #top-level-buttons-computed');
    const player = document.querySelector('ytd-watch-flexy #movie_player, #movie_player');
    if (!videoId || !bar || !player) {
      removeActionGlyph();
      return;
    }
    if (actionGlyph?.videoId === videoId && actionGlyph.button.parentElement === bar) return;
    removeActionGlyph();
    const like = bar.querySelector('segmented-like-dislike-button-view-model, like-button-view-model') || bar.firstElementChild;
    const button = createArchiveButton(videoId, extractPlayerMetadata, player, { native: true });
    button.classList.add(...borrowedButtonClasses(bar.querySelectorAll('button')));
    // A circle at the height of YouTube's pills, whatever size they currently use.
    const size = `${Math.round(like?.getBoundingClientRect().height) || 36}px`;
    Object.assign(button.style, { width: size, height: size, minWidth: size, padding: '0', borderRadius: '50%' });
    bar.insertBefore(button, like);
    actionGlyph = { videoId, button };
  }

  // Add button to video thumbnail
  function processThumbnail(container) {
    const processed = processedThumbnails.get(container);

    // Find the thumbnail element
    const thumbnail = container.querySelector('ytd-thumbnail, #thumbnail');
    if (!thumbnail) {
      if (processed) cleanupElement(container);
      return;
    }

    // Get video URL from link
    const link = container.querySelector('a#thumbnail, a[href*="watch"]');
    if (!link) {
      if (processed) cleanupElement(container);
      return;
    }

    const videoId = extractVideoId(link.href);
    if (!videoId) {
      if (processed) cleanupElement(container);
      return;
    }

    if (
      processed?.videoId === videoId &&
      processed.button?.isConnected &&
      processed.button.parentElement === thumbnail
    ) {
      return;
    }

    if (processed) cleanupElement(container);
    removeDirectArchiveButtons(thumbnail);

    // Create AbortController for container event listeners
    const controller = new AbortController();
    const { signal } = controller;

    const button = createArchiveButton(
      videoId,
      () => extractThumbnailMetadata(container),
      container
    );
    button.style.right = '4px';
    button.style.top = '4px';

    // Position relative to thumbnail
    thumbnail.style.position = 'relative';
    thumbnail.appendChild(button);

    // Show on container hover
    container.addEventListener('mouseenter', () => {
      button.style.opacity = '0.9';
      button.style.transform = 'scale(1)';
    }, { signal });

    container.addEventListener('mouseleave', () => {
      if (!downloadingVideos.has(videoId)) {
        button.style.opacity = '0';
        button.style.transform = 'scale(0.9)';
      }
    }, { signal });

    // Store controller for cleanup
    elementControllers.set(container, { controller, button, videoId });

    processedThumbnails.set(container, { videoId, button, thumbnail });
    if (Metrics) Metrics.increment('buttons_created');
  }

  // Process all video thumbnails
  function processAllThumbnails() {
    // Video renderers in feeds, search, recommendations
    const selectors = [
      'ytd-video-renderer',
      'ytd-grid-video-renderer',
      'ytd-compact-video-renderer',
      'ytd-rich-item-renderer',
      'ytd-playlist-video-renderer'
    ];

    selectors.forEach(selector => {
      document.querySelectorAll(selector).forEach(processThumbnail);
    });
  }

  // Process all elements
  function processAll() {
    if (Memory) Memory.track('process_cycle');
    processVideoPlayer();
    processWatchActions();
    processAllThumbnails();
  }

  // Cleanup function for removed elements
  function cleanupElement(element) {
    const data = elementControllers.get(element);
    if (data) {
      if (data.button?._archiverCleanup) {
        data.button._archiverCleanup();
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
    processedVideos.delete(element);
    processedThumbnails.delete(element);
  }

  // Debounce processAll to avoid hammering CPU on rapid DOM changes
  let processAllTimeout = null;
  function debouncedProcessAll() {
    if (processAllTimeout) return; // Already scheduled
    processAllTimeout = requestAnimationFrame(() => {
      processAllTimeout = null;
      processAll();
    });
  }

  // Observer for dynamic content with cleanup on removal
  const observer = new MutationObserver((mutations) => {
    // Check for removed nodes and clean up their listeners
    for (const mutation of mutations) {
      for (const node of mutation.removedNodes) {
        if (node.nodeType === Node.ELEMENT_NODE) {
          // Check if this element or its descendants have controllers
          if (elementControllers.has(node)) {
            cleanupElement(node);
          }
          // Check descendants
          if (node.querySelectorAll) {
            const descendants = node.querySelectorAll('.media-archiver-youtube-btn');
            for (const btn of descendants) {
              const parent = btn.closest('ytd-video-renderer, ytd-grid-video-renderer, ytd-compact-video-renderer, ytd-rich-item-renderer, ytd-playlist-video-renderer, #movie_player');
              if (parent && elementControllers.has(parent)) {
                cleanupElement(parent);
              }
            }
          }
        }
      }
    }
    debouncedProcessAll();
  });

  function handleYouTubeNavigation() {
    debouncedProcessAll();
    setTimeout(debouncedProcessAll, 250);
    setTimeout(debouncedProcessAll, 1000);
  }

  window.addEventListener('yt-navigate-finish', handleYouTubeNavigation);
  window.addEventListener('yt-page-data-updated', handleYouTubeNavigation);
  window.addEventListener('popstate', handleYouTubeNavigation);

  // Cleanup on page unload
  window.addEventListener('beforeunload', () => {
    observer.disconnect();
    if (processAllTimeout) {
      cancelAnimationFrame(processAllTimeout);
      processAllTimeout = null;
    }
    window.removeEventListener('yt-navigate-finish', handleYouTubeNavigation);
    window.removeEventListener('yt-page-data-updated', handleYouTubeNavigation);
    window.removeEventListener('popstate', handleYouTubeNavigation);
    downloadingVideos.clear();
  });

  // Initialize
  function initialize() {
    const main = document.querySelector('ytd-app, body');
    if (main) {
      observer.observe(main, { childList: true, subtree: true });
      processAll();

      // Periodic leak check (every 60 seconds)
      if (LeakDetector) {
        setInterval(() => LeakDetector.check(), 60000);
      }
    } else {
      setTimeout(initialize, 500);
    }
  }

  // Add custom styles
  const style = document.createElement('style');
  style.textContent = `
    .media-archiver-youtube-btn {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      -webkit-font-smoothing: antialiased;
      box-shadow: 0 2px 8px rgba(0,0,0,0.3);
    }

    .media-archiver-youtube-btn:hover {
      box-shadow: 0 4px 12px rgba(0,0,0,0.4);
      transform: scale(1.05) !important;
    }

    /* Action-bar glyph: YouTube's borrowed classes paint it; these are fallbacks only. */
    .media-archiver-native-youtube {
      flex: none;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      margin: 0 8px 0 0;
      border: 0;
      cursor: pointer;
      background: rgba(127, 127, 127, 0.16);
      color: inherit;
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
    .media-archiver-youtube-btn .archiver-menu {
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

    .media-archiver-youtube-btn .archiver-menu.visible {
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

    /* Hide on print */
    @media print {
      .media-archiver-youtube-btn, .media-archiver-native-youtube, .archiver-menu {
        display: none !important;
      }
    }
  `;
  document.head.appendChild(style);

  // Initialize when ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initialize);
  } else {
    initialize();
  }

})();
