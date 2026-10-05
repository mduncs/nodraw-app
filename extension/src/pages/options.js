const portInput = document.getElementById('port');
const statusEl = document.getElementById('status');
const discoveryEl = document.getElementById('discovery-info');
const b = (typeof browser !== 'undefined') ? browser : chrome;

// Show discovery status
(async () => {
  try {
    const port = await discoverPort();
    discoveryEl.textContent = `Discovery: connected — server on port ${port} (auto)`;
    discoveryEl.style.color = '#6c6';
  } catch {
    discoveryEl.textContent = 'Discovery: unavailable — using manual port';
    discoveryEl.style.color = '#c66';
  }
})();

// Load saved manual port override
b.storage.local.get({ port: null }).then(result => {
  if (result.port) {
    portInput.value = result.port;
  }
});

// Save manual override
document.getElementById('save').addEventListener('click', () => {
  const val = portInput.value.trim();
  if (!val) {
    // Clear override, use auto-discovery
    b.storage.local.remove('port').then(() => {
      showStatus('ok', 'Cleared manual override. Using auto-discovery.');
    });
    return;
  }
  const port = parseInt(val, 10);
  if (port < 1024 || port > 65535) {
    showStatus('err', 'Port must be between 1024 and 65535');
    return;
  }
  b.storage.local.set({ port }).then(() => {
    showStatus('ok', 'Saved manual override: http://localhost:' + port);
  });
});

// Test connection (uses discovery or manual)
document.getElementById('test').addEventListener('click', async () => {
  showStatus('info', 'Checking...');
  try {
    const url = await getServerURL();
    const resp = await fetch(url + '/health', { signal: AbortSignal.timeout(5000) });
    if (resp.ok) {
      const data = await resp.json();
      showStatus('ok', 'Connected to ' + url + ' — ' + (data.status || 'healthy'));
    } else {
      showStatus('err', 'Server at ' + url + ' responded with ' + resp.status);
    }
  } catch (e) {
    showStatus('err', 'Cannot reach server: ' + e.message);
  }
});

function showStatus(type, msg) {
  statusEl.className = 'status ' + type;
  statusEl.textContent = msg;
}
