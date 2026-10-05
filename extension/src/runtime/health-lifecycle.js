/** Serialize overlapping probes so an older failure cannot overwrite success. */
export function singleFlight(operation) {
  let inFlight = null;
  return (...args) => {
    if (inFlight) return inFlight;
    const run = Promise.resolve().then(() => operation(...args));
    inFlight = run.finally(() => {
      if (inFlight === wrapped) inFlight = null;
    });
    const wrapped = inFlight;
    return wrapped;
  };
}

/** Refuse a probe whose endpoint changed after its final network await. */
export function isCurrentHealthProbe(probe, currentEndpointGeneration) {
  return Boolean(
    probe
    && probe.stale !== true
    && probe.endpointGeneration === currentEndpointGeneration
  );
}

/** Keep startup, outage, and reconnection semantics independent of booleans. */
export class HealthLifecycle {
  constructor({ downNotificationThreshold = 2, snapshot = null } = {}) {
    this.state = 'unknown';
    this.hasBeenAvailable = false;
    this.consecutiveFailures = 0;
    this.downNotificationThreshold = downNotificationThreshold;
    this.downNotificationSent = false;
    if (snapshot) this.restore(snapshot);
  }

  restore(snapshot) {
    if (!snapshot || !['unknown', 'up', 'down'].includes(snapshot.state)) return;
    this.state = snapshot.state;
    this.hasBeenAvailable = snapshot.hasBeenAvailable === true;
    this.consecutiveFailures = Number.isInteger(snapshot.consecutiveFailures)
      ? Math.max(0, snapshot.consecutiveFailures)
      : 0;
    this.downNotificationSent = snapshot.downNotificationSent === true;
  }

  snapshot() {
    return {
      state: this.state,
      hasBeenAvailable: this.hasBeenAvailable,
      consecutiveFailures: this.consecutiveFailures,
      downNotificationSent: this.downNotificationSent
    };
  }

  record(available) {
    const previousState = this.state;
    if (available) {
      const transition = this.hasBeenAvailable && previousState === 'down'
        ? 'reconnected'
        : this.hasBeenAvailable ? 'steady-up' : 'initial-up';
      this.state = 'up';
      this.hasBeenAvailable = true;
      this.consecutiveFailures = 0;
      this.downNotificationSent = false;
      return { available: true, transition, notifyDown: false };
    }

    this.state = 'down';
    this.consecutiveFailures += 1;
    const notifyDown = !this.downNotificationSent
      && this.consecutiveFailures >= this.downNotificationThreshold;
    if (notifyDown) this.downNotificationSent = true;
    return {
      available: false,
      transition: this.hasBeenAvailable ? 'outage' : 'initial-down',
      notifyDown,
      consecutiveFailures: this.consecutiveFailures
    };
  }
}
