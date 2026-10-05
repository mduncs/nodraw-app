import { createCaptureIntent } from './capture-intent.js';

function withoutScreenshot(intent) {
  return {
    ...intent,
    options: { ...intent.options, screenshot: '' }
  };
}

function errorMessage(error) {
  return error?.message || String(error || 'Unknown error');
}

function durableStorageError(error) {
  return `Capture could not be saved to the durable inbox: ${errorMessage(error)}`;
}

function isQueueableTransportError(error) {
  return error?.code === 'server_offline'
    || error?.name === 'TimeoutError'
    || error instanceof TypeError;
}

function stateForReceipt(receipt = {}) {
  const status = String(receipt.status || '').toLowerCase();
  if (receipt.trackingPending) return 'queued';
  if (status === 'failed') return 'failed';
  if (status === 'stalled') return 'stalled';
  if (status === 'saved' || status === 'completed') return 'saved';
  if (receipt.disposition === 'duplicate') return 'duplicate';
  return 'accepted';
}

function isFailureState(state) {
  return state === 'failed' || state === 'stalled';
}

function isPendingRetryState(state) {
  return state === 'queued' || state === 'submitting';
}

function retainsRetryPayload(state) {
  return isFailureState(state) || isPendingRetryState(state);
}

function terminalReceiptError(receipt, state) {
  if (state === 'queued' && receipt?.trackingError) return receipt.trackingError;
  if (!isFailureState(state)) return null;
  return receipt?.error || `Archive server reported that the capture ${state}`;
}

function receiptResponse(receipt, state, captureId, localWarning = null, stateError = null) {
  const failed = isFailureState(state);
  const pendingRetry = isPendingRetryState(state);
  return {
    success: !failed && !pendingRetry,
    ...(pendingRetry ? { queued: state === 'queued', retryable: true } : {}),
    job_id: receipt?.jobId,
    capture_id: receipt?.captureId || captureId,
    disposition: receipt?.disposition,
    status: state,
    message: receipt?.message,
    ...(failed || pendingRetry ? {
      retryable: true,
      error: stateError || terminalReceiptError(receipt, state) || `Capture is ${state}`
    } : {}),
    ...(localWarning ? { warning: localWarning, storage_error: true } : {})
  };
}

function storedStateResponse(record, captureId) {
  const state = record?.state || 'unknown';
  const failed = isFailureState(state);
  const pendingRetry = isPendingRetryState(state);
  const successful = ['accepted', 'processing', 'saved', 'completed', 'duplicate'].includes(state);
  return {
    success: successful,
    already_resolved: true,
    capture_id: record?.captureId || captureId,
    status: state,
    ...(pendingRetry ? { queued: state === 'queued', retryable: true } : {}),
    ...(failed ? { retryable: true } : {}),
    ...(!successful ? { error: record?.error || `Capture is ${state}` } : {})
  };
}

/**
 * The extension's single capture boundary. Site scripts and browser UI should
 * describe a capture; only this object decides how it is transported.
 */
export class CaptureRuntime {
  constructor({ transport = null, retryTransport = null, patchTransport = null, store = null, onState = null }) {
    this._transport = transport;
    this._retryTransport = retryTransport;
    this._patchTransport = patchTransport;
    this._store = store;
    this._onState = onState;
    this._inFlight = new Set();
    this._metadataPatches = new Map();
  }

