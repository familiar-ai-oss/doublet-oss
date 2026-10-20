// Conversations: every event carries the Claude session it belongs to, from the first turn; Clear starts a new one
// that is tagged from its first event; an earlier one can be resumed and remembers.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createHarness } from './harness.ts';

const h = createHarness('p7');
const { client, events, next, all } = h;
after(() => h.cleanup());

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

async function prompt(text: string): Promise<number> {
  const from = events.length;
  await client.send({ type: 'prompt', text });
  return (await next('user', (e) => e.text.startsWith(text), from)).turn;
}
const turnEnd = (turn: number) => next('turn_end', (e) => e.turn === turn, 0, 300_000);
const reply = (turn: number) => all('assistant', (e) => e.turn === turn).map((e) => e.text).join('');

let a = '';
let b = '';

test('a new conversation is named by the hub, so its first turn is tagged with it', async () => {
  await h.startHub();
  await client.connect();
  const starting = await next('session', (e) => e.state === 'starting');
  a = starting.sessionId!;
  assert.match(a, UUID);
  assert.equal(starting.conversationId, a, 'the session event carries the conversation it starts');
  assert.equal((await next('lead_info')).conversationId, a);
  const t = await prompt('Remember the codeword HERON-77. Reply OK.');
  await turnEnd(t);
  for (const type of ['user', 'turn_start', 'assistant', 'turn_end'] as const) {
    assert.ok(all(type).some((e) => 'turn' in e && e.turn === t && e.conversationId === a), `${type} of turn ${t} is tagged ${a}`);
  }
  assert.equal(all('session', (e) => e.state === 'ready' && !!e.sessionId && e.sessionId !== a).length, 0, 'Claude Code kept the id the hub chose');
  assert.equal(JSON.parse(readFileSync(join(h.stateDir, 'state.json'), 'utf8')).leadSessionId, a, 'persisted once the transcript exists');
  assert.ok(all('fleet').every((e) => !('conversationId' in e)), 'hub-wide events are not tagged');
});

test('clear starts a second conversation; the old one ends on its own id, the new one begins on its', async () => {
  const from = events.length;
  await client.send({ type: 'clear' });
  const cleared = await next('context', (e) => e.action === 'cleared', from);
  const ready = await next('session', (e) => e.state === 'ready', from);
  b = ready.sessionId!;
  assert.match(b, UUID);
  assert.notEqual(b, a);
  assert.equal(all('session', (e) => e.state === 'stopped').at(-1)!.conversationId, a, 'the stop belongs to the old conversation');
  assert.equal(cleared.conversationId, b, 'cleared belongs to the new one');
  const t = await prompt('What codeword did I ask you to remember? If you do not know, reply UNKNOWN.');
  await turnEnd(t);
  assert.doesNotMatch(reply(t), /HERON-77/);
  assert.ok(all('user', (e) => e.turn === t).every((e) => e.conversationId === b));
  assert.equal(all('lead_info').at(-1)!.conversationId, b);
});

test('resume is refused while a turn runs, and for ids that are not sessions', async () => {
  await assert.rejects(client.send({ type: 'resume_session', sessionId: 'nope' }), /not a session id/);
  await assert.rejects(client.send({ type: 'resume_session', sessionId: '00000000-0000-4000-8000-000000000000' }), /no session/);
  const from = events.length;
  await client.send({ type: 'prompt', text: 'Count slowly from 1 to 5, one number per line, then reply DONE.' });
  const t = (await next('turn_start', () => true, from)).turn;
  await assert.rejects(client.send({ type: 'resume_session', sessionId: a }), /turn is running/);
  await turnEnd(t);
});

test('resuming the first conversation makes it live again, and Claude remembers', async () => {
  const from = events.length;
  await client.send({ type: 'resume_session', sessionId: a });
  const resumed = await next('context', (e) => e.action === 'resumed', from);
  assert.deepEqual([resumed.sessionId, resumed.conversationId, resumed.by], [a, a, 'test']);
  assert.equal((await next('session', (e) => e.state === 'ready', from)).conversationId, a);
  assert.equal((await next('lead_info', () => true, from)).conversationId, a);
  // Resuming what is already live is a no-op.
  await client.send({ type: 'resume_session', sessionId: a });
  assert.equal(all('context', (e) => e.action === 'resumed').length, 1);
  const t = await prompt('What codeword did I ask you to remember? Reply with just the codeword.');
  await turnEnd(t);
  assert.match(reply(t), /HERON-77/, 'the resumed conversation remembers');
  assert.ok(all('user', (e) => e.turn === t).every((e) => e.conversationId === a));
  assert.equal(JSON.parse(readFileSync(join(h.stateDir, 'state.json'), 'utf8')).leadSessionId, a);
});
