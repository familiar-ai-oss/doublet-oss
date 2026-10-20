// The Claude Code the hub runs: the hub user's own installed `claude`, as they signed it in (an API key, a Claude plan,
// or a cloud provider), never a copy of the hub's own. The hub never sees or handles that login.
// Set DUET_CLAUDE_PATH to use one that isn't on PATH.
import { accessSync, constants, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { delimiter, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

let found: string | null | undefined;

/** The path of the `claude` to run, or null when there's none. */
export function claudePath(): string | null {
  if (found !== undefined) return found;
  const runnable = (p: string) => { try { accessSync(p, constants.X_OK); return true; } catch { return false; } };
  const set = process.env.DUET_CLAUDE_PATH;
  if (set) return (found = runnable(set) ? set : null);
  // PATH, then where Claude Code's installers put it (a service's PATH may leave those out).
  const dirs = [...(process.env.PATH ?? '').split(delimiter), join(homedir(), '.local/bin'), join(homedir(), '.claude/local')];
  return (found = dirs.filter(Boolean).map((d) => join(d, 'claude')).find(runnable) ?? null);
}

export const NO_CLAUDE = 'Claude Code isn\'t installed for the hub\'s user: install it, run `claude` once and sign in, then ' +
  'restart the hub (or set DUET_CLAUDE_PATH to it).';

/** The SDK option that runs the user's `claude`. With none found it names plain `claude`, which then fails to start
 *  (the lead checks claudePath() first, to say why). */
export function claudeExecutable(): { pathToClaudeCodeExecutable: string } {
  return { pathToClaudeCodeExecutable: claudePath() ?? 'claude' };
}

/** The Claude Code version this Agent SDK was built with: the oldest `claude` the hub is sure to work with. */
export function sdkClaudeVersion(): string | null {
  try {
    const pkg = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.resolve('@anthropic-ai/claude-agent-sdk'))), 'package.json'), 'utf8'));
    return typeof pkg.claudeCodeVersion === 'string' ? pkg.claudeCodeVersion : null;
  } catch { return null; }
}

/** `claude --version`'s number (e.g. "2.1.303"), or null. */
export function claudeVersion(): string | null {
  const p = claudePath();
  if (!p) return null;
  try {
    return execFileSync(p, ['--version'], { encoding: 'utf8', timeout: 15_000 }).match(/\d+\.\d+\.\d+/)?.[0] ?? null;
  } catch { return null; }
}

/** Whether version a is older than b ("2.1.9" < "2.1.301"). */
export function olderThan(a: string, b: string): boolean {
  const x = a.split('.').map(Number), y = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) < (y[i] ?? 0);
  return false;
}
