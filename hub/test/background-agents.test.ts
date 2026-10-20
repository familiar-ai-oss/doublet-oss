// Claude's subagents followed through Claude Code's task messages, without models (fake SDK messages, in the order the
// CLI sends them):
//  1. A background subagent runs past Claude's turn, and ends at its notice with its real report and usage.
//  2. One Claude waits on still ends with its Agent call's result; its notice doesn't end it twice.
//  3. One missing from Claude Code's background work for 30 s, with no notice, ends as lost; one that comes back doesn't.
//  4. When Claude Code stops, every subagent stops with it; when the hub restarts, the log's running ones end.
//  5. A subagent's own subagent is a task under its parent's, and stays out of Claude's thread.
//  6. A turn Claude Code starts by itself (to read a report) gets its own number; a prompt sent meanwhile is the next.
import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import { Fleet, subagentTaskId } from '../src/fleet.ts';
import { LOST_AFTER_MS, LOST_NOTE, Lead } from '../src/lead.ts';
import { attachClaude } from './claude-session.ts';
import type { EventBody } from '../src/protocol.ts';
import { StateFile } from '../src/store.ts';

type Ev<T extends EventBody['type']> = Extract<EventBody, { type: T }>;
const of = <T extends EventBody['type']>(events: EventBody[], type: T) => events.filter((e): e is Ev<T> => e.type === type);

/** A lead and a fleet wired as the hub wires them, a conversation, and Claude Code's messages fed in by hand. */
function setup() {
  const events: EventBody[] = [];
  const emit = (e: EventBody) => void events.push(e);
  const fleet = new Fleet({ workers: [], llmdAdmin: 'http://127.0.0.1:1', modelsToml: '/nonexistent', claimsAllDevices: [], defaultCwd: '/tmp', proxyBaseUrl: () => '', log: () => {}, currentConversation: () => 'conv-1' }, emit);
  const lead = new Lead({
    model: 'haiku', effort: 'low', cwd: '/tmp', autoAllow: [], log: () => {},
    subagents: {
      start: (id, kind, prompt, info) => fleet.subagentStart(id, kind, prompt, info),
      progress: (id, p) => fleet.subagentProgress(id, p),
      isSubagent: (id) => fleet.isSubagent(id),
      background: (id) => fleet.subagentBackground(id),
      end: (id, state, result, outcome) => fleet.subagentEnd(id, state, result, outcome),
      stopped: (all) => fleet.subagentsStopped(all),
    },
  }, emit, new StateFile('/nonexistent'), 0);
  const sent: string[] = [];
  const claude = attachClaude(lead, (text) => void sent.push(text));
  const feed = (...ms: object[]) => { for (const m of ms) claude.handle(m as never); };
  const tasks = (id: string) => of(events, 'task').filter((e) => e.taskId === id);
  const cards = (id: string) => of(events, 'dialogue').filter((e) => e.taskId === id);
  return { lead, claude, fleet, events, sent, feed, tasks, cards };
}

// Claude Code's messages.
const ids = { uuid: 'u-1', session_id: 'conv-1' };
const agentCall = (id: string, input: Record<string, unknown>) =>
  ({ type: 'assistant', parent_tool_use_id: null, message: { id: `msg-${id}`, role: 'assistant', content: [{ type: 'tool_use', id, name: 'Agent', input }] }, ...ids });
const said = (text: string) => ({ type: 'assistant', parent_tool_use_id: null, message: { id: `msg-${text.length}`, role: 'assistant', content: [{ type: 'text', text }] }, ...ids });
const delta = (text: string) => ({ type: 'stream_event', parent_tool_use_id: null, event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } }, ...ids });
const toolResult = (id: string, content: string, out?: unknown, isError = false) =>
  ({ type: 'user', parent_tool_use_id: null, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content, is_error: isError }] }, tool_use_result: out, ...ids });
// A subagent's own tool call, and its result: what Claude Code sends of a background subagent's work.
const subCall = (parent: string, n: number, command: string) =>
  ({ type: 'assistant', parent_tool_use_id: parent, message: { id: `msg-sub-${n}`, role: 'assistant', content: [{ type: 'tool_use', id: `toolu_sub${n}`, name: 'Bash', input: { command } }], usage: { input_tokens: 400, output_tokens: 30, cache_read_input_tokens: 600, cache_creation_input_tokens: 0 } }, ...ids });
const subResult = (parent: string, n: number, content: string) =>
  ({ type: 'user', parent_tool_use_id: parent, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: `toolu_sub${n}`, content }] }, ...ids });
