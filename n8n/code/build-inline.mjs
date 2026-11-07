#!/usr/bin/env node
import fs from 'node:fs';
const dir = new URL('.', import.meta.url);
const strip = (s) => s.replace(/\nmodule\.exports[\s\S]*$/m, '');
const extract = strip(fs.readFileSync(new URL('extract-products.js', dir), 'utf8'));
fs.writeFileSync('/tmp/extract-node.js', `${extract}
const url = $('Batch: Produkt-URLs').item.json.url;
const runId = $('Run starten').first().json.id;
if ($json.error) return [{ json: { __error: $json.error?.message ?? String($json.error), url, run_id: runId } }];
const html = $json.data?.rawHtml ?? $json.rawHtml ?? $json.data?.html ?? '';
let raw;
try { raw = extractProduct(html, url); }
catch (e) { return [{ json: { __error: e.message, url, run_id: runId } }]; }
if (!raw) return [{ json: { __error: 'kein JSON-LD-Produkt', url, run_id: runId } }];
try { return [{ json: { ...normalizeProduct(raw, url), run_id: runId } }]; }
catch (e) { return [{ json: { __error: e.message, url, run_id: runId } }]; }
`);
console.log('erzeugt: /tmp/extract-node.js');
