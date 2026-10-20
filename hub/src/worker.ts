// One task on one local worker: its own Agent SDK session, pointed at the worker proxy.
// Its tools come from the task's profile (profiles.ts), all slim sets (Phase 0: the 9B made up a result on the full
// 20-tool harness, and slim was 3x faster to first token).
import { query } from '@anthropic-ai/claude-agent-sdk';
import type { HookCallbackMatcher, HookEvent, McpSdkServerConfigWithInstance, SDKMessage } from '@anthropic-ai/claude-agent-sdk';
import { execFile } from 'node:child_process';
import { resolve as resolvePath, sep } from 'node:path';
import { promisify } from 'node:util';
import { baseEnv } from './lead.ts';
import { claudeExecutable } from './claude.ts';
import { compactionEnv, turnWarning } from './context.ts';
import { readOnlyRefusal } from './profiles.ts';
import { fetchRefusal, sitesIn } from './web.ts';
import type { ToolCall } from './protocol.ts';

const run = promisify(execFile);

export type WorkerRun = {
  cwd: string;
  prompt: string;
  baseUrl: string;
  tools: readonly string[];
  maxTurns?: number;
  /** The model's real window in tokens: Claude Code compacts to fit it (context.ts). Unknown: its own default. */
  contextTokens?: number;
  /** For the hub's log: when the worker compacts. */
  log?: (m: string) => void;
  /** A read-only profile: no file edits, and Bash only for commands that read. */
  readOnly?: boolean;
  /** Files outside cwd the task names (delegate's `files`): the worker may read these, and only these, out there. */
  readable?: readonly string[];
  signal: AbortSignal;
  onProgress: (p: { text?: string; tools?: string[]; toolUses?: ToolCall[]; toolResult?: string }) => void;
  // From the dialogue layer: the worker's duet tools (ask_lead, report) and its STEER/Stop hooks.
  mcpServers?: Record<string, McpSdkServerConfigWithInstance>;
  hooks?: Partial<Record<HookEvent, HookCallbackMatcher[]>>;
};

export type WorkerOutcome = { ok: boolean; result: string; subtype: string; numTurns?: number; error?: string; tools: ToolCount[] };

/** One tool a worker called, counted by the hub from its session rather than its report: how often, how many of those
 *  calls the guard or its profile refused, and how many failed (an error from the tool itself). */
export type ToolCount = { name: string; calls: number; refused: number; failed: number };

/** The tools a worker calls, as they run. A call is refused when the guard denies it or its profile doesn't have it. */
export class ToolLog {
  private names = new Map<string, string>();
  private denied = new Set<string>();
  private counts = new Map<string, ToolCount>();
  private readonly allowed: readonly string[];
  constructor(allowed: readonly string[]) {
    this.allowed = allowed;
  }

  call(id: string, name: string): void {
    this.names.set(id, name);
    const c = this.counts.get(name) ?? { name, calls: 0, refused: 0, failed: 0 };
    c.calls++;
    this.counts.set(name, c);
  }

  /** The guard turned the call away (it may hear of it before or after the call itself). */
  refuse(id: string): void {
    this.denied.add(id);
  }

  result(id: string, isError: boolean): void {
    const name = this.names.get(id);
    const c = name === undefined ? undefined : this.counts.get(name);
    if (!c) return;
    if (this.denied.has(id) || !this.allowed.includes(c.name)) c.refused++;
    else if (isError) c.failed++;
  }

  /** In the order first called. */
  list(): ToolCount[] {
    return [...this.counts.values()].map((c) => ({ ...c }));
  }
}

// Guard rails until Phase 3 adds the full set: no commits/pushes, no network clients, file tools stay in the project.
const BLOCKED_BASH = /\bgit\s+(commit|push|reset\s+--hard|clean)\b|\b(curl|wget|ssh|scp|rsync|nc)\b|\bsudo\b/;

const READ_TOOLS = ['Read', 'Glob', 'Grep'];

/**
 * `sites`: sites the task names, whose pages a WebFetch may open besides documentation and code-hosting sites.
 * `readable`: files outside cwd the task names, which the file tools may read (and only read). `onRefuse` hears of
 * each call turned away, by its tool_use id.
 */
export function guard(cwd: string, readOnly = false, sites: string[] = [], extra: { readable?: readonly string[]; onRefuse?: (toolUseId: string) => void } = {}): HookCallbackMatcher[] {
  const root = resolvePath(cwd);
  const readable = new Set((extra.readable ?? []).map((f) => resolvePath(root, f)));
  return [{
    hooks: [async (input) => {
      if (input.hook_event_name !== 'PreToolUse') return {};
      const ti = input.tool_input as Record<string, unknown>;
      let reason: string | null = null;
      if (input.tool_name === 'Bash' && typeof ti.command === 'string' && BLOCKED_BASH.test(ti.command)) {
        reason = 'Doublet workers may not commit, push, use the network or sudo. Leave that to the lead.';
      }
      if (!reason && readOnly && input.tool_name === 'Bash' && typeof ti.command === 'string') reason = readOnlyRefusal(ti.command);
      if (!reason && input.tool_name === 'WebFetch') reason = fetchRefusal(String(ti.url ?? ''), sites);
      if (!reason && readOnly && ['Edit', 'Write', 'MultiEdit', 'NotebookEdit'].includes(input.tool_name)) {
        reason = 'This task is read-only: report what should change instead of changing it.';
      }
      const p = (ti.file_path ?? ti.path) as string | undefined;
      const abs = typeof p === 'string' ? resolvePath(root, p) : null;
      if (!reason && abs && abs !== root && !abs.startsWith(root + sep)) {
        reason = !readable.has(abs)
          ? `Stay inside the project directory ${root}. If the task needs ${abs}, you can't do that part: report outcome "blocked" and name the path.`
          : READ_TOOLS.includes(input.tool_name) ? null : `${abs} is outside the project directory ${root}: you may read it, not change it.`;
      }
      if (!reason) return {};
      extra.onRefuse?.(input.tool_use_id);
      return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } };
    }],
  }];
}

