// Phase 3 check.
//  1. Budget and loop guards (no models): the 13th agent message is refused; results still arrive;
//     your own messages are free and reset the budget; the lead's Stop hook blocks at most 7 times a turn.
//  2. Scripted scenario, no human input: the lead (Max) delegates to the 27B; the worker asks a question;
//     the lead answers mid-turn; the worker reports; the lead reviews — all in one lead turn.
//  3. Cancel cleans up: an open question is closed, nothing is left queued for the lead, llmd is idle.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { BUDGET_PER_USER_MESSAGE, Dialogue, LEAD, MAX_STOP_BLOCKS, workerOutput } from '../src/dialogue.ts';
import type { EventBody } from '../src/protocol.ts';
import { createHarness } from './harness.ts';

test('budget: the 13th agent message is refused, results still arrive, user messages are free and reset it', () => {
  const emitted: EventBody[] = [];
  const d = new Dialogue((e) => emitted.push(e));
  const tasks = new Map<string, { worker: string; state: string; by: string }>([['t-1', { worker: 'qwen-27b', state: 'running', by: LEAD }]]);
  d.attach(
    { delegate: () => 't-x', cancel: () => {}, taskInfo: (id) => tasks.get(id), activeTasks: () => ['t-1'], describe: () => '', idleLocal: () => [] },
    { busy: () => true, submit: () => {}, conversation: () => undefined },
  );
  for (let i = 1; i <= BUDGET_PER_USER_MESSAGE; i++) assert.equal(d.steer(LEAD, 't-1', `steer ${i}`), null, `message ${i} allowed`);
  assert.match(d.steer(LEAD, 't-1', 'one too many') ?? '', /budget used up/, '13th refused');
  const refusedCard = emitted.filter((e) => e.type === 'dialogue').at(-1) as Extract<EventBody, { type: 'dialogue' }>;
  assert.ok(refusedCard.refused, 'the refusal is visible as a card');
  assert.equal(d.steer('mac', 't-1', 'from the user'), null, 'your own messages are not budgeted');
  d.onTaskEnd('t-1', 'qwen-27b', 'done', 'all good', 'no changes');
  assert.ok(emitted.some((e) => e.type === 'dialogue' && e.kind === 'RESULT' && !e.refused), 'RESULT delivered past the budget');
  d.onUserMessage();
  tasks.set('t-2', { worker: 'qwen-9b', state: 'running', by: LEAD });
  assert.equal(d.steer(LEAD, 't-2', 'fresh budget'), null, 'a new user message resets the budget');
});

test('loop guard: the lead Stop hook blocks at most 7 times per turn, then lets the turn end', async () => {
  const d = new Dialogue(() => {});
  d.attach({ delegate: () => 't', cancel: () => {}, taskInfo: () => undefined, activeTasks: () => ['t-1'], describe: () => '', idleLocal: () => [] }, { busy: () => true, submit: () => {}, conversation: () => undefined });
  const stop = d.leadHooks().Stop![0].hooks[0];
  const input = { hook_event_name: 'Stop', stop_hook_active: false, session_id: 's', transcript_path: '', cwd: '' } as never;
  const decisions = [];
  for (let i = 0; i < 9; i++) decisions.push(((await stop(input, undefined, { signal: new AbortController().signal })) as { decision?: string }).decision ?? 'allow');
  assert.equal(decisions.filter((x) => x === 'block').length, MAX_STOP_BLOCKS);
  assert.equal(decisions.at(-1), 'allow');
  d.onLeadTurnStart();
  assert.equal(((await stop(input, undefined, { signal: new AbortController().signal })) as { decision?: string }).decision, 'block', 'counter resets each turn');
});

