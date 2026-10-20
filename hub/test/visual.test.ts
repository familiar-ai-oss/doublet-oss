// Diagrams, handwritten notes and the Lock Screen, against the real Max login (cheap model, low effort):
// Claude's diagram tool and revisions; notes to an idle Claude (with a picture) and to a busy one (mid-turn);
// an approval decided over HTTP (the Live Activity's buttons); plus the pure parts: note wording, the Lock Screen
// status, the push payload, the APNs token, and a task folder's diff.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createVerify, generateKeyPairSync } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { apnsJwt, type Apns } from '../src/apns.ts';
import { callSummary, LiveActivities, livePayload, LiveStatus } from '../src/live.ts';
import { notesPrompt } from '../src/notes.ts';
import type { Annotation, EventBody, HubEvent, Notes } from '../src/protocol.ts';
import { Annotations } from '../src/annotations.ts';
import { checkFolder, listDir, readFile } from '../src/fs.ts';
import { fullDiff } from '../src/worker.ts';
import { createHarness } from './harness.ts';

// A 1x1 PNG: enough for Claude to receive an image block.
const PIXEL = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const ev = (seq: number, body: object) => ({ seq, ts: 1_700_000_000_000 + seq * 1000, ...body }) as HubEvent;

test('notes read as one message: intent, the elements or lines they were drawn on, and the words', () => {
  const notes: Notes = {
    surface: { kind: 'diagram', diagramId: 'g-1', version: 2, title: 'Duet' },
    hasImage: true,
    items: [
      { id: 'a', intent: 'remove', elements: [{ id: 'proxy', label: 'Worker proxy' }], text: 'no longer needed' },
      { id: 'b', intent: 'connect', elements: [{ id: 'hub', label: 'Hub' }, { id: 'llmd', label: 'llmd' }], text: 'health checks' },
      { id: 'c', intent: 'group', elements: [{ id: 'lead', label: 'Lead' }, { id: 'fleet', label: 'Fleet' }] },
      { id: 'd', intent: 'question', text: 'why 12?' },
    ],
  };
  const text = notesPrompt('ipad', notes);
  assert.match(text, /^\[Handwritten notes from ipad on the diagram "Duet" \(g-1, version 2\)\. The attached image shows the ink\.\]/);
  assert.match(text, /1\. Remove "Worker proxy" \(proxy\): "no longer needed"/);
  assert.match(text, /2\. Connect "Hub" \(hub\) → "llmd": "health checks"/, 'a label that is its own id is not repeated');
  assert.match(text, /3\. These belong together: "Lead" \(lead\), "Fleet" \(fleet\)$/m);
  assert.match(text, /4\. Question about the whole diagram: "why 12\?"/);
  const diff = notesPrompt('ipad', { surface: { kind: 'diff', taskId: 't-1', worker: 'qwen-27b' }, items: [{ id: 'e', intent: 'connect', lines: [{ file: 'a.py', start: 3, end: 5 }, { file: 'a.py', start: 20, end: 20 }] }] });
  assert.match(diff, /qwen-27b's diff for task t-1/);
  assert.match(diff, /1\. Move a\.py:3-5 → a\.py:20/);
  // On the plan: steps go by number, and anything but a question redirects the work.
  const plan = { kind: 'plan' as const, conversationId: 'c-1' };
  const onPlan = notesPrompt('ipad', { surface: plan, items: [
    { id: 'p', intent: 'change', elements: [{ id: '3', label: 'Refactor the lexer' }], text: 'do the tests first' },
    { id: 'r', intent: 'remove', elements: [{ id: '4', label: 'Benchmark' }] },
  ] });
  assert.match(onPlan, /^\[Handwritten notes from ipad on your plan\.\]/);
  assert.match(onPlan, /1\. Change step 3 "Refactor the lexer": "do the tests first"/);
  assert.match(onPlan, /2\. Remove step 4 "Benchmark"$/m);
  assert.match(onPlan, /They redirect the work on those steps: change your plan to follow them \(the plan tool\)/);
  const askPlan = notesPrompt('ipad', { surface: plan, items: [{ id: 'q', intent: 'question', elements: [{ id: '2', label: 'Wire the tokens' }], text: 'why this order?' }] });
  assert.match(askPlan, /1\. Question about step 2 "Wire the tokens": "why this order\?"/);
  assert.doesNotMatch(askPlan, /redirect/, 'a question is answered, not acted on');
  // On a file, the note shows its question above the answer, so Claude starts with the answer.
  const onFile = (n: number) => notesPrompt('ipad', { surface: { kind: 'file', path: 'a.py' }, items: Array.from({ length: n }, (_, i) => ({ id: `q${i}`, intent: 'question' as const, text: 'why?' })) });
  assert.match(onFile(1), /Answer it about how this code works\. Start with the answer itself, in one paragraph of at most 65 words; then, after a blank line, any detail, code or citations\. Don't repeat the question: the note already shows it\./);
  assert.match(onFile(2), /Answer each one about how this code works, numbered like the notes\. Start each with its answer/);
  // A typed question isn't called handwriting.
  const typed = notesPrompt('ipad', { surface: { kind: 'file', path: 'a.py' }, items: [{ id: 't', intent: 'question', text: 'why?', typed: true }] });
  assert.match(typed, /^\[Typed notes from ipad on the file a\.py\.\]/);
});

test('the Lock Screen status follows the hub: phase, timer, approvals, questions, worker speeds', () => {
  const s = new LiveStatus();
  assert.equal(s.apply(ev(1, { type: 'fleet', workers: [{ id: 'qwen-27b', label: 'Qwen3.8 27B · R9700', enabled: true, running: null }] })), 'now');
  assert.equal(s.apply(ev(2, { type: 'turn_start', turn: 1 })), 'now');
  assert.deepEqual([s.state().busy, s.state().phase, s.state().since], [true, 'Thinking', 1_700_000_002]);
  assert.equal(s.apply(ev(3, { type: 'approval_request', id: 'a1', turn: 1, tool: 'Bash', input: { command: 'rm -rf build\necho done' } })), 'now');
  assert.deepEqual(s.state().approval, { id: 'a1', tool: 'Bash', summary: 'rm -rf build', risky: false });
  assert.equal(s.state().phase, 'Needs your approval');
  assert.equal(s.apply(ev(4, { type: 'worker_request', worker: 'qwen-27b', status: 200, ttfbMs: 1, totalMs: 2, inputTokens: 1, outputTokens: 1, tokPerS: 131.5, sent: {} })), 'soon');
  assert.deepEqual(s.state().workers, [{ id: 'qwen-27b', name: 'Qwen3.8 27B', place: 'R9700', tokPerS: 131.5, busy: false }]);
  s.apply(ev(5, { type: 'approval_resolved', id: 'a1', decision: 'allow', edited: false, by: 'iphone' }));
  s.apply(ev(6, { type: 'assistant', turn: 1, text: '', toolUses: [{ id: 'u', name: 'mcp__duet__await_workers', input: {} }] }));
  assert.equal(s.state().phase, 'Waiting on workers');
  s.apply(ev(7, { type: 'dialogue', id: 'q1', kind: 'QUESTION', taskId: 't', from: 'qwen-9b', to: 'iphone', text: '?' }));
  assert.equal(s.state().phase, '1 waiting on you');
  s.apply(ev(8, { type: 'turn_end', turn: 1, subtype: 'success', isError: false, interrupted: false }));
  assert.equal(s.state().busy, false);
  assert.equal(s.state().waiting, 1, "a worker's question to you still waits after Claude's turn");
  assert.equal(callSummary('Edit', { file_path: '/srv/app/main.ts', old_string: 'x' }), '/srv/app/main.ts');
});

test('Live Activity pushes: tokens merge, push-to-start reaches only devices whose app is closed (once), idle ones end', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'duet-live-'));
  const file = join(dir, 'live.json');
  const sent: string[] = [];
  const apns = { liveActivity: async (token: string, _env: string, p: { aps: { event: string } }) => (sent.push(`${p.aps.event}:${token}`), { status: 200 }) } as unknown as Apns;
  const open = new Set(['iphone']);
  const live = new LiveActivities(file, apns, () => {}, { connected: (d) => open.has(d), idleEndMs: 100 });
  const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
  const saved = () => JSON.parse(readFileSync(file, 'utf8'));
  try {
    live.register('iphone', { token: 'act-1', env: 'development' });
    live.register('iphone', { token: undefined, startToken: 'start-1', env: 'development' });
    live.register('ipad', { startToken: 'start-2', env: 'development' });
    assert.deepEqual(saved().iphone, { token: 'act-1', startToken: 'start-1', env: 'development' }, 'a start token alone keeps the activity token');
    await wait(50);
    sent.length = 0;
    live.onEvent(ev(1, { type: 'turn_start', turn: 1 }));
    await wait(400);
    live.onEvent(ev(2, { type: 'approval_request', id: 'a1', turn: 1, tool: 'Bash', input: { command: 'ls' } }));
    await wait(400);
    assert.deepEqual(sent.filter((s) => s.startsWith('start:')), ['start:start-2'], 'the closed iPad is started once; the open iPhone starts its own');
    assert.ok(sent.includes('update:act-1'));
    sent.length = 0;
    live.onEvent(ev(3, { type: 'turn_end', turn: 1, subtype: 'success', isError: false, interrupted: false }));
    await wait(1600);
    assert.ok(sent.includes('end:act-1'), `pushed: ${sent.join(', ')}`);
    assert.deepEqual(saved().iphone, { startToken: 'start-1', env: 'development' }, 'an ended activity takes no more updates');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('the push payload carries the content state, and an APNs token verifies with the key that signed it', () => {
  const st = new LiveStatus().state();
  const p = livePayload('start', st, 1000) as { aps: Record<string, unknown> };
  assert.equal(p.aps.event, 'start');
  assert.equal(p.aps['attributes-type'], 'DuetActivityAttributes');
  assert.deepEqual(p.aps['content-state'], st);
  assert.equal((livePayload('update', { ...st, busy: true }, 1000) as { aps: Record<string, unknown> }).aps['stale-date'], 1300);
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const jwt = apnsJwt(privateKey, 'KEY123', 'TEAM456', 1700000000);
  const [head, claims, sig] = jwt.split('.');
  assert.deepEqual(JSON.parse(Buffer.from(head, 'base64url').toString()), { alg: 'ES256', kid: 'KEY123' });
  assert.deepEqual(JSON.parse(Buffer.from(claims, 'base64url').toString()), { iss: 'TEAM456', iat: 1700000000 });
  assert.ok(createVerify('sha256').update(`${head}.${claims}`).verify({ key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(sig, 'base64url')));
});

test("a task folder's diff has its tracked changes and its new files", async () => {
  const dir = mkdtempSync(join(tmpdir(), 'duet-diff-'));
  try {
    const git = (...a: string[]) => execFileSync('git', ['-C', dir, ...a]);
    git('init', '-q');
    writeFileSync(join(dir, 'a.txt'), 'one\ntwo\n');
    git('add', '.');
    git('-c', 'user.email=t@x', '-c', 'user.name=t', 'commit', '-qm', 'init');
    writeFileSync(join(dir, 'a.txt'), 'one\nTWO\n');
    writeFileSync(join(dir, 'new.py'), 'print("hi")\n');
    const d = await fullDiff(dir);
    assert.match(d.diff, /-two\n\+TWO/);
    assert.match(d.diff, /\+\+\+ b\/new\.py\n@@ -0,0 \+1 @@\n\+print\("hi"\)/);
    assert.equal(d.truncated, false);
    assert.equal((await fullDiff(tmpdir())).error, 'not a git repository');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the file viewer lists a folder with each entry's git status, and reads a file with its changed lines", async () => {
  const dir = mkdtempSync(join(tmpdir(), 'duet-fs-'));
  try {
    const git = (...a: string[]) => execFileSync('git', ['-C', dir, ...a]);
    git('init', '-q', '-b', 'main');
    mkdirSync(join(dir, 'pkg'));
    writeFileSync(join(dir, 'a.py'), 'one\ntwo\nthree\nfour\n');
    writeFileSync(join(dir, 'pkg', 'c.py'), 'x = 1\n');
    writeFileSync(join(dir, 'Zeta.md'), 'z\n');
    git('add', '.');
    git('-c', 'user.email=t@x', '-c', 'user.name=t', 'commit', '-qm', 'init');
    writeFileSync(join(dir, 'a.py'), 'one\nTWO\nthree\n');
    writeFileSync(join(dir, 'pkg', 'c.py'), 'x = 2\n');
    writeFileSync(join(dir, 'b.txt'), 'new\n');
    mkdirSync(join(dir, 'newdir'));
    writeFileSync(join(dir, 'newdir', 'n.txt'), 'n\n');
    writeFileSync(join(dir, 'blob.bin'), Buffer.from([1, 0, 2, 3]));

    const l = await listDir(dir, '/');
    assert.equal(l.repo?.branch, 'main');
    assert.deepEqual(l.entries.map((e) => e.name), ['newdir', 'pkg', 'a.py', 'b.txt', 'blob.bin', 'Zeta.md'], 'folders first, then by name; no .git');
    const git_ = Object.fromEntries(l.entries.map((e) => [e.name, e.git ?? '']));
    assert.deepEqual(git_, { newdir: '?', pkg: '•', 'a.py': 'M', 'b.txt': '?', 'blob.bin': '?', 'Zeta.md': '' });
    assert.equal((await listDir('pkg', dir)).entries[0].git, 'M', 'a path relative to the base folder');

    const f = await readFile(join(dir, 'a.py'), '/');
    assert.equal(f.text, 'one\nTWO\nthree\n');
    assert.equal(f.git, 'M');
    assert.deepEqual(f.changed, [2], 'line 2 changed');
    assert.deepEqual(f.removedAfter, [3], 'a line removed after line 3');
    assert.equal((await readFile('blob.bin', dir)).binary, true);
    assert.equal((await readFile('b.txt', dir)).git, '?');
    await assert.rejects(checkFolder(join(dir, 'nope'), '/'), /doesn't exist/);
    await assert.rejects(checkFolder(join(dir, 'a.py'), '/'), /not a folder/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('annotations keep the handwriting, take their turn, and get its answer and diagrams', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'duet-ann-'));
  try {
    const out: Annotation[] = [];
    const a = new Annotations(dir, (b: EventBody) => { if (b.type === 'annotation') out.push(b.annotation); });
    const surface = { kind: 'file' as const, path: '/srv/calc.py' };
    a.add('ipad', surface, [
      { id: 'n1', intent: 'question', text: 'how does sub work?', lines: [{ file: '/srv/calc.py', start: 6, end: 8, code: 'def sub(a, b):' }], ink: PIXEL },
      { id: 'n2', intent: 'comment', text: 'not a png', ink: Buffer.from('hello').toString('base64') },
    ]);
    assert.deepEqual(out.map((x) => [x.id, x.status, x.ink ?? false]), [['n1', 'open', true], ['n2', 'open', false]], 'only a PNG is kept');
    assert.equal(a.ink('n1'), PIXEL);
    a.taken(['n1', 'n2'], 7);
    a.onEvent(ev(1, { type: 'turn_start', turn: 7 }));
    a.onEvent(ev(2, { type: 'assistant', turn: 7, text: 'sub returns b - a.', toolUses: [] }));
    a.onEvent(ev(3, { type: 'diagram', id: 'g-1', version: 1, title: 'sub', kind: 'mermaid', source: 'graph TD; A-->B', by: 'lead' }));
    a.onEvent(ev(4, { type: 'assistant', turn: 7, text: 'See the diagram.', toolUses: [] }));
    a.onEvent(ev(5, { type: 'turn_end', turn: 7, subtype: 'success', isError: false, interrupted: false }));
    await new Promise((r) => setTimeout(r, 10));
    const n1 = a.get('n1')!;
    assert.deepEqual([n1.status, n1.turn, n1.answer, n1.diagrams], ['answered', 7, 'sub returns b - a.\n\nSee the diagram.', ['g-1']]);
    // A stopped turn leaves its notes open.
    a.add('ipad', surface, [{ id: 'n3', intent: 'question', text: 'and mul?' }]);
    a.taken(['n3'], 8);
    a.onEvent(ev(6, { type: 'turn_start', turn: 8 }));
    a.onEvent(ev(7, { type: 'assistant', turn: 8, text: 'Half an answer', toolUses: [] }));
    a.onEvent(ev(8, { type: 'turn_end', turn: 8, subtype: 'success', isError: false, interrupted: true }));
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(a.get('n3')!.status, 'open');
    a.update('n1', { status: 'resolved' });
    assert.equal(a.get('n1')!.status, 'resolved');
    a.update('n1', { status: 'open' });
    assert.equal(a.get('n1')!.status, 'answered', 'reopened with its answer');
    a.update('n1', { delete: true });
    assert.equal(a.get('n1'), undefined);
    assert.equal(out.at(-1)?.deleted, true);
    assert.throws(() => a.ink('n1'), /no handwriting/);
    // After a restart, the log has them.
    const b = new Annotations(dir, () => {});
    b.seed(out.map((x, i) => ev(100 + i, { type: 'annotation', annotation: x })));
    assert.equal(b.get('n1'), undefined);
    assert.equal(b.get('n3')?.text, 'and mul?');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

const h = createHarness('vis');
const { client, events, next, all } = h;
after(() => h.cleanup());

async function prompt(text: string): Promise<number> {
  const from = events.length;
  await client.send({ type: 'prompt', text });
  return (await next('user', (e) => e.text === text, from)).turn;
}
const turnEnd = (turn: number) => next('turn_end', (e) => e.turn === turn, 0, 300_000);
const reply = (turn: number) => all('assistant', (e) => e.turn === turn).map((e) => e.text).join('');

test('Claude shows a diagram, then revises it under the same id', async () => {
  await h.startHub();
  await client.connect();
  await next('session', (e) => e.state === 'ready');
  const t1 = await prompt('Call mcp__duet__diagram with title "Pipeline", kind "mermaid", and source "graph TD; A[Prompt] --> B[Claude]". Then reply DONE.');
  await turnEnd(t1);
  const d1 = await next('diagram', (e) => e.title === 'Pipeline');
  assert.deepEqual([d1.kind, d1.version, d1.by], ['mermaid', 1, 'lead']);
  assert.match(d1.source, /A\[Prompt\] --> B\[Claude\]/);
  const t2 = await prompt(`Revise that diagram: call mcp__duet__diagram with id "${d1.id}", the same title and kind, and source "graph TD; A[Prompt] --> B[Claude] --> C[Workers]". Then reply DONE.`);
  await turnEnd(t2);
  const d2 = await next('diagram', (e) => e.id === d1.id && e.version === 2);
  assert.match(d2.source, /C\[Workers\]/);
});

test('notes asking for work start a turn for an idle Claude, tagged and with the picture attached', async () => {
  const from = events.length;
  await client.send({
    type: 'notes',
    surface: { kind: 'diagram', diagramId: 'g-test', version: 1, title: 'Pipeline' },
    items: [{ id: 'n1', intent: 'comment', elements: [{ id: 'B', label: 'Claude' }], text: 'say what this node does, and start your reply with KIWI-31' }],
    image: PIXEL,
    imageType: 'image/png',
  });
  const u = await next('user', (e) => !!e.notes, from);
  assert.equal(u.notes?.items[0].elements?.[0].id, 'B');
  assert.equal(u.notes?.hasImage, true);
  assert.match(u.text, /On "Claude" \(B\): "/);
  await turnEnd(u.turn);
  assert.match(reply(u.turn), /KIWI-31/);
});

test("a question on a diagram is answered by Claude in the note's thread, with the picture, not in the conversation", async () => {
  const from = events.length;
  await client.send({
    type: 'notes',
    surface: { kind: 'diagram', diagramId: 'g-test', version: 1, title: 'Pipeline' },
    items: [{ id: 'n1q', intent: 'question', elements: [{ id: 'B', label: 'Claude' }], text: 'what does this node do? Start your reply with KIWI-32' }],
    image: PIXEL,
    imageType: 'image/png',
  });
  const done = await next('annotation', (e) => e.annotation.id === 'n1q' && e.annotation.status === 'answered', from, 600_000);
  assert.deepEqual([done.annotation.route, done.annotation.answeredBy], ['claude', 'Claude']);
  assert.match(done.annotation.answer ?? '', /KIWI-32/);
  const chatId = done.annotation.chatId!;
  assert.ok(chatId, 'the note names its thread');
  const thread = all('side_message', (m) => m.chatId === chatId);
  assert.deepEqual(thread.map((m) => [m.role, m.fromNote]).slice(0, 2), [['user', true], ['assistant', true]], "the thread holds the note's own question and answer");
  assert.equal(all('side_chat', (e) => e.chatId === chatId).at(-1)?.annotationId, 'n1q');
  assert.equal(all('user', (e) => !!e.notes?.items.some((n) => n.id === 'n1q')).length, 0, "the conversation doesn't get the question");
});

test('a note sent while Claude works reaches it after its next tool call', async () => {
  const t = await prompt('Use the Bash tool to run exactly: echo STEP-ONE > step.txt . Then reply with a one-line summary of everything you were asked to do.');
  const req = await next('approval_request', (e) => e.turn === t);
  const from = events.length;
  await client.send({ type: 'notes', surface: { kind: 'diagram', diagramId: 'g-test' }, items: [{ id: 'n2', intent: 'comment', text: 'also include the word MANGO-55 in your reply' }] });
  const n = await next('notes', (e) => e.turn === t, from);
  assert.equal(n.notes.items[0].id, 'n2');
  await client.send({ type: 'approve', id: req.id });
  await turnEnd(t);
  assert.match(reply(t), /MANGO-55/, `reply: ${reply(t)}`);
});

test("the Lock Screen's buttons decide an approval over HTTP with the device token", async () => {
  const t = await prompt('Use the Bash tool to run exactly: echo LOCKED > lock.txt . Then reply DONE.');
  const req = await next('approval_request', (e) => e.turn === t);
  const url = `http://127.0.0.1:${h.port}/api/decide`;
  const bad = await fetch(url, { method: 'POST', headers: { 'x-duet-device': 'test', authorization: 'Bearer nope' }, body: JSON.stringify({ id: req.id, decision: 'allow' }) });
  assert.equal(bad.status, 403);
  const ok = await fetch(url, { method: 'POST', headers: { 'x-duet-device': 'test', authorization: `Bearer ${h.token}` }, body: JSON.stringify({ id: req.id, decision: 'allow' }) });
  assert.equal(ok.status, 200);
  const r = await next('approval_resolved', (e) => e.id === req.id);
  assert.deepEqual([r.decision, r.by], ['allow', 'test']);
  const again = await fetch(url, { method: 'POST', headers: { 'x-duet-device': 'test', authorization: `Bearer ${h.token}` }, body: JSON.stringify({ id: req.id, decision: 'deny' }) });
  assert.equal(again.status, 409, 'an approval that is already decided cannot be decided again');
  await turnEnd(t);
  const ack = await client.send({ type: 'live_activity', token: 'abc', environment: 'development' });
  assert.equal(ack.ok, true);
  // A Live Activity's token from a background launch, when there is no WebSocket.
  const reg = (token: string) => fetch(`http://127.0.0.1:${h.port}/api/live`, { method: 'POST', headers: { 'x-duet-device': 'test', authorization: `Bearer ${token}` }, body: JSON.stringify({ token: 'def', environment: 'development' }) });
  assert.equal((await reg('nope')).status, 403);
  assert.equal((await reg(h.token)).status, 200);
});

test('moving Claude to another folder keeps the conversation, and new shells, tasks and listings start there', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'duet-move-'));
  try {
    const t1 = await prompt('Remember the word PLUM-19. Reply with just OK.');
    await turnEnd(t1);
    await assert.rejects(client.send({ type: 'set_cwd', path: join(dir, 'missing') }), /doesn't exist/);
    const from = events.length;
    const ack = await client.send({ type: 'set_cwd', path: dir });
    assert.equal(ack.ok, true);
    const moved = await next('context', (e) => e.action === 'folder', from);
    assert.equal(moved.path, dir);
    const info = await next('lead_info', (e) => e.cwd === dir, from);
    assert.ok(info.recentCwds?.includes(dir));
    const t2 = await prompt('What word did I ask you to remember, and what is your working directory? Reply exactly WORD|DIRECTORY with nothing else.');
    await turnEnd(t2);
    const [word, where] = reply(t2).trim().split('|');
    assert.equal(word, 'PLUM-19', `reply: ${reply(t2)}`);
    assert.equal(where?.trim(), dir);
    const listing = await client.send({ type: 'fs_list' });
    assert.equal(listing.listing?.path, dir);
  } finally {
    // Back to the project before the folder goes, so later tests don't run Claude in a folder that's gone.
    await client.send({ type: 'set_cwd', path: h.projectDir }).catch(() => {});
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a question written on a file is kept and answered (in its thread, when it reaches Claude), and its handwriting can be fetched", async () => {
  const from = events.length;
  await client.send({
    type: 'notes',
    surface: { kind: 'file', path: '/srv/calc.py' },
    items: [{ id: 'q-file-1', intent: 'question', text: 'how does sub work? Answer from the lines shown, without tools, and start your reply with LYCHEE-8', lines: [{ file: '/srv/calc.py', start: 6, end: 8, code: 'def sub(a, b):\n    return b - a' }], ink: PIXEL }],
  });
  const done = await next('annotation', (e) => e.annotation.id === 'q-file-1' && e.annotation.status === 'answered', from, 900_000);
  assert.match(done.annotation.answer ?? '', /LYCHEE-8/);
  assert.equal(done.annotation.ink, true);
  assert.equal(JSON.stringify(events.slice(from)).includes(PIXEL), false, 'the handwriting stays out of the log');
  assert.equal((await client.send({ type: 'annotation_ink', id: 'q-file-1' })).image, PIXEL);
  // A local model couldn't read the file (it isn't there), so Claude answered, in the note's thread.
  if (done.annotation.route === 'claude') {
    const chatId = done.annotation.chatId!;
    assert.ok(chatId, 'the note names its thread');
    const first = all('side_message', (m) => m.chatId === chatId)[0];
    assert.deepEqual([first.role, first.fromNote, first.image], ['user', true, true], 'the thread starts with the handwritten question');
    await client.send({ type: 'annotation_update', id: 'q-file-1', delete: true });
    await next('side_chat', (e) => e.chatId === chatId && e.deleted === true, from);
  } else {
    await client.send({ type: 'annotation_update', id: 'q-file-1', delete: true });
  }
  await next('annotation', (e) => e.annotation.id === 'q-file-1' && !!e.annotation.deleted, from);
});

test('a diagram can name the code it explains and link its nodes to lines', async () => {
  const t = await prompt('Call mcp__duet__diagram with title "Sub", kind "mermaid", source "graph TD; A[sub] --> B[return b - a]", explains [{"path": "/srv/calc.py", "start": 6, "end": 8}], and links {"A": "/srv/calc.py:6", "B": "/srv/calc.py:8"}. Then reply DONE.');
  await turnEnd(t);
  const d = await next('diagram', (e) => e.title === 'Sub');
  assert.deepEqual(d.explains, [{ path: '/srv/calc.py', start: 6, end: 8 }]);
  assert.deepEqual(d.links, { A: '/srv/calc.py:6', B: '/srv/calc.py:8' });
});
