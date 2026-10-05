import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const extensionDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

async function javascriptFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(entry => {
    const target = path.join(directory, entry.name);
    if (entry.isDirectory()) return javascriptFiles(target);
    return entry.name.endsWith('.js') ? [target] : [];
  }));
  return nested.flat();
}

test('extension source has one capture message and server transport', async () => {
  const files = await javascriptFiles(path.join(extensionDir, 'src'));
  const source = (await Promise.all(files.map(file => readFile(file, 'utf8')))).join('\n');

  assert.doesNotMatch(source, /request\.action\s*===\s*['"]archive(?:Image)?['"]/);
  assert.doesNotMatch(source, /action:\s*['"]archive(?:Image)?['"]/);
  assert.doesNotMatch(source, /\$\{SERVER_URL\}\/archive(?:-image)?/);
  assert.match(source, /action:\s*['"]capture\.submit['"]/);
  assert.match(source, /\$\{SERVER_URL\}\/captures/);
});

test('browser updates remove the incompatible retired queue key', async () => {
  const background = await readFile(
    path.join(extensionDir, 'src/background/background.js'),
    'utf8'
  );
  assert.match(background, /storage\.local\.remove\(['"]downloadQueue['"]\)/);
});

test('the universal context menu exposes selection capture', async () => {
  const background = await readFile(
    path.join(extensionDir, 'src/background/background.js'),
    'utf8'
  );
  assert.match(
    background,
    /contexts:\s*\[[^\]]*['"]selection['"][^\]]*\]/
  );
});
