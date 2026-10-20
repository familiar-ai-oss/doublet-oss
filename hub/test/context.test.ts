// Workers fitted to their models' real windows, and turn limits that end with progress (context.ts), without models:
//  1. Each model's window from models.toml (vLLM's max-model-len; llama.cpp's -c over its slots; the smallest profile).
//  2. The compaction settings for a window: a reply budget that fits, a window Claude Code accepts, and when to compact.
//  3. A local server's "doesn't fit" error, in the words that make Claude Code compact and retry; other errors untouched.
//  4. A worker warned as its turns run out (once, then on its last turn); a stopped task's result keeps its progress,
//     and the lead's RESULT says it stopped (or finished, when it reported first) instead of failing.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { compactionEnv, overflowAsPromptTooLong, servedContext, tomlContexts, turnWarning, COMPACT_WINDOW_MIN } from '../src/context.ts';
import { Dialogue } from '../src/dialogue.ts';
import { OUT_OF_ROOM, stoppedResult, stoppedWords } from '../src/fleet.ts';
import { compactedTask, errorSubtype } from '../src/worker.ts';
import type { EventBody } from '../src/protocol.ts';

const TOML = `
# a comment with "-c","999"
[daemon]
port = 8800

[models."vllm-27b"]
device = "r9700"
args = ["--max-model-len","200000"]

[models."vllm-27b".profiles.interactive]
args = ["--speculative-config","{\\"max_model_len\\": 180000}"]

[models."llama-9b"]
args = ["-c","196608","-np","1"]

[models."llama-two-slots"]
args = ["-c","65536","-np","2"]   # 32K a slot

[models."no-context"]
device = "cpu"

[devices.r9700]
vram_mb = 32000
`;

test("models.toml: each model's window, per slot, the smallest of its profiles", () => {
  const m = tomlContexts(TOML);
  assert.equal(m.get('vllm-27b'), 180000, 'the smaller profile wins');
  assert.equal(m.get('llama-9b'), 196608);
  assert.equal(m.get('llama-two-slots'), 32768, 'the -c total split over -np slots');
  assert.equal(m.has('no-context'), false);
  assert.equal(m.size, 3, 'comments and other sections are ignored');
});

test('the running server says how much it holds: llama.cpp per slot, vLLM max_model_len', async () => {
  const llama = http.createServer((req, res) => {
    res.writeHead(req.url === '/props' ? 200 : 404, { 'content-type': 'application/json' });
    res.end(JSON.stringify(req.url === '/props' ? { default_generation_settings: { n_ctx: 98304 }, total_slots: 2 } : {}));
  });
  const vllm = http.createServer((req, res) => {
    res.writeHead(req.url === '/v1/models' ? 200 : 404, { 'content-type': 'application/json' });
    res.end(JSON.stringify(req.url === '/v1/models' ? { data: [{ id: 'sonnet', max_model_len: 1 }, { id: 'qwen3.8-27b', max_model_len: 200000 }] } : {}));
  });
  await Promise.all([llama, vllm].map((s) => new Promise<void>((r) => s.listen(0, '127.0.0.1', r))));
  try {
    const port = (s: http.Server) => (s.address() as { port: number }).port;
    assert.equal(await servedContext('127.0.0.1', port(llama), 'llama-9b'), 98304);
    assert.equal(await servedContext('127.0.0.1', port(vllm), 'qwen3.8-27b'), 200000, 'its own entry, not an alias');
    assert.equal(await servedContext('127.0.0.1', 1, 'gone', 300), null, 'nothing there: unknown');
  } finally {
    await Promise.all([llama, vllm].map((s) => new Promise((r) => s.close(r))));
  }
});

test('compaction settings: the reply fits, the window is one Claude Code accepts, and compaction comes in time', () => {
  for (const ctx of [32_768, 65_536, 131_072, 196_608, 200_000, 1_000_000]) {
    const e = compactionEnv(ctx);
    const output = Number(e.CLAUDE_CODE_MAX_OUTPUT_TOKENS);
    const window = Number(e.CLAUDE_CODE_AUTO_COMPACT_WINDOW);
    const at = (window * Number(e.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE)) / 100;
    assert.ok(output >= 4096 && output <= 32000, `${ctx}: reply budget ${output}`);
    assert.ok(window >= COMPACT_WINDOW_MIN && window <= 1_000_000, `${ctx}: window ${window}`);
    assert.ok(at + output < ctx, `${ctx}: compacting at ${at} leaves room for a ${output}-token reply`);
    assert.ok(at > ctx * 0.6, `${ctx}: not needlessly early (${at})`);
  }
  assert.deepEqual(compactionEnv(65_536), { CLAUDE_CODE_MAX_OUTPUT_TOKENS: '8192', CLAUDE_CODE_AUTO_COMPACT_WINDOW: '100000', CLAUDE_AUTOCOMPACT_PCT_OVERRIDE: '50' });
  assert.equal(compactionEnv(200_000).CLAUDE_CODE_AUTO_COMPACT_WINDOW, '200000');
});

