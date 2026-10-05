// Site scripts know the exact element a capture came from; the page agent only learns the
// capture's URLs. Content scripts of one extension share this isolated world, so a site
// script leaves a hint here and the page agent picks it up when it presents the capture.
const HINT_TTL_MS = 60000;

function hints() {
  return (globalThis.__nodrawCaptureTargets ||= new Map());
}

// avoid: the control the capture came from; marks keep their caption off it.
export function rememberCaptureTarget(urls, element, avoid = null) {
  const at = Date.now();
  for (const url of [].concat(urls).filter(Boolean)) hints().set(url, { element, at, avoid });
}

export function findCaptureTarget(urls, options) {
  return findCaptureHint(urls, options)?.element || null;
}

// take: the capture claims its element, so a later capture of the same page (say from the
// toolbar) is not framed around this one.
export function findCaptureHint(urls, { take = false } = {}) {
  const now = Date.now();
  for (const [url, hint] of hints()) {
    if (now - hint.at > HINT_TTL_MS || !hint.element?.isConnected) hints().delete(url);
  }
  for (const url of [].concat(urls).filter(Boolean)) {
    const hint = hints().get(url);
    if (!hint) continue;
    if (take) {
      for (const [key, other] of hints()) if (other.element === hint.element) hints().delete(key);
    }
    return hint;
  }
  return null;
}
