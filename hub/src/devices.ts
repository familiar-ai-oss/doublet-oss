// The user's devices: each one a token was made for, which have the app connected now, when each was last seen, and
// what each has open (for the others' switchers, "On iPad"). A place sent from one device to another (Open on iPad,
// Open on Mac) goes only to that device. The last one sent to a device is kept until the app there says it has it (for
// a day at most), so one sent while the device is away, or just as it went to sleep with its connection not yet
// closed, reaches it when it next connects.
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import type { DeviceInfo, DeviceKind, OpenPlace, OpenPlaces, ServerFrame } from './protocol.ts';

export type PlaceSent = Extract<ServerFrame, { type: 'place_sent' }>;
type Send = (f: ServerFrame) => void;
type Saved = {
  lastSeen: Record<string, number>;
  kinds: Record<string, DeviceKind>;
  waiting: Record<string, PlaceSent>;
  open: Record<string, OpenPlaces>;
};

export const DEVICE_KINDS: readonly DeviceKind[] = ['mac', 'ipad', 'iphone'];
/** A sent place is the app's own description of a place (opaque here): small, so this is generous. */
const PLACE_MAX = 64 << 10;
/**
 * What a device has open, all of it: a place is a few hundred bytes, so this is dozens of tabs. It's kept in the
 * devices file and goes out in every device list and welcome, so it stays small.
 */
const OPEN_MAX = 64 << 10;
/** A place sent to a device that hasn't come back in a day is old news, not something to open when it does. */
const WAIT_MS = 24 * 3600 * 1000;

/** What a device is, from its name when its hello didn't say: "mac", "ipad-pro", "iphone". */
export function kindOf(name: string): DeviceKind | undefined {
  const n = name.toLowerCase();
  return n.includes('iphone') ? 'iphone' : n.includes('ipad') ? 'ipad' : n.includes('mac') ? 'mac' : undefined;
}

export class Devices {
  /** Each device's connections now (a Mac can have more than one). */
  private conns = new Map<string, Set<Send>>();
  private saved: Saved = { lastSeen: {}, kinds: {}, waiting: {}, open: {} };
  private file: string;
  private names: () => string[];
  private log: (m: string) => void;

  constructor(file: string, names: () => string[], log: (m: string) => void) {
    this.file = file;
    this.names = names;
    this.log = log;
    try {
      if (existsSync(file)) this.saved = { ...this.saved, ...JSON.parse(readFileSync(file, 'utf8')) };
    } catch (e) {
      log(`devices: ${file} unreadable, starting over (${e instanceof Error ? e.message : e})`);
    }
    if (this.expire()) this.save();
  }

  online(device: string): boolean {
    return (this.conns.get(device)?.size ?? 0) > 0;
  }

  /** Every device: those with tokens, and any seen since (a token removed later still shows until it's forgotten). */
  list(): DeviceInfo[] {
    const all = new Set([...this.names(), ...Object.keys(this.saved.lastSeen), ...this.conns.keys()]);
    return [...all].sort().map((device) => {
      const kind = this.saved.kinds[device] ?? kindOf(device);
      const lastSeen = this.saved.lastSeen[device];
      const open = this.saved.open[device];
      return { device, online: this.online(device), ...(lastSeen ? { lastSeen } : {}), ...(kind ? { kind } : {}), ...(open ? { open } : {}) };
    });
  }

  /**
   * A device connected (perhaps another window of it). The others are told; it learns the list from its welcome, so it
   * isn't sent one before that.
   */
  connected(device: string, send: Send, kind?: unknown): void {
    const set = this.conns.get(device) ?? new Set<Send>();
    set.add(send);
    this.conns.set(device, set);
    this.saved.lastSeen[device] = Date.now();
    if (typeof kind === 'string' && (DEVICE_KINDS as readonly string[]).includes(kind)) this.saved.kinds[device] = kind as DeviceKind;
    this.save();
    this.tell(send);
  }

  disconnected(device: string, send: Send): void {
    const set = this.conns.get(device);
    set?.delete(send);
    if (set && !set.size) this.conns.delete(device);
    this.saved.lastSeen[device] = Date.now();
    this.save();
    this.tell();
  }

