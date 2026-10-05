import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';
import { createCaptureAdmission } from '../../src/content/capture-admission.js';
import { createCaptureButton } from '../../src/content/modules/capture-button.js';

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const click = { preventDefault() {}, stopPropagation() {} };

// Execute the shipped handlers, not a second model of their admission logic.
async function loadHandler(platform, overrides) {
  const source = await readFile(new URL(`../../src/content/content-${platform}.js`, import.meta.url), 'utf8');
  if (platform === 'bluesky') {
    // Bluesky now delegates admission and clicks to the shared controller.
    assert.match(source, /createCaptureButton\(\{[\s\S]*?reservations: downloadingPosts/);
    let initialProbe = true;
    let controller;
    controller = createCaptureButton({
      button: { addEventListener() {}, removeEventListener() {} }, target: {},
      key: '123', url: 'https://bsky.app/profile/test/post/123',
      reservations: overrides.downloadingPosts,
      getPieces: () => [],
      getArchiveStatus: () => {
        if (initialProbe) { initialProbe = false; return { archived: false }; }
        return overrides.checkArchiveStatus();
      },
      confirmAgain: status => overrides.showReArchivePrompt({}, status),
      submit: async (mode, event, captureAgain) => {
        await overrides.performDownload(mode, () => controller.handleStatus({ status: 'completed' }), captureAgain);
        return { success: true, job_id: 'job' };
      },
      runtime: { onMessage: { addListener() {}, removeListener() {} } },
      presentation: {
        attachMarks: () => ({ set() {}, destroy() {} }),
        showCapturePlan() {}, hideCapturePlan() {}, watchModifiers: () => () => {}
      },
      clock: { setTimeout: () => 0, clearTimeout() {} }
    });
    await Promise.resolve();
    return () => controller.start('full', click);
  }
  const marker = "button.addEventListener('click', ";
  const start = source.indexOf(marker) + marker.length;
  assert.ok(start >= marker.length);
  const end = source.indexOf('\n    });', start) + '\n    }'.length;
  return vm.runInNewContext(`(${source.slice(start, end)})`, {
    getTweetData: () => ({ tweetId: '123', tweetUrl: 'https://x.com/test/status/123' }),
    getTweetKey: () => '123',
    postKey: '123',
    postData: { postId: '123', postUrl: 'https://bsky.app/profile/test/post/123' },
    getSaveModeFromEvent: () => 'full',
    getArchiveCacheKey: () => '123',
    archiveStatusCache: new Map(),
    getActionableStatus: error => error,
    setStatusMessage() {},
    button: { setAttribute() {} },
    ...overrides
  });
}

for (const platform of ['twitter', 'bluesky']) {
  test(`${platform}: two widgets share admission through delayed lookup, prompt, and submission`, async () => {
    const downloadingPosts = createCaptureAdmission();
    const lookup = deferred();
    const prompt = deferred();
    let lookups = 0, prompts = 0, submissions = 0, release;
    const context = {
      downloadingPosts,
      checkArchiveStatus() { lookups++; return lookup.promise; },
      showReArchivePrompt() { prompts++; return prompt.promise; },
      async performDownload(...args) { submissions++; release = args[platform === 'twitter' ? 2 : 1]; }
    };
    const [one, two] = await Promise.all([loadHandler(platform, context), loadHandler(platform, context)]);
    const first = one(click);
    await two(click);
    assert.equal(lookups, 1);
    lookup.resolve({ archived: true });
    await Promise.resolve();
    await two(click);
    assert.equal(prompts, 1);
    prompt.resolve(true);
    await first;
    await two(click);
    assert.equal(submissions, 1, 'reservation remains until terminal job outcome');
    release();
    await two(click);
    assert.equal(submissions, 2, 'deliberate later rearchive remains available');
    release();
  });

  test(`${platform}: cancellation and lookup/prompt failure release admission for retry`, async () => {
    const downloadingPosts = createCaptureAdmission();
    let stage = 'cancel', submissions = 0;
    const handler = await loadHandler(platform, {
      downloadingPosts,
      async checkArchiveStatus() {
        if (stage === 'lookup failure') throw new Error('offline');
        return { archived: true };
      },
      async showReArchivePrompt() {
        if (stage === 'prompt failure') throw new Error('prompt closed');
        return stage !== 'cancel';
      },
      async performDownload(...args) { submissions++; args[platform === 'twitter' ? 2 : 1](); }
    });
    for (stage of ['cancel', 'lookup failure', 'prompt failure', 'success']) {
      await handler(click);
      assert.equal(downloadingPosts.has('123'), false);
    }
    assert.equal(submissions, 1);
  });
}

test('late completion cannot release a newer capture reservation', () => {
  const gate = createCaptureAdmission();
  const old = gate.reserve('post');
  assert.equal(gate.reserve('post'), null);
  old.release();
  const current = gate.reserve('post');
  old.release();
  assert.equal(gate.has('post'), true);
  current.release();
  assert.equal(gate.has('post'), false);
});
