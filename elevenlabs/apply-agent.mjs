#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const API = 'https://api.elevenlabs.io/v1/convai';
const dryRun = process.argv.includes('--dry-run');

function loadEnv(envPath = path.join(ROOT, '.env')) {
  if (!fs.existsSync(envPath)) return;
  for (const line of fs.readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (!m || process.env[m[1]]) continue;
    let value = m[2].trim();
    if (value.length >= 2 && (value[0] === '"' || value[0] === "'") && value.at(-1) === value[0]) {
      value = value.slice(1, -1);
    }
    process.env[m[1]] = value;
  }
}

const isMain = process.argv[1] !== undefined
  && fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);
if (isMain) loadEnv();
const key = process.env.ELEVENLABS_API_KEY;
const agentId = process.env.ELEVENLABS_AGENT_ID;

function buildAgentPayload(agent, prompt) {
  const clone = structuredClone(agent);
  const vars = {
    '{{shop_name}}': process.env.SHOP_NAME || 'unserem Shop',
    '{{shop_url}}': process.env.SHOP_BASE_URL || process.env.SHOP_URL || ''
  };
  const fill = (text) => Object.entries(vars)
    .reduce((acc, [key, value]) => acc.replaceAll(key, value), String(text));
  clone.conversation_config.agent.first_message =
    fill(clone.conversation_config.agent.first_message);
  clone.conversation_config.agent.prompt.prompt = fill(prompt);
  clone.conversation_config.tts.voice_id =
    process.env.ELEVENLABS_VOICE_ID || clone.conversation_config.tts.voice_id;
  clone.conversation_config.agent.prompt.llm =
    process.env.ELEVENLABS_LLM || clone.conversation_config.agent.prompt.llm;
  const transfers = clone.conversation_config.agent.prompt
    .built_in_tools?.transfer_to_number?.params?.transfers ?? [];
  for (const transfer of transfers) {
    const destination = transfer.transfer_destination;
    if (destination?.phone_number === 'HUMAN_TRANSFER_NUMBER') {
      destination.phone_number = process.env.HUMAN_TRANSFER_NUMBER || destination.phone_number;
    }
  }
  return clone;
}

function buildToolPayload(tool, { tunnelHost, secret }) {
  const clone = structuredClone(tool);
  const schema = clone.tool_config?.api_schema;
  if (!schema) throw new Error(`Tool ohne api_schema: ${clone.tool_config?.name ?? clone.name}`);
  schema.url = schema.url.replace('TUNNEL_HOST', tunnelHost);
  schema.request_headers = {
    ...(schema.request_headers || {}),
    Authorization: `Bearer ${secret}`
  };
  return clone;
}

async function api(pathname, options = {}) {
  const res = await fetch(`${API}${pathname}`, {
    ...options,
    headers: {
      'xi-api-key': key,
      'Content-Type': 'application/json',
      ...(options.headers || {})
    }
  });
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  return res.json();
}

async function main() {
  const required = {
    TUNNEL_HOST: process.env.TUNNEL_HOST,
    AGENT_WEBHOOK_SECRET: process.env.AGENT_WEBHOOK_SECRET,
    ELEVENLABS_VOICE_ID: process.env.ELEVENLABS_VOICE_ID,
    HUMAN_TRANSFER_NUMBER: process.env.HUMAN_TRANSFER_NUMBER
  };
  const unusable = Object.entries(required)
    .filter(([, value]) => !value || value.includes('CHANGE_ME') || value === '+49...')
    .map(([name]) => name);
  if (unusable.length) throw new Error(`Platzhalter in .env ausfüllen: ${unusable.join(', ')}`);

  const prompt = fs.readFileSync(path.join(ROOT, 'elevenlabs', 'prompt.md'), 'utf8');
  const agent = JSON.parse(fs.readFileSync(path.join(ROOT, 'elevenlabs', 'agent.json'), 'utf8'));
  const toolFiles = fs.readdirSync(path.join(ROOT, 'elevenlabs', 'tools')).filter((f) => f.endsWith('.json'));
  const tools = toolFiles.map((f) => buildToolPayload(
    JSON.parse(fs.readFileSync(path.join(ROOT, 'elevenlabs', 'tools', f), 'utf8')),
    { tunnelHost: process.env.TUNNEL_HOST, secret: process.env.AGENT_WEBHOOK_SECRET }
  ));

  if (dryRun) {
    console.log(JSON.stringify({ agent: buildAgentPayload(agent, prompt), tools }, null, 2));
    return;
  }
  if (!key || !agentId) throw new Error('ELEVENLABS_API_KEY und ELEVENLABS_AGENT_ID setzen');

  const existing = await api('/tools');
  const list = Array.isArray(existing) ? existing : (existing.tools ?? []);
  const byName = new Map(list.map((t) => [t.tool_config?.name ?? t.name, t.id ?? t.tool_id]));
  const created = [];
  for (const tool of tools) {
    const name = tool.tool_config.name;
    const id = byName.get(name);
    const res = id
      ? await api(`/tools/${id}`, { method: 'PATCH', body: JSON.stringify(tool) })
      : await api('/tools', { method: 'POST', body: JSON.stringify(tool) });
    const toolId = res.id ?? res.tool_id ?? id;
    if (!toolId) throw new Error(`Keine Tool-ID für ${name} erhalten`);
    created.push(toolId);
    console.log(`Tool ${name}: ${toolId}${id ? ' (aktualisiert)' : ' (neu)'}`);
  }

  const payload = buildAgentPayload(agent, prompt);
  payload.conversation_config.agent.prompt.tool_ids = created;
  const updated = await api(`/agents/${agentId}`, { method: 'PATCH', body: JSON.stringify(payload) });
  console.log(`Agent aktualisiert: ${updated.agent_id ?? agentId}`);
  console.log('Tool-IDs am Agenten gesetzt.');
}

if (isMain) {
  main().catch((e) => { console.error(e.message); process.exit(1); });
}
export { buildAgentPayload, buildToolPayload, loadEnv };
