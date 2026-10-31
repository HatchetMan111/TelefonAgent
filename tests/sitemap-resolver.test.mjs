import test from 'node:test';
import assert from 'node:assert/strict';
import { resolveProductUrls } from '../scripts/sitemap-urls.mjs';

const docs = {
  'https://s/sitemap.xml': '<sitemapindex><sitemap><loc>https://s/s1.xml</loc></sitemap><sitemap><loc>https://s/s2.xml</loc></sitemap></sitemapindex>',
  'https://s/s1.xml': '<urlset><url><loc>https://s/produkt/a</loc></url><url><loc>https://s/warenkorb</loc></url></urlset>',
  'https://s/s2.xml': '<urlset><url><loc>https://s/produkt/b</loc></url><url><loc>https://s/produkt/a</loc></url></urlset>'
};

test('löst Sitemap-Index auf und dedupliziert', async () => {
  const urls = await resolveProductUrls({
    sitemapUrl: 'https://s/sitemap.xml', pattern: '/produkt/',
    fetchText: async (u) => docs[u]
  });
  assert.deepEqual(urls, ['https://s/produkt/a', 'https://s/produkt/b']);
});

test('wirft bei leerer Sitemap', async () => {
  await assert.rejects(() => resolveProductUrls({
    sitemapUrl: 'https://s/empty.xml', pattern: '/produkt/',
    fetchText: async () => '<urlset></urlset>'
  }), /keine Produkt-URLs/);
});
