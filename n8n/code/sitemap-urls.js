'use strict';
// Wird vom Sitemap-Resolver (scripts/sitemap-urls.mjs) verwendet.
function parseSitemap(xml, productPattern) {
  const urls = [];
  const isIndex = /<sitemapindex[\s>]/i.test(xml);
  const re = /<loc>\s*([^<\s]+)\s*<\/loc>/gi;
  let m;
  while ((m = re.exec(xml))) urls.push(m[1].replace(/&amp;/g, '&'));
  if (isIndex) return { kind: 'index', urls };
  const raw = String(productPattern);
  const source = raw.startsWith('/') && raw.lastIndexOf('/') > 0
    ? raw.slice(1, raw.lastIndexOf('/'))
    : raw;
  const pattern = new RegExp(`(?:^|/)(${source})(?:/|$)`, 'i');
  const exclude = /(?:^|\/)(?:warenkorb|cart|checkout|kasse|account|konto|search|suche|filter)(?:\/|$)/i;
  const pathOf = (u) => {
    try { return new URL(u).pathname; } catch { return u; }
  };
  const products = urls.filter((u) => {
    const path = pathOf(u);
    return !exclude.test(path) && pattern.test(path);
  });
  return { kind: 'urlset', urls: products };
}
module.exports = { parseSitemap };
