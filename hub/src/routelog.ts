// Every routed question, one JSON line each in the state folder: where it went and why, which worker answered, how
// long it took, whether its citations checked out, and when you overrode it. The material a learned router will be
// calibrated on (phase 2), and the numbers for a routing page in the app (phase 3).
import { appendFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import type { QuestionClass, Surface } from './routing.ts';

export type RouteEntry = {
  surface: Surface;
  /** The note's or the side chat's id. */
  id: string;
  by: string;
  cls: QuestionClass;
  to: 'local' | 'claude';
  why: string;
  /** What happened: answered locally, sent on to Claude (and why), or you asked Claude instead. */
  outcome: 'local' | 'escalated' | 'claude' | 'override';
  worker?: string;
  ms?: number;
  citations?: { checked: number; failed: number; fixed: number };
  tries?: number;
  escalated?: string;
  /** A local answer's length as shown, in words, and whether it ran past the limits and was cut (scout.ts). */
  words?: number;
  trimmed?: boolean;
};

export class RouteLog {
  private file: string;
  private log: (m: string) => void;

  constructor(stateDir: string, log: (m: string) => void = () => {}) {
    mkdirSync(stateDir, { recursive: true });
    this.file = join(stateDir, 'routing.jsonl');
    this.log = log;
  }

  write(e: RouteEntry): void {
    try {
      appendFileSync(this.file, JSON.stringify({ ts: new Date().toISOString(), ...e }) + '\n');
    } catch (err) {
      this.log(`routing log: ${err}`);
    }
  }

  get path(): string {
    return this.file;
  }
}
