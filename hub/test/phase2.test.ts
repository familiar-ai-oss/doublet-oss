// Phase 2 check, against the real llmd on the hub machine:
//  - two tasks run at once (27B on the R9700, 9B on the 3060) and a third queues behind the 27B;
//  - every effort level, and temperature, changes what the proxy sends to llmd;
//  - a task on a model that isn't loaded asks before a swap and sends nothing to llmd; rejecting cancels it;
//  - cancel works for queued and running tasks; worker guard rails block commits.
// Never approves a swap, so nothing loaded on the hub machine is evicted.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { defaultFleetFile, loadWorkers, type WorkerDef } from '../src/fleet.ts';
import { EFFORT_TABLES } from '../src/effort.ts';
import { createHarness } from './harness.ts';

// gemma4-26b lives on the 3060 and is not loaded, so delegating to it must ask first.
const SWAP_WORKER: WorkerDef = { id: 'gemma-test', label: 'gemma (not loaded)', backend: 'llmd', url: 'http://127.0.0.1:8800', model: 'gemma4-26b', table: 'ctk-onoff', enabled: true };
const PROXY_PORT = 7990 + Math.floor(Math.random() * 9);
const h = createHarness('p2', { DUET_PROXY_PORT: String(PROXY_PORT) }, { workers: [...loadWorkers(defaultFleetFile()), SWAP_WORKER] });
const { client, next, all } = h;
after(() => h.cleanup());

const git = (cwd: string, ...args: string[]) => execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf8' });
function repo(): string {
  const d = mkdtempSync(join(h.work, 'repo-'));
  git(d, 'init', '-q');
  execFileSync('sh', ['-c', 'printf "hello world\\n" > greet.txt'], { cwd: d });
  git(d, 'add', '.');
  git(d, '-c', 'user.email=t@x', '-c', 'user.name=t', 'commit', '-qm', 'init');
  return d;
}
const EDIT = 'Edit greet.txt so it says "hello duet" instead of "hello world". Then run `git diff --stat` with Bash and reply with its output.';

async function delegate(worker: string, prompt: string, cwd?: string, effort?: string): Promise<string> {
  const ack = await client.send({ type: 'delegate', worker, prompt, cwd, effort });
  assert.ok(ack.taskId);
  return ack.taskId!;
}
const finished = (taskId: string, timeoutMs = 300_000) => next('task', (e) => e.taskId === taskId && ['done', 'failed', 'cancelled'].includes(e.state), 0, timeoutMs);
const stateSeq = (taskId: string, state: string) => all('task', (e) => e.taskId === taskId && e.state === state)[0]?.seq ?? Infinity;

test('hub starts with the fleet: 27B and 9B loaded, gemma not', async () => {
  await h.startHub();
  await client.connect();
  const f = await next('fleet', (e) => e.workers.some((w) => w.id === 'qwen-27b' && w.loaded));
  const by = Object.fromEntries(f.workers.map((w) => [w.id, w]));
  assert.equal(by['qwen-9b'].loaded, true, '9B loaded');
  assert.equal(by['gemma-test'].loaded, false, 'gemma not loaded');
  assert.equal(by['mac-9b'].enabled, false, 'mac worker is opt-in');
});

test('two tasks run at once on the two GPUs; a third queues behind the 27B', async () => {
  const [r1, r2, r3] = [repo(), repo(), repo()];
  const a = await delegate('qwen-27b', EDIT, r1);
  const b = await delegate('qwen-9b', EDIT, r2);
  const c = await delegate('qwen-27b', EDIT, r3);
  const queued = await next('task', (e) => e.taskId === c && e.state === 'queued');
  assert.equal(queued.queuePosition, 1, 'third task is first in the 27B queue');
  const [ea, eb, ec] = [await finished(a), await finished(b), await finished(c)];
  // Both ran at once: each started before the other finished.
  assert.ok(stateSeq(a, 'running') < ea.seq && stateSeq(b, 'running') < ea.seq && stateSeq(a, 'running') < eb.seq, '27B and 9B overlapped');
  assert.ok(stateSeq(c, 'running') > ea.seq, 'third started only after the first finished');
  for (const [e, dir] of [[ea, r1], [eb, r2], [ec, r3]] as const) {
    assert.equal(e.state, 'done', `${e.taskId} ${e.error ?? ''}`);
    assert.equal(readFileSync(join(dir, 'greet.txt'), 'utf8').trim(), 'hello duet', 'file really changed');
    assert.match(e.evidence ?? '', /greet\.txt/, 'hub-measured evidence names the file');
    console.log(`  ${e.worker}: ${(e.stats!.wallMs / 1000).toFixed(1)} s, ${e.stats!.requests} requests, first token ${e.stats!.firstTokenMs} ms, ${e.stats!.genTokPerS} tok/s`);
  }
});

