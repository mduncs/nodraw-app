const CAPTURE_INBOX_KEY = 'captureInboxV1';
// Keep the inbox below the smallest common browser.storage.local allowance
// while leaving headroom for active jobs, settings, and failure diagnostics.
// Capacity is fail-closed: an oversized mutation is rejected without evicting
// any existing capture or stripping screenshot context.
const CAPTURE_INBOX_BUDGET_BYTES = 4 * 1024 * 1024;
const CAPTURE_STATE_RANK = Object.freeze({
  draft: 0,
  submitting: 0,
  queued: 0,
  accepted: 1,
  processing: 1,
  duplicate: 1,
  stalled: 2,
  failed: 2,
  saved: 3,
  completed: 3
});

// browser.storage.local has no compare-and-swap operation. Keep every inbox
// read/modify/write in one module-wide queue so multiple CaptureStore instances
// in the same extension context cannot overwrite one another with stale arrays.
const storageQueues = new WeakMap();

export class CaptureStoreCapacityError extends Error {
  constructor(requiredBytes, budgetBytes) {
    const formatSize = bytes => {
      if (bytes >= 1024 * 1024) {
        const value = bytes / (1024 * 1024);
        return `${Number.isInteger(value) ? value.toFixed(0) : value.toFixed(2)} MiB`;
      }
      return `${Math.ceil(bytes / 1024)} KiB`;
    };
    super(
      `Capture inbox would need ${formatSize(requiredBytes)}, above its ${formatSize(budgetBytes)} safe storage budget. `
      + 'No capture was evicted and the requested inbox update was not written.'
    );
    this.name = 'CaptureStoreCapacityError';
    this.code = 'capture_inbox_capacity';
    this.requiredBytes = requiredBytes;
    this.budgetBytes = budgetBytes;
  }
}

function encodedBytes(value) {
  return new TextEncoder().encode(JSON.stringify(value)).byteLength;
}

function mergeCaptureUser(incoming = {}, canonical = {}) {
  const tags = [];
  const seen = new Set();
  for (const tag of [...(canonical.tags || []), ...(incoming.tags || [])]) {
    const value = typeof tag === 'string' ? tag.trim() : '';
    if (!value || seen.has(value)) continue;
    seen.add(value);
    tags.push(value);
  }
  return {
    ...incoming,
    ...canonical,
    tags,
    note: canonical.note || incoming.note || ''
  };
}

function mergeCanonicalIntent(incoming = {}, canonical = {}) {
  const modeRank = { quick: 0, text: 1, full: 2 };
  const incomingMode = incoming.options?.saveMode || 'full';
  const canonicalMode = canonical.options?.saveMode || 'full';
  const saveMode = (modeRank[incomingMode] ?? 1) > (modeRank[canonicalMode] ?? 1)
    ? incomingMode
    : canonicalMode;
  return {
    ...incoming,
    ...canonical,
    user: mergeCaptureUser(incoming.user, canonical.user),
    options: {
      ...(canonical.options || {}),
      ...(incoming.options || {}),
      saveMode,
      screenshot: incoming.options?.screenshot || canonical.options?.screenshot || '',
      siteData: {
        ...(canonical.options?.siteData || {}),
        ...(incoming.options?.siteData || {})
      },
      download: {
        ...(canonical.options?.download || {}),
        ...(incoming.options?.download || {})
      }
    }
  };
}

function incomingStateAdvancesTruth(canonicalState, incomingState) {
  if (!canonicalState) return true;
  const canonicalRank = CAPTURE_STATE_RANK[canonicalState] ?? 0;
  const incomingRank = CAPTURE_STATE_RANK[incomingState] ?? 0;
  return incomingRank > canonicalRank;
}

function firstOwnedValue(objects, key, fallback = null) {
  for (const object of objects) {
    if (object && Object.prototype.hasOwnProperty.call(object, key) && object[key] !== undefined) {
      return object[key];
    }
  }
  return fallback;
}

function withTransitionOutcome(record, applied) {
  Object.defineProperty(record, 'transitionApplied', {
    value: applied,
    enumerable: false,
    configurable: true
  });
  return record;
}

async function withStorageLock(storage, operation) {
  const previous = storageQueues.get(storage) || Promise.resolve();
  const run = previous.catch(() => {}).then(operation);
  const tail = run.then(() => undefined, () => undefined);
  storageQueues.set(storage, tail);

  try {
    return await run;
  } finally {
    if (storageQueues.get(storage) === tail) {
      storageQueues.delete(storage);
    }
  }
}

