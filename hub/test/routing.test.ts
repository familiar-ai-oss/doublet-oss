// Questions on notes and in side chats: which go to a local model, how a local answer proves itself (every citation is
// checked against the file), when it goes on to Claude with its evidence, "Ask Claude", and the routing log.
import { test, after } from 'node:test';
import type { McpSdkServerConfigWithInstance } from '@anthropic-ai/claude-agent-sdk';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Annotations } from '../src/annotations.ts';
import type { Answered } from '../src/fleet.ts';
import type { Annotation, EventBody, HubEvent, Notes } from '../src/protocol.ts';
import { NoteQuestions, noteThread } from '../src/questions.ts';
import { RouteLog } from '../src/routelog.ts';
import { classify, route } from '../src/routing.ts';
import { brief, checkClaims, evidence, judge, locate, parseScout, present, scout, sentences, wordy, type ScoutRun } from '../src/scout.ts';
import { SideChats, type NoteAsk, type SideDeps } from '../src/sidechat.ts';

const dir = mkdtempSync(join(tmpdir(), 'duet-routing-'));
after(() => rmSync(dir, { recursive: true, force: true }));
const proj = join(dir, 'proj');
mkdirSync(join(proj, 'src'), { recursive: true });
writeFileSync(join(proj, 'src/fleet.ts'), [
  '// Fleet scheduler',
  'export function pickAuto(workers, size) {',
  '  const idle = workers.filter((w) => !w.running);',
  '  return idle[0];',
  '}',
].join('\n'));
writeFileSync(join(dir, 'secret.txt'), 'outside the project');

const good = (quote = 'const idle = workers.filter((w) => !w.running);', start = 3) => JSON.stringify({
  answer: 'It takes the first idle worker.',
  claims: [{ text: 'idle workers are the ones not running', file: 'src/fleet.ts', start, end: start, quote }],
  unknowns: [],
  confidence: 'high',
});
const reply = (result: string, worker = 'qwen-27b'): ScoutRun => ({ ok: true, result, worker });
const all = <T extends EventBody['type']>(events: EventBody[], type: T) => events.filter((e): e is Extract<EventBody, { type: T }> => e.type === type);
const until = async (ok: () => boolean) => {
  for (let i = 0; i < 400 && !ok(); i++) await new Promise((r) => setTimeout(r, 5));
  assert.ok(ok(), 'it never happened');
};

// ---- where a question goes ----

test('questions about the code go to a local model; judgment, outside knowledge and the conversation go to Claude', () => {
  assert.equal(classify('Where is pickAuto defined?'), 'locate');
  assert.equal(classify('What does this mean?'), 'explain');
  assert.equal(classify('Walk me through what happens when a task is delegated'), 'trace');
  assert.equal(classify('Should we refactor this into two functions?'), 'design');
  assert.equal(classify('Why does this crash when the queue is empty?'), 'debug');
  assert.equal(classify("What's the latest version of node?"), 'external');
  assert.equal(classify('What did you change earlier?'), 'meta');
  assert.equal(classify("What's the next step in the plan?"), 'plan');

  const free = () => true, busy = () => false;
  assert.deepEqual(route('Where is pickAuto defined?', 'side', { localFree: free }), { to: 'local', cls: 'locate', size: 'small', why: 'finding something in the code' });
  assert.equal(route('What does this mean?', 'side', { localFree: busy }).why, 'the local models are busy', 'a side chat does not wait');
  assert.equal(route('What does this mean?', 'note', { localFree: busy }).to, 'local', 'a note waits its turn');
  assert.equal(route('What does this mean?', 'side', { localFree: free, picture: true }).to, 'claude');
  assert.equal(route('', 'note', { localFree: free }).to, 'claude', 'handwriting only: Claude reads the picture');
  assert.equal(route('Should we split this?', 'note', { localFree: free }).to, 'claude');
  assert.deepEqual(route('Where is it?', 'side', { localFree: free, forced: 'claude' }).why, 'you asked Claude');
});

// ---- how a local answer proves itself ----

