// Phase 1 check, against the hub user's real Claude Code login (cheap model, low effort):
// auth; approve, edit and reject; interrupt; effort change; a dropped connection mid-stream resumes with
// no gaps and no duplicates; a hub restart keeps the log and resumes the lead's conversation.
// Run on the hub machine: npm test   (DUET_TEST_MODEL overrides the model)
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { HubClient } from '../src/client.ts';
import type { HubEvent } from '../src/protocol.ts';
import { createHarness } from './harness.ts';

const h = createHarness('p1');
const { client, events, next, startHub, stopHub, projectDir, port: PORT, url: URL_WS, token: TOKEN } = h;

// Send a prompt and return the turn number the hub gave it.
async function prompt(text: string): Promise<number> {
  const from = events.length;
  await client.send({ type: 'prompt', text });
  return (await next('user', (e) => e.text === text, from)).turn;
}
const turnEnd = (turn: number, timeoutMs?: number) => next('turn_end', (e) => e.turn === turn, 0, timeoutMs);
const toolResults = (turn: number) => events.filter((e): e is Extract<HubEvent, { type: 'tool_result' }> => e.type === 'tool_result' && e.turn === turn);

after(() => h.cleanup());

test('hub starts and the lead is ready on the hub user\'s Claude Code login', async () => {
  await startHub();
  await client.connect();
  const ready = await next('session', (e) => e.state === 'ready');
  // With DUET_LEAD_AUTH=max (hub/local.env), only a Max plan gets this far.
  if (process.env.DUET_LEAD_AUTH === 'max') assert.match(ready.account?.subscription ?? '', /max/i);
  else assert.ok(ready.sessionId);
});

test('auth: wrong token, foreign tailscale login and wrong path are refused', async () => {
  await assert.rejects(new HubClient({ url: URL_WS, device: 'test', token: 'nope', reconnect: false }).connect(), /bad device token/);
  await assert.rejects(new HubClient({ url: URL_WS, device: 'test', token: TOKEN, reconnect: false, headers: { 'Tailscale-User-Login': 'someone@else' } }).connect(), /403/);
  await assert.rejects(new HubClient({ url: `ws://127.0.0.1:${PORT}/nope`, device: 'test', token: TOKEN, reconnect: false }).connect(), /403/);
  const ok = new HubClient({ url: URL_WS, device: 'test', token: TOKEN, reconnect: false, headers: { 'Tailscale-User-Login': 'tester@example' } });
  await ok.connect();
  ok.close();
});

test('approve: the tool runs as requested', async () => {
  const turn = await prompt('Use the Bash tool to run exactly this command: echo APPROVE-OK > approved.txt && cat approved.txt . Then reply DONE. Also remember the codeword PELICAN-42 for later.');
  const req = await next('approval_request', (e) => e.turn === turn);
  assert.equal(req.tool, 'Bash');
  await client.send({ type: 'approve', id: req.id });
  const end = await turnEnd(turn);
  assert.equal(end.subtype, 'success');
  assert.ok(toolResults(turn).some((r) => r.preview.includes('APPROVE-OK')), 'tool output has APPROVE-OK');
});

test('edit: the tool runs with the edited input', async () => {
  const turn = await prompt('Use the Bash tool to run exactly this command: echo ORIGINAL-TEXT > original.txt && cat original.txt . Then reply with what it printed.');
  const req = await next('approval_request', (e) => e.turn === turn);
  await client.send({ type: 'approve', id: req.id, updatedInput: { ...req.input, command: 'echo EDITED-7731 > edited.txt && cat edited.txt' } });
  const resolved = await next('approval_resolved', (e) => e.id === req.id);
  assert.equal(resolved.edited, true);
  assert.equal(resolved.updatedInput?.command, 'echo EDITED-7731 > edited.txt && cat edited.txt', 'clients see what ran');
  assert.ok(req.toolUseId, 'the card is paired with its tool call');
  await turnEnd(turn);
  const out = toolResults(turn).map((r) => r.preview).join('\n');
  assert.ok(out.includes('EDITED-7731') && !out.includes('ORIGINAL-TEXT'), `tool output: ${out}`);
  assert.equal(existsSync(join(projectDir, 'original.txt')), false, 'the original command never ran');

  // Claude is told the call was edited, and what ran.
  const ask = await prompt('Did the user change your last Bash command before it ran? Answer YES or NO, then give the exact command that ran.');
  await turnEnd(ask);
  const reply = events.filter((e) => e.type === 'assistant' && e.turn === ask).map((e) => (e as { text: string }).text).join('\n');
  assert.match(reply, /YES/i, `reply: ${reply}`);
  assert.match(reply, /EDITED-7731/, `reply: ${reply}`);
});

test('approving without changes is not an edit', async () => {
  const turn = await prompt('Use the Bash tool to run exactly this command: echo SAME-INPUT > same.txt . Then reply DONE.');
  const req = await next('approval_request', (e) => e.turn === turn);
  // Same input, keys in another order, as a client re-encoding it would send.
  const reordered = Object.fromEntries(Object.entries(req.input).reverse());
  await client.send({ type: 'approve', id: req.id, updatedInput: reordered });
  const resolved = await next('approval_resolved', (e) => e.id === req.id);
  assert.equal(resolved.edited, false);
  assert.equal(resolved.updatedInput, undefined);
  await turnEnd(turn);
});

