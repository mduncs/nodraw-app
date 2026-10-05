/**
 * discover.js -- Browser extension service discovery client.
 *
 * Discovers services via the port discovery service on localhost:8800.
 * Browser extensions can't read local files, so this is the bridge.
 *
 * Loaded before config.js and background.js in manifest background scripts.
 */

import {
  DEFAULT_SERVER_ENDPOINT,
  resolveServerEndpoint
} from '../runtime/endpoint-bootstrap.js';

const DISCOVERY_PORT = 8800;
const DISCOVERY_URL = `http://localhost:${DISCOVERY_PORT}`;
const DEFAULT_SERVICE = "org.nodraw.download-server";
const LEGACY_SERVICES = ["org.mediaviewer.download-server"];
const SERVICE_NAME_RE =
  /^[a-z][a-z0-9]*(?:\.[a-z0-9][a-z0-9-]*)+(?:@[a-z0-9][a-z0-9-]*)?$/;

// Port cache: services don't change ports until restart, 60s is conservative.
const _portCache = new Map(); // service -> { port, expires }
const CACHE_TTL = 60_000;

/**
 * Discover a service's port via the discovery service.
 * Caches results for CACHE_TTL ms.
 *
 * @param {string} service - Service name (org.project.service[@instance])
 * @returns {Promise<number>} The port number
 * @throws {Error} If service not found and no cache available
 */
export async function discoverPort(service = DEFAULT_SERVICE) {
  if (!SERVICE_NAME_RE.test(service)) {
    throw new Error(`Invalid service name: ${service}`);
  }

  const cached = _portCache.get(service);
  if (cached && Date.now() < cached.expires) {
    return cached.port;
  }

  try {
    const resp = await fetch(`${DISCOVERY_URL}/discover/${encodeURIComponent(service)}`, {
      signal: AbortSignal.timeout(3000),
    });

    if (resp.ok) {
      const data = await resp.json();
      _portCache.set(service, {
        port: data.port,
        expires: Date.now() + CACHE_TTL,
      });
      return data.port;
    }

    if (resp.status === 503) {
      _portCache.delete(service);
      throw new Error(`Service '${service}' is not running`);
    }

    if (resp.status === 404) {
      throw new Error(`Service '${service}' not registered`);
    }
  } catch (err) {
    if (cached) {
      console.warn(`[discover] Discovery unreachable, using cached port for ${service}`);
      return cached.port;
    }
    throw new Error(`Cannot discover '${service}': ${err.message}`);
  }

  throw new Error(`Service '${service}' not found`);
}

/**
 * Get the full localhost URL for the media server.
 * Drop-in replacement for the old getServerURL().
 * Tries: explicit manual override → discovery → hardcoded fallback.
 */
export async function getServerURL({
  storageArea = null,
  discoverServicePort = discoverPort
} = {}) {
  const resolvedStorage = storageArea || (() => {
    const b = (typeof browser !== 'undefined') ? browser : chrome;
    return b.storage.local;
  })();
  return resolveServerEndpoint({
    readManualPort: async () => {
      const result = await resolvedStorage.get({ port: null });
      return result.port;
    },
    discoverServicePort,
    services: [DEFAULT_SERVICE, ...LEGACY_SERVICES],
    fallbackEndpoint: DEFAULT_SERVER_ENDPOINT
  });
}

/** Invalidate the cached port so next call re-discovers. */
export function invalidateDiscoveryCache(service = DEFAULT_SERVICE) {
  _portCache.delete(service);
}

const discoverGlobal = typeof globalThis !== 'undefined' ? globalThis : window;
discoverGlobal.discoverPort = discoverPort;
discoverGlobal.getServerURL = getServerURL;
discoverGlobal.invalidateDiscoveryCache = invalidateDiscoveryCache;
