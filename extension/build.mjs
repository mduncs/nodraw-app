import { build } from 'esbuild';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const extensionDir = path.dirname(fileURLToPath(import.meta.url));
const outputDir = path.resolve(process.argv[2] || path.join(extensionDir, 'build'));
const browserName = process.argv[3] || 'firefox';

if (!['firefox', 'chrome'].includes(browserName)) {
  throw new Error(`Unsupported browser: ${browserName}`);
}

await mkdir(outputDir, { recursive: true });

await build({
  absWorkingDir: extensionDir,
  entryPoints: {
    background: 'src/entries/background.js',
    'content-twitter': 'src/entries/content-twitter.js',
    'content-bluesky': 'src/entries/content-bluesky.js',
    'content-youtube': 'src/entries/content-youtube.js',
    'content-reddit': 'src/entries/content-reddit.js',
    'content-gallery': 'src/entries/content-gallery.js',
    'content-generic': 'src/entries/content-generic.js',
    'page-agent': 'src/entries/page-agent.js',
    options: 'src/entries/options.js',
    debug: 'src/entries/debug.js'
  },
  outdir: outputDir,
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: browserName === 'chrome' ? ['chrome120'] : ['firefox140'],
  logLevel: 'warning',
  legalComments: 'none',
  charset: 'utf8'
});
