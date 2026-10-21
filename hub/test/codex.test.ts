// The Codex adapter without Codex: app-server's messages fed in by hand, and what the session writes back read off a
// fake stdin. Its items become the hub's tool calls and results, approvals become cards and their answers decisions,
// every request Codex makes is answered, and prompts steer a running turn or start the next.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { CodexSession, codexPolicy } from '../src/agents/codex.ts';
import type { AgentEvent } from '../src/agents/adapter.ts';

function setup() {
  const events: AgentEvent[] = [];
  const written: any[] = [];
  const prompts: unknown[] = [];
  const session = new CodexSession(
    { sessionId: 'hub-id', resume: false, cwd: '/work', model: 'gpt-6-luna', effort: 'low', mode: 'default', autoAllow: [] },
    { event: (e) => void events.push(e), beforePrompt: (p) => (prompts.push(p), prompts.length === 1 ? '[duet] moved to /work' : undefined), afterTool: () => undefined, log: () => {} },
  );
  session['proc'] = { stdin: { destroyed: false, write: (l: string) => void written.push(JSON.parse(l)) } } as never;
  session['threadId'] = 'th-1';
  const of = <T extends AgentEvent['type']>(type: T) => events.filter((e): e is Extract<AgentEvent, { type: T }> => e.type === type);
  return { session, events, written, prompts, of };
}

test("Codex's items become tool calls, results and messages, in order", () => {
  const { session, events, of } = setup();
  session.handle({ method: 'turn/started', params: { threadId: 'th-1', turn: { id: 'turn-1' } } });
  session.handle({ method: 'item/agentMessage/delta', params: { itemId: 'm1', delta: 'Running ' } });
  session.handle({ method: 'item/started', params: { item: { type: 'commandExecution', id: 'c1', command: 'swift test', cwd: '/work', status: 'inProgress' } } });
  session.handle({ method: 'item/completed', params: { item: { type: 'commandExecution', id: 'c1', command: 'swift test', status: 'completed', exitCode: 1, aggregatedOutput: '1 test failed' } } });
  session.handle({ method: 'item/completed', params: { item: { type: 'mcpToolCall', id: 'x1', server: 'duet', tool: 'fleet', status: 'completed', result: { content: [{ type: 'text', text: 'qwen: idle' }] }, error: null } } });
  session.handle({ method: 'item/completed', params: { item: { type: 'agentMessage', id: 'm1', text: '' } } });
  session.handle({ method: 'turn/completed', params: { threadId: 'th-1', turn: { id: 'turn-1', status: 'completed', error: null, durationMs: 900 } } });
  assert.deepEqual(of('text').map((e) => e.delta), ['Running ']);
  assert.deepEqual(of('message').map((e) => e.toolUses.map((u) => u.name)), [['Bash'], []]);
  assert.equal(of('message')[1].text, 'Running ', 'a message that ends without its text keeps what streamed');
  assert.deepEqual(of('tool_end').map((e) => [e.toolUseId, e.isError, e.output]), [['c1', true, '1 test failed'], ['x1', false, 'qwen: idle']]);
  const end = of('turn_end')[0];
  assert.deepEqual([end.subtype, end.isError, end.durationMs], ['success', false, 900]);
  assert.equal(events[0].type, 'activity', 'a turn Codex starts opens one in the hub');
  assert.equal(session['turnId'], null);
});

test('approvals become cards; their answers go back as decisions; anything else is still answered', () => {
  const { session, written, of } = setup();
  session.handle({ method: 'item/started', params: { item: { type: 'fileChange', id: 'f1', status: 'inProgress', changes: [{ path: 'a.swift', kind: { type: 'update' }, diff: '-a\n+b' }] } } });
  session.handle({ id: 7, method: 'item/commandExecution/requestApproval', params: { itemId: 'c2', command: 'rm -rf build', cwd: '/work', reason: 'clean' } });
  session.handle({ id: 8, method: 'item/fileChange/requestApproval', params: { itemId: 'f1' } });
  session.handle({ id: 9, method: 'item/commandExecution/requestApproval', params: { itemId: 'c3', command: 'ls' } });
  const [bash, edit, again] = of('approval');
  assert.deepEqual([bash.tool, bash.input, bash.description], ['Bash', { command: 'rm -rf build', cwd: '/work' }, 'clean']);
  assert.deepEqual(edit.input, { changes: [{ path: 'a.swift', kind: { type: 'update' }, diff: '-a\n+b' }] }, "the file change's diff, from its item");
  bash.respond({ allow: true, input: bash.input });
  edit.respond({ allow: false, message: 'no' });
  again.respond({ allow: false, message: 'Interrupted', interrupt: true });
  bash.respond({ allow: false, message: 'twice' });
  assert.deepEqual(written.filter((w) => w.result).map((w) => [w.id, w.result.decision]), [[7, 'accept'], [8, 'decline'], [9, 'cancel']], 'each answered once');
  // A rejection with a note tells Codex the note.
  assert.match(written.find((w) => w.method === 'turn/start')?.params.input[0].text ?? '', /rejected that call: no/);

  written.length = 0;
  session.handle({ id: 10, method: 'mcpServer/elicitation/request', params: {} });
  session.handle({ id: 11, method: 'attestation/generate', params: {} });
  assert.equal(written[0].result.action, 'decline');
  assert.equal(written[1].error.code, -32601);
});

