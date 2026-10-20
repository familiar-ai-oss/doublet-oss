// Terminals on the hub machine, streamed to the app's drawer (SwiftTerm).
// A terminal outlives its client's connection for DETACH_TTL_MS, keeps the last SCROLLBACK bytes of output,
// and any of your devices can attach to it, so you can pick a shell up on another device.
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import type { IPty } from 'node-pty';
import type { PtyKind } from './protocol.ts';

// node-pty is CommonJS with a native addon.
const pty = createRequire(import.meta.url)('node-pty') as typeof import('node-pty');

const SCROLLBACK = 256 * 1024;
const DETACH_TTL_MS = 10 * 60_000;
const KILL_AFTER_MS = 3_000;
const MAX_TERMINALS = 6;

const LLMD_STATUS = String.raw`while true; do
  clear; date '+llmd status · %H:%M:%S (every 2 s)'; echo
  [ -n "$DUET_LLMD_ADMIN" ] || { echo 'No llmd: set DUET_LLMD_ADMIN in hub/local.env'; exit 0; }
  curl -s -m 3 "$DUET_LLMD_ADMIN/admin/v1/status" | python3 -c '
import json, sys
s = json.load(sys.stdin)
for b in s["backends"]:
    print("%-28s %-8s %-8s inflight %s" % (b["served_id"], b["state"], b["device"], b["inflight"]))
print()
for d, v in s["devices"].items():
    if v["usable_vram_mb"]: print("%-8s vram %s/%s MB" % (d, v["committed_vram_mb"], v["usable_vram_mb"]))
' 2>/dev/null || echo 'llmd admin API not reachable'
  sleep 2
done`;

const COMMANDS: Record<PtyKind, { title: string; file: string; args: string[] }> = {
  shell: { title: 'Shell', file: 'bash', args: ['-l'] },
  hub_logs: { title: 'Hub logs', file: 'journalctl', args: ['--user', '-u', 'duet-hub', '-f', '-n', '200', '-o', 'short-iso'] },
  llmd: { title: 'llmd status', file: 'bash', args: ['-c', LLMD_STATUS] },
};

type Terminal = {
  id: string;
  kind: PtyKind;
  title: string;
  proc: IPty;
  buffer: string;
  clients: Set<Sink>;
  detachTimer: NodeJS.Timeout | null;
  exited: number | null;
};

export type Sink = { data(id: string, data: string): void; exit(id: string, code: number): void };

export class Terminals {
  private terms = new Map<string, Terminal>();
  private cwd: string;
  private log: (m: string) => void;

  constructor(cwd: string, log: (m: string) => void) {
    this.cwd = cwd;
    this.log = log;
  }

  list(): { id: string; kind: PtyKind; title: string }[] {
    return [...this.terms.values()].filter((t) => t.exited === null).map((t) => ({ id: t.id, kind: t.kind, title: t.title }));
  }

  /** Where new shells start: Claude's folder. */
  setCwd(dir: string): void {
    this.cwd = dir;
  }

  open(kind: PtyKind, cols: number, rows: number, sink: Sink, by: string, cwd?: string): string {
    const cmd = COMMANDS[kind];
    if (!cmd) throw new Error(`unknown terminal kind ${kind}`);
    if (this.list().length >= MAX_TERMINALS) throw new Error(`at most ${MAX_TERMINALS} terminals; close one first`);
    const env = { ...process.env, TERM: 'xterm-256color', COLORTERM: 'truecolor' } as Record<string, string>;
    const proc = pty.spawn(cmd.file, cmd.args, { name: 'xterm-256color', cols: clamp(cols, 20, 400), rows: clamp(rows, 5, 200), cwd: cwd ?? this.cwd, env });
    const t: Terminal = { id: `pty-${randomUUID().slice(0, 6)}`, kind, title: cmd.title, proc, buffer: '', clients: new Set([sink]), detachTimer: null, exited: null };
    proc.onData((d) => {
      t.buffer = (t.buffer + d).slice(-SCROLLBACK);
      for (const c of t.clients) c.data(t.id, d);
    });
    proc.onExit(({ exitCode, signal }) => {
      this.log(`terminal ${t.id} exited (code ${exitCode}${signal ? `, signal ${signal}` : ''}) with ${t.clients.size} attached`);
      t.exited = exitCode;
      for (const c of t.clients) c.exit(t.id, exitCode);
      if (t.detachTimer) clearTimeout(t.detachTimer);
      this.terms.delete(t.id);
    });
    this.terms.set(t.id, t);
    this.log(`${by} opened terminal ${t.id} (${kind})`);
    return t.id;
  }

  // Attach a (re)connected client: it gets the scrollback, then live output.
  attach(id: string, sink: Sink): void {
    const t = this.get(id);
    if (t.detachTimer) { clearTimeout(t.detachTimer); t.detachTimer = null; }
    t.clients.add(sink);
    if (t.buffer) sink.data(id, t.buffer);
  }

  input(id: string, data: string): void {
    this.get(id).proc.write(data);
  }

  resize(id: string, cols: number, rows: number): void {
    this.get(id).proc.resize(clamp(cols, 20, 400), clamp(rows, 5, 200));
  }

  // SIGHUP, as when a terminal window closes; anything still running a few seconds later is killed.
  close(id: string): void {
    const t = this.get(id);
    t.proc.kill();
    setTimeout(() => {
      if (t.exited !== null) return;
      this.log(`terminal ${t.id} ignored SIGHUP; killing it`);
      t.proc.kill('SIGKILL');
    }, KILL_AFTER_MS).unref();
  }

  // A client went away: keep its terminals for a while so it (or another device) can attach again.
  detachAll(sink: Sink): void {
    for (const t of this.terms.values()) {
      if (!t.clients.delete(sink) || t.clients.size) continue;
      t.detachTimer = setTimeout(() => { this.log(`terminal ${t.id} closed after ${DETACH_TTL_MS / 60000} min unattached`); t.proc.kill(); }, DETACH_TTL_MS);
    }
  }

  closeAll(): void {
    for (const t of this.terms.values()) t.proc.kill();
  }

  private get(id: string): Terminal {
    const t = this.terms.get(id);
    if (!t) throw new Error(`no terminal ${id}`);
    return t;
  }
}

function clamp(n: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, Math.round(n) || lo));
}
