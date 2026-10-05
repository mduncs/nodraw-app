import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import { extractPageContext } from '../../src/content/extract-page.js';

const fixtureUrl = new URL('../fixtures/page-contexts.json', import.meta.url);
const fixtures = JSON.parse(await readFile(fixtureUrl, 'utf8'));

function fakeDocument(fixture) {
  const elements = new Map(Object.entries(fixture.selectors || {}).map(([selector, attributes]) => [
    selector,
    { getAttribute: name => attributes[name] ?? null }
  ]));
  const scripts = (fixture.jsonLd || []).map(value => ({
    textContent: typeof value === 'string' ? value : JSON.stringify(value)
  }));

  return {
    title: fixture.title || '',
    location: { href: fixture.url || '' },
    documentElement: { lang: fixture.language || '' },
    querySelector: selector => elements.get(selector) || null,
    querySelectorAll: selector => selector === 'script[type="application/ld+json"]' ? scripts : [],
    createElement: () => ({
      innerHTML: '',
      append(fragment) {
        this.innerHTML = fragment.html;
      }
    })
  };
}

function fakeSelection(fixture) {
  if (!fixture) return null;
  return {
    rangeCount: 1,
    toString: () => fixture.text,
    getRangeAt: () => ({ cloneContents: () => ({ html: fixture.html }) })
  };
}

for (const fixture of fixtures) {
  test(`extracts ${fixture.name}`, () => {
    const result = extractPageContext(
      fakeDocument(fixture.document),
      fakeSelection(fixture.selection)
    );
    assert.deepEqual(result, fixture.expected);
  });
}

test('a selection without a range preserves text without throwing', () => {
  const result = extractPageContext(fakeDocument({ url: 'https://example.com' }), {
    rangeCount: 0,
    toString: () => 'Copied text'
  });
  assert.deepEqual(result.selection, { text: 'Copied text', html: '' });
});
