// The folders a client's explorer has open. A change in one (a file added, removed, renamed or written) is reported once
// things settle, so the client lists that folder again. Not recursive: only the folders it shows, so watching stays
// cheap even when the open project is a home folder.
import { watch, type FSWatcher } from 'node:fs';
import { isAbsolute } from 'node:path';

export class FolderWatch {
  private watchers = new Map<string, FSWatcher>();
  private timers = new Map<string, NodeJS.Timeout>();
  private onChange: (path: string) => void;
  private max: number;
  private settleMs: number;

  constructor(onChange: (path: string) => void, max = 64, settleMs = 250) {
    this.onChange = onChange;
    this.max = max;
    this.settleMs = settleMs;
  }

  get size(): number {
    return this.watchers.size;
  }

  /** Watch these folders (and stop watching the rest). Ones that don't exist or can't be read are skipped. */
  set(paths: string[]): void {
    const want = new Set(paths.filter((p) => typeof p === 'string' && isAbsolute(p)).slice(0, this.max));
    for (const p of [...this.watchers.keys()]) if (!want.has(p)) this.drop(p);
    for (const p of want) {
      if (this.watchers.has(p)) continue;
      try {
        const w = watch(p, { persistent: false }, () => this.changed(p));
        w.on('error', () => this.drop(p));
        this.watchers.set(p, w);
      } catch {
        // Gone, or not a folder we can read: nothing to watch.
      }
    }
  }

  close(): void {
    for (const p of [...this.watchers.keys()]) this.drop(p);
  }

  private changed(p: string): void {
    clearTimeout(this.timers.get(p));
    this.timers.set(p, setTimeout(() => {
      this.timers.delete(p);
      this.onChange(p);
    }, this.settleMs));
  }

  private drop(p: string): void {
    this.watchers.get(p)?.close();
    this.watchers.delete(p);
    clearTimeout(this.timers.get(p));
    this.timers.delete(p);
  }
}
