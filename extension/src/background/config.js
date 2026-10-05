/**
 * Shared configuration for nodraw extension
 * Single source of truth for server URL and settings
 *
 * Server discovery is handled by discover.js (loaded before this file).
 * getServerURL() is defined there — uses port discovery service on :8800.
 */

const CONFIG = {
  // Endpoints
  ENDPOINTS: {
    health: '/health',
    captures: '/captures',
    jobs: '/jobs',
    jobStatus: '/jobs/',  // + job_id
    stats: '/stats'
  },

  // Timeouts (ms)
  TIMEOUTS: {
    healthCheck: 5000,
    capture: 60000
  },

  // Health check interval (ms)
  HEALTH_CHECK_INTERVAL: 5000,

  // Image size thresholds
  IMAGE: {
    MIN_WIDTH: 200,
    MIN_HEIGHT: 200,
    LARGE_MIN_WIDTH: 400,
    LARGE_MIN_HEIGHT: 400
  },

  // Save modes
  SAVE_MODES: {
    FULL: 'full',      // Media + screenshot + metadata
    QUICK: 'quick',    // Media only
    TEXT: 'text'       // Screenshot + metadata only
  },

  // Platform identifiers
  PLATFORMS: {
    TWITTER: 'twitter',
    YOUTUBE: 'youtube',
    REDDIT: 'reddit',
    FLICKR: 'flickr',
    DEVIANTART: 'deviantart',
    ARTSTATION: 'artstation',
    PINTEREST: 'pinterest',
    GOOGLE_ARTS: 'googlearts',
    GENERIC: 'web'
  }
};

// Make available to content scripts, extension pages, and service workers.
if (typeof globalThis !== 'undefined') {
  globalThis.ARCHIVER_CONFIG = CONFIG;
}
