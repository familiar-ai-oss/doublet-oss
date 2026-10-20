// The user's devices: which exist (their tokens), which are online, when each was last seen, what each is and what each
// has open; and places sent from one to another, which reach only that device, and wait for it until it has them.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Devices, kindOf } from '../src/devices.ts';
import type { ServerFrame } from '../src/protocol.ts';

const dirs: string[] = [];
after(() => { for (const d of dirs) rmSync(d, { recursive: true, force: true }); });
const stateFile = () => {
  const d = mkdtempSync(join(tmpdir(), 'duet-devices-'));
  dirs.push(d);
  return join(d, 'devices.json');
};

/** A connection, and the frames it was sent. */
const conn = () => {
  const got: ServerFrame[] = [];
  return { got, send: (f: ServerFrame) => got.push(f) };
};
const lists = (c: ReturnType<typeof conn>) => c.got.flatMap((f) => (f.type === 'devices' ? [f.devices.map((d) => [d.device, d.online])] : []));
const sent = (c: ReturnType<typeof conn>) => c.got.flatMap((f) => (f.type === 'place_sent' ? [f] : []));

test('every device with a token is listed, online or not, with what it is: from its hello, else its name', () => {
  const d = new Devices(stateFile(), () => ['mac', 'ipad', 'test', 'studio'], () => {});
  assert.deepEqual(d.list(), [
    { device: 'ipad', online: false, kind: 'ipad' },
    { device: 'mac', online: false, kind: 'mac' },
    { device: 'studio', online: false },
    { device: 'test', online: false },
  ]);
  d.connected('studio', conn().send, 'mac');
  d.connected('test', conn().send, 'toaster');
  const studio = d.list().find((x) => x.device === 'studio')!;
  assert.deepEqual([studio.online, studio.kind, typeof studio.lastSeen], [true, 'mac', 'number']);
  assert.equal(d.list().find((x) => x.device === 'test')!.kind, undefined, 'not a kind of device');
  assert.deepEqual(['mac', 'MacBook-Air', 'ipad-pro', 'iPhone', 'cli'].map(kindOf), ['mac', 'mac', 'ipad', 'iphone', undefined]);
});

test('the others hear when a device comes or goes; the one connecting gets the list in its welcome instead', () => {
  const d = new Devices(stateFile(), () => ['mac', 'ipad'], () => {});
  const mac = conn();
  d.connected('mac', mac.send);
  assert.deepEqual(mac.got, [], 'nothing before its welcome');
  const ipad = conn();
  d.connected('ipad', ipad.send);
  assert.deepEqual([ipad.got, lists(mac)], [[], [[['ipad', true], ['mac', true]]]]);
  d.disconnected('ipad', ipad.send);
  assert.deepEqual(lists(mac).at(-1), [['ipad', false], ['mac', true]]);
  assert.equal(ipad.got.length, 0, 'not the one that left');
  // Another window's worth of the Mac: still online when the first closes.
  const mac2 = conn();
  d.connected('mac', mac2.send);
  d.disconnected('mac', mac.send);
  assert.equal(d.online('mac'), true);
});

