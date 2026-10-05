const DIRECT_CAPTURE_RULES = [
  {
    hosts: new Set(['x.com', 'twitter.com']),
    matches: url => /^\/(?:[^/]+\/status|i\/(?:web\/)?status)\/\d+(?:\/|$)/.test(url.pathname),
    message: 'Open a specific post before archiving from X.'
  },
  {
    hosts: new Set(['youtube.com']),
    matches: url => (url.pathname === '/watch' && Boolean(url.searchParams.get('v')))
      || /^\/(?:shorts|live)\/[^/]+(?:\/|$)/.test(url.pathname),
    message: 'Open a specific video before archiving from YouTube.'
  },
  {
    hosts: new Set(['youtu.be']),
    matches: url => /^\/[^/]+(?:\/|$)/.test(url.pathname),
    message: 'Open a specific video before archiving from YouTube.'
  },
  {
    hosts: new Set(['bsky.app']),
    matches: url => /^\/profile\/[^/]+\/post\/[^/]+(?:\/|$)/.test(url.pathname),
    message: 'Open a specific post before archiving from Bluesky.'
  },
  {
    hosts: new Set(['reddit.com']),
    matches: url => /(?:^|\/)comments\/[^/]+(?:\/|$)/.test(url.pathname)
      || /^\/gallery\/[^/]+(?:\/|$)/.test(url.pathname),
    message: 'Open a specific post before archiving from Reddit.'
  }
];

function normalizedHost(url) {
  return url.hostname.toLowerCase().replace(/\.$/, '').replace(/^(?:www|old|new|m|mobile)\./, '');
}

/**
 * Return a user-facing reason when a known multi-item site URL is a feed,
 * profile, search, or other collection instead of one specific item.
 * Unknown sites remain valid page captures.
 */
export function collectionCaptureBlockReason(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    return 'Open a valid page before archiving.';
  }
  if (!['http:', 'https:'].includes(url.protocol) || !url.hostname) {
    return 'Open a valid page before archiving.';
  }

  const host = normalizedHost(url);
  const rule = DIRECT_CAPTURE_RULES.find(candidate => candidate.hosts.has(host));
  if (!rule || rule.matches(url)) return null;
  return rule.message;
}
