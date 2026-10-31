#!/usr/bin/env node
import fs from 'node:fs';
const dir = new URL('.', import.meta.url);
const strip = (s) => s.replace(/\nmodule\.exports[\s\S]*$/m, '');
const extract = strip(fs.readFileSync(new URL('extract-products.js', dir), 'utf8'));
fs.writeFileSync('/tmp/extract-node.js', `${extract}
const url = $('URLs').item.json.url;
const html = $json.data?.rawHtml ?? $json.rawHtml ?? $json.data?.html ?? '';
const raw = extractProduct(html, url);
if (!raw) return [{ json: { __error: 'kein JSON-LD-Produkt', url } }];
try { return [{ json: normalizeProduct(raw, url) }]; }
catch (e) { return [{ json: { __error: e.message, url } }]; }
`);
console.log('erzeugt: /tmp/extract-node.js');
