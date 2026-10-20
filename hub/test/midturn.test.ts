// What you send while Claude works reaches it within seconds, not when its turn ends:
//  1. await_workers returns as soon as you write (a prompt or a note), though its workers still run.
//  2. A prompt goes straight to Claude Code, which hands it to Claude at its next tool call as a message from you
//     (UserPromptSubmit says when). It starts the hub's next turn, and nothing sends it again.
//  3. A note goes the same way with its picture, which is no longer dropped.
//  4. Every device sees what waits for Claude (a `queued` event), then sees it taken, or dropped by a hub restart.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Dialogue, LEAD, type FleetPort } from '../src/dialogue.ts';
import { droppedAtStart, Lead, SPOKEN_NOTE, VOICE_GUIDANCE, type Image } from '../src/lead.ts';
import { attachClaude } from './claude-session.ts';
import type { EventBody, HubEvent, Notes } from '../src/protocol.ts';
import { StateFile } from '../src/store.ts';

const signal = () => ({ signal: new AbortController().signal });
const INK: Image = { data: 'aW5r', type: 'image/png' };
const note = (id: string, text: string): Notes => ({ surface: { kind: 'file', path: '/tmp/a.ts' }, items: [{ id, intent: 'comment', text }], hasImage: true });
const textOf = (r: { content: { text: string }[] }) => r.content.map((c) => c.text).join('\n');

/** A busy lead wired to a dialogue as main.ts wires them, with one worker task running. */
function setup() {
  const events: EventBody[] = [];
  const taken: { ids: string[]; turn: number }[] = [];
  let idle = 0;
  let turnStarts = 0;
  const fleet: FleetPort = {
    delegate: () => 't-2',
    cancel: () => {},
    taskInfo: () => ({ worker: 'qwen-27b', state: 'running', by: LEAD }),
    activeTasks: () => ['t-1'],
    describe: () => '- qwen-27b: busy',
    idleLocal: () => [],
  };
  const d = new Dialogue((e) => events.push(e));
  const lead = new Lead({
    model: 'haiku', effort: 'low', cwd: '/tmp', autoAllow: [], log: () => {},
    onNotesTaken: (ids, turn) => taken.push({ ids: [...ids], turn }),
    onUserWaiting: () => d.userWrote(),
    onIdle: () => idle++,
    onTurnStart: () => turnStarts++,
  }, (e) => events.push(e), new StateFile('/nonexistent'), 4);
  d.attach(fleet, { busy: () => lead.busyNow, submit: (text, by) => lead.submit(text, by), conversation: () => 'conv-1', userWaiting: () => lead.userWaiting() });
  // What Claude Code was sent.
  const sent: { text: string; images: Image[] }[] = [];
  const claude = attachClaude(lead, (text, images = []) => void sent.push({ text, images }));
  // Claude is in turn 5, waiting on t-1.
  lead['busy'] = true;
  lead['turn'] = 5;
  /** Claude Code takes a message: its UserPromptSubmit hook, with the words it was sent. */
  const take = async (prompt: string) => {
    const out = (await claude['beforePrompt']({ hook_event_name: 'UserPromptSubmit', session_id: 's', transcript_path: '', cwd: '', prompt } as never, undefined, signal())) as {
      hookSpecificOutput?: { additionalContext?: string };
    };
    return out.hookSpecificOutput?.additionalContext ?? '';
  };
  const endTurn = () => claude.handle({ type: 'result', subtype: 'success', is_error: false, duration_ms: 1000, num_turns: 3 } as never);
  const of = <T extends EventBody['type']>(type: T) => events.filter((e): e is Extract<EventBody, { type: T }> => e.type === type);
  return { d, lead, claude, events, of, taken, sent, take, endTurn, idle: () => idle, turnStarts: () => turnStarts };
}

// ---- 1. await_workers ----

test('await_workers returns within seconds when you send a prompt, though its workers still run', async () => {
  const { d, lead } = setup();
  const started = Date.now();
  const waiting = d.awaitWorkers(undefined, 600);
  setTimeout(() => lead.submit('Also check the README', 'iphone'), 50);
  const r = await waiting;
  const took = Date.now() - started;
  assert.ok(took < 5000, `returned in ${took} ms`);
  assert.ok(took < 1000, `woken at once, not at the next 5 s check (${took} ms)`);
  assert.match(textOf(r), /The user wrote to you while you waited; their message follows/);
  assert.match(textOf(r), /call await_workers again: t-1 is still running/);
});