test('a place goes only to the device it was sent to, to each of its connections', () => {
  const d = new Devices(stateFile(), () => ['mac', 'ipad', 'iphone'], () => {});
  const mac = conn(), ipad = conn(), ipad2 = conn(), phone = conn();
  for (const [name, c] of [['mac', mac], ['ipad', ipad], ['ipad', ipad2], ['iphone', phone]] as const) d.connected(name, c.send);
  const place = { file: { path: '/p/Lexer.swift', line: 27 } };
  const r = d.sendPlace('mac', 'ipad', place, '  Lexer.swift ');
  assert.equal(r.queued, false);
  for (const c of [ipad, ipad2]) assert.deepEqual(sent(c).map((f) => ({ ...f, ts: 0 })), [{ type: 'place_sent', id: r.id, from: 'mac', to: 'ipad', place, title: 'Lexer.swift', ts: 0 }]);
  assert.deepEqual([sent(mac).length, sent(phone).length], [0, 0], 'never broadcast');
  assert.throws(() => d.sendPlace('mac', 'mac', place, 'x'), /that's this device/);
  assert.throws(() => d.sendPlace('mac', 'toaster', place, 'x'), /no device called toaster/);
  assert.throws(() => d.sendPlace('mac', 'ipad', undefined, 'x'), /nothing to send/);
  assert.throws(() => d.sendPlace('mac', 'ipad', { big: 'x'.repeat(70_000) }, 'x'), /too big/);
});

test("one sent to a device that's away waits for it (the last one only), across a hub restart, until after its replay", () => {
  const file = stateFile();
  const d = new Devices(file, () => ['mac', 'ipad'], () => {});
  d.connected('mac', conn().send);
  assert.equal(d.sendPlace('mac', 'ipad', { first: 1 }, 'First').queued, true);
  const second = d.sendPlace('mac', 'ipad', { second: 2 }, 'Second');
  assert.equal(second.queued, true);
  // The hub restarts; the iPad connects, and once it has caught up, the last one sent is waiting.
  const again = new Devices(file, () => ['mac', 'ipad'], () => {});
  const ipad = conn();
  again.connected('ipad', ipad.send);
  assert.equal(sent(ipad).length, 0, 'not before its welcome and replay');
  again.deliverWaiting('ipad', ipad.send);
  assert.deepEqual(sent(ipad).map((f) => [f.id, f.from, f.title, f.place]), [[second.id, 'mac', 'Second', { second: 2 }]]);
  // It comes again on the next hello until the app says it has it; an id it isn't waiting on changes nothing.
  const next = conn();
  again.connected('ipad', next.send);
  again.deliverWaiting('ipad', next.send);
  assert.deepEqual(sent(next).map((f) => f.id), [second.id]);
  again.seen('ipad', 'another');
  again.seen('mac', second.id);
  again.seen('ipad', second.id);
  const later = conn();
  again.connected('ipad', later.send);
  again.deliverWaiting('ipad', later.send);
  assert.equal(sent(later).length, 0, 'not once it has it');
  // When a device was last seen survives a restart too, token or not.
  assert.equal(typeof new Devices(file, () => [], () => {}).list().find((x) => x.device === 'mac')?.lastSeen, 'number');
});

test('a place sent to a device that went to sleep comes again when it next connects, until the app there has it', () => {
  const d = new Devices(stateFile(), () => ['mac', 'ipad'], () => {});
  const mac = conn(), asleep = conn();
  d.connected('mac', mac.send);
  d.connected('ipad', asleep.send);
  // iPadOS suspended Duet; its connection hasn't closed yet, so the place goes nowhere.
  const r = d.sendPlace('mac', 'ipad', { diagram: { _0: 'g1' } }, 'Lexer states');
  assert.equal(r.queued, false);
  d.disconnected('ipad', asleep.send);
  const awake = conn();
  d.connected('ipad', awake.send);
  d.deliverWaiting('ipad', awake.send);
  assert.deepEqual(sent(awake).map((f) => f.id), [r.id]);
  d.seen('ipad', r.id);
  d.deliverWaiting('ipad', awake.send);
  assert.equal(sent(awake).length, 1, 'not again once it has it');
});

test('a place sent to write on says so; any other is plain', () => {
  const d = new Devices(stateFile(), () => ['mac', 'ipad'], () => {});
  const ipad = conn();
  d.connected('ipad', ipad.send);
  d.sendPlace('mac', 'ipad', { file: { _0: '/p/Lexer.swift', line: 27 } }, 'Lexer.swift:27', true);
  d.sendPlace('mac', 'ipad', { diagram: { _0: 'g1' } }, 'Lexer states', 'yes');
  assert.deepEqual(sent(ipad).map((f) => [f.title, f.write]), [['Lexer.swift:27', true], ['Lexer states', undefined]]);
  assert.equal('write' in sent(ipad)[1], false);
});

test('what a device has open reaches the others in the device list, and a device connecting later in its welcome', () => {
  const file = stateFile();
  const d = new Devices(file, () => ['mac', 'ipad'], () => {});
  const mac = conn(), ipad = conn();
  d.connected('mac', mac.send);
  d.connected('ipad', ipad.send);
  const before = [mac.got.length, ipad.got.length];
  const places = [{ place: { file: { _0: '/p/Lexer.swift', line: 27 } }, title: ' Lexer.swift ' }, { place: { diagram: { _0: 'g1' } }, title: 'Lexer states' }];
  d.report('ipad', places, 1, ipad.send);
  assert.equal(ipad.got.length, before[1], 'not told back what it said');
  const heard = mac.got.slice(before[0]);
  assert.equal(heard.length, 1);
  const open = heard[0].type === 'devices' ? heard[0].devices.find((x) => x.device === 'ipad')?.open : undefined;
  assert.deepEqual({ ...open, ts: 0 }, { places: [{ ...places[0], title: 'Lexer.swift' }, places[1]], current: 1, ts: 0 });
  // The Mac connects again after a hub restart: its list (its welcome) has the iPad's places.
  const again = new Devices(file, () => ['mac', 'ipad'], () => {});
  assert.deepEqual(again.list().find((x) => x.device === 'ipad')?.open?.places.map((p) => p.title), ['Lexer.swift', 'Lexer states']);
  assert.equal(again.list().find((x) => x.device === 'mac')?.open, undefined, 'the Mac said nothing');
  // The same again (a reconnect) isn't news: no list goes out.
  const heardBefore = mac.got.length;
  d.report('ipad', places, 1, ipad.send);
  assert.equal(mac.got.length, heardBefore);
  // A current that isn't one of them is no current; nothing open is a list too.
  d.report('ipad', places, 7);
  assert.equal(d.list().find((x) => x.device === 'ipad')?.open?.current, undefined);
  d.report('ipad', []);
  assert.deepEqual(d.list().find((x) => x.device === 'ipad')?.open?.places, []);
  assert.throws(() => d.report('ipad', 'Lexer.swift'), /must be a list/);
  assert.throws(() => d.report('ipad', [{ title: 'Nothing' }]), /missing/);
  // Dozens of tabs fit; it's the whole that's capped, since it goes out in every list and welcome.
  d.report('ipad', Array.from({ length: 60 }, (_, i) => ({ place: { file: { _0: `/p/File${i}.swift`, line: i } }, title: `File${i}.swift` })));
  assert.equal(d.list().find((x) => x.device === 'ipad')?.open?.places.length, 60);
  assert.throws(() => d.report('ipad', Array.from({ length: 200 }, () => ({ place: { big: 'x'.repeat(400) }, title: 'x' }))), /too big/);
});

test('a place nobody picked up in a day is dropped, not opened when the device comes back', () => {
  const file = stateFile();
  const d = new Devices(file, () => ['mac', 'ipad'], () => {});
  const r = d.sendPlace('mac', 'ipad', { diagram: { _0: 'g1' } }, 'Lexer states');
  assert.equal(r.queued, true);
  // A day and more go by (the saved time, moved back).
  const saved = JSON.parse(readFileSync(file, 'utf8'));
  saved.waiting.ipad.ts -= 25 * 3600 * 1000;
  writeFileSync(file, JSON.stringify(saved));
  const later = new Devices(file, () => ['mac', 'ipad'], () => {});
  const ipad = conn();
  later.connected('ipad', ipad.send);
  later.deliverWaiting('ipad', ipad.send);
  assert.equal(sent(ipad).length, 0);
  assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')).waiting, {}, 'and forgotten');
});
