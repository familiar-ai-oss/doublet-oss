// Phase 6: Apple workers. The pure parts (a device's runs, the files' text), then a hub whose only workers are Apple
// ones, with the test client playing a device that has Apple Intelligence: it reports its model, receives the tasks the
// hub sends it and answers them. Ends with a real Claude delegating a summary to it and reading the answer.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AppleDevices } from '../src/apple.ts';
import { APPLE_INPUT_MAX, appleInput, filesNamedIn } from '../src/fleet.ts';
import type { ControlFrame } from '../src/protocol.ts';
import { createHarness } from './harness.ts';

type AppleTask = Extract<ControlFrame, { type: 'apple_task' }>;

test("a device's model runs what's sent to it; only that device's progress and answer count; cancel and disconnect end a task", async () => {
  const sent: ControlFrame[] = [];
  const sentB: ControlFrame[] = [];
  const send = (f: ControlFrame) => sent.push(f);
  const sendB = (f: ControlFrame) => sentB.push(f);
  const a = new AppleDevices(() => {});
  let changes = 0;
  a.onChange = () => changes++;
  a.status('ipad', send, { available: true, contextSize: 8192, capabilities: ['reasoning'], platform: 'ipad' });
  assert.equal(changes, 1);

  const progress: string[] = [];
  const p = a.run('ipad', 't-1', { prompt: 'Summarize', input: 'hello', temperature: 0.2 }, (t) => progress.push(t), new AbortController().signal);
  assert.deepEqual(sent[0], { type: 'apple_task', taskId: 't-1', prompt: 'Summarize', input: 'hello', temperature: 0.2 });
  a.progress('iphone', 't-1', 'not mine');
  a.progress('ipad', 't-1', 'Part 1 of 1');
  a.done('iphone', 't-1', { ok: true, result: 'from the wrong device' });
  a.done('ipad', 't-1', { ok: true, result: 'Short summary', stats: { inputTokens: 10, outputTokens: 5, wallMs: 100 } });
  assert.deepEqual(await p, { ok: true, result: 'Short summary', stats: { inputTokens: 10, outputTokens: 5, wallMs: 100 } });
  assert.deepEqual(progress, ['Part 1 of 1']);

  const stop = new AbortController();
  const p2 = a.run('ipad', 't-2', { prompt: 'x' }, () => {}, stop.signal);
  stop.abort();
  assert.deepEqual(await p2, { ok: false, result: '', error: 'cancelled' });
  assert.deepEqual(sent.at(-1), { type: 'apple_cancel', taskId: 't-2' });

  // A newer connection from the device takes over; the old one closing changes nothing.
  a.status('ipad', sendB, { available: true, contextSize: 8192, platform: 'ipad' });
  const p3 = a.run('ipad', 't-3', { prompt: 'y' }, () => {}, new AbortController().signal);
  assert.equal(sentB.at(-1)?.type, 'apple_task');
  a.disconnected('ipad', send);
  assert.equal(a.info('ipad')?.available, true);
  a.disconnected('ipad', sendB);
  const o3 = await p3;
  assert.equal(o3.ok, false);
  assert.match(o3.error ?? '', /ipad disconnected/);
  assert.equal(a.info('ipad'), undefined);

  a.status('mac', send, { available: false, reason: 'appleIntelligenceNotEnabled', platform: 'mac' });
  assert.match((await a.run('mac', 't-4', { prompt: 'z' }, () => {}, new AbortController().signal)).error ?? '', /isn't available/);
});

test("an Apple worker gets the files' text, each under its path; binary, missing and oversize input is refused", () => {
  const dir = mkdtempSync(join(tmpdir(), 'duet-apple-'));
  try {
    writeFileSync(join(dir, 'a.log'), 'line one\nline two\n');
    writeFileSync(join(dir, 'b.txt'), 'bee');
    writeFileSync(join(dir, 'blob.bin'), Buffer.from([1, 0, 2]));
    writeFileSync(join(dir, 'big.txt'), 'x'.repeat(APPLE_INPUT_MAX + 10));
    assert.equal(appleInput([join(dir, 'a.log'), join(dir, 'b.txt')]), `=== ${join(dir, 'a.log')} ===\nline one\nline two\n\n\n=== ${join(dir, 'b.txt')} ===\nbee`);
    assert.throws(() => appleInput([join(dir, 'blob.bin')]), /isn't text/);
    assert.throws(() => appleInput([join(dir, 'big.txt')]), /an Apple worker takes up to 400 KB/);
    assert.throws(() => appleInput([join(dir, 'missing.txt')]), /is not a file/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the files a task names by path are found, whatever punctuation is around them', () => {
  const dir = mkdtempSync(join(tmpdir(), 'duet-p6-named-'));
  try {
    mkdirSync(join(dir, 'src'));
    writeFileSync(join(dir, 'a.log'), 'x');
    writeFileSync(join(dir, 'src', 'main.ts'), 'x');
    const prompt = `Summarize ${join(dir, 'a.log')}. Then (src/main.ts:42-50) and "a.log", e.g. https://example.com/x, ~/no-such-file, src/ and missing.txt?`;
    assert.deepEqual(filesNamedIn(prompt, dir), [join(dir, 'a.log'), join(dir, 'src', 'main.ts')]);
    assert.deepEqual(filesNamedIn('Classify these: red, green, blue.', dir), []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// A hub with no GPU workers: whatever runs, runs on the "device".
const h = createHarness('p6', { DUET_APPLE_FOR_LEAD: '1' }, { workers: [] });
const { client, events, next, all } = h;
after(() => h.cleanup());

// The test client as a device with Apple Intelligence: it answers each task (unless told to hold), quoting what it got.
const tasks: AppleTask[] = [];
const cancels: string[] = [];
let hold = false;
client.on('control', (f: ControlFrame) => {
  if (f.type === 'apple_cancel') cancels.push(f.taskId);
  if (f.type !== 'apple_task') return;
  tasks.push(f);
  if (hold) return;
  void (async () => {
    if (f.prompt.includes('TOO-LONG')) {
      await client.send({ type: 'apple_done', taskId: f.taskId, ok: false, error: 'The text was too long for the on-device model (4098 tokens; it takes 4096)', stats: { inputTokens: 3000, outputTokens: 900, wallMs: 5000, parts: 3 } });
      return;
    }
    await client.send({ type: 'apple_progress', taskId: f.taskId, text: 'Part 1 of 1: read the log' });
    const lines = f.input ? f.input.split('\n').filter((l) => l.startsWith('ERROR')).length : 0;
    await client.send({ type: 'apple_done', taskId: f.taskId, ok: true, result: `SUMMARY-OK: ${lines} error lines, all about the disk filling up.`, stats: { inputTokens: 120, outputTokens: 40, wallMs: 800, parts: 1, genMs: 500 } });
  })().catch(() => { /* the hub went away first */ });
});

const work = mkdtempSync(join(tmpdir(), 'duet-p6-'));
after(() => rmSync(work, { recursive: true, force: true }));
const log = join(work, 'build.log');
writeFileSync(log, ['INFO start', 'ERROR disk full on /var', 'INFO retry', 'ERROR disk full on /var', 'ERROR no space left on device', 'INFO done'].join('\n'));

test("a device that reports Apple Intelligence becomes a worker; tasks for it run there and come back", async () => {
  await h.startHub();
  await client.connect();
  await next('session', (e) => e.state === 'ready');
  await client.send({ type: 'apple_status', available: true, variant: 'AFM 3 Core', contextSize: 4096, capabilities: ['guidedGeneration', 'toolCalling'], platform: 'mac' });
  const fleet = await next('fleet', (e) => e.workers.some((w) => w.id === 'apple-test' && w.available));
  const w = fleet.workers.find((x) => x.id === 'apple-test')!;
  assert.deepEqual([w.label, w.backend, w.device, w.variant, w.contextSize, w.effortLevels], ['Apple Intelligence · Mac', 'apple', 'test', 'AFM 3 Core', 4096, []]);

  const from = events.length;
  const ack = await client.send({ type: 'delegate', worker: 'apple-test', prompt: 'Summarize the errors in this log.', files: [log] });
  const t = tasks.at(-1)!;
  assert.equal(t.taskId, ack.taskId);
  assert.equal(t.prompt, 'Summarize the errors in this log.', 'just the task: no worker wrapper');
  assert.match(t.input ?? '', new RegExp(`^=== ${log} ===\\nINFO start\\nERROR disk full`));
  const p = await next('task_progress', (e) => e.taskId === ack.taskId, from);
  assert.equal(p.text, 'Part 1 of 1: read the log');
  const done = await next('task', (e) => e.taskId === ack.taskId && e.state === 'done', from);
  assert.equal(done.result, 'SUMMARY-OK: 3 error lines, all about the disk filling up.');
  assert.deepEqual([done.stats?.requests, done.stats?.inputTokens, done.stats?.outputTokens, done.stats?.genTokPerS], [1, 120, 40, 80], 'speed from the time spent writing: 40 tokens in 0.5 s');

  // Given straight to the worker ("@apple-test Summarize <path>"), the files it names are what it reads.
  const from2 = events.length;
  const direct = await client.send({ type: 'delegate', worker: 'apple-test', prompt: `Summarize ${log}.` });
  const queued = await next('task', (e) => e.taskId === direct.taskId && e.state === 'queued', from2);
  assert.deepEqual(queued.files, [log]);
  await next('task', (e) => e.taskId === direct.taskId && e.state === 'done', from2);
  assert.match(tasks.at(-1)!.input ?? '', new RegExp(`^=== ${log} ===\\n`));
});

test("when the device fails a task, the reason is what's reported, with the passes it made", async () => {
  const from = events.length;
  const ack = await client.send({ type: 'delegate', worker: 'apple-test', prompt: 'TOO-LONG summary, please.' });
  const failed = await next('task', (e) => e.taskId === ack.taskId && e.state === 'failed', from);
  assert.equal(failed.error, 'The text was too long for the on-device model (4098 tokens; it takes 4096)');
  assert.deepEqual([failed.stats?.requests, failed.stats?.inputTokens, failed.stats?.outputTokens, failed.stats?.genTokPerS], [3, 3000, 900, null], 'no speed when the device timed no writing');
  const result = await next('dialogue', (e) => e.taskId === ack.taskId && e.kind === 'RESULT', from);
  assert.match(result.text, /^Failed: The text was too long for the on-device model \(4098 tokens; it takes 4096\)/);
});

test("an Apple task can be cancelled; it can't be steered, and auto never picks an Apple worker", async () => {
  hold = true;
  const from = events.length;
  const ack = await client.send({ type: 'delegate', worker: 'apple-test', prompt: 'Classify these.' });
  await next('task', (e) => e.taskId === ack.taskId && e.state === 'running', from);
  await assert.rejects(client.send({ type: 'steer', taskId: ack.taskId!, text: 'faster' }), /can't take messages mid-task/);
  await client.send({ type: 'cancel_task', taskId: ack.taskId! });
  await next('task', (e) => e.taskId === ack.taskId && e.state === 'cancelled', from);
  assert.ok(cancels.includes(ack.taskId!));
  hold = false;
  await assert.rejects(client.send({ type: 'delegate', worker: 'auto', prompt: 'Write tests.' }), /auto found no local worker for this large task .*: there are no local workers/);
});

test('Claude delegates a summary of a file to the Apple worker and gets the answer back', async () => {
  const from = events.length;
  const text = `Make a one-step plan with mcp__duet__plan (id "1", text "Summarize the log", owner "apple-test", status "pending"). Then delegate to the worker apple-test, with step "1" and files ["${log}"], this task: "Summarize the errors in this log in one sentence." Then call await_workers, and reply with the worker's answer exactly as it gave it.`;
  await client.send({ type: 'prompt', text });
  const u = await next('user', (e) => e.text === text, from);
  const delegated = await next('task', (e) => e.worker === 'apple-test' && e.state === 'queued' && e.by === 'lead', from);
  await next('task', (e) => e.taskId === delegated.taskId && e.state === 'done', from);
  const t = tasks.find((x) => x.taskId === delegated.taskId);
  assert.match(t?.input ?? '', /ERROR no space left on device/, 'the hub sent the file it named');
  await next('turn_end', (e) => e.turn === u.turn, from, 300_000);
  const reply = all('assistant', (e) => e.turn === u.turn).map((e) => e.text).join('');
  assert.match(reply, /SUMMARY-OK: 3 error lines/);
});