test("a local server's context overflow reads as \"prompt is too long\"; other errors pass through", () => {
  const vllm = JSON.stringify({ type: 'error', error: { type: 'BadRequestError', message: "This model's maximum context length is 200000 tokens. However, you requested 212000 tokens (180000 in the messages, 32000 in the completion)." } });
  const out = JSON.parse(overflowAsPromptTooLong(400, vllm)!);
  assert.equal(out.error.type, 'invalid_request_error');
  assert.equal(out.error.message, 'prompt is too long: 212000 tokens > 200000 maximum');
  const maxTokens = '{"type":"error","error":{"message":"max_completion_tokens=300000 cannot be greater than max_model_len=max_total_tokens=200000."}}';
  assert.match(JSON.parse(overflowAsPromptTooLong(400, maxTokens)!).error.message, /^prompt is too long/);
  const llama = '{"error":{"code":400,"message":"the request exceeds the available context size, try increasing it","type":"exceed_context_size_error","n_prompt_tokens":70000,"n_ctx":65536}}';
  assert.match(JSON.parse(overflowAsPromptTooLong(400, llama)!).error.message, /^prompt is too long/);
  assert.equal(overflowAsPromptTooLong(400, '{"error":{"message":"temperature must be between 0 and 2"}}'), null);
  assert.equal(overflowAsPromptTooLong(500, vllm), null, 'a server error is not an overflow');
});

test('a worker is told as its turns run out: once with a tenth left, again on its last; with or without report', () => {
  const said = (used: number, max = 60, canReport = true) => turnWarning(used, max, canReport);
  assert.equal(said(10), null);
  assert.match(said(54)!, /You have 6 of your 60 turns left/);
  assert.match(said(54)!, /call report with kind "final"/);
  assert.equal(said(55), null);
  assert.match(said(59)!, /last turn of 60/);
  assert.match(said(27, 30, false)!, /3 of your 30 turns left.*write your final answer/s, 'a small budget still gets 3 turns of warning');
});

test("a stopped task keeps its progress, and the lead's RESULT says it stopped instead of failing", () => {
  const turns = { reason: 'turn_limit' as const, turns: 60 };
  assert.match(stoppedResult(turns, ['Read the fixtures.', '', 'Ran the tests: 2 still fail in test_table.']), /^Stopped at its 60-turn limit before finishing\. Its progress so far, in its own words:\nRead the fixtures\.\n\nRan the tests/);
  assert.match(stoppedResult({ reason: 'turn_limit', turns: 6 }, []), /wrote nothing about its progress/);
  assert.ok(stoppedResult(turns, ['x'.repeat(5000)]).length < 1700, 'only the end of a long output');
  const room = stoppedResult({ reason: 'context', turns: 30, context: 65536 }, ['Found it: ZEBRA-7 on line 137 of part6.md.', 'Autocompact is thrashing: the context refilled to the limit within 3 turns']);
  assert.match(room, /^Stopped before finishing: the work kept outgrowing its model's 65,536-token context, even after compacting/);
  assert.match(room, /ZEBRA-7 on line 137/);
  assert.doesNotMatch(room, /thrashing/, "Claude Code's own error isn't repeated as its words");
  assert.ok(OUT_OF_ROOM.test('Error: Claude Code returned an error result: Autocompact is thrashing: the context refilled'));
  assert.equal(errorSubtype('Error: Claude Code returned an error result: Reached maximum number of turns (60)'), 'error_max_turns', 'the SDK throws at the turn limit');
  assert.equal(errorSubtype('Error: socket hang up'), 'error');
  assert.match(compactedTask('Find the code word in docs/.'), /compacted.*\n\nFind the code word in docs\/\.\n\nCarry on/s, 'after a compaction the task comes back word for word');
  assert.equal(stoppedWords(['Running total: 16', 'Autocompact is thrashing: …']), 'Running total: 16');

  const emitted: EventBody[] = [];
  const d = new Dialogue((e) => emitted.push(e));
  const tasks = new Map<string, { worker: string; state: string; by: string }>([['t-1', { worker: 'qwen-27b', state: 'done', by: 'lead' }]]);
  d.attach(
    { delegate: () => 't-x', cancel: () => {}, taskInfo: (id) => tasks.get(id), activeTasks: () => [], describe: () => '', idleLocal: () => [] },
    { busy: () => true, submit: () => {}, conversation: () => undefined },
  );
  const result = () => (emitted.filter((e) => e.type === 'dialogue' && e.kind === 'RESULT').at(-1) as Extract<EventBody, { type: 'dialogue' }>).text;
  d.onTaskEnd('t-1', 'qwen-27b', 'done', stoppedWords(['Ran the tests: 2 still fail.']), 'no changes', 'Ran the tests: 2 still fail.', turns);
  assert.match(result(), /^Stopped at its 60-turn limit before finishing \(partial; continue it with a new task if more is needed\): Ran the tests: 2 still fail\./);
  d.onTaskEnd('t-1', 'qwen-27b', 'done', room, 'no changes', '', { reason: 'context', turns: 30 });
  assert.match(result(), /^Stopped at its model's context before finishing/);
  assert.doesNotMatch(result(), /^Failed/);
  d.onTaskEnd('t-1', 'qwen-27b', 'done', 'All fixed.', 'no changes', '');
  assert.match(result(), /^Finished: All fixed\./, 'an ordinary finish reads as before');
});
