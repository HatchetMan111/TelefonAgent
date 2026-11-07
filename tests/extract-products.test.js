'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  parsePriceCents, mapAvailability, extractProduct, normalizeProduct, slugFromUrl,
  decodeEntities, resolveUrl
} = require('../n8n/code/extract-products.js');

const fixture = (name) => fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8');

test('parsePriceCents: deutsche und internationale Formate', () => {
  assert.equal(parsePriceCents('89,90 €'), 8990);
  assert.equal(parsePriceCents('1.234,56 €'), 123456);
  assert.equal(parsePriceCents('129.90'), 12990);
  assert.equal(parsePriceCents(89.9), 8990);
  assert.equal(parsePriceCents('1.234'), 123400);
  assert.equal(parsePriceCents('89,9'), 8990);
  assert.equal(parsePriceCents('1.234,5'), 123450);
  assert.equal(parsePriceCents('1,234.56'), 123456);
  assert.equal(parsePriceCents(''), null);
  assert.equal(parsePriceCents(null), null);
});

test('mapAvailability', () => {
  assert.equal(mapAvailability('https://schema.org/InStock'), 'instock');
  assert.equal(mapAvailability('https://schema.org/OutOfStock'), 'outofstock');
  assert.equal(mapAvailability('https://schema.org/PreOrder'), 'preorder');
  assert.equal(mapAvailability('unavailable'), 'outofstock');
  assert.equal(mapAvailability('not available'), 'outofstock');
  assert.equal(mapAvailability(''), 'unknown');
});

test('slugFromUrl', () => {
  assert.equal(slugFromUrl('https://shop.example/produkt/regenschuh-42/'), 'regenschuh-42');
  assert.equal(slugFromUrl('kaputt'), null);
});

test('extractProduct: einfaches JSON-LD, Entities und Tags', () => {
  const p = extractProduct(fixture('product-simple.html'), 'https://shop.example/produkt/regenschuh-42');
  assert.equal(p.sku, 'REGEN-42');
  assert.equal(p.name, 'Regenschuh & Sohle');
  assert.equal(p.description, 'Wasserdichter Schuh');
  assert.equal(p.price_cents, 8990);
  assert.equal(p.availability, 'instock');
  assert.equal(p.category, 'Schuhe');
  assert.equal(p.brand, 'Urban');
  assert.equal(p.product_url, 'https://shop.example/produkt/regenschuh-42');
});

test('extractProduct: AggregateOffer nimmt lowPrice und merkt die Spanne', () => {
  const p = extractProduct(fixture('product-aggregate.html'), 'https://shop.example/produkt/regenjacke-1');
  assert.equal(p.price_cents, 12990);
  assert.deepEqual(p.attributes.price_range, { low_cents: 12990, high_cents: 15990 });
  assert.equal(p.availability, 'outofstock');
});

test('extractProduct: ohne JSON-LD null', () => {
  assert.equal(extractProduct(fixture('product-no-jsonld.html'), 'https://shop.example/produkt/x'), null);
});

test('extractProduct: @graph, erstes Angebot mit Preis und relative Bild-URL', () => {
  const p = extractProduct(fixture('product-graph.html'), 'https://shop.example/produkt/baecker-schuerze');
  assert.equal(p.sku, 'APRON-7');
  assert.equal(p.name, 'Bäcker-Schürze');
  assert.equal(p.description, 'Baumwollschürze für die Küche');
  assert.equal(p.price_cents, 2990);
  assert.equal(p.currency, 'EUR');
  assert.equal(p.availability, 'instock');
  assert.equal(p.image_url, 'https://shop.example/img/apron-7.jpg');
  assert.equal(p.product_url, 'https://shop.example/produkt/baecker-schuerze');
});

test('decodeEntities: ungültige Codepoints crashen nicht, deutsche Entities werden dekodiert', () => {
  assert.equal(decodeEntities('B&auml;cker &amp; S&ouml;hne'), 'Bäcker & Söhne');
  assert.equal(decodeEntities('Preis: 10 &euro;'), 'Preis: 10 €');
  assert.equal(decodeEntities('X &#x110000; Y'), 'X &#x110000; Y');
  assert.equal(decodeEntities('A &#xD800; B'), 'A &#xD800; B');
  assert.equal(decodeEntities('A &#55296; B'), 'A &#55296; B');
  assert.equal(decodeEntities('unbekannt &nicht_ENTITY; bleibt'), 'unbekannt &nicht_ENTITY; bleibt');
});

test('resolveUrl: relative und absolute URLs, ohne Basis unverändert', () => {
  assert.equal(resolveUrl('/img/x.jpg', 'https://shop.example/produkt/x'), 'https://shop.example/img/x.jpg');
  assert.equal(resolveUrl('https://cdn.example/x.jpg', 'https://shop.example/'), 'https://cdn.example/x.jpg');
  assert.equal(resolveUrl({ url: '/img/y.jpg' }, 'https://shop.example/'), 'https://shop.example/img/y.jpg');
  assert.equal(resolveUrl(null, 'https://shop.example/'), null);
  assert.equal(resolveUrl('/img/z.jpg', 'kaputt'), '/img/z.jpg');
});

test('normalizeProduct: SKU fehlt -> Slug, sonst Fehler', () => {
  const ok = normalizeProduct({ name: 'X', slug: 'x-1', sku: null }, 'https://shop.example/produkt/x-1');
  assert.equal(ok.sku, 'x-1');
  assert.throws(() => normalizeProduct({ name: 'X', sku: null, slug: null }, 'kaputt'), /sku or slug/);
});

test('normalizeProduct: alle 12 Schlüssel mit Defaults', () => {
  const p = normalizeProduct({ name: 'X', sku: 'S-1' }, 'https://shop.example/produkt/x-1');
  assert.deepEqual(
    Object.keys(p).sort(),
    ['sku', 'slug', 'name', 'description', 'price_cents', 'currency', 'availability',
      'category', 'brand', 'attributes', 'image_url', 'product_url'].sort()
  );
  assert.equal(p.slug, 'x-1');
  assert.equal(p.currency, 'EUR');
  assert.equal(p.availability, 'unknown');
  assert.deepEqual(p.attributes, {});
});
