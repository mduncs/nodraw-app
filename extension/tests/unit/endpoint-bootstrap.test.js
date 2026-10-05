import assert from 'node:assert/strict';
import test from 'node:test';

import { getServerURL } from '../../src/background/discover.js';
import {
  createEndpointBootstrap,
  DEFAULT_SERVER_ENDPOINT,
  isManualPortStorageChange,
  resolveServerEndpoint
} from '../../src/runtime/endpoint-bootstrap.js';

test('an explicit manual port wins before service discovery', async () => {
  let discoveries = 0;
  const endpoint = await getServerURL({
    storageArea: {
      get: async () => ({ port: 65055 })
    },
    discoverServicePort: async () => {
      discoveries += 1;
      return 65056;
    }
  });

  assert.equal(endpoint, 'http://localhost:65055');
  assert.equal(discoveries, 0);
});

test('missing manual routing uses discovery and then the default fallback', async () => {
  const discovered = await resolveServerEndpoint({
    readManualPort: async () => null,
    discoverServicePort: async service => service === 'primary' ? 65056 : 65057,
    services: ['primary', 'legacy']
  });
  assert.equal(discovered, 'http://localhost:65056');

  const fallback = await resolveServerEndpoint({
    readManualPort: async () => undefined,
    discoverServicePort: async () => { throw new Error('discovery offline'); },
    services: ['primary', 'legacy']
  });
  assert.equal(fallback, DEFAULT_SERVER_ENDPOINT);
});

test('healthy default cannot win while alternate discovery is bootstrapping', async () => {
  let resolveDiscovery;
  let resolutions = 0;
  const requests = [];
  const bootstrap = createEndpointBootstrap({
    resolveEndpoint: async () => {
      resolutions += 1;
      return new Promise(resolve => { resolveDiscovery = resolve; });
    },
    applyEndpoint: () => {},
    fallbackEndpoint: DEFAULT_SERVER_ENDPOINT,
    timeoutMs: 1000
  });
  const probe = async () => {
    const endpoint = await bootstrap.ensure();
    const url = `${endpoint}/health`;
    requests.push(url);
    return url === `${DEFAULT_SERVER_ENDPOINT}/health`;
  };

  const first = probe();
  const second = probe();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(resolutions, 1, 'concurrent startup checks share one resolver');
  assert.deepEqual(requests, [], 'no placeholder request is sent before bootstrap');

  resolveDiscovery('http://localhost:65056');
  assert.deepEqual(await Promise.all([first, second]), [false, false]);
  assert.deepEqual(requests, [
    'http://localhost:65056/health',
    'http://localhost:65056/health'
  ]);
});

test('a hung resolver reaches the default through the bounded fail-safe', async () => {
  const applied = [];
  const bootstrap = createEndpointBootstrap({
    resolveEndpoint: () => new Promise(() => {}),
    applyEndpoint: endpoint => applied.push(endpoint),
    fallbackEndpoint: DEFAULT_SERVER_ENDPOINT,
    timeoutMs: 5
  });

  assert.equal(await bootstrap.ensure(), DEFAULT_SERVER_ENDPOINT);
  assert.deepEqual(applied, [DEFAULT_SERVER_ENDPOINT]);
});

test('refresh invalidates a stale resolver and all waiters join the new generation', async () => {
  let firstResolution;
  let calls = 0;
  let invalidations = 0;
  const applied = [];
  const bootstrap = createEndpointBootstrap({
    resolveEndpoint: async () => {
      calls += 1;
      if (calls === 1) {
        return new Promise(resolve => { firstResolution = resolve; });
      }
      return 'http://localhost:65058';
    },
    applyEndpoint: endpoint => applied.push(endpoint),
    invalidateEndpoint: () => { invalidations += 1; },
    timeoutMs: 1000
  });

  const staleWaiter = bootstrap.ensure();
  await new Promise(resolve => setImmediate(resolve));
  const refreshed = bootstrap.refresh();
  firstResolution('http://localhost:8847');

  assert.equal(await staleWaiter, 'http://localhost:65058');
  assert.equal(await refreshed, 'http://localhost:65058');
  assert.equal(calls, 2);
  assert.equal(invalidations, 1);
  assert.deepEqual(applied, ['http://localhost:65058']);
});

test('manual-port change detection includes setting and removal', () => {
  assert.equal(isManualPortStorageChange({
    port: { oldValue: null, newValue: 65056 }
  }, 'local'), true);
  assert.equal(isManualPortStorageChange({
    port: { oldValue: 65056, newValue: undefined }
  }, 'local'), true);
  assert.equal(isManualPortStorageChange({ unrelated: { newValue: true } }, 'local'), false);
  assert.equal(isManualPortStorageChange({ port: { newValue: 65056 } }, 'sync'), false);
});