const sys = (subtype: string, fields: Record<string, unknown>) => ({ type: 'system', subtype, ...fields, ...ids });
const result = (numTurns = 2) => ({ type: 'result', subtype: 'success', is_error: false, duration_ms: 1200, num_turns: numTurns, result: '', ...ids });

const started = (taskId: string, toolUseId: string, more: Record<string, unknown> = {}) =>
  sys('task_started', { task_id: taskId, tool_use_id: toolUseId, description: 'Benchmark the lexer', subagent_type: 'general-purpose', task_type: 'local_agent', spawn_depth: 1, prompt: 'Time the lexer on big.swift.', ...more });
const launched = (id: string, agentId: string) =>
  toolResult(id, `Async agent launched successfully.\nagentId: ${agentId}`, { status: 'async_launched', agentId, description: 'Benchmark the lexer', prompt: 'Time the lexer on big.swift.', outputFile: `/tmp/${agentId}.output` });
const backgroundNow = (...taskIds: string[]) =>
  sys('background_tasks_changed', { tasks: taskIds.map((task_id) => ({ task_id, task_type: 'local_agent', subagent_type: 'general-purpose', description: 'Benchmark the lexer' })) });
const notice = (taskId: string, toolUseId: string, status: string, summary: string, usage = { total_tokens: 21000, tool_uses: 2, duration_ms: 52000 }) =>
  sys('task_notification', { task_id: taskId, tool_use_id: toolUseId, status, output_file: `/tmp/${taskId}.output`, summary, usage });

const CALL = 'toolu_01Bg000000benchmk';
const BG = subagentTaskId(CALL);

/** Claude starts a background subagent in turn 1, says so, and its turn ends. */
function launchInBackground(s: ReturnType<typeof setup>) {
  s.lead.submit('Benchmark the lexer in the background, please', 'mac');
  s.feed(
    agentCall(CALL, { description: 'Benchmark the lexer', prompt: 'Time the lexer on big.swift.', subagent_type: 'general-purpose', run_in_background: true }),
    // It joins Claude Code's background work before its task_started (as the SDK documents).
    backgroundNow('a-bench'),
    started('a-bench', CALL, { is_backgrounded: true }),
    launched(CALL, 'a-bench'),
    said("It's timing the lexer in the background; I'll tell you when it's done."),
    result(),
  );
}

test('a background subagent runs past the turn that started it, and ends at its notice with its real report', () => {
  const s = setup();
  launchInBackground(s);
  const [first, bg] = s.tasks(BG);
  assert.equal(first.state, 'running');
  assert.equal(first.label, 'Benchmark the lexer', "the Agent call's description, on its first event");
  assert.equal(first.background, undefined, 'not called background before Claude Code says so');
  assert.deepEqual([bg.state, bg.background], ['running', true], 'then it goes to the background');
  assert.equal(s.tasks(BG).length, 2, "the turn's end didn't cancel it");
  assert.equal(of(s.events, 'turn_end').at(-1)?.turn, 1);
  assert.equal(s.cards(BG).length, 1, 'only its TASK card so far');
  assert.deepEqual(of(s.events, 'fleet').at(-1)!.workers.find((w) => w.id === 'claude-general-purpose')!.active, [BG], 'its fleet row shows it running');

  // It works on: its tool calls show as its progress, and Claude Code's running totals change nothing.
  s.feed(subCall(CALL, 1, 'swift build -c release'), subResult(CALL, 1, 'Build complete!'), subCall(CALL, 2, 'time ./lexer big.swift'), subResult(CALL, 2, 'real 0.041s'));
  s.feed(sys('task_progress', { task_id: 'a-bench', tool_use_id: CALL, description: 'Benchmark the lexer', usage: { total_tokens: 9000, tool_uses: 2, duration_ms: 30000 }, last_tool_name: 'Bash' }));
  const progress = of(s.events, 'task_progress').filter((e) => e.taskId === BG);
  assert.equal(progress.length, 4);
  assert.equal(progress[3].toolResult, 'real 0.041s');

  // It ends: Claude Code says so, then sends its notice with the report, then drops it from its background work.
  s.feed(
    sys('task_updated', { task_id: 'a-bench', patch: { status: 'completed', end_time: 52 } }),
    notice('a-bench', CALL, 'completed', 'The lexer takes 41 ms on big.swift (12 MB), about 290 MB/s.'),
    backgroundNow(),
  );
  const done = s.tasks(BG).at(-1)!;
  assert.equal(done.state, 'done');
  assert.equal(done.result, 'The lexer takes 41 ms on big.swift (12 MB), about 290 MB/s.');
  assert.deepEqual([done.stats?.requests, done.stats?.inputTokens, done.stats?.outputTokens, done.stats?.wallMs], [2, 2000, 60, 52000], 'the tokens of its messages Duet saw, and Claude Code\'s time');
  assert.equal(s.cards(BG).at(-1)!.kind, 'RESULT');
  assert.equal(s.cards(BG).at(-1)!.text, 'Finished: The lexer takes 41 ms on big.swift (12 MB), about 290 MB/s.');
  assert.equal(s.cards(BG).at(-1)!.to, 'lead');
  assert.deepEqual(of(s.events, 'fleet').at(-1)!.workers.find((w) => w.id === 'claude-general-purpose')!.active, []);
  assert.equal(s.tasks(BG).length, 3, 'it ended once');

  // Claude Code starts a turn by itself to read the report: it gets the next number, with no prompt before it.
  const before = s.events.length;
  s.feed(delta('The benchmark is back: '), said('The benchmark is back: 41 ms on the 12 MB file.'), result());
  const turn = s.events.slice(before);
  assert.deepEqual(turn.map((e) => e.type), ['turn_start', 'text_delta', 'assistant', 'turn_end']);
  assert.deepEqual(turn.map((e) => (e as { turn?: number }).turn), [2, 2, 2, 2]);
});

