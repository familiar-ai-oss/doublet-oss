// A note's answer is what Claude said in reply, not its narration on the way ("Let me read the action…").
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Annotations } from '../src/annotations.ts';
import type { EventBody, HubEvent } from '../src/protocol.ts';

const ev = (seq: number, body: EventBody) => ({ seq, ts: 0, ...body }) as HubEvent;
const read = { id: 'u1', name: 'Read', input: { file_path: '/p/action.yml' } };

test("a note's answer leaves out what Claude said while it worked", async () => {
  const dir = mkdtempSync(join(tmpdir(), 'duet-ann-'));
  try {
    const a = new Annotations(dir, () => {});
    a.add('ipad', { kind: 'file', path: '/p/verify.yml' }, [{ id: 'q1', intent: 'question', text: 'What does this mean?' }]);
    a.taken(['q1'], 3);
    a.onEvent(ev(1, { type: 'turn_start', turn: 3 }));
    a.onEvent(ev(2, { type: 'assistant', turn: 3, text: "Let me read the action's definition.", toolUses: [read] }));
    a.onEvent(ev(3, { type: 'assistant', turn: 3, text: 'It pins which release CI downloads.', toolUses: [] }));
    a.onEvent(ev(4, { type: 'turn_end', turn: 3, subtype: 'success', isError: false, interrupted: false }));
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(a.get('q1')!.answer, 'It pins which release CI downloads.');

    // Only narration (it ended on a tool call): that's still all there is to show.
    a.add('ipad', { kind: 'file', path: '/p/verify.yml' }, [{ id: 'q2', intent: 'question', text: 'And this?' }]);
    a.taken(['q2'], 4);
    a.onEvent(ev(5, { type: 'turn_start', turn: 4 }));
    a.onEvent(ev(6, { type: 'assistant', turn: 4, text: 'Checking the workflow.', toolUses: [read] }));
    a.onEvent(ev(7, { type: 'turn_end', turn: 4, subtype: 'success', isError: false, interrupted: false }));
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(a.get('q2')!.answer, 'Checking the workflow.');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
