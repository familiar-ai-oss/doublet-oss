// Coding agents on the hub's machine, for Settings → Agents: Claude Code, Codex CLI, Cursor CLI and Gemini CLI. For each,
// where it is, its version, and whether it's ready (installed and signed in), needs signing in, or isn't installed.
//
// Finding one: the same search as the hub's own `claude` (claude.ts: PATH, then ~/.local/bin and ~/.claude/local), plus
// the places npm, Homebrew and the CLIs' own installers put things, since a service's PATH often leaves those out.
//
// Signing in is a best-effort guess from what's on disk or in the environment, never a call to the provider: each check
// says what it looks for (`signIn`). Nothing here reads a credential's value, only whether one is there.
import { execFile } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir, hostname } from 'node:os';
import { join } from 'node:path';
import { claudeDirs, findClaude, findIn } from './claude.ts';
import type { AgentId, AgentInfo, AgentScan } from './protocol.ts';

/** What a scan may look at: the environment, the home folder, the platform, and how to run a command. Tests pass their own. */
export type ScanEnv = {
  env: NodeJS.ProcessEnv;
  home: string;
  platform: NodeJS.Platform;
  /** Runs a command: ok and its stdout, or not ok and why (its stderr, or that it took too long). */
  run: (file: string, args: string[], timeoutMs: number) => Promise<RunResult>;
  host?: string;
};

export type RunResult = { ok: boolean; out: string };

export const runCommand = (file: string, args: string[], timeoutMs: number) => new Promise<RunResult>((resolve) => {
  execFile(file, args, { timeout: timeoutMs, encoding: 'utf8', env: { ...process.env, NO_COLOR: '1' } }, (err, stdout, stderr) => {
    if (!err) return resolve({ ok: true, out: stdout });
    const why = (err as { killed?: boolean }).killed ? `no answer within ${timeoutMs / 1000} s` : (stderr || err.message).trim().split('\n')[0].slice(0, 200);
    resolve({ ok: false, out: why });
  });
});

export function defaultScanEnv(): ScanEnv {
  return { env: process.env, home: homedir(), platform: process.platform, run: runCommand, host: hostname() };
}

/** A sign-in check: whether it found one, and what it looked for (shown when it didn't). */
type SignIn = { found: boolean; checked: string };

type AgentSpec = {
  id: AgentId;
  name: string;
  command: string;
  /** Where to find it, given the environment (the hub's own claudePath() search for Claude Code). */
  find: (s: ScanEnv) => string | null;
  signIn: (s: ScanEnv) => Promise<SignIn>;
  /** How to sign in, for the app to show beside "Needs sign-in". */
  howToSignIn: string;
};

/** Directories other CLIs commonly install to, after PATH and Claude Code's own. */
export function agentDirs(env: NodeJS.ProcessEnv, home: string): string[] {
  return [
    ...claudeDirs(env, home),
    join(home, '.npm-global/bin'), join(home, '.bun/bin'), join(home, '.volta/bin'), join(home, '.cargo/bin'),
    '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin',
  ];
}

const hasEnv = (s: ScanEnv, ...names: string[]) => names.find((n) => (s.env[n] ?? '').trim() !== '');
const file = (s: ScanEnv, ...parts: string[]) => join(s.home, ...parts);
function readJson(path: string): Record<string, unknown> | null {
  try { return JSON.parse(readFileSync(path, 'utf8')); } catch { return null; }
}

/** macOS keychain: whether a generic password with this service exists (`security find-generic-password -s`, without
 *  -w, prints only its attributes, never the secret). Elsewhere: never. */
async function inKeychain(s: ScanEnv, service: string): Promise<boolean> {
  if (s.platform !== 'darwin') return false;
  return (await s.run('/usr/bin/security', ['find-generic-password', '-s', service], 3000)).ok;
}

