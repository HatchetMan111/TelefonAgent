#!/usr/bin/env node
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);
const { parseSitemap } = require('../n8n/code/sitemap-urls.js');

export async function resolveProductUrls({ sitemapUrl, pattern, maxChild = 20, fetchText }) {
  const root = parseSitemap(await fetchText(sitemapUrl), pattern);
  let urls = [];
  if (root.kind === 'urlset') {
    urls = root.urls;
  } else {
    if (root.urls.length > maxChild) throw new Error(`Sitemap-Index zu groß: ${root.urls.length}`);
    for (const child of root.urls) {
      const parsed = parseSitemap(await fetchText(child), pattern);
      if (parsed.kind === 'index') throw new Error(`verschachtelter Sitemap-Index: ${child}`);
      urls.push(...parsed.urls);
    }
  }
  urls = [...new Set(urls)];
  if (urls.length === 0) throw new Error('keine Produkt-URLs gefunden');
  return urls;
}

async function fetchText(url) {
  const res = await fetch(url, {
    headers: { 'user-agent': 'ShopAgentCrawler/1.0' },
    signal: AbortSignal.timeout(30000)
  });
  if (!res.ok) throw new Error(`${res.status} ${url}`);
  return res.text();
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  resolveProductUrls({
    sitemapUrl: process.env.SHOP_SITEMAP_URL,
    pattern: process.env.SHOP_PRODUCT_PATTERN || '/(produkt|product|p)/',
    maxChild: Number(process.env.SITEMAP_MAX_CHILD || 20),
    fetchText
  }).then((urls) => process.stdout.write(JSON.stringify(urls)))
    .catch((e) => { console.error(e.message); process.exit(1); });
}
