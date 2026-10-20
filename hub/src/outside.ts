// Claude Code sessions started outside Duet on this machine: in the desktop app's Code tab (locally or over SSH), or in
// a terminal. The hub lists them while they run, follows one live for a device that opens it, and continues one in
// Duet: a fork while it still runs elsewhere (two processes must never write to one session), the session itself once
// it has ended. Claude Code keeps a registry of running sessions (`<config>/sessions/<pid>.json`), lists them the
// documented way (`claude agents --json --all`, which also has background sessions), and writes each session's
// transcript as it goes (`<config>/projects/<folder>/<sessionId>.jsonl`). See docs/import.md.
import { forkSession, getSessionMessages } from '@anthropic-ai/claude-agent-sdk';
import { execFile } from 'node:child_process';
import { closeSync, existsSync, openSync, readFileSync, readSync, readdirSync, statSync, watch, type FSWatcher } from 'node:fs';
import { homedir } from 'node:os';
import { basename, join } from 'node:path';
import type { OutsideMessage, OutsideSession } from './protocol.ts';
import { claudePath } from './claude.ts';

/** A device that sees the list, and the sessions it follows. */
export type OutsideSink = {
  sessions: (list: OutsideSession[]) => void;
  messages: (sessionId: string, messages: OutsideMessage[]) => void;
};

/** A registry entry, or a line of `claude agents --json --all`. */
type Running = {
  pid?: number; procStart?: string; sessionId?: string; cwd?: string; kind?: string; entrypoint?: string;
  status?: string; state?: string; name?: string; startedAt?: number; updatedAt?: number; statusUpdatedAt?: number;
};

export type OutsideConfig = {
  /** Claude Code's config folder: CLAUDE_CONFIG_DIR, else ~/.claude. */
  home?: string;
  /** Sessions the hub runs itself (its lead, side chats): never listed. */
  ours: (sessionId: string) => boolean;
  log: (m: string) => void;
  /** Live sessions the documented way; replaceable in tests. Unset: `claude agents --json --all`. */
  agents?: () => Promise<Running[]>;
  /** A session's conversation so far (the SDK's, by default). */
  history?: (sessionId: string, dir?: string) => Promise<{ uuid: string; type: string; message: unknown; parent_tool_use_id: string | null }[]>;
  /** List programmatic sessions too (SDK programs, print mode): for tests, which start one that way. */
  programmatic?: boolean;
  /** Forks a session (the SDK's, by default). */
  fork?: (sessionId: string, options: { dir?: string }) => Promise<{ sessionId: string }>;
  scanMs?: number;
  agentsMs?: number;
};

const ENDED_KEPT_MS = 24 * 3600_000;
const TEXT_MAX = 8000;
const HISTORY = 60;

type Follow = { path?: string; offset: number; rest: string; seen: Set<string>; sinks: Set<OutsideSink>; watcher?: FSWatcher; timer?: ReturnType<typeof setInterval> };

export class OutsideSessions {
  private cfg: OutsideConfig;
  private home: string;
  private sessions = new Map<string, OutsideSession>();
  private sinks = new Set<OutsideSink>();
  private follows = new Map<string, Follow>();
  private background: Running[] = [];
  private shown = '';
  private timers: ReturnType<typeof setInterval>[] = [];
  private watcher?: FSWatcher;
  /** Transcripts looked for by a full search (a long folder name is hashed): looked for again after a while. */
  private searched = new Map<string, { at: number; path?: string }>();

  constructor(cfg: OutsideConfig) {
    this.cfg = cfg;
    this.home = cfg.home ?? process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude');
  }

  /** Watch the registry (a session starting or ending shows within a second) and ask `claude agents` now and then. */
  start(): void {
    this.scan();
    const dir = join(this.home, 'sessions');
    try {
      if (existsSync(dir)) this.watcher = watch(dir, () => this.scan());
    } catch (e) {
      this.cfg.log(`outside sessions: can't watch ${dir}: ${e}`);
    }
    this.timers.push(setInterval(() => this.scan(), this.cfg.scanMs ?? 2000));
    const ask = () => void this.askAgents();
    ask();
    this.timers.push(setInterval(ask, this.cfg.agentsMs ?? 30_000));
  }