export const AGENTS: readonly AgentSpec[] = [
  {
    id: 'claude', name: 'Claude Code', command: 'claude',
    find: (s) => findClaude(s.env, s.home),
    howToSignIn: 'Run `claude` on this machine and sign in (or set ANTHROPIC_API_KEY).',
    // An API key or long-lived token in the environment, a cloud provider switched on, Linux's credentials file, the
    // account Claude Code records in ~/.claude.json, or (macOS) its keychain item.
    signIn: async (s) => {
      const checked = 'ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN / Bedrock or Vertex, ~/.claude/.credentials.json, ~/.claude.json oauthAccount, keychain "Claude Code-credentials"';
      if (hasEnv(s, 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX')) return { found: true, checked };
      if (existsSync(file(s, '.claude/.credentials.json'))) return { found: true, checked };
      if (readJson(file(s, '.claude.json'))?.oauthAccount) return { found: true, checked };
      return { found: await inKeychain(s, 'Claude Code-credentials'), checked };
    },
  },
  {
    id: 'codex', name: 'Codex CLI', command: 'codex',
    find: (s) => findIn('codex', agentDirs(s.env, s.home)),
    howToSignIn: 'Run `codex login` on this machine (or set OPENAI_API_KEY).',
    // An API key in the environment, or the auth file `codex login` writes ($CODEX_HOME/auth.json, default ~/.codex).
    signIn: async (s) => {
      const dir = s.env.CODEX_HOME || file(s, '.codex');
      return { found: Boolean(hasEnv(s, 'OPENAI_API_KEY') || existsSync(join(dir, 'auth.json'))), checked: 'OPENAI_API_KEY, $CODEX_HOME/auth.json (~/.codex/auth.json)' };
    },
  },
  {
    id: 'cursor', name: 'Cursor CLI', command: 'cursor-agent',
    find: (s) => findIn('cursor-agent', agentDirs(s.env, s.home)),
    howToSignIn: 'Run `cursor-agent login` on this machine (or set CURSOR_API_KEY).',
    // An API key in the environment, the token file `cursor-agent login` writes on Linux, the sign-in it records in
    // ~/.cursor/cli-config.json, or (macOS) its keychain item.
    signIn: async (s) => {
      const checked = 'CURSOR_API_KEY, ~/.config/cursor/auth.json, ~/.cursor/cli-config.json authInfo, keychain "cursor-access-token"';
      if (hasEnv(s, 'CURSOR_API_KEY')) return { found: true, checked };
      if (existsSync(file(s, '.config/cursor/auth.json'))) return { found: true, checked };
      if (readJson(file(s, '.cursor/cli-config.json'))?.authInfo) return { found: true, checked };
      return { found: await inKeychain(s, 'cursor-access-token'), checked };
    },
  },
  {
    id: 'gemini', name: 'Gemini CLI', command: 'gemini',
    find: (s) => findIn('gemini', agentDirs(s.env, s.home)),
    howToSignIn: 'Run `gemini` on this machine and choose a sign-in (or set GEMINI_API_KEY).',
    // An API key or Vertex in the environment, the Google sign-in it caches (~/.gemini/oauth_creds.json), or an auth
    // type chosen in its settings (which means it was set up, though a key it names may still be missing).
    signIn: async (s) => {
      const checked = 'GEMINI_API_KEY / GOOGLE_API_KEY / GOOGLE_GENAI_USE_VERTEXAI, ~/.gemini/oauth_creds.json, ~/.gemini/settings.json auth type';
      if (hasEnv(s, 'GEMINI_API_KEY', 'GOOGLE_API_KEY', 'GOOGLE_GENAI_USE_VERTEXAI')) return { found: true, checked };
      if (existsSync(file(s, '.gemini/oauth_creds.json'))) return { found: true, checked };
      const settings = readJson(file(s, '.gemini/settings.json'));
      const auth = settings?.selectedAuthType ?? (settings?.security as { auth?: { selectedType?: unknown } } | undefined)?.auth?.selectedType;
      return { found: typeof auth === 'string' && auth !== '', checked };
    },
  },
];

/** The first version number in a CLI's `--version` output ("codex-cli 0.47.0" → "0.47.0"). */
export function versionIn(out: string | null | undefined): string | undefined {
  return out?.match(/\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?/)?.[0];
}

/**
 * One agent: not installed, or where it is, its version (`--version`, cut off after 5 s) and whether it's signed in.
 * `problem`: `--version` failed, so it may not run at all (a broken install), whatever its sign-in says.
 */
export async function scanAgent(spec: AgentSpec, s: ScanEnv): Promise<AgentInfo> {
  const base = { id: spec.id, name: spec.name, command: spec.command };
  const path = spec.find(s);
  if (!path) return { ...base, state: 'not_installed' };
  const [ran, signIn] = await Promise.all([s.run(path, ['--version'], 5000), spec.signIn(s)]);
  const version = ran.ok ? versionIn(ran.out) : undefined;
  return {
    ...base, path, ...(version ? { version } : {}),
    state: signIn.found ? 'ready' : 'needs_sign_in',
    ...(signIn.found ? {} : { signIn: `${spec.howToSignIn} (Looked for: ${signIn.checked}.)` }),
    ...(ran.ok ? {} : { problem: `\`${spec.command} --version\` failed (${ran.out || 'no output'}): it may not run. Reinstall it?` }),
  };
}

/** Every agent, scanned at once. */
export async function scanAgents(s: ScanEnv = defaultScanEnv()): Promise<AgentScan> {
  const agents = await Promise.all(AGENTS.map((a) => scanAgent(a, s)));
  return { host: s.host ?? '', platform: s.platform, scannedAt: Date.now(), agents };
}

/** The last scan, kept until a rescan: a scan runs four CLIs, so listing again is free. */
export class AgentScanner {
  private last: Promise<AgentScan> | null = null;
  private readonly env: () => ScanEnv;
  constructor(env: () => ScanEnv = defaultScanEnv) {
    this.env = env;
  }
  list(): Promise<AgentScan> {
    return (this.last ??= this.scan());
  }
  scan(): Promise<AgentScan> {
    const p = scanAgents(this.env());
    this.last = p;
    // A failed scan isn't kept: the next list tries again.
    p.catch(() => { if (this.last === p) this.last = null; });
    return p;
  }
}