test("a subagent Claude waits on ends with its call's result, as before; its notice doesn't end it twice", () => {
  const s = setup();
  const call = 'toolu_01Fg00000000fgnd';
  s.lead.submit('Find where the lexer reads strings', 'ipad');
  s.feed(
    agentCall(call, { description: 'Find string reading', prompt: 'Find where the lexer reads string literals.', subagent_type: 'Explore' }),
    started('a-fg', call, { subagent_type: 'Explore', is_backgrounded: false, description: 'Find string reading' }),
    sys('task_updated', { task_id: 'a-fg', patch: { status: 'completed', end_time: 9 } }),
    notice('a-fg', call, 'completed', 'Lexer.swift:88 reads them.'),
    toolResult(call, '[Subagent hand-back] The report follows:\n  Lexer.swift:88', {
      status: 'completed', content: [{ type: 'text', text: 'readString() in Lexer.swift:88 reads them.' }], totalToolUseCount: 3, totalDurationMs: 9000, totalTokens: 5100,
      usage: { input_tokens: 1000, output_tokens: 100, cache_read_input_tokens: 4000, cache_creation_input_tokens: 0 },
    }),
    result(),
  );
  const id = subagentTaskId(call);
  const states = s.tasks(id).map((e) => e.state);
  assert.deepEqual(states, ['running', 'done'], 'never sent to the background, ended once');
  assert.equal(s.tasks(id)[1].result, 'readString() in Lexer.swift:88 reads them.', 'the report from its result, not its notice');
  assert.deepEqual([s.tasks(id)[1].stats?.inputTokens, s.tasks(id)[1].stats?.outputTokens], [5000, 100]);
  assert.equal(s.cards(id).at(-1)!.text, 'Finished: readString() in Lexer.swift:88 reads them.');
});

test('a failed background subagent fails with its reason; a stopped one is stopped, with no RESULT card', () => {
  const s = setup();
  launchInBackground(s);
  s.feed(notice('a-bench', CALL, 'failed', 'swift build failed: no such module Parser'));
  assert.equal(s.tasks(BG).at(-1)!.state, 'failed');
  assert.equal(s.cards(BG).at(-1)!.text, 'Failed: swift build failed: no such module Parser');

  const t = setup();
  launchInBackground(t);
  t.feed(notice('a-bench', CALL, 'stopped', 'Benchmark the lexer'));
  assert.equal(t.tasks(BG).at(-1)!.state, 'cancelled');
  assert.deepEqual(t.cards(BG).map((c) => c.kind), ['TASK']);
});

test('a subagent sent to the background mid-run runs on past its call', () => {
  const s = setup();
  const call = 'toolu_01Mv00000000moved';
  s.lead.submit('Run the slow tests', 'mac');
  s.feed(
    agentCall(call, { description: 'Run the slow tests', prompt: 'Run the slow test suite.' }),
    started('a-slow', call, { is_backgrounded: false, description: 'Run the slow tests' }),
    sys('task_updated', { task_id: 'a-slow', patch: { is_backgrounded: true } }),
    // Its call returns at once, saying it moved to the background.
    toolResult(call, 'Moved to the background. You will be notified when it finishes.'),
    result(),
  );
  const id = subagentTaskId(call);
  assert.deepEqual(s.tasks(id).map((e) => [e.state, e.background]), [['running', undefined], ['running', true]]);
  s.feed(notice('a-slow', call, 'completed', 'All 212 slow tests pass.'));
  assert.equal(s.tasks(id).at(-1)!.result, 'All 212 slow tests pass.');
});

