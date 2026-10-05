/**
 * Site-specific configurations for gallery content script
 * Each site has selectors and extractors for images, URLs, and metadata
 */

const GallerySiteConfigs = (function() {
  'use strict';

  const CONFIGS = {
    flickr: {
      // Handles both gallery views AND single photo pages
      itemSelector: '.photo-list-photo-view, .photo-card, .view.photo-well-media-scrappy-view, .photo-well-media-scrappy-view, .main-photo',
      containerSelector: '.photo-list-view, .photostream, .photo-list-photo-container, .photo-page-scrappy-view, main',
      singlePhotoSelector: '.photo-well-media-scrappy-view img, .main-photo img, [style*="background-image"]',
      getImageUrl: (el, maxWidth) => {
        // Try to get best size from modelExport JSON (single photo page)
        const bestUrl = GallerySiteConfigs.flickrGetBestSize(maxWidth);
        if (bestUrl) return bestUrl;

        // Fallback: use img src (gallery view)
        const img = el.tagName === 'IMG' ? el : el.querySelector('img');
        if (img) {
          let src = img.src || img.dataset.src;
          if (src) {
            // Flickr sizes: s=75, q=150, t=100, m=240, n=320, w=400, z=640, c=800, b=1024, h=1600, k=2048, o=original
            // Note: URL replacement only works for same-secret sizes (b,c,z,w,n,m,t,q,s)
            // Higher res (k,h,o,3k,4k,5k) have different secrets - need modelExport
            src = src.replace(/_[sqtmnwzc]\.jpg$/i, '_b.jpg');
            src = src.replace(/_[sqtmnwzc]_d\.jpg$/i, '_b.jpg');
          }
          return src;
        }
        return null;
      },
      getPageUrl: (el) => {
        // Try to find a direct link to the individual photo page
        // Must be careful to exclude gallery/album/with URLs
        const links = el.querySelectorAll('a[href*="/photos/"]');
        for (const link of links) {
          const href = link.href;
          // Skip gallery-type URLs (these don't point to individual photos)
          if (href.includes('/with/') || href.includes('/albums/') || href.includes('/sets/') || href.includes('/favorites')) continue;
          // Match individual photo page pattern: /photos/{user}/{photo_id}
          const match = href.match(/(\/photos\/[^/]+\/\d+)/);
          if (match) {
            return `https://www.flickr.com${match[1]}/`;
          }
        }
        // Fallback: extract photo ID from image URL and construct page URL
        const img = el.tagName === 'IMG' ? el : el.querySelector('img');
        // Handle lazy loading - Flickr uses data-src for deferred images
        const imgSrc = img?.src || img?.dataset?.src;
        if (imgSrc) {
          // Image URL format: https://live.staticflickr.com/65535/PHOTOID_secret_size.jpg
          // OR: https://live.staticflickr.com/65535/PHOTOID_secret.jpg (no size suffix in some galleries)
          const photoIdMatch = imgSrc.match(/\/(\d+)_[a-f0-9]+(?:_[a-z0-9]+)?\.jpg/i);
          if (photoIdMatch) {
            // Get username from current URL
            const userMatch = window.location.pathname.match(/\/photos\/([^/]+)/);
            const username = userMatch ? userMatch[1] : 'unknown';
            console.log(`[archiver] Flickr: extracted photo page from img src: /photos/${username}/${photoIdMatch[1]}/`);
            return `https://www.flickr.com/photos/${username}/${photoIdMatch[1]}/`;
          }
        }
        console.warn('[archiver] Flickr: could not extract photo page URL, using window.location');
        return window.location.href;
      },
      getMetadata: (el) => {
        const title = document.querySelector('.photo-title')?.textContent?.trim() ||
                      document.querySelector('meta[property="og:title"]')?.content ||
                      el.querySelector('.title')?.textContent?.trim() ||
                      el.querySelector('img')?.alt || '';
        const owner = document.querySelector('.owner-name a')?.textContent?.trim() ||
                      document.querySelector('.attribution a')?.textContent?.trim() ||
                      el.querySelector('.owner-name')?.textContent?.trim() || '';
        const desc = document.querySelector('.photo-desc')?.textContent?.trim() ||
                     document.querySelector('meta[property="og:description"]')?.content || '';
        return { title, artist: owner, description: desc };
      }
    },

    deviantart: {
      itemSelector: '[data-testid="deviation-card"], .torpedo-container, ._2vMZg, [data-hook="deviation_std_thumb"]',
      containerSelector: '[data-hook="content_row"], .browse-container, main, #root',
      getImageUrl: (el) => {
        const img = el.querySelector('img[src*="wixmp"], img[src*="deviantart"]');
        if (!img) return null;
        let src = img.src || img.dataset.src;
        if (src && src.includes('wixmp')) {
          src = src.replace(/\/v1\/fill\/[^/]+\//, '/');
        }
        return src;
      },
      getPageUrl: (el) => {
        const link = el.querySelector('a[href*="/art/"]');
        return link?.href || window.location.href;
      },
      getMetadata: (el) => {
        const title = el.querySelector('[data-hook="deviation_title"]')?.textContent?.trim() ||
                      el.querySelector('a[href*="/art/"]')?.title || '';
        const artist = el.querySelector('[data-hook="user_link"]')?.textContent?.trim() ||
                       el.querySelector('a[href*="deviantart.com/"]')?.textContent?.trim() || '';
        return { title, artist, description: '' };
      }
    },

    artstation: {
      itemSelector: '.project-image, .gallery-grid-item, [class*="ProjectCard"], .project',
      containerSelector: '.gallery-grid, .projects-list, main, #root',
      getImageUrl: (el) => {
        const img = el.querySelector('img');
        if (!img) return null;
        let src = img.src || img.dataset.src;
        if (src && src.includes('artstation')) {
          src = src.replace(/\/smaller_square\//, '/large/').replace(/\/small\//, '/large/');
        }
        return src;
      },
      getPageUrl: (el) => {
        const link = el.querySelector('a[href*="/artwork/"]');
        return link?.href || window.location.href;
      },
      getMetadata: (el) => {
        const title = el.querySelector('.project-title')?.textContent?.trim() ||
                      el.querySelector('img')?.alt || '';
        const artist = el.querySelector('.artist-name')?.textContent?.trim() ||
                       el.querySelector('[class*="username"]')?.textContent?.trim() || '';
        return { title, artist, description: '' };
      }
    },

    pinterest: {
      itemSelector: '[data-test-id="pin"], [data-test-id="pinrep"], .Pin, [data-grid-item="true"]',
      containerSelector: '[data-test-id="grid"], .gridCentered, main, #__PWS_ROOT__',
      getImageUrl: (el) => {
        const img = el.querySelector('img[src*="pinimg.com"]');
        if (!img) return null;
        let src = img.src || img.dataset.src;
        if (src) {
          src = src.replace(/\/\d+x[^/]*\//, '/originals/');
        }
        return src;
      },
      getPageUrl: (el) => {
        const link = el.querySelector('a[href*="/pin/"]');
        return link?.href || window.location.href;
      },
      getMetadata: (el) => {
        const title = el.querySelector('[data-test-id="pin-title"]')?.textContent?.trim() ||
                      el.querySelector('img')?.alt || '';
        const artist = el.querySelector('[data-test-id="pinner-name"]')?.textContent?.trim() || '';
        const desc = el.querySelector('[data-test-id="pin-description"]')?.textContent?.trim() || '';
        return { title, artist, description: desc };
      }
    },

    // Museum sites
    met: {
      itemSelector: '.artwork__image, .met-carousel__slide, .collection-search__image',
      containerSelector: '.artwork, .met-carousel, main',
      getImageUrl: (el) => {
        const img = el.querySelector('img');
        if (!img) return null;
        let src = img.src || img.dataset.src;
        if (img.srcset) {
          const sources = img.srcset.split(',').map(s => s.trim());
          const largest = sources[sources.length - 1];
          src = largest.split(' ')[0];
        }
        return src?.replace(/web-large|web-additional/, 'original');
      },
      getPageUrl: (el) => window.location.href,
      getMetadata: (el) => {
        const title = document.querySelector('.artwork__title--text, h1')?.textContent?.trim() || '';
        const artist = document.querySelector('.artwork__artist, .artwork__tombstone--artist')?.textContent?.trim() || '';
        const date = document.querySelector('.artwork__date')?.textContent?.trim() || '';
        return { title, artist, description: date };
      }
    },

    britishmuseum: {
      itemSelector: '.object-page__image img, .image-viewer img',
      containerSelector: '.object-page, main',
      getImageUrl: (el) => {
        const img = el.tagName === 'IMG' ? el : el.querySelector('img');
        return img?.src?.replace(/\?.*$/, '');
      },
      getPageUrl: (el) => window.location.href,
      getMetadata: (el) => {
        const title = document.querySelector('h1, .object-page__title')?.textContent?.trim() || '';
        const museum = document.querySelector('.object-page__museum')?.textContent?.trim() || '';
        return { title, artist: '', description: museum };
      }
    },

    rijksmuseum: {
      itemSelector: '.art-object-page-image img, [data-object-image] img',
      containerSelector: '.art-object-page, main',
      getImageUrl: (el) => {
        const img = el.tagName === 'IMG' ? el : el.querySelector('img');
        let src = img?.src;
        if (src?.includes('iiif')) {
          src = src.replace(/\/full\/\d+,\d+\//, '/full/max/');
        }
        return src;
      },
      getPageUrl: (el) => window.location.href,
      getMetadata: (el) => {
        const title = document.querySelector('h1, .art-object-page-title')?.textContent?.trim() || '';
        const artist = document.querySelector('.art-object-page-artist')?.textContent?.trim() || '';
        return { title, artist, description: '' };
      }
    },

    wikimedia: {
      itemSelector: '.fullImageLink img, #file img',
      containerSelector: '.fullMedia, #file',
      getImageUrl: (el) => {
        const originalLink = document.querySelector('.fullImageLink a, #file a');
        return originalLink?.href || el.src;
      },
      getPageUrl: (el) => window.location.href,
      getMetadata: (el) => {
        const title = document.querySelector('#firstHeading')?.textContent?.trim()?.replace('File:', '') || '';
        const author = document.querySelector('#fileinfotpl_aut + td')?.textContent?.trim() || '';
        const desc = document.querySelector('#fileinfotpl_desc + td')?.textContent?.trim() || '';
        return { title, artist: author, description: desc };
      }
    },

    nga: {
      itemSelector: '.object-image img, .artwork-image img',
      containerSelector: '.object-page, main',
      getImageUrl: (el) => {
        const img = el.tagName === 'IMG' ? el : el.querySelector('img');
        let src = img?.src;
        if (src?.includes('iiif')) {
          src = src.replace(/\/full\/\d+,\//, '/full/max/');
        }
        return src;
      },
      getPageUrl: (el) => window.location.href,
      getMetadata: (el) => {
        const title = document.querySelector('h1, .artwork-title')?.textContent?.trim() || '';
        const artist = document.querySelector('.artwork-artist, .object-artist')?.textContent?.trim() || '';
        return { title, artist, description: '' };
      }
    },

    // Google Arts & Culture - uses tiled/zoomable images handled by dezoomify-rs
    googlearts: {
      itemSelector: '.openseadragon-container, [class*="viewer"], canvas[class*="openseadragon"], [class*="asset-image"], [class*="AssetImage"], [data-asset-id]',
      containerSelector: 'body',
      getImageUrl: (el) => {
        // For Google Arts & Culture, we pass the page URL to dezoomify-rs
        return window.location.href;
      },
      getPageUrl: (el) => window.location.href,
      getMetadata: (el) => {
        const details = {};

        document.querySelectorAll('[class*="detail"], [class*="Detail"], dl, [class*="metadata"]').forEach(container => {
          const text = container.textContent || '';
          const patterns = [
            /Title:\s*(.+?)(?=Creator:|Date:|$)/i,
            /Creator:\s*(.+?)(?=Creator Lifespan:|Date:|$)/i,
            /Date:\s*(.+?)(?=Physical|Medium|$)/i,
            /Medium:\s*(.+?)(?=Physical|Rights|$)/i,
            /Type:\s*(.+?)(?=Rights|External|$)/i,
          ];
          patterns.forEach(p => {
            const m = text.match(p);
            if (m) details[p.source.split(':')[0].replace(/[\\\/]/g, '')] = m[1].trim();
          });
        });

        // Extract title - prioritize itemprop="name" for better accuracy
        const title = document.querySelector('[itemprop="name"]')?.textContent?.trim() ||
                      document.querySelector('meta[property="og:title"]')?.content ||
                      document.querySelector('h1')?.textContent?.trim() ||
                      details['Title'] || '';

        let artist = '';
        const creatorLink = document.querySelector('a[href*="/entity/"]');
        if (creatorLink) {
          artist = creatorLink.textContent?.trim() || '';
        }
        if (!artist) {
          artist = details['Creator'] ||
                   document.querySelector('[itemprop="creator"]')?.textContent?.trim() || '';
        }

        const parts = [];
        if (details['Date']) parts.push(details['Date']);
        if (details['Medium']) parts.push(details['Medium']);
        if (details['Type']) parts.push(details['Type']);

        const institution = document.querySelector('a[href*="/partner/"]')?.textContent?.trim() || '';
        if (institution) parts.push(institution);

        const description = parts.join(' | ') ||
                           document.querySelector('meta[property="og:description"]')?.content || '';

        // Extract asset ID from URL: /asset/{title-slug}/{ASSET_ID}
        let assetId = '';
        const urlMatch = window.location.pathname.match(/\/asset\/[^/]+\/([^/]+)/);
        if (urlMatch) {
          assetId = urlMatch[1];
        }

        return { title, artist, description, assetId };
      }
    }
  };

  /**
   * Detect current site from hostname
   */
  function detectSite() {
    const host = window.location.hostname;
    if (host.includes('flickr.com')) return 'flickr';
    if (host.includes('deviantart.com')) return 'deviantart';
    if (host.includes('artstation.com')) return 'artstation';
    if (host.includes('pinterest.')) return 'pinterest';
    if (host.includes('artsandculture.google.com')) return 'googlearts';
    if (host.includes('metmuseum.org')) return 'met';
    if (host.includes('britishmuseum.org')) return 'britishmuseum';
    if (host.includes('rijksmuseum.nl')) return 'rijksmuseum';
    if (host.includes('commons.wikimedia.org')) return 'wikimedia';
    if (host.includes('nga.gov')) return 'nga';
    return null;
  }

  /**
   * Get config for a site
   */
  function getConfig(siteName) {
    return CONFIGS[siteName] || null;
  }

  /**
   * Extract best Flickr image URL from page HTML
   * Flickr embeds all size URLs in the page with escaped slashes
   * @param {number|null} maxWidth - Max width (null = original)
   * @returns {string|null} Best available image URL
   */
  function flickrGetBestSize(maxWidth) {
    try {
      // Get current photo ID from URL
      const photoIdMatch = window.location.pathname.match(/\/photos\/[^/]+\/(\d+)/);
      if (!photoIdMatch) {
        console.log('[archiver] Flickr: not on a single photo page');
        return null;
      }
      const photoId = photoIdMatch[1];
      console.log(`[archiver] Flickr: looking for photo ID ${photoId}`);

      // Get the full page HTML
      const html = document.documentElement.innerHTML;

      // Size order: try largest first
      // For default (8K max), skip 'o' as it may be huge
      const sizeOrder = maxWidth === null
        ? ['o', '5k', '4k', '3k', 'k', 'h']
        : ['5k', '4k', '3k', 'k', 'h'];

      for (const size of sizeOrder) {
        // Match escaped URL pattern for THIS photo only
        // \/\/live.staticflickr.com\/SERVER\/PHOTOID_SECRET_SIZE.jpg
        const pattern = new RegExp(`\\\\/\\\\/live\\.staticflickr\\.com\\\\/\\d+\\\\/${photoId}_[a-f0-9]+_${size}\\.jpg`, 'i');
        const match = html.match(pattern);
        if (match) {
          const url = 'https:' + match[0].replace(/\\\//g, '/');
          console.log(`[archiver] Flickr: found ${size} size: ${url}`);
          return url;
        }
      }

      console.log('[archiver] Flickr: no high-res sizes found for photo ' + photoId);
    } catch (e) {
      console.log('[archiver] Flickr size extraction error:', e);
    }
    return null;
  }

  return {
    detectSite,
    getConfig,
    flickrGetBestSize,
    CONFIGS
  };
})();

// Make available globally
if (typeof window !== 'undefined') {
  window.GallerySiteConfigs = GallerySiteConfigs;
}
