// A post captured from a feed is titled the way its own permalink page titles it,
// not after the feed's tab ("Home / X"). Empty when there is nothing to name it by,
// so the background's page-title fallback still applies.
export function postTitle(author, text, site, max = 80) {
  const name = String(author || '').split('\n')[0].trim();
  const words = String(text || '').replace(/\s+/g, ' ').trim();
  const snippet = words.length > max ? `${words.slice(0, max - 1).trimEnd()}…` : words;
  if (!name) return snippet ? `"${snippet}"` : '';
  return snippet ? `${name} on ${site}: "${snippet}"` : `${name} on ${site}`;
}
