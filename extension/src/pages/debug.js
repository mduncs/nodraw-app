// URL Saver Debug Panel Script
const browser = window.browser || window.chrome;

function formatUptime(ms) {
  const seconds = Math.floor(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);

  if (hours > 0) {
    return `${hours}h ${minutes % 60}m`;
  } else if (minutes > 0) {
    return `${minutes}m ${seconds % 60}s`;
  }
  return `${seconds}s`;
}

function formatTime(timestamp) {
  if (!timestamp) return '--';
  const date = new Date(timestamp);
  return date.toLocaleTimeString('en-US', { hour12: false });
}

function formatDuration(ms) {
  if (ms >= 1000) {
    return `${(ms / 1000).toFixed(1)}s`;
  }
  return `${ms}ms`;
}

// Safe DOM element creation helper
function createElement(tag, attrs = {}, children = []) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key === 'className') {
      el.className = value;
    } else if (key === 'textContent') {
      el.textContent = value;
    } else if (key === 'title') {
      el.title = value;
    } else {
      el.setAttribute(key, value);
    }
  }
  for (const child of children) {
    if (typeof child === 'string') {
      el.appendChild(document.createTextNode(child));
    } else {
      el.appendChild(child);
    }
  }
  return el;
}

async function refresh() {
  try {
    const response = await browser.runtime.sendMessage({ action: 'getMetrics' });
    if (!response) {
      console.error('No response from background script');
      return;
    }

    const { metrics, uptime, serverAvailable } = response;

    // Update server status
    const statusEl = document.getElementById('server-status');
    statusEl.className = `status-indicator ${serverAvailable ? 'status-online' : 'status-offline'}`;

    // Update uptime
    document.getElementById('uptime').textContent = `Uptime: ${formatUptime(uptime)}`;

    // Update request stats
    const { requests } = metrics;
    document.getElementById('total').textContent = requests.total;
    document.getElementById('success').textContent = requests.success;

    const failedEl = document.getElementById('failed');
    failedEl.textContent = requests.failed;
    failedEl.className = `metric-value ${requests.failed > 0 ? 'error' : ''}`;

    const rateEl = document.getElementById('rate');
    if (requests.total > 0) {
      const rate = Math.round((requests.success / requests.total) * 100);
      rateEl.textContent = `${rate}%`;
      rateEl.className = `metric-value ${rate < 90 ? 'warning' : ''} ${rate < 50 ? 'error' : ''}`;
    } else {
      rateEl.textContent = '--';
      rateEl.className = 'metric-value';
    }

    // Update timing data
    renderTimingData(metrics.timing);

    // Update errors
    renderErrors(metrics.errors);

    // Update recent requests
    renderRequests(metrics.recentRequests);

    // Update durable captures separately from transient request metrics.
    await loadCaptureInbox();

    // Update debug mode button
    const debugResponse = await browser.runtime.sendMessage({ action: 'getDebugMode' });
    const debugBtn = document.getElementById('debug-toggle');
    if (debugResponse.debugMode) {
      debugBtn.textContent = 'Debug Mode: ON';
      debugBtn.classList.add('toggle-on');
    } else {
      debugBtn.textContent = 'Debug Mode: OFF';
      debugBtn.classList.remove('toggle-on');
    }

  } catch (error) {
    console.error('Error fetching metrics:', error);
  }
}

function renderTimingData(timing) {
  const container = document.getElementById('timing-data');
  container.replaceChildren();

  const hasData = Object.values(timing).some(t => t.count > 0);
  if (!hasData) {
    container.appendChild(createElement('div', { className: 'no-data', textContent: 'No timing data yet' }));
    return;
  }

  for (const [key, stats] of Object.entries(timing)) {
    if (stats.count === 0) continue;

    const row = createElement('div', { className: 'timing-row' }, [
      createElement('span', { className: 'timing-label', textContent: key }),
      createElement('div', { className: 'timing-values' }, [
        createTimingStat('avg', stats.avg),
        createTimingStat('min', stats.min),
        createTimingStat('max', stats.max),
        createTimingStat('n', stats.count, true)
      ])
    ]);
    container.appendChild(row);
  }
}

function createTimingStat(label, value, isCount = false) {
  return createElement('div', { className: 'timing-stat' }, [
    createElement('div', { className: 'timing-stat-label', textContent: label }),
    createElement('div', { className: 'timing-stat-value', textContent: isCount ? value : formatDuration(value) })
  ]);
}

function renderErrors(errors) {
  const container = document.getElementById('errors-data');
  container.replaceChildren();

  const errorTypes = Object.keys(errors);
  if (errorTypes.length === 0) {
    container.appendChild(createElement('div', { className: 'no-data', textContent: 'No errors recorded' }));
    return;
  }

  for (const [type, data] of Object.entries(errors)) {
    const item = createElement('div', { className: 'error-item' }, [
      createElement('span', { className: 'error-type', textContent: type }),
      createElement('span', { className: 'error-count', textContent: `x${data.count}` }),
      createElement('div', { className: 'error-message', textContent: data.lastMessage })
    ]);
    container.appendChild(item);
  }
}

function renderRequests(recentRequests) {
  const container = document.getElementById('requests-data');
  container.replaceChildren();

  if (recentRequests.length === 0) {
    container.appendChild(createElement('div', { className: 'no-data', textContent: 'No requests yet' }));
    return;
  }

  for (const req of recentRequests) {
    const item = createElement('div', { className: 'request-item' }, [
      createElement('span', { className: `request-status ${req.success ? 'success' : 'failed'}` }),
      createElement('span', { className: 'request-type', textContent: req.type }),
      createElement('span', { className: 'request-url', textContent: req.url, title: req.url }),
      createElement('span', { className: 'request-duration', textContent: formatDuration(req.duration) }),
      createElement('span', { className: 'request-time', textContent: formatTime(req.timestamp) })
    ]);
    container.appendChild(item);
  }
}

