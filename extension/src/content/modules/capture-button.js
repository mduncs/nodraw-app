import { attachMarks } from '../ui/marks.js';
import { showCapturePlan, hideCapturePlan, watchModifiers } from '../ui/capture-plan.js';
import { rememberCaptureTarget } from '../ui/capture-target-hint.js';

// Sites with resolution shortcuts can supply their own mapping.
export function modeFromEvent(event = {}) {
  return event.altKey ? 'text' : event.shiftKey ? 'quick' : 'full';
}

let planOwner = null;

export function createCaptureButton({
  button, target, getPieces, submit, url, key = url, reservations, hintUrls,
  render = () => {}, runtime = (globalThis.browser || globalThis.chrome)?.runtime,
  getArchiveStatus, confirmAgain, beforeSubmit, onKept = () => {}, modeLabels = {},
  menu, hoverDelay = 1000, mapMode = modeFromEvent, keptDelay = 3500,
  presentation = { attachMarks, showCapturePlan, hideCapturePlan, watchModifiers },
  clock = globalThis
}) {
  let marks = null;
  let archiveStatus = null;
  let planMode = null;
  let state = 'idle';
  let mode = 'full';
  let hovered = false;
  let destroyed = false;
  let resetTimer = null;
  let menuTimer = null;
  let unwatch = null;
  let operation = null;
  let lastCaptureId = null;
  let lastCaptureMode = null;
  let lastCaptureEvent = {};
  let lastCaptureKey = null;
  let lastCaptureUrl = null;
  const listeners = [];
  const value = input => typeof input === 'function' ? input() : input;

  function clearPlan() {
    if (planOwner === button) {
      presentation.hideCapturePlan();
      planOwner = null;
    }
    planMode = null;
  }

  function clearMarks() {
    marks?.destroy();
    marks = null;
  }

  function paintHover() {
    if (!marks || !hovered || operation) return;
    marks.set(archiveStatus?.archived ? 'already' : 'hover', {
      ...(archiveStatus?.archived ? archiveStatus : {}),
      modeLabel: modeLabels[mode],
      onSaveAgain: () => start(mode, {}, true)
    });
  }

  function paint(info = {}) {
    if (destroyed) return;
    if (button.dataset) button.dataset.archiverState = state;
    const menuVisible = value(menu)?.classList.contains('visible');
    render(state, { mode, ...info });
    if (menuVisible && hovered && !operation) value(menu)?.classList.add('visible');
  }

  function release(op) {
    op?.release();
    if (operation === op) operation = null;
    if (op?.listener) runtime?.onMessage.removeListener(op.listener);
  }

  function settle(op, nextState, info = {}) {
    if (operation !== op) return;
    state = nextState;
    release(op);
    if (nextState === 'kept' || nextState === 'already') onKept(info);
    paint(info);
    if (nextState === 'kept' && !destroyed) {
      resetTimer = clock.setTimeout(() => {
        resetTimer = null;
        state = hovered ? 'hover' : 'idle';
        paint();
      }, keptDelay);
    }
  }

  function handleStatus(job, op = operation) {
    if (!op || operation !== op) return;
    lastCaptureId = job.captureId || job.capture_id || lastCaptureId;
    const status = job.status;
    if (['completed', 'saved', 'duplicate'].includes(status)) {
      settle(op, status === 'duplicate' || job.disposition === 'duplicate' ? 'already' : 'kept', job);
    } else if (['failed', 'stalled', 'cancelled'].includes(status)) {
      settle(op, 'failed', { ...job, error: job.message || job.error || 'Archive failed' });
    } else {
      paint({ progress: job.progress, caption: status === 'queued' ? 'QUEUED' : 'SAVING' });
    }
  }

  async function start(nextMode = mode, event = {}, captureAgain = false) {
    if (destroyed || operation) return;
    const captureKey = value(key);
    let reservation;
    if (reservations?.reserve) reservation = reservations.reserve(captureKey);
    else if (reservations) {
      if (!reservations.has(captureKey)) {
        reservations.add(captureKey);
        reservation = { release: () => reservations.delete(captureKey) };
      }
    } else reservation = { release() {} };
    if (!reservation) return;
    const captureUrl = typeof url === 'function' ? url(nextMode, event) : url;
    const sameModifiers = ['shiftKey', 'altKey', 'metaKey', 'ctrlKey']
      .every(key => !!event[key] === !!lastCaptureEvent[key]);
    const retryId = state === 'failed' && !captureAgain && nextMode === lastCaptureMode
      && captureKey === lastCaptureKey && captureUrl === lastCaptureUrl && sameModifiers ? lastCaptureId : null;
    if (!retryId) lastCaptureId = null;
    lastCaptureMode = nextMode;
    lastCaptureKey = captureKey;
    lastCaptureUrl = captureUrl;
    lastCaptureEvent = {
      shiftKey: !!event.shiftKey, altKey: !!event.altKey,
      metaKey: !!event.metaKey, ctrlKey: !!event.ctrlKey
    };
    const op = {
      release: reservation.release, jobId: null,
      url: captureUrl, early: []
    };
    operation = op;
    mode = nextMode;
    clock.clearTimeout(resetTimer);
    clock.clearTimeout(menuTimer);
    value(menu)?.classList.remove('visible');
    clearPlan();
    clearMarks();
    state = 'saving';
    paint({ caption: 'SAVING' });

    // Subscribe before submission: a fast job may finish before its receipt.
    op.listener = request => {
      if (request?.action !== 'archiveJobStatus') return;
      const jobId = request.jobId || request.job_id;
      if (op.jobId ? jobId !== op.jobId : !op.url || request.url !== op.url) return;
      if (!op.ready) op.early.push(request);
      else handleStatus(request, op);
    };
    runtime?.onMessage.addListener(op.listener);
    try {
      if (beforeSubmit && !await beforeSubmit(mode, event)) {
        settle(op, hovered ? 'hover' : 'idle');
        return;
      }
      if (getArchiveStatus && !captureAgain && !retryId) {
        const status = await getArchiveStatus();
        if (destroyed) { release(op); return; }
        archiveStatus = status;
        if (status.archived) {
          if (confirmAgain && !await confirmAgain(status)) {
            settle(op, 'already', status);
            return;
          }
          captureAgain = true;
        }
      }
      if (destroyed) { release(op); return; }
      rememberCaptureTarget([captureUrl, ...[].concat(hintUrls?.(mode) || [])], value(target), button);
      clearMarks();
      const response = retryId && runtime?.sendMessage
        ? await runtime.sendMessage({ action: 'capture.retry', captureId: retryId })
        : await submit(mode, event, captureAgain);
      if (operation !== op) return;
      lastCaptureId = response?.capture_id || response?.captureId || lastCaptureId;
      op.jobId = response?.job_id || response?.jobId;
      op.ready = true;
      if (['saved', 'completed', 'duplicate', 'failed', 'stalled'].includes(response?.status)) {
        handleStatus(response, op);
      } else if (response?.queued || (response?.success && op.jobId)) {
        paint({ caption: response.queued ? 'QUEUED' : 'SAVING', error: response.error });
      } else if (response?.success && !['accepted', 'processing'].includes(response.status)) {
        settle(op, response.disposition === 'duplicate' ? 'already' : 'kept', response);
      } else if (!response?.success) {
        throw new Error(response?.error || 'Archive failed');
      }
      for (const job of op.early) {
        if (!op.jobId || (job.jobId || job.job_id) === op.jobId) handleStatus(job, op);
      }
      op.early.length = 0;
    } catch (error) {
      settle(op, 'failed', { error: error?.message || String(error) });
    }
  }

  function updateMode(nextMode) {
    if (operation) return;
    const changed = mode !== nextMode;
    mode = nextMode;
    if (state === 'idle' || state === 'hover') paint();
    paintHover();
    if (hovered && (planMode === null || changed)) {
      planOwner = button;
      const element = value(target);
      const pieces = getPieces(mode);
      const hovered = pieces.findIndex(piece => piece.element === element);
      presentation.showCapturePlan(pieces.map((piece, index) =>
        index === hovered ? { ...piece, captionAbove: true } : piece), { mode });
      planMode = mode;
    }
  }

  function listen(name, handler) {
    button.addEventListener(name, handler);
    listeners.push([name, handler]);
  }
  listen('mouseenter', event => {
    hovered = true;
    if (!operation && !marks) marks = presentation.attachMarks(value(target), { avoid: button });
    if (state === 'idle') state = 'hover';
    updateMode(mapMode(event));
    unwatch?.();
    unwatch = presentation.watchModifiers(nextMode => updateMode(mapMode({
      shiftKey: nextMode === 'quick' || nextMode === 'quoted',
      altKey: nextMode === 'text' || nextMode === 'quoted'
    })));
    menuTimer = clock.setTimeout(() => {
      if (!operation) value(menu)?.classList.add('visible');
    }, hoverDelay);
  });
  listen('mousemove', event => updateMode(mapMode(event)));
  listen('mouseleave', () => {
    hovered = false;
    unwatch?.();
    unwatch = null;
    clock.clearTimeout(menuTimer);
    value(menu)?.classList.remove('visible');
    clearPlan();
    clearMarks();
    if (state === 'hover') { state = 'idle'; mode = 'full'; paint(); }
  });
  listen('click', event => {
    event.preventDefault();
    event.stopPropagation();
    clearMarks();
    void start(mapMode(event), event);
  });

  paint();
  if (getArchiveStatus) {
    Promise.resolve().then(getArchiveStatus).then(status => {
      if (!destroyed && !operation) {
        archiveStatus = status;
        if (state === 'idle' && status.archived) {
          state = 'already';
          paint(status);
        }
        paintHover();
      }
    }).catch(() => {});
  }

  function destroy() {
    if (destroyed) return;
    destroyed = true;
    clock.clearTimeout(resetTimer);
    clock.clearTimeout(menuTimer);
    unwatch?.();
    clearPlan();
    for (const [name, handler] of listeners) button.removeEventListener(name, handler);
    clearMarks();
    // An in-flight operation retains only its status listener and reservation
    // until terminal server truth, so recycled widgets cannot submit it twice.
  }
  button._archiverCleanup = destroy;
  return { destroy, start, handleStatus, get state() { return state; } };
}
