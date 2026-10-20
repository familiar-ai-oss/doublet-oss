// How the lead hands work out and hears back, without models:
//  1. Claude's own subagents never get the lead's worker messages, notes or duet tools (hooks fire inside them too).
//  2. Routing: local workers first (an Agent call is turned away while one is idle), auto by task size, one task at a
//     time per worker, and task profiles (tools, read-only guard, instructions).
//  3. Questions: Claude answers, or passes one on to you; a task waiting only on you doesn't keep Claude's turn going.
//  4. The plan: required before any handoff, each task joined to its step, kept current, and shown at every prompt.
//  5. Briefs a worker can carry out: the lead is told what the guard turns away, `files` outside cwd are readable (or
//     refused at delegate), a blocked worker is told to say so, and the RESULT shows the tools it really used.
import { test, mock } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Dialogue, LEAD, MAX_STOP_BLOCKS, YOU, formatPlan, leadGuidance, toolsLine, wrapTask, type FleetPort } from '../src/dialogue.ts';
import { Fleet, pickAuto, readableOutside, takes, type WorkerDef } from '../src/fleet.ts';
import { Lead } from '../src/lead.ts';
import { attachClaude } from './claude-session.ts';
import { describeProfiles, PROFILES, readOnlyRefusal } from '../src/profiles.ts';
import type { EventBody, PlanStep } from '../src/protocol.ts';
import { StateFile } from '../src/store.ts';
import { guard, ToolLog } from '../src/worker.ts';

type Card = Extract<EventBody, { type: 'dialogue' }>;
const of = <T extends EventBody['type']>(events: EventBody[], type: T) => events.filter((e): e is Extract<EventBody, { type: T }> => e.type === type);
const signal = () => ({ signal: new AbortController().signal });

/** A dialogue over a fake fleet: tasks start running on the worker they're given ("auto" is qwen-27b). */
function setup(conversation = 'conv-1') {
  const events: EventBody[] = [];
  const tasks = new Map<string, { worker: string; state: string; by: string; conversationId?: string; ahead?: string[] }>();
  const prompts = new Map<string, string>();
  const idle: { id: string; takes: 'any' | 'small' }[] = [];
  let n = 0;
  const fleet: FleetPort = {
    delegate: (worker, prompt, by) => {
      const id = `t-${++n}`;
      tasks.set(id, { worker: worker === 'auto' ? 'qwen-27b' : worker, state: 'running', by, conversationId: conversation });
      prompts.set(id, prompt);
      return id;
    },
    cancel: (id) => { tasks.get(id)!.state = 'cancelled'; },
    taskInfo: (id) => tasks.get(id),
    activeTasks: (by) => [...tasks].filter(([, t]) => t.by === by && ['queued', 'running', 'awaiting_swap'].includes(t.state)).map(([id]) => id),
    describe: () => '- qwen-27b: Qwen3.8 27B · R9700 — idle; any task',
    idleLocal: () => idle,
  };
  const submitted: string[] = [];
  let busy = true;
  const d = new Dialogue((e) => events.push(e));
  d.attach(fleet, { busy: () => busy, submit: (text) => submitted.push(text), conversation: () => conversation });
  const hooks = d.leadHooks();
  const call = async (event: 'PreToolUse' | 'PostToolUse' | 'Stop' | 'UserPromptSubmit', input: Record<string, unknown> = {}) =>
    (await hooks[event]![0].hooks[0]({ hook_event_name: event, session_id: 's', transcript_path: '', cwd: '', ...input } as never, undefined, signal())) as {
      decision?: string; reason?: string; hookSpecificOutput?: { permissionDecision?: string; permissionDecisionReason?: string; additionalContext?: string };
    };
  const end = (id: string, state = 'done', result = 'ok') => { tasks.get(id)!.state = state; d.onTaskEnd(id, tasks.get(id)!.worker, state, result, 'no changes'); };
  return { d, events, tasks, prompts, idle, submitted, call, end, setIdle: (b: boolean) => { busy = !b; } };
}

const steps = (...s: [string, string, string?][]) => s.map(([id, owner, status]) => ({ id, text: `step ${id}`, owner, status: (status ?? 'pending') as PlanStep['status'] }));

// ---- Apple's on-device workers: the user's, not Claude's ----

