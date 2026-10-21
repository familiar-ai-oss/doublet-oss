// Settings → Agents on the hub: coding-agent discovery, the OpenAI-compatible endpoints it keeps (never handing out a
// key), Test Connection, and endpoints joining the fleet beside the fleet file. Model-free: a fake home folder and a
// fake OpenAI-compatible server.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AgentScanner, parseClaudeStatus, parseCodexStatus, parseCursorStatus, runCommand, scanAgents, stripAnsi, versionIn, type ScanEnv } from '../src/agents.ts';
import { EndpointStore, endpointId, modelsIn, normalizeBaseUrl, testEndpoint } from '../src/endpoints.ts';
import { Fleet, loadWorkers, type WorkerDef } from '../src/fleet.ts';
import type { ControlFrame, EventBody } from '../src/protocol.ts';
import { Settings, type SettingsFleet } from '../src/settings.ts';

const dir = mkdtempSync(join(tmpdir(), 'duet-settings-'));
after(() => rmSync(dir, { recursive: true, force: true }));

// ---- a fake OpenAI-compatible server: lists two models, and wants a key if `needKey` ----
let needKey = '';
const hits: { path: string; auth?: string }[] = [];
const server = http.createServer((req, res) => {
  hits.push({ path: req.url ?? '', auth: req.headers.authorization });
  if (needKey && req.headers.authorization !== `Bearer ${needKey}`) return void res.writeHead(401, { 'content-type': 'application/json' }).end(JSON.stringify({ error: { message: 'Incorrect API key provided' } }));
  if (req.url === '/v1/models') return void res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ object: 'list', data: [{ id: 'qwen3-coder', max_model_len: 65536 }, { id: 'gemma4-26b' }] }));
  if (req.url === '/html/v1/models') return void res.writeHead(200, { 'content-type': 'text/html' }).end('<html>hi</html>');
  res.writeHead(404).end();
});
await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${(server.address() as { port: number }).port}/v1`;
// A port nothing listens on.
const closed = http.createServer();
await new Promise<void>((r) => closed.listen(0, '127.0.0.1', r));
const deadBase = `http://127.0.0.1:${(closed.address() as { port: number }).port}/v1`;
closed.close();
after(() => server.close());

