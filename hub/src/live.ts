// The Lock Screen and the Dynamic Island. The hub keeps a small status from its own events (what Claude is doing,
// what waits on you, each worker's speed) and pushes it to every device's Live Activity through APNs.
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { hostname } from 'node:os';
import type { Apns, ApnsEnv } from './apns.ts';
import type { HubEvent, WorkerView } from './protocol.ts';

// Mirrored by DuetActivityAttributes.ContentState in the app: same keys, `since` in seconds since 1970.
export type LiveState = {
  phase: string;
  symbol: string;
  busy: boolean;
  since: number | null;
  waiting: number;
  approval: { id: string; tool: string; summary: string; risky: boolean } | null;
  workers: { id: string; name: string; place: string; tokPerS: number | null; busy: boolean }[];
};

type Change = 'now' | 'soon' | null;

const FRIENDLY: Record<string, string> = {
  mcp__duet__await_workers: 'Waiting on workers',
  mcp__duet__delegate: 'Handing work to a worker',
  mcp__duet__diagram: 'Drawing a diagram',
  mcp__duet__answer: "Answering a worker",
  mcp__duet__plan: 'Planning',
  mcp__duet__escalate: 'Passing a question to you',
};

/** One line for the Lock Screen: the command, file or pattern a call is about. */
export function callSummary(tool: string, input: Record<string, unknown>): string {
  const s = (k: string) => (typeof input[k] === 'string' && input[k] ? String(input[k]) : undefined);
  const first = s('command') ?? s('file_path') ?? s('pattern') ?? s('url') ?? s('description') ?? Object.values(input).find((v) => typeof v === 'string');
  const line = String(first ?? tool).split('\n')[0];
  return line.length > 90 ? `${line.slice(0, 89)}…` : line;
}

export class LiveStatus {
  private busy = false;
  private since: number | null = null;
  private doing = '';
  private approvals = new Map<string, NonNullable<LiveState['approval']>>();
  private otherWaiting = new Set<string>();
  private workers: WorkerView[] = [];
  private rates = new Map<string, number>();

  /** Fold one event in. Returns how soon the Live Activities should hear about it. */
  apply(e: HubEvent): Change {
    switch (e.type) {
      case 'turn_start':
        this.busy = true;
        this.since = Math.round(e.ts / 1000);
        this.doing = 'Thinking';
        return 'now';
      case 'text_delta':
        if (this.doing === 'Writing') return null;
        this.doing = 'Writing';
        return 'soon';
      case 'assistant': {
        const last = e.toolUses.at(-1);
        if (!last) return null;
        this.doing = FRIENDLY[last.name] ?? `Running ${last.name.startsWith('mcp__') ? last.name.split('__').at(-1) : last.name}`;
        return 'soon';
      }
      case 'approval_request':
        this.approvals.set(e.id, { id: e.id, tool: e.displayName ?? e.tool, summary: callSummary(e.tool, e.input), risky: !!e.defaultToNo });
        return 'now';
      case 'approval_resolved':
        return this.approvals.delete(e.id) ? 'now' : null;
      case 'turn_end':
        this.busy = false;
        this.since = null;
        this.doing = '';
        this.approvals.clear();
        return 'now';
      case 'dialogue':
        if (e.kind === 'QUESTION' && e.to !== 'lead' && !e.refused) { this.otherWaiting.add(`q-${e.id}`); return 'now'; }
        // Claude passed one of its workers' questions on to you: it waits on you now (its ANSWER clears it).
        if (e.kind === 'ESCALATE' && e.replyTo && !e.refused) { this.otherWaiting.add(`q-${e.replyTo}`); return 'now'; }
        if (e.kind === 'ANSWER' && e.replyTo && this.otherWaiting.delete(`q-${e.replyTo}`)) return 'now';
        return null;
      case 'swap_request':
        this.otherWaiting.add(`s-${e.id}`);
        return 'now';
      case 'swap_resolved':
        return this.otherWaiting.delete(`s-${e.id}`) ? 'now' : null;
      case 'fleet': {
        const wasBusy = this.workers.map((w) => !!w.running).join();
        this.workers = e.workers;
        return wasBusy !== e.workers.map((w) => !!w.running).join() ? 'now' : 'soon';
      }
      case 'worker_request':
        if (e.tokPerS == null) return null;
        this.rates.set(e.worker, e.tokPerS);
        return 'soon';
      default:
        return null;
    }
  }

  state(): LiveState {
    const approval = [...this.approvals.values()][0] ?? null;
    const waiting = this.approvals.size + this.otherWaiting.size;
    const phase = approval ? 'Needs your approval' : waiting ? `${waiting} waiting on you` : this.busy ? this.doing || 'Working' : 'Idle';
    const symbol = approval || waiting ? 'hand.raised.fill' : !this.busy ? 'checkmark.circle' : this.doing === 'Writing' ? 'text.cursor' : this.doing.startsWith('Waiting on') ? 'person.2.wave.2' : this.doing === 'Thinking' ? 'brain' : 'wrench.and.screwdriver';
    return {
      phase,
      symbol,
      busy: this.busy,
      since: this.since,
      waiting,
      approval,
      workers: this.workers.filter((w) => w.enabled).map((w) => {
        const [name, place] = w.label.split('·').map((s) => s.trim());
        return { id: w.id, name, place: place ?? '', tokPerS: this.rates.get(w.id) ?? w.tokPerS, busy: !!w.running };
      }),
    };
  }
}

type Reg = { token?: string; startToken?: string; env: ApnsEnv };