export class CaptureStore {
  constructor(storageArea, { budgetBytes = CAPTURE_INBOX_BUDGET_BYTES } = {}) {
    this.storage = storageArea;
    this.budgetBytes = budgetBytes;
  }

  async _readRecords() {
    const result = await this.storage.get({ [CAPTURE_INBOX_KEY]: [] });
    const stored = result[CAPTURE_INBOX_KEY];
    if (!Array.isArray(stored)) return [];
    return stored;
  }

  async list() {
    return withStorageLock(this.storage, () => this._readRecords());
  }

  async _writeRecords(previousRecords, nextRecords) {
    const previousBytes = encodedBytes(previousRecords);
    const requiredBytes = encodedBytes(nextRecords);
    if (requiredBytes > this.budgetBytes && requiredBytes > previousBytes) {
      throw new CaptureStoreCapacityError(requiredBytes, this.budgetBytes);
    }
    await this.storage.set({ [CAPTURE_INBOX_KEY]: nextRecords });
  }

  async get(captureId) {
    return withStorageLock(this.storage, async () => (
      (await this._readRecords()).find(record => record?.captureId === captureId) || null
    ));
  }

  async put(intent, state = 'draft') {
    return withStorageLock(this.storage, async () => {
      const records = await this._readRecords();
      const previousRecords = records.slice();
      const existingIndex = records.findIndex(record => record?.captureId === intent.captureId);
      const existing = existingIndex >= 0 ? records[existingIndex] : {};
      const record = {
        ...existing,
        captureId: intent.captureId,
        fingerprint: intent.fingerprint,
        intent,
        state,
        attempts: existing.attempts || 0,
        updatedAt: new Date().toISOString()
      };
      if (existingIndex >= 0) records.splice(existingIndex, 1);
      records.unshift(record);
      await this._writeRecords(previousRecords, records);
      return record;
    });
  }

  async transition(captureId, state, detail = {}, { onlyIfStates = null } = {}) {
    return withStorageLock(this.storage, async () => {
      const records = await this._readRecords();
      const previousRecords = records.slice();
      const index = records.findIndex(record => record?.captureId === captureId);
      if (index < 0) return null;
      if (Array.isArray(onlyIfStates) && !onlyIfStates.includes(records[index].state)) {
        return withTransitionOutcome(records[index], false);
      }
      records[index] = {
        ...records[index],
        ...detail,
        state,
        attempts: detail.incrementAttempt
          ? (records[index].attempts || 0) + 1
          : (records[index].attempts || 0),
        updatedAt: new Date().toISOString()
      };
      delete records[index].incrementAttempt;
      await this._writeRecords(previousRecords, records);
      return Array.isArray(onlyIfStates)
        ? withTransitionOutcome(records[index], true)
        : records[index];
    });
  }