  stop(): void {
    this.watcher?.close();
    for (const t of this.timers) clearInterval(t);
    for (const f of this.follows.values()) this.unwatch(f);
    this.follows.clear();
  }

  list(): OutsideSession[] {
    return [...this.sessions.values()].sort((a, b) => Number(b.live) - Number(a.live) || (b.updatedAt ?? b.startedAt ?? 0) - (a.updatedAt ?? a.startedAt ?? 0));
  }

  get(sessionId: string): OutsideSession | undefined {
    return this.sessions.get(sessionId);
  }

  /** A device: it gets the list now and whenever it changes. Returns the detach (which also drops its follows). */
  attach(sink: OutsideSink): () => void {
    this.sinks.add(sink);
    sink.sessions(this.list());
    return () => {
      this.sinks.delete(sink);
      for (const id of [...this.follows.keys()]) this.unfollow(sink, id);
    };
  }

  /**
   * What continuing a session in Duet resumes: a fork while it still runs elsewhere (so the original is never written
   * to by two processes), the session itself once it has ended.
   */
  async continueAs(sessionId: string): Promise<{ sessionId: string; forked: boolean; from: OutsideSession }> {
    const from = this.sessions.get(sessionId);
    if (!from) throw new Error(`no session ${sessionId} running outside Doublet`);
    if (!from.live) return { sessionId, forked: false, from };
    const { sessionId: fork } = await (this.cfg.fork ?? forkSession)(sessionId, from.cwd ? { dir: from.cwd } : {});
    return { sessionId: fork, forked: true, from };
  }

  /** Continued in Duet: an ended one is Duet's now, so it leaves the list. */
  continued(sessionId: string): void {
    const s = this.sessions.get(sessionId);
    if (s && !s.live) {
      this.sessions.delete(sessionId);
      this.publish();
    }
  }

  /** Reads the registry: what runs now, and what has ended since. */
  scan(): void {
    const now = Date.now();
    const seen = new Map<string, OutsideSession>();
    const add = (r: Running, where: OutsideSession['where']) => {
      const id = r.sessionId;
      if (!id || this.cfg.ours(id) || !this.said(id, r.cwd ?? '')) return;
      const prev = seen.get(id);
      const status = r.status ?? r.state ?? 'running';
      const s: OutsideSession = {
        sessionId: id, name: r.name?.trim() || basename(r.cwd ?? '') || 'Claude Code', cwd: r.cwd ?? '', where, status, live: true,
        ...(r.startedAt ? { startedAt: r.startedAt } : {}), ...((r.statusUpdatedAt ?? r.updatedAt) ? { updatedAt: r.statusUpdatedAt ?? r.updatedAt } : {}),
      };
      // Two processes on one session (it happens): busy if either is.
      seen.set(id, prev ? { ...prev, status: prev.status === 'busy' ? 'busy' : s.status } : s);
    };
    for (const r of this.registry()) {
      if (!r.pid || !alive(r.pid, r.procStart)) continue;
      // Programmatic sessions (SDK programs, the hub's own included) aren't someone's conversation: like `/resume`.
      if (r.entrypoint?.startsWith('sdk') && !this.cfg.programmatic) continue;
      add(r, r.entrypoint === 'claude-desktop' ? 'desktop' : 'terminal');
    }
    for (const r of this.background) add(r, 'background');
    // Gone since the last look: ended, and kept a day (to be continued in Duet).
    for (const [id, s] of this.sessions) {
      if (seen.has(id)) continue;
      if (s.live) seen.set(id, { ...s, live: false, status: 'ended', endedAt: now });
      else if (now - (s.endedAt ?? 0) < ENDED_KEPT_MS) seen.set(id, s);
    }
    this.sessions = seen;
    this.publish();
  }

  /** Whether anything has been said in it: a session with nothing yet (a new desktop tab) has no transcript, so there's
   *  nothing to follow or continue, and it isn't listed until there is. */
  private said(sessionId: string, cwd: string): boolean {
    if (cwd && existsSync(join(this.home, 'projects', cwd.replace(/[^A-Za-z0-9]/g, '-'), `${sessionId}.jsonl`))) return true;
    const s = this.searched.get(sessionId);
    if (s && Date.now() - s.at < 30_000) return !!s.path;
    const path = this.transcript(sessionId);
    this.searched.set(sessionId, { at: Date.now(), ...(path ? { path } : {}) });
    return !!path;
  }

