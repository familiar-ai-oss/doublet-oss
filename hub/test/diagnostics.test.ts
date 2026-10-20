// Crash and freeze reports from the devices (diagnostics.ts), without a hub: kept once per device and id, listed,
// cut when huge, pruned when many, and refused when they aren't reports.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Diagnostics, describeDiagnostics, MAX_PAYLOAD, MAX_REPORTS } from '../src/diagnostics.ts';

const fresh = () => mkdtempSync(join(tmpdir(), 'duet-diag-'));

test('a report is kept once, with its context and payload, and listed', () => {
  const dir = fresh();
  try {
    const d = new Diagnostics(dir);
    const r = { id: 'f-1', kind: 'freeze' as const, summary: 'Freeze 2.9 s on the conversation', durationMs: 2903.6, context: { place: 'lead' }, payload: '{"x":1}', build: '0.1 (1)' };
    assert.deepEqual(d.add('ipad', r), { kept: true });
    assert.deepEqual(d.add('ipad', r), { kept: false }, 'the same report again (a lost ack) is kept once');
    assert.deepEqual(d.add('mac', r), { kept: true }, 'another device may use the same id');
    const list = d.list();
    assert.equal(list.length, 2);
    assert.equal(list[0].durationMs, 2904);
    assert.equal(list[0].device, 'ipad');
    const saved = JSON.parse(readFileSync(join(d.dir, list[0].file), 'utf8'));
    assert.deepEqual(saved.context, { place: 'lead' });
    assert.equal(saved.payload, '{"x":1}');
    assert.match(describeDiagnostics(list), /ipad\s+freeze Freeze 2\.9 s/);
    // A new hub process remembers what it kept.
    assert.deepEqual(new Diagnostics(dir).add('ipad', r), { kept: false });
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('a huge payload is cut, and the oldest reports go past the limit', () => {
  const dir = fresh();
  try {
    const d = new Diagnostics(dir);
    d.add('ipad', { id: 'big', kind: 'hang', summary: 'Hang 4 s', payload: 'x'.repeat(MAX_PAYLOAD + 10) });
    assert.equal(d.list()[0].truncated, true);
    for (let i = 0; i < MAX_REPORTS + 5; i++) d.add('ipad', { id: `n${i}`, kind: 'freeze', summary: `Freeze ${i}` });
    assert.equal(readdirSync(d.dir).length, MAX_REPORTS);
    assert.equal(d.list().length, MAX_REPORTS);
    assert.equal(d.list().at(-1)!.id, `n${MAX_REPORTS + 4}`);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('what isn\'t a report is refused', () => {
  const dir = fresh();
  try {
    const d = new Diagnostics(dir);
    assert.throws(() => d.add('ipad', { id: 'a', kind: 'nope' as never, summary: 's' }), /unknown diagnostic kind/);
    assert.throws(() => d.add('ipad', { id: '../etc', kind: 'crash', summary: 's' }), /needs an id/);
    assert.throws(() => d.add('ipad', { id: 'a', kind: 'crash', summary: ' ' }), /needs a summary/);
    assert.equal(d.list().length, 0);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
