#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

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

function requireEnv(name) {
  const value = (process.env[name] ?? '').trim();
  if (!value || value.includes('CHANGE_ME')) {
    throw new Error(`${name} fehlt oder ist ein Platzhalter`);
  }
  return value;
}

loadEnv();
const API = 'https://api.elevenlabs.io/v1/convai';
const API_KEY = requireEnv('ELEVENLABS_API_KEY');
const AGENT = requireEnv('ELEVENLABS_AGENT_ID');
const HEADERS = {
  'xi-api-key': API_KEY,
  'Content-Type': 'application/json'
};

const cases = JSON.parse(fs.readFileSync(path.join(ROOT, 'tests', 'eval-cases.json'), 'utf8'));

async function call(url, options = {}) {
  const res = await fetch(url, { ...options, headers: HEADERS });
  if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
  return res.json();
}

async function createTest(c) {
  const out = await call(`${API}/agent-testing/create`, {
    method: 'POST',
    body: JSON.stringify({
      name: `shopagent-${c.id}`,
      type: 'simulation',
      simulation_scenario: c.scenario,
      simulation_max_turns: 6,
      success_conditions: c.success,
      simulation_environment: 'production',
      conversation_initiation_source: 'sip_trunk'
    })
  });
  if (!out?.id) throw new Error(`createTest lieferte keine id für ${c.id}`);
  return out.id;
}

async function runTests(testIds) {
  const out = await call(`${API}/agents/${AGENT}/run-tests`, {
    method: 'POST',
    body: JSON.stringify({
      name: `shopagent-eval-${Date.now()}`,
      tests: testIds.map((test_id) => ({ test_id }))
    })
  });
  if (!out?.id) throw new Error('runTests lieferte keine invocation id');
  return out;
}

const TERMINAL_STATUSES = new Set(['passed', 'failed', 'cancelled']);
const REPORT = path.join(ROOT, 'eval-report.json');
const POLL_LIMIT = Math.max(60, cases.length * 6);

function buildResults(tests, runs) {
  const byTest = new Map(runs.map((r) => [r.test_id, r]));
  return tests.map(({ id, testId }) => {
    const run = byTest.get(testId) ?? {};
    return {
      id,
      status: run.status ?? 'missing',
      ok: run.status === 'passed',
      rationale: run.condition_result?.rationale?.summary ?? ''
    };
  });
}

async function waitFor(runId, tests) {
  let results = [];
  for (let i = 0; i < POLL_LIMIT; i++) {
    const run = await call(`${API}/test-invocations/${runId}`);
    results = run.test_runs ?? [];
    if (results.length >= tests.length && results.every((r) => TERMINAL_STATUSES.has(r.status))) {
      return results;
    }
    if (i < POLL_LIMIT - 1) await new Promise((resolve) => setTimeout(resolve, 10000));
  }
  fs.writeFileSync(REPORT, JSON.stringify(buildResults(tests, results), null, 2));
  throw new Error('Timeout beim Warten auf den Testlauf');
}

async function deleteTests(testIds) {
  for (const testId of testIds) {
    try {
      const res = await fetch(`${API}/agent-testing/${testId}`, { method: 'DELETE', headers: HEADERS });
      if (!res.ok) console.error(`Warnung: Test ${testId} konnte nicht gelöscht werden (${res.status})`);
    } catch (e) {
      console.error(`Warnung: Test ${testId} konnte nicht gelöscht werden (${e.message})`);
    }
  }
}

const tests = [];
try {
  for (const c of cases) tests.push({ id: c.id, testId: await createTest(c) });

  const invocation = await runTests(tests.map((t) => t.testId));
  const runs = await waitFor(invocation.id, tests);
  const results = buildResults(tests, runs);

  fs.writeFileSync(REPORT, JSON.stringify(results, null, 2));
  const passed = results.filter((r) => r.ok).length;
  console.log(`${passed}/${results.length} bestanden`);
  process.exitCode = passed === results.length ? 0 : 1;
} catch (e) {
  console.error(e.message);
  process.exitCode = 1;
} finally {
  await deleteTests(tests.map((t) => t.testId));
}