// ---- live scenario on the hub machine ----
test("a RESULT carries what the worker wrote when its report only summarizes", () => {
  const emitted: EventBody[] = [];
  const d = new Dialogue((e) => emitted.push(e));
  const tasks = new Map<string, { worker: string; state: string; by: string }>();
  d.attach(
    { delegate: () => 't-x', cancel: () => {}, taskInfo: (id) => tasks.get(id), activeTasks: () => [], describe: () => '', idleLocal: () => [] },
    { busy: () => true, submit: () => {}, conversation: () => undefined },
  );
  const result = () => (emitted.filter((e) => e.type === 'dialogue' && e.kind === 'RESULT').at(-1) as Extract<EventBody, { type: 'dialogue' }>).text;
  tasks.set('t-1', { worker: 'qwen-9b', state: 'running', by: LEAD });
  d.onTaskEnd('t-1', 'qwen-9b', 'done', 'Wrote the poem.', 'no changes', 'Here it is:\nSilicon hums in the dark');
  assert.match(result(), /Worker's output:\nHere it is:\nSilicon hums in the dark\nHub-measured changes/);
  tasks.set('t-2', { worker: 'qwen-9b', state: 'running', by: LEAD });
  d.onTaskEnd('t-2', 'qwen-9b', 'done', 'Silicon hums in the dark', 'no changes', 'Silicon hums in the dark');
  assert.doesNotMatch(result(), /Worker's output/, 'not repeated when the summary already has it');
  tasks.set('t-4', { worker: 'qwen-9b', state: 'running', by: LEAD });
  const poem = 'Green ghost in a plastic cage,\nDual fans spin through silent rage,\nVRAM eats my desktop dreams,\nBut 5K displays keep their screens.';
  d.onTaskEnd('t-4', 'qwen-9b', 'done', 'ok', 'no changes', `Done. Here is the poem:\n\n${poem.split('\n').map((l) => `**${l}**`).join('\n')}`);
  assert.match(result(), /Worker's output/, 'a description of the poem is not the poem');
  const bold = `Done. Here is the poem:\n\n${poem.split('\n').map((l) => `**${l}**`).join('\n')}`;
  assert.equal(workerOutput(bold, `Four-line poem:\n\n${poem}`), '', 'the same poem in bold, with a line around it, is not repeated');
  tasks.set('t-3', { worker: 'qwen-9b', state: 'running', by: LEAD });
  d.onTaskEnd('t-3', 'qwen-9b', 'done', 'ok', 'no changes', `${'x'.repeat(5000)}THE-END`);
  assert.match(result(), /earlier output trimmed[\s\S]*THE-END/, 'long output keeps its end');
  assert.ok(result().length < 4300, 'and stays bounded');
});

const h = createHarness('p3');
const { client, next, all } = h;
after(() => h.cleanup());
const git = (cwd: string, ...args: string[]) => execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf8' });

test('scripted dialogue: delegate → question → answer mid-turn → result → review, with no human input', async () => {
  const repo = h.projectDir;
  git(repo, 'init', '-q');
  writeFileSync(join(repo, 'greet.txt'), 'hello world\n');
  git(repo, 'add', '.');
  git(repo, '-c', 'user.email=t@x', '-c', 'user.name=t', 'commit', '-qm', 'init');

  await h.startHub();
  await client.connect();
  await next('session', (e) => e.state === 'ready');
  const workerTask = `In ${repo}, greet.txt says "hello world". Replace the word "world" with a different word. You do not know which word: you MUST first call mcp__duet__ask_lead to ask which word to use, and use exactly the word in the answer. Then make the edit, run git diff --stat, and finish with mcp__duet__report kind "final".`;
  const prompt = [
    'Use only the mcp__duet tools for this; do not use any other tool.',
    '1. Call mcp__duet__plan with two steps: id "1", text "Replace the word", owner "qwen-27b", status "pending"; and id "2", text "Review the result", owner "lead", status "pending".',
    `2. Call mcp__duet__delegate with worker "qwen-27b", step "1", profile "implement", cwd "${repo}", and this exact task: ${JSON.stringify(workerTask)}`,
    '3. Call mcp__duet__await_workers to wait. When the worker asks which word to use, call mcp__duet__answer with exactly: duet',
    '4. Keep calling mcp__duet__await_workers until the RESULT arrives.',
    '5. Review the RESULT (check the hub-measured changes), call mcp__duet__plan with both steps completed, then reply with REVIEWED followed by a one-line verdict.',
  ].join('\n');
  const t0 = Date.now();
  await client.send({ type: 'prompt', text: prompt });
  const turn = (await next('user', (e) => e.text === prompt)).turn;
  // Fail fast if the lead tries a tool that would need a human (and leave no timer behind).
  let onEvent: ((e: { type: string; turn?: number; tool?: string }) => void) | undefined;
  const approval = new Promise<never>((_, reject) => {
    onEvent = (e) => { if (e.type === 'approval_request' && e.turn === turn) reject(new Error(`lead asked for approval of ${e.tool}`)); };
    client.on('event', onEvent);
  });
  const end = await Promise.race([next('turn_end', (e) => e.turn === turn, 0, 600_000), approval]).finally(() => client.off('event', onEvent!));
  assert.equal(end.subtype, 'success');

  const cards = all('dialogue');
  const task = cards.find((c) => c.kind === 'TASK' && c.from === 'lead');
  assert.ok(task, 'lead delegated');
  const thread = cards.filter((c) => c.taskId === task.taskId);
  const q = thread.find((c) => c.kind === 'QUESTION');
  const a = thread.find((c) => c.kind === 'ANSWER');
  const r = thread.find((c) => c.kind === 'RESULT');
  assert.ok(q && q.from === 'qwen-27b' && q.to === 'lead', 'worker asked the lead');
  assert.ok(a && a.from === 'lead' && a.replyTo === q.id && /duet/i.test(a.text), 'lead answered that question');
  assert.ok(r && r.to === 'lead', 'result went to the lead');
  assert.ok(q.seq < a.seq && a.seq < r.seq && r.seq < end.seq, 'question, answer and result all happened inside the one lead turn');
  assert.ok(thread.every((c) => !c.refused), 'nothing hit the budget');
  assert.equal(readFileSync(join(repo, 'greet.txt'), 'utf8').trim(), 'hello duet', 'the worker used the answer');
  const progress = all('task_progress', (e) => e.taskId === task.taskId);
  assert.ok(progress.every((p) => !(p.tools ?? []).some((x) => x.startsWith('mcp__duet__'))), 'the duet tools show as cards, not tool lines');
  assert.ok(progress.some((p) => p.toolUses?.some((u) => u.name === 'Edit' || u.name === 'Write' || u.name === 'Bash')), 'tool calls arrive structured');
  assert.ok(progress.every((p) => !p.toolResult?.startsWith('[{')), 'tool results arrive as text');
  const final = all('assistant', (e) => e.turn === turn).map((e) => e.text).join('\n');
  assert.match(final, /REVIEWED/, 'the lead reviewed the result');
  assert.equal(all('approval_request', (e) => e.turn === turn).length, 0, 'no human input was needed');
  const plans = all('plan');
  assert.ok(plans.some((p) => p.steps.find((s) => s.id === '1')?.taskId === task.taskId), 'the task joined its plan step');
  assert.ok(plans.at(-1)?.steps.every((s) => s.status === 'completed'), 'the plan ended up to date');
  assert.equal(all('task', (e) => e.taskId === task.taskId && e.state === 'queued').at(0)?.profile, 'implement');
  console.log(`  scenario: ${((Date.now() - t0) / 1000).toFixed(1)} s, ${thread.length} cards (${thread.map((c) => c.kind).join(' → ')}), lead: ${final.split('\n').pop()?.slice(0, 120)}`);
});

test('cancel cleans up: open question closed, nothing waiting, llmd idle', async () => {
  const d = h.projectDir;
  const ack = await client.send({ type: 'delegate', worker: 'qwen-27b', prompt: 'Before doing anything else, call mcp__duet__ask_lead to ask whether to write the README in English or French. Wait for the answer.', cwd: d });
  const taskId = ack.taskId!;
  const q = await next('dialogue', (e) => e.taskId === taskId && e.kind === 'QUESTION', 0, 180_000);
  assert.equal(q.to, 'test', 'a task you delegated asks you, not the lead');
  type Health = { dialogue: { openQuestions: number; leadInbox: number; threads: number } };
  let health = await (await fetch(`http://127.0.0.1:${h.port}/health`)).json() as Health;
  assert.equal(health.dialogue.openQuestions, 1);
  await client.send({ type: 'cancel_task', taskId });
  const end = await next('task', (e) => e.taskId === taskId && ['done', 'failed', 'cancelled'].includes(e.state), 0, 30_000);
  assert.equal(end.state, 'cancelled');
  assert.ok(all('dialogue', (e) => e.taskId === taskId && e.kind === 'CANCEL').length === 1, 'CANCEL card');
  await assert.rejects(client.send({ type: 'answer', questionId: q.id, text: 'English' }), /no open question/, 'the question is closed');
  health = await (await fetch(`http://127.0.0.1:${h.port}/health`)).json() as Health;
  assert.deepEqual([health.dialogue.openQuestions, health.dialogue.leadInbox, health.dialogue.threads], [0, 0, 0], 'no dialogue state left');
  await new Promise((r) => setTimeout(r, 1500));
  const st = await (await fetch('http://127.0.0.1:8801/admin/v1/status')).json() as { backends: { served_id: string; inflight: number }[] };
  assert.equal(st.backends.find((b) => b.served_id === 'qwen3.8-27b')?.inflight, 0, '27B idle');
});
