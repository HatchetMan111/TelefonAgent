'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { parseSitemap } = require('../n8n/code/sitemap-urls.js');

test('urlset filtert Produkt-URLs', () => {
  const xml = `<urlset><url><loc>https://s/produkt/a</loc></url><url><loc>https://s/warenkorb</loc></url></urlset>`;
  assert.deepEqual(parseSitemap(xml, '/(produkt|product|p)/'), {
    kind: 'urlset', urls: ['https://s/produkt/a']
  });
});

test('sitemapindex liefert alle Loc-Einträge', () => {
  const xml = `<sitemapindex><sitemap><loc>https://s/sitemap-1.xml</loc></sitemap></sitemapindex>`;
  assert.deepEqual(parseSitemap(xml, '/produkt/'), {
    kind: 'index', urls: ['https://s/sitemap-1.xml']
  });
});

test('leere Sitemap -> leeres Array', () => {
  assert.deepEqual(parseSitemap('<urlset></urlset>', '/produkt/'), { kind: 'urlset', urls: [] });
});

test('kurzes Produktsegment trifft keine Nicht-Produktpfade', () => {
  const xml = `<urlset>
    <url><loc>https://s/impressum</loc></url>
    <url><loc>https://s/warenkorb</loc></url>
    <url><loc>https://s/p/foo</loc></url>
  </urlset>`;
  assert.deepEqual(parseSitemap(xml, '/p/'), {
    kind: 'urlset', urls: ['https://s/p/foo']
  });
});

test('Produktpfade werden als Pfadsegmente gematcht', () => {
  const xml = `<urlset>
    <url><loc>https://s/shop/produkt/foo</loc></url>
    <url><loc>https://s/shop/warenkorb</loc></url>
    <url><loc>https://s/shop/checkout</loc></url>
  </urlset>`;
  assert.deepEqual(parseSitemap(xml, '/produkt/'), {
    kind: 'urlset', urls: ['https://s/shop/produkt/foo']
  });
});
