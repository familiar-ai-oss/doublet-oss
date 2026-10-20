// What went wrong on the user's devices: crashes, freezes and the system's own reports (MetricKit), sent by the app the
// next time it connects. Each report is one JSON file in the state folder's diagnostics/, plus a line in
// diagnostics.jsonl to list them by. Read them with `src/main.ts diagnostics [count]` (docs/diagnostics.md).
import { appendFileSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { DiagnosticKind } from './protocol.ts';

export const DIAGNOSTIC_KINDS: readonly DiagnosticKind[] = ['crash', 'hang', 'freeze', 'exit', 'cpu', 'disk', 'launch'];
/** A report's payload (MetricKit's JSON, with its call stacks) is cut beyond this; the summary always fits. */
export const MAX_PAYLOAD = 512 * 1024;
/** Reports kept: the oldest go first. */
export const MAX_REPORTS = 300;

export type DiagnosticReport = {
  kind: DiagnosticKind;
  /** When it happened on the device (ISO 8601); the hub's own time when absent. */
  at?: string;
  /** One line: "Freeze 2.9 s on the conversation", "Crash: EXC_CRASH SIGABRT in AudioRig.init". */
  summary: string;
  durationMs?: number;
  /** The app's build and the system it ran on. */
  build?: string;
  os?: string;
  model?: string;
  /** What the app was doing: what was on screen, the last few things you did. */
  context?: Record<string, unknown>;
  /** The system's report as it gave it (MetricKit's JSON), for its call stacks. */
  payload?: string;
  /** The app's id for it, so a report sent twice (the ack lost) is kept once. */
  id: string;
};

export type DiagnosticEntry = Omit<DiagnosticReport, 'payload' | 'context'> & { device: string; received: string; file: string; truncated?: boolean };

export class Diagnostics {
  readonly dir: string;
  readonly index: string;
  private ids = new Set<string>();
  private log: (m: string) => void;

  constructor(stateDir: string, log: (m: string) => void = () => {}) {
    this.log = log;
    this.dir = join(stateDir, 'diagnostics');
    this.index = join(stateDir, 'diagnostics.jsonl');
    mkdirSync(this.dir, { recursive: true });
    for (const e of this.list()) this.ids.add(`${e.device}/${e.id}`);
  }

  /** Keeps a report (once per device and id). Throws on one that isn't a report. */
  add(device: string, r: DiagnosticReport): { kept: boolean } {
    if (!DIAGNOSTIC_KINDS.includes(r.kind)) throw new Error(`unknown diagnostic kind ${r.kind}`);
    if (typeof r.id !== 'string' || !/^[\w.-]{1,80}$/.test(r.id)) throw new Error('diagnostic needs an id');
    if (typeof r.summary !== 'string' || !r.summary.trim()) throw new Error('diagnostic needs a summary');
    const key = `${device}/${r.id}`;
    if (this.ids.has(key)) return { kept: false };
    const received = new Date().toISOString();
    const truncated = typeof r.payload === 'string' && r.payload.length > MAX_PAYLOAD;
    const payload = truncated ? r.payload!.slice(0, MAX_PAYLOAD) : r.payload;
    const safeDevice = device.replace(/[^\w.-]/g, '_');
    const file = `${received.replace(/[:.]/g, '-')}-${safeDevice}-${r.kind}-${r.id}.json`;
    const entry: DiagnosticEntry = {
      kind: r.kind, at: r.at ?? received, summary: r.summary.slice(0, 300), id: r.id, device, received, file,
      ...(r.durationMs != null ? { durationMs: Math.round(Number(r.durationMs)) } : {}),
      ...(r.build ? { build: String(r.build).slice(0, 80) } : {}),
      ...(r.os ? { os: String(r.os).slice(0, 80) } : {}),
      ...(r.model ? { model: String(r.model).slice(0, 80) } : {}),
      ...(truncated ? { truncated } : {}),
    };
    writeFileSync(join(this.dir, file), JSON.stringify({ ...entry, context: r.context ?? {}, payload: payload ?? null }, null, 2));
    appendFileSync(this.index, JSON.stringify(entry) + '\n');
    this.ids.add(key);
    this.log(`diagnostic from ${device}: ${entry.summary}`);
    this.prune();
    return { kept: true };
  }

  /** Every report kept, oldest first (the index, without payloads). */
  list(): DiagnosticEntry[] {
    let text = '';
    try { text = readFileSync(this.index, 'utf8'); } catch { return []; }
    return text.split('\n').filter(Boolean).flatMap((l) => { try { return [JSON.parse(l) as DiagnosticEntry]; } catch { return []; } });
  }

  private prune(): void {
    const files = readdirSync(this.dir).filter((f) => f.endsWith('.json')).sort();
    if (files.length <= MAX_REPORTS) return;
    const gone = new Set(files.slice(0, files.length - MAX_REPORTS));
    for (const f of gone) rmSync(join(this.dir, f), { force: true });
    const kept = this.list().filter((e) => !gone.has(e.file));
    writeFileSync(this.index, kept.map((e) => JSON.stringify(e) + '\n').join(''));
  }
}

/** The reports as lines to read: newest last. */
export function describeDiagnostics(entries: DiagnosticEntry[]): string {
  return entries.map((e) => `${e.at}  ${e.device.padEnd(8)} ${e.kind.padEnd(6)} ${e.summary}${e.build ? `  [${e.build}]` : ''}\n    ${e.file}`).join('\n');
}
