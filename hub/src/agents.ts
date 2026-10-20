// Coding agents on the hub's machine, for Settings → Agents: Claude Code, Codex CLI, Cursor CLI, Antigravity CLI and
// Gemini CLI. For each, where it is, its version, and whether it's ready (installed and signed in), needs signing in,
// isn't installed, or is signed in a way its terms don't let an app like Doublet use (blocked).
//
// Finding one: the same search as the hub's own `claude` (claude.ts: PATH, then ~/.local/bin and ~/.claude/local), plus
// the places npm, Homebrew and the CLIs' own installers put things, since a service's PATH often leaves those out.
//
// Signing in: the agent's own status command where it has one (`claude auth status`, `codex login status`, `agent status`),
// which knows about keychains and sign-ins files miss. When that command is missing (an older version) or gives no clear
// answer, a best-effort guess from what's on disk or in the environment: each check says what it looks for. Nothing here
// reads a credential's value, only whether one is there. Sources for each command: docs/agents/*.md (2026-10-20).
import { execFile } from 'node:child_process';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { homedir, hostname } from 'node:os';
import { basename, join } from 'node:path';
import { claudeDirs, findClaude, findIn } from './claude.ts';
import type { AgentId, AgentInfo, AgentScan } from './protocol.ts';

/** What a scan may look at: the environment, the home folder, the platform, and how to run a command. Tests pass their own. */
export type ScanEnv = {
  env: NodeJS.ProcessEnv;
  home: string;
  platform: NodeJS.Platform;
  /** Runs a command: ok and its stdout; or not ok and its stdout if it printed any (status commands answer "signed out"
   *  with exit 1), else why (the first line of stderr, or that it took too long). */
  run: (file: string, args: string[], timeoutMs: number) => Promise<RunResult>;
  host?: string;
};

export type RunResult = { ok: boolean; out: string };

export const runCommand = (file: string, args: string[], timeoutMs: number) => new Promise<RunResult>((resolve) => {
  execFile(file, args, { timeout: timeoutMs, encoding: 'utf8', env: { ...process.env, NO_COLOR: '1' } }, (err, stdout, stderr) => {
    if (!err) return resolve({ ok: true, out: stdout });
    if ((err as { killed?: boolean }).killed) return resolve({ ok: false, out: `no answer within ${timeoutMs / 1000} s` });
    if (stdout.trim()) return resolve({ ok: false, out: stdout });
    resolve({ ok: false, out: (stderr || err.message).trim().split('\n')[0].slice(0, 200) });
  });
});

export function defaultScanEnv(): ScanEnv {
  return { env: process.env, home: homedir(), platform: process.platform, run: runCommand, host: hostname() };
}

/** A sign-in check: whether it found one, and what it looked for (shown when it didn't). `blocked`: signed in, but only
 *  in a way its terms don't allow an app like Doublet to use; the text says what would work instead. */
type SignIn = { found: boolean; checked: string; blocked?: string };

type AgentSpec = {
  id: AgentId;
  name: string;
  /** What it's usually run as; a scan reports the name it actually found (Cursor's `agent` or `cursor-agent`). */
  command: string;
  /** Other names it may be installed as (Cursor's older `cursor-agent`); a scan reports the one it found. */
  aliases?: string[];
  /** Where to find it, given the environment (the hub's own claudePath() search for Claude Code). */
  find: (s: ScanEnv) => string | null;
  /** Its own status command: whether it's signed in, or null when the command isn't there or doesn't say. */
  status?: (path: string, s: ScanEnv) => Promise<boolean | null>;
  /** The fallback guess from files and the environment. */
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

/** Terminal colour and cursor codes, which some CLIs print even with NO_COLOR. */
export const stripAnsi = (t: string) => t.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '');

/** `claude auth status`: JSON with `loggedIn` (exit 0 signed in, 1 not). Null when it isn't JSON (a version without the
 *  command). */
export function parseClaudeStatus(r: RunResult): boolean | null {
  try { const j = JSON.parse(r.out); return typeof j.loggedIn === 'boolean' ? j.loggedIn : null; } catch { return null; }
}

/** `codex login status`: exit 0 when signed in; "Not logged in" when not. Anything else (a crash) says nothing. */
export function parseCodexStatus(r: RunResult): boolean | null {
  if (r.ok) return true;
  return /not logged in|not signed in/i.test(r.out) ? false : null;
}

/** `agent status --format json` (current Cursor CLI), or plain `status` (older versions don't take --format). */
export function parseCursorStatus(r: RunResult): boolean | null {
  try {
    const j = JSON.parse(r.out) as Record<string, unknown>;
    for (const k of ['isAuthenticated', 'authenticated', 'loggedIn']) if (typeof j[k] === 'boolean') return j[k] as boolean;
    if (typeof j.email === 'string' || typeof j.account === 'string') return true;
  } catch { /* text */ }
  const t = stripAnsi(r.out);
  if (/not (logged|signed) in|not authenticated/i.test(t)) return false;
  if (/(logged|signed) in as|authenticated as/i.test(t)) return true;
  return null;
}

/** Cursor's CLI is `agent` now, `cursor-agent` before. `agent` is a common name, so it counts only when it resolves into
 *  Cursor's own install folder. */
export function findCursor(s: ScanEnv): string | null {
  const dirs = agentDirs(s.env, s.home);
  const agent = findIn('agent', dirs);
  if (agent) {
    try { if (/cursor/i.test(realpathSync(agent))) return agent; } catch { /* not resolvable */ }
  }
  return findIn('cursor-agent', dirs);
}

