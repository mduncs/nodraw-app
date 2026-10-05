const DEFAULT_SERVER_ENDPOINT = 'http://localhost:8847';

function normalizedPort(value) {
  if (typeof value === 'string' && /^\d+$/.test(value.trim())) {
    value = Number(value);
  }
  return Number.isInteger(value) && value >= 1024 && value <= 65535
    ? value
    : null;
}

/** Resolve explicit user routing before service discovery and its fallback. */
export async function resolveServerEndpoint({
  readManualPort,
  discoverServicePort,
  services,
  fallbackEndpoint = DEFAULT_SERVER_ENDPOINT
}) {
  try {
    const manualPort = normalizedPort(await readManualPort());
    if (manualPort !== null) return `http://localhost:${manualPort}`;
  } catch {
    // Storage can be unavailable during an MV3 cold start. Discovery remains a
    // valid route, and the bounded bootstrap still has a final fallback.
  }

  for (const service of services) {
    try {
      const discoveredPort = normalizedPort(await discoverServicePort(service));
      if (discoveredPort !== null) return `http://localhost:${discoveredPort}`;
    } catch {
      // Try the remaining compatibility service names.
    }
  }

  return fallbackEndpoint;
}

/**
 * A generation-aware, single-flight endpoint barrier. No caller can observe
 * the fallback placeholder while discovery/manual routing is still pending.
 */
export function createEndpointBootstrap({
  resolveEndpoint,
  applyEndpoint,
  invalidateEndpoint = null,
  fallbackEndpoint = DEFAULT_SERVER_ENDPOINT,
  timeoutMs = 7000
}) {
  let generation = 0;
  let resolvedEndpoint = null;
  let inFlight = null;

  async function resolveBounded() {
    let timeoutId;
    const timeout = new Promise((_, reject) => {
      timeoutId = setTimeout(() => {
        const error = new Error(`Server endpoint bootstrap timed out after ${timeoutMs}ms`);
        error.name = 'TimeoutError';
        reject(error);
      }, timeoutMs);
    });
    try {
      const endpoint = await Promise.race([
        Promise.resolve().then(resolveEndpoint),
        timeout
      ]);
      return typeof endpoint === 'string' && endpoint.length > 0
        ? endpoint
        : fallbackEndpoint;
    } catch {
      return fallbackEndpoint;
    } finally {
      clearTimeout(timeoutId);
    }
  }

  function ensure() {
    if (resolvedEndpoint) return Promise.resolve(resolvedEndpoint);
    if (inFlight) return inFlight;

    const requestedGeneration = generation;
    const run = resolveBounded().then(endpoint => {
      if (requestedGeneration !== generation) return ensure();
      resolvedEndpoint = endpoint;
      applyEndpoint(endpoint);
      return endpoint;
    });
    inFlight = run.finally(() => {
      if (inFlight === wrapped) inFlight = null;
    });
    const wrapped = inFlight;
    return wrapped;
  }

  function refresh() {
    generation += 1;
    resolvedEndpoint = null;
    inFlight = null;
    if (invalidateEndpoint) invalidateEndpoint();
    return ensure();
  }

  return { ensure, refresh };
}

/** A removed key still carries a `port` change object with no new value. */
export function isManualPortStorageChange(changes, areaName = 'local') {
  return areaName === 'local'
    && Boolean(changes)
    && Object.prototype.hasOwnProperty.call(changes, 'port');
}

export { DEFAULT_SERVER_ENDPOINT };
