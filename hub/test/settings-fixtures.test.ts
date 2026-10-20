// Canonical Settings frames (hub -> clients), type-checked against the protocol. With DUET_FIXTURES_DIR set they are
// written to settings.jsonl, which the Swift tests decode (and round-trip, for the fleet event).
import { test } from 'node:test';
import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import type { EndpointView, ServerFrame } from '../src/protocol.ts';

const lm: EndpointView = { id: 'lm-studio', name: 'LM Studio', baseUrl: 'http://127.0.0.1:1234/v1', model: 'qwen3-coder-30b', hasApiKey: true, enabled: true };
const vllm: EndpointView = { id: 'vllm', name: 'vLLM', baseUrl: 'http://my-gpu-box:8000/v1', model: 'qwen3-coder', hasApiKey: false, enabled: false };

export const SETTINGS_FRAMES: ServerFrame[] = [
  { type: 'ack', ref: '61', ok: true, scan: { host: 'my-gpu-box', platform: 'linux', scannedAt: 1792500000000, agents: [
    { id: 'claude', name: 'Claude Code', command: 'claude', state: 'ready', path: '/home/you/.local/bin/claude', version: '2.1.303' },
    { id: 'codex', name: 'Codex CLI', command: 'codex', state: 'needs_sign_in', path: '/usr/local/bin/codex', version: '0.47.0', signIn: 'Run `codex login` on this machine (or set OPENAI_API_KEY). (Looked for: OPENAI_API_KEY, $CODEX_HOME/auth.json (~/.codex/auth.json).)' },
    { id: 'cursor', name: 'Cursor CLI', command: 'cursor-agent', state: 'not_installed' },
    { id: 'gemini', name: 'Gemini CLI', command: 'gemini', state: 'ready', path: '/usr/local/bin/gemini', problem: '`gemini --version` failed (no answer within 5 s): it may not run. Reinstall it?' },
  ] } },
  { type: 'ack', ref: '63', ok: true, endpoints: [lm, vllm] },
  { type: 'ack', ref: '64', ok: true, endpoint: lm },
  { type: 'ack', ref: '64', ok: false, error: 'The base URL must end in /v1 (e.g. http://127.0.0.1:1234/v1)' },
  { type: 'ack', ref: '68', ok: true, test: { ok: true, models: ['qwen3-coder-30b', 'gemma4-26b', 'text-embedding-nomic'], ms: 42 } },
  { type: 'ack', ref: '69', ok: true, test: { ok: false, models: [], error: 'the API key was refused: Invalid API key', ms: 120, status: 401 } },
  { type: 'ack', ref: '67', ok: false, error: 'LM Studio has a task running or waiting: stop it (or let it finish), then remove it' },
  { type: 'endpoints', endpoints: [lm, vllm] },
  { type: 'endpoints', endpoints: [] },
  { seq: 1, ts: 1792500000000, type: 'fleet', workers: [
    { id: 'lm-studio', label: 'LM Studio · qwen3-coder-30b', backend: 'openai', model: 'qwen3-coder-30b', enabled: true, available: true, loaded: true, effort: 'default', effortLevels: [], tokPerS: 61.5, verifiedEffort: false, running: null, queue: [], fromSettings: true },
    { id: 'vllm', label: 'vLLM · qwen3-coder', backend: 'openai', model: 'qwen3-coder', enabled: false, available: false, loaded: false, effort: 'default', effortLevels: [], tokPerS: null, verifiedEffort: false, running: null, queue: [], fromSettings: true },
  ] },
];

test('settings frame fixtures', () => {
  const dir = process.env.DUET_FIXTURES_DIR;
  if (!dir) return;
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'settings.jsonl'), SETTINGS_FRAMES.map((m) => JSON.stringify(m)).join('\n') + '\n');
});
