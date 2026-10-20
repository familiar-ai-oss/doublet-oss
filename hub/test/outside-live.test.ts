// Live on the hub machine: a Claude Code session started outside Duet (print mode kept open, as a terminal or the desktop app
// keeps a session) shows in the hub's list within seconds, is followed live from its transcript, and is continued here:
// as a fork while it still runs there, and as itself once it has ended. The hub lists print-mode sessions only for this
// test (DUET_OUTSIDE_PROGRAMMATIC); real use lists the desktop app's and terminals' sessions.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import type { OutsideMessage, OutsideSession } from '../src/protocol.ts';
import { createHarness } from './harness.ts';

const h = createHarness('outside', { DUET_OUTSIDE_PROGRAMMATIC: '1' });
const { client, next } = h;
const project = mkdtempSync(join(tmpdir(), 'duet-outside-'));
after(() => {
  h.cleanup();
  rmSync(project, { recursive: true, force: true });
  // Its transcripts (the session and the fork) are this test's own.
  rmSync(join(homedir(), '.claude/projects', project.replace(/[^A-Za-z0-9]/g, '-')), { recursive: true, force: true });
});

const lists: OutsideSession[][] = [];
const mirrored: OutsideMessage[] = [];
client.on('control', (f: { type: string; sessions?: OutsideSession[]; messages?: OutsideMessage[] }) => {
  if (f.type === 'outside_sessions' && f.sessions) lists.push(f.sessions);
  if (f.type === 'outside_messages' && f.messages) mirrored.push(...f.messages);
});
const until = async (ok: () => boolean, what: string, ms = 60_000) => {
  for (const t0 = Date.now(); !ok(); await new Promise((r) => setTimeout(r, 100))) if (Date.now() - t0 > ms) assert.fail(`timed out: ${what}`);
};
// Found by its folder first, then by its id (Duet's own sessions there show too while this test lists print-mode ones).
const listed = (id?: string) => lists.at(-1)?.find((s) => (id ? s.sessionId === id : s.cwd === project));

test('a session started outside Duet is listed, followed live, and continued here', async () => {
  await h.startHub();
  await client.connect();
  await next('session', (e) => e.state === 'ready');
  // The outside session, kept open between prompts.
  const outside = spawn('claude', ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--model', 'claude-haiku-5-5'], { cwd: project, stdio: ['pipe', 'pipe', 'inherit'] });
  let out = '';
  const results: (() => void)[] = [];
  outside.stdout.on('data', (d) => {
    out += d;
    for (let i = out.indexOf('\n'); i >= 0; i = out.indexOf('\n')) {
      const line = out.slice(0, i);
      out = out.slice(i + 1);
      try { if (JSON.parse(line).type === 'result') results.shift()?.(); } catch { /* partial */ }
    }
  });
  const ask = (text: string) => new Promise<void>((resolve) => {
    results.push(resolve);
    outside.stdin.write(`${JSON.stringify({ type: 'user', message: { role: 'user', content: text } })}\n`);
  });
  const t0 = Date.now();
  await ask('Remember the code word OKAPI. Reply with just: noted.');
  await until(() => !!listed(), 'listed');
  const s = listed()!;
  console.log(`  listed after ${((Date.now() - t0) / 1000).toFixed(1)} s: ${s.name} (${s.where}, ${s.status})`);
  assert.equal(s.live, true);

  // Followed: its conversation so far, then each new message as it lands.
  const f = await client.send({ type: 'outside_follow', sessionId: s.sessionId });
  assert.deepEqual(f.messages?.map((m) => m.role), ['user', 'assistant']);
  assert.match(f.messages?.[0].text ?? '', /OKAPI/);
  const asked = Date.now();
  await ask('Also remember PANGOLIN. Reply with just: noted.');
  await until(() => mirrored.some((m) => m.role === 'assistant'), 'mirrored');
  console.log(`  mirrored ${mirrored.length} new messages, the last ${((Date.now() - asked) / 1000).toFixed(1)} s after it was asked`);
  assert.match(mirrored.find((m) => m.role === 'user')?.text ?? '', /PANGOLIN/);

  // Continued here while it still runs: a fork, its last messages carried over, and Claude remembers.
  const c1 = await client.send({ type: 'outside_continue', sessionId: s.sessionId });
  assert.equal(c1.forked, true);
  assert.notEqual(c1.sessionId, s.sessionId);
  const imported = await next('conversation_import', (e) => e.conversationId === c1.sessionId);
  assert.equal(imported.from.sessionId, s.sessionId);
  assert.ok(imported.messages.some((m) => /PANGOLIN/.test(m.text)), 'its last messages come along');
  const from = h.events.length;
  await client.send({ type: 'prompt', text: 'What were the two code words? Reply with just the two words, comma-separated.' });
  const done = await next('turn_end', () => true, from, 300_000);
  const said = h.all('assistant', (e) => e.turn === done.turn).map((e) => e.text).join(' ');
  console.log(`  continued as a fork: ${said.trim().slice(0, 80)}`);
  assert.match(said, /OKAPI/i);
  assert.match(said, /PANGOLIN/i);

  // Once it has ended there, the list says so, and continuing resumes the session itself.
  outside.stdin.end();
  await new Promise((r) => outside.on('exit', r));
  await until(() => listed(s.sessionId)?.live === false, 'ended');
  const c2 = await client.send({ type: 'outside_continue', sessionId: s.sessionId });
  assert.deepEqual([c2.forked, c2.sessionId], [false, s.sessionId]);
  await until(() => !listed(s.sessionId), 'it leaves the list once continued here');
});
