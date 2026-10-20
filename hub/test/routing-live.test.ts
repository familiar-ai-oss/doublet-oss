// Questions routed for real, on the GPUs: a local model answers a side chat question and a note about a file, and
// every citation it gives is checked against the file. When it can't prove its answer, Claude answers instead and
// says why. Either way the answer says who gave it, and the routing log has it.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createHarness } from './harness.ts';

const h = createHarness('routing');
const { client, events, next, all } = h;
after(() => h.cleanup());

const code = [
  '// A tiny job queue.',
  'export type Job = { id: string; priority: number };',
  '',
  'const jobs: Job[] = [];',
  '',
  'export function enqueue(job: Job): void {',
  '  jobs.push(job);',
  '  jobs.sort((a, b) => b.priority - a.priority);',
  '}',
  '',
  '/** The next job to run: the highest priority, or null when there is none. */',
  'export function nextJob(): Job | null {',
  '  return jobs.shift() ?? null;',
  '}',
].join('\n');

test('a side chat question about the code goes to a local model, and its answer is checked or handed to Claude', async () => {
  mkdirSync(join(h.projectDir, 'src'), { recursive: true });
  writeFileSync(join(h.projectDir, 'src/queue.ts'), code);
  await h.startHub();
  await client.connect();
  await next('session', (e) => e.state === 'ready');
  const from = events.length;
  const t0 = Date.now();
  const chatId = (await client.send({ type: 'side_ask', text: 'Which function gives the next job to run, and what does it return when the queue is empty?' })).chatId!;
  const done = await next('side_chat', (e) => e.chatId === chatId && e.state !== 'answering', from, 900_000);
  assert.equal(done.state, 'idle', done.error);
  const answer = all('side_message', (m) => m.chatId === chatId && m.role === 'assistant').at(-1)!;
  console.log(`  side chat (${((Date.now() - t0) / 1000).toFixed(0)} s): ${answer.local ? `${answer.model}, ${answer.checked?.claims} citations checked` : `Claude (${answer.model}): ${answer.escalated}`}`);
  console.log(`  ${answer.text.replace(/\n/g, ' ').slice(0, 300)}`);
  assert.match(answer.text, /nextJob/);
  if (answer.local) {
    assert.ok((answer.checked?.claims ?? 0) >= 1, 'a local answer cites the code');
    assert.match(answer.text, /Checked against [^\n]*queue\.ts:1[0-4]/);
  } else {
    assert.ok(answer.escalated, 'a Claude answer says why it got the question');
  }
  const log = readFileSync(join(h.stateDir, 'routing.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.equal(log.at(-1).surface, 'side');
  assert.ok(['local', 'escalated'].includes(log.at(-1).outcome));
});

test('a question written on a line of code is answered by a local model when its citations check out', async () => {
  const from = events.length;
  const t0 = Date.now();
  const path = join(h.projectDir, 'src/queue.ts');
  await client.send({
    type: 'notes', surface: { kind: 'file', path },
    items: [{ id: 'live-q1', intent: 'question', text: 'What happens here when there are no jobs?', lines: [{ file: path, start: 13, end: 13, code: '  return jobs.shift() ?? null;' }] }],
  });
  const answered = await next('annotation', (e) => e.annotation.id === 'live-q1' && e.annotation.status === 'answered', from, 900_000);
  const a = answered.annotation;
  const log = readFileSync(join(h.stateDir, 'routing.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l)).filter((e) => e.id === 'live-q1').at(-1);
  console.log(`  note (${((Date.now() - t0) / 1000).toFixed(0)} s): ${a.route === 'local' ? `${a.answeredBy}, ${a.checked?.claims} citations checked, ${log.words} words, ${log.tries} tries` : `Claude: ${a.escalated}`}`);
  console.log(`  ${(a.answer ?? '').replace(/\n/g, ' ').slice(0, 300)}`);
  assert.match(a.answer ?? '', /null/);
  if (a.route === 'local') assert.ok((a.checked?.claims ?? 0) >= 1);
  else assert.ok(a.escalated, 'a note Claude answered says why');
  assert.ok(existsSync(join(h.stateDir, 'routing.jsonl')));
});

test('asked for plain words about a dense paragraph, the answer stays short: a sentence or two, the rest under More', async () => {
  const doc = [
    '# Duet',
    '',
    'Duet is a hub on a home server that runs one lead conversation with Claude on the Max login, streams every event to the iPhone, iPad and Mac over a sequenced WebSocket that resumes without gaps, hands mechanical work to local models on the GPUs through llmd with one task per worker and effort levels per model, checks every local answer against the files before it counts, and keeps handwritten notes, diagrams and side chats in an append-only log so every device sees the same state after a restart.',
  ].join('\n');
  const path = join(h.projectDir, 'README.md');
  writeFileSync(path, doc);
  const from = events.length;
  const t0 = Date.now();
  await client.send({
    type: 'notes', surface: { kind: 'file', path },
    items: [{ id: 'live-q2', intent: 'question', text: "Can you explain this in layman's terms?", lines: [{ file: path, start: 3, end: 3, code: doc.split('\n')[2] }] }],
  });
  const a = (await next('annotation', (e) => e.annotation.id === 'live-q2' && e.annotation.status === 'answered', from, 900_000)).annotation;
  const log = readFileSync(join(h.stateDir, 'routing.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l)).filter((e) => e.id === 'live-q2').at(-1);
  const said = (a.answer ?? '').split('\n\n')[0];
  const count = said.split(/\s+/).filter(Boolean).length;
  console.log(`  plain words (${((Date.now() - t0) / 1000).toFixed(0)} s): ${a.route === 'local' ? `${a.answeredBy}, ${log.words} words${log.trimmed ? ', cut by the hub' : ''}, ${log.tries} tries` : `Claude (${count} words): ${a.escalated}`}`);
  console.log(`  ${(a.answer ?? '').replace(/\n/g, ' ')}`);
  if (a.more) console.log(`  More: ${a.more.replace(/\n/g, ' ')}`);
  if (a.route === 'local') assert.ok(count <= 65, `${count} words`);
});

test('a reply to a note goes on in its thread, local first; deleting the note deletes the thread', async () => {
  const from = events.length;
  const t0 = Date.now();
  const chatId = (await client.send({ type: 'note_reply', id: 'live-q1', text: 'Why does it use ?? rather than ||?' })).chatId!;
  assert.ok(chatId, 'the ack carries the thread');
  await next('annotation', (e) => e.annotation.id === 'live-q1' && e.annotation.chatId === chatId, from);
  const reply = await next('side_message', (m) => m.chatId === chatId && m.role === 'assistant' && !m.fromNote, from, 900_000);
  const thread = all('side_message', (m) => m.chatId === chatId);
  assert.deepEqual(thread.slice(0, 2).map((m) => [m.role, m.fromNote]), [['user', true], ['assistant', true]], 'it starts with the note');
  assert.equal(all('side_chat', (e) => e.chatId === chatId).at(-1)?.annotationId, 'live-q1');
  console.log(`  thread reply (${((Date.now() - t0) / 1000).toFixed(0)} s): ${reply.local ? `${reply.model}, ${reply.checked?.claims} citations checked` : `Claude (${reply.model}): ${reply.escalated ?? ''}`}`);
  console.log(`  ${reply.text.replace(/\n/g, ' ').slice(0, 300)}`);
  await client.send({ type: 'annotation_update', id: 'live-q1', delete: true });
  await next('side_chat', (e) => e.chatId === chatId && e.deleted === true, from);
});