  private registry(): Running[] {
    const dir = join(this.home, 'sessions');
    let files: string[];
    try { files = readdirSync(dir).filter((f) => f.endsWith('.json')); } catch { return []; }
    return files.flatMap((f) => {
      try { return [JSON.parse(readFileSync(join(dir, f), 'utf8')) as Running]; } catch { return []; }
    });
  }

  private async askAgents(): Promise<void> {
    try {
      const all = await (this.cfg.agents ?? claudeAgents)();
      this.background = all.filter((r) => r.kind === 'background');
      this.scan();
    } catch (e) {
      this.cfg.log(`outside sessions: claude agents: ${e}`);
    }
  }

  private publish(): void {
    const list = this.list();
    const now = JSON.stringify(list);
    if (now === this.shown) return;
    this.shown = now;
    for (const s of this.sinks) s.sessions(list);
  }

  /**
   * Follow a session live for a device: its recent conversation now (resolved by the SDK, so a rewound branch doesn't
   * show), then each message as its transcript gets it.
   */
  async follow(sink: OutsideSink, sessionId: string): Promise<{ session?: OutsideSession; messages: OutsideMessage[] }> {
    let f = this.follows.get(sessionId);
    if (f) {
      f.sinks.add(sink);
      return { session: this.sessions.get(sessionId), messages: await this.recent(sessionId) };
    }
    const path = this.transcript(sessionId);
    if (!path) throw new Error(`no transcript for session ${sessionId}`);
    // Where the tail starts: what's appended after this is followed; what the history has too is dropped by uuid.
    const offset = statSync(path).size;
    const messages = await this.recent(sessionId);
    // Another device may have started following while the history loaded.
    const other = this.follows.get(sessionId);
    if (other) {
      other.sinks.add(sink);
      return { session: this.sessions.get(sessionId), messages };
    }
    f = { path, offset, rest: '', seen: new Set(messages.map((m) => m.uuid)), sinks: new Set([sink]) };
    this.follows.set(sessionId, f);
    const read = () => this.tail(sessionId);
    try { f.watcher = watch(join(path, '..'), read); } catch { /* the poll still runs */ }
    f.timer = setInterval(read, 1000);
    read();
    return { session: this.sessions.get(sessionId), messages };
  }

  unfollow(sink: OutsideSink, sessionId: string): void {
    const f = this.follows.get(sessionId);
    if (!f) return;
    f.sinks.delete(sink);
    if (!f.sinks.size) {
      this.unwatch(f);
      this.follows.delete(sessionId);
    }
  }

  /** The conversation so far, its last messages: what a device shows first, and what continuing in Duet carries over. */
  async recent(sessionId: string, n = HISTORY): Promise<OutsideMessage[]> {
    const dir = this.sessions.get(sessionId)?.cwd || undefined;
    const get = this.cfg.history ?? ((id: string, d?: string) => getSessionMessages(id, d ? { dir: d } : {}));
    const all = await get(sessionId, dir).catch(() => (dir ? get(sessionId) : Promise.reject(new Error(`no session ${sessionId}`))));
    return all.filter((m) => m.parent_tool_use_id === null).flatMap((m) => {
      const out = fromMessage(m.uuid, m.type, m.message);
      return out ? [out] : [];
    }).slice(-n);
  }

  /** A transcript by session id: its folder name is the cwd's, but cut and hashed when long, so it's looked up. */
  transcript(sessionId: string): string | undefined {
    const cwd = this.sessions.get(sessionId)?.cwd;
    const projects = join(this.home, 'projects');
    const guess = cwd ? join(projects, cwd.replace(/[^A-Za-z0-9]/g, '-'), `${sessionId}.jsonl`) : '';
    if (guess && existsSync(guess)) return guess;
    try {
      for (const d of readdirSync(projects)) {
        const p = join(projects, d, `${sessionId}.jsonl`);
        if (existsSync(p)) return p;
      }
    } catch { /* no projects folder */ }
    return undefined;
  }