test('reject: the tool does not run and the model gets the note', async () => {
  const turn = await prompt('Use the Bash tool to run exactly this command: touch rejected.txt . If it is refused, reply with the reason you were given.');
  const req = await next('approval_request', (e) => e.turn === turn);
  await client.send({ type: 'reject', id: req.id, message: 'Not allowed: leave the filesystem alone.' });
  await turnEnd(turn);
  assert.equal(existsSync(join(projectDir, 'rejected.txt')), false, 'file must not exist');
  const resolved = await next('approval_resolved', (e) => e.id === req.id);
  assert.equal(resolved.decision, 'deny');
  assert.equal(resolved.message, 'Not allowed: leave the filesystem alone.');
});

test('effort: applyFlagSettings changes $CLAUDE_EFFORT from the next turn', async () => {
  const ask = 'Use the Bash tool to run exactly this command: echo "EFFORT=$CLAUDE_EFFORT" . Reply with its output only.';
  const readEffort = async () => {
    const turn = await prompt(ask);
    const req = await next('approval_request', (e) => e.turn === turn);
    await client.send({ type: 'approve', id: req.id });
    await turnEnd(turn);
    return toolResults(turn).map((r) => r.preview.match(/EFFORT=(\w*)/)?.[1]).find(Boolean);
  };
  assert.equal(await readEffort(), 'low');
  await client.send({ type: 'set_effort', level: 'high' });
  await next('effort', (e) => e.level === 'high');
  assert.equal(await readEffort(), 'high');
  await client.send({ type: 'set_effort', level: 'low' });
});

test('interrupt: a streaming turn stops, and the next prompt works', async () => {
  const turn = await prompt('Write the numbers from 1 to 800, one per line, with no other text.');
  for (let n = 0; n < 5; n++) await next('text_delta', (e) => e.turn === turn && events.filter((x) => x.type === 'text_delta' && x.turn === turn).length > n);
  const t0 = Date.now();
  await client.send({ type: 'interrupt' });
  const end = await turnEnd(turn, 30_000);
  assert.equal(end.interrupted, true);
  assert.ok(Date.now() - t0 < 15_000, 'interrupt took effect quickly');
  const t2 = await prompt('Reply with exactly: AFTER-INTERRUPT');
  const end2 = await turnEnd(t2);
  assert.equal(end2.subtype, 'success');
  assert.ok(events.some((e) => e.type === 'assistant' && e.turn === t2 && e.text.includes('AFTER-INTERRUPT')));
});

test('reconnect: dropping the socket mid-stream loses nothing and duplicates nothing', async () => {
  const turn = await prompt('Write the numbers from 1 to 150, one per line, with no other text.');
  await next('text_delta', (e) => e.turn === turn && events.filter((x) => x.type === 'text_delta' && x.turn === turn).length >= 10);
  const dropSeq = client.lastSeq;
  let welcomeHead = 0;
  const onControl = (f: { type: string; headSeq?: number }) => { if (f.type === 'welcome') welcomeHead = f.headSeq ?? 0; };
  client.on('control', onControl);
  client.dropConnection(); // reconnects after 2 s while the hub keeps streaming
  await new Promise((r) => client.once('reconnected', r));
  client.off('control', onControl);
  await turnEnd(turn);
  assert.ok(welcomeHead > dropSeq, `events were produced while disconnected (drop at ${dropSeq}, head at reconnect ${welcomeHead})`);
  assert.deepEqual(client.gaps, [], 'no gaps');
  const seqs = events.map((e) => e.seq);
  assert.equal(new Set(seqs).size, seqs.length, 'no duplicate seqs delivered');
  assert.deepEqual(seqs, seqs.map((_, i) => seqs[0] + i), 'seqs are contiguous');
  const streamed = events.filter((e) => e.type === 'text_delta' && e.turn === turn).map((e) => (e as { text: string }).text).join('');
  const final = events.filter((e) => e.type === 'assistant' && e.turn === turn).map((e) => (e as { text: string }).text).join('');
  assert.equal(streamed, final, 'streamed text equals the final message');
  console.log(`  reconnect: dropped at seq ${dropSeq}, ${welcomeHead - dropSeq} events replayed, ${client.duplicates} duplicates dropped by client`);
});

test('hub restart: log and seqs survive, the lead resumes its conversation', async () => {
  const before = client.lastSeq;
  const turnBefore = events.filter((e) => e.type === 'turn_end').at(-1)!.turn;
  await stopHub();
  await startHub();
  await new Promise((r) => client.once('reconnected', r));
  await next('session', (e) => e.state === 'ready' && e.seq > before);
  assert.deepEqual(client.gaps, []);
  const turn = await prompt('What codeword did I ask you to remember earlier? Reply with the codeword only.');
  assert.ok(turn > turnBefore, 'turn numbers continue');
  await turnEnd(turn);
  assert.ok(events.some((e) => e.type === 'assistant' && e.turn === turn && e.text.includes('PELICAN-42')), 'resumed session remembers the codeword');
});
