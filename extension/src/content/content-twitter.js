// Twitter/X specific content script with minimally invasive UI

import { extractTweetContent, getCapturePieces, getSaveModeFromEvent, mergeTweetData } from './twitter-media.js';
import { showCapturePlan, hideCapturePlan, watchModifiers } from './ui/capture-plan.js';
import { createCaptureAdmission } from './capture-admission.js';
import { postTitle } from './modules/post-title.js';
import { withArchiverUIHidden } from './modules/capture-hide.js';

(function() {
  'use strict';

  // Firefox compatibility - content scripts have browser/chrome as globals
  const browserAPI = (typeof browser !== 'undefined') ? browser : chrome;

  // Icon paths only - size is applied dynamically
  // NOTE: X's native icons use fill, not stroke. Our stroke-based approach
  // needs stroke-width 2 to have similar visual weight.
  const ICON_PATHS = {
    download: 'M12 3v12m0 0l-4-4m4 4l4-4M5 17v2a2 2 0 002 2h10a2 2 0 002-2v-2',
    quick: 'M12 4v12m0 0l-4-4m4 4l4-4',
    text: 'M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 012-2h2a2 2 0 012 2M9 5h6',
    loading: null, // special case
    success: 'M5 13l4 4L19 7',
    error: 'M6 18L18 6M6 6l12 12',
    archived: 'M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z', // checkmark in circle
    tooSmall: 'M4 14l6-6m0 0v5m0-5H5M20 10l-6 6m0 0v-5m0 5h5' // shrink arrows
  };

  // Check if error is about content being too small
  function isTooSmallError(error) {
    const msg = (error?.message || error || '').toLowerCase();
    return msg.includes('too small') || msg.includes('minimum');
  }

  function getActionableStatus(error, fallbackMessage = '') {
    const rawMessage = String(error?.message || error || fallbackMessage || 'Archive failed').trim();
    const message = rawMessage.toLowerCase();

    if (message.includes('durable inbox') || message.includes('quota_bytes')) {
      return {
        tone: 'error',
        shortLabel: 'Capture not queued',
        detail: `${rawMessage}. Free browser extension storage and retry, or deliberately use Quick mode without screenshot context.`,
        resetDelay: 10000
      };
    }

    if (message.includes('queued for retry') || message.includes('server offline')) {
      return {
        tone: 'queued',
        shortLabel: 'Queued for retry',
        detail: 'The local archive server is offline. Start it, then the extension will retry automatically.',
        resetDelay: 7000
      };
    }

    if (isTooSmallError(rawMessage)) {
      return {
        tone: 'warning',
        shortLabel: 'Media too small',
        detail: 'X likely served a placeholder or thumbnail. Open the tweet or media at full size and try again.',
        resetDelay: 7000
      };
    }

    if (message.includes('capture') || message.includes('screenshot')) {
      return {
        tone: 'error',
        shortLabel: 'Screenshot failed',
        detail: 'Keep the tweet visible on screen and try again. If it keeps failing, use Quick mode to save without a screenshot.',
        resetDelay: 8000
      };
    }

    return {
      tone: 'error',
      shortLabel: 'Archive failed',
      detail: `${rawMessage}. Try again, or check that the local archive server is running.`,
      resetDelay: 8000
    };
  }

  // X icon style reference (Nov 2024):
  // - Size: dynamically read from X's SVG (typically 18.75-20px)
  // - X's native icons use fill="currentColor", ours use stroke
  // - Stroke: 2 gives similar visual weight to X's filled icons
  const X_STROKE_WIDTH = 2;

  // Generate icon SVG with dynamic size
  function getIcon(type, size = 20) {
    if (type === 'loading') {
      return `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="${X_STROKE_WIDTH}" class="archiver-spin"><circle cx="12" cy="12" r="9" stroke-dasharray="40 20"/></svg>`;
    }
    return `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="${X_STROKE_WIDTH}" stroke-linecap="round" stroke-linejoin="round"><path d="${ICON_PATHS[type]}"/></svg>`;
  }

  // Clone X's native button wrapper for perfect styling match
  function cloneXButtonWrapper(actionBar) {
    // Find any existing button wrapper in the action bar (like bookmark or share)
    // X's structure: div[role="group"] > div (button wrapper) > button > div > svg
    const existingWrapper = actionBar.querySelector(':scope > div:last-child');
    if (existingWrapper) {
      const clone = existingWrapper.cloneNode(true);
      // Clear the clone's inner content
      clone.innerHTML = '';
      // Remove any data attributes that might cause issues
      clone.removeAttribute('data-testid');
      return clone;
    }
    return null;
  }

  // Copy computed styles from a reference element
  function copyStyles(source, target, properties) {
    const computed = window.getComputedStyle(source);
    properties.forEach(prop => {
      target.style[prop] = computed[prop];
    });
  }

  // Track processed posts - map to track mode ('timeline' or 'portal')
  const processedPosts = new WeakMap();
  let activeCapturePreview = null;

  function clearDetachedCapturePlan() {
    if (activeCapturePreview && (!activeCapturePreview.button.isConnected || !activeCapturePreview.article.isConnected)) {
      activeCapturePreview.clear();
    }
  }
  const downloadingPosts = createCaptureAdmission();
  const pendingArchiveJobs = new Map();
  const pendingArchiveUrls = new Map();
  const QUEUED_STATUS_TTL_MS = 10 * 60 * 1000 + 30000;
  // Track archive status for tweets (tweetId -> {archived, age_days, file_exists})
  const archiveStatusCache = new Map();

  browserAPI.runtime.onMessage.addListener((request) => {
    if (request?.action !== 'archiveJobStatus') return;
    const handler = pendingArchiveJobs.get(request.jobId) || pendingArchiveUrls.get(request.url);
    if (handler) handler(request);
  });

  // Check if a URL has been archived
  async function checkArchiveStatus(url, tweetId) {
    // Check cache first
    if (archiveStatusCache.has(tweetId)) {
      return archiveStatusCache.get(tweetId);
    }

    try {
      const response = await browserAPI.runtime.sendMessage({
        action: 'checkArchived',
        url: url
      });

      const status = {
        archived: response?.archived || false,
        age_days: response?.age_days || 0,
        file_exists: response?.file_exists || false,
        file_path: response?.file_path || null
      };

      archiveStatusCache.set(tweetId, status);
      return status;
    } catch (e) {
      // console.log('[archiver] Could not check archive status:', e);
      return { archived: false };
    }
  }

  // Show re-archive prompt dialog
  function showReArchivePrompt(tweetData, archiveStatus) {
    return new Promise((resolve) => {
      // Create modal overlay
      const overlay = document.createElement('div');
      overlay.className = 'archiver-modal-overlay';
      overlay.style.cssText = `
        position: fixed;
        top: 0;
        left: 0;
        right: 0;
        bottom: 0;
        background: rgba(0, 0, 0, 0.6);
        backdrop-filter: blur(4px);
        z-index: 2147483647;
        display: flex;
        align-items: center;
        justify-content: center;
      `;

      const ageStr = archiveStatus.age_days === 0 ? 'today' :
                     archiveStatus.age_days === 1 ? 'yesterday' :
                     `${archiveStatus.age_days} days ago`;

      const modal = document.createElement('div');
      modal.className = 'archiver-modal';
      modal.style.cssText = `
        background: rgb(22, 24, 28);
        border-radius: 16px;
        padding: 24px;
        max-width: 320px;
        color: white;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        box-shadow: 0 8px 32px rgba(0,0,0,0.4);
      `;

      modal.innerHTML = `
        <div style="font-size: 16px; font-weight: 600; margin-bottom: 8px;">Already Archived</div>
        <div style="font-size: 14px; color: rgb(139, 148, 158); margin-bottom: 16px;">
          This tweet was archived ${ageStr}.
          ${archiveStatus.file_exists ? '✓ File exists on disk.' : '⚠ File may have been moved.'}
        </div>
        <div style="display: flex; flex-direction: column; gap: 8px;">
          <button class="archiver-modal-btn" data-action="redownload" style="
            background: rgb(29, 155, 240);
            color: white;
            border: none;
            padding: 12px 16px;
            border-radius: 9999px;
            font-size: 14px;
            font-weight: 600;
            cursor: pointer;
          ">Re-download fresh copy</button>
          <button class="archiver-modal-btn" data-action="cancel" style="
            background: transparent;
            color: rgb(139, 148, 158);
            border: 1px solid rgb(56, 68, 77);
            padding: 12px 16px;
            border-radius: 9999px;
            font-size: 14px;
            font-weight: 600;
            cursor: pointer;
          ">Cancel</button>
        </div>
      `;

      overlay.appendChild(modal);
      document.body.appendChild(overlay);

      // Handle clicks
      modal.querySelectorAll('.archiver-modal-btn').forEach(btn => {
        btn.addEventListener('click', () => {
          const action = btn.dataset.action;
          overlay.remove();
          resolve(action === 'redownload');
        });
      });

      // Click outside to cancel
      overlay.addEventListener('click', (e) => {
        if (e.target === overlay) {
          overlay.remove();
          resolve(false);
        }
      });

      // ESC to cancel
      const handleEsc = (e) => {
        if (e.key === 'Escape') {
          overlay.remove();
          document.removeEventListener('keydown', handleEsc);
          resolve(false);
        }
      };
      document.addEventListener('keydown', handleEsc);
    });
  }

  // Save mode config
  const SAVE_MODES = {
    full: { icon: 'download', label: 'Full save', desc: 'media + screenshot' },
    quick: { icon: 'quick', label: 'Quick', desc: 'media only' },
    text: { icon: 'text', label: 'Text', desc: 'screenshot + post text' },
    quoted: { icon: 'download', label: 'With quoted posts', desc: 'media at every quote level' }
  };

  // Create hover menu HTML (uses smaller 16px icons for menu)
  function createHoverMenu() {
    const menu = document.createElement('div');
    menu.className = 'archiver-menu';
    menu.innerHTML = `
      <div class="archiver-menu-item active" data-mode="full">
        ${getIcon('download', 16)} Full save <kbd>click</kbd>
      </div>
      <div class="archiver-menu-item" data-mode="quick">
        ${getIcon('quick', 16)} Quick <kbd>⇧</kbd>
      </div>
      <div class="archiver-menu-item" data-mode="text">
        ${getIcon('text', 16)} Text only <kbd>⌥</kbd>
      </div>
      <div class="archiver-menu-item" data-mode="quoted">
        ${getIcon('download', 16)} With quoted posts <kbd>⌥⇧</kbd>
      </div>
    `;
    return menu;
  }

  // Capture element screenshot via background script
  async function captureElement(element) {
    const rect = element.getBoundingClientRect();
    const scrollX = window.scrollX;
    const scrollY = window.scrollY;

    // Get device pixel ratio for high-DPI displays
    const dpr = window.devicePixelRatio || 1;

    const bounds = {
      x: Math.round((rect.x + scrollX) * dpr),
      y: Math.round(rect.y * dpr),  // y relative to viewport for captureVisibleTab
      width: Math.round(rect.width * dpr),
      height: Math.round(rect.height * dpr),
      viewportY: Math.round(rect.y),  // original viewport-relative y
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

  // Create archive button by cloning X's native button structure
  function createArchiveButton(initialTweetData, article, actionBar) {
    let latestTweetData = initialTweetData;

    function getTweetData(refresh = false) {
      if (refresh) {
        latestTweetData = mergeTweetData(latestTweetData, extractTweetContent(article));
      }
      return latestTweetData;
    }

    function getTweetKey(data = latestTweetData) {
      return data?.tweetId || data?.tweetUrl || initialTweetData.tweetId || initialTweetData.tweetUrl || '';
    }

    // Find X's native SVG to match its exact size
    const refSvg = actionBar.querySelector('svg');
    let iconSize = 20; // default fallback
    if (refSvg) {
      const rect = refSvg.getBoundingClientRect();
      iconSize = Math.max(rect.width, rect.height) || 20;
    }

    const refButton = actionBar.querySelector(':scope > div button');

    const button = document.createElement('button');
    button.className = 'media-archiver-twitter-btn';
    button.setAttribute('aria-label', 'Archive tweet');
    button.dataset.iconSize = iconSize; // store for later icon swaps
    button.title = '';
    button.type = 'button';

    // Copy styles from X's native button if available
    if (refButton) {
      const computed = window.getComputedStyle(refButton);
      button.style.cssText = `
        background: transparent;
        border: none;
        cursor: pointer;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: ${computed.padding};
        margin: 0;
        min-width: ${computed.minWidth || '36px'};
        min-height: ${computed.minHeight || '36px'};
        border-radius: 9999px;
        transition: background-color 0.2s, color 0.2s;
        color: rgb(113, 118, 123);
      `;
    } else {
      // Fallback minimal styles
      button.style.cssText = `
        background: transparent;
        border: none;
        cursor: pointer;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 0 12px;
        min-width: 36px;
        min-height: 36px;
        border-radius: 9999px;
        transition: background-color 0.2s, color 0.2s;
        color: rgb(113, 118, 123);
      `;
    }

    const iconHolder = document.createElement('span');
    iconHolder.className = 'archiver-icon';
    iconHolder.innerHTML = getIcon('download', iconSize);
    button.appendChild(iconHolder);

    // Add hover menu
    const menu = createHoverMenu();
    button.appendChild(menu);

    const statusBubble = document.createElement('div');
    statusBubble.className = 'archiver-status-bubble';
    statusBubble.setAttribute('role', 'status');
    statusBubble.setAttribute('aria-live', 'polite');
    button.appendChild(statusBubble);

    let menuTimeout;
    let statusHideTimeout;
    let statusPersistOnHover = false;
    let currentStatus = null;

    function setIcon(type) {
      iconHolder.innerHTML = getIcon(type, button.dataset.iconSize || 20);
    }

    function queueStatusHide(delay) {
      clearTimeout(statusHideTimeout);
      if (!delay || statusPersistOnHover) return;
      statusHideTimeout = setTimeout(() => {
        statusBubble.classList.remove('visible');
      }, delay);
    }

    function setStatusMessage(status, options = {}) {
      const { persistOnHover = false, announce = true, delay = 0, visibleOnSet = true } = options;
      currentStatus = status;
      statusPersistOnHover = persistOnHover;

      if (!status) {
        clearTimeout(statusHideTimeout);
        statusBubble.textContent = '';
        statusBubble.className = 'archiver-status-bubble';
        button.removeAttribute('data-status-tone');
        button.title = '';
        if (announce) {
          button.setAttribute('aria-label', 'Archive tweet');
        }
        return;
      }

      statusBubble.textContent = `${status.shortLabel}. ${status.detail}`;
      statusBubble.className = visibleOnSet ? 'archiver-status-bubble visible' : 'archiver-status-bubble';
      button.dataset.statusTone = status.tone;
      button.title = statusBubble.textContent;
      if (announce) {
        button.setAttribute('aria-label', `${status.shortLabel}. ${status.detail}`);
      }
      queueStatusHide(delay);
    }

    // Update button appearance based on modifier keys
    let planVisible = false;
    let stopWatchingModifiers = null;
    let previewMode = 'full';

    function clearCapturePlan() {
      planVisible = false;
      clearTimeout(menuTimeout);
      stopWatchingModifiers?.();
      stopWatchingModifiers = null;
      menu.classList.remove('visible');
      if (activeCapturePreview?.button === button) {
        activeCapturePreview = null;
        hideCapturePlan();
      }
    }

    function renderCapturePlan(mode) {
      previewMode = mode;
      clearDetachedCapturePlan();
      if (planVisible || menu.classList.contains('visible')) {
        showCapturePlan(getCapturePieces(article, mode), { mode });
      }
    }

    function updateButtonForModifier(e) {
      const mode = getSaveModeFromEvent(e);
      if (mode !== previewMode) renderCapturePlan(mode);
      const liveTweetData = getTweetData(true);
      if (downloadingPosts.has(getTweetKey(liveTweetData))) return;

      // The menu names the mode a click will use, even while the glyph shows an archived post.
      menu.querySelectorAll('.archiver-menu-item').forEach(item => {
        item.classList.toggle('active', item.dataset.mode === mode);
      });
      if (currentStatus?.tone === 'saved' || currentStatus?.tone === 'archived') return;

      setIcon(SAVE_MODES[mode].icon);
    }

    // Reset button to default appearance
    function resetButtonAppearance() {
      if (downloadingPosts.has(getTweetKey())) return;
      if (currentStatus?.tone === 'saved') {
        setIcon('success');
      } else if (currentStatus?.tone === 'archived') {
        setIcon('archived');
      } else if (currentStatus?.tone === 'queued') {
        setIcon('error');
      } else if (currentStatus?.tone === 'warning') {
        setIcon('tooSmall');
      } else if (currentStatus?.tone === 'error') {
        setIcon('error');
      } else {
        setIcon('download');
      }
      menu.querySelectorAll('.archiver-menu-item').forEach(item => {
        item.classList.toggle('active', item.dataset.mode === 'full');
      });
    }

    // Show menu after 1s hover delay
    button.addEventListener('mouseenter', (e) => {
      activeCapturePreview?.clear();
      activeCapturePreview = { button, article, clear: clearCapturePlan };
      planVisible = true;
      renderCapturePlan(getSaveModeFromEvent(e));
      stopWatchingModifiers?.();
      stopWatchingModifiers = watchModifiers(mode => {
        renderCapturePlan(mode);
        updateButtonForModifier({ altKey: mode === 'text' || mode === 'quoted', shiftKey: mode === 'quick' || mode === 'quoted' });
      });
      updateButtonForModifier(e);
      if (currentStatus?.tone === 'saved' || currentStatus?.tone === 'archived') {
        button.style.color = 'rgb(34, 197, 94)';
      } else if (currentStatus?.tone === 'warning') {
        button.style.color = 'rgb(251, 191, 36)';
      } else if (currentStatus?.tone === 'error' || currentStatus?.tone === 'queued') {
        button.style.color = 'rgb(239, 68, 68)';
      } else {
        button.style.color = 'rgb(29, 155, 240)';
      }
      if (currentStatus) {
        clearTimeout(statusHideTimeout);
        statusBubble.classList.add('visible');
      }
      menuTimeout = setTimeout(() => {
        clearDetachedCapturePlan();
        if (!planVisible) return;
        // If in portal, position menu with fixed coords
        if (button.closest('.media-archiver-portal')) {
          const btnRect = button.getBoundingClientRect();
          menu.style.position = 'fixed';
          menu.style.left = 'auto';
          menu.style.right = `${Math.max(0, window.innerWidth - btnRect.right - 6)}px`;
          // The portal stylesheet pins transform to none, so place the menu's top edge directly.
          menu.style.top = `${Math.max(8, btnRect.top - 8 - menu.offsetHeight)}px`;
        }
        menu.classList.add('visible');
        renderCapturePlan(previewMode);
      }, 1000);
    });

    button.addEventListener('mousemove', updateButtonForModifier);

    button.addEventListener('mouseleave', () => {
      clearCapturePlan();
      resetButtonAppearance();
      if (currentStatus) {
        if (statusPersistOnHover && !currentStatus.resetDelay) {
          statusBubble.classList.remove('visible');
        } else {
          queueStatusHide(currentStatus.resetDelay || 0);
        }
      }
      if (!downloadingPosts.has(getTweetKey())) {
        if (currentStatus?.tone === 'saved' || currentStatus?.tone === 'archived') {
          button.style.color = 'rgb(34, 197, 94)';
        } else if (currentStatus?.tone === 'warning') {
          button.style.color = 'rgb(251, 191, 36)';
        } else if (currentStatus?.tone === 'error' || currentStatus?.tone === 'queued') {
          button.style.color = 'rgb(239, 68, 68)';
        } else {
          button.style.color = 'rgb(113, 118, 123)';
        }
      }
    });

    // ═══════════════════════════════════════════════════════════════════════
    // Perform download with optional emotion data
    async function performDownload(saveMode, tweetData, releaseCapture, captureAgain = false, emotionData = null) {
      const tweetKey = getTweetKey(tweetData);
      // console.log('[archiver] performDownload called:', { saveMode, emotionData, tweetId: tweetData.tweetId, url: tweetData.tweetUrl });


      menu.classList.remove('visible');
      clearTimeout(menuTimeout);
      clearTimeout(statusHideTimeout);
      // The overlay must not become part of the context screenshot.
      activeCapturePreview?.clear();
      clearCapturePlan();

      function handleTerminalJobStatus(job) {
        pendingArchiveJobs.delete(job.jobId);
        pendingArchiveUrls.delete(job.url);
        pendingArchiveUrls.delete(tweetData.tweetUrl);

        if (job.status === 'completed') {
          setIcon('success');
          button.style.color = 'rgb(34, 197, 94)';
          archiveStatusCache.set(tweetData.tweetId, {
            archived: true,
            age_days: 0,
            file_exists: true
          });
          setStatusMessage({
            tone: 'saved',
            shortLabel: 'Saved',
            detail: job.filename ? `Archived as ${job.filename}.` : 'Archive completed successfully.',
            resetDelay: 3500
          }, { persistOnHover: true, delay: 3500 });

          setTimeout(() => {
            setIcon('download');
            button.style.color = 'rgb(113, 118, 123)';
            button.style.opacity = '1';
            setStatusMessage(null);
            releaseCapture();
          }, 3500);
          return;
        }

        const detailParts = [
          job.message || job.error || 'Archive failed.',
          job.actionHint || 'Click this button again to retry.'
        ].filter(Boolean);

        setIcon('error');
        button.style.color = 'rgb(239, 68, 68)';
        setStatusMessage({
          tone: 'error',
          shortLabel: job.status === 'stalled' ? 'May have stalled' : 'Download failed',
          detail: detailParts.join(' '),
          resetDelay: 10000
        }, { persistOnHover: true, delay: 10000 });

        // Let the user retry immediately; the visible error remains as guidance.
        releaseCapture();
        setTimeout(() => {
          if (!downloadingPosts.has(tweetKey)) {
            setIcon('download');
            button.style.color = 'rgb(113, 118, 123)';
            button.style.opacity = '1';
            setStatusMessage(null);
          }
        }, 10000);
      }

      setIcon('loading');
      button.style.color = 'rgb(29, 155, 240)';
      button.style.opacity = '1';
      setStatusMessage({
        tone: 'loading',
        shortLabel: 'Saving',
        detail: saveMode === 'quick' ? 'Saving media only.' : 'Capturing the tweet and sending it to the archive server.',
        resetDelay: 0
      }, { persistOnHover: false, delay: 0 });

      try {
        let screenshot = null;
        if (saveMode !== 'quick') {
          // console.log('[archiver] capturing screenshot...');
          screenshot = await withArchiverUIHidden(() => captureElement(article));
          // console.log('[archiver] screenshot captured:', screenshot ? `${screenshot.length} chars` : 'null');
        }

        // Build tweet content with optional emotion metadata
        const tweetContent = {
          text: tweetData.text,
          userName: tweetData.userName,
          timestamp: tweetData.timestamp,
          mediaCount: tweetData.mediaCount,
          imageUrls: tweetData.imageUrls,
          imageAlts: tweetData.imageAlts,
          hasVideo: tweetData.hasVideo,
          hasGif: tweetData.hasGif,
          gifUrl: tweetData.gifUrl,
          media: tweetData.media,
          hasImage: tweetData.hasImage
        };

        // Add emotion tag if present (emotionData is now just a string: 'joy', 'fear', etc.)
        if (emotionData) {
          tweetContent.emotion = emotionData;
        }

        const response = await NoDrawCapture.submit({
          kind: 'page',
          targetUrl: tweetData.tweetUrl,
          sourcePageUrl: window.location.href,
          page: {
            title: postTitle(tweetData.userName, tweetData.text, 'X'),
            author: tweetData.userName,
            description: tweetData.text,
            publishedAt: tweetData.timestamp
          },
          options: {
            saveMode: saveMode === 'quoted' ? 'full' : saveMode,
            captureAgain,
            screenshot,
            platform: 'twitter',
            siteData: {
              pageContext: window.location.href,
              mediaType: tweetData.hasGif ? 'gif' : 'twitter',
              tweetContent,
              quotes: tweetData.quotes,
              emotionTag: emotionData || null,
              twitterQuoted: saveMode === 'quoted'
            }
          }
        });

        // console.log('[archiver] response from background:', response);

        if (response?.success && response.job_id) {
          pendingArchiveJobs.set(response.job_id, handleTerminalJobStatus);
          setIcon('loading');
          button.style.color = 'rgb(29, 155, 240)';
          setStatusMessage({
            tone: 'loading',
            shortLabel: 'Download started',
            detail: 'Waiting for the archive server. This will change to Saved or Failed when the job finishes.',
            resetDelay: 0
          }, { persistOnHover: false, delay: 0 });
        } else if (response?.success) {
          setIcon('success');
          button.style.color = 'rgb(34, 197, 94)';
          setStatusMessage({
            tone: 'saved',
            shortLabel: 'Saved',
            detail: 'Archive completed successfully.',
            resetDelay: 2500
          }, { persistOnHover: true, delay: 2500 });

          setTimeout(() => {
            setIcon('download');
            button.style.color = 'rgb(113, 118, 123)';
            button.style.opacity = '1';
            setStatusMessage(null);
            releaseCapture();
          }, 2500);
        } else {
          console.error('[archiver] FAILED - response:', response);
          throw new Error(response?.error || 'Archive failed');
        }
      } catch (error) {
        console.error('[archiver] Archive error:', error);
        const status = getActionableStatus(error);
        if (status.tone === 'queued') {
          pendingArchiveUrls.set(tweetData.tweetUrl, handleTerminalJobStatus);
          setTimeout(() => {
            if (pendingArchiveUrls.get(tweetData.tweetUrl) === handleTerminalJobStatus) {
              pendingArchiveUrls.delete(tweetData.tweetUrl);
            }
          }, QUEUED_STATUS_TTL_MS);
        } else {
          pendingArchiveUrls.delete(tweetData.tweetUrl);
        }
        setIcon(status.tone === 'warning' ? 'tooSmall' : 'error');
        button.style.color = status.tone === 'warning' ? 'rgb(251, 191, 36)' : 'rgb(239, 68, 68)';
        setStatusMessage(status, { persistOnHover: true, delay: status.resetDelay });
        releaseCapture();

        setTimeout(() => {
          setIcon('download');
          button.style.color = 'rgb(113, 118, 123)';
          button.style.opacity = '1';
          setStatusMessage(null);
        }, status.resetDelay);
      }
    }

    // Handle click - Alt=text mode, Shift=quick mode, default=full mode
    button.addEventListener('click', async (e) => {
      e.preventDefault();
      e.stopPropagation();

      const tweetData = getTweetData(true);
      const tweetKey = getTweetKey(tweetData);
      const reservation = downloadingPosts.reserve(tweetKey);
      if (!reservation) return;
      const saveMode = getSaveModeFromEvent(e);

      try {
        const archiveStatus = await checkArchiveStatus(tweetData.tweetUrl, tweetData.tweetId);
        if (archiveStatus.archived) {
          const shouldRedownload = await showReArchivePrompt(tweetData, archiveStatus);
          if (!shouldRedownload) { reservation.release(); return; }
          archiveStatusCache.delete(tweetData.tweetId);
        }
        // Keep the clicked item's snapshot even if the timeline recycles its DOM.
        await performDownload(saveMode, tweetData, reservation.release, archiveStatus.archived === true);
      } catch (error) {
        reservation.release();
        setStatusMessage(getActionableStatus(error), { persistOnHover: true, delay: 10000 });
      }
    });

    // Check archive status asynchronously and update button appearance
    const tweetData = getTweetData(true);
    checkArchiveStatus(tweetData.tweetUrl, tweetData.tweetId).then(status => {
      if (status.archived && !downloadingPosts.has(getTweetKey())) {
        // Show archived indicator
        setIcon('archived');
        button.style.color = 'rgb(34, 197, 94)'; // green
        button.style.opacity = '0.7';

        const ageStr = status.age_days === 0 ? 'today' :
                       status.age_days === 1 ? 'yesterday' :
                       `${status.age_days} days ago`;
        setStatusMessage({
          tone: 'archived',
          shortLabel: 'Already archived',
          detail: `Saved ${ageStr}. Click to download a fresh copy if needed.`,
          resetDelay: 0
        }, { persistOnHover: true, announce: false, delay: 0, visibleOnSet: false });
      }
    });

    return button;
  }

  // Track portal wrappers for cleanup
  const portalWrappers = new WeakMap();
  // Keep timeline order repair weakly tied to the live wrapper. The shared
  // timeline observer invokes these callbacks, so each tweet does not need
  // its own MutationObserver retaining a detached action bar.
  const timelineOrderMaintainers = new WeakMap();
  // Track all cleanup functions for beforeunload
  const portalCleanups = new Set();

  // Check if we're in detail/modal view (clicked into a specific tweet)
  // Returns: 'main' for main tweet needing portal, 'reply' for replies, false for timeline
  function getViewType(article) {
    const isModal = !!article.closest('[role="dialog"]') || !!article.closest('[aria-modal="true"]');
    const isStatusPage = window.location.pathname.includes('/status/');

    if (!isStatusPage && !isModal) return 'timeline';

    // Check if this is the main tweet (first article in the thread)
    const primaryColumn = article.closest('[data-testid="primaryColumn"]');
    if (!primaryColumn) return 'timeline';

    // Main tweet has no previous article sibling and is at the top
    const allArticles = primaryColumn.querySelectorAll('article[data-testid="tweet"]');
    const isFirstArticle = allArticles[0] === article;

    if (isModal || isFirstArticle) return 'main';
    return 'reply';
  }

  // Legacy helper
  function isDetailView(article) {
    return getViewType(article) === 'main';
  }

  // Update portal position to track action bar
  function updatePortalPosition(wrapper, actionBar, archiveBtn) {
    if (!wrapper || !actionBar) return;
    const rect = actionBar.getBoundingClientRect();
    wrapper.style.top = `${rect.top}px`;
    wrapper.style.left = `${rect.left}px`;
    wrapper.style.width = `${rect.width}px`;
    wrapper.style.height = `${rect.height}px`;
  }

  // Process individual tweet
  function processTweet(article) {
    const viewType = getViewType(article);
    const needsPortal = viewType === 'main';
    const currentMode = processedPosts.get(article);

    // Already processed in correct mode
    if (currentMode === (needsPortal ? 'portal' : 'timeline')) return;

    // If was timeline mode but now needs portal, upgrade
    if (currentMode === 'timeline' && needsPortal) {
      // Remove old button/wrapper from action bar
      const oldWrapper = article.querySelector('.media-archiver-wrapper');
      if (oldWrapper) oldWrapper.remove();
      const oldBtn = article.querySelector('.media-archiver-twitter-btn');
      if (oldBtn) oldBtn.remove();
      clearDetachedCapturePlan();
      processedPosts.delete(article);
    }

    // Skip if already portal mode (don't downgrade)
    if (currentMode === 'portal') return;

    const tweetData = extractTweetContent(article);

    // Only add button if tweet has content worth archiving
    if (!tweetData.text && !tweetData.hasMedia) return;

    // Find the action bar (like, retweet buttons area)
    const actionBar = article.querySelector('[role="group"]');
    if (!actionBar) return;

    // Check if already has our button (in case WeakMap failed)
    if (actionBar.querySelector('.media-archiver-wrapper') ||
        actionBar.querySelector('.media-archiver-twitter-btn')) {
      processedPosts.set(article, 'timeline');
      return;
    }

    const archiveBtn = createArchiveButton(tweetData, article, actionBar);

    if (needsPortal) {
      // Portal pattern: append to body with fixed positioning
      const rect = actionBar.getBoundingClientRect();
      const wrapper = document.createElement('div');
      wrapper.className = 'media-archiver-portal';
      wrapper.style.cssText = `
        position: fixed;
        top: ${rect.top}px;
        left: ${rect.left}px;
        width: ${rect.width}px;
        height: ${rect.height}px;
        pointer-events: none;
        z-index: 2147483647;
        display: flex;
        align-items: center;
        justify-content: flex-end;
        padding-right: 40px;
      `;

      // Make button work inside pointer-events: none wrapper
      archiveBtn.style.pointerEvents = 'auto';

      wrapper.appendChild(archiveBtn);
      document.body.appendChild(wrapper);

      // Store reference for cleanup and position updates
      portalWrappers.set(article, { wrapper, actionBar, archiveBtn });

      // Update position on scroll
      const scrollContainer = article.closest('[data-testid="primaryColumn"]') || window;
      const updatePosition = () => updatePortalPosition(wrapper, actionBar, archiveBtn);

      if (scrollContainer !== window) {
        scrollContainer.addEventListener('scroll', updatePosition, { passive: true });
      }
      window.addEventListener('scroll', updatePosition, { passive: true });
      window.addEventListener('resize', updatePosition, { passive: true });

      // Use MutationObserver to detect article removal
      const portalObserver = new MutationObserver((mutations) => {
        if (!document.contains(article)) {
          cleanup();
        }
      });
      portalObserver.observe(document.body, { childList: true, subtree: true });

      // Cleanup when article is removed or page unloads
      const cleanup = () => {
        wrapper.remove();
        clearDetachedCapturePlan();
        window.removeEventListener('scroll', updatePosition);
        window.removeEventListener('resize', updatePosition);
        if (scrollContainer !== window) {
          scrollContainer.removeEventListener('scroll', updatePosition);
        }
        portalObserver.disconnect();
        portalCleanups.delete(cleanup);
        processedPosts.delete(article);
      };

      // Track for global cleanup on page unload
      portalCleanups.add(cleanup);

      // Mark as processed in portal mode
      processedPosts.set(article, 'portal');

    } else {
      // Timeline/reply view: insert before share button with matching wrapper
      const shareBtn = actionBar.querySelector('[aria-label="Share post"]') ||
                       actionBar.querySelector('[aria-label*="Share"]');

      // Find the share wrapper (a direct child of the action bar).
      let shareWrapper = shareBtn;
      while (shareWrapper && shareWrapper.parentElement !== actionBar) {
        shareWrapper = shareWrapper.parentElement;
      }

      // Clone share's wrapper - it has no extra margin classes unlike bookmark
      const wrapper = shareWrapper
        ? shareWrapper.cloneNode(false)
        : document.createElement('div');

      // Clear cloned attributes
      wrapper.innerHTML = '';
      wrapper.removeAttribute('aria-label');
      wrapper.removeAttribute('aria-expanded');
      wrapper.removeAttribute('aria-haspopup');
      wrapper.classList.add('media-archiver-wrapper');

      // Reset button to minimal styling, let wrapper handle layout
      archiveBtn.style.cssText = `
        background: transparent;
        border: none;
        cursor: pointer;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 0;
        margin: 0;
        min-height: 20px;
        border-radius: 9999px;
        transition: background-color 0.2s, color 0.2s;
        color: rgb(113, 118, 123);
      `;

      wrapper.appendChild(archiveBtn);

      const findDirectWrapper = (node) => {
        let current = node;
        while (current && current.parentElement !== actionBar) {
          current = current.parentElement;
        }
        return current;
      };

      // X can reconcile the action bar after the content script inserts us.
      // Re-apply the intended order after those child-list updates:
      // ... | bookmark | OURS | share.
      const ensureArchiveOrder = () => {
        if (!actionBar.isConnected) return;

        const currentBookmark = actionBar.querySelector('[data-testid="bookmark"], [data-testid="removeBookmark"], [aria-label*="ookmark"]');
        const currentShare = actionBar.querySelector('[aria-label="Share post"], [aria-label*="Share"]');
        const currentBookmarkWrapper = findDirectWrapper(currentBookmark);
        const currentShareWrapper = findDirectWrapper(currentShare);
        const reference = currentBookmarkWrapper?.nextElementSibling || currentShareWrapper || null;
        const alreadyOrdered = currentBookmarkWrapper
          ? currentBookmarkWrapper.nextElementSibling === wrapper
          : currentShareWrapper
            ? wrapper.nextElementSibling === currentShareWrapper
            : wrapper.parentElement === actionBar;

        if (!alreadyOrdered) {
          actionBar.insertBefore(wrapper, reference);
        }
      };

      try {
        ensureArchiveOrder();
      } catch (e) {
        // console.warn('[archiver] Twitter action bar insertion failed:', e.message);
        // Fallback: append to end
        try { actionBar.appendChild(wrapper); } catch (_) {}
      }

      timelineOrderMaintainers.set(wrapper, ensureArchiveOrder);
      requestAnimationFrame(ensureArchiveOrder);
      setTimeout(ensureArchiveOrder, 100);

      // Fix spacing: bookmark has 9px marginRight that creates uneven gaps
      // Also fix inner elements with negative margins
      setTimeout(() => {
        const bm = actionBar.querySelector('[data-testid="bookmark"], [data-testid="removeBookmark"]');
        if (bm) {
          let bmWrapper = bm;
          while (bmWrapper && bmWrapper.parentElement !== actionBar) {
            bmWrapper = bmWrapper.parentElement;
          }
          if (bmWrapper) {
            bmWrapper.style.marginRight = '0';
            bmWrapper.querySelectorAll('*').forEach(el => {
              if (window.getComputedStyle(el).marginRight !== '0px') {
                el.style.marginRight = '0';
              }
            });
          }
        }
      }, 50);

      // Mark as processed in timeline mode
      processedPosts.set(article, 'timeline');
    }
  }

  // Process all visible tweets and repair action-bar order from the one shared
  // observer. WeakMap entries disappear with detached wrappers.
  function processAllTweets() {
    const tweets = document.querySelectorAll('article[data-testid="tweet"]');
    tweets.forEach(processTweet);

    document.querySelectorAll('.media-archiver-wrapper').forEach(wrapper => {
      const maintainOrder = timelineOrderMaintainers.get(wrapper);
      if (maintainOrder) {
        try { maintainOrder(); } catch (_) {}
      }
    });
  }

  let processFrame = null;
  function scheduleTweetProcessing() {
    clearDetachedCapturePlan();
    if (processFrame !== null) return;
    processFrame = requestAnimationFrame(() => {
      processFrame = null;
      processAllTweets();
    });
  }

  // One observer handles new tweets and action-bar reconciliation.
  const observer = new MutationObserver(scheduleTweetProcessing);

  // Start observing when timeline is ready
  function initialize() {
    const timeline = document.querySelector('main');
    if (timeline) {
      observer.observe(timeline, {
        childList: true,
        subtree: true
      });
      processAllTweets();
    } else {
      // Retry if timeline not ready
      setTimeout(initialize, 500);
    }
  }

  // Add custom styles for better integration
  const style = document.createElement('style');
  style.textContent = `
    .media-archiver-twitter-btn {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      -webkit-font-smoothing: antialiased;
      position: relative;
    }

    .media-archiver-twitter-btn:hover {
      background: rgba(29, 155, 240, 0.1);
    }

    .media-archiver-twitter-btn svg {
      display: block;
    }

    .media-archiver-twitter-btn .archiver-icon {
      display: inline-flex;
      align-items: center;
      justify-content: center;
    }

    .media-archiver-twitter-btn .archiver-status-bubble {
      position: absolute;
      top: calc(100% + 6px);
      left: 50%;
      transform: translateX(-50%) translateY(-4px);
      min-width: 180px;
      max-width: min(280px, 60vw);
      padding: 8px 10px;
      border-radius: 10px;
      background: rgba(15, 23, 42, 0.96);
      color: white;
      font-size: 12px;
      line-height: 1.35;
      text-align: left;
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.3);
      opacity: 0;
      pointer-events: none;
      transition: opacity 0.15s ease, transform 0.15s ease;
      z-index: 10000;
      white-space: normal;
    }

    .media-archiver-twitter-btn .archiver-status-bubble.visible {
      opacity: 1;
      transform: translateX(-50%) translateY(0);
    }

    .media-archiver-twitter-btn[data-status-tone="saved"] .archiver-status-bubble,
    .media-archiver-twitter-btn[data-status-tone="archived"] .archiver-status-bubble {
      background: rgba(20, 83, 45, 0.96);
    }

    .media-archiver-twitter-btn[data-status-tone="queued"] .archiver-status-bubble,
    .media-archiver-twitter-btn[data-status-tone="error"] .archiver-status-bubble {
      background: rgba(127, 29, 29, 0.96);
    }

    .media-archiver-twitter-btn[data-status-tone="warning"] .archiver-status-bubble {
      background: rgba(120, 53, 15, 0.96);
    }

    /* Spinning animation for loading */
    .archiver-spin {
      animation: archiver-spin 1s linear infinite;
    }

    @keyframes archiver-spin {
      from { transform: rotate(0deg); }
      to { transform: rotate(360deg); }
    }

    /* Hover menu - hidden by default, shown via .visible class after delay */
    .media-archiver-twitter-btn .archiver-menu {
      position: absolute;
      bottom: 100%;
      /* Right-aligned: the glyph sits near the end of X's action bar and the
         article clips overflow, so a centred menu loses its shortcut hints. */
      right: -6px;
      transform: translateY(4px) scale(0.95);
      transform-origin: bottom right;
      margin-bottom: 8px;
      background: rgba(0, 0, 0, 0.9);
      backdrop-filter: blur(12px);
      border-radius: 12px;
      padding: 8px 0;
      min-width: 150px;
      opacity: 0;
      pointer-events: none;
      transition: all 0.15s ease;
      font-size: 13px;
      color: white;
      white-space: nowrap;
      box-shadow: 0 4px 12px rgba(0,0,0,0.3);
    }

    .media-archiver-twitter-btn .archiver-menu.visible {
      opacity: 1;
      transform: translateY(0) scale(1);
      /* This is a keyboard-shortcut hint, not an interactive popover. Keeping
         it non-interactive lets mouseleave dismiss it instead of trapping the
         pointer over the menu. */
      pointer-events: none;
    }

    .archiver-menu-item {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 8px 12px;
      opacity: 0.6;
      transition: all 0.1s;
    }

    .archiver-menu-item:hover {
      opacity: 1;
      background: rgba(255, 255, 255, 0.1);
    }

    .archiver-menu-item.active {
      opacity: 1;
      background: rgba(29, 155, 240, 0.2);
    }

    .archiver-menu-item svg {
      flex-shrink: 0;
    }

    .archiver-menu-item kbd {
      font-family: inherit;
      font-size: 11px;
      padding: 2px 6px;
      background: rgba(255,255,255,0.1);
      border-radius: 4px;
      margin-left: auto;
      opacity: 0.7;
    }

    /* Menu divider */
    .archiver-menu-divider {
      height: 1px;
      background: rgba(255, 255, 255, 0.1);
      margin: 6px 0;
    }

    /* Portal wrapper for detail view */
    .media-archiver-portal {
      pointer-events: none;
    }

    .media-archiver-portal .media-archiver-twitter-btn {
      pointer-events: auto;
    }

    /* Menu in portal needs fixed positioning to escape any clipping */
    .media-archiver-portal .archiver-menu {
      position: fixed !important;
      bottom: auto !important;
      transform: none !important;
    }

    .media-archiver-portal .archiver-menu.visible {
      transform: none !important;
    }

    /* Hide on print */
    @media print {
      .media-archiver-twitter-btn, .archiver-menu, .media-archiver-portal {
        display: none !important;
      }
    }
  `;
  document.head.appendChild(style);

  // Cleanup all resources on page unload
  window.addEventListener('beforeunload', () => {
    activeCapturePreview?.clear();
    // Disconnect main timeline observer and cancel its pending batch.
    observer.disconnect();
    if (processFrame !== null) {
      cancelAnimationFrame(processFrame);
      processFrame = null;
    }
    // Run all portal cleanup functions (removes portals, disconnects their observers)
    portalCleanups.forEach(cleanup => cleanup());
    portalCleanups.clear();
  });

  // Initialize when ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initialize);
  } else {
    initialize();
  }

})();
