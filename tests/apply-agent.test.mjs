import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildAgentPayload, buildToolPayload, loadEnv } from '../elevenlabs/apply-agent.mjs';

test('buildToolPayload ersetzt Tunnel und Secret', () => {
  const tool = {
    tool_config: {
      type: 'webhook',
      name: 'search_products',
      api_schema: {
        url: 'https://TUNNEL_HOST/webhook/shopagent/search',
        method: 'POST',
        request_headers: { Authorization: 'Bearer AGENT_WEBHOOK_SECRET' }
      }
    }
  };
  const out = buildToolPayload(tool, { tunnelHost: 'agent.example.de', secret: 'abc123' });
  assert.equal(out.tool_config.api_schema.url, 'https://agent.example.de/webhook/shopagent/search');
  assert.equal(out.tool_config.api_schema.request_headers.Authorization, 'Bearer abc123');
  assert.equal(tool.tool_config.api_schema.url, 'https://TUNNEL_HOST/webhook/shopagent/search');
});

test('buildAgentPayload ersetzt Variablen und Transfer-Nummer', () => {
  process.env.SHOP_NAME = 'Testshop';
  process.env.HUMAN_TRANSFER_NUMBER = '+4915112345678';
  const agent = {
    conversation_config: {
      agent: {
        first_message: 'Hallo {{shop_name}}',
        prompt: {
          prompt: '',
          built_in_tools: {
            transfer_to_number: {
              params: {
                transfers: [{
                  transfer_destination: { type: 'phone', phone_number: 'HUMAN_TRANSFER_NUMBER' },
                  condition: 'Beschwerde'
                }]
              }
            }
          }
        }
      },
      tts: { voice_id: 'alt' }
    }
  };
  const out = buildAgentPayload(agent, 'Prompt');
  assert.equal(out.conversation_config.agent.first_message, 'Hallo Testshop');
  assert.equal(out.conversation_config.agent.prompt.prompt, 'Prompt');
  assert.equal(
    out.conversation_config.agent.prompt.built_in_tools.transfer_to_number
      .params.transfers[0].transfer_destination.phone_number,
    '+4915112345678'
  );
  assert.equal(
    agent.conversation_config.agent.prompt.built_in_tools.transfer_to_number
      .params.transfers[0].transfer_destination.phone_number,
    'HUMAN_TRANSFER_NUMBER'
  );
});

test('loadEnv entfernt passende einfache und doppelte Anführungszeichen', () => {
  const names = ['TEST_ENV_DOUBLE', 'TEST_ENV_SINGLE', 'TEST_ENV_PLAIN', 'TEST_ENV_MISMATCH'];
  for (const name of names) delete process.env[name];
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'apply-agent-')), '.env');
  fs.writeFileSync(file, [
    'TEST_ENV_DOUBLE="quoted value"',
    "TEST_ENV_SINGLE='single value'",
    'TEST_ENV_PLAIN=plain value',
    'TEST_ENV_MISMATCH="half',
    ''
  ].join('\n'));
  try {
    loadEnv(file);
    assert.equal(process.env.TEST_ENV_DOUBLE, 'quoted value');
    assert.equal(process.env.TEST_ENV_SINGLE, 'single value');
    assert.equal(process.env.TEST_ENV_PLAIN, 'plain value');
    assert.equal(process.env.TEST_ENV_MISMATCH, '"half');
  } finally {
    for (const name of names) delete process.env[name];
    fs.rmSync(path.dirname(file), { recursive: true, force: true });
  }
});