export async function runWorker(r: WorkerRun): Promise<WorkerOutcome> {
  const abortController = new AbortController();
  r.signal.addEventListener('abort', () => abortController.abort(), { once: true });
  // Every model tier maps to the one name the proxy expects; the proxy forces the real backend model anyway.
  const model = 'sonnet';
  const env = {
    ...baseEnv(),
    ANTHROPIC_BASE_URL: r.baseUrl,
    ANTHROPIC_AUTH_TOKEN: 'local',
    ANTHROPIC_MODEL: model,
    ANTHROPIC_DEFAULT_OPUS_MODEL: model,
    ANTHROPIC_DEFAULT_SONNET_MODEL: model,
    ANTHROPIC_DEFAULT_HAIKU_MODEL: model,
    ANTHROPIC_SMALL_FAST_MODEL: model,
    CLAUDE_CODE_SUBAGENT_MODEL: model,
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1',
    DISABLE_TELEMETRY: '1',
    // Claude Code takes the model for Sonnet and would compact only near Sonnet's window: fit it to the real one.
    ...(r.contextTokens ? compactionEnv(r.contextTokens) : {}),
  };
  // Turns used so far (each of the model's replies counts once), and the warnings already given as they run out.
  const maxTurns = r.maxTurns ?? 40;
  let turns = 0;
  const replies = new Set<string>();
  const warned = new Set<number>();
  const canReport = Boolean(r.mcpServers?.duet);
  // After a compaction, the task again in full: a small model's summary can lose it, and then the worker wanders off.
  const afterCompact: HookCallbackMatcher = {
    hooks: [async (input) => {
      if (input.hook_event_name !== 'SessionStart' || input.source !== 'compact') return {};
      return { hookSpecificOutput: { hookEventName: 'SessionStart' as const, additionalContext: compactedTask(r.prompt) } };
    }],
  };
  const turnsLeft: HookCallbackMatcher = {
    hooks: [async (input) => {
      if (input.hook_event_name !== 'PostToolUse') return {};
      const note = turnWarning(turns, maxTurns, canReport);
      if (!note || warned.has(maxTurns - turns)) return {};
      warned.add(maxTurns - turns);
      r.log?.(`${maxTurns - turns} of ${maxTurns} turns left: asked it to wrap up`);
      return { hookSpecificOutput: { hookEventName: 'PostToolUse' as const, additionalContext: note } };
    }],
  };
  let result = '';
  let subtype = 'unknown';
  let numTurns: number | undefined;
  const toolLog = new ToolLog(r.tools);
  try {
    const q = query({
      prompt: r.prompt,
      options: {
        ...claudeExecutable(),
        cwd: r.cwd,
        env,
        model,
        tools: [...r.tools],
        settingSources: [],
        // The guard checks which sites a worker fetches; the fetch itself shouldn't wait on a check at Anthropic.
        settings: { crossSessionInbound: 'refuse', skipWebFetchPreflight: true },
        disallowedTools: ['SendMessage', 'ListAgents'],
        permissionMode: 'bypassPermissions',
        allowDangerouslySkipPermissions: true,
        persistSession: false,
        maxTurns,
        hooks: {
          ...r.hooks,
          PreToolUse: [...guard(r.cwd, r.readOnly, sitesIn(r.prompt), { readable: r.readable, onRefuse: (id) => toolLog.refuse(id) }), ...(r.hooks?.PreToolUse ?? [])],
          PostToolUse: [turnsLeft, ...(r.hooks?.PostToolUse ?? [])],
          SessionStart: [afterCompact, ...(r.hooks?.SessionStart ?? [])],
        },
        mcpServers: r.mcpServers,
        abortController,
      },
    });
    // The duet tools (ask_lead, report) already show as QUESTION/STATUS/RESULT cards, so their calls aren't progress.
    const duetCalls = new Set<string>();
    for await (const m of q as AsyncIterable<SDKMessage>) {
      if (m.type === 'assistant' && m.parent_tool_use_id === null && !replies.has(m.message.id)) {
        replies.add(m.message.id);
        turns = replies.size;
      }
      if (m.type === 'system' && m.subtype === 'compact_boundary') {
        r.log?.(`compacted its conversation (${m.compact_metadata.trigger}): ${m.compact_metadata.pre_tokens} tokens before`);
      }
      if (m.type === 'assistant' && m.parent_tool_use_id === null) {
        const text = m.message.content.flatMap((b) => (b.type === 'text' ? [b.text] : [])).join('');
        const calls = m.message.content.flatMap((b) => (b.type === 'tool_use' ? [b] : []));
        for (const b of calls) if (b.name.startsWith(DUET_TOOLS)) duetCalls.add(b.id);
        const shown = calls.filter((b) => !duetCalls.has(b.id));
        for (const b of shown) toolLog.call(b.id, b.name);
        const tools = shown.map((b) => `${b.name} ${JSON.stringify(b.input).slice(0, 160)}`);
        const toolUses = shown.map((b) => ({ name: b.name, input: clip(b.input) }));
        if (text || tools.length) r.onProgress({ text: text || undefined, tools: tools.length ? tools : undefined, toolUses: toolUses.length ? toolUses : undefined });
      } else if (m.type === 'user' && m.parent_tool_use_id === null && Array.isArray(m.message.content)) {
        for (const b of m.message.content) {
          if (typeof b === 'object' && b && b.type === 'tool_result' && !duetCalls.has(b.tool_use_id)) {
            toolLog.result(b.tool_use_id, b.is_error === true);
            r.onProgress({ toolResult: resultText(b.content).slice(0, 500) });
          }
        }
      } else if (m.type === 'result') {
        subtype = m.subtype;
        numTurns = m.num_turns;
        if (m.subtype === 'success') result = m.result;
      }
    }
    return { ok: subtype === 'success', result, subtype, numTurns, tools: toolLog.list() };
  } catch (err) {
    if (r.signal.aborted) return { ok: false, result, subtype: 'cancelled', numTurns, tools: toolLog.list() };
    return { ok: false, result, subtype: errorSubtype(String(err)), numTurns, error: String(err).slice(0, 500), tools: toolLog.list() };
  }
}

