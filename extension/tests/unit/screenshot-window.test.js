import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

// Run the shipped background handler against a fake two-window browser. An X save on
// 2026-10-02 got a YouTube tab's picture because the capture shot the last focused window.
async function loadCapture(tabs, { switchDuringCapture = false } = {}) {
  const source = await readFile(new URL('../../src/background/background.js', import.meta.url), 'utf8');
  const start = source.indexOf('async function captureScreenshot(');
  assert.ok(start >= 0);
  const end = source.indexOf('\n}\n', start) + 2;
  const shots = [];
  const errors = [];
  const browser = {
    tabs: {
      async get(id) {
        const tab = tabs.find(t => t.id === id);
        if (!tab) throw new Error(`no tab ${id}`);
        return { ...tab };
      },
      async captureVisibleTab(windowId) {
        shots.push(windowId);
        const visible = tabs.find(t => t.windowId === windowId && t.active)
          ?? tabs.find(t => t.lastFocused && t.active);
        if (switchDuringCapture) for (const t of tabs) t.active = !t.active;
        return `data:image/png;base64,${visible.id}`;
      }
    }
  };
  const captureScreenshot = vm.runInNewContext(`(${source.slice(start, end)})`, {
    browser, performance, console: { error() {} },
    recordTiming() {}, recordError: (kind, message) => errors.push(message)
  });
  return { captureScreenshot, shots, errors };
}

const xTab = { id: 7, windowId: 1, active: true };
const youtubeTab = { id: 9, windowId: 2, active: true, lastFocused: true };

test('captures the sender tab\'s own window, not the last focused one', async () => {
  const { captureScreenshot, shots } = await loadCapture([{ ...xTab }, { ...youtubeTab }]);
  assert.equal(await captureScreenshot(7, null), 'data:image/png;base64,7');
  assert.deepEqual(shots, [1]);
});

test('a sender tab that is not visible gets no screenshot rather than another tab\'s', async () => {
  const { captureScreenshot, shots, errors } = await loadCapture([{ ...xTab, active: false }, { ...youtubeTab }]);
  assert.equal(await captureScreenshot(7, null), null);
  assert.deepEqual(shots, []);
  assert.match(errors[0], /not the visible tab/);
});

test('a tab switch during the capture discards the picture', async () => {
  const { captureScreenshot } = await loadCapture([{ ...xTab }, { id: 8, windowId: 1, active: false }],
    { switchDuringCapture: true });
  assert.equal(await captureScreenshot(7, null), null);
});

test('a request without a sender tab gets no screenshot', async () => {
  const { captureScreenshot, shots } = await loadCapture([{ ...youtubeTab }]);
  assert.equal(await captureScreenshot(undefined, null), null);
  assert.deepEqual(shots, []);
});
