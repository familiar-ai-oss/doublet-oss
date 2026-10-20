// Sessions started outside Duet: listed from Claude Code's registry of running sessions (and background ones from
// `claude agents`), noticed when they end, followed live from their transcripts, and continued here as a fork while
// they still run elsewhere, or as themselves once they've ended.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { appendFileSync, mkdirSync, mkdtempSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { alive, fromMessage, fromRecord, OutsideSessions, type OutsideSink } from '../src/outside.ts';
import type { OutsideMessage, OutsideSession } from '../src/protocol.ts';

const dirs: string[] = [];
after(() => { for (const d of dirs) rmSync(d, { recursive: true, force: true }); });

/** A Claude config folder with a registry; `register` writes a running session's entry. */
function claudeHome() {
  const home = mkdtempSync(join(tmpdir(), 'duet-outside-'));
  dirs.push(home);
  mkdirSync(join(home, 'sessions'));
  mkdirSync(join(home, 'projects'));
  // A session is listed once something has been said in it: its transcript, where Claude Code keeps it.
  const said = (sessionId: string, cwd: string) => {
    const folder = join(home, 'projects', cwd.replace(/[^A-Za-z0-9]/g, '-'));
    mkdirSync(folder, { recursive: true });
    appendFileSync(join(folder, `${sessionId}.jsonl`), '');
  };
  const register = (file: string, entry: { sessionId: string; cwd: string } & Record<string, unknown>, talked = true) => {
    writeFileSync(join(home, 'sessions', `${file}.json`), JSON.stringify(entry));
    if (talked) said(entry.sessionId, entry.cwd);
  };
  return { home, register, said };
}

/** A device: the lists it got, and the messages of what it follows. */
function device() {
  const lists: OutsideSession[][] = [];
  const got: { id: string; messages: OutsideMessage[] }[] = [];
  const sink: OutsideSink = { sessions: (l) => lists.push(l), messages: (id, messages) => got.push({ id, messages }) };
  return { sink, lists, got };
}

const until = async (ok: () => boolean, ms = 4000) => {
  for (const t0 = Date.now(); !ok() && Date.now() - t0 < ms;) await new Promise((r) => setTimeout(r, 25));
  assert.ok(ok(), 'it never happened');
};

const me = process.pid;
const gone = 2 ** 22 + 12345;

test('running sessions are listed from the registry: where each runs and whether it is busy; programmatic ones and our own are left out', async () => {
  const { home, register, said } = claudeHome();
  register('1', { pid: me, sessionId: 'desk-1', cwd: '/home/b/proj', entrypoint: 'claude-desktop', kind: 'interactive', status: 'busy', name: 'Chip findings', startedAt: 1 });
  register('2', { pid: me, sessionId: 'term-1', cwd: '/home/b/other', entrypoint: 'cli', kind: 'interactive', status: 'idle', startedAt: 2 });
  register('3', { pid: me, sessionId: 'sdk-1', cwd: '/home/b', entrypoint: 'sdk-ts', status: 'idle' });
  register('4', { pid: me, sessionId: 'lead-1', cwd: '/home/b', entrypoint: 'cli', status: 'idle' });
  register('5', { pid: gone, sessionId: 'dead-1', cwd: '/home/b', entrypoint: 'cli', status: 'idle' });
  // The same session in two processes: busy if either is.
  register('6', { pid: me, sessionId: 'term-1', cwd: '/home/b/other', entrypoint: 'cli', status: 'busy', startedAt: 2 });
  // A new desktop tab nobody has typed in yet: nothing to follow, so not listed.
  register('7', { pid: me, sessionId: 'empty-1', cwd: '/home/b/proj', entrypoint: 'claude-desktop', status: 'idle' }, false);
  said('bg-1', '/home/b/bg');
  const o = new OutsideSessions({ home, ours: (id) => id === 'lead-1', log: () => {}, agents: async () => [{ id: 'bg', sessionId: 'bg-1', cwd: '/home/b/bg', kind: 'background', state: 'blocked', name: 'corpus run' }] });
  o.start();
  try {
    await until(() => o.list().some((s) => s.sessionId === 'bg-1'));
    const by = Object.fromEntries(o.list().map((s) => [s.sessionId, [s.where, s.status, s.live, s.name]]));
    assert.deepEqual(by, {
      'desk-1': ['desktop', 'busy', true, 'Chip findings'],
      'term-1': ['terminal', 'busy', true, 'other'],
      'bg-1': ['background', 'blocked', true, 'corpus run'],
    });
  } finally {
    o.stop();
  }
});

test("a device gets the list at once and when it changes; a session that ends stays a day, until it's continued here", () => {
  const { home, register } = claudeHome();
  register('1', { pid: me, sessionId: 'desk-1', cwd: '/home/b/proj', entrypoint: 'claude-desktop', status: 'idle' });
  const o = new OutsideSessions({ home, ours: () => false, log: () => {}, agents: async () => [] });
  o.scan();
  const d = device();
  const detach = o.attach(d.sink);
  assert.equal(d.lists.length, 1);
  o.scan();
  assert.equal(d.lists.length, 1, 'nothing changed, so nothing is sent');
  register('1', { pid: me, sessionId: 'desk-1', cwd: '/home/b/proj', entrypoint: 'claude-desktop', status: 'busy' });
  o.scan();
  assert.equal(d.lists.at(-1)?.[0].status, 'busy');
  unlinkSync(join(home, 'sessions', '1.json'));
  o.scan();
  const ended = d.lists.at(-1)?.[0];
  assert.deepEqual([ended?.live, ended?.status, typeof ended?.endedAt], [false, 'ended', 'number']);
  o.continued('desk-1');
  assert.deepEqual(d.lists.at(-1), []);
  detach();
});