/** What a worker is told right after its conversation is compacted: its task, word for word, and to carry on. */
export function compactedTask(prompt: string): string {
  return `Your conversation was just compacted to fit your model. Your task, exactly as you were given it:\n\n${prompt}\n\nCarry on from where the summary says you were; don't start over, and don't drop any part of the task.`;
}

/** The SDK ends a run that hit its turn limit by throwing, not with an error_max_turns result: name it the same. */
export function errorSubtype(message: string): string {
  return /Reached maximum number of turns/i.test(message) ? 'error_max_turns' : 'error';
}

const DUET_TOOLS = 'mcp__duet__';

// Long strings (file contents, long commands) are cut, so a progress event stays small but its input stays valid JSON.
export function clip(v: unknown, depth = 0): unknown {
  if (typeof v === 'string') return v.length > 300 ? `${v.slice(0, 300)}…` : v;
  if (Array.isArray(v)) return v.slice(0, 20).map((x) => clip(x, depth + 1));
  if (v && typeof v === 'object' && depth < 4) return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, clip(x, depth + 1)]));
  return v;
}

// A tool result as text. MCP and many built-in tools return an array of content blocks.
export function resultText(c: unknown): string {
  if (typeof c === 'string') return c;
  if (Array.isArray(c)) {
    return c.map((b) => (b && typeof b === 'object' ? ('text' in b ? String(b.text) : (b as { type?: string }).type === 'image' ? '[image]' : '') : '')).filter(Boolean).join('\n');
  }
  return JSON.stringify(c ?? '');
}

// A task folder's full diff, for reading and annotating: tracked changes, then each new file. Capped for phones.
export async function fullDiff(cwd: string, max = 200_000): Promise<{ diff: string; truncated: boolean; error?: string }> {
  try {
    let diff = (await run('git', ['-C', cwd, 'diff', '--no-color'], { maxBuffer: 16 << 20 })).stdout;
    const added = (await run('git', ['-C', cwd, 'ls-files', '--others', '--exclude-standard'])).stdout.split('\n').filter(Boolean);
    for (const f of added.slice(0, 40)) {
      if (diff.length > max) break;
      // --no-index exits 1 when the files differ, which they always do here.
      const r = await run('git', ['-C', cwd, 'diff', '--no-color', '--no-index', '--', '/dev/null', f], { maxBuffer: 16 << 20 }).catch((e: { stdout?: string }) => e);
      diff += r.stdout ?? '';
    }
    return diff.length > max ? { diff: diff.slice(0, max), truncated: true } : { diff, truncated: false };
  } catch {
    return { diff: '', truncated: false, error: 'not a git repository' };
  }
}

// What actually changed, measured by the hub rather than reported by the model.
export async function evidence(cwd: string): Promise<string> {
  try {
    const stat = (await run('git', ['-C', cwd, 'diff', '--stat'])).stdout.trim();
    const status = (await run('git', ['-C', cwd, 'status', '--short'])).stdout.trim();
    return [stat && `diff --stat:\n${stat}`, status && `status:\n${status}`].filter(Boolean).join('\n') || 'no changes';
  } catch {
    return 'not a git repository';
  }
}
