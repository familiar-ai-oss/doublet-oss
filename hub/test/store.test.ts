// The event log stamps every conversation-scoped event with the live conversation, unless the emitter knew better.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { EventLog } from '../src/store.ts';

test('append tags events with the current conversation, keeps a given one, and leaves hub-wide events bare', () => {
  const dir = mkdtempSync(join(tmpdir(), 'duet-store-'));
  try {
    const log = new EventLog(dir);
    let current: string | undefined;
    log.conversation = () => current;
    // Before the lead has a session: nothing to tag with.
    assert.equal('conversationId' in log.append({ type: 'notice', text: 'hello' }), false);
    current = 'c1';
    assert.equal(log.append({ type: 'turn_start', turn: 1 }).conversationId, 'c1');
    // A worker task that started in an earlier conversation keeps it.
    assert.equal(log.append({ type: 'task', taskId: 't-1', worker: 'qwen-9b', state: 'done', conversationId: 'c0' }).conversationId, 'c0');
    // Hub-wide events are not tagged by default; lead_info names the live conversation itself.
    assert.equal('conversationId' in log.append({ type: 'fleet', workers: [] }), false);
    assert.equal(log.append({ type: 'lead_info', model: 'm', effort: null, models: [], conversationId: 'c1' }).conversationId, 'c1');
    // Sequence numbers are unaffected, and a reopened log reads the tags back.
    assert.deepEqual(log.since(0).map((e) => e.seq), [1, 2, 3, 4, 5]);
    const again = new EventLog(dir);
    assert.deepEqual(again.since(0).map((e) => e.conversationId), [undefined, 'c1', 'c0', undefined, 'c1']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
