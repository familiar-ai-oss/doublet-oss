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

test("a side chat is answered by the lead's agent: it knows the conversation, adds nothing to it, and continues", async () => {
  const settled = (chatId: string, from: number) => next('side_chat', (e) => e.chatId === chatId && e.state !== 'answering', from, 240_000);
  const answers = (chatId: string) => events.filter((e): e is Ev<'side_message'> => e.type === 'side_message' && e.chatId === chatId && e.role === 'assistant').map((m) => m.text);
  const prompts = events.filter((e) => e.type === 'user').length;
  let from = events.length;
  const chatId = (await client.send({ type: 'side_ask', text: 'Which single word did I first ask you to reply with? Answer with the word only.' })).chatId!;
  const done = await settled(chatId, from);
  assert.equal(done.state, 'idle', done.error);
  assert.equal(done.forked, 'whole');
  assert.match(answers(chatId).join('\n'), /pong/i, 'it knows the conversation');
  assert.equal(events.filter((e) => e.type === 'user').length, prompts, 'the conversation itself got no new turn');
  from = events.length;
  await client.send({ type: 'side_ask', chatId, text: 'Say that word again, in capital letters, and nothing else.' });
  const again = await settled(chatId, from);
  assert.equal(again.state, 'idle', again.error);
  assert.match(answers(chatId).at(-1) ?? '', /PONG/, 'the follow-up continues the same aside');
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

test('plan mode: the plan comes on the plan card, and approving it leaves plan mode and does the work', async () => {
  await client.send({ type: 'set_permission_mode', mode: 'plan' });
  await next('lead_info', (e) => e.permissionMode === 'plan', 0, 30_000);
  const turn = await prompt(`Plan how to create ${join(projectDir, 'planned.txt')} containing the single word: planned. Don't create it yet; present your plan for my approval.`);
  const card = await next('approval_request', (e) => e.tool === 'ExitPlanMode', 0, 240_000);
  assert.ok(typeof card.plan === 'string' && card.plan.length > 0, 'the plan is on the card');
  assert.equal(existsSync(join(projectDir, 'planned.txt')), false, 'nothing changes while planning');
  const from = events.length;
  await client.send({ type: 'approve', id: card.id });
  await next('lead_info', (e) => e.permissionMode === 'default', from, 60_000);
  // The work starts by itself; any command it runs still asks.
  const deadline = Date.now() + 240_000;
  while (!existsSync(join(projectDir, 'planned.txt')) && Date.now() < deadline) {
    const ask = events.slice(from).find((e): e is Ev<'approval_request'> => e.type === 'approval_request' && e.tool !== 'ExitPlanMode' && !events.some((x) => x.type === 'approval_resolved' && x.id === e.id));
    if (ask) await client.send({ type: 'approve', id: ask.id });
    await new Promise((r) => setTimeout(r, 1000));
  }
  void turn;
  assert.equal(readFileSync(join(projectDir, 'planned.txt'), 'utf8').trim(), 'planned');
});

test('compact asks Codex to summarize its thread', async () => {
  const from = events.length;
  await client.send({ type: 'compact' });
  const done = await next('context', (e) => e.action === 'compacted', from, 180_000);
  assert.equal(done.by, 'test');
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
