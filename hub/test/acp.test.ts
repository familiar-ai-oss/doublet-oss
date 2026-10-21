// The ACP adapter without an agent: the agent's messages fed in by hand, and what the session writes back read off a
// fake stdin. A prompt written mid-turn waits for the next; permission requests pick the right option (read-only
// calls and Doublet's own tools run without a card); an MCP call is shown once the agent names it; the history
// session/load replays isn't news; and every request is answered.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AcpSession, CURSOR_ACP } from '../src/agents/acp.ts';
import type { AgentEvent } from '../src/agents/adapter.ts';

const OPTIONS = [
  { optionId: 'allow-once', name: 'Allow once', kind: 'allow_once' },
  { optionId: 'allow-always', name: 'Allow always', kind: 'allow_always' },
  { optionId: 'reject-once', name: 'Reject', kind: 'reject_once' },
];

function setup(mode: 'default' | 'bypassPermissions' = 'default') {
  const events: AgentEvent[] = [];
  const written: any[] = [];
  const taken: unknown[] = [];
  const session = new AcpSession(CURSOR_ACP,
    { sessionId: 's', resume: false, cwd: '/work', model: 'default[]', effort: 'low', mode, autoAllow: [] },
    { event: (e) => void events.push(e), beforePrompt: (p) => void taken.push(p), afterTool: () => undefined, log: () => {} });
  session['proc'] = { stdin: { destroyed: false, write: (l: string) => void written.push(JSON.parse(l)) } } as never;
  session['sessionId'] = 'sess-1';
  const of = <T extends AgentEvent['type']>(type: T) => events.filter((e): e is Extract<AgentEvent, { type: T }> => e.type === type);
  const update = (u: Record<string, unknown>) => session.handle({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: 'sess-1', update: u } });
  return { session, events, written, taken, of, update };
}

test('one prompt at a time: what comes while a turn runs starts the next, and the hub sees it taken then', async () => {
  const { session, written, taken, of } = setup();
  session['guidance'] = 'Doublet guidance';
  session.send('first');
  assert.deepEqual(written[0].params.prompt.map((b: { text: string }) => b.text), ['Doublet guidance', 'first'], "a new session's guidance goes with its first prompt");
  session.send('second');
  assert.equal(written.length, 1, 'held while the turn runs');
  assert.deepEqual(taken, ['first']);
  session.handle({ jsonrpc: '2.0', id: written[0].id, result: { stopReason: 'end_turn' } });
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(of('turn_end').map((e) => [e.subtype, e.isError]), [['success', false]]);
  assert.equal(written[1].method, 'session/prompt');
  assert.deepEqual(written[1].params.prompt.map((b: { text: string }) => b.text), ['second'], 'guidance only once');
  assert.deepEqual(taken, ['first', 'second']);
  await session.interrupt();
  assert.deepEqual(written[2], { jsonrpc: '2.0', method: 'session/cancel', params: { sessionId: 'sess-1' } });
  session.handle({ jsonrpc: '2.0', id: written[1].id, result: { stopReason: 'cancelled' } });
  await new Promise((r) => setImmediate(r));
  assert.equal(of('turn_end')[1].subtype, 'interrupted');
});

test("an MCP call is shown once it's named, words before a tool call are one message, results end it", () => {
  const { of, update } = setup();
  update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'Checking the fleet. ' } });
  update({ sessionUpdate: 'tool_call', toolCallId: 't1', title: 'MCP: tool', kind: 'other', status: 'pending', rawInput: {} });
  assert.deepEqual(of('message').map((m) => m.text), ['Checking the fleet. '], 'not shown as "MCP: tool"');
  update({ sessionUpdate: 'tool_call_update', toolCallId: 't1', title: 'duet: fleet', rawInput: { providerIdentifier: 'duet', toolName: 'fleet', args: {} } });
  update({ sessionUpdate: 'tool_call_update', toolCallId: 't1', status: 'completed', content: [{ type: 'content', content: { type: 'text', text: 'qwen: idle' } }] });
  update({ sessionUpdate: 'tool_call', toolCallId: 't2', title: 'ls', kind: 'execute', status: 'completed', rawInput: { command: 'ls' }, rawOutput: 'a.txt' });
  assert.deepEqual(of('message').flatMap((m) => m.toolUses.map((u) => [u.name, u.input])), [['mcp__duet__fleet', {}], ['Bash', { command: 'ls' }]]);
  assert.deepEqual(of('tool_end').map((e) => [e.toolUseId, e.output]), [['t1', 'qwen: idle'], ['t2', 'a.txt']]);
});

test('permissions: a card for anything that changes things, none for reads or Doublet\'s tools, or in Bypass', () => {
  const { session, written, of } = setup();
  const ask = (id: number, toolCall: Record<string, unknown>) => session.handle({ jsonrpc: '2.0', id, method: 'session/request_permission', params: { sessionId: 'sess-1', toolCall, options: OPTIONS } });
  ask(1, { toolCallId: 'r', title: 'Read a.txt', kind: 'read' });
  ask(2, { toolCallId: 'd', title: 'duet-fleet: fleet', kind: 'other' });
  ask(3, { toolCallId: 'x', title: 'rm -rf build', kind: 'execute', rawInput: { command: 'rm -rf build' } });
  ask(4, { toolCallId: 'y', title: 'touch z', kind: 'execute', rawInput: { command: 'touch z' } });
  ask(5, { toolCallId: 'z', title: 'edit', kind: 'edit' });
  assert.deepEqual(written.slice(0, 2).map((w) => [w.id, w.result.outcome.optionId]), [[1, 'allow-once'], [2, 'allow-once']]);
  const [rm, touch, edit] = of('approval');
  assert.deepEqual([rm.tool, rm.input.command], ['Bash', 'rm -rf build']);
  rm.respond({ allow: true, input: rm.input });
  touch.respond({ allow: false, message: 'no' });
  edit.respond({ allow: false, message: 'Interrupted', interrupt: true });
  assert.deepEqual(written.slice(2).map((w) => [w.id, w.result.outcome]), [[3, { outcome: 'selected', optionId: 'allow-once' }], [4, { outcome: 'selected', optionId: 'reject-once' }], [5, { outcome: 'cancelled' }]]);

  const bypass = setup('bypassPermissions');
  bypass.session.handle({ jsonrpc: '2.0', id: 9, method: 'session/request_permission', params: { toolCall: { toolCallId: 'q', kind: 'execute' }, options: OPTIONS } });
  assert.equal(bypass.written[0].result.outcome.optionId, 'allow-once');
  assert.equal(bypass.of('approval').length, 0);

  written.length = 0;
  session.handle({ jsonrpc: '2.0', id: 10, method: 'cursor/ask_question', params: {} });
  assert.equal(written[0].error.code, -32601, 'answered, so the agent never waits for ever');
});

test('what session/load replays is not shown again; Doublet\'s plan mode is Cursor\'s plan mode', () => {
  const { session, events, update } = setup();
  session['loading'] = true;
  update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'old words' } });
  session['loading'] = false;
  assert.equal(events.length, 0);
  assert.equal(CURSOR_ACP.mode('plan'), 'plan');
  assert.equal(CURSOR_ACP.mode('acceptEdits'), 'agent');
  session['mode'] = 'plan';
  update({ sessionUpdate: 'current_mode_update', currentModeId: 'agent' });
  assert.deepEqual(events.at(-1), { type: 'mode', mode: 'default' }, 'leaving plan mode is followed');
});
