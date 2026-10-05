import { createCaptureButton } from './modules/capture-button.js';

// Generic image downloader - OFF by default, enabled per-site
// Scans page for large images and adds download buttons

(function() {
  'use strict';

  const browserAPI = (typeof browser !== 'undefined') ? browser : chrome;

  // Check if already initialized (avoid double-injection)
  if (window.__archiverGenericInitialized) return;
  window.__archiverGenericInitialized = true;

  const CURRENT_HOST = window.location.hostname.replace(/^www\./, '');

  // Minimum image dimensions to show download button
  const MIN_WIDTH = 300;
  const MIN_HEIGHT = 300;

  // Button styles - same as gallery script
  const BUTTON_STYLES = {
    position: 'absolute',
    right: '8px',
    top: '8px',
    width: '24px',
    height: '24px',
    minWidth: '24px',
    maxWidth: '24px',
    minHeight: '24px',
    maxHeight: '24px',
    padding: '0',
    margin: '0',
    borderRadius: '6px',
    backgroundColor: 'rgba(0, 0, 0, 0.7)',
    backdropFilter: 'blur(8px)',
    border: '2px solid rgba(255, 255, 255, 0.3)',
    cursor: 'pointer',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    color: 'white',
    zIndex: '999999',
    transition: 'all 0.15s ease',
    opacity: '0',
    transform: 'scale(1)',
    boxSizing: 'border-box',
    lineHeight: '1'
  };

  const ICONS = {
    dot: `<svg viewBox="0 0 24 24" width="10" height="10"><circle cx="12" cy="12" r="5" fill="currentColor"/></svg>`,
    success: `<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 13l4 4L19 7"/></svg>`,
    error: `<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M6 18L18 6M6 6l12 12"/></svg>`,
    loading: `<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" class="archiver-generic-spin"><circle cx="12" cy="12" r="9" stroke-dasharray="40 20"/></svg>`
  };

  let imageButtonEntries = new WeakMap();
  const activeButtonEntries = new Set();
  const downloadingImages = new Set();
  let isEnabled = false;
  let observer = null;
  let scrollTimeout = null;
  let scanScheduled = false;

  // Check if this site is enabled
  async function checkEnabled() {
    try {
      const result = await browserAPI.storage.local.get('genericDownloaderSites');
      const sites = result.genericDownloaderSites || {};
      isEnabled = sites[CURRENT_HOST] === true;
      // console.log(`[archiver-generic] ${CURRENT_HOST}: ${isEnabled ? 'enabled' : 'disabled'}`);
      return isEnabled;
    } catch (e) {
      console.error('[archiver-generic] Error checking enabled status:', e);
      return false;
    }
  }

  // Get best image URL (try to find larger version)
  function getBestImageUrl(img) {
    // Check srcset for larger version
    if (img.srcset) {
      const sources = img.srcset.split(',').map(s => {
        const parts = s.trim().split(/\s+/);
        const url = parts[0];
        const descriptor = parts[1] || '1x';
        const width = descriptor.endsWith('w') ? parseInt(descriptor) : 0;
        return { url, width };
      });

      // Sort by width descending and get largest
      sources.sort((a, b) => b.width - a.width);
      if (sources.length > 0 && sources[0].url) {
        return sources[0].url;
      }
    }

    // Check data-src for lazy-loaded images
    const dataSrc = img.dataset.src || img.dataset.lazySrc || img.dataset.originalSrc;
    if (dataSrc) {
      return dataSrc;
    }

    return img.src;
  }

  // Extract metadata from image context
  function getMetadata(img) {
    // Try to find title from various sources
    const title = img.alt ||
                  img.title ||
                  document.querySelector('h1')?.textContent?.trim() ||
                  document.title.split('|')[0].trim() ||
                  'untitled';

    // Try to find author/source
    const author = document.querySelector('meta[name="author"]')?.content ||
                   document.querySelector('[rel="author"]')?.textContent?.trim() ||
                   '';

    return { title, author };
  }

  function createDownloadButton(img) {
    const button = document.createElement('button');
    button.className = 'archiver-generic-btn';
    button.innerHTML = ICONS.dot;
    button.title = 'Download image';

    Object.assign(button.style, BUTTON_STYLES);

    createCaptureButton({
      button, target: img, runtime: browserAPI.runtime,
      key: () => getBestImageUrl(img), url: () => getBestImageUrl(img), reservations: downloadingImages,
      hintUrls: () => [window.location.href],
      getPieces: () => [{ element: img, kind: 'image', level: 0, included: true, scope: 'THIS PAGE' }],
      // Generic captures always keep the image; Option has no text-only meaning.
      mapMode: event => event.shiftKey ? 'quick' : 'full',
      modeLabels: { quick: '⇧ · image only' },
      render: (state, info) => {
        button.innerHTML = ICONS[state === 'saving' ? 'loading' : ['kept', 'already'].includes(state) ? 'success' : state === 'failed' ? 'error' : 'dot'];
        button.style.backgroundColor = state === 'failed' ? 'rgba(239, 68, 68, 0.9)' : ['kept', 'already'].includes(state) ? 'rgba(34, 197, 94, 0.9)' : BUTTON_STYLES.backgroundColor;
        button.style.borderColor = state === 'failed' ? 'rgba(239, 68, 68, 0.5)' : ['kept', 'already'].includes(state) ? 'rgba(34, 197, 94, 0.5)' : 'rgba(255, 255, 255, 0.3)';
        if (state !== 'idle') button.style.opacity = '1';
        button.title = info.error || (state === 'saving' ? 'Saving image' : state === 'kept' ? 'Archive completed' : state === 'already' ? 'Already archived' : 'Download image');
      },
      submit: (saveMode, event, captureAgain) => {
        const imageUrl = getBestImageUrl(img);
        const metadata = getMetadata(img);
        return NoDrawCapture.submit({
          kind: 'media', targetUrl: imageUrl, sourcePageUrl: window.location.href,
          media: { url: imageUrl, type: 'image', alt: img.alt || '' },
          page: { title: metadata.title, author: metadata.author },
          options: {
            saveMode, captureAgain, platform: 'web',
            siteData: { platform: 'web', title: metadata.title, author: metadata.author, description: '', pageUrl: window.location.href }
          }
        });
      }
    });

    return button;
  }

  function detachButtonEntry(entry) {
    if (!entry) return;

    entry.container.removeEventListener('mouseenter', entry.onMouseEnter);
    entry.container.removeEventListener('mouseleave', entry.onMouseLeave);
    entry.button._archiverCleanup?.();
    entry.button.remove();
    imageButtonEntries.delete(entry.img);
    activeButtonEntries.delete(entry);
  }

  function removeAllButtons() {
    Array.from(activeButtonEntries).forEach(detachButtonEntry);
    activeButtonEntries.clear();
    imageButtonEntries = new WeakMap();

    // Clean up any untracked buttons left by an older script instance or DOM move.
    document.querySelectorAll('.archiver-generic-btn').forEach(btn => btn.remove());
  }

  function processImage(img) {
    const existingEntry = imageButtonEntries.get(img);
    if (existingEntry?.button.isConnected) return;
    if (existingEntry) {
      detachButtonEntry(existingEntry);
    }

    // Check dimensions
    const rect = img.getBoundingClientRect();
    const width = img.naturalWidth || rect.width;
    const height = img.naturalHeight || rect.height;

    if (width < MIN_WIDTH || height < MIN_HEIGHT) return;

    // Skip tiny display sizes even if natural size is large
    if (rect.width < 100 || rect.height < 100) return;

    // Skip images in nav, footer, etc.
    if (img.closest('nav, header, footer, aside, .sidebar, .ad, [class*="advertisement"]')) return;

    // Skip images that are likely icons/logos
    if (img.src.includes('logo') || img.src.includes('icon') || img.src.includes('avatar')) return;

    // Find or create a suitable container
    let container = img.parentElement;
    if (!container) return;

    // If parent is an anchor, use the anchor as container
    if (container.tagName === 'A') {
      // Check parent of anchor
      const anchorParent = container.parentElement;
      if (anchorParent) {
        const anchorStyle = window.getComputedStyle(anchorParent);
        if (anchorStyle.position === 'static') {
          anchorParent.style.position = 'relative';
        }
        container = anchorParent;
      }
    } else {
      const computedStyle = window.getComputedStyle(container);
      if (computedStyle.position === 'static') {
        container.style.position = 'relative';
      }
    }

    const button = createDownloadButton(img);
    container.appendChild(button);

    // Show on hover
    const onMouseEnter = () => {
      button.style.opacity = '1';
      button.style.transform = 'scale(1.05)';
    };

    const onMouseLeave = () => {
      const itemId = getBestImageUrl(img);
      if (!downloadingImages.has(itemId)) {
        button.style.opacity = '0';
        button.style.transform = 'scale(1)';
      }
    };

    container.addEventListener('mouseenter', onMouseEnter);
    container.addEventListener('mouseleave', onMouseLeave);

    const entry = { img, button, container, onMouseEnter, onMouseLeave };
    imageButtonEntries.set(img, entry);
    activeButtonEntries.add(entry);
  }

  function scanImages() {
    if (!isEnabled) return;

    for (const entry of activeButtonEntries) {
      if (!entry.img.isConnected || !entry.button.isConnected) detachButtonEntry(entry);
    }
    const images = document.querySelectorAll('img');
    let processed = 0;

    images.forEach(img => {
      const before = imageButtonEntries.get(img)?.button;
      processImage(img);
      const after = imageButtonEntries.get(img)?.button;
      if (!before && after) processed++;
    });

    if (processed > 0) {
      // console.log(`[archiver-generic] Processed ${processed} new images`);
    }
  }

  function scheduleScan() {
    if (!isEnabled || scanScheduled) return;

    scanScheduled = true;
    requestAnimationFrame(() => {
      scanScheduled = false;
      scanImages();
    });
  }

  function handleImageLoad(event) {
    if (!isEnabled || event.target?.tagName !== 'IMG') return;
    processImage(event.target);
  }

  function startWatching() {
    const root = document.documentElement || document.body;
    if (!root) return;

    if (!observer) {
      observer = new MutationObserver(scheduleScan);
      observer.observe(root, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['src', 'srcset', 'sizes', 'data-src', 'data-lazy-src', 'data-original-src']
      });
    }

    document.addEventListener('load', handleImageLoad, true);
    window.addEventListener('scroll', handleScroll, { passive: true });
  }

  function stopWatching() {
    if (observer) {
      observer.disconnect();
      observer = null;
    }

    document.removeEventListener('load', handleImageLoad, true);
    window.removeEventListener('scroll', handleScroll);
    clearTimeout(scrollTimeout);
    scrollTimeout = null;
    scanScheduled = false;
  }

  function handleScroll() {
    clearTimeout(scrollTimeout);
    scrollTimeout = setTimeout(scanImages, 200);
  }

  function enableGenericDownloader() {
    isEnabled = true;
    addStyles();
    startWatching();
    scanImages();
  }

  function disableGenericDownloader() {
    isEnabled = false;
    stopWatching();
    removeAllButtons();
  }

  // Add styles
  function addStyles() {
    if (document.getElementById('archiver-generic-styles')) return;

    const style = document.createElement('style');
    style.id = 'archiver-generic-styles';
    style.textContent = `
      .archiver-generic-btn {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        -webkit-font-smoothing: antialiased;
        box-shadow: 0 2px 8px rgba(0,0,0,0.3);
        pointer-events: auto;
      }

      .archiver-generic-btn:hover {
        background-color: rgba(29, 155, 240, 0.95) !important;
        border-color: rgba(29, 155, 240, 0.5) !important;
      }

      .archiver-generic-btn svg {
        display: block;
      }

      .archiver-generic-spin {
        animation: archiver-generic-spin 1s linear infinite;
      }

      @keyframes archiver-generic-spin {
        from { transform: rotate(0deg); }
        to { transform: rotate(360deg); }
      }

      @media print {
        .archiver-generic-btn {
          display: none !important;
        }
      }
    `;
    document.head.appendChild(style);
  }

  // Listen for enable/disable messages from background
  browserAPI.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.action === 'genericDownloaderToggle') {
      isEnabled = message.enabled;
      // console.log(`[archiver-generic] ${CURRENT_HOST}: toggled to ${isEnabled ? 'enabled' : 'disabled'}`);

      if (isEnabled) {
        enableGenericDownloader();
      } else {
        disableGenericDownloader();
      }

      sendResponse({ success: true });
    }
    return true;
  });

  // Initialize
  async function init() {
    const enabled = await checkEnabled();

    if (enabled) {
      // console.log(`[archiver-generic] Initializing for ${CURRENT_HOST}`);
      enableGenericDownloader();
    }
  }

  // Cleanup on page unload
  window.addEventListener('beforeunload', () => {
    stopWatching();
    removeAllButtons();
  });

  // Wait for DOM ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
