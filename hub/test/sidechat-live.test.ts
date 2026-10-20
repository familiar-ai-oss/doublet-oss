// Side chats and the explorer against the real hub (the Max login; the side chat on Haiku): a side chat knows the
// conversation (it answers in a copy of it) yet adds nothing to it, and a follow-up continues the same copy; the
// explorer's folders are watched; Go to File lists the folder's files.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { ControlFrame } from '../src/protocol.ts';
import { createHarness } from './harness.ts';

const h = createHarness('side');
const { client, events, next, all } = h;
after(() => h.cleanup());

const settled = (chatId: string, from: number) => next('side_chat', (e) => e.chatId === chatId && e.state !== 'answering', from, 180_000);
const answers = (chatId: string) => all('side_message', (m) => m.chatId === chatId && m.role === 'assistant').map((m) => m.text);

test('a side chat knows the conversation, adds nothing to it, and a follow-up continues it', async () => {
  await h.startHub();
  await client.connect();
  await next('session', (e) => e.state === 'ready');
  const text = 'Remember this word for later: PINEAPPLE. Reply with just OK.';
  await client.send({ type: 'prompt', text });
  const turn = (await next('user', (e) => e.text === text)).turn;
  await next('turn_end', (e) => e.turn === turn, 0, 300_000);
  const prompts = all('user').length;

  let from = events.length;
  const t0 = Date.now();
  const chatId = (await client.send({ type: 'side_ask', text: 'Which word did I ask you to remember? Answer with the word only.' })).chatId!;
  assert.match(chatId, /^sc-/);
  const done = await settled(chatId, from);
  assert.equal(done.state, 'idle', done.error);
  assert.equal(done.forked, 'whole', 'a copy of all of it: Claude was between turns');
  assert.match(answers(chatId).join('\n'), /PINEAPPLE/i, 'it knows the conversation');
  assert.ok(all('side_delta', (d) => d.chatId === chatId).length > 0, 'the answer streamed');
  assert.equal(all('user').length, prompts, 'the conversation itself got no new turn');
  const first = Date.now() - t0;

  from = events.length;
  // Only the side chat's own earlier answer says which word: a follow-up that didn't continue it couldn't know.
  // (Not spelled backwards: models get letter games wrong now and then, and that isn't what's tested.)
  await client.send({ type: 'side_ask', chatId, text: 'Say that word again, all in lowercase, and nothing else.' });
  const again = await settled(chatId, from);
  assert.equal(again.state, 'idle', again.error);
  assert.match(answers(chatId).at(-1) ?? '', /\bpineapple\b/, 'the follow-up continues the same copy');
  assert.ok(events.filter((e) => e.type.startsWith('side_')).every((e) => e.conversationId === done.conversationId), 'all of it belongs to the conversation it was asked in');
  console.log(`  side chat: first answer in ${(first / 1000).toFixed(1)} s: ${answers(chatId).join(' / ').replace(/\n/g, ' ').slice(0, 120)}`);
});

test("the explorer's folders are watched, and Go to File lists the folder's files", async () => {
  const dir = join(h.projectDir, 'src');
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'a.ts'), 'export const a = 1;\n');
  const files = (await client.send({ type: 'fs_files', path: h.projectDir })).files ?? [];
  assert.ok(files.includes('src/a.ts'), `listed: ${files.join(', ')}`);
  const changed = new Promise<string>((resolve) => client.on('control', (f: ControlFrame) => { if (f.type === 'fs_changed') resolve(f.path); }));
  await client.send({ type: 'fs_watch', paths: [dir] });
  writeFileSync(join(dir, 'b.ts'), 'export const b = 2;\n');
  const path = await Promise.race([changed, new Promise<string>((_, reject) => setTimeout(() => reject(new Error('no fs_changed in 10 s')), 10_000))]);
  assert.equal(path, dir);
});
