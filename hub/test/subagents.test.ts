// Claude's own subagents shown as workers: each kind a fleet entry, each Agent call a task with a thread.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Fleet, subagentReport, subagentTaskId } from '../src/fleet.ts';
import type { EventBody } from '../src/protocol.ts';

function fleet(currentConversation?: () => string | undefined) {
  const events: EventBody[] = [];
  const f = new Fleet({ workers: [], llmdAdmin: 'http://127.0.0.1:1', modelsToml: '/nonexistent', claimsAllDevices: [], defaultCwd: '/tmp', proxyBaseUrl: () => '', log: () => {}, currentConversation }, (e) => events.push(e));
  return { f, events };
}
const of = <T extends EventBody['type']>(events: EventBody[], type: T) => events.filter((e): e is Extract<EventBody, { type: T }> => e.type === type);

test("a subagent call is a task of its kind's worker, with its messages as progress, its tokens, and cards in Claude's thread", () => {
  const { f, events } = fleet();
  f.subagentStart('toolu_0123456789abcdef', 'Explore', 'Find where the hub reads models.toml');
  f.subagentStart('toolu_00000000ffffeeee', 'Explore', 'Find the effort tables');
  const id = subagentTaskId('toolu_0123456789abcdef');
  assert.equal(id, 'sa-89abcdef');
  const w = of(events, 'fleet').at(-1)!.workers.find((x) => x.id === 'claude-explore')!;
  assert.deepEqual([w.label, w.backend, w.available, w.running, w.active], ['Explore · Claude subagent', 'claude', true, id, [id, 'sa-ffffeeee']]);
  assert.deepEqual(of(events, 'dialogue')[0], { type: 'dialogue', id: `${id}-task`, kind: 'TASK', taskId: id, from: 'lead', to: 'claude-explore', text: 'Find where the hub reads models.toml' });

  // Blocks of one API message repeat its usage: counted once.
  f.subagentProgress('toolu_0123456789abcdef', { toolUses: [{ name: 'Grep', input: { pattern: 'models.toml' } }], usage: { messageId: 'msg_1', input: 1000, output: 40 } });
  f.subagentProgress('toolu_0123456789abcdef', { text: 'Found it in fleet.ts.', usage: { messageId: 'msg_1', input: 1000, output: 60 } });
  f.subagentProgress('toolu_0123456789abcdef', { toolResult: 'src/fleet.ts:172' });
  f.subagentProgress('toolu_unknown', { text: "a subagent's own subagent: ignored" });
  const progress = of(events, 'task_progress');
  assert.equal(progress.length, 3);
  assert.deepEqual(progress[0].toolUses, [{ name: 'Grep', input: { pattern: 'models.toml' } }]);
  assert.equal(progress[1].text, 'Found it in fleet.ts.');

  assert.equal(f.isSubagent('toolu_0123456789abcdef'), true);
  assert.equal(f.isSubagent('toolu_something_else'), false);
  f.subagentEnd('toolu_0123456789abcdef', 'done', 'readDevices() in src/fleet.ts reads it.');
  const done = of(events, 'task').find((e) => e.taskId === id && e.state === 'done')!;
  assert.equal(done.result, 'readDevices() in src/fleet.ts reads it.');
  assert.deepEqual([done.stats?.requests, done.stats?.inputTokens, done.stats?.outputTokens], [1, 1000, 60]);
  assert.equal(of(events, 'dialogue').at(-1)!.text, 'Finished: readDevices() in src/fleet.ts reads it.');
  assert.deepEqual(of(events, 'fleet').at(-1)!.workers.find((x) => x.id === 'claude-explore')!.active, ['sa-ffffeeee']);

  // The turn ended with one still running: cancelled, without a RESULT card.
  const cards = of(events, 'dialogue').length;
  f.subagentsStopped();
  assert.equal(of(events, 'task').at(-1)!.state, 'cancelled');
  assert.equal(of(events, 'dialogue').length, cards);
  assert.deepEqual(f.activeTasks('lead'), []);
});

test("Claude's subagents can't be given tasks, cancelled one by one, picked by auto, or listed for Claude", () => {
  const { f, events } = fleet();
  f.subagentStart('toolu_aaaaaaaabbbbbbbb', 'general-purpose', 'Refactor x');
  assert.throws(() => f.delegate('claude-general-purpose', 'Do y', 'mac'), /Claude starts those itself/);
  assert.throws(() => f.cancel('sa-bbbbbbbb', 'mac'), /stops with Claude's turn/);
  assert.throws(() => f.delegate('auto', 'Do y', 'mac'), /auto found no local worker for this large task \(a busy one would just have queued it\): there are no local workers\.$/);
  assert.equal(f.describe(), '');
  const before = events.length;
  f.seedSubagents(['claude-plan', 'qwen-27b']);
  assert.equal(events.length, before, 'seeding publishes nothing: the first refresh does, once what is loaded is known');
  assert.ok(f.snapshot().some((w) => w.id === 'claude-plan' && w.label === 'Plan · Claude subagent'));
});

test("a task's events carry the conversation it started in, even after the lead moves to another", () => {
  let current: string | undefined = 'conv-A';
  const { f, events } = fleet(() => current);
  f.subagentStart('toolu_0123456789abcdef', 'Explore', 'Find the effort tables');
  assert.equal(of(events, 'task')[0].conversationId, 'conv-A');
  assert.equal(of(events, 'dialogue')[0].conversationId, 'conv-A');
  current = 'conv-B'; // a Clear happened
  f.subagentProgress('toolu_0123456789abcdef', { text: 'Still looking.' });
  f.subagentEnd('toolu_0123456789abcdef', 'done', 'effort.ts');
  assert.ok(events.slice(1).filter((e) => e.type !== 'fleet' && e.type !== 'model_catalog').every((e) => e.conversationId === 'conv-A'));
  assert.equal(f.taskInfo('sa-89abcdef')?.conversationId, 'conv-A');
  // Without a lead to ask, tasks carry no tag (the log stamps the current conversation).
  const bare = fleet();
  bare.f.subagentStart('toolu_0000000011111111', 'Plan', 'Plan it');
  assert.equal('conversationId' in of(bare.events, 'task')[0], false);
});

test("a subagent's report: Claude Code's totals when it gives them, its framed text otherwise", () => {
  assert.equal(subagentReport('[Subagent hand-back] The text below is the final report. The report follows:\n  One file reads it.\n  \n  **Where**\n  - fleet.ts:173'), 'One file reads it.\n\n**Where**\n- fleet.ts:173');
  assert.equal(subagentReport('Plain report.'), 'Plain report.');
  const { f, events } = fleet();
  f.subagentStart('toolu_cccccccc11112222', 'general-purpose', 'Rename x to y');
  f.subagentEnd('toolu_cccccccc11112222', 'done', 'ignored framed text', { report: 'Renamed in 2 files.', inputTokens: 5000, outputTokens: 700, toolUses: 6, durationMs: 31000, edits: { files: 2, added: 4, removed: 4 } });
  const done = of(events, 'task').at(-1)!;
  assert.equal(done.result, 'Renamed in 2 files.');
  assert.equal(done.evidence, "2 files edited, +4 −4 lines (Claude Code's count)");
  assert.deepEqual([done.stats?.inputTokens, done.stats?.outputTokens, done.stats?.wallMs], [5000, 700, 31000]);
});