  async submit(rawIntent, tab) {
    const intent = createCaptureIntent(rawIntent);
    if (!this._transport || !this._store) {
      throw new Error('CaptureRuntime requires a transport and durable store');
    }
    this._inFlight.add(intent.captureId);

    try {
      // Persist the complete first-attempt payload. In particular, screenshot
      // context must survive an offline first POST so an automatic retry remains
      // semantically equivalent to the user's original capture.
      try {
        await this._store.put(intent, 'submitting');
      } catch (error) {
        const message = durableStorageError(error);
        this._notify(intent, 'failed', { tabId: tab?.id, error: message });
        return {
          success: false,
          queued: false,
          storage_error: true,
          capture_id: intent.captureId,
          error: message
        };
      }

      this._notify(intent, 'saving', { tabId: tab?.id });

      let receipt;
      try {
        receipt = await this._transport(intent, tab);
      } catch (error) {
        const queued = isQueueableTransportError(error);
        const state = queued ? 'queued' : 'failed';
        let stateStorageError = null;
        let stored = null;
        try {
          stored = await this._store.transition(
            intent.captureId,
            state,
            {
              error: errorMessage(error),
              retryable: true,
              incrementAttempt: true
            },
            { onlyIfStates: ['submitting'] }
          );
          if (!stored) throw new Error('capture record disappeared before retry state was recorded');
        } catch (storageError) {
          stateStorageError = durableStorageError(storageError);
        }
        if (!stateStorageError && stored?.transitionApplied === false) {
          this._notify(stored.intent || intent, stored.state, {
            tabId: tab?.id,
            error: stored.error || null
          });
          return storedStateResponse(stored, intent.captureId);
        }
        const failure = stateStorageError
          ? `${errorMessage(error)}; ${stateStorageError}`
          : errorMessage(error);
        const visibleState = stateStorageError ? 'failed' : state;
        this._notify(intent, visibleState, {
          tabId: tab?.id,
          error: failure
        });
        return {
          success: false,
          queued: queued && !stateStorageError,
          storage_error: Boolean(stateStorageError),
          capture_id: intent.captureId,
          error: stateStorageError
            ? failure
            : queued ? `${errorMessage(error)} — saved in capture inbox for retry` : errorMessage(error)
        };
      }

      // A successful transport response is the durable server boundary. Only
      // now may the browser copy discard screenshot payloads for non-retryable
      // states.
      const state = stateForReceipt(receipt);
      const retryableTerminal = retainsRetryPayload(state);
      const receiptError = terminalReceiptError(receipt, state);
      const storedIntent = {
        ...(retryableTerminal ? intent : withoutScreenshot(intent)),
        captureId: receipt.captureId || intent.captureId
      };
      const detail = {
        receipt,
        jobId: receipt.jobId,
        error: receiptError,
        retryable: retryableTerminal,
        incrementAttempt: true
      };
      let persisted = null;
      let localWarning = null;
      try {
        persisted = storedIntent.captureId === intent.captureId
          ? await this._store.transition(
            intent.captureId,
            state,
            { ...detail, intent: storedIntent },
            { onlyIfStates: ['submitting'] }
          )
          : await this._store.rekey(intent.captureId, storedIntent, state, {
            ...detail,
            retryIntent: intent
          });
        if (!persisted) throw new Error('capture record disappeared before acceptance was recorded');
      } catch (error) {
        localWarning = `Server accepted the capture, but its local inbox state could not be updated: ${errorMessage(error)}`;
      }
      const visibleState = persisted?.state || state;
      const visibleIntent = persisted?.intent || storedIntent;
      const visibleError = persisted?.error || receiptError || localWarning;
      this._notify(visibleIntent, visibleState, {
        tabId: tab?.id,
        receipt,
        error: visibleError
      });
      return receiptResponse(
        receipt,
        visibleState,
        storedIntent.captureId,
        localWarning,
        visibleError
      );
    } finally {
      this._inFlight.delete(intent.captureId);
    }
  }

