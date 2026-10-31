'use strict';

const ENTITIES = { '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'", '&nbsp;': ' ' };

function decodeEntities(s = '') {
  return String(s)
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(parseInt(d, 10)))
    .replace(/&(amp|lt|gt|quot|#39|nbsp);/g, (m) => ENTITIES[m] ?? m);
}

function stripTags(s = '') {
  return decodeEntities(String(s).replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim();
}

function parsePriceCents(value) {
  if (value == null) return null;
  if (typeof value === 'number' && Number.isFinite(value)) return Math.round(value * 100);
  const raw = String(value).trim();
  if (!raw) return null;
  const cleaned = raw.replace(/[^\d,.-]/g, '');
  if (!cleaned) return null;
  const lastDot = cleaned.lastIndexOf('.');
  const lastComma = cleaned.lastIndexOf(',');
  const lastSep = Math.max(lastDot, lastComma);
  let normalized;
  if (lastSep !== -1 && cleaned.length - lastSep - 1 >= 1 && cleaned.length - lastSep - 1 <= 2) {
    const dec = cleaned[lastSep];
    const other = dec === '.' ? ',' : '.';
    const withoutOther = cleaned.split(other).join('');
    const idx = withoutOther.lastIndexOf(dec);
    normalized = withoutOther.slice(0, idx) + '.' + withoutOther.slice(idx + 1);
  } else {
    normalized = cleaned.replace(/[.,]/g, '');
  }
  if (!normalized) return null;
  const n = Number(normalized);
  return Number.isFinite(n) ? Math.round(n * 100) : null;
}

function mapAvailability(value) {
  const v = String(value ?? '').toLowerCase();
  if (!v) return 'unknown';
  if (/(outofstock|out_of_stock|soldout|unavailable|not available|nicht verfügbar|ausverkauft)/.test(v)) return 'outofstock';
  if (/(preorder|backorder|vorbestellung)/.test(v)) return 'preorder';
  if (/(instock|in_stock|available|lieferbar|auf lager)/.test(v)) return 'instock';
  return 'unknown';
}

function extractJsonLd(html) {
  const out = [];
  const re = /<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let m;
  while ((m = re.exec(html))) {
    try {
      const parsed = JSON.parse(m[1].trim());
      if (Array.isArray(parsed)) out.push(...parsed);
      else out.push(parsed);
    } catch { /* malformed JSON-LD ignorieren */ }
  }
  return out;
}

function findProduct(node) {
  if (!node || typeof node !== 'object') return null;
  const type = node['@type'];
  const types = Array.isArray(type) ? type : [type];
  if (types.includes('Product')) return node;
  for (const key of ['@graph', 'itemListElement', 'mainEntity']) {
    const child = node[key];
    if (Array.isArray(child)) {
      for (const c of child) {
        const found = findProduct(c?.item ?? c);
        if (found) return found;
      }
    } else if (child) {
      const found = findProduct(child);
      if (found) return found;
    }
  }
  return null;
}

function pickOffer(product) {
  const offers = Array.isArray(product.offers) ? product.offers : [product.offers];
  const first = offers.find(Boolean) ?? {};
  const low = first.lowPrice ?? first.price;
  const high = first.highPrice ?? first.price;
  return {
    priceCents: parsePriceCents(low),
    highCents: parsePriceCents(high),
    currency: first.priceCurrency ?? 'EUR',
    availability: mapAvailability(first.availability)
  };
}

function slugFromUrl(url) {
  try {
    const p = new URL(url).pathname.replace(/\/+$/, '');
    return p.split('/').filter(Boolean).pop() ?? null;
  } catch { return null; }
}

function extractProduct(html, url) {
  const product = extractJsonLd(html).map(findProduct).find(Boolean);
  if (!product) return null;
  const offer = pickOffer(product);
  const image = Array.isArray(product.image) ? product.image[0] : product.image;
  const brand = typeof product.brand === 'object' ? product.brand?.name : product.brand;
  const category = typeof product.category === 'object' ? product.category?.name : product.category;
  const attributes = {};
  if (offer.highCents && offer.highCents !== offer.priceCents) {
    attributes.price_range = { low_cents: offer.priceCents, high_cents: offer.highCents };
  }
  return {
    sku: product.sku ? String(product.sku).trim() : null,
    slug: slugFromUrl(url),
    name: stripTags(product.name ?? ''),
    description: stripTags(product.description ?? ''),
    price_cents: offer.priceCents,
    currency: String(offer.currency || 'EUR').toUpperCase(),
    availability: offer.availability,
    category: category ? stripTags(category) : null,
    brand: brand ? stripTags(brand) : null,
    attributes,
    image_url: typeof image === 'string' ? image : image?.url ?? null,
    product_url: url
  };
}

function normalizeProduct(raw, url) {
  const p = { ...raw, product_url: raw.product_url ?? url };
  if (!p.name) throw new Error('product without name');
  if (!p.slug) p.slug = slugFromUrl(url);
  if (!p.sku) p.sku = p.slug;
  if (!p.sku) throw new Error('product without sku or slug');
  const defaults = {
    description: '',
    price_cents: null,
    currency: 'EUR',
    availability: 'unknown',
    category: null,
    brand: null,
    attributes: {},
    image_url: null
  };
  for (const [key, value] of Object.entries(defaults)) {
    if (p[key] == null) p[key] = value;
  }
  return p;
}

module.exports = {
  decodeEntities, stripTags, parsePriceCents, mapAvailability,
  extractJsonLd, findProduct, pickOffer, slugFromUrl, extractProduct, normalizeProduct
};