test('a prompt steers the running turn, else starts one; the hub\'s extra context goes with it', async () => {
  const { session, written, prompts } = setup();
  session.send('first');
  await new Promise((r) => setImmediate(r));
  assert.equal(written[0].method, 'turn/start');
  assert.deepEqual(written[0].params.input.map((i: { text: string }) => i.text), ['first', '[duet] moved to /work']);
  assert.equal(written[0].params.approvalPolicy, 'untrusted');
  session.handle({ id: written[0].id, result: { turn: { id: 'turn-2' } } });
  await new Promise((r) => setImmediate(r));

  session.send('also this');
  await new Promise((r) => setImmediate(r));
  assert.deepEqual([written[1].method, written[1].params.expectedTurnId], ['turn/steer', 'turn-2']);
  // The turn ended just before: the steer is refused, and the prompt starts the next turn instead.
  session.handle({ id: written[1].id, error: { code: -32000, message: 'no active turn' } });
  await new Promise((r) => setImmediate(r));
  assert.equal(written[2].method, 'turn/start');
  assert.deepEqual(prompts, ['first', 'also this'], 'the hub sees each prompt taken, as with Claude Code');
});

test("Doublet's modes as Codex's policies", () => {
  assert.deepEqual([codexPolicy('default', '/w').approvalPolicy, codexPolicy('default', '/w').sandbox], ['untrusted', 'workspace-write']);
  assert.deepEqual([codexPolicy('plan', '/w').sandbox, codexPolicy('plan', '/w').sandboxPolicy.type], ['read-only', 'readOnly']);
  assert.equal(codexPolicy('acceptEdits', '/w').approvalPolicy, 'on-request');
  assert.deepEqual([codexPolicy('bypassPermissions', '/w').approvalPolicy, codexPolicy('bypassPermissions', '/w').sandbox], ['never', 'danger-full-access']);
});

test("Codex's plan and questions use Claude's cards; approving the plan leaves plan mode and starts the work", async () => {
  const { session, written, of } = setup();
  session['mode'] = 'plan';
  session.handle({ method: 'item/completed', params: { item: { type: 'plan', id: 'turn-1-plan', text: '## Add a README\n- write it' } } });
  const plan = of('approval')[0];
  assert.deepEqual([plan.tool, plan.input.plan], ['ExitPlanMode', '## Add a README\n- write it']);
  plan.respond({ allow: true, input: { plan: '## Add a README\n- write it, short' } });
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(of('mode').at(-1), { type: 'mode', mode: 'default' });
  const start = written.find((w) => w.method === 'turn/start');
  assert.match(start.params.input[0].text, /approved your plan, with their edits[\s\S]*write it, short/);
  assert.equal(start.params.collaborationMode.mode, 'default', 'out of plan mode');

  session.handle({ method: 'item/completed', params: { item: { type: 'agentMessage', id: 'm9', text: 'Which tone?', questions: [{ title: 'Which tone?', options: ['Friendly', 'Formal'] }] } } });
  const q = of('approval')[1];
  assert.deepEqual(q.input, { questions: [{ question: 'Which tone?', options: [{ label: 'Friendly' }, { label: 'Formal' }], multiSelect: false }] });
  q.respond({ allow: true, input: { ...q.input, answers: { 'Which tone?': 'Friendly' } } });
  await new Promise((r) => setImmediate(r));
  assert.ok(written.some((w) => w.method === 'turn/start' && /Which tone\? Friendly/.test(w.params.input[0].text)), 'the answers go to Codex as the next message');

  // A blocking question (requestUserInput) is answered in place, by option label.
  session.handle({ id: 20, method: 'item/tool/requestUserInput', params: { itemId: 'u1', questions: [{ id: 'q', header: 'Tone', question: 'Tone?', isOther: false, isSecret: false, options: [{ label: 'Friendly', description: '' }] }], isBlocking: true } });
  of('approval')[2].respond({ allow: true, input: { answers: { 'Tone?': 'Friendly' } } });
  assert.deepEqual(written.find((w) => w.id === 20)?.result, { answers: { q: { answers: ['Friendly'] } } });
});