test('a local answer is the JSON in its reply, fenced or not', () => {
  assert.equal(parseScout('Here you go:\n```json\n' + good() + '\n```')?.claims.length, 1);
  assert.equal(parseScout('no json here'), null);
  assert.equal(parseScout('{"claims": []}'), null, 'no answer');
  assert.equal(parseScout('{"answer": "x", "confidence": "sure"}')?.confidence, 'medium');
});

test('a quote is found by its code, whatever its whitespace, nearest the lines it was cited at', () => {
  const lines = readFileSync(join(proj, 'src/fleet.ts'), 'utf8').split('\n');
  assert.deepEqual(locate('const idle = workers.filter((w) => !w.running);', lines, 3), { start: 3, end: 3 });
  assert.deepEqual(locate('const idle = workers.filter((w) => !w.running);', lines, 40), { start: 3, end: 3 }, 'cited at the wrong line');
  assert.deepEqual(locate('const idle = workers.filter(\n      (w) => !w.running);\n  return idle[0];', lines, 3), { start: 3, end: 4 }, 'joined and re-indented');
  assert.equal(locate('const busy = workers.filter((w) => w.running);', lines, 3), null);
  assert.equal(locate('}', lines, 5), null, 'too short to mean anything');
});

test('each citation is checked against its file, inside the project only; line numbers a little off are corrected', () => {
  const s = parseScout(JSON.stringify({
    answer: 'x', confidence: 'high', unknowns: [],
    claims: [
      { text: 'right', file: 'src/fleet.ts', start: 3, end: 3, quote: 'const idle = workers.filter((w) => !w.running);' },
      { text: 'lines off', file: 'src/fleet.ts', start: 9, end: 9, quote: 'return idle[0];' },
      { text: 'no such file', file: 'src/nope.ts', start: 1, end: 1, quote: 'whatever it says' },
      { text: 'escapes', file: '../secret.txt', start: 1, end: 1, quote: 'outside the project' },
      { text: 'made up', file: 'src/fleet.ts', start: 2, end: 2, quote: 'export function pickBusy(workers)' },
    ],
  }))!;
  const c = checkClaims(s, proj);
  assert.deepEqual(c.claims.map((k) => [k.text, k.start]), [['right', 3], ['lines off', 4]]);
  assert.equal(c.fixed, 1);
  assert.deepEqual(c.failed.map((f) => f.why), ["the file doesn't exist", 'it is outside the project folder', "that text isn't in the file"]);
  assert.deepEqual(judge(s, c), { pass: false, why: "3 of its 5 citations didn't match the files", repairable: true });
});

