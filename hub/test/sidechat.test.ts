// Side chats and explorer watching, without models:
//  1. A side chat copies the conversation up to Claude's last reply (all of it between turns), answers read-only in
//     that copy, streams its answer, and continues the same copy on a follow-up.
//  2. The explorer's folders are watched: a change is reported once things settle.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { lastReply, notePrompt, SIDE_ALLOWED, SIDE_DIAGRAM, SIDE_TOOLS, SIDE_VOICE, SideChats, sidePrompt, type ForkSource, type SideDeps } from '../src/sidechat.ts';
import { ANSWER_FIRST } from '../src/notes.ts';
import type { EventBody } from '../src/protocol.ts';
import { FolderWatch } from '../src/watch.ts';

type Ev<T extends EventBody['type']> = Extract<EventBody, { type: T }>;
const of = <T extends EventBody['type']>(events: EventBody[], type: T) => events.filter((e): e is Ev<T> => e.type === type);

const transcript = [
  { type: 'user', uuid: 'u1', parent_tool_use_id: null, message: { role: 'user', content: 'Refactor the parser' } },
  { type: 'assistant', uuid: 'a1', parent_tool_use_id: null, message: { role: 'assistant', content: [{ type: 'text', text: 'Done: tokens carry ranges.' }] } },
  { type: 'user', uuid: 'u2', parent_tool_use_id: null, message: { role: 'user', content: 'Now add tests' } },
  { type: 'assistant', uuid: 'a2', parent_tool_use_id: null, message: { role: 'assistant', content: [{ type: 'text', text: 'On it.' }, { type: 'tool_use', id: 't', name: 'Read', input: {} }] } },
  { type: 'assistant', uuid: 's1', parent_tool_use_id: 'toolu_x', message: { role: 'assistant', content: [{ type: 'text', text: "a subagent's words" }] } },
];

/** A stand-in for Claude: records what it was asked, answers in a few streamed words, and stops when aborted. */
function fakes(answer = 'It picks the idle worker.') {
  const calls: { prompt: unknown; options: Record<string, unknown> }[] = [];
  const forks: { id: string; upTo?: string }[] = [];
  let release: () => void = () => {};
  let hold = false;
  const deps: Partial<SideDeps> = {
    getSessionMessages: (async () => transcript) as unknown as SideDeps['getSessionMessages'],
    forkSession: (async (id: string, o?: { upToMessageId?: string }) => { forks.push({ id, upTo: o?.upToMessageId }); return { sessionId: `fork-${forks.length}` }; }) as unknown as SideDeps['forkSession'],
    query: ((args: { prompt: AsyncIterable<{ message: { content: unknown } }>; options: Record<string, unknown> }) => {
      const run = async function* () {
        let prompt: unknown;
        for await (const m of args.prompt) prompt = m.message.content;
        calls.push({ prompt, options: args.options });
        yield { type: 'system', subtype: 'init', session_id: (args.options.resume as string) ?? 'new-session' };
        if (hold) {
          await new Promise<void>((resolve, reject) => {
            release = resolve;
            (args.options.abortController as AbortController).signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
          });
        }
        yield { type: 'assistant', parent_tool_use_id: null, message: { id: 'msg_1', content: [{ type: 'tool_use', id: 't1', name: 'Read', input: { file_path: '/p/fleet.ts' } }] } };
        for (const word of answer.split(' ')) yield { type: 'stream_event', parent_tool_use_id: null, event: { type: 'content_block_delta', delta: { type: 'text_delta', text: `${word} ` } } };
        yield { type: 'assistant', parent_tool_use_id: null, message: { id: 'msg_2', content: [{ type: 'text', text: answer }] } };
        yield { type: 'result', subtype: 'success' };
      };
      return run();
    }) as unknown as SideDeps['query'],
  };
  return { deps, calls, forks, holdNext: () => { hold = true; }, release: () => release() };
}