test('await_workers returns when you send a note, and says so beside worker messages', async () => {
  const { d, lead, take, sent } = setup();
  const waiting = d.awaitWorkers(undefined, 600);
  setTimeout(() => lead.addNotes('ipad', note('n1', 'rename this'), 'Note: rename this', INK), 50);
  assert.match(textOf(await waiting), /The user wrote to you/);

  d.post({ kind: 'STATUS', taskId: 't-1', from: 'qwen-27b', to: LEAD, text: 'halfway' });
  const both = textOf(await d.awaitWorkers(undefined, 600));
  assert.match(both, /\[STATUS task=t-1 from=qwen-27b\]\nhalfway/);
  assert.match(both, /The user wrote to you/, 'the note is still to be taken');

  // Once Claude Code has handed it over, await_workers waits again.
  await take(sent[0].text);
  assert.equal(lead.userWaiting(), false);
  assert.match(textOf(await d.awaitWorkers(undefined, 0.2)), /Still working: t-1/);
});

test("commands and the hub's own turns wait for the turn's end, and don't cut await_workers short", async () => {
  const { d, lead, sent } = setup();
  lead.compact('mac');
  lead.submit('[duet] Worker messages are waiting.', 'duet');
  assert.equal(sent.length, 0);
  assert.equal(lead.userWaiting(), false);
  assert.match(textOf(await d.awaitWorkers(undefined, 0.2)), /Still working: t-1/);
});

// ---- 2. prompts ----

test('a prompt goes to Claude Code at once, starts the next turn when taken, and is never sent again', async () => {
  const { lead, of, sent, take, endTurn, idle } = setup();
  lead.submit('Use the 9B for the tally', 'iphone');
  assert.deepEqual(sent, [{ text: 'Use the 9B for the tally', images: [] }], 'sent now, as a message from you');
  assert.equal(of('user').length, 0, 'not in the transcript until Claude has it');

  await take('Use the 9B for the tally');
  assert.deepEqual(of('user'), [{ type: 'user', turn: 6, text: 'Use the 9B for the tally', by: 'iphone' }], 'the next turn');
  assert.ok(of('turn_start').some((e) => e.turn === 6));
  assert.equal(of('turn_end').length, 0, "Claude Code's turn goes on");

  endTurn();
  assert.deepEqual(of('turn_end').map((e) => e.turn), [6]);
  assert.equal(sent.length, 1, 'the turn\'s end sends nothing again');
  assert.equal(lead.busyNow, false);
  assert.equal(idle(), 1);
});

test('a prompt Claude Code takes after the turn ends is a turn of its own', async () => {
  const { lead, of, sent, take, endTurn, idle, turnStarts } = setup();
  lead.submit('One more thing', 'mac');
  endTurn();
  assert.deepEqual(of('turn_end').map((e) => e.turn), [5]);
  assert.equal(lead.busyNow, true, 'Claude Code holds it for its next turn');
  assert.equal(idle(), 0, 'not idle');
  lead.submit('And another', 'mac');
  assert.equal(sent.length, 2, 'behind it, in order');

  await take('One more thing');
  assert.deepEqual(of('user').map((e) => [e.turn, e.text]), [[6, 'One more thing']]);
  assert.equal(turnStarts(), 1, 'a turn of its own');
  await take('And another');
  assert.deepEqual(of('user').map((e) => [e.turn, e.text]), [[6, 'One more thing'], [7, 'And another']]);
});

test('a spoken prompt sent mid-turn carries its spoken note, and Claude hears its reply is read aloud', async () => {
  const { lead, of, sent, take } = setup();
  lead.submit('Stop the 27B', 'iphone', false, { voice: true });
  assert.equal(sent[0].text, `Stop the 27B\n\n${SPOKEN_NOTE}`);
  assert.match(await take(sent[0].text), new RegExp(VOICE_GUIDANCE.slice(0, 40).replace(/[()[\]]/g, '\\$&')));
  assert.equal(of('user')[0].voice, true);
  assert.equal(of('user')[0].text, 'Stop the 27B', 'the transcript shows what was said');
});