const AGY_SETTINGS = '.gemini/antigravity-cli/settings.json';
const AGY_BLOCKED = 'Signed in with a Google account: Antigravity\'s terms don\'t allow apps like Doublet to use a personal ' +
  'Google AI plan. Set GEMINI_API_KEY for the hub and "modelProvider": "gemini" in ~/' + AGY_SETTINGS + ', or use Gemini Enterprise.';
const GEMINI_BLOCKED = 'Gemini CLI no longer works with personal Google sign-ins (since June 2026). Set GEMINI_API_KEY for the ' +
  'hub, or use Vertex AI or Gemini Code Assist Standard or Enterprise.';

export const AGENTS: readonly AgentSpec[] = [
  {
    id: 'claude', name: 'Claude Code', command: 'claude',
    find: (s) => findClaude(s.env, s.home),
    status: async (path, s) => parseClaudeStatus(await s.run(path, ['auth', 'status'], 8000)),
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
    status: async (path, s) => parseCodexStatus(await s.run(path, ['login', 'status'], 8000)),
    howToSignIn: 'Run `codex login` on this machine (or set OPENAI_API_KEY).',
    // An API key in the environment, or the auth file `codex login` writes ($CODEX_HOME/auth.json, default ~/.codex).
    signIn: async (s) => {
      const dir = s.env.CODEX_HOME || file(s, '.codex');
      return { found: Boolean(hasEnv(s, 'OPENAI_API_KEY') || existsSync(join(dir, 'auth.json'))), checked: 'OPENAI_API_KEY, $CODEX_HOME/auth.json (~/.codex/auth.json)' };
    },
  },
  {
    id: 'cursor', name: 'Cursor CLI', command: 'agent', aliases: ['cursor-agent'],
    find: findCursor,
    status: async (path, s) => {
      const json = parseCursorStatus(await s.run(path, ['status', '--format', 'json'], 8000));
      return json ?? parseCursorStatus(await s.run(path, ['status'], 8000));
    },
    howToSignIn: 'Run `agent login` on this machine (or set CURSOR_API_KEY).',
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
    id: 'agy', name: 'Antigravity CLI', command: 'agy',
    find: (s) => findIn('agy', agentDirs(s.env, s.home)),
    howToSignIn: 'Set GEMINI_API_KEY for the hub and "modelProvider": "gemini" in ~/' + AGY_SETTINGS + ' (or use Gemini Enterprise).',
    // agy has no status command. Doublet may use it only with a Gemini API key (modelProvider "gemini" plus the key in the
    // environment) or an enterprise sign-in through Application Default Credentials (AGY_ADC_AUTH). A personal Google
    // sign-in lives in the keyring, which can't be checked without asking it; any other installed agy is taken to be one.
    signIn: async (s) => {
      const checked = 'GEMINI_API_KEY with modelProvider "gemini" in ~/' + AGY_SETTINGS + ', or AGY_ADC_AUTH';
      const provider = readJson(file(s, AGY_SETTINGS))?.modelProvider;
      if ((provider === 'gemini' && hasEnv(s, 'GEMINI_API_KEY')) || hasEnv(s, 'AGY_ADC_AUTH')) return { found: true, checked };
      return { found: false, checked, blocked: AGY_BLOCKED };
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
      const settings = readJson(file(s, '.gemini/settings.json'));
      const auth = settings?.selectedAuthType ?? (settings?.security as { auth?: { selectedType?: unknown } } | undefined)?.auth?.selectedType;
      // A personal Google sign-in (oauth-personal, its cached oauth_creds.json) no longer works; Vertex or Code Assist do.
      const personal = auth === 'oauth-personal' || (auth === undefined && existsSync(file(s, '.gemini/oauth_creds.json')));
      if (personal) return { found: false, checked, blocked: GEMINI_BLOCKED };
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
  const path = spec.find(s);
  const command = path && spec.aliases?.includes(basename(path)) ? basename(path) : spec.command;
  const base = { id: spec.id, name: spec.name, command };
  if (!path) return { ...base, state: 'not_installed' };
  const [ran, guess, told] = await Promise.all([
    s.run(path, ['--version'], 5000), spec.signIn(s), spec.status ? spec.status(path, s) : Promise.resolve(null),
  ]);
  const version = ran.ok ? versionIn(ran.out) : undefined;
  // Its own status command wins; the file guess only when it doesn't say. A blocked sign-in is never ready.
  const found = told ?? guess.found;
  const state: AgentInfo['state'] = found ? 'ready' : guess.blocked ? 'blocked' : 'needs_sign_in';
  const checked = told === null ? guess.checked : `\`${base.command} ${spec.id === 'claude' ? 'auth status' : spec.id === 'codex' ? 'login status' : 'status'}\``;
  return {
    ...base, path, ...(version ? { version } : {}),
    state,
    ...(state === 'blocked' ? { signIn: guess.blocked } : state === 'needs_sign_in' ? { signIn: `${spec.howToSignIn.replaceAll(`\`${spec.command} `, `\`${base.command} `)} (Looked for: ${checked}.)` } : {}),
    ...(ran.ok ? {} : { problem: `\`${base.command} --version\` failed (${ran.out.trim().split('\n')[0].slice(0, 200) || 'no output'}): it may not run. Reinstall it?` }),
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
