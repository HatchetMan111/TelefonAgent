'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  parsePriceCents, mapAvailability, extractProduct, normalizeProduct, slugFromUrl
} = require('../n8n/code/extract-products.js');

const fixture = (name) => fs.readFileSync(path.join(__dirname, 'fixtures', name), 'utf8');

test('parsePriceCents: deutsche und internationale Formate', () => {
  assert.equal(parsePriceCents('89,90 €'), 8990);
  assert.equal(parsePriceCents('1.234,56 €'), 123456);
  assert.equal(parsePriceCents('129.90'), 12990);
  assert.equal(parsePriceCents(89.9), 8990);
  assert.equal(parsePriceCents(''), null);
  assert.equal(parsePriceCents(null), null);
});

test('mapAvailability', () => {
  assert.equal(mapAvailability('https://schema.org/InStock'), 'instock');
  assert.equal(mapAvailability('https://schema.org/OutOfStock'), 'outofstock');
  assert.equal(mapAvailability('https://schema.org/PreOrder'), 'preorder');
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

test('normalizeProduct: SKU fehlt -> Slug, sonst Fehler', () => {
  const ok = normalizeProduct({ name: 'X', slug: 'x-1', sku: null }, 'https://shop.example/produkt/x-1');
  assert.equal(ok.sku, 'x-1');
  assert.throws(() => normalizeProduct({ name: 'X', sku: null, slug: null }, 'kaputt'), /sku or slug/);
});