test("an answer counts only when it cites the code, every citation holds, and it's confident with nothing left open", () => {
  const ok = parseScout(good())!;
  assert.deepEqual(judge(ok, checkClaims(ok, proj)), { pass: true });
  const none = parseScout('{"answer": "It just works.", "claims": [], "confidence": "high"}')!;
  assert.equal(judge(none, checkClaims(none, proj)).pass, false);
  const unsure = parseScout(JSON.stringify({ ...JSON.parse(good()), confidence: 'low' }))!;
  assert.match((judge(unsure, checkClaims(unsure, proj)) as { why: string }).why, /wasn't confident/);
  const open = parseScout(JSON.stringify({ ...JSON.parse(good()), unknowns: ['who calls it'] }))!;
  assert.match((judge(open, checkClaims(open, proj)) as { why: string }).why, /couldn't settle: who calls it/);
  assert.equal(judge(null, null).pass, false);
});

test('a local answer whose citations are off gets one more try; then it goes to Claude with what checked out', async () => {
  const fixed = [reply(good('const idle = workers.filter((w) => w.idle);')), reply(good())];
  const prompts: string[] = [];
  const once = await scout(async (p) => { prompts.push(p); return fixed.shift()!; }, { question: 'What does pickAuto return?' }, proj);
  assert.equal(once.verdict.pass, true);
  assert.equal(once.tries, 2);
  assert.match(prompts[1], /cited lines that didn't match the files/);

  const stubborn = await scout(async () => reply(good('const idle = workers.filter((w) => w.idle);')), { question: 'What does pickAuto return?' }, proj);
  assert.equal(stubborn.verdict.pass, false);
  assert.equal(stubborn.tries, 2);
  assert.match(evidence(stubborn), /didn't count because 1 of its 1 citations didn't match the files/);
  assert.match(evidence(stubborn), /Its draft \(unverified\):\nIt takes the first idle worker\./);

  const prose = await scout(async () => reply('I think it returns the first worker.'), { question: 'What does pickAuto return?' }, proj);
  assert.equal(prose.tries, 1, 'nothing to repair');
  assert.equal(prose.verdict.pass, false);

  const shown = present(once.scouted!, once.checked!);
  assert.deepEqual([shown.text, shown.more], ['It takes the first idle worker.\n\nChecked against `src/fleet.ts:3`.', undefined]);
});

test('an answer as shown: headings go, lists become points, sentences split outside code, each source listed once', () => {
  assert.deepEqual(sentences('It calls `a.b()`. Then e.g. this one. Done!'), ['It calls `a.b()`.', 'Then e.g. this one.', 'Done!']);
  const s = parseScout(JSON.stringify({ ...JSON.parse(good()), answer: '## Answer\nIt takes the first idle worker.\n\n- one\n- two\n\nA last paragraph.', more: '- three\n4. four' }))!;
  assert.deepEqual(s.more, ['three', 'four'], 'points as one string, a point per line');
  assert.deepEqual(brief(s), { answer: 'It takes the first idle worker.', more: ['one', 'two', 'A last paragraph.', 'three', 'four'], trimmed: true });
  const listy = parseScout(JSON.stringify({ ...JSON.parse(good()), answer: '1. First it filters.\n2. Then it picks one.' }))!;
  assert.deepEqual(brief(listy), { answer: 'First it filters.', more: ['Then it picks one.'], trimmed: true });
  const c = { claims: [3, 3, 4, 2, 5, 1].map((n) => ({ text: '', file: 'src/fleet.ts', start: n, end: n, quote: 'x' })), failed: [], fixed: 0 };
  assert.match(present(parseScout(good())!, c).text, /Checked against `src\/fleet\.ts:3`, `src\/fleet\.ts:4`, `src\/fleet\.ts:2`, `src\/fleet\.ts:5` and 1 more\.$/);
});

// ---- notes ----

function noteDesk(answers: string[]) {
  const events: EventBody[] = [];
  const state = mkdtempSync(join(dir, 'state-'));
  const annotations = new Annotations(state, (e) => events.push(e));
  // Notes' threads: opened on demand (its answer, if any, already on the note); Claude answers when a test calls `done`.
  const threads = { opened: [] as { id: string; answer?: string }[], claude: [] as { chatId: string; text: string; o: NoteAsk }[] };
  const notices: string[] = [];
  const routes = new RouteLog(state);
  const desk = new NoteQuestions({
    annotations,
    ask: async (): Promise<Answered> => ({ taskId: 't-1', worker: 'qwen-27b', state: 'done', result: answers.shift() ?? '', output: '' }),
    threads: {
      open: (a) => {
        if (a.chatId) return a.chatId;
        threads.opened.push({ id: a.id, ...(a.answer ? { answer: a.answer } : {}) });
        annotations.thread(a.id, `th-${a.id}`);
        return `th-${a.id}`;
      },
      busy: () => false,
      claude: (chatId, text, o) => { threads.claude.push({ chatId, text, o }); },
    },
    notice: (t) => notices.push(t),
    cwd: () => proj,
    routes,
    log: () => {},
  });
  const logged = () => readFileSync(routes.path, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  return { desk, annotations, threads, notices, logged };
}
const surface = { kind: 'file' as const, path: join(proj, 'src/fleet.ts') };
const question = { id: 'n1', intent: 'question' as const, text: 'What does this return?', lines: [{ file: 'src/fleet.ts', start: 4, end: 4, code: 'return idle[0];' }] };

test("a question on code is answered by a local model when its citations check out, and Claude hears about it", async () => {
  const d = noteDesk([good()]);
  d.annotations.add('ipad', surface, [question]);
  assert.deepEqual(d.desk.local(surface, [question, { id: 'n2', intent: 'change', text: 'rename this' }, { id: 'n3', intent: 'question', text: 'Should we split this?' }]).map((n) => n.id), ['n1'],
    'only questions about the code: a change, or a design question, goes to Claude');
  await d.desk.answer('ipad', surface, question);
  const a = d.annotations.get('n1')!;
  assert.deepEqual([a.status, a.route, a.answeredBy, a.checked], ['answered', 'local', 'qwen-27b', { claims: 1, failed: 0 }]);
  assert.match(a.answer ?? '', /It takes the first idle worker\.\n\nChecked against `src\/fleet\.ts:3`\./);
  assert.equal(d.threads.claude.length, 0, 'Claude spent nothing on it');
  assert.match(d.notices[0], /Meanwhile qwen-27b answered the user's note on src\/fleet\.ts:4 \("What does this return\?"\)/);
  assert.deepEqual(d.logged().map((e) => [e.surface, e.cls, e.outcome, e.worker]), [['note', 'explain', 'local', 'qwen-27b']]);

  // "Ask Claude": Claude checks the local answer in the note's thread (opened while the note still had that answer, so
  // the thread starts with it), and both answers are kept.
  d.desk.reroute('n1', 'ipad');
  const b = d.annotations.get('n1')!;
  assert.deepEqual([b.status, b.route, b.answering, b.escalated, b.chatId], ['open', 'claude', 'Claude', 'you asked Claude', 'th-n1']);
  assert.match(d.threads.opened[0].answer ?? '', /It takes the first idle worker/, 'the thread starts with the local answer');
  assert.match(b.localAnswer ?? '', /It takes the first idle worker/);
  assert.deepEqual([b.answer, b.answeredBy, b.checked], [undefined, undefined, undefined], "while Claude works, the local answer isn't shown as Claude's");
  assert.equal(d.threads.claude[0].chatId, 'th-n1');
  assert.match(d.threads.claude[0].text, /^\[Handwritten notes from ipad on the file .*\n1\. Question about src\/fleet\.ts:4/s);
  assert.match(d.threads.claude[0].o.extra ?? '', /qwen-27b answered this note first, and the user asked you to check it/);
  assert.equal(d.logged().at(-1).outcome, 'override');
});

test('"Ask Claude" on a note answered a while ago: Claude answers, the local answer stays beside it, and the time counts from the ask', async () => {
  const d = noteDesk([]);
  const ev = (seq: number, body: EventBody) => ({ seq, ts: 0, ...body }) as HubEvent;
  d.annotations.seed([ev(1, { type: 'annotation', annotation: {
    ...question, surface, by: 'ipad', ts: Date.now() - 600_000, status: 'answered', answer: 'It takes the first idle worker.', answeredBy: 'qwen-27b', route: 'local', checked: { claims: 1, failed: 0 }, ms: 4000,
  } })]);
  d.desk.reroute('n1', 'ipad');
  d.threads.claude[0].o.done({ text: 'Yes: the first idle worker, or undefined when none is idle.', diagrams: ['g-1'] });
  const a = d.annotations.get('n1')!;
  assert.deepEqual([a.status, a.answeredBy, a.route, a.answer, a.localAnswer, a.diagrams], ['answered', 'Claude', 'claude', 'Yes: the first idle worker, or undefined when none is idle.', 'It takes the first idle worker.', ['g-1']]);
  assert.ok((a.ms ?? Infinity) < 60_000, `timed from the ask, not from when the note was written ten minutes ago (${a.ms} ms)`);
  assert.match(d.notices.at(-1) ?? '', /Meanwhile Claude answered the user's note on src\/fleet\.ts:4 in the note's thread/, 'the conversation hears about it');
});

test('a long answer gets one more try to shorten it, and whatever still runs over goes under "More"', async () => {
  const long = `It takes the first idle worker. ${'A worker that is running is skipped, so a busy one never gets a second task. '.repeat(5)}`.trim();
  const draft = (answer: string, more: string[] = []) => JSON.stringify({ ...JSON.parse(good()), answer, more });
  const broken = JSON.stringify({ ...JSON.parse(good('nowhere in the file at all')), answer: 'Short.' });
  assert.deepEqual([wordy(parseScout(draft(long))!), wordy(parseScout(good())!)], [true, false]);

  // It passed but ran long: one more try with the limits spelled out, and the shorter answer replaces it.
  const prompts: string[] = [];
  const replies = [reply(draft(long)), reply(draft('It takes the first idle worker.', ['A running worker is skipped.']))];
  const shorter = await scout(async (p) => { prompts.push(p); return replies.shift()!; }, { question: 'What does pickAuto return?' }, proj);
  assert.equal(shorter.tries, 2);
  assert.match(prompts[1], /too long to read at a glance \(\d+ words\)/);
  assert.doesNotMatch(prompts[1], /didn't match the files/);
  assert.deepEqual([shorter.scouted?.answer, shorter.scouted?.more], ['It takes the first idle worker.', ['A running worker is skipped.']]);

  // A shorter retry that breaks its citations doesn't replace the answer that passed: the hub cuts that one instead.
  const kept = [reply(draft(long)), reply(broken)];
  const cut = await scout(async () => kept.shift()!, { question: 'What does pickAuto return?' }, proj);
  assert.deepEqual([cut.verdict.pass, cut.scouted?.answer], [true, long]);
  const shown = present(cut.scouted!, cut.checked!);
  assert.ok(shown.trimmed && shown.words <= 65, `${shown.words} words`);
  assert.match(shown.text, /^It takes the first idle worker\. A worker that is running is skipped[^\n]*\n\nChecked against `src\/fleet\.ts:3`\.$/);
  assert.match(shown.more ?? '', /^- A worker that is running is skipped/);

  // On a note: the card gets the short answer, "More" the rest, and the log how long it was and that it was cut.
  const d = noteDesk([draft(long), broken]);
  d.annotations.add('ipad', surface, [question]);
  await d.desk.answer('ipad', surface, question);
  const a = d.annotations.get('n1')!;
  assert.match(a.answer ?? '', /^It takes the first idle worker\./);
  assert.match(a.more ?? '', /^- A worker that is running is skipped/);
  assert.deepEqual([d.logged()[0].trimmed, d.logged()[0].words <= 65], [true, true]);
});

test("a local answer that doesn't check out goes to Claude with its evidence, and the note says why", async () => {
  const bad = good('const idle = workers.filter((w) => w.idle);');
  const d = noteDesk([bad, bad]);
  d.annotations.add('ipad', surface, [question]);
  await d.desk.answer('ipad', surface, question);
  const a = d.annotations.get('n1')!;
  assert.deepEqual([a.status, a.route, a.answering, a.chatId], ['open', 'claude', 'Claude', 'th-n1']);
  assert.match(a.escalated ?? '', /citations didn't match the files/);
  // Claude answers in the note's thread, with the evidence, not in the conversation.
  assert.equal(d.threads.claude.length, 1);
  assert.match(d.threads.claude[0].text, /^\[Handwritten notes from ipad on the file .*\n1\. Question about src\/fleet\.ts:4/s);
  assert.match(d.threads.claude[0].o.extra ?? '', /\[duet\] A local model \(qwen-27b\) looked into this first/);
  assert.match(d.threads.claude[0].o.extra ?? '', /The user hasn't seen its draft, so answer them directly, without mentioning it\./);
  assert.deepEqual(d.logged().map((e) => [e.outcome, e.tries]), [['escalated', 2]]);
});

test("a question a local model isn't for goes straight to Claude in the note's thread, with the picture; a failure says so", () => {
  const d = noteDesk([]);
  const design = { id: 'n4', intent: 'question' as const, text: 'Should we split this?', lines: question.lines };
  d.annotations.add('ipad', surface, [design]);
  d.desk.direct('ipad', [design], { data: 'PIXEL', type: 'image/png' });
  const a = d.annotations.get('n4')!;
  assert.deepEqual([a.route, a.answering, a.escalated, a.chatId], ['claude', 'Claude', 'it comes with a picture', 'th-n4']);
  assert.deepEqual([d.threads.claude[0].o.image?.data, d.threads.claude[0].o.escalated], ['PIXEL', 'it comes with a picture']);
  assert.match(d.threads.claude[0].text, /The attached image shows the ink\./);
  assert.deepEqual(d.logged().map((e) => [e.outcome, e.cls]), [['claude', 'design']]);
  d.threads.claude[0].o.failed?.('rate limited');
  const b = d.annotations.get('n4')!;
  assert.deepEqual([b.status, b.answering], ['open', undefined]);
  assert.match(b.escalated ?? '', /it comes with a picture; Claude couldn't answer \(rate limited\)/);
});

// ---- side chats ----

function sideDesk(local: { answers: string[]; free?: boolean }, opts: { diagrams?: boolean } = {}) {
  const events: EventBody[] = [];
  const state = mkdtempSync(join(dir, 'side-'));
  const routes = new RouteLog(state);
  const claude: { prompt: string; model: unknown; allowed: string[]; mcp: boolean }[] = [];
  const deps: Partial<SideDeps> = {
    getSessionMessages: (async () => []) as unknown as SideDeps['getSessionMessages'],
    forkSession: (async () => ({ sessionId: 'fork-1' })) as unknown as SideDeps['forkSession'],
    query: ((args: { prompt: AsyncIterable<{ message: { content: unknown } }>; options: Record<string, unknown> }) => (async function* () {
      let prompt = '';
      for await (const m of args.prompt) prompt = JSON.stringify(m.message.content);
      claude.push({ prompt, model: args.options.model, allowed: args.options.allowedTools as string[], mcp: !!args.options.mcpServers });
      yield { type: 'system', subtype: 'init', session_id: 'claude-1' };
      yield { type: 'assistant', parent_tool_use_id: null, message: { id: `msg-${claude.length}`, content: [{ type: 'text', text: "Claude's answer." }] } };
      yield { type: 'result', subtype: 'success' };
    })()) as unknown as SideDeps['query'],
  };
  const sides = new SideChats({
    source: () => ({ sessionId: 'conv-1', transcribed: true, busy: false, cwd: proj }), env: () => ({}), log: () => {}, deps, routes,
    local: { ask: async () => reply(local.answers.shift() ?? ''), free: () => local.free ?? true, cancel: () => {} },
    ...(opts.diagrams ? { diagrams: () => ({ type: 'sdk', name: 'duet' }) as unknown as McpSdkServerConfigWithInstance } : {}),
  }, (e) => events.push(e));
  const settled = (chatId: string, n: number) => until(() => all(events, 'side_chat').filter((e) => e.chatId === chatId && e.state !== 'answering').length >= n);
  const answers = (chatId: string) => all(events, 'side_message').filter((m) => m.chatId === chatId && m.role === 'assistant');
  const logged = () => readFileSync(routes.path, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  return { sides, events, claude, settled, answers, logged };
}

test('a side chat question about the code is answered locally when it checks out; "Ask Claude" sends it on', async () => {
  const s = sideDesk({ answers: [good()] });
  const id = s.sides.ask('mac', { text: 'What does pickAuto return?' });
  await s.settled(id, 1);
  const [mine] = s.answers(id);
  assert.deepEqual([mine.local, mine.model, mine.checked], [true, 'qwen-27b', { claims: 1, failed: 0 }]);
  assert.match(mine.text, /It takes the first idle worker\.\n\nChecked against `src\/fleet\.ts:3`\./);
  assert.equal(s.claude.length, 0);

  s.sides.reroute('mac', id);
  await s.settled(id, 2);
  assert.equal(s.claude.length, 1);
  assert.equal(s.claude[0].model, 'sonnet');
  assert.match(s.claude[0].prompt, /qwen-27b answered the question below in this side chat, and the user asked you to check it/);
  assert.equal(s.answers(id).at(-1)!.escalated, 'you asked Claude');
  assert.deepEqual(s.logged().map((e) => e.outcome), ['local', 'override']);

  // Claude has the thread now: a follow-up stays with it.
  s.sides.ask('mac', { chatId: id, text: 'Where is it defined?' });
  await s.settled(id, 3);
  assert.equal(s.claude.length, 2);
});

test("a local side chat answer that doesn't check out goes to Sonnet with its evidence", async () => {
  const bad = good('const idle = workers.filter((w) => w.idle);');
  const s = sideDesk({ answers: [bad, bad] });
  const id = s.sides.ask('mac', { text: 'What does pickAuto return?' });
  await s.settled(id, 1);
  assert.equal(s.claude.length, 1);
  assert.equal(s.claude[0].model, 'sonnet');
  assert.match(s.claude[0].prompt, /A local model \(qwen-27b\) looked into this first/);
  const [answer] = s.answers(id);
  assert.match(answer.escalated ?? '', /citations didn't match/);
  assert.equal(answer.local, undefined);
});

test('busy local models, a picked model, a picture or a question needing judgment go straight to Claude', async () => {
  const busy = sideDesk({ answers: [], free: false });
  const a = busy.sides.ask('mac', { text: 'What does pickAuto return?' });
  await busy.settled(a, 1);
  assert.equal(busy.claude[0].model, 'haiku', 'a quick question waits for nobody: Haiku answers');

  const picked = sideDesk({ answers: [good()] });
  const b = picked.sides.ask('mac', { text: 'What does pickAuto return?', model: 'opus' });
  await picked.settled(b, 1);
  assert.equal(picked.claude[0].model, 'opus');

  const design = sideDesk({ answers: [good()] });
  const c = design.sides.ask('mac', { text: 'Should we refactor pickAuto?' });
  await design.settled(c, 1);
  assert.equal(design.claude[0].model, 'sonnet');
  assert.deepEqual(design.logged().map((e) => [e.cls, e.outcome]), [['design', 'claude']]);
});

// ---- a note's thread ----

const answeredNote: Annotation = {
  ...question, surface, by: 'ipad', ts: 1, status: 'answered', ink: true, answeredBy: 'qwen-27b', route: 'local', checked: { claims: 1, failed: 0 }, ms: 4000,
  answer: 'It takes the first idle worker.\n\nChecked against `src/fleet.ts:3`.', more: '- A running worker is skipped.',
};

test("a note on the plan opens a thread about the steps it was written on", () => {
  const plan = { kind: 'plan' as const, conversationId: 'conv-0' };
  const one = noteThread({ ...answeredNote, surface: plan, lines: undefined, elements: [{ id: '3', label: 'Refactor the lexer' }] }, 'conv-0', () => undefined);
  assert.deepEqual([one.title, one.about], ['Note on step 3 “Refactor the lexer” of the plan', { kind: 'text', label: 'step 3 “Refactor the lexer” of the plan', text: '3. Refactor the lexer' }]);
  const two = noteThread({ ...answeredNote, surface: plan, lines: undefined, elements: [{ id: '2', label: 'Wire it' }, { id: '3', label: 'Test it' }] }, 'conv-0', () => undefined);
  assert.deepEqual(two.about, { kind: 'text', label: 'steps 2, 3 of the plan', text: '2. Wire it\n3. Test it' });
  assert.equal(noteThread({ ...answeredNote, surface: plan, lines: undefined, elements: undefined }, 'conv-0', () => undefined).title, 'Note on the plan');
});

test("a note's thread is about where the note was written: the file's lines, a diagram's elements, a diff's lines", () => {
  const t = noteThread(answeredNote, 'conv-0', () => undefined);
  assert.deepEqual([t.about, t.title, t.question, t.ink, t.conversationId], [{ kind: 'file', path: 'src/fleet.ts', start: 4, end: 4 }, 'Note on src/fleet.ts:4', 'What does this return?', true, 'conv-0']);
  assert.deepEqual(t.answer, { text: answeredNote.answer, model: 'qwen-27b', local: true, checked: { claims: 1, failed: 0 }, ms: 4000, more: '- A running worker is skipped.' });
  const lexer = (id: string) => (id === 'g-1' ? { title: 'Lexer states', source: 'stateDiagram-v2\n  Start --> InString' } : undefined);
  const onDiagram = noteThread({ ...answeredNote, surface: { kind: 'diagram', diagramId: 'g-1', title: 'Old title' }, lines: undefined, elements: [{ id: 'InString', label: 'InString' }] }, undefined, lexer);
  assert.deepEqual(onDiagram.about, { kind: 'text', label: '“InString” in the diagram “Lexer states”', text: 'stateDiagram-v2\n  Start --> InString' });
  const onDiff = noteThread({ ...answeredNote, surface: { kind: 'diff', taskId: 't-1', worker: 'qwen-27b' }, lines: [{ file: 'a.py', start: 3, end: 5, code: 'x = 1' }] }, undefined, () => undefined);
  assert.deepEqual(onDiff.about, { kind: 'text', label: "a.py:3-5 in qwen-27b's change for task t-1", text: 'a.py:3-5\nx = 1' });
});

test("a reply to a note goes on in its thread: a side chat that starts with the note, answered like any follow-up", async () => {
  const s = sideDesk({ answers: [good()] });
  const id = s.sides.thread(noteThread(answeredNote, 'conv-0', () => undefined));
  // It starts with the note's own question (with its ink) and answer, marked as the note's, in the note's conversation.
  const seeded = all(s.events, 'side_message').filter((m) => m.chatId === id);
  assert.deepEqual(seeded.map((m) => [m.role, m.fromNote, m.image ?? false]), [['user', true, true], ['assistant', true, false]]);
  assert.deepEqual([seeded[1].local, seeded[1].model, seeded[1].more], [true, 'qwen-27b', '- A running worker is skipped.']);
  const opened = all(s.events, 'side_chat').find((e) => e.chatId === id)!;
  assert.deepEqual([opened.annotationId, opened.conversationId, opened.about], ['n1', 'conv-0', { kind: 'file', path: 'src/fleet.ts', start: 4, end: 4 }]);
  // The reply: a local model first, with the note's exchange as context.
  s.sides.ask('ipad', { chatId: id, text: 'Why the first one?' });
  await s.settled(id, 2);
  assert.match(s.answers(id).at(-1)!.text, /^It takes the first idle worker\./);
  assert.equal(s.claude.length, 0);
  // After a restart it's still the note's thread, with the note's answer as context.
  const again = sideDesk({ answers: [] });
  again.sides.seed(s.events);
  assert.equal(again.sides.has(id), true);
  again.sides.reroute('ipad', id);
  await again.settled(id, 1);
  assert.match(again.claude[0].prompt, /Earlier in this side chat:\\nQ: What does this return\?\\nA \(qwen-27b\): It takes the first idle worker/);
});

test("\"Ask Claude\" in a note's thread checks the note's own answer; deleting the note deletes its thread everywhere", async () => {
  const s = sideDesk({ answers: [] });
  const id = s.sides.thread(noteThread(answeredNote, undefined, () => undefined));
  s.sides.reroute('ipad', id);
  await s.settled(id, 2);
  assert.match(s.claude[0].prompt, /qwen-27b answered the question below in this side chat, and the user asked you to check it/);
  assert.match(s.claude[0].prompt, /It takes the first idle worker/);
  s.sides.remove(id);
  const gone = all(s.events, 'side_chat').at(-1)!;
  assert.deepEqual([gone.chatId, gone.deleted, gone.annotationId, s.sides.has(id)], [id, true, 'n1', false]);
  const restarted = sideDesk({ answers: [] });
  restarted.sides.seed(s.events);
  assert.equal(restarted.sides.has(id), false, 'gone after a restart too');
});

test("Claude answers a note's own question in its thread: marked as the note's, able to draw, and kept on the note", async () => {
  const s = sideDesk({ answers: [] }, { diagrams: true });
  const open: Annotation = { ...question, surface, by: 'ipad', ts: 1, status: 'open' };
  const id = s.sides.thread(noteThread(open, 'conv-0', () => undefined));
  let kept: { text: string; diagrams: string[] } | undefined;
  s.sides.answerNote(id, '[Handwritten notes from ipad on the file x]\n1. Question about src/fleet.ts:4: "What does this return?"', { escalated: 'a design question', done: (r) => { kept = r; } });
  await s.settled(id, 2);
  assert.match(s.claude[0].prompt, /\[A note, answered in its own thread beside our conversation/);
  assert.match(s.claude[0].prompt, /Question about src\/fleet\.ts:4/);
  assert.ok(s.claude[0].allowed.includes('mcp__duet__diagram') && s.claude[0].mcp, 'it can draw a diagram');
  const answer = s.answers(id).at(-1)!;
  assert.deepEqual([answer.fromNote, answer.escalated, answer.model], [true, 'a design question', 'sonnet']);
  assert.deepEqual(kept, { text: "Claude's answer.", diagrams: [] });
  // A reply after that stays with Claude, which has the thread now, and isn't the note's own answer.
  s.sides.ask('ipad', { chatId: id, text: 'And when the list is empty?' });
  await s.settled(id, 3);
  assert.equal(s.answers(id).at(-1)!.fromNote, undefined);
  assert.equal(s.claude[1].mcp, false, 'only the note\'s own answer draws');
});