function setup(source: Partial<ForkSource> = {}, answer?: string) {
  const events: EventBody[] = [];
  const f = fakes(answer);
  const src: ForkSource = { sessionId: 'conv-1', transcribed: true, busy: false, cwd: tmpdir(), ...source };
  const sides = new SideChats({ source: () => src, env: () => ({}), log: () => {}, deps: f.deps }, (e) => events.push(e));
  const settled = async (chatId: string, n = 1) => {
    for (let i = 0; i < 200; i++) {
      if (of(events, 'side_chat').filter((e) => e.chatId === chatId && e.state !== 'answering').length >= n) return;
      await new Promise((r) => setTimeout(r, 5));
    }
    throw new Error('the side chat never finished');
  };
  return { sides, events, src, settled, ...f };
}

test("the copy ends at Claude's last finished reply: never inside a turn or a subagent's words", () => {
  assert.deepEqual(lastReply(transcript), { uuid: 'a1', last: false });
  assert.deepEqual(lastReply(transcript.slice(0, 2)), { uuid: 'a1', last: true });
  assert.equal(lastReply(transcript.slice(0, 1)), null, 'no reply yet');
});

test('the first question says what a side chat is, what it is about, and how much of the conversation it has', () => {
  const p = sidePrompt('mac', 'Why two GPUs?', { kind: 'file', path: '/p/fleet.ts', start: 12, end: 20 }, 'whole');
  assert.match(p, /^\[Side chat from mac: a quick question beside our conversation\. Nothing here goes into the conversation itself/);
  assert.match(p, /\n\nAbout the file \/p\/fleet\.ts, lines 12-20\.\n\nWhy two GPUs\?$/);
  assert.match(sidePrompt('ipad', 'And this?', { kind: 'text', label: "qwen-27b's result", text: 'Finished: 3 files' }, 'before_turn'), /up to your last reply.*\n\nAbout qwen-27b's result:\nFinished: 3 files\n\nAnd this\?$/s);
  assert.match(sidePrompt('mac', 'Hi', undefined, 'none'), /There's no conversation to go on yet/);
});

test('a side chat, with no diagram tool, is told a ```mermaid block is drawn (it once said it could not draw and gave source)', () => {
  assert.match(SIDE_DIAGRAM, /```mermaid block: Doublet draws it as a diagram/);
  assert.ok(sidePrompt('mac', 'Make a diagram of the attempts', undefined, 'whole').includes(SIDE_DIAGRAM));
  assert.ok(!notePrompt('Draw it', 'whole').includes(SIDE_DIAGRAM), "a note's thread draws with the tool");
});

test('answers start with the answer itself, in one short paragraph, so a device can show it alone (a sticky note)', () => {
  assert.match(ANSWER_FIRST, /one paragraph of at most 65 words; then, after a blank line, any detail/);
  assert.ok(sidePrompt('mac', 'Why two GPUs?', undefined, 'whole').includes(ANSWER_FIRST), 'a side chat');
  assert.ok(notePrompt('Question about step 3: "why?"', 'whole').includes(ANSWER_FIRST), "a note's thread");
});

test('a side chat answers read-only in a copy of the conversation, streams, and keeps to the conversation it was asked in', async () => {
  const s = setup();
  const id = s.sides.ask('mac', { text: 'How does auto pick?', about: { kind: 'file', path: '/p/fleet.ts' } });
  await s.settled(id);
  assert.deepEqual(s.forks, [{ id: 'conv-1', upTo: 'a1' }]);
  const opts = s.calls[0].options;
  assert.deepEqual([opts.resume, opts.tools, opts.allowedTools, opts.permissionMode, opts.model, opts.cwd], ['fork-1', SIDE_TOOLS, SIDE_ALLOWED, 'dontAsk', 'haiku', tmpdir()]);
  assert.ok(!SIDE_ALLOWED.includes('WebFetch') && SIDE_ALLOWED.includes('WebFetch(domain:developer.apple.com)'), 'pages open on documentation sites only');
  assert.match(String(s.calls[0].prompt), /^\[Side chat from mac.*\n\nAbout the file \/p\/fleet\.ts\.\n\nHow does auto pick\?$/s);
  const chat = of(s.events, 'side_chat');
  assert.deepEqual(chat.map((e) => [e.state, e.activity ?? null]), [['answering', 'Reading the conversation'], ['answering', 'Read /p/fleet.ts'], ['idle', null]]);
  assert.deepEqual([chat.at(-1)!.forked, chat.at(-1)!.sessionId, chat.at(-1)!.title], ['before_turn', 'fork-1', 'How does auto pick?']);
  const messages = of(s.events, 'side_message');
  assert.deepEqual(messages.map((m) => [m.role, m.text]), [['user', 'How does auto pick?'], ['assistant', 'It picks the idle worker.']]);
  assert.equal(of(s.events, 'side_delta').map((d) => d.text).join(''), 'It picks the idle worker. ');
  assert.ok(s.events.every((e) => e.conversationId === 'conv-1'), 'tagged with the conversation it was asked in');
});

test('a follow-up continues the same copy; a new chat between turns copies all of it; no conversation, no copy', async () => {
  const s = setup();
  const id = s.sides.ask('mac', { text: 'First' });
  await s.settled(id);
  s.sides.ask('ipad', { chatId: id, text: 'And then?', model: 'sonnet' });
  await s.settled(id, 2);
  // A follow-up is the question as typed, with the reminder of how an answer starts.
  assert.deepEqual([s.calls[1].options.resume, s.calls[1].options.model, s.calls[1].prompt], ['fork-1', 'sonnet', `[${ANSWER_FIRST}]\n\nAnd then?`]);
  assert.equal(s.forks.length, 1, 'no second copy');

  // Between turns, with Claude's last reply the transcript's last message: the copy has all of it.
  const idle = setup({ busy: false });
  idle.deps.getSessionMessages = (async () => transcript.slice(0, 2)) as unknown as SideDeps['getSessionMessages'];
  const sides = new SideChats({ source: () => idle.src, env: () => ({}), log: () => {}, deps: idle.deps }, (e) => idle.events.push(e));
  const wid = sides.ask('mac', { text: 'Q' });
  await idle.settled(wid);
  assert.equal(of(idle.events, 'side_chat').at(-1)!.forked, 'whole');

  const none = setup({ transcribed: false });
  const nid = none.sides.ask('mac', { text: 'Q' });
  await none.settled(nid);
  assert.equal(none.calls[0].options.resume, undefined);
  assert.equal(of(none.events, 'side_chat').at(-1)!.forked, 'none');
  assert.match(String(none.calls[0].prompt), /no conversation to go on yet/);
});

test("one question at a time per side chat, three side chats at once, and Stop ends one", async () => {
  const s = setup();
  s.holdNext();
  const id = s.sides.ask('mac', { text: 'Long one' });
  assert.throws(() => s.sides.ask('mac', { chatId: id, text: 'Again' }), /still answering/);
  s.sides.ask('mac', { text: 'Two' });
  s.sides.ask('mac', { text: 'Three' });
  assert.throws(() => s.sides.ask('mac', { text: 'Four' }), /3 side chats are answering already/);
  assert.throws(() => s.sides.ask('mac', { text: '  ' }), /empty question/);
  assert.throws(() => s.sides.ask('mac', { chatId: 'sc-nope', text: 'x' }), /no side chat sc-nope/);
  assert.throws(() => s.sides.ask('mac', { text: 'x', model: 'rm -rf' }), /not a model/);
  await new Promise((r) => setTimeout(r, 20));
  s.sides.stop(id);
  await s.settled(id);
  const last = of(s.events, 'side_chat').filter((e) => e.chatId === id).at(-1)!;
  assert.deepEqual([last.state, last.error], ['failed', 'Stopped.']);
  s.sides.stopAll();
});

test('after a restart, side chats continue from the log, and one cut off mid-answer says so', () => {
  const events: EventBody[] = [];
  const sides = new SideChats({ source: () => ({ sessionId: 'conv-2', transcribed: true, busy: false, cwd: tmpdir() }), env: () => ({}), log: () => {}, deps: fakes().deps }, (e) => events.push(e));
  sides.seed([
    { type: 'side_chat', chatId: 'sc-1', state: 'idle', title: 'Done one', model: 'haiku', by: 'mac', sessionId: 'S1', conversationId: 'conv-1' },
    { type: 'side_chat', chatId: 'sc-2', state: 'answering', title: 'Cut off', model: 'haiku', by: 'ipad', conversationId: 'conv-1' },
  ]);
  assert.deepEqual(events.map((e) => e.type === 'side_chat' && [e.chatId, e.state, e.error, e.conversationId]), [['sc-2', 'failed', 'The hub restarted while this was being answered. Ask again.', 'conv-1']]);
  assert.equal(sides.ask('mac', { chatId: 'sc-1', text: 'Follow-up' }), 'sc-1', 'a restored chat takes follow-ups');
  sides.stopAll();
});

test("the explorer's folders are watched: a change is reported once it settles, and only for folders it shows", async () => {
  const dir = mkdtempSync(join(tmpdir(), 'duet-watch-'));
  const other = mkdtempSync(join(tmpdir(), 'duet-watch-'));
  const seen: string[] = [];
  const w = new FolderWatch((p) => seen.push(p), 64, 50);
  try {
    w.set([dir, 'relative/ignored', join(dir, 'missing')]);
    assert.equal(w.size, 1, 'only absolute folders that exist');
    writeFileSync(join(dir, 'a.txt'), 'one');
    writeFileSync(join(dir, 'a.txt'), 'two');
    writeFileSync(join(other, 'b.txt'), 'not watched');
    for (let i = 0; i < 100 && !seen.length; i++) await new Promise((r) => setTimeout(r, 20));
    await new Promise((r) => setTimeout(r, 120));
    assert.deepEqual(seen, [dir], 'once, after the burst settles');
    w.set([other]);
    writeFileSync(join(dir, 'c.txt'), 'no longer watched');
    writeFileSync(join(other, 'd.txt'), 'now watched');
    for (let i = 0; i < 100 && seen.length < 2; i++) await new Promise((r) => setTimeout(r, 20));
    assert.deepEqual(seen, [dir, other]);
  } finally {
    w.close();
    rmSync(dir, { recursive: true, force: true });
    rmSync(other, { recursive: true, force: true });
  }
});

test('a question asked out loud says so, so the answer opens with what sounds right spoken; what you see is just your words', async () => {
  const s = setup();
  const id = s.sides.ask('iphone', { text: 'Why two GPUs?', voice: true });
  await s.settled(id);
  assert.ok(String(s.calls[0].prompt).startsWith(`${SIDE_VOICE}\n\n[Side chat from iphone`), 'before the side chat header');
  s.sides.ask('iphone', { chatId: id, text: 'And the small one?', voice: true });
  await s.settled(id, 2);
  assert.equal(s.calls[1].prompt, `${SIDE_VOICE}\n\nAnd the small one?`);
  s.sides.ask('mac', { chatId: id, text: 'Typed this time' });
  await s.settled(id, 3);
  assert.equal(s.calls[2].prompt, `[${ANSWER_FIRST}]\n\nTyped this time`);
  assert.deepEqual(of(s.events, 'side_message').filter((m) => m.role === 'user').map((m) => m.text), ['Why two GPUs?', 'And the small one?', 'Typed this time']);
});

test('a device can give a side chat a better name; every device gets it, note threads keep theirs', async () => {
  const s = setup();
  const id = s.sides.ask('mac', { text: 'Why does the hub use two GPUs for the lead and the workers, and what happens when one of them is busy?' });
  await s.settled(id);
  assert.equal(s.sides.retitle(id, '  Why the Hub Uses Two GPUs. '), true);
  const last = of(s.events, 'side_chat').at(-1)!;
  assert.deepEqual([last.chatId, last.title, last.state], [id, 'Why the Hub Uses Two GPUs', 'idle'], 'posted again as it was, with the name');
  assert.equal(s.sides.retitle(id, 'Why the Hub Uses Two GPUs'), false, 'the same name again');
  assert.throws(() => s.sides.retitle(id, 'one two three four five six seven eight nine'), /one to eight words/);
  assert.throws(() => s.sides.retitle('sc-none', 'A Name'), /no side chat/);
  const thread = s.sides.thread({ annotationId: 'n1', title: 'Note on a.ts:3', by: 'ipad', question: 'why?' } as never);
  assert.equal(s.sides.retitle(thread, 'Something Else'), false, "a note's thread is named after its note");
});
