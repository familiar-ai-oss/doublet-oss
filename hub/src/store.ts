// Append-only event log: in memory for replay, mirrored to JSONL so a hub restart keeps sequence numbers.
// Also holds small hub state (the lead's session id) in state.json.
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import { UNTAGGED_EVENTS, type EventBody, type HubEvent, type PermissionMode } from './protocol.ts';

export type Listener = (e: HubEvent) => void;

export class EventLog {
  private events: HubEvent[] = [];
  private listeners = new Set<Listener>();
  private readonly file: string;
  /** The conversation an event belongs to unless it says otherwise: the lead's current session. Set once the lead exists. */
  conversation: () => string | undefined = () => undefined;

  constructor(dir: string) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    this.file = join(dir, 'events.jsonl');
    if (existsSync(this.file)) {
      for (const line of readFileSync(this.file, 'utf8').split('\n')) {
        if (!line) continue;
        try { this.events.push(JSON.parse(line)); } catch { /* torn final line after a crash */ }
      }
    }
  }

  get headSeq(): number {
    return this.events.at(-1)?.seq ?? 0;
  }

  append(body: EventBody): HubEvent {
    // Every event in a conversation carries it. Hub-wide events (the fleet, the model list) get none by default;
    // lead_info sets its own to say which conversation is live.
    const { conversationId: given, ...rest } = body;
    const conversationId = UNTAGGED_EVENTS.has(body.type) ? given : given ?? this.conversation();
    const e = { ...rest, ...(conversationId ? { conversationId } : {}), seq: this.headSeq + 1, ts: Date.now() } as HubEvent;
    this.events.push(e);
    appendFileSync(this.file, JSON.stringify(e) + '\n');
    for (const l of this.listeners) l(e);
    return e;
  }

  // Events with seq > lastSeq. Seqs are dense from 1, so this is a slice.
  since(lastSeq: number): HubEvent[] {
    return this.events.slice(Math.max(0, lastSeq));
  }

  // Replay and subscribe in one synchronous step, so no event can fall between them.
  subscribe(lastSeq: number, l: Listener): { backlog: HubEvent[]; unsubscribe: () => void } {
    const backlog = this.since(lastSeq);
    this.listeners.add(l);
    return { backlog, unsubscribe: () => this.listeners.delete(l) };
  }
}

// `cwd`: the folder Claude was last moved to (it outlives restarts); `recentCwds`: the last few, newest first.
// `permissionMode`: the lead's, so the next session starts in it.
export type HubState = { leadSessionId?: string; cwd?: string; recentCwds?: string[]; permissionMode?: PermissionMode };

export class StateFile {
  private readonly file: string;
  constructor(dir: string) {
    this.file = join(dir, 'state.json');
  }
  read(): HubState {
    try { return JSON.parse(readFileSync(this.file, 'utf8')); } catch { return {}; }
  }
  write(s: HubState): void {
    writeFileSync(this.file + '.tmp', JSON.stringify(s, null, 2), { mode: 0o600 });
    renameSync(this.file + '.tmp', this.file);
  }
}
