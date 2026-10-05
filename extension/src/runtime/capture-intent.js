export const CAPTURE_INTENT_VERSION = 1;
export const CAPTURE_KINDS = Object.freeze(['page', 'media', 'link', 'selection']);

function cleanString(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function cleanTags(value) {
  const tags = Array.isArray(value) ? value : [];
  return [...new Set(tags.map(cleanString).filter(Boolean))];
}

function stableHash(value) {
  let hash = 0x811c9dc5;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return (hash >>> 0).toString(16).padStart(8, '0');
}

function stableSerializable(value) {
  if (Array.isArray(value)) return value.map(stableSerializable);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(
    Object.keys(value).sort().map(key => [key, stableSerializable(value[key])])
  );
}

function makeCaptureId() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  return `capture-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

export function captureFingerprint(intent) {
  const identity = JSON.stringify([
    intent.kind,
    intent.targetUrl,
    intent.sourcePageUrl,
    intent.media?.url || '',
    intent.selection?.text || '',
    intent.selection?.html || '',
    intent.options?.saveMode || 'full',
    intent.options?.captureAgain ? intent.captureId : '',
    // Screenshot context is part of the requested result, not incidental
    // transport data. Hash the bytes separately so two Full captures of the
    // same URL at different visual states cannot collapse, without copying a
    // multi-megabyte data URL into the small identity tuple.
    stableHash(intent.options?.screenshot || ''),
    intent.options?.platform || 'web',
    stableSerializable(intent.options?.siteData || {}),
    stableSerializable(intent.options?.download || {})
  ]);
  return `v${CAPTURE_INTENT_VERSION}-${stableHash(identity)}`;
}

export function createCaptureIntent(input = {}, options = {}) {
  const kind = CAPTURE_KINDS.includes(input.kind) ? input.kind : 'page';
  const sourcePageUrl = cleanString(input.sourcePageUrl || input.page?.url);
  const targetUrl = cleanString(
    input.targetUrl || input.media?.url || input.link?.url || sourcePageUrl
  );

  if (!targetUrl && kind !== 'selection') {
    throw new TypeError('CaptureIntent requires a target URL');
  }

  const intent = {
    schemaVersion: CAPTURE_INTENT_VERSION,
    captureId: cleanString(input.captureId) || options.captureId || makeCaptureId(),
    kind,
    targetUrl,
    sourcePageUrl: sourcePageUrl || targetUrl,
    createdAt: cleanString(input.createdAt) || options.createdAt || new Date().toISOString(),
    page: {
      title: cleanString(input.page?.title),
      canonicalUrl: cleanString(input.page?.canonicalUrl),
      author: cleanString(input.page?.author),
      description: cleanString(input.page?.description),
      publishedAt: cleanString(input.page?.publishedAt),
      siteName: cleanString(input.page?.siteName),
      language: cleanString(input.page?.language),
      image: cleanString(input.page?.image),
      schemaTypes: Array.isArray(input.page?.schemaTypes)
        ? [...new Set(input.page.schemaTypes.map(cleanString).filter(Boolean))]
        : []
    },
    media: kind === 'media' ? {
      url: cleanString(input.media?.url || targetUrl),
      type: cleanString(input.media?.type),
      alt: cleanString(input.media?.alt)
    } : null,
    selection: kind === 'selection' ? {
      text: cleanString(input.selection?.text),
      html: cleanString(input.selection?.html)
    } : null,
    user: {
      tags: cleanTags(input.user?.tags || input.tags),
      note: cleanString(input.user?.note || input.note)
    },
    options: {
      saveMode: cleanString(input.options?.saveMode || input.saveMode) || 'full',
      screenshot: cleanString(input.options?.screenshot || input.screenshot),
      platform: cleanString(input.options?.platform || input.platform) || 'web',
      captureAgain: input.options?.captureAgain === true,
      siteData: input.options?.siteData && typeof input.options.siteData === 'object'
        ? input.options.siteData
        : {},
      download: input.options?.download && typeof input.options.download === 'object'
        ? input.options.download
        : {}
    }
  };

  intent.fingerprint = cleanString(input.fingerprint) || captureFingerprint(intent);
  return intent;
}