test("Claude doesn't hand work to Apple's on-device workers unless the user allows it; the user still can", () => {
  const { d, tasks } = setup();
  d.setPlan(LEAD, steps(['1', 'lead']));
  const r = d.delegate(LEAD, 'apple-ipad', 'Summarize the log');
  assert.match(r.refused ?? '', /apple-ipad is the user's on-device model.*local worker/);
  assert.equal(tasks.size, 0);
  assert.ok(d.delegate('ipad', 'apple-ipad', 'Summarize the log').taskId, 'the user, by @mention');
  d.appleForLead = true;
  assert.ok(d.delegate(LEAD, 'apple-ipad', 'Summarize the log').taskId, 'with DUET_APPLE_FOR_LEAD');
  assert.doesNotMatch(leadGuidance(false), /Use them for the gist/);
  assert.match(leadGuidance(false), /hand them to an idle local worker/);
  assert.match(leadGuidance(true), /apple-\* workers are Apple's on-device model.*8K on newer devices/);
});

test("the lead's fleet listing leaves out Apple workers unless the user allows them", () => {
  const apple = { info: () => ({ available: true, platform: 'ipad', contextSize: 8192 }), devices: () => [['ipad', { available: true, platform: 'ipad' }]], on: () => {} };
  const make = (appleForLead: boolean) => {
    const f = new Fleet({ workers: [], llmdAdmin: 'http://127.0.0.1:1', modelsToml: '/nonexistent', claimsAllDevices: [], defaultCwd: '/tmp', proxyBaseUrl: () => '', log: () => {}, apple: apple as never, appleForLead }, () => {});
    f.syncApple();
    return f.describe();
  };
  assert.doesNotMatch(make(false), /apple-ipad/);
  assert.match(make(true), /apple-ipad.*8192-token context/);
});

// ---- 1. Claude's subagents ----

test("a worker's message waits for Claude's own next tool call: a subagent's tool call doesn't take it", async () => {
  const { d, call, end } = setup();
  d.setPlan(LEAD, steps(['1', 'qwen-27b']));
  const { taskId } = d.delegate(LEAD, 'qwen-27b', 'Do it', { step: '1' });
  end(taskId!);
  const inSubagent = await call('PostToolUse', { tool_name: 'Grep', tool_input: {}, tool_response: '', tool_use_id: 'u1', agent_id: 'agent-1', agent_type: 'Explore' });
  assert.deepEqual(inSubagent, {}, 'nothing injected into the subagent');
  const claude = await call('PostToolUse', { tool_name: 'Read', tool_input: {}, tool_response: '', tool_use_id: 'u2' });
  assert.match(claude.hookSpecificOutput?.additionalContext ?? '', /\[RESULT task=t-1 from=qwen-27b\]\nFinished: ok/);
});

test("Claude's subagents can't use the duet tools; Claude can, and the subagents keep their own tools", async () => {
  const { call } = setup();
  const sub = { agent_id: 'agent-1', agent_type: 'general-purpose', tool_input: {}, tool_use_id: 'u1' };
  for (const tool of ['mcp__duet__await_workers', 'mcp__duet__delegate', 'mcp__duet__plan']) {
    const r = await call('PreToolUse', { ...sub, tool_name: tool });
    assert.equal(r.hookSpecificOutput?.permissionDecision, 'deny', `${tool} denied in a subagent`);
    assert.match(r.hookSpecificOutput?.permissionDecisionReason ?? '', /belong to the lead/);
  }
  assert.deepEqual(await call('PreToolUse', { ...sub, tool_name: 'Read' }), {});
  assert.deepEqual(await call('PreToolUse', { tool_name: 'mcp__duet__await_workers', tool_input: {}, tool_use_id: 'u2' }), {});
});

test("your notes go to Claude Code as your message, never a subagent's hook; an edited call's notice goes to whoever made it", async () => {
  const lead = new Lead({ model: 'haiku', effort: 'low', cwd: '/tmp', autoAllow: [], log: () => {} }, () => {}, new StateFile('/nonexistent'), 0);
  const sent: string[] = [];
  const claude = attachClaude(lead, (text) => void sent.push(text));
  lead['busy'] = true;
  lead.addNotes('ipad', { surface: { kind: 'file', path: '/tmp/a.ts' }, items: [{ id: 'n1', intent: 'comment', text: 'rename this' }] }, 'Note: rename this');
  assert.deepEqual(sent, ['Note: rename this'], 'Claude Code hands it to Claude itself, at its own next tool call');
  lead['edits'].set('u-sub', { tool: 'Bash', original: { command: 'ls' }, ran: { command: 'ls -la' } });
  const after = (input: Record<string, unknown>) => claude['afterTool']({ hook_event_name: 'PostToolUse', session_id: 's', transcript_path: '', cwd: '', tool_name: 'Bash', tool_input: {}, tool_response: '', ...input } as never, undefined, signal()) as Promise<{ hookSpecificOutput?: { additionalContext?: string } }>;
  const sub = await after({ tool_use_id: 'u-sub', agent_id: 'agent-1' });
  assert.match(sub.hookSpecificOutput?.additionalContext ?? '', /edited this Bash call/, 'the subagent hears its call was edited');
  assert.doesNotMatch(sub.hookSpecificOutput?.additionalContext ?? '', /rename this/, 'but not your note');
  assert.deepEqual(await after({ tool_use_id: 'u-lead' }), {});
});

// ---- 2. routing ----

test('an Agent call waits for a plan, then goes to an idle local worker unless it says why it needs Claude', async () => {
  const { d, call, idle } = setup();
  const agent = (prompt: string, kind = 'Explore', id = 'toolu_a') => call('PreToolUse', { tool_name: 'Agent', tool_input: { subagent_type: kind, prompt, description: 'find it' }, tool_use_id: id });
  assert.match((await agent('Find where effort is applied')).hookSpecificOutput?.permissionDecisionReason ?? '', /Set out your plan/);
  assert.equal(d.wasTurnedAway('toolu_a'), true, 'shown as a subagent that never ran');
  d.setPlan(LEAD, steps(['1', 'lead', 'in_progress']));
  // Every worker busy: Claude's subagent is the overflow.
  assert.deepEqual(await agent('Find where effort is applied', 'Explore', 'toolu_b'), {});
  idle.push({ id: 'qwen-9b', takes: 'small' }, { id: 'qwen-27b', takes: 'any' });
  const r = await agent('Find where effort is applied', 'Explore', 'toolu_c');
  assert.equal(r.hookSpecificOutput?.permissionDecision, 'deny');
  assert.match(r.hookSpecificOutput?.permissionDecisionReason ?? '', /qwen-9b \(small, mechanical tasks only\), qwen-27b \(any task\)/);
  assert.match(r.hookSpecificOutput?.permissionDecisionReason ?? '', /worker "qwen-27b", profile "explore"/, 'suggests the large worker and the matching profile');
  assert.match((await agent('Refactor it', 'general-purpose', 'toolu_d')).hookSpecificOutput?.permissionDecisionReason ?? '', /profile "general"/);
  assert.deepEqual(await agent('Needs Claude: it has to search the web. Find the changelog.', 'general-purpose', 'toolu_e'), {});
  assert.equal(d.wasTurnedAway('toolu_e'), false);
  d.setPaused(true);
  assert.deepEqual(await agent('Find it', 'Explore', 'toolu_f'), {}, 'handoffs paused: nothing to redirect to');
  d.onLeadTurnStart();
  assert.equal(d.wasTurnedAway('toolu_c'), false, 'kept for one turn');
});

test('auto: a large task never goes to a small model; a small one takes a small worker first', () => {
  const w = (id: string, model: string, x: Partial<{ running: unknown; queue: unknown[]; loaded: boolean; enabled: boolean; backend: WorkerDef['backend']; takes: WorkerDef['takes'] }> = {}) =>
    ({ id, model, backend: 'llmd' as WorkerDef['backend'], enabled: true, available: true, loaded: true, running: null as unknown, queue: [] as unknown[], ...x });
  assert.deepEqual([takes({ model: 'qwen3.8-27b' }), takes({ model: 'qwen3.5-9b-3060' }), takes({ model: 'hf.co/ornith-ai/Ornith-1.5-9B-GGUF:Q8_0' }), takes({ model: 'qwen3:30b-a3b' }), takes({ model: 'dsv4-flash' })],
    ['any', 'small', 'small', 'any', 'any']);
  assert.equal(takes({ model: 'qwen3.5-9b', takes: 'any' }), 'any', 'set in fleet.json, it wins');
  const big = w('qwen-27b', 'qwen3.8-27b');
  const small = w('qwen-9b', 'qwen3.5-9b-3060');
  assert.equal(pickAuto([big, small], 'large')?.id, 'qwen-27b');
  assert.equal(pickAuto([big, small], 'small')?.id, 'qwen-9b', 'keeps the large worker free');
  const busyBig = { ...big, running: {} };
  assert.equal(pickAuto([busyBig, small], 'large')?.id, 'qwen-27b', 'waits for the large model rather than going to the 9B');
  // Everyone busy: a small task waits for the small worker, even behind a longer queue, so large work never waits on it.
  const busySmall = { ...small, running: {} };
  assert.equal(pickAuto([busyBig, busySmall], 'small')?.id, 'qwen-9b', 'equal queues: the small worker');
  assert.equal(pickAuto([busyBig, { ...busySmall, queue: [1, 2, 3] }], 'small')?.id, 'qwen-9b', 'a longer small queue still wins');
  assert.equal(pickAuto([busyBig, { ...busySmall, queue: [1, 2] }, w('mac-9b', 'Ornith-1.5-9B', { running: {}, queue: [1] })], 'small')?.id, 'mac-9b', 'the shortest small queue');
  assert.equal(pickAuto([{ ...busyBig, queue: [1] }, w('qwen-30b', 'qwen3:30b-a3b', { running: {} })], 'small')?.id, 'qwen-30b', 'no small worker: the shortest queue');
  assert.equal(pickAuto([busyBig, { ...busySmall, queue: [1, 2] }], 'large')?.id, 'qwen-27b', 'a large task is unaffected');
  assert.equal(pickAuto([busyBig, small], 'small')?.id, 'qwen-9b', 'an idle small worker first');
  assert.equal(pickAuto([big, busySmall], 'small')?.id, 'qwen-27b', 'then any idle worker');
  assert.equal(pickAuto([w('gemma', 'gemma4-27b', { loaded: false }), small], 'large'), undefined, 'never one that needs a swap');
  assert.equal(pickAuto([w('apple-ipad', 'on-device', { backend: 'apple' }), w('off', 'qwen3.8-27b', { enabled: false })], 'small'), undefined);
});

test('the fleet: one task at a time per worker (the rest wait behind it), what each takes, and profiles checked', async () => {
  const llmd = http.createServer((_req, res) => res.end(JSON.stringify({ backends: [
    { served_id: 'qwen3.8-27b', state: 'READY', device: 'r9700' }, { served_id: 'qwen3.5-9b-3060', state: 'READY', device: 'rtx3060' },
  ] })));
  await new Promise<void>((r) => llmd.listen(0, '127.0.0.1', r));
  const admin = `http://127.0.0.1:${(llmd.address() as { port: number }).port}`;
  const def = (id: string, model: string): WorkerDef => ({ id, label: id, backend: 'llmd', url: 'http://127.0.0.1:1', model, table: 'ctk-onoff', enabled: true });
  const events: EventBody[] = [];
  const f = new Fleet({ workers: [def('qwen-27b', 'qwen3.8-27b'), def('qwen-9b', 'qwen3.5-9b-3060'), def('gemma', 'gemma4-27b')], llmdAdmin: admin, modelsToml: '/nonexistent', claimsAllDevices: [], defaultCwd: '/tmp', proxyBaseUrl: () => '', log: () => {} }, (e) => events.push(e));
  try {
    await f.refresh();
    assert.deepEqual(f.idleLocal(), [{ id: 'qwen-27b', takes: 'any' }, { id: 'qwen-9b', takes: 'small' }]);
    const text = f.describe();
    assert.match(text, /runs ONE task at a time/);
    assert.match(text, /- qwen-27b: .* — idle; any task;/);
    assert.match(text, /- qwen-9b: .* — idle; small, mechanical tasks only;/);
    assert.match(text, /- gemma: .* — not loaded \(delegating asks the user to approve a GPU swap/);
    // gemma's model isn't loaded, so nothing runs (no session starts): its tasks wait in its one queue.
    const first = f.delegate('gemma', 'One', 'lead', { profile: 'explore' });
    const second = f.delegate('gemma', 'Two', 'lead', { profile: 'review' });
    assert.deepEqual([f.taskInfo(first)?.state, f.taskInfo(first)?.ahead], ['awaiting_swap', []]);
    assert.deepEqual([f.taskInfo(second)?.state, f.taskInfo(second)?.ahead], ['queued', [first]]);
    assert.equal(of(events, 'task').find((e) => e.taskId === second)?.profile, 'review');
    // A question the hub puts to a worker itself (a note) is queued like any task, even when nobody asks for its id.
    void f.ask('gemma', 'Four', 'hub', { profile: 'explore' });
    assert.deepEqual([of(events, 'task').at(-1)?.prompt, of(events, 'task').at(-1)?.state], ['Four', 'queued']);
    assert.match(f.describe(), /- gemma: .* — not loaded/);
    assert.throws(() => f.delegate('gemma', 'Three', 'lead', { profile: 'bogus' as never }), /unknown profile bogus/);
    // With the 27B off, a large task has nowhere to go: auto says why, worker by worker, and what to do instead. It never
    // blames a busy worker (gemma is busy with queued tasks, but it's out because its model isn't loaded).
    f.setWorker('qwen-27b', { enabled: false });
    assert.throws(() => f.delegate('auto', 'Big job', 'lead'), (e: Error) => e.message ===
      'auto found no local worker for this large task (a busy one would just have queued it): qwen-27b is switched off; ' +
      "qwen-9b takes small, mechanical tasks only; gemma's model isn't loaded. " +
      'Pass size "small" if the task is short and mechanical. Name gemma to ask the user to load its model.');
    f.setWorker('qwen-9b', { enabled: false });
    assert.throws(() => f.delegate('auto', 'Small job', 'lead', { size: 'small' }), (e: Error) => e.message ===
      "auto found no local worker for this small task (a busy one would just have queued it): qwen-27b is switched off; qwen-9b is switched off; gemma's model isn't loaded. Name gemma to ask the user to load its model.");
  } finally {
    f.stop();
    llmd.close();
  }
});

test("profiles: each sets the worker's tools and turns; read-only ones can't write, even through Bash", async () => {
  assert.deepEqual(PROFILES.explore.tools, ['Read', 'Glob', 'Grep']);
  assert.ok(PROFILES.review.readOnly && PROFILES.explore.readOnly && !PROFILES.implement.readOnly);
  for (const ok of ['git diff', 'git log --oneline -5', 'grep -rn foo src', 'ls -la', 'npm test 2>&1', 'npm test > /dev/null', 'cat a.txt | wc -l']) assert.equal(readOnlyRefusal(ok), null, ok);
  for (const bad of ['echo x > a.txt', 'cat a >> b', 'rm -rf build', "sed -i 's/a/b/' f.ts", 'git checkout main', 'git stash', 'npm install lodash', 'ls | tee out.txt', 'mv a b']) assert.ok(readOnlyRefusal(bad), bad);
  const pre = async (hooks: ReturnType<typeof guard>, tool: string, input: Record<string, unknown>) =>
    ((await hooks[0].hooks[0]({ hook_event_name: 'PreToolUse', session_id: 's', transcript_path: '', cwd: '/tmp', tool_name: tool, tool_input: input, tool_use_id: 'u' } as never, undefined, signal())) as { hookSpecificOutput?: { permissionDecision?: string } }).hookSpecificOutput?.permissionDecision ?? 'allow';
  const ro = guard('/tmp/project', true);
  assert.equal(await pre(ro, 'Bash', { command: 'git diff --stat' }), 'allow');
  assert.equal(await pre(ro, 'Bash', { command: 'echo hi > notes.txt' }), 'deny');
  assert.equal(await pre(ro, 'Edit', { file_path: '/tmp/project/a.ts' }), 'deny');
  assert.equal(await pre(guard('/tmp/project'), 'Edit', { file_path: '/tmp/project/a.ts' }), 'allow', 'an implement task edits');
  const brief = wrapTask('Add a test for pickAuto.', 'test', 'npm test passes');
  assert.match(brief, /Add a test for pickAuto\.\n\nDone when: npm test passes\n\n---\nYou are a Doublet worker\. Task profile: test\. Follow the project's test style/);
  assert.match(brief, /must give the tests you added or changed.*Say whether "done when" holds/s);
  assert.match(wrapTask('Where is X?', 'explore'), /Task profile: explore \(read-only\)\. Search with Grep and Glob/);
  assert.doesNotMatch(wrapTask('Where is X?', 'explore'), /Done when/);
});

// ---- briefs a worker can carry out ----

test("the lead is told each profile's tools and what the guard turns away; a worker is told to say when it's blocked", () => {
  const profiles = describeProfiles();
  assert.match(profiles, /"explore" \(Read, Glob, Grep; no shell; read-only\): find and read code/);
  assert.match(profiles, /"review" \(Read, Glob, Grep, Bash; read-only\): review code/);
  assert.match(profiles, /"implement" \(Read, Edit, Write, Bash, Glob, Grep\): make a specified code change/);
  for (const apple of [false, true]) {
    const g = leadGuidance(apple);
    assert.match(g, /What workers can't do: commit, push, use the network \(curl, wget, ssh, rsync\) or sudo; and their file tools can't leave the task's cwd, except to read files you pass in `files`\./);
    assert.match(g, /The explore, research and docs profiles have no shell, so they can't run commands: a task that runs commands needs review \(read-only\) or general\./);
    assert.match(g, /commit yourself after you review/);
  }
  const explore = wrapTask('Run git log in ../bench and paste the output.', 'explore');
  assert.match(explore, /Your tools: Read, Glob, Grep\. You have no shell, so you cannot run commands\. The hub turns away commits, pushes, the network, sudo, and file tools outside your folder/);
  assert.match(explore, /When a tool is refused or a command can't run, don't work around it with guesses: report outcome "blocked" and name the tool and the command or path it refused\. Never write output a tool didn't return/);
  const general = wrapTask('Fix the bug.', 'general');
  assert.match(general, /Your tools: Read, Edit, Write, Bash, Glob, Grep\. The hub turns away/);
  assert.doesNotMatch(general, /no shell/);
  assert.match(general, /report outcome "blocked"/, 'every profile gets the rule');
});

test('files outside the task folder: readable (only read) when they exist, refused at delegate by name when they do not', async () => {
  const root = mkdtempSync(join(tmpdir(), 'duet-files-'));
  const project = join(root, 'project');
  const bench = join(root, 'bench');
  mkdirSync(project);
  mkdirSync(bench);
  writeFileSync(join(project, 'a.ts'), 'x');
  writeFileSync(join(bench, 'tally.txt'), '20 4 13 7');
  const llmd = http.createServer((_req, res) => res.end(JSON.stringify({ backends: [] })));
  await new Promise<void>((r) => llmd.listen(0, '127.0.0.1', r));
  const admin = `http://127.0.0.1:${(llmd.address() as { port: number }).port}`;
  const events: EventBody[] = [];
  const handedOut = () => of(events, 'task').filter((e) => e.prompt !== undefined);
  // gemma's model isn't loaded, so its tasks only queue: nothing runs.
  const f = new Fleet({ workers: [{ id: 'gemma', label: 'gemma', backend: 'llmd', url: 'http://127.0.0.1:1', model: 'gemma4-27b', table: 'ctk-onoff', enabled: true }], llmdAdmin: admin, modelsToml: '/nonexistent', claimsAllDevices: [], defaultCwd: project, proxyBaseUrl: () => '', log: () => {} }, (e) => events.push(e));
  try {
    await f.refresh();
    assert.deepEqual(readableOutside([join(project, 'a.ts'), 'a.ts', join(bench, 'tally.txt'), '../bench/tally.txt'], project), [join(bench, 'tally.txt')], 'inside ones need nothing; duplicates once');
    f.delegate('gemma', 'Count the holds in tally.txt.', 'lead', { profile: 'explore', files: [join(project, 'a.ts'), join(bench, 'tally.txt')] });
    assert.match(handedOut().at(-1)!.prompt!, new RegExp(`\nFiles: ${join(project, 'a.ts')}, ${join(bench, 'tally.txt')} \\(outside your folder: you may read it, not change it\\)$`));
    assert.throws(() => f.delegate('gemma', 'Read the bench.', 'lead', { profile: 'explore', files: [bench, join(bench, 'missing.log'), join(bench, 'tally.txt')] }), (e: Error) => e.message ===
      `${bench}, ${join(bench, 'missing.log')} are outside the task's folder ${project} and aren't files. A worker can read files outside its folder that you pass in \`files\`, but never folders or missing paths there: pass the files themselves, set cwd to that folder, or do that part yourself.`);
    assert.throws(() => f.delegate('gemma', 'x', 'lead', { files: [join(bench, 'missing.log')] }), /missing\.log is outside the task's folder .* and isn't a file\./);
    assert.equal(handedOut().length, 1, 'a refused delegate queues nothing');
    f.delegate('gemma', 'Create notes.md here.', 'lead', { files: [join(project, 'notes.md')] });
    assert.equal(handedOut().length, 2, 'a missing file inside the folder is fine: the task may create it');

    // The guard lets the file tools read exactly those files, and tells the worker what to do about anything else.
    const refused: string[] = [];
    const hooks = guard(project, true, [], { readable: [join(bench, 'tally.txt')], onRefuse: (id) => refused.push(id) });
    const pre = async (tool: string, input: Record<string, unknown>, id = 'u') =>
      ((await hooks[0].hooks[0]({ hook_event_name: 'PreToolUse', session_id: 's', transcript_path: '', cwd: project, tool_name: tool, tool_input: input, tool_use_id: id } as never, undefined, signal())) as { hookSpecificOutput?: { permissionDecisionReason?: string } }).hookSpecificOutput?.permissionDecisionReason ?? 'allow';
    assert.equal(await pre('Read', { file_path: join(bench, 'tally.txt') }), 'allow');
    assert.equal(await pre('Grep', { pattern: 'x', path: join(bench, 'tally.txt') }), 'allow');
    assert.equal(await pre('Read', { file_path: 'a.ts' }), 'allow');
    assert.equal(await pre('Read', { file_path: join(bench, 'other.txt') }, 'u1'), `Stay inside the project directory ${project}. If the task needs ${join(bench, 'other.txt')}, you can't do that part: report outcome "blocked" and name the path.`);
    assert.equal(await pre('Glob', { pattern: '*', path: bench }, 'u2'), `Stay inside the project directory ${project}. If the task needs ${bench}, you can't do that part: report outcome "blocked" and name the path.`, 'not the folder it is in');
    const rw = guard(project, false, [], { readable: [join(bench, 'tally.txt')] });
    const decide = async (tool: string, input: Record<string, unknown>) =>
      ((await rw[0].hooks[0]({ hook_event_name: 'PreToolUse', session_id: 's', transcript_path: '', cwd: project, tool_name: tool, tool_input: input, tool_use_id: 'w' } as never, undefined, signal())) as { hookSpecificOutput?: { permissionDecisionReason?: string } }).hookSpecificOutput?.permissionDecisionReason ?? 'allow';
    assert.equal(await decide('Edit', { file_path: join(bench, 'tally.txt'), old_string: 'a', new_string: 'b' }), `${join(bench, 'tally.txt')} is outside the project directory ${project}: you may read it, not change it.`);
    assert.equal(await decide('Write', { file_path: join(project, 'b.ts'), content: '' }), 'allow');
    assert.equal(await pre('Bash', { command: 'git log' }, 'u3'), 'allow', "the guard doesn't police tools a profile lacks: the SDK never runs them");
    assert.deepEqual(refused, ['u1', 'u2'], 'each refusal is heard by its tool_use id');
  } finally {
    f.stop();
    llmd.close();
    rmSync(root, { recursive: true, force: true });
  }
});

test("the RESULT has a hub-measured line of the tools the worker used and how many were refused, whatever it reports", () => {
  // The morning's shape: an explore task (no shell) asked for 12 commands' output from a folder outside its cwd.
  const log = new ToolLog(PROFILES.explore.tools);
  log.call('r1', 'Read');
  log.refuse('r2'); // the guard can hear of a call before the call itself shows up
  log.call('r2', 'Read');
  log.call('r3', 'Read');
  log.call('g1', 'Grep');
  log.call('b1', 'Bash');
  log.call('g2', 'Grep');
  log.result('r1', true); // a file that doesn't exist: failed, not refused
  log.result('r2', true);
  log.refuse('r3');
  log.result('r3', true);
  log.result('g1', false);
  log.result('b1', true); // not in its profile: Claude Code says there's no such tool
  log.result('g2', false);
  log.result('nope', true);
  assert.deepEqual(log.list(), [
    { name: 'Read', calls: 3, refused: 2, failed: 1 },
    { name: 'Grep', calls: 2, refused: 0, failed: 0 },
    { name: 'Bash', calls: 1, refused: 1, failed: 0 },
  ]);
  const morning = { used: log.list(), profile: 'explore' as const };
  assert.equal(toolsLine(morning), 'Tools used (hub-measured): Read ×3 (2 refused, 1 failed), Grep ×2, Bash ×1 (1 refused); no shell (the explore profile has none)');
  const cmds = Array.from({ length: 12 }, (_, i) => `cmd ${i}`);
  assert.equal(toolsLine({ used: [{ name: 'Read', calls: 1, refused: 0, failed: 0 }], profile: 'general' }, cmds), 'Tools used (hub-measured): Read ×1; no shell command ran, though its report lists 12 commands');
  assert.equal(toolsLine({ used: [{ name: 'Bash', calls: 2, refused: 2, failed: 0 }], profile: 'implement' }, ['git commit -m x']), 'Tools used (hub-measured): Bash ×2 (2 refused); no shell command ran, though its report lists 1 command');
  assert.equal(toolsLine({ used: [{ name: 'Bash', calls: 4, refused: 1, failed: 2 }, { name: 'Edit', calls: 1, refused: 0, failed: 0 }], profile: 'implement' }, cmds), 'Tools used (hub-measured): Bash ×4 (1 refused, 2 failed), Edit ×1', 'commands ran: nothing more to say');
  assert.equal(toolsLine({ used: [], profile: 'review' }), 'Tools used (hub-measured): none; no shell command ran');

  const { d, events } = setup();
  d.setPlan(LEAD, steps(['1', 'qwen-9b']));
  const { taskId } = d.delegate(LEAD, 'qwen-9b', 'Run these 12 commands in ../bench and paste their output.', { profile: 'explore', step: '1' });
  d['thread'](taskId!).final = { summary: 'All 12 commands executed verbatim below.', commands: cmds };
  d.onTaskEnd(taskId!, 'qwen-9b', 'done', '', 'no changes', '', undefined, morning);
  const result = of(events, 'dialogue').filter((c: Card) => c.kind === 'RESULT').at(-1)!;
  assert.equal(result.text, 'Finished: All 12 commands executed verbatim below.\nTools used (hub-measured): Read ×3 (2 refused, 1 failed), Grep ×2, Bash ×1 (1 refused); no shell (the explore profile has none), though its report lists 12 commands\nHub-measured changes:\nno changes');
  // Claude's own subagents and Apple workers have no such count: no line.
  const other = d.delegate(LEAD, 'qwen-9b', 'Another', { step: '1' }).taskId!;
  d.onTaskEnd(other, 'qwen-9b', 'done', 'ok', 'no changes');
  assert.doesNotMatch(of(events, 'dialogue').at(-1)!.text, /Tools used/);
});

test('delegate tells Claude when the task starts: now, behind the tasks its worker runs first, or after a swap', () => {
  const { d, tasks } = setup();
  d.setPlan(LEAD, steps(['1', 'qwen-27b']));
  const { taskId, step } = d.delegate(LEAD, 'qwen-27b', 'Do it', { step: '1' });
  assert.match(d['delegated'](taskId!, step), /^Delegated as t-1 \(plan step 1\): qwen-27b has started it\./);
  tasks.set('t-9', { worker: 'qwen-27b', state: 'queued', by: LEAD, ahead: ['t-1', 't-5'] });
  assert.match(d['delegated']('t-9'), /runs one task at a time and has t-1, t-5 to finish first, so this one waits in its queue/);
  tasks.set('t-8', { worker: 'gemma', state: 'awaiting_swap', by: LEAD, ahead: [] });
  assert.match(d['delegated']('t-8'), /gemma's model isn't loaded, so the user is asked to approve loading it/);
});

// ---- 3. questions ----

test("a question Claude passes to you: the worker waits for your answer, Claude's turn can end, and the RESULT carries it", async () => {
  const { d, events, call, end } = setup();
  d.setPlan(LEAD, steps(['1', 'qwen-27b']));
  const { taskId } = d.delegate(LEAD, 'qwen-27b', 'Format the file', { step: '1' });
  const asked = d.ask(taskId!, 'qwen-27b', 'Tabs or spaces?', ['tabs', 'spaces']);
  assert.equal((await call('Stop')).decision, 'block', 'unread question');
  const inbox = await call('PostToolUse', { tool_name: 'Read', tool_input: {}, tool_response: '', tool_use_id: 'u1' });
  const qid = /question_id=(\S+)/.exec(inbox.hookSpecificOutput?.additionalContext ?? '')?.[1];
  assert.ok(qid, 'Claude got the question with its id');
  assert.match((await call('Stop')).reason ?? '', /still running \(t-1\)/, 'its worker is busy');
  d.escalate(LEAD, qid!, 'A style choice for your codebase.');
  const esc = of(events, 'dialogue').find((c) => c.kind === 'ESCALATE') as Card;
  assert.deepEqual([esc.from, esc.to, esc.replyTo, esc.text, esc.refused], [LEAD, YOU, qid, 'A style choice for your codebase.', undefined]);
  assert.equal((await call('Stop')).decision, undefined, 'waiting only on you: the turn may end');
  assert.equal(d.answer('iphone', qid!, 'spaces'), null);
  assert.deepEqual(await asked, { text: 'Answer: spaces' });
  assert.throws(() => d.escalate(LEAD, qid!, 'again'), /no open question/);
  end(taskId!, 'done', 'Reformatted with spaces.');
  const result = of(events, 'dialogue').find((c) => c.kind === 'RESULT') as Card;
  assert.match(result.text, /The user answered its questions: "Tabs or spaces\?" → spaces/);
});

test('an unanswered question times out with a card that says so, and the worker can ask again', async () => {
  mock.timers.enable({ apis: ['setTimeout'] });
  try {
    const { d, events } = setup();
    d.setPlan(LEAD, steps(['1', 'qwen-27b']));
    const { taskId } = d.delegate(LEAD, 'qwen-27b', 'Do it', { step: '1' });
    const asked = d.ask(taskId!, 'qwen-27b', 'Which one?');
    mock.timers.tick(30 * 60_000);
    assert.match((await asked).text, /^Answer: No answer in time\. Proceed with your best judgment/);
    const closing = of(events, 'dialogue').at(-1) as Card;
    assert.deepEqual([closing.kind, closing.from, closing.replyTo !== undefined], ['ANSWER', 'duet', true]);
    const again = d.ask(taskId!, 'qwen-27b', 'And this?');
    const qid = (of(events, 'dialogue').at(-1) as Card).id;
    d.answer(LEAD, qid, 'that one');
    assert.deepEqual(await again, { text: 'Answer: that one' });
  } finally {
    mock.timers.reset();
  }
});

// ---- 4. the plan ----

test('the plan comes first; each handed-out task joins its step (or a new one), and updates keep the tasks', () => {
  const { d, events, prompts } = setup();
  assert.match(d.delegate(LEAD, 'qwen-27b', 'Do it').refused ?? '', /Set out your plan with plan\(\) first/);
  assert.ok(d.delegate('mac', 'qwen-27b', 'Your own task').taskId, 'your own tasks need no plan');
  d.setPlan(LEAD, [
    { id: '1', text: 'Find the effort tables', owner: 'auto', status: 'pending' },
    { id: '2', text: 'Review the change', owner: 'lead', status: 'pending' },
  ]);
  const a = d.delegate(LEAD, 'auto', 'Find where effort tables are defined.', { step: '1', profile: 'explore', doneWhen: 'the answer has file:line' });
  assert.match(prompts.get(a.taskId!) ?? '', /Done when: the answer has file:line\n\n---\nYou are a Doublet worker\. Task profile: explore \(read-only\)\./);
  assert.match((of(events, 'dialogue').find((c) => c.kind === 'TASK' && c.taskId === a.taskId) as Card).text, /\n\nDone when: the answer has file:line$/);
  const b = d.delegate(LEAD, 'qwen-9b', 'Rename foo to bar in util.ts\nand nothing else.', { profile: 'implement' });
  assert.equal(b.step, '3');
  let plan = of(events, 'plan').at(-1)!;
  assert.equal(plan.conversationId, 'conv-1');
  assert.deepEqual(plan.steps.map((s) => [s.id, s.owner, s.status, s.taskId ?? null, s.text]), [
    ['1', 'qwen-27b', 'in_progress', a.taskId, 'Find the effort tables'],
    ['2', 'lead', 'pending', null, 'Review the change'],
    ['3', 'qwen-9b', 'in_progress', b.taskId, 'Rename foo to bar in util.ts'],
  ]);
  // Claude sends the list again (it never sends task ids): the tasks stay with their steps.
  d.setPlan(LEAD, [
    { id: '1', text: 'Find the effort tables', owner: 'auto', status: 'completed', note: 'effort.ts:12' },
    { id: '2', text: 'Review the change', owner: 'lead', status: 'in_progress' },
    { id: '3', text: 'Rename foo', owner: 'qwen-9b', status: 'in_progress' },
  ]);
  plan = of(events, 'plan').at(-1)!;
  assert.deepEqual(plan.steps.map((s) => [s.owner, s.taskId ?? null, s.note ?? null]), [['qwen-27b', a.taskId, 'effort.ts:12'], ['lead', null, null], ['qwen-9b', b.taskId, null]]);
  assert.throws(() => d.setPlan(LEAD, steps(['1', 'lead'], ['1', 'lead'])), /unique/);
  assert.throws(() => d.setPlan(LEAD, []), /at least one step/);
});

test("Claude is reminded once to bring its plan up to date before it stops, and sees the plan at every prompt", async () => {
  const { d, call, end } = setup();
  assert.equal((await call('Stop')).decision, undefined, 'no plan, nothing to remind');
  d.setPlan(LEAD, [{ id: '1', text: 'Write tests', owner: 'qwen-27b', status: 'pending' }, { id: '2', text: 'Review', owner: 'lead', status: 'in_progress' }]);
  const { taskId } = d.delegate(LEAD, 'qwen-27b', 'Write tests', { step: '1' });
  const ctx = (await call('UserPromptSubmit', { prompt: 'go' })).hookSpecificOutput?.additionalContext ?? '';
  assert.match(ctx, /Fleet now:\n- qwen-27b/);
  assert.match(ctx, /Your plan:\n- \[>\] 1 \(qwen-27b, t-1 running\): Write tests\n- \[>\] 2 \(lead\): Review/);
  end(taskId!);
  await call('PostToolUse', { tool_name: 'mcp__duet__answer', tool_input: {}, tool_response: '', tool_use_id: 'u' }); // takes the RESULT
  const stop = await call('Stop');
  assert.equal(stop.decision, 'block');
  assert.match(stop.reason ?? '', /Your plan is out of date \(steps 1, 2\)/);
  assert.equal((await call('Stop')).decision, undefined, 'once per turn');
  d.onLeadTurnStart();
  d.setPlan(LEAD, [{ id: '1', text: 'Write tests', owner: 'qwen-27b', status: 'completed' }, { id: '2', text: 'Review', owner: 'lead', status: 'completed' }]);
  assert.equal((await call('Stop')).decision, undefined, 'up to date');
});

test('plans are kept per conversation and continue after a restart', () => {
  const a = setup('conv-A');
  a.d.setPlan(LEAD, steps(['1', 'lead', 'in_progress']));
  const saved = of(a.events, 'plan').map((e) => ({ conversationId: e.conversationId, steps: e.steps }));
  const b = setup('conv-A');
  b.d.seedPlans([...saved, { conversationId: 'conv-B', steps: steps(['x', 'lead']).map((s) => ({ ...s })) }]);
  assert.deepEqual(b.d.plan().map((s) => s.id), ['1']);
  assert.match(formatPlan(b.d.plan(), () => undefined), /^- \[>\] 1 \(lead\): step 1$/);
});

test('the Stop hook still gives up after MAX_STOP_BLOCKS, a stale plan included', async () => {
  const { d, call } = setup();
  d.setPlan(LEAD, steps(['1', 'qwen-27b']));
  d.delegate(LEAD, 'qwen-27b', 'Long job', { step: '1' });
  const decisions = [];
  for (let i = 0; i < MAX_STOP_BLOCKS + 2; i++) decisions.push((await call('Stop')).decision ?? 'allow');
  assert.equal(decisions.filter((x) => x === 'block').length, MAX_STOP_BLOCKS);
});