test('an edited command is refused, and Codex is told what to run instead; reject uses a decision Codex offers', async () => {
  const { session, written, of } = setup();
  session.handle({ id: 30, method: 'item/commandExecution/requestApproval', params: { itemId: 'c', command: 'rm -rf build', availableDecisions: ['accept', 'cancel'] } });
  of('approval')[0].respond({ allow: true, input: { command: 'rm -rf build/tmp' } });
  await new Promise((r) => setImmediate(r));
  assert.equal(written.find((w) => w.id === 30)?.result.decision, 'cancel', 'decline is not on offer here');
  assert.match(written.find((w) => w.method === 'turn/start')?.params.input[0].text, /Run this instead: rm -rf build\/tmp/);
});

test('a compaction is reported once, whichever way Codex says it', () => {
  const { session, of } = setup();
  session.handle({ method: 'item/completed', params: { item: { type: 'contextCompaction', id: 'cc1' } } });
  session.handle({ method: 'thread/compacted', params: { threadId: 'th-1' } });
  assert.equal(of('compacted').length, 1);
  session.handle({ method: 'thread/compacted', params: { threadId: 'th-1' } });
  assert.equal(of('compacted').length, 2, 'an older version says it only here');
});

test("Codex's own subagents are workers, from spawn to their end", () => {
  const started: string[] = [];
  const ended: [string, string][] = [];
  const { session } = setup();
  session['host'].subagents = { start: (id: string, kind: string) => void started.push(`${id}:${kind}`), end: (id: string, st: string) => void ended.push([id, st]), progress: () => {}, isSubagent: () => true, background: () => {}, stopped: () => {} } as never;
  const call = (status: string, states: Record<string, unknown>) => ({ type: 'collabAgentToolCall', id: 'k1', tool: 'spawnAgent', status, senderThreadId: 'th-1', receiverThreadIds: ['ag-1'], prompt: 'Find every use of Token.text', model: 'gpt-6-luna', agentsStates: states });
  session.handle({ method: 'item/started', params: { item: call('inProgress', {}) } });
  session.handle({ method: 'item/completed', params: { item: call('completed', { 'ag-1': { status: 'running', message: null } }) } });
  assert.deepEqual(started, ['ag-1:gpt-6-luna'], 'started once');
  session.handle({ method: 'item/completed', params: { item: { type: 'collabAgentToolCall', id: 'k2', tool: 'wait', status: 'completed', receiverThreadIds: ['ag-1'], agentsStates: { 'ag-1': { status: 'completed', message: '4 files' } } } } });
  assert.deepEqual(ended, [['ag-1', 'done']]);
});

test('a plan approved while its turn still runs starts the work in a turn of its own, out of plan mode', async () => {
  const { session, written, of } = setup();
  session['mode'] = 'plan';
  session['turnId'] = 'turn-plan';
  session.handle({ method: 'item/completed', params: { item: { type: 'plan', id: 'p', text: '## Plan' } } });
  of('approval')[0].respond({ allow: true, input: { plan: '## Plan' } });
  await new Promise((r) => setImmediate(r));
  assert.equal(written.filter((w) => w.method === 'turn/steer' || w.method === 'turn/start').length, 0, 'not steered into the read-only turn');
  session.handle({ method: 'turn/completed', params: { threadId: 'th-1', turn: { id: 'turn-plan', status: 'completed', error: null, durationMs: 1 } } });
  await new Promise((r) => setImmediate(r));
  const start = written.find((w) => w.method === 'turn/start');
  assert.equal(start?.params.collaborationMode.mode, 'default');
  assert.match(start?.params.input[0].text, /approved your plan/);
});
