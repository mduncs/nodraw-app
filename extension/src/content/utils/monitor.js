/**
 * Performance monitoring module for browser extension
 * Provides memory tracking, timing metrics, leak detection, and debug utilities
 *
 * Usage from console:
 *   window.__archiver_monitor.status()
 *   window.__archiver_monitor.Debug.toggle()
 *   window.__archiver_monitor.Timing.allStats()
 */

const Monitor = (function() {
  'use strict';

  // Storage keys. Keep the debug panel and content-script monitor on the same
  // key so toggling the panel actually enables logging in the page scripts.
  const DEBUG_STORAGE_KEY = 'debugMode';
  const LEGACY_DEBUG_STORAGE_KEY = 'archiver_debug_mode';
  const DEBUG_DEFAULT_ENABLED = false;
  const METRICS_STORAGE_KEY = 'archiver_metrics';

  function getStorage() {
    const extensionAPI = typeof browser !== 'undefined' ? browser : chrome;
    return extensionAPI?.storage?.local || null;
  }

  // ============ Debug ============
  // Conditional logging based on stored debug flag
  const Debug = {
    _enabled: null,
    _prefix: '[archiver]',

    /**
     * Check if debug mode is enabled (sync, uses cache)
     * @returns {boolean}
     */
    isEnabled() {
      if (this._enabled !== null) {
        return this._enabled;
      }

      // Try localStorage (sync access)
      try {
        const stored = localStorage.getItem(DEBUG_STORAGE_KEY);
        if (stored !== null) {
          this._enabled = stored === 'true';
          return this._enabled;
        }
        const legacyStored = localStorage.getItem(LEGACY_DEBUG_STORAGE_KEY);
        if (legacyStored !== null) {
          this._enabled = legacyStored === 'true';
          return this._enabled;
        }
      } catch (e) {
        // localStorage not available
      }

      this._enabled = DEBUG_DEFAULT_ENABLED;
      return this._enabled;
    },

    /**
     * Load debug state from extension storage (async)
     */
    async load() {
      try {
        const storage = getStorage();
        if (storage) {
          const result = await storage.get([DEBUG_STORAGE_KEY, LEGACY_DEBUG_STORAGE_KEY]);
          const stored = typeof result[DEBUG_STORAGE_KEY] === 'boolean'
            ? result[DEBUG_STORAGE_KEY]
            : result[LEGACY_DEBUG_STORAGE_KEY];
          this._enabled = typeof stored === 'boolean' ? stored : DEBUG_DEFAULT_ENABLED;
          if (typeof result[DEBUG_STORAGE_KEY] !== 'boolean' && typeof result[LEGACY_DEBUG_STORAGE_KEY] === 'boolean') {
            await storage.set({ [DEBUG_STORAGE_KEY]: this._enabled });
          }
        } else {
          this._enabled = this.isEnabled();
        }
      } catch (e) {
        this._enabled = DEBUG_DEFAULT_ENABLED;
      }
      return this._enabled;
    },

    /**
     * Toggle debug mode
     * @returns {Promise<boolean>} New debug state
     */
    async toggle() {
      this._enabled = !this._enabled;

      try {
        const storage = getStorage();
        if (storage) {
          await storage.set({
            [DEBUG_STORAGE_KEY]: this._enabled,
            [LEGACY_DEBUG_STORAGE_KEY]: this._enabled
          });
        }
        localStorage.setItem(DEBUG_STORAGE_KEY, String(this._enabled));
        localStorage.setItem(LEGACY_DEBUG_STORAGE_KEY, String(this._enabled));
      } catch (e) {
        // Storage not available
      }

      console.log(`[monitor] Debug mode: ${this._enabled ? 'ON' : 'OFF'}`);
      return this._enabled;
    },

    /**
     * Set debug mode explicitly
     * @param {boolean} enabled
     */
    async set(enabled) {
      this._enabled = !!enabled;

      try {
        const storage = getStorage();
        if (storage) {
          await storage.set({
            [DEBUG_STORAGE_KEY]: this._enabled,
            [LEGACY_DEBUG_STORAGE_KEY]: this._enabled
          });
        }
        localStorage.setItem(DEBUG_STORAGE_KEY, String(this._enabled));
        localStorage.setItem(LEGACY_DEBUG_STORAGE_KEY, String(this._enabled));
      } catch (e) {
        // Storage not available
      }

      return this._enabled;
    },

    /**
     * Conditional logging
     * @param {string} tag - Log category
     * @param {...*} args - Log arguments
     */
    log(tag, ...args) {
      if (!this.isEnabled()) return;
      console.log(`${this._prefix}:${tag}`, ...args);
    },

    /**
     * Conditional table logging
     * @param {string} tag - Log category
     * @param {*} data - Data to display as table
     */
    table(tag, data) {
      if (!this.isEnabled()) return;
      console.log(`${this._prefix}:${tag}`);
      console.table(data);
    },

    /**
     * Conditional warning
     * @param {string} tag - Log category
     * @param {...*} args
     */
    warn(tag, ...args) {
      if (!this.isEnabled()) return;
      console.warn(`${this._prefix}:${tag}`, ...args);
    },

    /**
     * Error logging (always logs regardless of debug mode)
     * @param {string} tag - Log category
     * @param {...*} args
     */
    error(tag, ...args) {
      console.error(`${this._prefix}:${tag}`, ...args);
    }
  };

  // ============ Memory ============
  // Memory tracking using performance.memory (Chrome) or estimation
  const Memory = {
    _snapshots: [],
    _maxSnapshots: 100,

    /**
     * Capture current heap size if available
     * @returns {Object|null} Memory snapshot
     */
    snapshot() {
      const snap = {
        timestamp: Date.now(),
        label: null,
        heap: null,
        heapTotal: null,
        heapLimit: null
      };

      // Chrome-specific memory API
      if (typeof performance !== 'undefined' && performance.memory) {
        snap.heap = performance.memory.usedJSHeapSize;
        snap.heapTotal = performance.memory.totalJSHeapSize;
        snap.heapLimit = performance.memory.jsHeapSizeLimit;
      }

      return snap;
    },

    /**
     * Log memory at checkpoint with label
     * @param {string} label - Checkpoint identifier
     * @returns {Object|null}
     */
    track(label) {
      const snap = this.snapshot();
      if (!snap) return null;

      snap.label = label;
      this._snapshots.push(snap);

      if (this._snapshots.length > this._maxSnapshots) {
        this._snapshots.shift();
      }

      if (Debug.isEnabled() && snap.heap) {
        const heapMB = (snap.heap / 1024 / 1024).toFixed(2);
        console.log(`[monitor:memory] ${label}: ${heapMB} MB`);
      }

      return snap;
    },

    /**
     * Warn if memory exceeds threshold
     * @param {number} thresholdMB - Threshold in megabytes
     * @returns {boolean} True if threshold exceeded
     */
    warn(thresholdMB) {
      const snap = this.snapshot();
      if (!snap || !snap.heap) return false;

      const heapMB = snap.heap / 1024 / 1024;
      if (heapMB > thresholdMB) {
        console.warn(`[monitor:memory] WARNING: Heap ${heapMB.toFixed(2)} MB exceeds threshold ${thresholdMB} MB`);
        return true;
      }
      return false;
    },

    /**
     * Get recent snapshots
     * @param {number} count
     * @returns {Array}
     */
    getRecent(count = 10) {
      return this._snapshots.slice(-count);
    },

    /**
     * Get memory growth statistics
     * @returns {Object|null}
     */
    getGrowth() {
      if (this._snapshots.length < 2) return null;

      const first = this._snapshots[0];
      const last = this._snapshots[this._snapshots.length - 1];

      if (!first.heap || !last.heap) return null;

      return {
        startMB: (first.heap / 1024 / 1024).toFixed(2),
        endMB: (last.heap / 1024 / 1024).toFixed(2),
        growthMB: ((last.heap - first.heap) / 1024 / 1024).toFixed(2),
        durationMs: last.timestamp - first.timestamp,
        samples: this._snapshots.length
      };
    },

    /**
     * Clear stored snapshots
     */
    clear() {
      this._snapshots = [];
    }
  };

  // ============ Timing ============
  // Track operation durations with averaging support
  const Timing = {
    _timers: new Map(),
    _history: new Map(),
    _maxHistory: 50,

    /**
     * Start a timer
     * @param {string} label - Timer identifier
     * @returns {number} Start timestamp
     */
    start(label) {
      const start = performance.now();
      this._timers.set(label, start);
      return start;
    },

    /**
     * End timer and return duration
     * @param {string} label - Timer identifier
     * @returns {number|null} Duration in ms
     */
    end(label) {
      const start = this._timers.get(label);
      if (start === undefined) {
        if (Debug.isEnabled()) {
          console.warn(`[monitor:timing] Timer "${label}" not found`);
        }
        return null;
      }

      const duration = performance.now() - start;
      this._timers.delete(label);

      if (!this._history.has(label)) {
        this._history.set(label, []);
      }
      const hist = this._history.get(label);
      hist.push(duration);
      if (hist.length > this._maxHistory) {
        hist.shift();
      }

      if (Debug.isEnabled()) {
        console.log(`[monitor:timing] ${label}: ${duration.toFixed(2)} ms`);
      }

      return duration;
    },

    /**
     * Wrap async function with timing
     * @param {string} label - Timer identifier
     * @param {Function} fn - Async function to measure
     * @returns {Promise<*>} Function result
     */
    async measure(label, fn) {
      this.start(label);
      try {
        const result = await fn();
        this.end(label);
        return result;
      } catch (error) {
        this.end(label);
        throw error;
      }
    },

    /**
     * Get average timing for a label
     * @param {string} label
     * @returns {number|null} Average duration in ms
     */
    average(label) {
      const hist = this._history.get(label);
      if (!hist || hist.length === 0) return null;
      return hist.reduce((a, b) => a + b, 0) / hist.length;
    },

    /**
     * Get timing statistics for a label
     * @param {string} label
     * @returns {Object|null}
     */
    stats(label) {
      const hist = this._history.get(label);
      if (!hist || hist.length === 0) return null;

      return {
        label,
        count: hist.length,
        min: Math.min(...hist),
        max: Math.max(...hist),
        avg: hist.reduce((a, b) => a + b, 0) / hist.length,
        recent: hist.slice(-5)
      };
    },

    /**
     * Get all timing statistics
     * @returns {Array}
     */
    allStats() {
      const result = [];
      for (const label of this._history.keys()) {
        result.push(this.stats(label));
      }
      return result;
    },

    /**
     * Clear all timing data
     */
    clear() {
      this._timers.clear();
      this._history.clear();
    }
  };

  // ============ LeakDetector ============
  // Track Sets/Maps for potential memory leaks
  const LeakDetector = {
    _tracked: new Map(),
    _snapshots: new Map(),
    _thresholds: {
      default: 100,
      downloadingVideos: 50,
      downloadingPosts: 50,
      processedVideos: 500,
      processedPosts: 500
    },
    _growthWarningRatio: 1.5, // 50% growth triggers warning

    /**
     * Register a Set or Map to watch
     * @param {string} name - Collection identifier
     * @param {Set|Map} collection - Collection to monitor
     * @param {number} [threshold] - Custom threshold
     */
    register(name, collection, threshold) {
      if (!(collection instanceof Set || collection instanceof Map)) {
        console.warn(`[monitor:leak] "${name}" is not a Set or Map`);
        return;
      }

      const limit = threshold || this._thresholds[name] || this._thresholds.default;
      this._tracked.set(name, { ref: collection, threshold: limit });
      this._snapshots.set(name, [collection.size]);

      if (Debug.isEnabled()) {
        console.log(`[monitor:leak] Registered: ${name} (threshold: ${limit})`);
      }
    },

    /**
     * Unregister a collection
     * @param {string} name
     */
    unregister(name) {
      this._tracked.delete(name);
      this._snapshots.delete(name);
    },

    /**
     * Check all tracked collections for issues
     * @returns {Array} Array of warnings
     */
    check() {
      const warnings = [];

      for (const [name, data] of this._tracked) {
        const collection = data.ref;
        if (!collection) continue;

        // WeakSet/WeakMap don't have size
        if (typeof collection.size !== 'number') continue;

        const size = collection.size;
        const history = this._snapshots.get(name) || [];
        history.push(size);

        if (history.length > 20) {
          history.shift();
        }
        this._snapshots.set(name, history);

        // Check absolute threshold
        if (size > data.threshold) {
          const warning = {
            name,
            type: 'threshold',
            size,
            threshold: data.threshold,
            message: `${name} has ${size} entries (threshold: ${data.threshold})`
          };
          warnings.push(warning);
          console.warn(`[monitor:leak] THRESHOLD: ${warning.message}`);
        }

        // Check growth trend
        if (history.length >= 5) {
          const oldest = history[0];
          const newest = history[history.length - 1];

          if (oldest > 0 && newest / oldest >= this._growthWarningRatio) {
            const growthPct = ((newest / oldest - 1) * 100).toFixed(1);
            const warning = {
              name,
              type: 'growth',
              size: newest,
              growth: growthPct + '%',
              history: [...history],
              message: `${name} growing: ${oldest} -> ${newest} (+${growthPct}%)`
            };
            warnings.push(warning);

            if (Debug.isEnabled()) {
              console.warn(`[monitor:leak] GROWTH: ${warning.message}`);
            }
          }
        }

        if (Debug.isEnabled()) {
          console.log(`[monitor:leak] ${name}: ${size} items`);
        }
      }

      return warnings;
    },

    /**
     * Get sizes of all tracked collections
     * @returns {Object}
     */
    report() {
      const result = {};
      for (const [name, data] of this._tracked) {
        const collection = data.ref;
        if (collection && typeof collection.size === 'number') {
          result[name] = {
            size: collection.size,
            threshold: data.threshold,
            percentUsed: Math.round((collection.size / data.threshold) * 100),
            history: this._snapshots.get(name) || []
          };
        }
      }
      return result;
    },

    /**
     * Clear all tracking
     */
    clear() {
      this._tracked.clear();
      this._snapshots.clear();
    }
  };

  // ============ Metrics ============
  // Count events, record timings, track gauges
  const Metrics = {
    _counters: new Map(),
    _timings: new Map(),
    _gauges: new Map(),
    _maxTimingHistory: 100,

    /**
     * Increment a counter
     * @param {string} name - Counter name
     * @param {number} delta - Amount to add (default 1)
     */
    increment(name, delta = 1) {
      const current = this._counters.get(name) || 0;
      this._counters.set(name, current + delta);

      if (Debug.isEnabled()) {
        console.log(`[monitor:metric] ${name}: ${current + delta}`);
      }
    },

    /**
     * Record a timing measurement
     * @param {string} name - Timing name
     * @param {number} ms - Duration in milliseconds
     */
    timing(name, ms) {
      if (!this._timings.has(name)) {
        this._timings.set(name, []);
      }
      const history = this._timings.get(name);
      history.push({ value: ms, timestamp: Date.now() });

      if (history.length > this._maxTimingHistory) {
        history.shift();
      }

      if (Debug.isEnabled()) {
        console.log(`[monitor:timing] ${name}: ${ms.toFixed(2)}ms`);
      }
    },

    /**
     * Set a gauge value (point-in-time measurement)
     * @param {string} name - Gauge name
     * @param {number} value - Current value
     */
    gauge(name, value) {
      this._gauges.set(name, {
        value,
        timestamp: Date.now()
      });
    },

    /**
     * Get all metrics as object
     * @returns {Object}
     */
    report() {
      const counters = {};
      for (const [name, value] of this._counters) {
        counters[name] = value;
      }

      const timings = {};
      for (const [name, history] of this._timings) {
        if (history.length === 0) continue;
        const values = history.map(h => h.value);
        timings[name] = {
          count: values.length,
          min: Math.min(...values),
          max: Math.max(...values),
          avg: values.reduce((a, b) => a + b, 0) / values.length,
          last: values[values.length - 1]
        };
      }

      const gauges = {};
      for (const [name, data] of this._gauges) {
        gauges[name] = data;
      }

      return {
        counters,
        timings,
        gauges,
        collectedAt: Date.now()
      };
    },

    /**
     * Reset all metrics
     */
    reset() {
      this._counters.clear();
      this._timings.clear();
      this._gauges.clear();
    },

    /**
     * Persist metrics to storage
     */
    async save() {
      try {
        const report = this.report();
        if (typeof chrome !== 'undefined' && chrome.storage && chrome.storage.local) {
          await chrome.storage.local.set({ [METRICS_STORAGE_KEY]: report });
        } else {
          localStorage.setItem(METRICS_STORAGE_KEY, JSON.stringify(report));
        }
      } catch (e) {
        // Storage not available
      }
    },

    /**
     * Load persisted metrics
     */
    async load() {
      try {
        let data = null;
        if (typeof chrome !== 'undefined' && chrome.storage && chrome.storage.local) {
          const result = await chrome.storage.local.get(METRICS_STORAGE_KEY);
          data = result[METRICS_STORAGE_KEY];
        } else {
          const stored = localStorage.getItem(METRICS_STORAGE_KEY);
          data = stored ? JSON.parse(stored) : null;
        }

        if (data && data.counters) {
          for (const [name, value] of Object.entries(data.counters)) {
            this._counters.set(name, value);
          }
        }
      } catch (e) {
        // Storage or parse error
      }
    }
  };

  // ============ Public API ============
  return {
    Memory,
    Timing,
    LeakDetector,
    Debug,
    Metrics,

    /**
     * Initialize monitor (load persisted state)
     */
    async init() {
      await Debug.load();
      await Metrics.load();

      if (Debug.isEnabled()) {
        console.log('[monitor] Initialized - debug mode ON');
      }
    },

    /**
     * Quick status dump for console debugging
     * @returns {Object}
     */
    status() {
      return {
        debug: Debug.isEnabled(),
        memory: Memory.snapshot(),
        memoryGrowth: Memory.getGrowth(),
        leaks: LeakDetector.report(),
        timings: Timing.allStats(),
        metrics: Metrics.report()
      };
    },

    /**
     * Print formatted status report to console
     */
    logReport() {
      const report = this.status();
      console.group('[monitor] Full Report');
      console.log('Debug mode:', report.debug);

      if (report.memory && report.memory.heap) {
        console.log('Memory:', (report.memory.heap / 1024 / 1024).toFixed(2), 'MB');
      }

      if (report.memoryGrowth) {
        console.log('Memory growth:', report.memoryGrowth);
      }

      console.log('Leak tracking:');
      console.table(report.leaks);

      console.log('Timing stats:');
      console.table(report.timings);

      console.log('Metrics:', report.metrics);
      console.groupEnd();

      return report;
    }
  };
})();

// Attach to window for console access
if (typeof window !== 'undefined') {
  window.__archiver_monitor = Monitor;
  // Legacy alias for backwards compatibility
  window.ArchiverMonitor = Monitor;
}

// Export for ES modules if supported
