// Phase 5 hub check: lead model/effort info, Boost, Compact, Clear; the worker model catalog with swap
// warnings and model switching; @all; terminals (shell, llmd status) that survive a dropped connection.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import type { ControlFrame } from '../src/protocol.ts';
import { HubClient } from '../src/client.ts';
import { createHarness } from './harness.ts';

const h = createHarness('p5');
const { client, events, next, all } = h;
after(() => h.cleanup());

async function prompt(text: string, boost = false): Promise<number> {
  const from = events.length;
  await client.send({ type: 'prompt', text, boost });
  return (await next('user', (e) => e.text.startsWith(text), from)).turn;
}
const turnEnd = (turn: number) => next('turn_end', (e) => e.turn === turn, 0, 300_000);
const reply = (turn: number) => all('assistant', (e) => e.turn === turn).map((e) => e.text).join('');

test('lead_info lists models with their effort levels; set_model switches and reports it', async () => {
  await h.startHub();
  await client.connect();
  const info = await next('lead_info');
  assert.ok(info.models.length >= 2, 'several models offered');
  assert.ok(info.models.every((m) => Array.isArray(m.effortLevels)));
  const other = info.models.find((m) => m.value !== info.model && m.effortLevels.length)!;
  const from = events.length;
  await client.send({ type: 'set_model', model: other.value });
  assert.equal((await next('lead_info', () => true, from)).model, other.value);
  await client.send({ type: 'set_model', model: info.model });
  await assert.rejects(client.send({ type: 'set_model', model: 'not-a-model' }), /unknown model/);
  console.log(`  lead models: ${info.models.map((m) => `${m.value}${m.resolved ? `→${m.resolved}` : ''}[${m.effortLevels.join('/')}]`).join(', ')}`);
});

test('boost adds ultrathink to that one turn', async () => {
  const t = await prompt('Reply with exactly: BOOST-OK', true);
  assert.match(all('user', (e) => e.turn === t)[0].text, /\n\nultrathink$/);
  await turnEnd(t);
  assert.match(reply(t), /BOOST-OK/);
});

test('compact reports the token counts; clear starts a fresh session that forgets', async () => {
  const t1 = await prompt('Remember the codeword HERON-77. Reply OK.');
  await turnEnd(t1);
  const from = events.length;
  await client.send({ type: 'compact' });
  const c = await next('context', (e) => e.action === 'compacted', from, 300_000);
  await turnEnd((await next('user', (e) => e.text === '/compact', from)).turn);
  assert.ok((c.preTokens ?? 0) > 0, 'compaction reported its size');
  const sid = all('session', (e) => e.state === 'ready').at(-1)!.sessionId;
  const from2 = events.length;
  await client.send({ type: 'clear' });
  await next('context', (e) => e.action === 'cleared', from2);
  await next('session', (e) => e.state === 'ready', from2);
  const t2 = await prompt('What codeword did I ask you to remember? If you do not know, reply UNKNOWN.');
  await turnEnd(t2);
  assert.doesNotMatch(reply(t2), /HERON-77/, 'the cleared session does not remember');
  const newSid = all('session').filter((e) => e.sessionId).at(-1)!.sessionId;
  assert.notEqual(newSid, sid, 'new session id');
  console.log(`  compact: ${c.preTokens} → ${c.postTokens ?? '?'} tokens`);
});

test('model catalog shows what loading a model would evict; a worker can switch models without loading anything', async () => {
  const cat = await next('model_catalog');
  const by = Object.fromEntries(cat.models.map((m) => [m.id, m]));
  assert.equal(by['qwen3.8-27b'].loaded, true);
  assert.equal(by['qwen3.8-27b'].verified, true);
  assert.equal(by['gemma4-26b']?.loaded, false);
  assert.ok(by['gemma4-26b'].evicts.includes('qwen3.5-9b-3060'), `gemma evicts ${by['gemma4-26b'].evicts}`);
  assert.ok(!cat.models.some((m) => /embedding|reranker|dsv4/.test(m.id)), 'non-chat and both-GPU models are not offered');
  const from = events.length;
  await client.send({ type: 'set_worker', worker: 'qwen-9b', model: 'gemma4-26b' });
  const f = await next('fleet', (e) => e.workers.some((w) => w.id === 'qwen-9b' && w.model === 'gemma4-26b'), from);
  const w = f.workers.find((x) => x.id === 'qwen-9b')!;
  assert.equal(w.loaded, false);
  assert.equal(w.verifiedEffort, false);
  await client.send({ type: 'set_worker', worker: 'qwen-9b', model: 'qwen3.5-9b-3060' });
  await next('fleet', (e) => e.workers.some((x) => x.id === 'qwen-9b' && x.model === 'qwen3.5-9b-3060' && x.loaded));
  const st = await (await fetch('http://127.0.0.1:8801/admin/v1/status')).json() as { backends: { served_id: string; state: string }[] };
  assert.deepEqual(st.backends.filter((b) => b.state === 'READY').map((b) => b.served_id).sort(), ['qwen3.5-9b-3060', 'qwen3.8-27b'], 'nothing was loaded');
});