test("a background subagent missing from Claude Code's background work for 30 s, with no notice, is lost; one that comes back isn't", () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    const s = setup();
    launchInBackground(s);
    s.feed(backgroundNow()); // gone, without a word
    mock.timers.tick(LOST_AFTER_MS - 1000);
    s.feed(backgroundNow('a-bench')); // back: the clock stops
    mock.timers.tick(LOST_AFTER_MS);
    assert.equal(s.tasks(BG).at(-1)!.state, 'running', 'it came back in time');

    s.feed(backgroundNow());
    mock.timers.tick(LOST_AFTER_MS - 1);
    assert.equal(s.tasks(BG).at(-1)!.state, 'running');
    mock.timers.tick(1);
    const lost = s.tasks(BG).at(-1)!;
    assert.deepEqual([lost.state, lost.result], ['failed', LOST_NOTE]);
    assert.equal(s.cards(BG).at(-1)!.text, `Failed: ${LOST_NOTE}`);
    // A notice that comes after all changes nothing.
    s.feed(notice('a-bench', CALL, 'completed', 'Too late.'));
    assert.equal(s.tasks(BG).length, 3);

    // Idle means nothing runs, background work included: one still running here was missed, unless it's still listed.
    const t = setup();
    launchInBackground(t);
    t.feed(sys('session_state_changed', { state: 'idle' }));
    mock.timers.tick(LOST_AFTER_MS);
    assert.equal(t.tasks(BG).at(-1)!.state, 'running', 'still listed as background work');
    t.feed(backgroundNow(), sys('task_updated', { task_id: 'a-bench', patch: { status: 'completed' } }));
    mock.timers.tick(LOST_AFTER_MS);
    assert.deepEqual([t.tasks(BG).at(-1)!.state, t.tasks(BG).at(-1)!.result], ['done', "Claude Code said this subagent ended, but its report never reached Doublet."], 'it said it ended; its notice never came');
  } finally {
    mock.timers.reset();
  }
});

test('when Claude Code stops, its subagents stop with it; when the hub restarts, those the log shows running end', async () => {
  const s = setup();
  s.lead['stopping'] = true; // no automatic restart in a test
  async function* stream() {
    yield agentCall(CALL, { description: 'Benchmark the lexer', prompt: 'Time it.' });
    yield started('a-bench', CALL, { is_backgrounded: true });
    yield launched(CALL, 'a-bench');
    yield result();
    yield backgroundNow('a-bench');
  }
  s.lead.submit('Benchmark it in the background', 'mac');
  await s.claude['pump'](stream() as never);
  const end = s.tasks(BG).at(-1)!;
  assert.equal(end.state, 'cancelled');
  assert.match(end.result ?? '', /Claude Code restarted while it ran/);
  assert.equal(s.claude['runs'].size, 0);
  assert.equal(s.claude['backgroundSet'], null, "the next process's background work starts unknown");
  assert.equal(of(s.events, 'session').at(-1)?.state, 'stopped');

  // A hub that restarts reads its log: Claude's subagents still running there stopped with the old hub.
  const events: EventBody[] = [];
  const fleet = new Fleet({ workers: [], llmdAdmin: 'http://127.0.0.1:1', modelsToml: '/nonexistent', claimsAllDevices: [], defaultCwd: '/tmp', proxyBaseUrl: () => '', log: () => {} }, (e) => events.push(e));
  fleet.endOrphans([
    { type: 'task', taskId: 'sa-11111111', worker: 'claude-explore', state: 'running', prompt: 'p', conversationId: 'c-old' },
    { type: 'task', taskId: 'sa-11111111', worker: 'claude-explore', state: 'running', background: true, conversationId: 'c-old' },
    { type: 'task', taskId: 'sa-22222222', worker: 'claude-plan', state: 'running', conversationId: 'c-old' },
    { type: 'task', taskId: 'sa-22222222', worker: 'claude-plan', state: 'done', result: 'Planned.', conversationId: 'c-old' },
    { type: 'task', taskId: 't-abc123', worker: 'qwen-27b', state: 'running', conversationId: 'c-old' },
  ]);
  assert.deepEqual(events, [{ type: 'task', taskId: 'sa-11111111', worker: 'claude-explore', state: 'cancelled', result: 'Stopped: the hub restarted while it ran.', conversationId: 'c-old' }]);
});

