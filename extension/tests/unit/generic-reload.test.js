import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../../src/background/background.js', import.meta.url), 'utf8');
const injectionSource = source.slice(
  source.indexOf('async function injectScriptIntoTab('),
  source.indexOf('async function ensureCaptureAgent(')
);
const reloadSource = source.slice(
  source.indexOf('function shouldInjectGenericDownloader('),
  source.indexOf('// Toggle generic downloader for a site')
);

function createHarness({ sites = {}, scripting = null, executeScript, storageError } = {}) {
  let listener;
  let reads = 0;
  let menus = 0;
  const browser = {
    storage: {
      local: {
        async get(key) {
          assert.equal(key, 'genericDownloaderSites');
          reads += 1;
          if (storageError) throw storageError;
          return { genericDownloaderSites: sites };
        }
      }
    },
    tabs: {
      executeScript,
      onUpdated: { addListener(callback) { listener = callback; } }
    }
  };
  const context = vm.createContext({
    URL,
    browser,
    scriptingApi: scripting,
    updateGenericDownloaderMenu: () => { menus += 1; }
  });
  vm.runInContext(`${injectionSource}\n${reloadSource}`, context);
  return {
    shouldInject: context.shouldInjectGenericDownloader,
    restore: context.restoreGenericDownloader,
    onUpdated: (...args) => listener(...args),
    reads: () => reads,
    menus: () => menus
  };
}

test('generic reload requires a finished web tab on an explicitly enabled host', () => {
  const { shouldInject } = createHarness();
  const sites = { 'example.com': true, 'other.example.com': false };
  const complete = { status: 'complete' };

  assert.equal(shouldInject(7, complete, { url: 'https://example.com/images' }, sites), true);
  assert.equal(shouldInject(7, complete, { url: 'http://www.example.com/images' }, sites), true);
  assert.equal(shouldInject(7, complete, { url: 'https://other.example.com/' }, sites), false);
  assert.equal(shouldInject(7, complete, { url: 'https://new.example.com/' }, sites), false);
  assert.equal(shouldInject(7, complete, { url: 'https://example.com/' }), false);
  assert.equal(shouldInject(7, complete, { url: 'https://example.com/' }, { 'example.com': 'true' }), false);
  assert.equal(shouldInject(7, { status: 'loading' }, { url: 'https://example.com/' }, sites), false);
  assert.equal(shouldInject(7, { url: 'https://example.com/' }, { url: 'https://example.com/' }, sites), false);
});

test('generic reload ignores invalid tab IDs, malformed URLs and browser pages', () => {
  const { shouldInject } = createHarness();
  const sites = { 'example.com': true };
  for (const tabId of [undefined, null, -1, 1.5, '7']) {
    assert.equal(shouldInject(tabId, { status: 'complete' }, { url: 'https://example.com' }, sites), false);
  }
  for (const url of [undefined, '', 'invalid', 'about:blank', 'chrome://example.com/', 'file://example.com/photo.jpg']) {
    assert.equal(shouldInject(7, { status: 'complete' }, { url }, sites), false);
  }
  assert.equal(shouldInject(7, { status: 'complete' }, undefined, sites), false);
});

test('Chrome MV3 restores an enabled downloader through scripting.executeScript', async () => {
  const calls = [];
  const harness = createHarness({
    sites: { 'example.com': true },
    scripting: { async executeScript(options) { calls.push(options); } },
    executeScript() { assert.fail('Firefox fallback should not run on Chrome'); }
  });
  await harness.restore(7, { status: 'complete' }, { url: 'https://www.example.com/gallery' });

  assert.equal(calls.length, 1);
  assert.equal(calls[0].target.tabId, 7);
  assert.deepEqual(Array.from(calls[0].files), ['content-generic.js']);
});

test('Firefox MV2 restores an enabled downloader through tabs.executeScript', async () => {
  const calls = [];
  const harness = createHarness({
    sites: { 'example.com': true },
    async executeScript(tabId, options) { calls.push({ tabId, options, receiver: this }); }
  });
  await harness.restore(8, { status: 'complete' }, { url: 'https://example.com/gallery' });

  assert.equal(calls.length, 1);
  assert.equal(calls[0].tabId, 8);
  assert.equal(calls[0].options.file, 'content-generic.js');
  assert.equal(typeof calls[0].receiver.onUpdated.addListener, 'function');
});

test('the tab-update listener restores after reload or navigation and leaves other updates alone', async () => {
  const calls = [];
  const harness = createHarness({
    sites: { 'example.com': true },
    scripting: { async executeScript(options) { calls.push(options); } }
  });
  harness.onUpdated(7, { status: 'loading' }, { url: 'https://example.com/' });
  harness.onUpdated(7, { url: 'https://example.com/new' }, { url: 'https://example.com/new' });
  assert.equal(harness.reads(), 0);
  assert.equal(harness.menus(), 0);

  harness.onUpdated(7, { status: 'complete' }, { url: 'https://example.com/' });
  await new Promise(resolve => setImmediate(resolve));
  harness.onUpdated(7, { status: 'complete' }, { url: 'https://example.com/new' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls.length, 2);
  assert.equal(harness.menus(), 2);
});

test('disabled sites do not inject and storage or browser injection failures settle safely', async () => {
  const disabled = createHarness({
    scripting: { executeScript() { assert.fail('Disabled sites must stay off'); } }
  });
  await disabled.restore(7, { status: 'complete' }, { url: 'https://example.com/' });

  const unavailableStorage = createHarness({ storageError: new Error('storage unavailable') });
  await assert.doesNotReject(unavailableStorage.restore(7, { status: 'complete' }, { url: 'https://example.com/' }));

  const restrictedTab = createHarness({
    sites: { 'example.com': true },
    scripting: { async executeScript() { throw new Error('tab closed'); } }
  });
  await assert.doesNotReject(restrictedTab.restore(7, { status: 'complete' }, { url: 'https://example.com/' }));
});