test('a prompt that comes while Claude is idle starts a turn at once, as before', () => {
  const { lead, of, sent } = setup();
  lead['busy'] = false;
  lead.submit('Hello', 'mac');
  assert.deepEqual(sent.map((s) => s.text), ['Hello']);
  assert.deepEqual(of('user').map((e) => e.turn), [6]);
  assert.equal(of('queued').length, 0, 'nothing waits');
});

// ---- 3. notes ----

test("a note sent while Claude works shows at once, and reaches Claude with its picture", async () => {
  const { lead, of, sent, take, taken } = setup();
  lead.addNotes('ipad', note('n1', 'this loop is wrong'), 'Note: this loop is wrong. The attached image shows the ink.', INK);
  assert.equal(of('notes').length, 1, 'its row, where it came');
  assert.deepEqual(sent, [{ text: 'Note: this loop is wrong. The attached image shows the ink.', images: [INK] }], 'kept, not dropped');
  assert.equal(of('queued').length, 0, 'its row is the notes row');
  await take(sent[0].text);
  assert.deepEqual(taken, [{ ids: ['n1'], turn: 5 }]);
  assert.equal(of('user').length, 0, 'no second row');
});

test('notes taken earlier in a turn are answered by the turn a mid-turn prompt starts', async () => {
  const { lead, taken, take, sent } = setup();
  lead.addNotes('ipad', note('n1', 'rename this'), 'Note: rename this', INK);
  await take(sent[0].text);
  lead.submit('Thanks', 'ipad');
  await take('Thanks');
  assert.deepEqual(taken.at(-1), { ids: ['n1'], turn: 6 }, 'turn 5 has no end of its own now');
});

// ---- 4. what waits, on every device ----

test('every device sees a prompt wait for Claude, then sees it taken', async () => {
  const { lead, of, take } = setup();
  lead.submit('how long do we keep the EC2 up?', 'iphone');
  const [w] = of('queued');
  assert.equal(w.state, 'waiting');
  assert.equal(w.text, 'how long do we keep the EC2 up?');
  assert.equal(w.by, 'iphone');
  await take('how long do we keep the EC2 up?');
  assert.deepEqual(of('queued').map((e) => e.state), ['waiting', 'taken']);
});

test("a command held for the turn's end waits visibly too, and is taken when it runs", () => {
  const { lead, of, endTurn } = setup();
  lead.compact('mac');
  assert.deepEqual(of('queued').map((e) => [e.state, e.text]), [['waiting', '/compact']]);
  endTurn();
  assert.deepEqual(of('queued').map((e) => e.state), ['waiting', 'taken']);
  assert.equal(of('user').at(-1)?.text, '/compact');
});

test('what Claude Code took unseen is marked taken once it is idle, so nothing waits for ever', () => {
  const { lead, claude, of } = setup();
  lead.submit('reworded somewhere', 'mac');
  claude.handle({ type: 'system', subtype: 'session_state_changed', state: 'idle' } as never);
  assert.deepEqual(of('queued').map((e) => e.state), ['waiting', 'taken']);
  assert.equal(lead.userWaiting(), false);
});

test('a hub restart drops what it held, and says so', () => {
  const at = (seq: number, body: EventBody): HubEvent => ({ ...body, seq, ts: seq, conversationId: 'c1' }) as HubEvent;
  const log = [
    at(1, { type: 'queued', id: 'q-1', state: 'waiting', text: 'first', by: 'mac' }),
    at(2, { type: 'queued', id: 'q-2', state: 'waiting', text: 'second', by: 'mac' }),
    at(3, { type: 'queued', id: 'q-1', state: 'taken' }),
  ];
  assert.deepEqual(droppedAtStart(log), [{ type: 'queued', id: 'q-2', state: 'dropped', reason: 'the hub restarted before Claude took it', conversationId: 'c1' }]);
  assert.deepEqual(droppedAtStart([...log, at(4, { type: 'queued', id: 'q-2', state: 'dropped' })]), []);
});