  async rekey(originalCaptureId, intent, state, detail = {}) {
    return withStorageLock(this.storage, async () => {
      const records = await this._readRecords();
      const original = records.find(record => record?.captureId === originalCaptureId) || {};
      const destination = records.find(record => record?.captureId === intent.captureId) || null;
      const trackingRepairNeeded = destination
        && state === 'queued'
        && detail.receipt?.trackingPending === true
        && ['draft', 'submitting', 'queued', 'accepted', 'processing', 'duplicate']
          .includes(destination.state);
      const useIncomingTruth = destination
        ? trackingRepairNeeded || incomingStateAdvancesTruth(destination.state, state)
        : true;
      const resolvedState = useIncomingTruth ? state : destination?.state;
      const resolvedNeedsRetryPayload = ['draft', 'submitting', 'queued', 'failed', 'stalled']
        .includes(resolvedState);
      const mergeIntent = resolvedNeedsRetryPayload && detail.retryIntent
        ? detail.retryIntent
        : intent;
      const attempts = Math.max(original.attempts || 0, destination?.attempts || 0)
        + (detail.incrementAttempt ? 1 : 0);

      // Collision precedence:
      // - the existing canonical record owns durable state, receipt/job/file
      //   truth, and non-empty note values;
      // - tags are unioned with canonical ordering;
      // - an incoming server-confirmed state replaces canonical state only
      //   when it advances local -> accepted -> retryable terminal -> saved;
      //   equal-authority collisions keep the established canonical values.
      const record = destination ? {
        ...original,
        ...detail,
        ...destination,
        captureId: intent.captureId,
        fingerprint: destination.fingerprint || intent.fingerprint,
        intent: mergeCanonicalIntent(mergeIntent, destination.intent),
        state: resolvedState,
        jobId: firstOwnedValue(
          useIncomingTruth ? [detail, original, destination] : [destination, detail, original],
          'jobId'
        ),
        receipt: firstOwnedValue(
          useIncomingTruth ? [detail, original, destination] : [destination, detail, original],
          'receipt'
        ),
        error: firstOwnedValue(
          useIncomingTruth ? [detail, original, destination] : [destination, detail, original],
          'error'
        ),
        retryable: firstOwnedValue(
          useIncomingTruth ? [detail, original, destination] : [destination, detail, original],
          'retryable',
          false
        ),
        filePath: firstOwnedValue(
          useIncomingTruth ? [detail, original, destination] : [destination, detail, original],
          'filePath'
        ),
        attempts,
        updatedAt: new Date().toISOString()
      } : {
        ...original,
        ...detail,
        captureId: intent.captureId,
        fingerprint: intent.fingerprint,
        intent,
        state,
        attempts,
        updatedAt: new Date().toISOString()
      };
      if (!resolvedNeedsRetryPayload && record.intent?.options) {
        record.intent = {
          ...record.intent,
          options: { ...record.intent.options, screenshot: '' }
        };
      }
      delete record.incrementAttempt;
      delete record.retryIntent;
      const remaining = records.filter(candidate => (
        candidate?.captureId !== originalCaptureId && candidate?.captureId !== intent.captureId
      ));
      remaining.unshift(record);
      await this._writeRecords(records, remaining);
      return record;
    });
  }

  async updateUser(captureId, user) {
    return withStorageLock(this.storage, async () => {
      const records = await this._readRecords();
      const previousRecords = records.slice();
      const index = records.findIndex(record => record?.captureId === captureId);
      if (index < 0) return null;
      records[index] = {
        ...records[index],
        intent: {
          ...records[index].intent,
          user: { ...(records[index].intent?.user || {}), ...user }
        },
        updatedAt: new Date().toISOString()
      };
      await this._writeRecords(previousRecords, records);
      return records[index];
    });
  }

  async _updateMetadata(captureId, update) {
    return withStorageLock(this.storage, async () => {
      const records = await this._readRecords();
      const index = records.findIndex(record => record?.captureId === captureId);
      if (index < 0) throw new Error('Capture is not in the durable inbox');
      const record = structuredClone(records[index]);
      record.metadata ||= { revision: 0, draft: {}, pending: null, receipt: null };
      update(record.metadata, record);
      record.updatedAt = new Date().toISOString();
      const next = records.slice();
      next[index] = record;
      await this._writeRecords(records, next);
      return record;
    });
  }

  async stageMetadata(captureId, fields) {
    return this._updateMetadata(captureId, (metadata, record) => {
      metadata.revision += 1;
      metadata.draft = { ...metadata.draft, ...fields };
      metadata.error = null;
      record.intent.user = { ...(record.intent.user || {}), ...fields };
    });
  }

  async beginMetadata(captureId) {
    return this._updateMetadata(captureId, metadata => {
      if (!metadata.pending && Object.keys(metadata.draft).length) {
        metadata.pending = {
          mutationId: crypto.randomUUID(), fields: metadata.draft, revision: metadata.revision
        };
        metadata.draft = {};
      }
    });
  }

  async acknowledgeMetadata(captureId, mutationId, receipt) {
    return this._updateMetadata(captureId, (metadata, record) => {
      // A delayed ACK can never consume a newer staged/dispatching edit.
      if (mutationId && metadata.pending?.mutationId !== mutationId) return;
      if (mutationId) metadata.pending = null;
      metadata.receipt = receipt;
      metadata.error = receipt?.metadataError || null;
      record.receipt = { ...(record.receipt || {}), ...receipt };
    });
  }

  async failMetadata(captureId, error) {
    return this._updateMetadata(captureId, metadata => { metadata.error = error; });
  }

  async dismiss(captureId) {
    return withStorageLock(this.storage, async () => {
      const previousRecords = await this._readRecords();
      const records = previousRecords.filter(record => record?.captureId !== captureId);
      await this._writeRecords(previousRecords, records);
    });
  }
}

export { CAPTURE_INBOX_BUDGET_BYTES, CAPTURE_INBOX_KEY };