function captureLabel(record) {
  return record.intent?.page?.title
    || record.intent?.media?.alt
    || record.intent?.targetUrl
    || record.intent?.sourcePageUrl
    || record.captureId
    || 'Untitled capture';
}

function captureUrl(record) {
  return record.intent?.targetUrl || record.intent?.sourcePageUrl || '';
}

function captureDetail(record) {
  const parts = [];
  if (record.intent?.kind) parts.push(record.intent.kind);
  if (record.attempts) parts.push(`${record.attempts} attempt${record.attempts === 1 ? '' : 's'}`);
  if (record.updatedAt) parts.push(`updated ${formatTime(record.updatedAt)}`);
  return parts.join(' · ');
}

function retryableCapture(record) {
  return ['queued', 'submitting', 'failed', 'stalled'].includes(record.state);
}

async function captureAction(action, captureId, button) {
  const feedback = document.getElementById('capture-inbox-feedback');
  button.disabled = true;
  feedback.textContent = action === 'capture.patch' ? 'Retrying metadata…' : action === 'capture.retry' ? 'Retrying capture…' : 'Dismissing capture…';
  try {
    const response = await browser.runtime.sendMessage({ action, captureId });
    if (response?.success === false) {
      throw new Error(response.error || 'Capture action failed');
    }
    feedback.textContent = action === 'capture.patch' ? (response.metadata_pending ? 'Metadata remains pending.' : 'Metadata saved.') : action === 'capture.retry' ? 'Retry submitted.' : 'Capture dismissed.';
    await loadCaptureInbox();
  } catch (error) {
    feedback.textContent = error?.message || 'Capture action failed';
  } finally {
    button.disabled = false;
  }
}

function renderCaptureInbox(captures) {
  const container = document.getElementById('capture-inbox-data');
  container.replaceChildren();

  if (!captures.length) {
    container.appendChild(createElement('div', {
      className: 'no-data',
      textContent: 'Capture inbox is empty'
    }));
    return;
  }

  for (const record of captures) {
    const state = record.state || 'unknown';
    const summary = createElement('div', { className: 'capture-summary' }, [
      createElement('div', { className: 'capture-heading' }, [
        createElement('span', { className: `capture-state ${state}`, textContent: state }),
        createElement('span', { className: 'capture-title', textContent: captureLabel(record), title: captureLabel(record) })
      ]),
      createElement('div', { className: 'capture-url', textContent: captureUrl(record), title: captureUrl(record) }),
      createElement('div', { className: 'capture-detail', textContent: captureDetail(record) })
    ]);

    if (record.error) {
      summary.appendChild(createElement('div', { className: 'capture-error', textContent: record.error }));
    }

    const actions = createElement('div', { className: 'capture-actions' });
    const metadata = record.metadata;
    const metadataPending = metadata && (metadata.pending || Object.keys(metadata.draft || {}).length
      || ['pending', 'failed'].includes(metadata.receipt?.metadataProjection));
    if (metadataPending) {
      summary.appendChild(createElement('div', { className: 'capture-error', textContent: metadata.error || metadata.receipt?.metadataError || 'Metadata changes pending' }));
      const retryMetadata = createElement('button', { textContent: 'Retry changes', title: 'Retry metadata without downloading media again' });
      retryMetadata.addEventListener('click', () => captureAction('capture.patch', record.captureId, retryMetadata));
      actions.appendChild(retryMetadata);
    }
    if (retryableCapture(record)) {
      const retry = createElement('button', { textContent: 'Retry', title: 'Retry this capture now' });
      retry.addEventListener('click', () => captureAction('capture.retry', record.captureId, retry));
      actions.appendChild(retry);
    }
    const dismiss = createElement('button', { className: 'secondary', textContent: 'Dismiss', title: 'Remove this capture from the inbox' });
    dismiss.addEventListener('click', () => {
      if (confirm('Dismiss this capture from the durable inbox?')) {
        void captureAction('capture.dismiss', record.captureId, dismiss);
      }
    });
    actions.appendChild(dismiss);

    container.appendChild(createElement('div', { className: 'capture-item' }, [summary, actions]));
  }
}

async function loadCaptureInbox() {
  const container = document.getElementById('capture-inbox-data');
  try {
    const response = await browser.runtime.sendMessage({ action: 'capture.list' });
    renderCaptureInbox(Array.isArray(response?.captures) ? response.captures : []);
  } catch (error) {
    container.replaceChildren(createElement('div', {
      className: 'no-data',
      textContent: `Capture inbox unavailable: ${error?.message || 'unknown error'}`
    }));
  }
}

async function resetMetrics() {
  if (confirm('Reset all metrics? This cannot be undone.')) {
    await browser.runtime.sendMessage({ action: 'resetMetrics' });
    refresh();
  }
}

async function toggleDebug() {
  const response = await browser.runtime.sendMessage({ action: 'getDebugMode' });
  const newValue = !response.debugMode;
  await browser.runtime.sendMessage({ action: 'setDebugMode', enabled: newValue });
  refresh();
}

document.getElementById('refresh-button').addEventListener('click', refresh);
document.getElementById('reset-metrics-button').addEventListener('click', resetMetrics);
document.getElementById('debug-toggle').addEventListener('click', toggleDebug);

// Auto-refresh every 5 seconds
let refreshInterval = setInterval(refresh, 5000);

// Initial load
refresh();

// Pause auto-refresh when tab is hidden
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    clearInterval(refreshInterval);
  } else {
    refresh();
    refreshInterval = setInterval(refresh, 5000);
  }
});
