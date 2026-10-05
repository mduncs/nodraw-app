function content(document, selector, attribute = 'content') {
  return document.querySelector(selector)?.getAttribute(attribute)?.trim() || '';
}

function first(...values) {
  return values.find(value => typeof value === 'string' && value.trim())?.trim() || '';
}

function schemaTypes(document) {
  const types = new Set();
  for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
    try {
      const value = JSON.parse(script.textContent || 'null');
      const nodes = Array.isArray(value) ? value : [value];
      for (const node of nodes) {
        const graph = Array.isArray(node?.['@graph']) ? node['@graph'] : [node];
        for (const item of graph) {
          const rawTypes = Array.isArray(item?.['@type']) ? item['@type'] : [item?.['@type']];
          rawTypes.filter(Boolean).forEach(type => types.add(String(type)));
        }
      }
    } catch {
      // Invalid publisher JSON-LD should not make capture fail.
    }
  }
  return [...types];
}

export function extractPageContext(document, selection = null) {
  const locationUrl = document.location?.href || '';
  const canonicalUrl = content(document, 'link[rel="canonical"]', 'href');
  return {
    page: {
      title: first(content(document, 'meta[property="og:title"]'), document.title),
      canonicalUrl,
      author: first(
        content(document, 'meta[name="author"]'),
        content(document, 'meta[property="article:author"]')
      ),
      description: first(
        content(document, 'meta[property="og:description"]'),
        content(document, 'meta[name="description"]')
      ),
      publishedAt: first(
        content(document, 'meta[property="article:published_time"]'),
        content(document, 'time[datetime]', 'datetime')
      ),
      siteName: content(document, 'meta[property="og:site_name"]'),
      language: document.documentElement?.lang || '',
      image: first(
        content(document, 'meta[property="og:image"]'),
        content(document, 'meta[name="twitter:image"]')
      ),
      schemaTypes: schemaTypes(document)
    },
    sourcePageUrl: locationUrl,
    selection: selection ? {
      text: selection.toString(),
      html: selection.rangeCount
        ? (() => {
            const container = document.createElement('div');
            container.append(selection.getRangeAt(0).cloneContents());
            return container.innerHTML;
          })()
        : ''
    } : null
  };
}