  /** What was sent to this device and not yet seen there, once it's caught up (after its replay). */
  deliverWaiting(device: string, send: Send): void {
    if (this.expire()) this.save();
    const w = this.saved.waiting[device];
    if (w) send(w);
  }

  /**
   * A place for another device to open (`write`: with the Pencil tools out). It goes to that device's connections
   * only, and it's kept, replacing anything sent before, until the app there says it has it (`seen`): if the device is
   * away, or went to sleep before its connection closed, it gets it when it next connects. Throws when there's no such
   * device, or it's this one.
   */
  sendPlace(from: string, to: unknown, place: unknown, title: unknown, write?: unknown): { id: string; queued: boolean } {
    if (typeof to !== 'string' || !to.trim()) throw new Error('send it to which device?');
    if (to === from) throw new Error("that's this device");
    if (!this.list().some((d) => d.device === to)) throw new Error(`no device called ${to}`);
    if (place === undefined || place === null) throw new Error('nothing to send');
    if (JSON.stringify(place).length > PLACE_MAX) throw new Error('that place is too big to send');
    const frame: PlaceSent = {
      type: 'place_sent', id: randomUUID(), from, to, place, title: typeof title === 'string' ? title.trim().slice(0, 200) : '', ts: Date.now(),
      ...(write === true ? { write: true } : {}),
    };
    this.saved.waiting[to] = frame;
    this.save();
    const here = this.conns.get(to);
    if (here?.size) {
      for (const s of here) s(frame);
      return { id: frame.id, queued: false };
    }
    this.log(`${from} sent ${to} "${frame.title}"; it's away, so it waits`);
    return { id: frame.id, queued: true };
  }

  /** The app on `device` has the place `id` it was sent: it isn't sent again. An id it isn't waiting on changes nothing. */
  seen(device: string, id: unknown): void {
    if (typeof id !== 'string' || this.saved.waiting[device]?.id !== id) return;
    delete this.saved.waiting[device];
    this.save();
  }

  /**
   * What `device` has open now (its tabs and windows; `current` indexes the one in front), replacing what it said
   * before. The other connections hear it in the device list; a device connecting later, in its welcome. The same again
   * (a reconnect) changes nothing. Throws when it isn't a list of places, or it's too big to keep.
   */
  report(device: string, places: unknown, current?: unknown, from?: Send): void {
    if (!Array.isArray(places)) throw new Error('places must be a list');
    const open: OpenPlace[] = places.map((p: unknown) => {
      const o = typeof p === 'object' && p !== null ? (p as { place?: unknown; title?: unknown }) : {};
      if (o.place === undefined || o.place === null) throw new Error('a place is missing');
      return { place: o.place, title: typeof o.title === 'string' ? o.title.trim().slice(0, 200) : '' };
    });
    const at = typeof current === 'number' && Number.isInteger(current) && current >= 0 && current < open.length ? current : undefined;
    const said = JSON.stringify({ places: open, current: at });
    if (said.length > OPEN_MAX) throw new Error('what this device has open is too big to keep');
    const before = this.saved.open[device];
    if (before && JSON.stringify({ places: before.places, current: before.current }) === said) return;
    this.saved.open[device] = { places: open, ...(at === undefined ? {} : { current: at }), ts: Date.now() };
    this.save();
    this.tell(from);
  }

  /** Places waiting a day or more are dropped. True when one was. */
  private expire(): boolean {
    let dropped = false;
    for (const [device, w] of Object.entries(this.saved.waiting)) {
      if (Date.now() - w.ts < WAIT_MS) continue;
      delete this.saved.waiting[device];
      dropped = true;
    }
    return dropped;
  }

  /** The list, to every connection but `except` (a device that's just connecting gets it in its welcome). */
  private tell(except?: Send): void {
    const devices = this.list();
    for (const set of this.conns.values()) for (const s of set) if (s !== except) s({ type: 'devices', devices });
  }

  private save(): void {
    try {
      writeFileSync(`${this.file}.tmp`, JSON.stringify(this.saved));
      renameSync(`${this.file}.tmp`, this.file);
    } catch (e) {
      this.log(`devices: couldn't save (${e instanceof Error ? e.message : e})`);
    }
  }
}