test('worker tok/s appears on the fleet card after a task', async () => {
  const ack = await client.send({ type: 'delegate', worker: 'qwen-27b', prompt: 'Without using tools, write four short sentences about GPUs.' });
  await next('task', (e) => e.taskId === ack.taskId && e.state === 'done', 0, 120_000);
  const f = await next('fleet', (e) => e.workers.some((w) => w.id === 'qwen-27b' && (w.tokPerS ?? 0) > 0));
  console.log(`  qwen-27b tok/s on its card: ${f.workers.find((w) => w.id === 'qwen-27b')!.tokPerS}`);
});

test('@all: the lead gets a prompt and every running worker gets a STEER', async () => {
  const ack = await client.send({ type: 'delegate', worker: 'qwen-27b', prompt: 'Without using tools, write a 3000-word essay about the printing press.' });
  await next('task', (e) => e.taskId === ack.taskId && e.state === 'running');
  const from = events.length;
  await client.send({ type: 'broadcast', text: 'Reply with exactly: ALL-OK' });
  const u = await next('user', (e) => e.text === 'Reply with exactly: ALL-OK', from);
  const steer = await next('dialogue', (e) => e.kind === 'STEER' && e.taskId === ack.taskId, from);
  assert.equal(steer.from, 'test');
  await client.send({ type: 'cancel_task', taskId: ack.taskId! });
  await turnEnd(u.turn);
});

test('terminals: shell I/O, llmd status, survive a dropped connection with scrollback', async () => {
  const frames: ControlFrame[] = [];
  const onControl = (f: ControlFrame) => frames.push(f);
  client.on('control', onControl);
  const outOf = (id: string) => frames.filter((f): f is Extract<ControlFrame, { type: 'pty_data' }> => f.type === 'pty_data' && f.id === id).map((f) => f.data).join('');
  const until = async (label: string, cond: () => boolean, ms = 15_000) => {
    const t0 = Date.now();
    while (!cond()) {
      if (Date.now() - t0 > ms) {
        const hubSaw = h.hubLog.join('').split('\n').filter((l) => /terminal|disconnected|connected/.test(l)).slice(-8).join('\n');
        throw new Error(`timed out: ${label}\nframes: ${frames.filter((f) => f.type !== 'pty_data').map((f) => JSON.stringify(f)).slice(-6).join(' ')}\nhub log:\n${hubSaw}`);
      }
      await new Promise((r) => setTimeout(r, 100));
    }
  };

  const shell = (await client.send({ type: 'pty_open', kind: 'shell', cols: 100, rows: 30 })).ptyId!;
  await client.send({ type: 'pty_input', id: shell, data: 'echo PTY-$((6*7)) $COLUMNS\n' });
  await until('shell echo', () => /PTY-42 100/.test(outOf(shell)), 30_000); // a login shell can be slow to start
  await client.send({ type: 'pty_resize', id: shell, cols: 120, rows: 40 });
  await client.send({ type: 'pty_input', id: shell, data: 'echo AFTER-$(tput cols)\n' });
  await until('resize', () => /AFTER-120/.test(outOf(shell)));

  const llmd = (await client.send({ type: 'pty_open', kind: 'llmd', cols: 100, rows: 30 })).ptyId!;
  await until('llmd status', () => /qwen3\.8-27b\s+READY/.test(outOf(llmd)));
  await client.send({ type: 'pty_close', id: llmd });
  await until('llmd exit', () => frames.some((f) => f.type === 'pty_exit' && f.id === llmd));

  // A second device sees the live shell and attaches; it gets the scrollback.
  const other = new HubClient({ url: h.url, device: 'test', token: h.token, reconnect: false });
  const otherFrames: ControlFrame[] = [];
  other.on('control', (f: ControlFrame) => otherFrames.push(f));
  await other.connect();
  const list = otherFrames.find((f): f is Extract<ControlFrame, { type: 'pty_list' }> => f.type === 'pty_list')!;
  assert.deepEqual(list.terminals.map((t) => t.id), [shell], 'the live shell is listed; the closed one is not');
  await other.send({ type: 'pty_attach', id: shell });
  await until('scrollback on attach', () => otherFrames.some((f) => f.type === 'pty_data' && /PTY-42/.test(f.data)));
  other.close();

  await client.send({ type: 'pty_close', id: shell });
  await until('shell exit', () => frames.some((f) => f.type === 'pty_exit' && f.id === shell));
  client.off('control', onControl);
  assert.ok(!events.some((e) => JSON.stringify(e).includes('PTY-42')), 'terminal output never enters the event log');
});