  async retry(captureId, tab = null) {
    if (!this._store) throw new Error('Capture inbox is unavailable');
    if (this._inFlight.has(captureId)) {
      return {
        success: false,
        busy: true,
        capture_id: captureId,
        error: 'Capture is already being submitted'
      };
    }
    this._inFlight.add(captureId);
    try {
      const record = await this._store.get(captureId);
      if (!record) throw new Error('Capture not found');
      const retryableStates = ['failed', 'stalled', 'queued', 'submitting'];
      if (!retryableStates.includes(record.state)) {
        return {
          success: false,
          retryable: false,
          capture_id: captureId,
          status: record.state,
          error: `Capture is already ${record.state || 'in a terminal state'}`
        };
      }
      if (this._retryTransport && record.jobId) {
        try {
          const staged = await this._store.transition(
            captureId,
            'submitting',
            { incrementAttempt: true },
            { onlyIfStates: [record.state] }
          );
          if (!staged) throw new Error('capture record disappeared before retry could start');
          if (staged.transitionApplied === false) {
            return storedStateResponse(staged, captureId);
          }
        } catch (error) {
          const message = durableStorageError(error);
          this._notify(record.intent, 'failed', { tabId: tab?.id, error: message });
          return {
            success: false,
            storage_error: true,
            capture_id: captureId,
            error: message
          };
        }
        this._notify(record.intent, 'saving', { tabId: tab?.id });

        let receipt;
        try {
          receipt = await this._retryTransport(captureId, record.intent, tab);
        } catch (error) {
          const queued = isQueueableTransportError(error);
          const state = queued ? 'queued' : 'failed';
          let stateStorageError = null;
          let stored = null;
          try {
            stored = await this._store.transition(
              captureId,
              state,
              {
                error: errorMessage(error),
                retryable: true
              },
              { onlyIfStates: ['submitting'] }
            );
            if (!stored) throw new Error('capture record disappeared before retry state was recorded');
          } catch (storageError) {
            stateStorageError = durableStorageError(storageError);
          }
          if (!stateStorageError && stored?.transitionApplied === false) {
            this._notify(stored.intent || record.intent, stored.state, {
              tabId: tab?.id,
              error: stored.error || null
            });
            return storedStateResponse(stored, captureId);
          }
          const failure = stateStorageError
            ? `${errorMessage(error)}; ${stateStorageError}`
            : errorMessage(error);
          this._notify(record.intent, stateStorageError ? 'failed' : state, {
            tabId: tab?.id,
            error: failure
          });
          return {
            success: false,
            queued: queued && !stateStorageError,
            storage_error: Boolean(stateStorageError),
            capture_id: captureId,
            error: stateStorageError
              ? failure
              : queued ? `${failure} — saved in capture inbox for retry` : failure
          };
        }

        const state = stateForReceipt(receipt);
        const retryableTerminal = retainsRetryPayload(state);
        const receiptError = terminalReceiptError(receipt, state);
        const storedIntent = retryableTerminal ? record.intent : withoutScreenshot(record.intent);
        let persisted = null;
        let localWarning = null;
        try {
          persisted = await this._store.transition(
            captureId,
            state,
            {
              intent: storedIntent,
              receipt,
              jobId: receipt.jobId,
              error: receiptError,
              retryable: retryableTerminal
            },
            { onlyIfStates: ['submitting'] }
          );
          if (!persisted) throw new Error('capture record disappeared before retry acceptance was recorded');
        } catch (error) {
          localWarning = `Server accepted the retry, but its local inbox state could not be updated: ${errorMessage(error)}`;
        }
        const visibleState = persisted?.state || state;
        const visibleIntent = persisted?.intent || storedIntent;
        const visibleError = persisted?.error || receiptError || localWarning;
        this._notify(visibleIntent, visibleState, {
          tabId: tab?.id,
          receipt,
          error: visibleError
        });
        return receiptResponse(
          receipt,
          visibleState,
          captureId,
          localWarning,
          visibleError
        );
      }
      return await this.submit(record.intent, tab);
    } finally {
      this._inFlight.delete(captureId);
    }
  }

  async retryPending({ states = ['queued', 'submitting'] } = {}) {
    if (!this._store) return [];
    const recoverableStates = new Set(states);
    const queued = (await this._store.list())
      .filter(record => (
        recoverableStates.has(record.state)
        && !this._inFlight.has(record.captureId)
      ));
    const results = [];
    for (const record of queued) {
      // Re-check immediately before retry. Another event may have started or
      // completed this capture after the list() snapshot resolved.
      if (this._inFlight.has(record.captureId)) continue;
      try {
        results.push(await this.retry(record.captureId, null));
      } catch (error) {
        const message = errorMessage(error);
        let preserved = record;
        try {
          preserved = await this._store.transition(
            record.captureId,
            'failed',
            { error: message, retryable: false },
            { onlyIfStates: [record.state] }
          ) || record;
        } catch {
          // The original durable record remains the source of truth if even
          // the diagnostic transition cannot be written.
        }
        this._notify(preserved.intent || record.intent, preserved.state || 'failed', {
          error: preserved.error || message
        });
        results.push({
          success: false,
          capture_id: record.captureId,
          status: preserved.state || record.state,
          error: preserved.error || message
        });
      }
    }
    return results;
  }

