// Codex as the lead, against the hub user's real Codex sign-in (DUET_LEAD_AGENT=codex, a small model, low effort):
// a reply streams; a command asks first and runs once approved, or doesn't when rejected; Doublet's own tools work
// through the MCP gateway; Stop interrupts a turn; a hub restart resumes the same Codex thread.
// Run on the hub machine with Codex signed in: node --experimental-strip-types --test test/codex-live.test.ts
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import type { HubEvent } from '../src/protocol.ts';
import { createHarness } from './harness.ts';

const h = createHarness('codex', { DUET_LEAD_AGENT: 'codex', DUET_LEAD_MODEL: process.env.DUET_TEST_CODEX_MODEL || 'gpt-6-luna' });
const { client, events, next, startHub, stopHub, projectDir } = h;
after(async () => { if (process.env.DUET_SHOW_HUB_LOG) process.stderr.write(h.hubLog.join('')); await h.cleanup(); });

type Ev<T extends HubEvent['type']> = Extract<HubEvent, { type: T }>;
const inTurn = <T extends HubEvent['type']>(type: T, turn: number) => events.filter((e): e is Ev<T> => e.type === type && (e as { turn?: number }).turn === turn);
const said = (turn: number) => inTurn('assistant', turn).map((e) => e.text).join('');

async function prompt(text: string): Promise<number> {
  const from = events.length;
  await client.send({ type: 'prompt', text });
  return (await next('user', (e) => e.text === text, from)).turn;
}
const turnEnd = (turn: number, timeoutMs = 180_000) => next('turn_end', (e) => e.turn === turn, 0, timeoutMs);

let thread = '';

test('the hub starts with Codex leading, on a thread Codex names', async () => {
  await startHub();
  await client.connect();
  // The lead follows the id Codex gives its thread, so every ready carries it.
  const ready = await next('session', (e) => e.state === 'ready', 0, 60_000);
  thread = ready.sessionId!;
  assert.ok(thread);
  const info = await next('lead_info', () => true);
  assert.ok(info.models.length > 0, 'model/list fills the picker');
});

test('a reply streams in and the turn ends', async () => {
  const turn = await prompt('Reply with exactly the word: pong');
  const end = await turnEnd(turn);
  assert.equal(end.isError, false);
  assert.ok(inTurn('text_delta', turn).length > 0, 'text streamed');
  assert.match(said(turn), /pong/i);
});

test('a command waits for approval, and runs once approved', async () => {
  const turn = await prompt(`Run this exact shell command in ${projectDir} and nothing else: echo doublet-ok > ok.txt`);
  const req = await next('approval_request', (e) => e.turn === turn, 0, 120_000);
  assert.equal(req.tool, 'Bash');
  assert.match(String(req.input.command), /doublet-ok/);
  await client.send({ type: 'approve', id: req.id });
  await turnEnd(turn);
  assert.equal(readFileSync(join(projectDir, 'ok.txt'), 'utf8').trim(), 'doublet-ok');
  assert.ok(inTurn('tool_result', turn).length > 0);
});

test('a rejected command does not run', async () => {
  const turn = await prompt(`Run this exact shell command in ${projectDir} and nothing else: touch rejected.txt`);
  const req = await next('approval_request', (e) => e.turn === turn, 0, 120_000);
  await client.send({ type: 'reject', id: req.id, message: 'No.' });
  await turnEnd(turn);
  assert.equal(existsSync(join(projectDir, 'rejected.txt')), false);
});

test("Doublet's own tools reach Codex through the gateway", async () => {
  const turn = await prompt('Call the fleet tool from the duet MCP server once, then tell me in one sentence what it said.');
  // If Codex asks before an MCP call, that's an approval like any other.
  const approving = (async () => {
    for (let i = 0; i < 3; i++) {
      const req = await next('approval_request', (e) => e.turn === turn && !events.some((x) => x.type === 'approval_resolved' && x.id === e.id), 0, 120_000).catch(() => null);
      if (!req) return;
      await client.send({ type: 'approve', id: req.id });
    }
  })();
  await turnEnd(turn);
  void approving;
  const uses = inTurn('assistant', turn).flatMap((e) => e.toolUses);
  assert.ok(uses.some((u) => u.name === 'mcp__duet__fleet'), `tool calls: ${uses.map((u) => u.name).join(', ')}`);
  const result = inTurn('tool_result', turn).find((r) => uses.some((u) => u.id === r.toolUseId && u.name === 'mcp__duet__fleet'));
  assert.equal(result?.isError, false, result?.preview);
});

test('Stop interrupts a turn, and the next prompt works', async () => {
  const turn = await prompt('Count from 1 to 400, one number per line, with no other text.');
  await next('text_delta', (e) => e.turn === turn, 0, 120_000);
  await client.send({ type: 'interrupt' });
  const end = await turnEnd(turn, 60_000);
  assert.equal(end.interrupted, true);
  const again = await prompt('Reply with exactly the word: again');
  await turnEnd(again);
  assert.match(said(again), /again/i);
});

test('after a hub restart, Codex resumes the same thread and remembers it', async () => {
  await stopHub();
  const from = events.length;
  await startHub();
  const ready = await next('session', (e) => e.state === 'ready', from, 60_000);
  assert.equal(ready.sessionId, thread);
  const turn = await prompt('Which single word did I first ask you to reply with? Answer with just that word.');
  await turnEnd(turn);
  assert.match(said(turn), /pong/i);
});