test('every effort level changes what llmd receives; output_config.effort never passes', async () => {
  for (const [worker, table] of [['qwen-27b', 'qwen-levels'], ['qwen-9b', 'ctk-onoff']] as const) {
    for (const level of EFFORT_TABLES[table].levels) {
      const t = await delegate(worker, 'Reply with exactly: OK', undefined, level);
      const end = await finished(t);
      assert.equal(end.state, 'done', `${worker}/${level}: ${end.error}`);
      const reqs = all('worker_request', (e) => e.taskId === t);
      assert.ok(reqs.length >= 1);
      for (const r of reqs) {
        assert.deepEqual(r.sent.chat_template_kwargs, EFFORT_TABLES[table].apply(level).chat_template_kwargs, `${worker}/${level} sent`);
        assert.equal((r.sent.output_config as { effort?: string } | undefined)?.effort, undefined, 'Claude Code effort stripped');
      }
      console.log(`  ${worker}/${level}: sent ${JSON.stringify(reqs[0].sent.chat_template_kwargs)}, ${reqs[0].outputTokens} out tok, ${reqs[0].totalMs} ms`);
    }
  }
  await client.send({ type: 'set_worker', worker: 'qwen-9b', temperature: 0.3 });
  const t = await delegate('qwen-9b', 'Reply with exactly: OK');
  await finished(t);
  assert.ok(all('worker_request', (e) => e.taskId === t).every((r) => r.sent.temperature === 0.3), 'temperature applied');
  await client.send({ type: 'set_worker', worker: 'qwen-9b', temperature: null });
  await assert.rejects(client.send({ type: 'delegate', worker: 'qwen-9b', prompt: 'x', effort: 'xhigh' }), /not offered/);
});

test('a model that would swap asks first, sends nothing, and rejecting cancels', async () => {
  const t = await delegate('gemma-test', 'Reply with exactly: OK');
  const swap = await next('swap_request', (e) => e.taskId === t);
  assert.equal(swap.device, 'rtx3060');
  assert.ok(swap.evicts.includes('qwen3.5-9b-3060'), `evicts ${swap.evicts}`);
  await new Promise((r) => setTimeout(r, 3000));
  assert.equal(all('worker_request', (e) => e.worker === 'gemma-test').length, 0, 'no request reached llmd');
  // Even a direct request to the proxy for that worker is refused.
  const direct = await fetch(`http://127.0.0.1:${PROXY_PORT}/w/gemma-test/v1/messages`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{"model":"x","max_tokens":5,"messages":[]}' });
  assert.equal(direct.status, 403);
  // auto never picks a worker that would swap
  const auto = await delegate('auto', 'Reply with exactly: OK');
  assert.notEqual((await next('task', (e) => e.taskId === auto)).worker, 'gemma-test');
  await client.send({ type: 'reject_swap', id: swap.id });
  assert.equal((await finished(t)).state, 'cancelled');
  await finished(auto);
  const st = await (await fetch('http://127.0.0.1:8801/admin/v1/status')).json() as { backends: { served_id: string; state: string }[] };
  assert.deepEqual(st.backends.filter((b) => b.state === 'READY').map((b) => b.served_id).sort(), ['qwen3.5-9b-3060', 'qwen3.8-27b'], 'loaded models unchanged');
});

test('cancel: a queued task and a running task', async () => {
  const long = await delegate('qwen-27b', 'Without using any tools, write a 4000-word essay on the history of the printing press, in plain prose.');
  const queuedTask = await delegate('qwen-27b', 'Reply with exactly: OK');
  await client.send({ type: 'cancel_task', taskId: queuedTask });
  assert.equal((await finished(queuedTask)).state, 'cancelled');
  await next('task', (e) => e.taskId === long && e.state === 'running');
  await new Promise((r) => setTimeout(r, 1500));
  const t0 = Date.now();
  await client.send({ type: 'cancel_task', taskId: long });
  assert.equal((await finished(long, 30_000)).state, 'cancelled');
  assert.ok(Date.now() - t0 < 15_000, 'running task cancelled quickly');
  // The upstream request was torn down: llmd has nothing in flight on the 27B shortly after.
  await new Promise((r) => setTimeout(r, 2000));
  const st = await (await fetch('http://127.0.0.1:8801/admin/v1/status')).json() as { backends: { served_id: string; inflight: number }[] };
  assert.equal(st.backends.find((b) => b.served_id === 'qwen3.8-27b')?.inflight, 0, '27B has no request in flight');
});

test('guard rails: a worker cannot commit', async () => {
  const d = repo();
  const t = await delegate('qwen-9b', 'Run this exact Bash command: git commit --allow-empty -m "worker commit" . Then reply with what happened.', d);
  await finished(t);
  assert.equal(git(d, 'rev-list', '--count', 'HEAD').trim(), '1', 'no new commit');
});
