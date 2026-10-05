import assert from 'node:assert/strict';
import test from 'node:test';

import {
  HealthLifecycle,
  isCurrentHealthProbe,
  singleFlight
} from '../../src/runtime/health-lifecycle.js';

test('fresh-worker success is initial availability, not a reconnect', () => {
  const lifecycle = new HealthLifecycle();
  assert.equal(lifecycle.record(true).transition, 'initial-up');
  assert.equal(lifecycle.record(true).transition, 'steady-up');
});

test('non-OK health results count toward one delayed outage notification', () => {
  const lifecycle = new HealthLifecycle({ downNotificationThreshold: 2 });
  lifecycle.record(true);
  const first = lifecycle.record(false);
  const second = lifecycle.record(false);
  const third = lifecycle.record(false);

  assert.equal(first.notifyDown, false);
  assert.equal(second.notifyDown, true);
  assert.equal(third.notifyDown, false);
  assert.equal(lifecycle.record(true).transition, 'reconnected');
});

test('initial unavailability reports one delayed outage without masquerading as a reconnect', () => {
  const lifecycle = new HealthLifecycle({ downNotificationThreshold: 2 });
  const first = lifecycle.record(false);
  const second = lifecycle.record(false);
  const third = lifecycle.record(false);

  assert.equal(first.transition, 'initial-down');
  assert.equal(first.notifyDown, false);
  assert.equal(second.transition, 'initial-down');
  assert.equal(second.notifyDown, true);
  assert.equal(third.notifyDown, false);
  assert.equal(lifecycle.record(true).transition, 'initial-up');
});

test('persisted health state distinguishes a fresh worker from a reconnect', () => {
  const prior = new HealthLifecycle();
  prior.record(true);
  const freshWhileHealthy = new HealthLifecycle({ snapshot: prior.snapshot() });
  assert.equal(freshWhileHealthy.record(true).transition, 'steady-up');

  prior.record(false);
  const freshAfterOutage = new HealthLifecycle({ snapshot: prior.snapshot() });
  assert.equal(freshAfterOutage.record(true).transition, 'reconnected');
});

test('singleFlight shares one probe and cannot apply stale overlapping results', async () => {
  let probes = 0;
  let resolveProbe;
  const check = singleFlight(async () => {
    probes += 1;
    if (probes > 1) return { available: false };
    return new Promise(resolve => { resolveProbe = resolve; });
  });

  const first = check();
  const second = check();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(probes, 1);
  resolveProbe({ available: true });
  assert.deepEqual(await first, { available: true });
  assert.deepEqual(await second, { available: true });

  assert.deepEqual(await check(), { available: false });
  assert.equal(probes, 2);
});

test('a port-change generation invalidates a completed old-endpoint probe', () => {
  const completedOldProbe = {
    available: true,
    stale: false,
    endpointGeneration: 4
  };

  assert.equal(isCurrentHealthProbe(completedOldProbe, 4), true);
  assert.equal(isCurrentHealthProbe(completedOldProbe, 5), false);
  assert.equal(isCurrentHealthProbe({ ...completedOldProbe, stale: true }, 4), false);
});
