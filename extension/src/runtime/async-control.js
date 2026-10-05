function timeoutError(timeoutMs) {
  const error = new Error(`Request timed out after ${timeoutMs}ms`);
  error.name = 'TimeoutError';
  return error;
}

/**
 * Run a fetch with an AbortSignal-backed deadline while preserving cancellation
 * supplied by the caller. The injected fetch function keeps this browser helper
 * directly unit-testable without network access.
 */
export async function fetchWithTimeout(
  fetchImplementation,
  input,
  init = {},
  timeoutMs = 5000,
  consumeResponse = null
) {
  if (typeof fetchImplementation !== 'function') {
    throw new TypeError('fetchWithTimeout requires a fetch implementation');
  }

  const controller = new AbortController();
  const sourceSignal = init.signal;
  let forwardAbort = null;
  const cancellation = sourceSignal ? new Promise((_, reject) => {
    forwardAbort = () => {
      const reason = sourceSignal.reason || new Error('Request cancelled');
      controller.abort(reason);
      reject(reason);
    };
    if (sourceSignal.aborted) forwardAbort();
    else sourceSignal.addEventListener('abort', forwardAbort, { once: true });
  }) : null;

  const deadlineError = timeoutError(timeoutMs);
  let deadlineExpired = false;
  let timeoutId;
  const deadline = new Promise((_, reject) => {
    timeoutId = setTimeout(() => {
      deadlineExpired = true;
      controller.abort(deadlineError);
      reject(deadlineError);
    }, timeoutMs);
  });
  const request = (async () => {
    const response = await fetchImplementation(input, { ...init, signal: controller.signal });
    return typeof consumeResponse === 'function'
      ? consumeResponse(response)
      : response;
  })();
  try {
    return await Promise.race(cancellation
      ? [request, deadline, cancellation]
      : [request, deadline]);
  } catch (error) {
    // Some fetch implementations reject with a generic AbortError instead of
    // propagating AbortSignal.reason. Preserve a deterministic TimeoutError so
    // capture runtime can queue the durable request truthfully.
    if (deadlineExpired) throw deadlineError;
    throw error;
  } finally {
    clearTimeout(timeoutId);
    if (forwardAbort) sourceSignal?.removeEventListener('abort', forwardAbort);
  }
}

/** Run every item with bounded concurrency and retain all outcomes. */
export async function allSettledBounded(items, concurrency, operation) {
  const values = Array.from(items);
  if (values.length === 0) return [];
  const width = Math.max(1, Math.min(values.length, Math.floor(concurrency) || 1));
  const results = new Array(values.length);
  let cursor = 0;

  async function worker() {
    while (cursor < values.length) {
      const index = cursor;
      cursor += 1;
      try {
        results[index] = { status: 'fulfilled', value: await operation(values[index], index) };
      } catch (reason) {
        results[index] = { status: 'rejected', reason };
      }
    }
  }

  await Promise.all(Array.from({ length: width }, () => worker()));
  return results;
}

/** Normalize persisted jobs without treating total runtime as a failure signal. */
export function normalizeRestoredJobs(jobs, now) {
  const restorable = [];
  const invalid = [];

  for (const job of Array.isArray(jobs) ? jobs : []) {
    if (!job?.jobId || !job?.url) {
      invalid.push(job);
      continue;
    }
    const startTime = Number.isFinite(job.startTime) ? job.startTime : now;
    const lastConfirmedAt = Number.isFinite(job.lastConfirmedAt)
      ? job.lastConfirmedAt
      : startTime;
    restorable.push({ ...job, startTime, lastConfirmedAt });
  }

  return { restorable, invalid };
}

function unconfirmedResult(trackedJob, now, unconfirmedTimeoutMs, reason) {
  const lastConfirmedAt = Number.isFinite(trackedJob?.lastConfirmedAt)
    ? trackedJob.lastConfirmedAt
    : Number.isFinite(trackedJob?.startTime) ? trackedJob.startTime : now;
  const unconfirmedForMs = Math.max(0, now - lastConfirmedAt);
  if (unconfirmedForMs >= unconfirmedTimeoutMs) {
    return {
      action: 'stalled',
      confirmed: false,
      reason: `${reason}; server truth has been unconfirmed for ${unconfirmedForMs}ms`,
      unconfirmedForMs
    };
  }
  return {
    action: 'retain',
    confirmed: false,
    reason,
    unconfirmedForMs
  };
}

/**
 * Ask the server for current truth before making any age-based decision. Total
 * job runtime is intentionally unlimited; only time since a confirmed server
 * observation can eventually produce a local stalled state.
 */
export async function reconcileTrackedJob({
  fetchImplementation,
  requestUrl,
  requestTimeoutMs,
  trackedJob,
  now = Date.now(),
  unconfirmedTimeoutMs
}) {
  let response;
  let payload;
  let payloadError = null;
  try {
    const result = await fetchWithTimeout(
      fetchImplementation,
      requestUrl,
      {},
      requestTimeoutMs,
      async fetchedResponse => {
        if (!fetchedResponse.ok) {
          return { response: fetchedResponse, payload: null, payloadError: null };
        }
        try {
          return {
            response: fetchedResponse,
            payload: await fetchedResponse.json(),
            payloadError: null
          };
        } catch (error) {
          return { response: fetchedResponse, payload: null, payloadError: error };
        }
      }
    );
    ({ response, payload, payloadError } = result);
  } catch (error) {
    return unconfirmedResult(
      trackedJob,
      now,
      unconfirmedTimeoutMs,
      error?.message || 'Job status request failed'
    );
  }

  if (!response.ok) {
    if (response.status === 404 || response.status === 410) {
      return {
        action: 'stalled',
        confirmed: true,
        reason: `Archive server no longer has job ${trackedJob?.jobId || ''}`.trim()
      };
    }
    return unconfirmedResult(
      trackedJob,
      now,
      unconfirmedTimeoutMs,
      `Job status returned HTTP ${response.status}`
    );
  }

  if (payloadError) {
    return unconfirmedResult(
      trackedJob,
      now,
      unconfirmedTimeoutMs,
      `Job status response was invalid: ${payloadError?.message || 'invalid JSON'}`
    );
  }

  const status = String(payload?.status || '').toLowerCase();
  if (['pending', 'queued', 'accepted', 'processing', 'downloading'].includes(status)) {
    return { action: 'retain', confirmed: true, observedAt: now, payload };
  }
  if (['completed', 'saved'].includes(status)) {
    return { action: 'completed', confirmed: true, observedAt: now, payload };
  }
  if (status === 'failed') {
    return { action: 'failed', confirmed: true, observedAt: now, payload };
  }
  if (status === 'stalled') {
    return {
      action: 'stalled',
      confirmed: true,
      observedAt: now,
      payload,
      reason: payload.error || 'Archive server reported that the job stalled'
    };
  }

  return unconfirmedResult(
    trackedJob,
    now,
    unconfirmedTimeoutMs,
    `Archive server returned unknown job status ${status || '(missing)'}`
  );
}