  /** What's been appended since the last read, as messages, to the session's followers. */
  private tail(sessionId: string): void {
    const f = this.follows.get(sessionId);
    if (!f?.path) return;
    let size: number;
    try { size = statSync(f.path).size; } catch { return; }
    if (size < f.offset) { f.offset = 0; f.rest = ''; }
    if (size === f.offset) return;
    const buf = Buffer.alloc(size - f.offset);
    const fd = openSync(f.path, 'r');
    try { readSync(fd, buf, 0, buf.length, f.offset); } finally { closeSync(fd); }
    f.offset = size;
    const lines = (f.rest + buf.toString('utf8')).split('\n');
    f.rest = lines.pop() ?? '';
    const out: OutsideMessage[] = [];
    for (const line of lines) {
      let r: Record<string, unknown>;
      try { r = JSON.parse(line); } catch { continue; }
      const m = fromRecord(r);
      if (!m || f.seen.has(m.uuid)) continue;
      f.seen.add(m.uuid);
      out.push(m);
    }
    if (out.length) for (const s of f.sinks) s.messages(sessionId, out);
  }

  private unwatch(f: Follow): void {
    f.watcher?.close();
    if (f.timer) clearInterval(f.timer);
  }
}

/** Live, and the same process: `procStart` is its start time (field 22 of /proc/<pid>/stat), so a reused pid isn't. */
export function alive(pid: number, procStart?: string): boolean {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');
    // The command name (field 2) can hold spaces and parentheses: fields after it start past the last ")".
    const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
    return !procStart || fields[19] === procStart;
  } catch {
    // No /proc (macOS): the pid answering is the best there is.
    try { process.kill(pid, 0); return true; } catch { return false; }
  }
}

/** A transcript record as a message: what was said, and the tools reached for. Subagents, meta records and tool
 *  results (shown as the tool line on Claude's side) are left out. */
export function fromRecord(r: Record<string, unknown>): OutsideMessage | null {
  if (r.isSidechain || r.isMeta || r.isCompactSummary) return null;
  if (r.type !== 'user' && r.type !== 'assistant') return null;
  const ts = typeof r.timestamp === 'string' ? Date.parse(r.timestamp) : undefined;
  return fromMessage(String(r.uuid ?? ''), r.type, r.message, ts);
}

export function fromMessage(uuid: string, type: string, message: unknown, ts?: number): OutsideMessage | null {
  if (!uuid || (type !== 'user' && type !== 'assistant')) return null;
  const content = (message as { content?: unknown } | undefined)?.content;
  const blocks = typeof content === 'string' ? [{ type: 'text', text: content }] : Array.isArray(content) ? (content as { type?: string; text?: string; name?: string; input?: unknown }[]) : [];
  const text = blocks.flatMap((b) => (b.type === 'text' && b.text?.trim() ? [b.text.trim()] : b.type === 'image' ? ['[a picture]'] : [])).join('\n\n');
  const tools = blocks.flatMap((b) => (b.type === 'tool_use' && b.name ? [toolLine(b.name, b.input)] : []));
  // A user turn that is only tool results is Claude's work, shown as its tool lines; thinking alone shows nothing.
  if (!text && !tools.length) return null;
  return { uuid, role: type, text: text.length > TEXT_MAX ? `${text.slice(0, TEXT_MAX - 1)}…` : text, ...(tools.length ? { tools } : {}), ...(ts && !Number.isNaN(ts) ? { ts } : {}) };
}

/** "Read src/fleet.ts", "Bash npm test": what a tool call was about. */
function toolLine(name: string, input: unknown): string {
  const i = (input ?? {}) as Record<string, unknown>;
  const what = [i.file_path, i.command, i.pattern, i.path, i.url, i.query, i.description].find((v) => typeof v === 'string' && v) as string | undefined;
  const short = what && what.length > 120 ? `${what.slice(0, 119)}…` : what;
  return short ? `${name} ${short}` : name;
}

/** `claude agents --json --all`: every live session, background ones included. */
function claudeAgents(): Promise<Running[]> {
  return new Promise((resolve, reject) => {
    execFile(claudePath() ?? 'claude', ['agents', '--json', '--all'], { timeout: 15_000, maxBuffer: 4 << 20 }, (err, stdout) => {
      if (err) return reject(err);
      try { resolve(JSON.parse(stdout) as Running[]); } catch (e) { reject(e); }
    });
  });
}
