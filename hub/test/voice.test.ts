// Talk mode: a spoken prompt is marked as spoken, and Claude is told on that turn that its reply will be read aloud.
// Turns the hub starts itself (worker messages, late notes) follow your last prompt; a typed prompt ends it.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Lead, SPOKEN_NOTE, VOICE_GUIDANCE } from '../src/lead.ts';
import type { EventBody } from '../src/protocol.ts';
import { StateFile } from '../src/store.ts';

function setup() {
  const events: EventBody[] = [];
  const lead = new Lead({ model: 'haiku', effort: 'low', cwd: '/tmp', autoAllow: [], log: () => {} }, (e) => events.push(e), new StateFile('/nonexistent'), 0);
  const sent: string[] = [];
  lead['input'] = { push: (text: string) => sent.push(text) } as never;
  // One turn: dispatch the next prompt, run its UserPromptSubmit hook, then finish the turn.
  const turn = async () => {
    const out = (await lead['beforePrompt']({ hook_event_name: 'UserPromptSubmit', prompt: sent.at(-1) } as never, undefined, { signal: new AbortController().signal })) as {
      hookSpecificOutput?: { additionalContext?: string };
    };
    lead['busy'] = false;
    return out.hookSpecificOutput?.additionalContext ?? '';
  };
  return { lead, events, sent, turn };
}

test('a spoken prompt is marked as spoken, and Claude hears its reply will be read aloud on that turn only', async () => {
  const { lead, events, sent, turn } = setup();
  lead.submit('What does auto do?', 'iphone', false, { voice: true });
  assert.deepEqual(sent, [`What does auto do?\n\n${SPOKEN_NOTE}`], 'the words go to Claude as said, with the note after them');
  const user = events.find((e) => e.type === 'user');
  assert.equal(user?.type === 'user' && user.voice, true, 'the transcript shows it was spoken');
  assert.equal(await turn(), VOICE_GUIDANCE);

  assert.equal((events.find((e) => e.type === 'user') as { text: string }).text, 'What does auto do?', 'the transcript shows only what was said');
  lead.submit('Now in writing, please', 'mac');
  assert.equal(sent.at(-1), 'Now in writing, please');
  assert.ok(!('voice' in events.filter((e) => e.type === 'user').at(-1)!), 'a typed prompt carries no voice flag');
  assert.equal(await turn(), '', 'a typed prompt gets no voice guidance');
});

test("turns the hub starts itself follow the last prompt: read aloud after a spoken one, not after a typed one", async () => {
  const { lead, turn } = setup();
  lead.submit('Have the workers look into it', 'iphone', false, { voice: true });
  await turn();
  lead.submit('[duet] Worker messages are waiting.', 'duet');
  assert.match(await turn(), /Talk mode/, 'the reply to worker messages is read aloud too');

  lead.submit('Thanks, I will read the rest', 'mac');
  await turn();
  lead.submit('[duet] Worker messages are waiting.', 'duet');
  assert.equal(await turn(), '');
});

test('the voice guidance keeps the spoken part short, plain and honest', () => {
  assert.match(VOICE_GUIDANCE, /read aloud/);
  assert.match(VOICE_GUIDANCE, /one to three short, plain sentences/);
  assert.match(VOICE_GUIDANCE, /code blocks and tables are skipped/);
  assert.match(VOICE_GUIDANCE, /unsure/);
  assert.ok(VOICE_GUIDANCE.length < 600, 'a few lines a turn, not a page');
});
