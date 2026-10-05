import { createCaptureButton } from './modules/capture-button.js';

// Gallery sites content script (Flickr, DeviantArt, ArtStation, Pinterest)
// Uses GallerySiteConfigs module loaded from modules/gallery-site-configs.js

(function() {
  'use strict';

  const browserAPI = (typeof browser !== 'undefined') ? browser : chrome;

  // Use site configs module (loaded before this script)
  const currentSite = GallerySiteConfigs.detectSite();
  if (!currentSite) return;

  const config = GallerySiteConfigs.getConfig(currentSite);
  if (!config) {
    console.error('[archiver] No config for site:', currentSite);
    return;
  }
  // console.log(`[archiver] Gallery script active for: ${currentSite}`);

  // Button styles - rounded square with dot icon
  const BUTTON_STYLES = {
    position: 'absolute',
    right: '4px',
    top: '4px',
    width: '20px',
    height: '20px',
    minWidth: '20px',
    maxWidth: '20px',
    minHeight: '20px',
    maxHeight: '20px',
    padding: '0',
    margin: '0',
    borderRadius: '4px',
    backgroundColor: 'rgba(0, 0, 0, 0.6)',
    backdropFilter: 'blur(8px)',
    border: 'none',
    cursor: 'pointer',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    color: 'white',
    zIndex: '9999',
    transition: 'all 0.15s ease',
    opacity: '0.6',
    transform: 'scale(1)',
    boxSizing: 'border-box',
    lineHeight: '1'
  };

  // SVG icons - simple dot for default, small icons for states
  const ICONS = {
    dot: `<svg viewBox="0 0 24 24" width="8" height="8"><circle cx="12" cy="12" r="5" fill="currentColor"/></svg>`,
    success: `<svg viewBox="0 0 24 24" width="10" height="10" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 13l4 4L19 7"/></svg>`,
    error: `<svg viewBox="0 0 24 24" width="10" height="10" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M6 18L18 6M6 6l12 12"/></svg>`,
    loading: `<svg viewBox="0 0 24 24" width="10" height="10" fill="none" stroke="currentColor" stroke-width="2" class="archiver-spin"><circle cx="12" cy="12" r="9" stroke-dasharray="40 20"/></svg>`,
    tooSmall: `<svg viewBox="0 0 24 24" width="10" height="10" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 14l6-6m0 0v5m0-5H5"/><path d="M20 10l-6 6m0 0v-5m0 5h5"/></svg>`
  };

  // Check if error is about image being too small
  function isTooSmallError(error) {
    const msg = (error?.message || error || '').toLowerCase();
    return msg.includes('too small') || msg.includes('minimum');
  }

  // Resolution presets for sites with large/original images
  const FLICKR_PRESETS = {
    default: { maxWidth: 8000, label: '8K max', desc: 'original up to 8K' },
    full: { maxWidth: null, label: 'Original', desc: 'true original (can be huge)' }
  };

  const processedElements = new WeakSet();
  const downloadingItems = new Set();

  // Cache for fetched metadata (avoid re-fetching same page)
  const metadataCache = new Map();
  const MAX_CACHE_SIZE = 50;

  // LRU-style trim: delete oldest entry when cache exceeds max size
  function trimMetadataCache() {
    if (metadataCache.size > MAX_CACHE_SIZE) {
      const firstKey = metadataCache.keys().next().value;
      metadataCache.delete(firstKey);
    }
  }

  // Fetch rich metadata from single photo page (for Flickr gallery view)
  async function fetchFlickrPhotoMetadata(pageUrl) {
    if (metadataCache.has(pageUrl)) {
      return metadataCache.get(pageUrl);
    }

    try {
      // console.log('[archiver] Fetching metadata from:', pageUrl);
      const response = await fetch(pageUrl, { credentials: 'same-origin' });
      const html = await response.text();

      // Parse HTML
      const parser = new DOMParser();
      const doc = parser.parseFromString(html, 'text/html');

      // Extract metadata from the fetched page
      const title = doc.querySelector('.photo-title')?.textContent?.trim() ||
                    doc.querySelector('meta[property="og:title"]')?.content || '';
      const owner = doc.querySelector('.owner-name a')?.textContent?.trim() ||
                    doc.querySelector('.attribution a')?.textContent?.trim() || '';
      const desc = doc.querySelector('.photo-desc')?.textContent?.trim() ||
                   doc.querySelector('.sub-photo-view .description')?.textContent?.trim() || '';

      // Try to get tags
      const tags = Array.from(doc.querySelectorAll('.tags-list a.tag'))
                        .map(t => t.textContent?.trim())
                        .filter(Boolean)
                        .slice(0, 10); // Limit to 10 tags

      // Get date if available
      const dateTaken = doc.querySelector('.date-taken-label')?.textContent?.trim() || '';

      const metadata = { title, artist: owner, description: desc, tags, dateTaken };
      metadataCache.set(pageUrl, metadata);
      trimMetadataCache();
      // console.log('[archiver] Fetched metadata:', metadata);
      return metadata;
    } catch (error) {
      console.error('[archiver] Failed to fetch photo metadata:', error);
      return null;
    }
  }

  // console.log('[archiver] content-gallery.js loaded, hostname:', window.location.hostname);

  function generateItemId(pageUrl, imageUrl) {
    return `${currentSite}-${(pageUrl || imageUrl || '').slice(-20)}`;
  }

  function renderGalleryButton(button, state, info) {
    const failedSmall = state === 'failed' && isTooSmallError(info.error);
    button.innerHTML = ICONS[state === 'saving' ? 'loading' : ['kept', 'already'].includes(state) ? 'success' : failedSmall ? 'tooSmall' : state === 'failed' ? 'error' : 'dot'];
    button.classList.toggle('archiver-loading', state === 'saving');
    button.style.backgroundColor = failedSmall ? 'rgba(251, 191, 36, 0.9)' : state === 'failed' ? 'rgba(239, 68, 68, 0.9)' : ['kept', 'already'].includes(state) ? 'rgba(34, 197, 94, 0.9)' : BUTTON_STYLES.backgroundColor;
    if (state !== 'idle') button.style.opacity = '1';
    if (state === 'failed') button.title = info.error;
    else if (state === 'saving') button.title = 'Saving image';
    else if (state === 'kept') button.title = 'Archive completed';
    else if (state === 'already') button.title = 'Already archived';
    else button.title = button.dataset.idleTitle;
  }

  function createArchiveButton(element) {
    const pageUrl = config.getPageUrl(element);
    const metadata = config.getMetadata(element);
    // Get initial imageUrl for itemId (may be updated at click time for Flickr)
    const initialImageUrl = config.getImageUrl(element);
    const itemId = generateItemId(pageUrl, initialImageUrl);

    const button = document.createElement('button');
    button.className = 'media-archiver-gallery-btn';
    button.setAttribute('aria-label', 'Archive image');
    button.innerHTML = ICONS.dot;

    // Site-specific button title
    if (currentSite === 'flickr') {
      button.title = 'Click: 8K max | ⌥: Original';
    } else {
      button.title = 'Click: full | ⇧: quick';
    }

    button.dataset.idleTitle = button.title;
    Object.assign(button.style, BUTTON_STYLES);

    createCaptureButton({
      button, target: element.matches('img') ? element : element.querySelector('img') || element,
      runtime: browserAPI.runtime, key: itemId, url: (mode, event = {}) => config.getImageUrl(element, currentSite === 'flickr' && !(event.altKey || event.metaKey) ? FLICKR_PRESETS.default.maxWidth : null),
      reservations: downloadingItems,
      hintUrls: () => [pageUrl || window.location.href],
      mapMode: event => event.shiftKey ? 'quick' : 'full',
      modeLabels: { quick: '⇧ · image only' },
      beforeSubmit: (mode, event) => currentSite !== 'flickr' || !(event.altKey || event.metaKey)
        || confirm('Download FULL original resolution?\n\nSome Flickr originals can be very large.\n\nContinue?'),
      getPieces: () => [{ element: element.matches('img') ? element : element.querySelector('img') || element, kind: 'image', level: 0, included: true, scope: 'THIS PAGE' }],
      render: (state, info) => renderGalleryButton(button, state, info),
      submit: async (saveMode, event, captureAgain) => {
        let maxWidth = null;
        let resolutionOptions = {};
        if (currentSite === 'flickr') {
          if (event.altKey || event.metaKey) {
            maxWidth = FLICKR_PRESETS.full.maxWidth;
          } else maxWidth = FLICKR_PRESETS.default.maxWidth;
          resolutionOptions = { max_width: maxWidth };
        }
        const imageUrl = config.getImageUrl(element, maxWidth);
        let richMetadata = metadata;
        if (currentSite === 'flickr' && pageUrl && !isSinglePhotoPage()) {
          richMetadata = await fetchFlickrPhotoMetadata(pageUrl) || metadata;
        }
        const siteData = {
          platform: currentSite, title: richMetadata.title, author: richMetadata.artist,
          description: richMetadata.description, tags: richMetadata.tags || [],
          dateTaken: richMetadata.dateTaken || '', pageUrl: pageUrl || window.location.href
        };
        return NoDrawCapture.submit({
          kind: 'media', targetUrl: imageUrl, sourcePageUrl: pageUrl || window.location.href,
          media: { url: imageUrl, type: 'image', alt: richMetadata.description || '' },
          page: { title: richMetadata.title, author: richMetadata.artist, description: richMetadata.description, publishedAt: richMetadata.dateTaken || '' },
          user: { tags: richMetadata.tags || [] },
          options: { saveMode, captureAgain, platform: currentSite, download: resolutionOptions, siteData }
        });
      }
    });

    return button;
  }

  function processElement(element) {
    if (processedElements.has(element)) return;

    const imageUrl = config.getImageUrl(element);
    if (!imageUrl) {
      // console.log('[archiver] No imageUrl for element:', element.className?.slice(0, 30));
      return;
    }
    // console.log('[archiver] Processing element with url:', imageUrl.slice(0, 60));

    // Skip if element is too large (probably a page wrapper, not an item)
    const rect = element.getBoundingClientRect();
    if (rect.width > window.innerWidth * 0.95 && rect.height > window.innerHeight * 0.9) {
      // console.log(`[archiver] Skipping oversized element: ${Math.round(rect.width)}x${Math.round(rect.height)} (viewport: ${window.innerWidth}x${window.innerHeight})`);
      // Mark as processed so we don't keep trying
      processedElements.add(element);
      return;
    }

    // Ensure element has relative/absolute positioning for button placement
    const computedStyle = window.getComputedStyle(element);
    if (computedStyle.position === 'static') {
      element.style.position = 'relative';
    }

    const archiveBtn = createArchiveButton(element);
    element.appendChild(archiveBtn);

    // Debug: check button placement
    const btnRect = archiveBtn.getBoundingClientRect();
    const elRect = element.getBoundingClientRect();
    const btnStyles = window.getComputedStyle(archiveBtn);
    // console.log(`[archiver] Button appended to: ${element.tagName}.${element.className?.slice(0,30)}`);
    // console.log(`[archiver] Element rect: ${Math.round(elRect.width)}x${Math.round(elRect.height)} at (${Math.round(elRect.left)},${Math.round(elRect.top)})`);
    // console.log(`[archiver] Button rect: ${Math.round(btnRect.width)}x${Math.round(btnRect.height)} at (${Math.round(btnRect.left)},${Math.round(btnRect.top)})`);
    // console.log(`[archiver] Button visibility: opacity=${btnStyles.opacity}, display=${btnStyles.display}, position=${btnStyles.position}`);
    // console.log(`[archiver] Element overflow: ${window.getComputedStyle(element).overflow}`);

    // Hover: scale up
    element.addEventListener('mouseenter', () => {
      archiveBtn.style.opacity = '1';
      archiveBtn.style.transform = 'scale(1.1)';
    });

    element.addEventListener('mouseleave', () => {
      const itemId = generateItemId(config.getPageUrl(element), config.getImageUrl(element));
      if (!downloadingItems.has(itemId)) {
        archiveBtn.style.opacity = '0.6';
        archiveBtn.style.transform = 'scale(1)';
      }
    });

    processedElements.add(element);
  }

  // Check if we're on a single photo page (not gallery/photostream)
  function isSinglePhotoPage() {
    if (currentSite === 'flickr') {
      // Flickr single photo: /photos/{user}/{id}/ (not /photos/{user}/ which is photostream)
      const match = window.location.pathname.match(/^\/photos\/[^/]+\/(\d+)/);
      return !!match;
    }
    return false;
  }

  function processAllElements() {
    // For single photo pages, skip gallery selectors and go straight to single photo logic
    if (isSinglePhotoPage()) {
      // console.log('[archiver] Single photo page detected, using direct approach');
      const buttonsAdded = document.querySelectorAll('.media-archiver-gallery-btn').length;
      if (buttonsAdded === 0) {
        processSinglePhotoPage();
      }
      return;
    }

    const elements = document.querySelectorAll(config.itemSelector);
    // console.log(`[archiver] Found ${elements.length} items with selector: ${config.itemSelector.slice(0,50)}...`);

    elements.forEach(processElement);

    const buttonsAdded = document.querySelectorAll('.media-archiver-gallery-btn').length;
    // console.log(`[archiver] Buttons in DOM: ${buttonsAdded}`);

    // Google Arts: always run to catch new thumbnails on scroll
    if (currentSite === 'googlearts') {
      processGoogleArtsGallery();
      return;
    }

    // Fallback for pages where selectors didn't work
    if (buttonsAdded === 0) {
      // console.log('[archiver] No buttons added, trying single photo fallback');
      processSinglePhotoPage();
    }
  }

  // Separate function for Google Arts gallery - runs on every scan
  function processGoogleArtsGallery() {
    // Asset page: fixed button
    if (window.location.pathname.includes('/asset/')) {
      if (!document.querySelector('.archiver-floating-btn')) {
        // console.log('[archiver] Google Arts: adding fixed button for asset page');
        const btn = createGoogleArtsButton(window.location.href, document.querySelector('img, canvas') || document.body);
        Object.assign(btn.style, {
          position: 'fixed',
          top: '70px',
          right: '16px',
          width: '36px',
          height: '36px',
          opacity: '0.7',
          transform: 'scale(1)',
          zIndex: '999999'
        });
        document.body.appendChild(btn);
        btn.addEventListener('mouseenter', () => { btn.style.opacity = '1'; btn.style.transform = 'scale(1.1)'; });
        btn.addEventListener('mouseleave', () => { if (!btn.classList.contains('archiver-loading')) { btn.style.opacity = '0.7'; btn.style.transform = 'scale(1)'; }});
      }
    }

    // Gallery pages: scan for ALL asset links (not just unprocessed)
    const thumbnails = document.querySelectorAll('a[href*="/asset/"]');
    let newCount = 0;

    thumbnails.forEach(link => {
      if (link.dataset.archiverProcessed) return;
      link.dataset.archiverProcessed = 'true';

      const container = link.closest('[class*="card"]') || link.closest('[class*="item"]') || link;
      if (!container || container.querySelector('.archiver-thumb-btn')) return;

      const containerStyle = window.getComputedStyle(container);
      if (containerStyle.position === 'static') {
        container.style.position = 'relative';
      }

      const btn = createGoogleArtsButton(link.href, link.querySelector('img') || link);
      btn.className += ' archiver-thumb-btn';
      Object.assign(btn.style, {
        position: 'absolute',
        top: '4px',
        right: '4px',
        width: '24px',
        height: '24px',
        opacity: '0.6',  // Visible by default, not hidden
        transform: 'scale(1)'
      });
      btn.querySelector('svg')?.setAttribute('width', '12');
      btn.querySelector('svg')?.setAttribute('height', '12');

      container.appendChild(btn);
      newCount++;

      container.addEventListener('mouseenter', () => { btn.style.opacity = '1'; btn.style.transform = 'scale(1.1)'; });
      container.addEventListener('mouseleave', () => { if (!btn.classList.contains('archiver-loading')) { btn.style.opacity = '0.6'; btn.style.transform = 'scale(1)'; }});
    });

    if (newCount > 0) {
      // console.log(`[archiver] Google Arts: added ${newCount} new gallery buttons`);
    }
  }

  // Resolution presets for Google Arts downloads
  // Full res can be 40,000+ pixels (500MB+), so default to something reasonable
  const RESOLUTION_PRESETS = {
    default: { maxWidth: 4000, label: '4K', desc: '~5-15MB' },
    large: { maxWidth: 8000, label: '8K', desc: '~20-60MB' },
    full: { maxWidth: null, label: 'Full', desc: 'can be 100MB+' }
  };

  // Helper for Google Arts buttons (module-level so both functions can use it)
  function createGoogleArtsButton(assetUrl, target) {
    const btn = document.createElement('button');
    btn.className = 'media-archiver-gallery-btn archiver-floating-btn';
    btn.innerHTML = ICONS.dot;
    btn.title = 'Click: 4K | ⇧: 8K | ⌥: Full res (large!)';
    btn.dataset.idleTitle = btn.title;
    Object.assign(btn.style, BUTTON_STYLES);

    // Extract assetId and title-slug from the URL (works for both gallery thumbnails and asset pages)
    // URL pattern: /asset/{title-slug}/{ASSET_ID} or /u/N/asset/{title-slug}/{ASSET_ID}
    let assetId = '';
    let titleFromUrl = '';
    try {
      const urlPath = new URL(assetUrl).pathname;
      const assetMatch = urlPath.match(/\/asset\/([^/]+)\/([^/]+)/);
      if (assetMatch) {
        // title-slug is hyphenated, convert to readable: "the-starry-night" -> "The Starry Night"
        titleFromUrl = assetMatch[1]
          .split('-')
          .map(word => word.charAt(0).toUpperCase() + word.slice(1))
          .join(' ');
        assetId = assetMatch[2];
        // console.log(`[archiver] Google Arts: extracted from URL - title: "${titleFromUrl}", assetId: ${assetId}`);
      }
    } catch (e) {
      // console.warn('[archiver] Google Arts: could not parse assetUrl:', assetUrl);
    }

    createCaptureButton({
      button: btn, target, runtime: browserAPI.runtime, key: assetUrl, url: assetUrl, reservations: downloadingItems,
      hintUrls: () => [window.location.href],
      mapMode: event => event.altKey || event.metaKey ? 'original' : event.shiftKey ? 'large' : 'full',
      modeLabels: { large: '⇧ · 8K', original: '⌥ · full size' },
      beforeSubmit: mode => mode !== 'original'
        || confirm('Download FULL resolution?\n\nGoogle Arts images can be 40,000+ pixels and 100-500MB.\nThis may take several minutes.\n\nContinue?'),
      getPieces: () => [{ element: target, kind: 'image', level: 0, included: true, scope: 'THIS PAGE' }],
      render: (state, info) => renderGalleryButton(btn, state, info),
      submit: (mode, event, captureAgain) => {
        const preset = mode === 'original' ? RESOLUTION_PRESETS.full : mode === 'large' ? RESOLUTION_PRESETS.large : RESOLUTION_PRESETS.default;
        const metadata = config.getMetadata(document.body);
        const isOnAssetPage = window.location.pathname.includes('/asset/');
        const title = isOnAssetPage ? (metadata.title || titleFromUrl) : (titleFromUrl || metadata.title);
        const siteData = {
          platform: 'googlearts', title, author: metadata.artist, description: metadata.description,
          pageUrl: assetUrl, assetId: assetId || metadata.assetId || ''
        };
        return NoDrawCapture.submit({
          kind: 'media', targetUrl: assetUrl, sourcePageUrl: assetUrl,
          media: { url: assetUrl, type: 'image', alt: metadata.description || '' },
          page: { title, author: metadata.artist, description: metadata.description },
          options: { saveMode: 'full', captureAgain, platform: 'googlearts', download: { max_width: preset.maxWidth }, siteData }
        });
      }
    });

    return btn;
  }

  // Handle single photo pages where there's no "item" wrapper
  function processSinglePhotoPage() {
    // For Flickr, try specific selectors first
    if (currentSite === 'flickr') {
      const flickrSelectors = [
        '.photo-well-media-scrappy-view img.main-photo',
        '.photo-well-media-scrappy-view img',
        '.photo-page-scrappy-view img.main-photo',
        '.main-photo',
        'img.main-photo'
      ];

      for (const selector of flickrSelectors) {
        const mainPhoto = document.querySelector(selector);
        if (mainPhoto && !processedElements.has(mainPhoto)) {
          // console.log(`[archiver] Flickr: found main photo with selector: ${selector}`);
          addButtonToImage(mainPhoto);
          return;
        }
      }
      // console.log('[archiver] Flickr: no main photo found with specific selectors');
    }

    // Generic fallback: Look for large images on the page
    const largeImages = document.querySelectorAll('img');
    // console.log(`[archiver] Single photo fallback: found ${largeImages.length} images`);

    for (const img of largeImages) {
      if (processedElements.has(img)) continue;

      const rect = img.getBoundingClientRect();
      // console.log(`[archiver] Checking img: ${img.src?.slice(0,50)}... natural=${img.naturalWidth}x${img.naturalHeight} display=${Math.round(rect.width)}x${Math.round(rect.height)}`);

      // Use display size if natural size not loaded yet
      const width = img.naturalWidth || rect.width;
      const height = img.naturalHeight || rect.height;

      if (width < 400 || height < 400) continue;
      if (img.closest('nav, header, footer, .sidebar, .comments')) continue;
      if (rect.width < 300 || rect.height < 300) continue;

      addButtonToImage(img);
      break; // Only add to the first/main large image
    }
  }

  // Helper to add button to a single image
  function addButtonToImage(img) {
    if (processedElements.has(img)) return;

    // Find the best container - prefer direct parent, but check if it's suitable
    let wrapper = img.parentElement;
    if (!wrapper) {
      // console.log('[archiver] No parent wrapper for image');
      return;
    }

    // If the immediate parent is too large or a generic container, create our own wrapper
    const imgRect = img.getBoundingClientRect();
    const wrapperRect = wrapper.getBoundingClientRect();

    const computedStyle = window.getComputedStyle(wrapper);
    const hasOverflowHidden = computedStyle.overflow === 'hidden' ||
                               computedStyle.overflowX === 'hidden' ||
                               computedStyle.overflowY === 'hidden';

    // If wrapper is much larger than image OR has overflow:hidden, wrap the image ourselves
    if (wrapperRect.width > imgRect.width * 1.5 || wrapperRect.height > imgRect.height * 1.5 || hasOverflowHidden) {
      // console.log(`[archiver] Creating custom wrapper (overflow: ${computedStyle.overflow}, size ratio: ${(wrapperRect.width / imgRect.width).toFixed(1)})`);
      const customWrapper = document.createElement('div');
      customWrapper.className = 'archiver-img-wrapper';
      customWrapper.style.cssText = 'position: relative; display: inline-block;';
      // Defensive check: ensure img is still a child of its parent before manipulating
      const parent = img.parentElement;
      if (parent && parent.contains(img)) {
        try {
          parent.insertBefore(customWrapper, img);
          customWrapper.appendChild(img);
          wrapper = customWrapper;
        } catch (e) {
          // console.warn('[archiver] DOM manipulation failed, using parent as wrapper:', e.message);
          // Fall through to use existing wrapper
        }
      }
    } else {
      if (computedStyle.position === 'static') {
        wrapper.style.position = 'relative';
      }
    }

    const archiveBtn = createArchiveButton(img);
    wrapper.appendChild(archiveBtn);

    // Debug positioning
    const btnRect = archiveBtn.getBoundingClientRect();
    const finalWrapperRect = wrapper.getBoundingClientRect();
    // console.log(`[archiver] Single photo button appended to: ${wrapper.tagName}.${wrapper.className?.slice(0,30)}`);
    // console.log(`[archiver] Wrapper rect: ${Math.round(finalWrapperRect.width)}x${Math.round(finalWrapperRect.height)} at (${Math.round(finalWrapperRect.left)},${Math.round(finalWrapperRect.top)})`);
    // console.log(`[archiver] Button rect: ${Math.round(btnRect.width)}x${Math.round(btnRect.height)} at (${Math.round(btnRect.left)},${Math.round(btnRect.top)})`);
    // console.log(`[archiver] Wrapper overflow: ${window.getComputedStyle(wrapper).overflow}`);

    // Hover: scale up
    wrapper.addEventListener('mouseenter', () => {
      archiveBtn.style.opacity = '1';
      archiveBtn.style.transform = 'scale(1.1)';
    });

    wrapper.addEventListener('mouseleave', () => {
      const itemId = generateItemId(window.location.href, img.src);
      if (!downloadingItems.has(itemId)) {
        archiveBtn.style.opacity = '0.6';
        archiveBtn.style.transform = 'scale(1)';
      }
    });

    processedElements.add(img);
    // console.log('[archiver] Added button to image:', img.src?.slice(0, 60));
  }

  // Debounce processAllElements to avoid hammering CPU on rapid DOM changes
  let processAllTimeout = null;
  function debouncedProcessAll() {
    if (processAllTimeout) return; // Already scheduled
    processAllTimeout = requestAnimationFrame(() => {
      processAllTimeout = null;
      processAllElements();
    });
  }

  function cleanupButtons(node) {
    if (!(node instanceof Element) || node.isConnected) return;
    if (node.matches('.media-archiver-gallery-btn')) node._archiverCleanup?.();
    node.querySelectorAll('.media-archiver-gallery-btn').forEach(button => button._archiverCleanup?.());
  }

  const observer = new MutationObserver(mutations => {
    mutations.forEach(mutation => mutation.removedNodes.forEach(cleanupButtons));
    debouncedProcessAll();
  });

  // Debounced scroll handler for lazy-loaded/virtualized content
  let scrollTimeout;
  let scrollListenerInterval;
  function handleScroll() {
    clearTimeout(scrollTimeout);
    scrollTimeout = setTimeout(() => {
      processAllElements();
    }, 150);
  }

  // Find and attach scroll listeners to scrollable containers
  function attachScrollListeners() {
    // Find all potentially scrollable elements
    const scrollables = document.querySelectorAll('[style*="overflow"], [class*="scroll"], [class*="Scroll"], [class*="gallery"], [class*="Gallery"], [class*="grid"], [class*="Grid"]');
    scrollables.forEach(el => {
      if (!el.dataset.archiverScrollListener) {
        el.dataset.archiverScrollListener = 'true';
        el.addEventListener('scroll', handleScroll, { passive: true });
        // console.log('[archiver] Added scroll listener to:', el.className?.slice(0, 40));
      }
    });
  }

  // Cleanup on page unload
  window.addEventListener('beforeunload', () => {
    observer.disconnect();
    document.querySelectorAll('.media-archiver-gallery-btn').forEach(button => button._archiverCleanup?.());
    clearTimeout(scrollTimeout);
    clearInterval(scrollListenerInterval);
  });

  function initialize() {
    // console.log('[archiver] Initializing...');
    const container = document.querySelector(config.containerSelector) || document.body;
    // console.log('[archiver] Container:', container?.tagName, container?.className?.slice(0,30));
    observer.observe(container, {
      childList: true,
      subtree: true
    });

    // Listen for scroll on window and document
    window.addEventListener('scroll', handleScroll, { passive: true });
    document.addEventListener('scroll', handleScroll, { passive: true, capture: true });

    // Attach to scrollable containers
    attachScrollListeners();
    // Re-attach periodically in case new containers appear
    scrollListenerInterval = setInterval(attachScrollListeners, 2000);

    processAllElements();
  }

  // Add styles
  const style = document.createElement('style');
  style.textContent = `
    .media-archiver-gallery-btn {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      -webkit-font-smoothing: antialiased;
      box-shadow: 0 1px 3px rgba(0,0,0,0.3);
      pointer-events: auto;
      color: white;
    }

    .media-archiver-gallery-btn:hover {
      background-color: rgba(29, 155, 240, 0.95) !important;
    }

    .media-archiver-gallery-btn svg {
      display: block;
    }

    /* Spin animation for loading */
    .archiver-spin {
      animation: archiver-spin 1s linear infinite;
    }

    @keyframes archiver-spin {
      from { transform: rotate(0deg); }
      to { transform: rotate(360deg); }
    }


    @media print {
      .media-archiver-gallery-btn, .archiver-tooltip {
        display: none !important;
      }
    }
  `;
  document.head.appendChild(style);

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initialize);
  } else {
    initialize();
  }

})();
