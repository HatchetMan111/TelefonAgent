#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dryRun = process.argv.includes('--dry-run');

function loadEnv(envPath = path.join(ROOT, '.env')) {
  if (!fs.existsSync(envPath)) return;
  for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (!m || process.env[m[1]]) continue;
    let value = m[2];
    if (value.length >= 2 && (value[0] === '"' || value[0] === "'") && value.at(-1) === value[0]) {
      value = value.slice(1, -1);
    }
    process.env[m[1]] = value;
  }
}

async function main() {
  loadEnv();
  const payload = JSON.parse(fs.readFileSync(path.join(ROOT, 'elevenlabs', 'phone-number.json'), 'utf8'));
  payload.agent_id = process.env.ELEVENLABS_AGENT_ID;
  payload.phone_number = process.env.ELEVENLABS_PHONE_NUMBER;
  payload.inbound_trunk_config.allowed_addresses = [process.env.SIP_PROVIDER_IP];

  const required = {
    ELEVENLABS_API_KEY: process.env.ELEVENLABS_API_KEY,
    ELEVENLABS_AGENT_ID: process.env.ELEVENLABS_AGENT_ID,
    ELEVENLABS_PHONE_NUMBER: process.env.ELEVENLABS_PHONE_NUMBER,
    SIP_PROVIDER_IP: process.env.SIP_PROVIDER_IP
  };
  const unusable = Object.entries(required)
    .filter(([, value]) => !value || value.includes('CHANGE_ME') || value === '+49...')
    .map(([name]) => name);
  if (unusable.length) throw new Error(`Platzhalter in .env ausfüllen: ${unusable.join(', ')}`);
  if (!/^\+[1-9]\d{6,14}$/.test(payload.phone_number)) {
    throw new Error(`ELEVENLABS_PHONE_NUMBER ist keine gültige E.164-Nummer: ${payload.phone_number}`);
  }

  if (dryRun) {
    console.log(JSON.stringify(payload, null, 2));
    return;
  }

  const headers = {
    'xi-api-key': process.env.ELEVENLABS_API_KEY,
    'Content-Type': 'application/json'
  };
  const base = 'https://api.elevenlabs.io/v1/convai/phone-numbers';
  const listRes = await fetch(base, { headers });
  if (!listRes.ok) throw new Error(`${listRes.status} ${await listRes.text()}`);
  const list = (await listRes.json()).phone_numbers ?? [];
  const existing = list.find((p) => p.phone_number === payload.phone_number);
  const url = existing ? `${base}/${existing.phone_number_id ?? existing.id}` : base;
  const body = existing
    ? {
        agent_id: payload.agent_id,
        label: payload.label,
        inbound_trunk_config: payload.inbound_trunk_config
      }
    : payload;
  const res = await fetch(url, {
    method: existing ? 'PATCH' : 'POST',
    headers,
    body: JSON.stringify(body)
  });
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  console.log(JSON.stringify(await res.json(), null, 2));
}

main().catch((e) => { console.error(e.message); process.exit(1); });