test("a subagent's own subagent is a task under its parent's, out of Claude's thread, and ends at its notice", () => {
  const s = setup();
  launchInBackground(s);
  const nested = 'toolu_01Nst0000000nested';
  const id = subagentTaskId(nested);
  s.feed(sys('task_started', { task_id: 'a-read', tool_use_id: nested, parent_task_id: 'a-bench', spawn_depth: 2, description: 'Read the parser', subagent_type: 'Explore', task_type: 'local_agent', is_backgrounded: false, prompt: 'Read Parser.swift and say how it reads tokens.' }));
  const [first] = s.tasks(id);
  assert.deepEqual([first.worker, first.state, first.label, first.parentId, first.depth, first.conversationId], ['claude-explore', 'running', 'Read the parser', BG, 2, 'conv-1']);
  const [card] = s.cards(id);
  assert.deepEqual([card.kind, card.from, card.to], ['TASK', 'claude-general-purpose', 'claude-explore'], "its parent's message, not Claude's");

  // Claude's next turn ends while both run: the background parent's helper runs on.
  s.lead.submit('Anything yet?', 'mac');
  s.feed(said('Still running.'), result());
  assert.equal(s.tasks(id).at(-1)!.state, 'running');

  s.feed(notice('a-read', nested, 'completed', 'It reads one token at a time with peek().'));
  assert.equal(s.tasks(id).at(-1)!.result, 'It reads one token at a time with peek().');
  assert.deepEqual([s.cards(id).at(-1)!.from, s.cards(id).at(-1)!.to], ['claude-explore', 'claude-general-purpose']);

  // One a waited-on subagent started is cut off with it at the turn's end; one whose launcher the hub doesn't follow
  // (an agent inside a workflow) isn't a task at all.
  const t = setup();
  const fg = 'toolu_01Fg0000000parent';
  t.lead.submit('Look into it', 'mac');
  t.feed(
    agentCall(fg, { description: 'Look into it', prompt: 'Look into the parser.' }),
    started('a-fg', fg, { is_backgrounded: false }),
    sys('task_started', { task_id: 'a-helper', tool_use_id: 'toolu_01Hp00000helper', parent_task_id: 'a-fg', spawn_depth: 2, description: 'Helper', subagent_type: 'Explore', task_type: 'local_agent' }),
    sys('task_started', { task_id: 'a-wf', tool_use_id: 'toolu_01Wf00000wfagent', spawn_depth: 2, description: 'Inside a workflow', subagent_type: 'Explore', task_type: 'local_agent' }),
    result(),
  );
  assert.equal(t.tasks(subagentTaskId('toolu_01Hp00000helper')).at(-1)!.state, 'cancelled');
  assert.equal(t.tasks(subagentTaskId(fg)).at(-1)!.state, 'cancelled');
  assert.equal(t.tasks(subagentTaskId('toolu_01Wf00000wfagent')).length, 0);
});

test('a turn Claude Code starts by itself gets its own number, and a prompt sent meanwhile is the next one', async () => {
  const s = setup();
  s.lead.submit('Hello', 'mac');
  s.feed(said('Hi.'), result());
  assert.deepEqual(of(s.events, 'turn_end').map((e) => e.turn), [1]);

  // Claude Code answers a background report with no prompt from the hub: a turn of its own.
  s.feed(said('The benchmark finished: 41 ms.'));
  assert.deepEqual(of(s.events, 'turn_start').map((e) => e.turn), [1, 2]);
  assert.equal(of(s.events, 'user').length, 1, 'no prompt is made up for it');
  assert.equal(s.lead.busyNow, true);
  s.lead.submit('Thanks. Now run it on the small file', 'ipad');
  // It goes to Claude Code at once, which hands it to Claude at its next tool call or as the next turn (midturn.test.ts).
  assert.deepEqual(s.sent, ['Hello', 'Thanks. Now run it on the small file']);
  s.feed(result());
  assert.deepEqual(of(s.events, 'turn_end').map((e) => e.turn), [1, 2]);
  await s.claude['beforePrompt']({ hook_event_name: 'UserPromptSubmit', prompt: 'Thanks. Now run it on the small file' } as never, undefined, { signal: new AbortController().signal });
  assert.equal(of(s.events, 'user').at(-1)!.turn, 3);

  // A result with no turn open and no model call in it (a queued command run without the model) ends nothing.
  s.feed(said('Running it.'), result());
  const n = s.events.length;
  s.feed(result(0));
  assert.equal(s.events.length, n);
});
