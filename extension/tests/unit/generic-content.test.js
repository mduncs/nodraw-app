import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = (await readFile(new URL('../../src/content/content-generic.js', import.meta.url), 'utf8'))
  .replace(/^import .*;\n/gm, '');

test('repeated generic injection installs only one runtime listener and initialization', () => {
  const runtimeListeners = [];
  const readyListeners = [];
  const windowListeners = [];
  const window = {
    location: { hostname: 'www.example.test' },
    addEventListener: (...args) => windowListeners.push(args)
  };
  const context = vm.createContext({
    window, chrome: { runtime: { onMessage: { addListener: fn => runtimeListeners.push(fn) } } },
    document: { readyState: 'loading', addEventListener: (...args) => readyListeners.push(args) }
  });
  vm.runInContext(source, context);
  vm.runInContext(source, context);
  assert.equal(window.__archiverGenericInitialized, true);
  assert.equal(runtimeListeners.length, 1);
  assert.equal(readyListeners.length, 1);
  assert.equal(windowListeners.length, 1);
});

test('generic stays disabled when the hostname has no true setting', async () => {
  let reads = 0;
  const context = vm.createContext({
    window: { location: { hostname: 'example.test' }, addEventListener() {} },
    chrome: {
      runtime: { onMessage: { addListener() {} } },
      storage: { local: { get: async () => { reads++; return { genericDownloaderSites: {} }; } } }
    },
    document: { readyState: 'complete' }, console
  });
  vm.runInContext(source, context);
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(reads, 1);
  // No DOM scan, styles, observer or image buttons are created when off.
});