test('a session is followed live: its recent conversation first, then each message as its transcript gets it', async () => {
  const { home, register } = claudeHome();
  register('1', { pid: me, sessionId: 's-1', cwd: '/home/b/proj', entrypoint: 'cli', status: 'busy' });
  const transcript = join(home, 'projects', '-home-b-proj', 's-1.jsonl');
  const record = (r: Record<string, unknown>) => appendFileSync(transcript, `${JSON.stringify(r)}\n`);
  record({ type: 'user', uuid: 'u1', message: { role: 'user', content: 'Where is the lexer?' }, timestamp: '2026-10-18T10:00:00Z' });
  record({ type: 'assistant', uuid: 'a1', message: { content: [{ type: 'text', text: 'In src/lexer.ts.' }] }, timestamp: '2026-10-18T10:00:05Z' });
  const o = new OutsideSessions({
    home, ours: () => false, log: () => {}, agents: async () => [],
    // The SDK's resolved conversation: the main thread only (a subagent's message has a parent tool use).
    history: async () => [
      { type: 'user', uuid: 'u1', message: { content: 'Where is the lexer?' }, parent_tool_use_id: null },
      { type: 'assistant', uuid: 'sub', message: { content: [{ type: 'text', text: 'subagent work' }] }, parent_tool_use_id: 'toolu_1' },
      { type: 'assistant', uuid: 'a1', message: { content: [{ type: 'text', text: 'In src/lexer.ts.' }] }, parent_tool_use_id: null },
    ],
  });
  o.scan();
  const d = device();
  const first = await o.follow(d.sink, 's-1');
  assert.deepEqual(first.messages.map((m) => [m.role, m.text]), [['user', 'Where is the lexer?'], ['assistant', 'In src/lexer.ts.']]);
  assert.equal(first.session?.where, 'terminal');
  // Claude keeps working there: a tool call, its result (shown as the tool line), and the answer.
  record({ type: 'assistant', uuid: 'a2', message: { content: [{ type: 'text', text: 'Let me check.' }, { type: 'tool_use', name: 'Read', input: { file_path: 'src/lexer.ts' } }] } });
  record({ type: 'user', uuid: 'r2', message: { content: [{ type: 'tool_result', tool_use_id: 'x', content: '…' }] } });
  record({ type: 'assistant', uuid: 'a3', isSidechain: true, message: { content: [{ type: 'text', text: 'subagent' }] } });
  record({ type: 'assistant', uuid: 'a4', message: { content: [{ type: 'text', text: 'It tokenizes strings at line 27.' }] } });
  await until(() => d.got.flatMap((g) => g.messages).some((m) => m.uuid === 'a4'));
  const live = d.got.flatMap((g) => g.messages);
  assert.deepEqual(live.map((m) => [m.uuid, m.text, m.tools ?? []]), [['a2', 'Let me check.', ['Read src/lexer.ts']], ['a4', 'It tokenizes strings at line 27.', []]]);
  o.unfollow(d.sink, 's-1');
  record({ type: 'assistant', uuid: 'a5', message: { content: [{ type: 'text', text: 'after' }] } });
  await new Promise((r) => setTimeout(r, 1300));
  assert.ok(!d.got.flatMap((g) => g.messages).some((m) => m.uuid === 'a5'), 'nothing after unfollowing');
  o.stop();
});

test('continuing here: a fork while it still runs elsewhere, the session itself once it has ended', async () => {
  const { home, register } = claudeHome();
  register('1', { pid: me, sessionId: 'live-1', cwd: '/home/b/proj', entrypoint: 'claude-desktop', status: 'idle' });
  const forks: { id: string; dir?: string }[] = [];
  const o = new OutsideSessions({ home, ours: () => false, log: () => {}, agents: async () => [], fork: async (id, opts) => { forks.push({ id, dir: opts.dir }); return { sessionId: 'fork-1' }; } });
  o.scan();
  assert.deepEqual(await o.continueAs('live-1').then((c) => [c.sessionId, c.forked, c.from.name]), ['fork-1', true, 'proj']);
  assert.deepEqual(forks, [{ id: 'live-1', dir: '/home/b/proj' }]);
  unlinkSync(join(home, 'sessions', '1.json'));
  o.scan();
  assert.deepEqual(await o.continueAs('live-1').then((c) => [c.sessionId, c.forked]), ['live-1', false]);
  await assert.rejects(o.continueAs('nope'), /no session nope running outside Doublet/);
});

test('transcript records as messages: what was said and the tools reached for; tool results, subagents and meta left out', () => {
  assert.equal(alive(me), true);
  assert.equal(alive(gone), false);
  assert.deepEqual(fromRecord({ type: 'user', uuid: 'u', message: { content: [{ type: 'text', text: 'Look' }, { type: 'image' }] }, timestamp: '2026-10-18T10:00:00Z' }),
    { uuid: 'u', role: 'user', text: 'Look\n\n[a picture]', ts: Date.parse('2026-10-18T10:00:00Z') });
  assert.equal(fromRecord({ type: 'user', uuid: 'r', message: { content: [{ type: 'tool_result', content: 'x' }] } }), null);
  assert.equal(fromRecord({ type: 'user', uuid: 'm', isMeta: true, message: { content: 'x' } }), null);
  assert.equal(fromRecord({ type: 'assistant', uuid: 't', message: { content: [{ type: 'thinking', thinking: 'hmm' }] } }), null);
  assert.equal(fromRecord({ type: 'system', uuid: 's', subtype: 'turn_duration' }), null);
  assert.deepEqual(fromMessage('a', 'assistant', { content: [{ type: 'tool_use', name: 'Bash', input: { command: 'npm test' } }] }), { uuid: 'a', role: 'assistant', text: '', tools: ['Bash npm test'] });
});