  async list() {
    return this._store ? this._store.list() : [];
  }

  async dismiss(captureId) {
    if (this._store) await this._store.dismiss(captureId);
  }

  async mark(captureId, state, detail = {}) {
    if (!captureId || !this._store) return null;
    return this._store.transition(captureId, state, detail);
  }

  async stageMetadata(captureId, fields) {
    if (!this._store) throw new Error('Durable metadata storage is unavailable');
    const patch = {};
    if (fields?.tags != null) {
      if (!Array.isArray(fields.tags) || fields.tags.some(tag => typeof tag !== 'string')) throw new TypeError('Tags must be a list of text');
      patch.tags = [...fields.tags];
    }
    if (fields?.note != null) {
      if (typeof fields.note !== 'string') throw new TypeError('Note must be text');
      patch.note = fields.note;
    }
    return this._store.stageMetadata(captureId, patch);
  }

  async get(captureId) { return this._store?.get(captureId); }

  async patch(captureId, user, tab) {
    if (!this._patchTransport) throw new Error('Capture metadata editing is unavailable');
    if (!this._store) throw new Error('Durable metadata storage is unavailable');
    // Serialize per capture across tabs/cards; an older response must not overwrite a newer
    // local intent. Omitted fields are not edits (background messages may contain undefined).
    const patch = {};
    if (user?.tags != null) {
      if (!Array.isArray(user.tags)) throw new TypeError('Tags must be a list');
      patch.tags = [...user.tags];
    }
    if (user?.note != null) {
      if (typeof user.note !== 'string') throw new TypeError('Note must be text');
      patch.note = user.note;
    }
    const previous = this._metadataPatches.get(captureId) || Promise.resolve();
    const operation = previous.catch(() => {}).then(async () => {
      // Quota/storage failure is fail-closed before any network acceptance.
      if (Object.keys(patch).length) await this.stageMetadata(captureId, patch);
      let record = await this._store.beginMetadata(captureId);
      let receipt;
      try {
        do {
          const pending = record.metadata?.pending;
          receipt = await this._patchTransport(captureId, pending
            ? { ...pending.fields, mutationId: pending.mutationId } : {});
          // If this write fails, the exact token+snapshot remains durable. A
          // restart replays that token, never rebases a conflicting old edit.
          record = await this._store.acknowledgeMetadata(captureId, pending?.mutationId, receipt);
          if (!Object.keys(record.metadata.draft).length) break;
          record = await this._store.beginMetadata(captureId);
        } while (record.metadata.pending);
      } catch (error) {
        const message = errorMessage(error);
        try { record = await this._store.failMetadata(captureId, message); } catch { /* Durable dispatch evidence remains. */ }
        this._notify(record.intent, record.state, { tabId: tab?.id ?? record.tabId, metadata: record.metadata });
        return { success: false, metadata_pending: true, error: message, ...(receipt || {}) };
      }
      const projection = receipt?.metadataProjection;
      this._notify(record.intent, record.state, { tabId: tab?.id ?? record.tabId, metadata: record.metadata });
      return { ...receipt, success: projection !== 'failed',
        metadata_pending: projection === 'pending' || projection === 'failed',
        ...(projection === 'failed' ? { error: receipt.metadataError || 'Media is saved, but these changes need retry.' } : {}) };
    });
    this._metadataPatches.set(captureId, operation);
    try {
      return await operation;
    } finally {
      if (this._metadataPatches.get(captureId) === operation) this._metadataPatches.delete(captureId);
    }
  }

  _notify(intent, state, detail = {}) {
    if (this._onState) this._onState({ intent, state, ...detail });
  }
}
