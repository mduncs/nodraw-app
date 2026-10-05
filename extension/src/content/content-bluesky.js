// Bluesky specific content script with minimally invasive UI
import { createCaptureButton } from './modules/capture-button.js';
import { createCaptureAdmission } from './capture-admission.js';
import { postTitle } from './modules/post-title.js';
import { withArchiverUIHidden } from './modules/capture-hide.js';

(function() {
  'use strict';

  const browserAPI = (typeof browser !== 'undefined') ? browser : chrome;

  const ICON_PATHS = {
    download: 'M12 3v12m0 0l-4-4m4 4l4-4M5 17v2a2 2 0 002 2h10a2 2 0 002-2v-2',
    quick: 'M12 4v12m0 0l-4-4m4 4l4-4',
    text: 'M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 012-2h2a2 2 0 012 2M9 5h6',
    loading: null,
    success: 'M5 13l4 4L19 7',
    error: 'M6 18L18 6M6 6l12 12',
    archived: 'M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z',
    tooSmall: 'M4 14l6-6m0 0v5m0-5H5M20 10l-6 6m0 0v-5m0 5h5'
  };


  function getIcon(type, size = 18) {
    if (type === 'loading') {
      return '<svg viewBox="0 0 24 24" width="' + size + '" height="' + size + '" fill="none" stroke="currentColor" stroke-width="2" class="archiver-spin"><circle cx="12" cy="12" r="9" stroke-dasharray="40 20"/></svg>';
    }
    return '<svg viewBox="0 0 24 24" width="' + size + '" height="' + size + '" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="' + ICON_PATHS[type] + '"/></svg>';
  }

  const processedPosts = new WeakMap();
  const downloadingPosts = createCaptureAdmission();
  const archiveStatusCache = new Map();

  function getArchiveCacheKey(url, postId) {
    return postId || url;
  }

  function getPostKey(postData) {
    return postData.postId || postData.postUrl;
  }


  async function checkArchiveStatus(url, postId) {
    const cacheKey = getArchiveCacheKey(url, postId);
    if (archiveStatusCache.has(cacheKey)) return archiveStatusCache.get(cacheKey);
    try {
      const response = await browserAPI.runtime.sendMessage({ action: 'checkArchived', url: url });
      const status = { archived: response?.archived || false, age_days: response?.age_days || 0, file_exists: response?.file_exists || false, file_path: response?.file_path || null };
      archiveStatusCache.set(cacheKey, status);
      return status;
    } catch (e) { return { archived: false }; }
  }

  function showReArchivePrompt(postData, archiveStatus) {
    return new Promise((resolve) => {
      const overlay = document.createElement('div');
      overlay.className = 'archiver-modal-overlay';
      overlay.style.cssText = 'position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,0.6);backdrop-filter:blur(4px);z-index:2147483647;display:flex;align-items:center;justify-content:center;';
      const ageStr = archiveStatus.age_days === 0 ? 'today' : archiveStatus.age_days === 1 ? 'yesterday' : archiveStatus.age_days + ' days ago';
      const modal = document.createElement('div');
      modal.className = 'archiver-modal';
      modal.style.cssText = 'background:rgb(22,24,28);border-radius:16px;padding:24px;max-width:320px;color:white;font-family:InterVariable,system-ui,-apple-system,sans-serif;box-shadow:0 8px 32px rgba(0,0,0,0.4);';
      const title = document.createElement('div');
      title.style.cssText = 'font-size:16px;font-weight:600;margin-bottom:8px;';
      title.textContent = 'Already Archived';
      const desc = document.createElement('div');
      desc.style.cssText = 'font-size:14px;color:rgb(139,148,158);margin-bottom:16px;';
      desc.textContent = 'This post was archived ' + ageStr + '. ' + (archiveStatus.file_exists ? '✓ File exists.' : '⚠ File may have moved.');
      const btnContainer = document.createElement('div');
      btnContainer.style.cssText = 'display:flex;flex-direction:column;gap:8px;';
      const redownloadBtn = document.createElement('button');
      redownloadBtn.dataset.action = 'redownload';
      redownloadBtn.style.cssText = 'background:rgb(0,106,255);color:white;border:none;padding:12px 16px;border-radius:9999px;font-size:14px;font-weight:600;cursor:pointer;';
      redownloadBtn.textContent = 'Re-download fresh copy';
      const cancelBtn = document.createElement('button');
      cancelBtn.dataset.action = 'cancel';
      cancelBtn.style.cssText = 'background:transparent;color:rgb(139,148,158);border:1px solid rgb(56,68,77);padding:12px 16px;border-radius:9999px;font-size:14px;font-weight:600;cursor:pointer;';
      cancelBtn.textContent = 'Cancel';
      btnContainer.appendChild(redownloadBtn);
      btnContainer.appendChild(cancelBtn);
      modal.appendChild(title);
      modal.appendChild(desc);
      modal.appendChild(btnContainer);
      overlay.appendChild(modal);
      document.body.appendChild(overlay);
      let settled = false;
      function close(shouldRedownload) {
        if (settled) return;
        settled = true;
        document.removeEventListener('keydown', handleKeydown);
        overlay.remove();
        resolve(shouldRedownload);
      }
      function handleKeydown(e) {
        if (e.key === 'Escape') close(false);
      }
      [redownloadBtn, cancelBtn].forEach(btn => btn.addEventListener('click', () => close(btn.dataset.action === 'redownload')));
      overlay.addEventListener('click', (e) => { if (e.target === overlay) close(false); });
      document.addEventListener('keydown', handleKeydown);
    });
  }

  const SAVE_MODES = { full: { icon: 'download' }, quick: { icon: 'quick' }, text: { icon: 'text' } };

  function createHoverMenu() {
    const menu = document.createElement('div');
    menu.className = 'archiver-menu';
    [{ mode: 'full', icon: 'download', label: 'Full save', kbd: 'click', active: true },
     { mode: 'quick', icon: 'quick', label: 'Quick', kbd: '⇧', active: false },
     { mode: 'text', icon: 'text', label: 'Text only', kbd: '⌥', active: false }].forEach(m => {
      const item = document.createElement('div');
      item.className = 'archiver-menu-item' + (m.active ? ' active' : '');
      item.dataset.mode = m.mode;
      const iconSpan = document.createElement('span');
      iconSpan.innerHTML = getIcon(m.icon, 14);
      const kbd = document.createElement('kbd');
      kbd.textContent = m.kbd;
      item.appendChild(iconSpan);
      item.appendChild(document.createTextNode(' ' + m.label + ' '));
      item.appendChild(kbd);
      menu.appendChild(item);
    });
    return menu;
  }

  async function captureElement(element) {
    const rect = element.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;
    const bounds = { x: Math.round((rect.x + window.scrollX) * dpr), y: Math.round(rect.y * dpr), width: Math.round(rect.width * dpr), height: Math.round(rect.height * dpr), viewportY: Math.round(rect.y), dpr: dpr };
    try {
      const response = await browserAPI.runtime.sendMessage({ action: 'captureScreenshot', bounds: bounds });
      return response?.screenshot || null;
    } catch (e) { return null; }
  }


  function normalizePostPath(href) {
    if (!href) return '';
    try {
      const url = new URL(href, 'https://bsky.app');
      if (url.hostname !== 'bsky.app') return '';
      return url.pathname.replace(/\/(liked-by|reposted-by|quotes)$/, '');
    } catch (e) {
      return href.startsWith('/profile/')
        ? href.replace(/\/(liked-by|reposted-by|quotes)$/, '')
        : '';
    }
  }

  function getPostHandleFromPath(postPath) {
    return postPath.match(/\/profile\/([^/]+)\/post\//)?.[1] || '';
  }

  function extractPostContent(postElement) {
    const postText = postElement.querySelector('[data-testid="postText"]')?.innerText || '';
    const feedItem = postElement.closest('[data-testid^="feedItem-by-"]');
    const threadItem = postElement.closest('[data-testid^="postThreadItem-by-"]');
    let handle = '';
    if (feedItem) handle = feedItem.getAttribute('data-testid')?.replace('feedItem-by-', '') || '';
    else if (threadItem) handle = threadItem.getAttribute('data-testid')?.replace('postThreadItem-by-', '') || '';
    const timeLink = postElement.querySelector('a[href*="/post/"]');
    const timestamp = timeLink?.getAttribute('aria-label') || '';
    // Find the main post link, excluding engagement stat links (liked-by, reposted-by, quotes)
    const allPostLinks = Array.from(postElement.querySelectorAll('a[href*="/profile/"][href*="/post/"]'));
    const mainPostLink = allPostLinks.find(a => {
      const href = a.getAttribute('href') || '';
      return !href.includes('/liked-by') && !href.includes('/reposted-by') && !href.includes('/quotes');
    });
    let postPath = normalizePostPath(mainPostLink?.getAttribute('href') || '');
    if (!postPath && threadItem && window.location.pathname.includes('/post/')) {
      // On detail page, use the URL directly (strip any suffixes)
      postPath = normalizePostPath(window.location.pathname);
    }
    if (!handle) handle = getPostHandleFromPath(postPath);
    const postUrl = postPath ? new URL(postPath, 'https://bsky.app').href : '';
    const postId = postPath.match(/\/post\/([^/]+)/)?.[1] || '';
    const imageElements = Array.from(postElement.querySelectorAll('img[src*="cdn.bsky.app/img/feed_"]'));
    const images = imageElements.map(img => ({
      url: img.src.replace('feed_thumbnail', 'feed_fullsize'),
      alt: img.alt || ''
    }));
    const imageUrls = images.map(i => i.url);
    const imageAlts = images.map(i => i.alt).filter(a => a);
    const hasVideo = postElement.querySelector('video') !== null;
    // console.log('[archiver] extractPostContent:', { handle, imageCount: images.length, imageAlts, postUrl });
    return { text: postText, handle, timestamp, postId, postUrl, hasMedia: images.length > 0 || hasVideo, hasImage: images.length > 0, hasVideo, imageUrls, imageAlts, mediaCount: images.length + (hasVideo ? 1 : 0) };
  }

  function findActionButton(postElement, testId, ariaNeedle) {
    const byTestId = postElement.querySelector('[data-testid="' + testId + '"]');
    if (byTestId) return byTestId;
    const needle = ariaNeedle.toLowerCase();
    return Array.from(postElement.querySelectorAll('button[aria-label]')).find(btn => (
      btn.getAttribute('aria-label').toLowerCase().includes(needle)
    )) || null;
  }

  function getDirectChildWithin(element, container) {
    let child = element;
    while (child && child.parentElement && child.parentElement !== container) {
      child = child.parentElement;
    }
    return child && child.parentElement === container ? child : element;
  }

  function setButtonIcon(button, iconType, menu) {
    const size = button.dataset.iconSize || 18;
    while (button.firstChild) button.removeChild(button.firstChild);
    const iconContainer = document.createElement('span');
    iconContainer.innerHTML = getIcon(iconType, size);
    button.appendChild(iconContainer.firstChild);
    if (menu) button.appendChild(menu);
  }

  function createArchiveButton(postData, postElement) {
    const iconSize = 18;
    const postKey = getPostKey(postData);

    // Wrapper to hold button and menu as siblings (so menu doesn't expand button's bounding box)
    const wrapper = document.createElement('div');
    wrapper.className = 'media-archiver-bsky-wrapper';
    wrapper.style.cssText = 'position:relative;display:flex;align-items:center;';

    const button = document.createElement('button');
    button.className = 'media-archiver-bsky-btn';
    button.setAttribute('aria-label', 'Archive post');
    button.setAttribute('role', 'button');
    button.setAttribute('tabindex', '0');
    button.dataset.iconSize = iconSize;

    const initialIcon = document.createElement('span');
    initialIcon.innerHTML = getIcon('download', iconSize);
    button.appendChild(initialIcon.firstChild);

    // Match native Bluesky button size exactly
    button.style.cssText = 'justify-content:center;align-items:center;border-radius:999px;background:transparent;padding:5px;border:none;cursor:pointer;display:flex;color:rgb(102,123,153);transition:color 0.15s,background-color 0.15s;';

    const menu = createHoverMenu();
    wrapper.appendChild(button);
    wrapper.appendChild(menu);

    createCaptureButton({
      button, target: postElement.querySelector('img[src*="cdn.bsky.app/img/feed_"], video') || postElement,
      menu, runtime: browserAPI.runtime, key: postKey, url: postData.postUrl,
      hintUrls: mode => [window.location.href, ...(mode === 'text' ? [] : postData.imageUrls)],
      reservations: downloadingPosts,
      getArchiveStatus: () => checkArchiveStatus(postData.postUrl, postData.postId),
      confirmAgain: status => showReArchivePrompt(postData, status),
      onKept: () => archiveStatusCache.set(getArchiveCacheKey(postData.postUrl, postData.postId), {
        archived: true, age_days: 0, file_exists: true
      }),
      modeLabels: { quick: '⇧ · media only', text: '⌥ · post text' },
      getPieces: mode => {
        const pieces = mode === 'text' ? [] : Array.from(postElement.querySelectorAll('img, video'))
          .filter(el => el.tagName === 'VIDEO' || postData.imageUrls.some(url => el.src.replace('feed_thumbnail', 'feed_fullsize') === url))
          .map(element => ({ element, kind: element.tagName === 'VIDEO' ? 'video' : 'image', level: 0, included: true }));
        if (mode !== 'quick') pieces.push({ element: postElement, kind: 'text', level: 0, included: true, label: 'TEXT · THIS POST' });
        return pieces;
      },
      render: (state, info) => {
        const icon = state === 'saving' ? 'loading' : state === 'kept' ? 'success' : state === 'already' ? 'archived' : state === 'failed' ? 'error' : SAVE_MODES[info.mode].icon;
        setButtonIcon(button, icon, null);
        button.style.color = state === 'failed' ? 'rgb(239,68,68)' : ['kept', 'already'].includes(state) ? 'rgb(34,197,94)' : ['hover', 'saving'].includes(state) ? 'rgb(0,106,255)' : 'rgb(102,123,153)';
        button.style.backgroundColor = state === 'hover' ? 'rgba(0,106,255,0.1)' : 'transparent';
        button.style.opacity = state === 'already' ? '0.7' : '1';
        button.title = info.error || (state === 'saving' ? 'Sending to archive server' : state === 'kept' ? 'Archive completed' : state === 'already' ? 'Already archived' : 'Archive post');
        button.setAttribute('aria-label', button.title);
        menu.querySelectorAll('.archiver-menu-item').forEach(item => item.classList.toggle('active', item.dataset.mode === info.mode));
      },
      submit: async (saveMode, event, captureAgain) => {
        let screenshot = null;
        if (saveMode !== 'quick') {
          screenshot = await withArchiverUIHidden(() => captureElement(postElement));
        }
        return NoDrawCapture.submit({
          kind: 'page', targetUrl: postData.postUrl, sourcePageUrl: window.location.href,
          page: { title: postTitle(postData.handle, postData.text, 'Bluesky'), author: postData.handle, description: postData.text, publishedAt: postData.timestamp },
          options: {
            saveMode, captureAgain, screenshot, platform: 'bluesky',
            siteData: {
              pageContext: window.location.href, mediaType: 'bluesky',
              postContent: { text: postData.text, handle: postData.handle, timestamp: postData.timestamp, mediaCount: postData.mediaCount, imageUrls: postData.imageUrls, imageAlts: postData.imageAlts, hasVideo: postData.hasVideo, hasImage: postData.hasImage }
            }
          }
        });
      }
    });

    return wrapper;
  }

  function processPost(postElement) {
    if (processedPosts.has(postElement)) return;
    const postData = extractPostContent(postElement);
    if (!postData.text && !postData.hasMedia) return;
    if (!postData.postUrl) return;
    const bookmarkBtn = findActionButton(postElement, 'postBookmarkBtn', 'bookmark');
    if (!bookmarkBtn) return;
    const rightActionBar = bookmarkBtn.closest('[role="group"]') || bookmarkBtn.parentElement;
    if (!rightActionBar || rightActionBar.querySelector('.media-archiver-bsky-wrapper')) { processedPosts.set(postElement, true); return; }
    const archiveWrapper = createArchiveButton(postData, postElement);
    const shareBtn = findActionButton(rightActionBar, 'postShareBtn', 'share');
    const bookmarkWrapper = getDirectChildWithin(bookmarkBtn, rightActionBar);
    const shareWrapper = shareBtn ? getDirectChildWithin(shareBtn, rightActionBar) : null;
    if (bookmarkWrapper?.nextSibling) rightActionBar.insertBefore(archiveWrapper, bookmarkWrapper.nextSibling);
    else if (shareWrapper) rightActionBar.insertBefore(archiveWrapper, shareWrapper);
    else rightActionBar.appendChild(archiveWrapper);
    processedPosts.set(postElement, true);
  }

  function getPostCandidates() {
    const candidates = new Set();
    [
      '[data-testid^="feedItem-by-"]',
      '[data-testid^="postThreadItem-by-"]',
      'article'
    ].forEach(selector => {
      document.querySelectorAll(selector).forEach(element => {
        if (element.querySelector('[data-testid="postText"], a[href*="/profile/"][href*="/post/"], video, img[src*="cdn.bsky.app/img/feed_"]')) {
          candidates.add(element);
        }
      });
    });
    return candidates;
  }

  function processAllPosts() {
    getPostCandidates().forEach(processPost);
  }

  let processFrame = null;
  let initializeTimer = null;
  let observedMain = null;
  let disposed = false;

  function scheduleProcessAllPosts() {
    if (processFrame !== null || disposed) return;
    processFrame = requestAnimationFrame(() => {
      processFrame = null;
      processAllPosts();
    });
  }

  function cleanupArchiverNode(node) {
    if (!(node instanceof Element) || node.isConnected) return;
    const buttons = node.matches('.media-archiver-bsky-btn')
      ? [node]
      : Array.from(node.querySelectorAll('.media-archiver-bsky-btn'));
    buttons.forEach(button => {
      if (button._archiverCleanup) button._archiverCleanup();
    });
  }

  function cleanupRemovedNodes(mutations) {
    mutations.forEach(mutation => {
      mutation.removedNodes.forEach(cleanupArchiverNode);
    });
  }

  const observer = new MutationObserver((mutations) => {
    cleanupRemovedNodes(mutations);
    scheduleProcessAllPosts();
  });

  function observeMain(main) {
    if (!main || observedMain === main || disposed) return;
    if (observedMain) observer.disconnect();
    observedMain = main;
    observedMain.dataset.archiverAttached = 'true';
    observer.observe(observedMain, { childList: true, subtree: true });
    processAllPosts();
  }

  function initialize() {
    if (disposed) return;
    const main = document.querySelector('main') || document.querySelector('[data-testid="HomeScreen"]') || document.querySelector('[data-testid="postThreadScreen"]');
    if (main) observeMain(main);
    else initializeTimer = setTimeout(initialize, 500);
  }

  // Also watch body for late-loading main element (React hydration)
  const bodyObs = new MutationObserver((mutations) => {
    cleanupRemovedNodes(mutations);
    const main = document.querySelector('main');
    if (main) observeMain(main);
  });
  if (document.body) bodyObs.observe(document.body, { childList: true, subtree: true });

  const style = document.createElement('style');
  style.textContent = '.media-archiver-bsky-btn{font-family:InterVariable,system-ui,sans-serif;-webkit-font-smoothing:antialiased}.media-archiver-bsky-btn:hover{color:rgb(0,106,255)!important;background-color:rgba(0,106,255,0.1)!important}.media-archiver-bsky-btn svg{display:block}.archiver-spin{animation:archiver-spin 1s linear infinite}@keyframes archiver-spin{from{transform:rotate(0deg)}to{transform:rotate(360deg)}}.media-archiver-bsky-wrapper .archiver-menu{position:absolute;bottom:100%;left:50%;transform:translateX(-50%) translateY(4px) scale(0.95);margin-bottom:8px;background:rgba(0,0,0,0.9);backdrop-filter:blur(12px);border-radius:12px;padding:8px 0;min-width:150px;opacity:0;transition:all 0.15s ease;pointer-events:none;font-size:13px;color:white;white-space:nowrap;box-shadow:0 4px 12px rgba(0,0,0,0.3);z-index:9999}.media-archiver-bsky-wrapper .archiver-menu.visible{opacity:1;transform:translateX(-50%) translateY(0) scale(1);pointer-events:auto}.archiver-menu-item{display:flex;align-items:center;gap:8px;padding:8px 12px;opacity:0.6;transition:all 0.1s}.archiver-menu-item:hover{opacity:1;background:rgba(255,255,255,0.1)}.archiver-menu-item.active{opacity:1;background:rgba(0,106,255,0.2)}.archiver-menu-item svg{flex-shrink:0}.archiver-menu-item kbd{font-family:inherit;font-size:11px;padding:2px 6px;background:rgba(255,255,255,0.1);border-radius:4px;margin-left:auto;opacity:0.7}@media print{.media-archiver-bsky-btn,.archiver-menu,.media-archiver-bsky-wrapper{display:none!important}}';
  // The menu is a keyboard-shortcut hint, not an interactive popover. Keep it
  // non-interactive so moving away from the button reliably dismisses it.
  style.textContent += '.media-archiver-bsky-wrapper .archiver-menu.visible{pointer-events:none}';
  document.head.appendChild(style);

  function cleanup() {
    if (disposed) return;
    disposed = true;
    observer.disconnect();
    bodyObs.disconnect();
    if (processFrame !== null) cancelAnimationFrame(processFrame);
    if (initializeTimer) clearTimeout(initializeTimer);
    document.querySelectorAll('.media-archiver-bsky-btn').forEach(button => button._archiverCleanup?.());
    document.removeEventListener('DOMContentLoaded', initialize);
    window.removeEventListener('pagehide', handlePageHide);
    window.removeEventListener('beforeunload', cleanup);
  }

  function handlePageHide(event) {
    if (!event.persisted) cleanup();
  }

  window.addEventListener('pagehide', handlePageHide);
  window.addEventListener('beforeunload', cleanup, { once: true });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize);
  else initialize();
})();
