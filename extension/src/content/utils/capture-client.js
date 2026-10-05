/**
 * The only content-script capture transport. Site integrations describe an
 * intent; the background CaptureRuntime owns persistence and server I/O.
 */
const captureBrowser = globalThis.browser || globalThis.chrome;

function pageDefaults(page = {}) {
  return {
    title: page.title || document.title || '',
    author: page.author || '',
    description: page.description || '',
    publishedAt: page.publishedAt || '',
    canonicalUrl: page.canonicalUrl || '',
    siteName: page.siteName || '',
    language: page.language || document.documentElement?.lang || '',
    image: page.image || '',
    schemaTypes: page.schemaTypes || []
  };
}

async function submitCapture({
  kind = 'page',
  targetUrl,
  sourcePageUrl = globalThis.location?.href || targetUrl,
  page = {},
  media = null,
  selection = null,
  user = {},
  options = {}
}) {
  return captureBrowser.runtime.sendMessage({
    action: 'capture.submit',
    intent: {
      kind,
      targetUrl,
      sourcePageUrl,
      page: pageDefaults(page),
      media,
      selection,
      user,
      options
    }
  });
}

const NoDrawCapture = Object.freeze({ submit: submitCapture });
globalThis.NoDrawCapture = NoDrawCapture;