/** The Live Activity push payload for one event. */
export function livePayload(event: 'start' | 'update' | 'end', st: LiveState, now = Math.floor(Date.now() / 1000)): object {
  const aps: Record<string, unknown> = { timestamp: now, event, 'content-state': st };
  if (event === 'update') aps['stale-date'] = now + (st.busy || st.waiting ? 300 : 3600);
  if (event === 'start') {
    aps['attributes-type'] = 'DuetActivityAttributes';
    aps.attributes = { hub: process.env.DUET_HUB_NAME || hostname() };
    aps.alert = { title: 'Claude', body: st.phase };
  }
  // Already idle for a quarter of an hour by the time it ends: off the Lock Screen within a minute.
  if (event === 'end') aps['dismissal-date'] = now + 60;
  return { aps };
}

export class LiveActivities {
  readonly status = new LiveStatus();
  private regs: Record<string, Reg> = {};
  private nowTimer: NodeJS.Timeout | null = null;
  private soonTimer: NodeJS.Timeout | null = null;
  private lastPush = 0;
  private idleSince = Date.now();
  private ended = false;
  private endTimer: NodeJS.Timeout | null = null;
  /** Devices sent a push-to-start in this stretch of work, so a second event doesn't start a second activity. */
  private started = new Set<string>();
  private file: string;
  private apns: Apns | null;
  private log: (m: string) => void;
  private connected: (device: string) => boolean;
  private idleEndMs: number;

  /**
   * `connected`: whether a device's app is connected now (it starts its own activity, so the hub doesn't).
   * `idleEndMs`: an activity idle this long ends; the next turn starts a new one.
   */
  constructor(file: string, apns: Apns | null, log: (m: string) => void, opts: { connected?: (device: string) => boolean; idleEndMs?: number } = {}) {
    this.file = file;
    this.apns = apns;
    this.log = log;
    this.connected = opts.connected ?? (() => false);
    this.idleEndMs = opts.idleEndMs ?? 15 * 60_000;
    try { if (existsSync(file)) this.regs = JSON.parse(readFileSync(file, 'utf8')); } catch { this.regs = {}; }
  }

  get enabled(): boolean {
    return this.apns !== null;
  }

  /** A device's activity token (to update its current activity) and push-to-start token (to start one remotely). */
  register(device: string, r: Reg): void {
    // Only what this call names: a push-to-start token alone keeps the activity's token, and the other way round.
    const given = Object.fromEntries(Object.entries(r).filter(([, v]) => v != null)) as Partial<Reg>;
    this.regs[device] = { ...this.regs[device], ...given } as Reg;
    this.save();
    if (r.token) void this.pushOne(device, 'update', 10);
  }

  forget(device: string): void {
    const r = this.regs[device];
    if (!r) return;
    delete r.token;
    this.save();
  }

  onEvent(e: HubEvent): void {
    const change = this.status.apply(e);
    if (change === 'now') {
      // Coalesce a burst (approval + phase change) into one push.
      if (!this.nowTimer) this.nowTimer = setTimeout(() => { this.nowTimer = null; void this.pushAll(10); }, 300);
    } else if (change === 'soon' && !this.soonTimer) {
      // Speeds and phase details: at most one push every 5 seconds, at low priority.
      const wait = Math.max(0, this.lastPush + 5000 - Date.now());
      this.soonTimer = setTimeout(() => { this.soonTimer = null; void this.pushAll(5); }, wait);
    }
  }

  private async pushAll(priority: 5 | 10): Promise<void> {
    this.lastPush = Date.now();
    const st = this.status.state();
    const active = st.busy || st.waiting > 0;
    if (active) {
      this.idleSince = Date.now();
      this.ended = false;
      if (this.endTimer) { clearTimeout(this.endTimer); this.endTimer = null; }
    } else {
      this.started.clear();
      // Nothing else may happen for a while, so a timer ends idle activities.
      if (!this.ended && !this.endTimer) {
        this.endTimer = setTimeout(() => { this.endTimer = null; void this.pushAll(10); }, Math.max(0, this.idleSince + this.idleEndMs - Date.now()) + 1000);
        this.endTimer.unref?.();
      }
    }
    const stale = !active && Date.now() - this.idleSince >= this.idleEndMs;
    for (const device of Object.keys(this.regs)) {
      const r = this.regs[device];
      if (r.token) {
        if (stale) {
          await this.pushOne(device, 'end', 10);
          // An ended activity takes no more updates; the next one brings its own token.
          delete r.token;
          this.save();
        } else {
          await this.pushOne(device, 'update', priority);
        }
      } else if (r.startToken && active && priority === 10 && !this.started.has(device) && !this.connected(device)) {
        // Nothing on its Lock Screen, and its app isn't open to start one: start one remotely.
        this.started.add(device);
        await this.pushOne(device, 'start', 10);
      }
    }
    if (stale) this.ended = true;
  }

  private async pushOne(device: string, event: 'start' | 'update' | 'end', priority: 5 | 10): Promise<void> {
    const r = this.regs[device];
    const token = event === 'start' ? r?.startToken : r?.token;
    if (!this.apns || !r || !token) return;
    const res = await this.apns.liveActivity(token, r.env, livePayload(event, this.status.state()), priority);
    if (res.status === 200) return;
    this.log(`live activity ${event} for ${device}: ${res.status} ${res.reason ?? ''}`);
    // The activity ended on the device, or the token is from another environment: stop using it.
    if (res.status === 410 || res.reason === 'BadDeviceToken' || res.reason === 'Unregistered') {
      if (event === 'start') delete r.startToken; else delete r.token;
      this.save();
    }
  }

  private save(): void {
    // Push tokens: readable by this user only, like the device tokens.
    try { writeFileSync(this.file, JSON.stringify(this.regs, null, 2), { mode: 0o600 }); } catch (e) { this.log(`live activities: ${e}`); }
  }
}