test('base URLs and ids', () => {
  assert.equal(normalizeBaseUrl(' http://127.0.0.1:8000/v1/ '), 'http://127.0.0.1:8000/v1');
  assert.equal(normalizeBaseUrl('https://openrouter.ai/api/v1'), 'https://openrouter.ai/api/v1');
  assert.throws(() => normalizeBaseUrl('http://127.0.0.1:8000'), /must end in \/v1 \(e\.g\. http:\/\/127\.0\.0\.1:8000\/v1\)/);
  assert.throws(() => normalizeBaseUrl('ftp://x/v1'), /http:\/\/ or https:\/\//);
  assert.throws(() => normalizeBaseUrl('localhost:8000/v1'), /http:\/\/ or https:\/\/|isn't a URL/);
  assert.throws(() => normalizeBaseUrl(''), /isn't a URL/);
  assert.equal(endpointId('LM Studio (Mac)', new Set()), 'lm-studio-mac');
  assert.equal(endpointId('vLLM', new Set(['vllm', 'vllm-2'])), 'vllm-3');
  assert.equal(endpointId('Claude-proxy', new Set()), 'ep-claude-proxy', "the hub's own prefixes are kept clear");
  assert.equal(endpointId('auto', new Set()), 'ep-auto');
  assert.equal(endpointId('!!!', new Set()), 'endpoint');
  assert.deepEqual(modelsIn({ data: [{ id: 'a', context_length: 8192 }, { id: 'b' }, { nope: 1 }] }), [{ id: 'a', context: 8192 }, { id: 'b' }]);
  assert.deepEqual(modelsIn({ models: ['x'] }), [{ id: 'x' }]);
});

test('the store keeps endpoints in the state folder, readable only by the hub, and changes them whole or not at all', () => {
  const d = join(dir, 'store');
  const s = new EndpointStore(d);
  s.reserved = () => ['ollama'];
  const a = s.add({ name: 'Ollama', baseUrl: 'http://127.0.0.1:11434/v1/', model: 'qwen3:8b' });
  assert.equal(a.id, 'ollama-2', "a fleet file's id isn't taken");
  assert.equal(a.baseUrl, 'http://127.0.0.1:11434/v1');
  assert.equal(a.enabled, true);
  const b = s.add({ name: 'Hosted', baseUrl: 'https://api.example.com/v1', model: 'm', apiKey: ' sk-test ' });
  assert.equal(b.apiKey, 'sk-test');
  assert.equal(statSync(s.file).mode & 0o777, 0o600);
  assert.throws(() => s.add({ name: '', baseUrl: base, model: 'm' }), /name/);
  assert.throws(() => s.add({ name: 'x', baseUrl: base, model: ' ' }), /model/);
  // A bad change changes nothing.
  assert.throws(() => s.update(b.id, { name: 'Renamed', baseUrl: 'https://api.example.com' }), /\/v1/);
  assert.equal(s.get(b.id)?.name, 'Hosted');
  // The key: kept when absent, replaced, then removed with null.
  assert.equal(s.update(b.id, { name: 'Renamed' }).apiKey, 'sk-test');
  assert.equal(s.update(b.id, { apiKey: 'sk-new' }).apiKey, 'sk-new');
  assert.equal('apiKey' in s.update(b.id, { apiKey: null }), false);
  assert.equal(s.update(a.id, { enabled: false }).enabled, false);
  // Read back after a restart.
  const again = new EndpointStore(d);
  assert.deepEqual(again.list().map((e) => [e.id, e.name, e.enabled]), [['ollama-2', 'Ollama', false], ['hosted', 'Renamed', true]]);
  again.remove('ollama-2');
  assert.throws(() => again.remove('ollama-2'), /no endpoint/);
  assert.deepEqual(JSON.parse(readFileSync(again.file, 'utf8')).endpoints.map((e: { id: string }) => e.id), ['hosted']);
});

test('Test Connection lists the models, or says why not', async () => {
  needKey = '';
  const ok = await testEndpoint(`${base}/`);
  assert.equal(ok.ok, true);
  assert.deepEqual(ok.models, ['qwen3-coder', 'gemma4-26b']);
  assert.equal(typeof ok.ms, 'number');

  needKey = 'sk-right';
  const noKey = await testEndpoint(base);
  assert.equal(noKey.ok, false);
  assert.equal(noKey.status, 401);
  assert.match(noKey.error ?? '', /^it needs an API key: Incorrect API key provided/);
  const wrong = await testEndpoint(base, 'sk-wrong');
  assert.match(wrong.error ?? '', /^the API key was refused/);
  hits.length = 0;
  assert.equal((await testEndpoint(base, 'sk-right')).ok, true);
  assert.equal(hits[0].auth, 'Bearer sk-right');
  needKey = '';

  assert.match((await testEndpoint(deadBase)).error ?? '', /connection refused/);
  assert.match((await testEndpoint(base.replace('/v1', '/html/v1'))).error ?? '', /not with JSON/);
  assert.match((await testEndpoint('http://127.0.0.1:1')).error ?? '', /must end in \/v1/);
});

// ---- agent discovery, in a fake home folder ----

function fakeHome(): ScanEnv {
  const home = join(dir, 'home');
  const bin = join(home, 'bin');
  mkdirSync(bin, { recursive: true });
  const exe = (name: string, out: string) => {
    writeFileSync(join(bin, name), `#!/bin/sh\necho "${out}"\n`);
    chmodSync(join(bin, name), 0o755);
  };
  exe('claude', '2.1.303 (Claude Code)');
  exe('codex', 'codex-cli 0.47.0');
  writeFileSync(join(bin, 'broken'), '#!/bin/sh\necho "Error: spawn vendor/codex ENOENT" >&2\nexit 1\n');
  chmodSync(join(bin, 'broken'), 0o755);
  // Cursor: not installed. Codex signed in by its auth file; Claude by the account in ~/.claude.json.
  mkdirSync(join(home, '.codex'), { recursive: true });
  writeFileSync(join(home, '.codex/auth.json'), '{}');
  writeFileSync(join(home, '.claude.json'), JSON.stringify({ oauthAccount: { emailAddress: 'you@example.com' } }));
  return { env: { PATH: bin }, home, platform: 'linux', run: runCommand, host: 'test-host' };
}

test('the scan finds each agent, its version, and whether it is signed in', async () => {
  const s = fakeHome();
  const scan = await scanAgents(s);
  assert.equal(scan.host, 'test-host');
  assert.equal(scan.platform, 'linux');
  const by = Object.fromEntries(scan.agents.map((a) => [a.id, a]));
  assert.deepEqual(scan.agents.map((a) => a.id), ['claude', 'codex', 'cursor']);
  assert.equal(by.claude.state, 'ready');
  assert.equal(by.claude.version, '2.1.303');
  assert.equal(by.claude.path, join(s.home, 'bin/claude'));
  assert.equal(by.codex.state, 'ready');
  assert.equal(by.codex.version, '0.47.0');
  assert.deepEqual(by.cursor, { id: 'cursor', name: 'Cursor CLI', command: 'agent', state: 'not_installed' });
  // DUET_CLAUDE_PATH is the hub's own `claude`, as for the lead.
  const elsewhere = await scanAgents({ ...s, env: { ...s.env, DUET_CLAUDE_PATH: join(s.home, 'nowhere') } });
  assert.equal(elsewhere.agents.find((a) => a.id === 'claude')?.state, 'not_installed');
  // A broken install (its --version fails) is found, with the problem said.
  const broken = await scanAgents({ ...s, env: { ...s.env, DUET_CLAUDE_PATH: join(s.home, 'bin/broken') } });
  const c = broken.agents.find((a) => a.id === 'claude');
  assert.equal(c?.version, undefined);
  assert.match(c?.problem ?? '', /^`claude --version` failed \(Error: spawn vendor\/codex ENOENT\): it may not run/);
  assert.equal(by.codex.problem, undefined);
  assert.equal(versionIn('codex-cli 0.47.0-alpha.2\n'), '0.47.0-alpha.2');
  assert.equal(versionIn(null), undefined);
});

test('each agent\'s own status command is read, and wins over the file guess', () => {
  assert.equal(parseClaudeStatus({ ok: true, out: '{"loggedIn": true, "authMethod": "claude.ai"}' }), true);
  assert.equal(parseClaudeStatus({ ok: false, out: '{"loggedIn": false, "authMethod": "none"}' }), false);
  assert.equal(parseClaudeStatus({ ok: false, out: 'error: unknown command \'auth\'' }), null);
  assert.equal(parseCodexStatus({ ok: true, out: 'Logged in using ChatGPT' }), true);
  assert.equal(parseCodexStatus({ ok: false, out: 'Not logged in' }), false);
  // A broken install says nothing about the sign-in.
  assert.equal(parseCodexStatus({ ok: false, out: 'Error: spawn vendor/codex ENOENT' }), null);
  assert.equal(parseCursorStatus({ ok: true, out: '{"isAuthenticated": true, "email": "you@example.com"}' }), true);
  assert.equal(parseCursorStatus({ ok: false, out: 'error: unknown option \'--format\'' }), null);
  // Cursor 2025's plain status, colour codes and all.
  const old = ' Starting login process...\n\x1b[2K\x1b[1A\x1b[2K\x1b[GChecking authentication status...\n\x1b[2K\x1b[G\n Not logged in\n';
  assert.equal(stripAnsi(old).includes('\x1b'), false);
  assert.equal(parseCursorStatus({ ok: true, out: old }), false);
  assert.equal(parseCursorStatus({ ok: true, out: 'Logged in as you@example.com' }), true);
});

test('Cursor is found as agent or cursor-agent, and an agent\'s own status wins over the file guess', async () => {
  const s = fakeHome();
  const bin = join(s.home, 'bin');
  const exe = (path: string, body: string) => { writeFileSync(path, `#!/bin/sh\n${body}\n`); chmodSync(path, 0o755); };
  // Some other program called `agent` is not Cursor's.
  exe(join(bin, 'agent'), 'echo 1.0');
  assert.equal((await scanAgents(s)).agents.find((a) => a.id === 'cursor')?.state, 'not_installed');
  // Cursor's `agent`, a link into its install folder, whose status says it's signed in.
  rmSync(join(bin, 'agent'));
  const versions = join(s.home, '.local/share/cursor-agent/versions/2026.10.1');
  mkdirSync(versions, { recursive: true });
  exe(join(versions, 'cursor-agent'), 'case "$1" in status) echo \'{"isAuthenticated":true}\';; *) echo 2026.10.1;; esac');
  symlinkSync(join(versions, 'cursor-agent'), join(bin, 'agent'));
  const cursor = (await scanAgents(s)).agents.find((a) => a.id === 'cursor');
  assert.equal(cursor?.command, 'agent');
  assert.equal(cursor?.state, 'ready');
  rmSync(join(bin, 'agent'));

  // Claude's own status says signed out, though ~/.claude.json names an account: the status wins.
  exe(join(bin, 'claude'), 'case "$1" in auth) echo \'{"loggedIn":false}\'; exit 1;; *) echo "2.1.303 (Claude Code)";; esac');
  const claude = (await scanAgents(s)).agents.find((a) => a.id === 'claude');
  assert.equal(claude?.state, 'needs_sign_in');
  assert.match(claude?.signIn ?? '', /Looked for: `claude auth status`/);
});

test('the scanner keeps its last scan until a rescan', async () => {
  let scans = 0;
  const s = fakeHome();
  const scanner = new AgentScanner(() => { scans++; return s; });
  const first = await scanner.list();
  assert.equal(await scanner.list(), first);
  assert.equal(scans, 1);
  const fresh = await scanner.scan();
  assert.notEqual(fresh, first);
  assert.equal(await scanner.list(), fresh);
  assert.equal(scans, 2);
});

// ---- Settings messages, with a stand-in fleet ----

test('Settings adds, changes, tests and removes endpoints, and never sends a key', async () => {
  const synced: WorkerDef[][] = [];
  let busy = '';
  const fleet: SettingsFleet = { syncEndpoints: (d) => synced.push(d), busy: (id) => id === busy, workerIds: () => ['qwen-27b', ...(synced.at(-1) ?? []).map((d) => d.id)] };
  const frames: ControlFrame[] = [];
  const settings = new Settings(new EndpointStore(join(dir, 'settings')), fleet, (f) => frames.push(f), new AgentScanner(fakeHome));
  settings.sync();
  assert.deepEqual(synced.slice(), [[]]);

  const added = await settings.handle({ type: 'endpoint_add', name: 'qwen-27b', baseUrl: base, model: 'qwen3-coder', apiKey: 'sk-secret' });
  assert.deepEqual(added.endpoint, { id: 'qwen-27b-2', name: 'qwen-27b', baseUrl: base, model: 'qwen3-coder', hasApiKey: true, enabled: true });
  // The fleet gets the key (to call the server with); devices get only that there is one.
  assert.deepEqual(synced.at(-1), [{ id: 'qwen-27b-2', label: 'qwen-27b · qwen3-coder', backend: 'openai', url: base, model: 'qwen3-coder', apiKey: 'sk-secret', table: 'none', enabled: true }]);
  assert.deepEqual(frames.at(-1), { type: 'endpoints', endpoints: [added.endpoint] });
  assert.doesNotMatch(JSON.stringify([added, frames, await settings.handle({ type: 'endpoints_list' })]), /sk-secret/);

  // Test a saved one with its stored key, and an unsaved one by URL.
  needKey = 'sk-secret';
  assert.deepEqual((await settings.handle({ type: 'endpoint_test', id: 'qwen-27b-2' })).test?.models, ['qwen3-coder', 'gemma4-26b']);
  assert.equal((await settings.handle({ type: 'endpoint_test', baseUrl: base })).test?.ok, false);
  needKey = '';
  await assert.rejects(settings.handle({ type: 'endpoint_test' }), /base URL/);
  await assert.rejects(settings.handle({ type: 'endpoint_test', id: 'nope' }), /no endpoint nope/);

  const changed = await settings.handle({ type: 'endpoint_update', id: 'qwen-27b-2', model: 'gemma4-26b', apiKey: null, enabled: false });
  assert.deepEqual(changed.endpoint, { id: 'qwen-27b-2', name: 'qwen-27b', baseUrl: base, model: 'gemma4-26b', hasApiKey: false, enabled: false });
  assert.equal(synced.at(-1)?.[0].apiKey, undefined);
  await assert.rejects(settings.handle({ type: 'endpoint_add', name: 'x', baseUrl: 'http://127.0.0.1:1234', model: 'm' }), /\/v1/);

  busy = 'qwen-27b-2';
  await assert.rejects(settings.handle({ type: 'endpoint_remove', id: 'qwen-27b-2' }), /has a task running or waiting/);
  busy = '';
  assert.deepEqual(await settings.handle({ type: 'endpoint_remove', id: 'qwen-27b-2' }), {});
  assert.deepEqual(synced.at(-1), []);
  assert.deepEqual(frames.at(-1), { type: 'endpoints', endpoints: [] });

  const listed = await settings.handle({ type: 'agents_list' });
  assert.equal(listed.scan?.agents.length, 3);
  assert.notEqual((await settings.handle({ type: 'agents_scan' })).scan, listed.scan);
});

// ---- the fleet: the fleet file stays as it was; endpoints join it ----

test('with no fleet file, endpoints stand in for the default Ollama worker unless DUET_OLLAMA_* asks for it', () => {
  const none = join(dir, 'no-fleet.json');
  assert.deepEqual(loadWorkers(none, { env: {} }).map((w) => w.id), ['ollama']);
  assert.deepEqual(loadWorkers(none, { hasEndpoints: true, env: {} }), []);
  assert.deepEqual(loadWorkers(none, { hasEndpoints: true, env: { DUET_OLLAMA_URL: 'http://127.0.0.1:11434' } }).map((w) => w.id), ['ollama']);
  const file = join(dir, 'fleet.json');
  writeFileSync(file, JSON.stringify({ workers: [{ id: 'big', label: 'Big', backend: 'ollama', url: 'http://127.0.0.1:11434', model: 'qwen3:30b', table: 'ollama-onoff', enabled: true }] }));
  assert.deepEqual(loadWorkers(file, { hasEndpoints: true, env: {} }).map((w) => w.id), ['big']);
});

test('endpoints join the fleet as openai workers, checked with /v1/models, and leave when removed', async () => {
  const emitted: EventBody[] = [];
  const fileWorker: WorkerDef = { id: 'mine', label: 'Mine', backend: 'ollama', url: 'http://127.0.0.1:1', model: 'x', table: 'ollama-onoff', enabled: false };
  const fleet = new Fleet({ workers: [fileWorker], llmdAdmin: '', modelsToml: '', claimsAllDevices: [], defaultCwd: dir, proxyBaseUrl: (w) => `http://127.0.0.1:9/w/${w}`, log: () => {} }, (e) => emitted.push(e));
  const def = (id: string, model: string, url = base): WorkerDef => ({ id, label: `${id} · ${model}`, backend: 'openai', url, model, apiKey: 'sk-1', table: 'none', enabled: true });
  needKey = 'sk-1';
  fleet.syncEndpoints([def('coder', 'qwen3-coder'), def('missing', 'not-there'), def('mine', 'qwen3-coder')]);
  await fleet.refresh();
  const view = Object.fromEntries(fleet.snapshot().map((w) => [w.id, w]));
  assert.equal(view.coder.backend, 'openai');
  assert.equal(view.coder.available, true);
  assert.equal(view.coder.loaded, true);
  assert.equal(view.coder.fromSettings, true);
  assert.equal('apiKey' in view.coder, false, 'a key is never in the fleet view');
  assert.equal(view.missing.available, true);
  assert.equal(view.missing.loaded, false, "a model the server doesn't list isn't loaded");
  assert.equal(view.mine.backend, 'ollama', "the fleet file's worker wins its id");
  assert.equal(view.mine.fromSettings, undefined);
  assert.equal(fleet.contextFor({ model: 'qwen3-coder' }), 65536, 'the window the server lists');
  assert.doesNotMatch(JSON.stringify(emitted), /sk-1/);
  // auto may give it work: an idle, loaded local worker.
  assert.deepEqual(fleet.idleLocal().map((w) => w.id), ['coder']);
  // Its route goes to the OpenAI translator with its key.
  assert.match(String((fleet.route('coder') as { refuse: string }).refuse), /no running task/);

  // Moved to a dead server: asked again at once, and unavailable.
  fleet.syncEndpoints([def('coder', 'qwen3-coder', deadBase)]);
  await fleet.refresh();
  const after1 = Object.fromEntries(fleet.snapshot().map((w) => [w.id, w]));
  assert.equal(after1.coder.available, false);
  assert.equal(after1.missing, undefined, 'removed endpoints leave the fleet');
  assert.equal(after1.mine.backend, 'ollama');
  fleet.syncEndpoints([]);
  assert.deepEqual(fleet.snapshot().map((w) => w.id), ['mine']);
  needKey = '';
  fleet.stop();
});
