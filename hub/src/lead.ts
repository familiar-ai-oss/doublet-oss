// The lead: one long-lived Agent SDK session on the Max login.
// Turns are 1:1 with prompts: the hub queues them while Claude Code can't take them, and sends what you write while
// Claude works straight to Claude Code, which takes it at Claude's next tool call. Tool approvals go to clients via canUseTool.
import { getSessionInfo, query } from '@anthropic-ai/claude-agent-sdk';
import { claudeExecutable, claudePath, NO_CLAUDE } from './claude.ts';
import type {
  CanUseTool, HookCallback, HookCallbackMatcher, HookEvent, McpSdkServerConfigWithInstance, Options, PermissionResult, Query, SDKMessage,
  SDKTaskNotificationMessage, SDKTaskProgressMessage, SDKTaskStartedMessage, SDKTaskUpdatedMessage, SDKUserMessage,
} from '@anthropic-ai/claude-agent-sdk';
import { randomUUID } from 'node:crypto';
import { existsSync, statSync } from 'node:fs';
import { PERMISSION_MODES, type EffortLevel, type EventBody, type HubEvent, type LeadModel, type Notes, type PermissionMode, type ToolCall, type ToolUse } from './protocol.ts';
import { clip, resultText } from './worker.ts';
import type { StateFile } from './store.ts';

export type LeadConfig = {
  model: string;
  effort: EffortLevel;
  cwd: string;
  // Tools that run without asking. Everything else becomes an approval card.
  autoAllow: string[];
  // Built-in tools Claude doesn't get.
  disallowedTools?: string[];
  log: (msg: string) => void;
  // Dialogue layer (Phase 3). A factory, because a restarted session needs fresh MCP server instances.
  mcpServers?: () => Record<string, McpSdkServerConfigWithInstance>;
  hooks?: Partial<Record<HookEvent, HookCallbackMatcher[]>>;
  onTurnStart?: () => void;
  onIdle?: () => void;
  /** Handwritten notes reached Claude in this turn (at its start, or after a tool call mid-turn). */
  onNotesTaken?: (noteIds: string[], turn: number) => void;
  /** The user wrote while Claude works (a prompt or a note): it reaches Claude after its next tool call, so a waiting
   *  await_workers should return. */
  onUserWaiting?: () => void;
  /** Claude's own subagents (its Agent tool), shown as workers. */
  subagents?: SubagentPort;
};

export type SubagentPort = {
  /** Claude called its Agent tool, or (`info.parent`) one of its subagents did: a task of the subagent's kind. */
  start(toolUseId: string, kind: string, prompt: string, info?: SubagentInfo): void;
  progress(toolUseId: string, p: { text?: string; toolUses?: ToolCall[]; toolResult?: string; usage?: { messageId: string; input: number; output: number } }): void;
  isSubagent(toolUseId: string): boolean;
  /** It runs in the background now: its call returned at once, and it ends later, with its own notice. */
  background(toolUseId: string): void;
  end(toolUseId: string, state: 'done' | 'failed' | 'cancelled', result: string, outcome?: SubagentOutcome): void;
  /** Claude's turn ended, cutting off the subagents it waited on; or (`all`) Claude Code stopped, and every one with it. */
  stopped(all?: boolean): void;
};

/** A subagent as it starts: the few words Claude gave it, and, for one a subagent started, that one's Agent call and
 *  how deep it is (Claude Code's spawn depth: 2 for a subagent's own subagent). */
export type SubagentInfo = { label?: string; background?: boolean; parent?: string; depth?: number };

/** What Claude Code reports about a finished subagent: the Agent tool's structured result, or a background subagent's
 *  end notice, which counts only its tokens in all (`totalTokens`). */
export type SubagentOutcome = {
  report: string; toolUses: number; durationMs: number; model?: string;
  inputTokens?: number; outputTokens?: number; totalTokens?: number;
  edits?: { files: number; added: number; removed: number };
};

/** How long a background subagent can be missing from Claude Code's list of running work, with no end notice, before
 *  it ends as lost. */
export const LOST_AFTER_MS = 30_000;
export const LOST_NOTE = "Doublet lost track of this subagent: Claude Code stopped listing it as running and never said how it ended.";
const LATE_NOTE = "Claude Code said this subagent ended, but its report never reached Doublet.";

/** Claude Code's word for how a subagent's task ended, as a task state. */
const ENDED: Record<SDKTaskNotificationMessage['status'], 'done' | 'failed' | 'cancelled'> = { completed: 'done', failed: 'failed', stopped: 'cancelled' };

type AgentUsage = { total_tokens: number; tool_uses: number; duration_ms: number };

/** One of Claude's subagents as the hub follows it in Claude Code, by the Agent call that started it, until it ends. */
type AgentRun = {
  /** Claude Code's task id for it (task_started). */
  taskId?: string;
  /** It runs in the background: its call returned at once, and its end comes as a notice. */
  background: boolean;
  /** For a subagent's own subagent: the Agent call of the subagent that started it. */
  parent?: string;
  /** Claude Code said it ended (task_updated), with its notice to follow. */
  endedAs?: 'completed' | 'failed' | 'killed';
  usage?: AgentUsage;
  /** Missing from Claude Code's running work: it's lost when this fires, unless it comes back or ends first. */
  missing?: NodeJS.Timeout;
};

/** A subagent's report from its end notice: what it handed back (with any warning Claude Code put on it), else what
 *  it said last (Claude Code's summary of a subagent). Empty: the task's result is the summary. */
function handedBack(m: SDKTaskNotificationMessage): string {
  const h = (m as { handback_report?: unknown }).handback_report;
  if (typeof h === 'string') return h;
  if (!h || typeof h !== 'object' || typeof (h as { text?: unknown }).text !== 'string') return '';
  const { text, warning } = h as { text: string; warning?: unknown };
  return typeof warning === 'string' && warning ? `${warning}\n${text}` : text;
}

/** The parts of the SDK's AgentOutput that Duet shows. */
function subagentOutcome(r: unknown): SubagentOutcome | undefined {
  if (!r || typeof r !== 'object') return undefined;
  const o = r as Record<string, any>;
  if (o.status !== 'completed' || !Array.isArray(o.content)) return undefined;
  const u = o.usage ?? {};
  return {
    report: o.content.map((c: { text?: string }) => c.text ?? '').join('\n').trim(),
    inputTokens: (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0),
    outputTokens: u.output_tokens ?? 0,
    toolUses: o.totalToolUseCount ?? 0,
    durationMs: o.totalDurationMs ?? 0,
    model: o.resolvedModel,
    ...(o.toolStats ? { edits: { files: o.toolStats.editFileCount ?? 0, added: o.toolStats.linesAdded ?? 0, removed: o.toolStats.linesRemoved ?? 0 } } : {}),
  };
}

/** Claude Code's tool for starting a subagent (called Task in older versions). */
const AGENT_TOOLS = new Set(['Agent', 'Task']);

/** Claude asks to leave plan mode with its plan, which Claude Code reads from its plan file into the call's input. */
const EXIT_PLAN = 'ExitPlanMode';

const isMode = (m: unknown): m is PermissionMode => (PERMISSION_MODES as readonly unknown[]).includes(m);

type Pending = { resolve: (r: PermissionResult) => void; input: Record<string, unknown>; tool: string; toolUseId?: string };
export type Image = { data: string; type: 'image/png' | 'image/jpeg' };
// held: shown to the user as waiting for Claude (a `queued` event) until Claude takes it. sent: the words as Claude
// Code got them, for one sent while Claude works.
type Queued = { text: string; by: string; images?: Image[]; notes?: Notes; noteIds?: string[]; voice?: boolean; held?: string; sent?: string };

/** At the hub's start: the prompts the last run held for Claude, which went with it (the queue lives in memory). */
export function droppedAtStart(log: HubEvent[]): EventBody[] {
  const held = new Map<string, string | undefined>();
  for (const e of log) if (e.type === 'queued') e.state === 'waiting' ? held.set(e.id, e.conversationId) : held.delete(e.id);
  return [...held].map(([id, conversationId]) => ({ type: 'queued', id, state: 'dropped', reason: 'the hub restarted before Claude took it', ...(conversationId ? { conversationId } : {}) }));
}

/** What can go to Claude while it works: the user's own words. Commands (/compact) and the hub's own turns wait for
 *  the turn's end. */
const midTurn = (q: Queued) => q.by !== 'duet' && !q.text.startsWith('/');

/**
 * A spoken turn (Talk mode): the app reads Claude's replies aloud, skipping code blocks and tables, which stay on
 * screen. So the spoken part should be short, plain and first.
 */
export const VOICE_GUIDANCE =
  "[duet] The user is talking with you in Talk mode: your replies are read aloud to them (code blocks and tables are skipped; they stay on screen). Open with the answer in one to three short, plain sentences that sound natural spoken, with no file paths, symbols or code in them; details can follow. Before long work, say in a few words what you're about to do. Ask at most one question at a time. If you're unsure of something, say so rather than guess.";

/** After a spoken prompt's words, in the message Claude gets. */
export const SPOKEN_NOTE =
  "(Said out loud in Talk mode: your reply is read aloud. Open with the answer in one to three short spoken sentences, with no file names, paths, line numbers or code in them; put details after.)";

type Edit = { tool: string; original: Record<string, unknown>; ran: Record<string, unknown> };

// Key order doesn't make an edit: clients re-encode the input they were sent.
function stableJson(v: unknown): string {
  return JSON.stringify(v, (_k, x) =>
    x && typeof x === 'object' && !Array.isArray(x) ? Object.fromEntries(Object.entries(x).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) : x);
}

function describeEdit(e: Edit): string {
  const lead = `[duet] The user edited this ${e.tool} call before approving it`;
  if (typeof e.ran.command === 'string' && typeof e.original.command === 'string') {
    return `${lead}. It ran \`${e.ran.command}\` instead of \`${e.original.command}\`; the result is from the edited command.`;
  }
  return `${lead}. It ran with this input instead of yours: ${JSON.stringify(e.ran)}`;
}

function withHooks(base: LeadConfig['hooks'], extra: Partial<Record<HookEvent, HookCallbackMatcher[]>>): Partial<Record<HookEvent, HookCallbackMatcher[]>> {
  const out: Partial<Record<HookEvent, HookCallbackMatcher[]>> = { ...base };
  for (const [k, v] of Object.entries(extra) as [HookEvent, HookCallbackMatcher[]][]) out[k] = [...(out[k] ?? []), ...v];
  return out;
}

// CLAUDE_CODE_SHELL_PREFIX runs each command in a memory-capped scope (systemd/run-command.sh), for the lead and the
// workers alike; DBUS_SESSION_BUS_ADDRESS and DUET_COMMAND_MEMORY_MAX go with it.
const ENV_KEEP = ['HOME', 'PATH', 'USER', 'LOGNAME', 'SHELL', 'LANG', 'TERM', 'XDG_RUNTIME_DIR', 'TMPDIR',
  'CLAUDE_CODE_SHELL_PREFIX', 'DBUS_SESSION_BUS_ADDRESS', 'DUET_COMMAND_MEMORY_MAX'];

// How Claude Code signs in is the user's choice (an API key, a Claude plan, a cloud provider); the hub never handles
// it. DUET_LEAD_AUTH narrows it on your own hub: `subscription` runs Claude only on a Claude plan's login, never an API
// key or provider in the environment; `max` only on a Max plan. Unset: whatever Claude Code is signed in with.
export type LeadAuth = 'any' | 'subscription' | 'max';
export function leadAuth(): LeadAuth {
  const a = process.env.DUET_LEAD_AUTH;
  return a === 'subscription' || a === 'max' ? a : 'any';
}

// Claude Code's own sign-in settings: an API key, a gateway, or a cloud provider (Bedrock, Vertex, Foundry).
const isAuthVar = (k: string) => /^(ANTHROPIC_|AWS_|CLAUDE_CODE_USE_)/.test(k) || k === 'CLOUD_ML_REGION' || k === 'GOOGLE_APPLICATION_CREDENTIALS';

// The SDK's env option replaces process.env, so each session's env is built from an allowlist.
/** For the workers, which run on local models through the hub's proxy: never any Claude credentials. */
export function baseEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const k of ENV_KEEP) if (process.env[k]) env[k] = process.env[k]!;
  return env;
}

/** For Claude itself (the lead, side chats): the base, plus the user's sign-in settings unless DUET_LEAD_AUTH rules them out. */
export function leadEnv(): Record<string, string> {
  const env = baseEnv();
  if (leadAuth() === 'any') for (const [k, v] of Object.entries(process.env)) if (v && isAuthVar(k)) env[k] = v;
  return env;
}

// Async iterable the SDK reads user turns from; stays open for the life of the session.
class InputQueue implements AsyncIterable<SDKUserMessage> {
  private items: SDKUserMessage[] = [];
  private wake: (() => void) | null = null;
  private closed = false;
  push(text: string, images: Image[] = []): void {
    // Images go first, so the text can refer to them.
    const content = images.length
      ? [...images.map((i) => ({ type: 'image' as const, source: { type: 'base64' as const, media_type: i.type, data: i.data } })), { type: 'text' as const, text }]
      : text;
    this.items.push({ type: 'user', message: { role: 'user', content }, parent_tool_use_id: null, session_id: '', origin: { kind: 'human' } } as SDKUserMessage);
    this.wake?.();
  }
  close(): void {
    this.closed = true;
    this.wake?.();
  }
  async *[Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
    while (true) {
      while (this.items.length) yield this.items.shift()!;
      if (this.closed) return;
      await new Promise<void>((r) => (this.wake = r));
      this.wake = null;
    }
  }
}

export class Lead {
  private q: Query | null = null;
  private input: InputQueue | null = null;
  private queue: Queued[] = [];
  /** Prompts and notes sent while Claude works, oldest first: Claude Code takes each at Claude's next tool call (or as
   *  the next turn) as a message from the user, and its UserPromptSubmit hook says when. */
  private pushed: Queued[] = [];
  /** Notes Claude took in the hub's current turn: a prompt taken mid-turn starts the next one, which answers them. */
  private turnNotes: string[] = [];
  private pending = new Map<string, Pending>();
  // Edited calls by tool-use id, until their result reaches Claude.
  private edits = new Map<string, Edit>();
  private turn = 0;
  private busy = false;
  private interrupted = false;
  private stopping = false;
  private restartQuietly = false;
  private onStopped: (() => void) | null = null;
  /** The conversation: a Claude session. The hub names a new one before its first turn, so every event of it is tagged. */
  private sessionId: string | undefined;
  /** Claude Code has a transcript for `sessionId` (its init was seen), so a restart resumes it rather than naming it. */
  private sessionCreated = false;
  private effort: EffortLevel;
  private model: string;
  /** How Claude asks before it acts. Saved, so the next session starts in it. */
  private mode: PermissionMode;
  private compactBy: string | null = null;
  /** Told to Claude with its next prompt: it was moved to another folder. */
  private folderNotice: string | null = null;
  /** The turn being dispatched is read aloud: Claude is told so. Turns the hub starts itself follow the last prompt. */
  private voiceTurn = false;
  private lastPromptVoice = false;
  private notices: string[] = [];
  /** Claude's subagents running in Claude Code, by the Agent call that started each, and Claude Code's task ids for them. */
  private runs = new Map<string, AgentRun>();
  private runOf = new Map<string, string>();
  /** task_started for an Agent call of Claude's that the hub hasn't seen yet (the call's message comes first, normally). */
  private early = new Map<string, SDKTaskStartedMessage>();
  /** Claude Code's live background tasks (their task ids): the whole set each time it changes. Unknown until it first
   *  says, in each of its processes. */
  private backgroundSet: Set<string> | null = null;

  private cfg: LeadConfig;
  private emit: (e: EventBody) => void;
  private state: StateFile;

  constructor(cfg: LeadConfig, emit: (e: EventBody) => void, state: StateFile, startTurn: number) {
    this.cfg = cfg;
    this.emit = emit;
    this.state = state;
    this.effort = cfg.effort;
    this.model = cfg.model;
    this.turn = startTurn;
    const st = state.read();
    this.sessionId = st.leadSessionId;
    this.sessionCreated = !!this.sessionId;
    this.mode = isMode(st.permissionMode) ? st.permissionMode : 'default';
  }

  /** The folder Claude works in. */
  get cwd(): string {
    return this.cfg.cwd;
  }

  /** The live conversation: the id every event of it carries. */
  get conversationId(): string | undefined {
    return this.sessionId;
  }

  /** Claude Code has the live conversation's transcript (its first turn has started), so it can be copied. */
  get transcribed(): boolean {
    return this.sessionCreated;
  }

  get currentTurn(): number {
    return this.turn;
  }

  // A turn is running or waiting on an approval; deploys refuse to restart the hub while this is true.
  get busyNow(): boolean {
    return this.busy || this.queue.length > 0 || this.pushed.length > 0;
  }

  async start(): Promise<void> {
    // A new conversation is named here, not by Claude Code on its first turn, so its first events carry the id.
    if (!this.sessionId) this.sessionId = randomUUID();
    this.emit({ type: 'session', state: 'starting', sessionId: this.sessionId, model: this.cfg.model });
    if (!claudePath()) {
      this.emit({ type: 'error', message: NO_CLAUDE });
      this.emit({ type: 'session', state: 'stopped', reason: NO_CLAUDE });
      throw new Error(NO_CLAUDE);
    }
    this.input = new InputQueue();
    this.q = query({ prompt: this.input, options: this.options() });

    // With DUET_LEAD_AUTH set, check the login before accepting any prompt.
    const account = await this.q.accountInfo();
    const auth = leadAuth();
    const plan = account.apiProvider === 'firstParty' && !!account.subscriptionType;
    if ((auth === 'subscription' && !plan) || (auth === 'max' && !(plan && /max/i.test(account.subscriptionType ?? '')))) {
      const reason = `DUET_LEAD_AUTH=${auth}, but Claude Code is signed in with subscription=${account.subscriptionType}, provider=${account.apiProvider}`;
      this.emit({ type: 'error', message: reason });
      this.emit({ type: 'session', state: 'stopped', reason });
      this.input.close();
      throw new Error(reason);
    }
    this.emit({ type: 'session', state: 'ready', sessionId: this.sessionId, model: this.model, account: { subscription: account.subscriptionType } });
    await this.publishInfo();
    void this.pump(this.q);
  }

  /** A session's options: built for each start, since a restarted session needs fresh MCP server instances. */
  private options(): Options {
    return {
      cwd: this.cfg.cwd,
      // Claude Code says when nothing at all runs any more, background work included (session_state_changed idle).
      ...claudeExecutable(),
      env: { ...leadEnv(), CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS: '1' },
      model: this.model,
      effort: this.effort,
      settingSources: [],
      settings: { crossSessionInbound: 'refuse' },
      // Bypass Permissions can only be switched on later in a session that starts allowing it.
      permissionMode: this.mode,
      allowDangerouslySkipPermissions: true,
      allowedTools: this.cfg.autoAllow,
      ...(this.cfg.disallowedTools?.length ? { disallowedTools: this.cfg.disallowedTools } : {}),
      canUseTool: this.ask,
      mcpServers: this.cfg.mcpServers?.(),
      hooks: withHooks(this.cfg.hooks, {
        PostToolUse: [{ hooks: [this.afterTool] }],
        PostToolUseFailure: [{ hooks: [this.afterTool] }],
        UserPromptSubmit: [{ hooks: [this.beforePrompt] }],
      }),
      includePartialMessages: true,
      // Resume a session Claude Code has; give a new one its id (the two options exclude each other).
      ...(this.sessionCreated ? { resume: this.sessionId } : { sessionId: this.sessionId }),
      stderr: (d) => this.cfg.log(`[claude] ${d.trimEnd()}`),
    };
  }

  // Each call that needs an OK becomes an approval card on every device. Leaving plan mode carries the plan.
  private ask: CanUseTool = (tool, input, opts) =>
    new Promise<PermissionResult>((resolve) => {
      const id = randomUUID().slice(0, 8);
      this.pending.set(id, { resolve, input, tool, toolUseId: opts.toolUseID });
      const plan = tool === EXIT_PLAN && typeof input.plan === 'string' ? input.plan : undefined;
      this.emit({
        type: 'approval_request', id, turn: this.turn, tool, input, title: opts.title, description: opts.description,
        toolUseId: opts.toolUseID, displayName: opts.displayName, defaultToNo: opts.defaultToNo || undefined, ...(plan !== undefined ? { plan } : {}),
      });
      opts.signal.addEventListener('abort', () => this.settle(id, { behavior: 'deny', message: 'Aborted' }, 'deny', false, 'abort'));
    });

  private async pump(q: Query): Promise<void> {
    try {
      for await (const m of q) this.handle(m);
      this.cfg.log('lead stream ended');
    } catch (err) {
      this.emit({ type: 'error', message: `lead session failed: ${String(err).slice(0, 500)}` });
    }
    for (const id of [...this.pending.keys()]) this.settle(id, { behavior: 'deny', message: 'Session ended' }, 'deny', false, 'session_end');
    // Claude's subagents run in Claude Code's process: they stopped with it. The next process says nothing of its
    // background work until that changes.
    this.cfg.subagents?.stopped(true);
    for (const id of [...this.runs.keys()]) this.forget(id);
    this.early.clear();
    this.backgroundSet = null;
    // Sent to a Claude Code that's gone: the next one gets them.
    this.queue.unshift(...this.pushed.splice(0));
    if (this.busy) {
      this.emit({ type: 'turn_end', turn: this.turn, subtype: 'session_ended', isError: true, interrupted: this.interrupted });
      this.busy = false;
    }
    this.emit({ type: 'session', state: 'stopped', sessionId: this.sessionId });
    if (this.restartQuietly) {
      // clear() restarts the session itself.
      this.restartQuietly = false;
      this.onStopped?.();
      this.onStopped = null;
      return;
    }
    if (!this.stopping) {
      this.cfg.log('restarting lead in 3s');
      setTimeout(() => this.start().then(() => this.dispatch()).catch((e) => this.cfg.log(`restart failed: ${e}`)), 3000);
    }
  }

  // Model list and the effort levels each one accepts, for the app's pickers.
  private async publishInfo(): Promise<void> {
    if (!this.q) return;
    let models: LeadModel[] = [];
    try {
      models = (await this.q.supportedModels()).map((m) => ({ value: m.value, displayName: m.displayName, effortLevels: m.supportedEffortLevels ?? [], resolved: m.resolvedModel }));
    } catch (e) {
      this.cfg.log(`supportedModels failed: ${e}`);
    }
    const st = this.state.read();
    this.emit({ type: 'lead_info', model: this.model, effort: this.effort, models, cwd: this.cfg.cwd, recentCwds: st.recentCwds ?? [], conversationId: this.sessionId, permissionMode: this.mode });
  }

  private handle(m: SDKMessage): void {
    switch (m.type) {
      case 'system':
        if (m.subtype === 'compact_boundary') {
          this.emit({ type: 'context', action: 'compacted', by: this.compactBy ?? 'auto', preTokens: m.compact_metadata.pre_tokens, postTokens: m.compact_metadata.post_tokens });
          this.compactBy = null;
          return;
        }
        if (m.subtype === 'status') {
          // Claude Code says whenever the mode changes: set from a device, or by Claude leaving plan mode.
          if (m.permissionMode) this.followMode(m.permissionMode);
          return;
        }
        if (m.subtype === 'init') {
          this.followMode(m.permissionMode);
          if (leadAuth() !== 'any' && m.apiKeySource !== 'none') {
            this.emit({ type: 'error', message: `lead apiKeySource is ${m.apiKeySource}, but DUET_LEAD_AUTH=${leadAuth()} expects a Claude plan; stopping` });
            void this.stop();
            return;
          }
          if (m.session_id !== this.sessionId) {
            // Claude Code chose another id (it shouldn't: the hub names new sessions and resumes old ones). Follow it.
            this.cfg.log(`lead session is ${m.session_id}, not ${this.sessionId}; following Claude Code`);
            this.sessionId = m.session_id;
            this.emit({ type: 'session', state: 'ready', sessionId: m.session_id, model: this.model });
          }
          if (!this.sessionCreated) {
            // Claude Code has the transcript now: a restart resumes it. (Not before: resuming a session with no
            // transcript fails, and a hub that died before the first turn would crash-loop.)
            this.sessionCreated = true;
            this.state.write({ ...this.state.read(), leadSessionId: this.sessionId });
          }
          return;
        }
        // Claude's subagents as Claude Code runs them: started, sent to the background, ended.
        if (m.subtype === 'task_started') return this.taskStarted(m);
        if (m.subtype === 'task_updated') return this.taskUpdated(m);
        if (m.subtype === 'task_progress') return this.taskProgress(m);
        if (m.subtype === 'task_notification') return this.taskNotified(m);
        if (m.subtype === 'background_tasks_changed') return this.backgroundChanged(m.tasks.map((t) => t.task_id));
        // Idle: nothing runs in Claude Code any more, background work included. (Claude Code says "running" for as long as
        // background work runs, so it doesn't mark the turns it starts itself: ownTurn() does.)
        if (m.subtype === 'session_state_changed' && m.state === 'idle') {
          this.unseen();
          return this.settled();
        }
        return;
      case 'stream_event': {
        if (m.parent_tool_use_id !== null) return;
        this.ownTurn();
        const ev = m.event;
        if (ev.type === 'content_block_delta' && ev.delta.type === 'text_delta') {
          this.emit({ type: 'text_delta', turn: this.turn, text: ev.delta.text });
        }
        return;
      }
      case 'assistant': {
        const blocks = m.message.content;
        const text = blocks.flatMap((b) => (b.type === 'text' ? [b.text] : [])).join('');
        if (m.parent_tool_use_id !== null) {
          // One of Claude's subagents at work: its task's progress.
          const u = m.message.usage;
          this.cfg.subagents?.progress(m.parent_tool_use_id, {
            text: text || undefined,
            toolUses: blocks.flatMap((b) => (b.type === 'tool_use' ? [{ name: b.name, input: clip(b.input) }] : [])),
            usage: u ? { messageId: m.message.id, input: (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0), output: u.output_tokens ?? 0 } : undefined,
          });
          return;
        }
        this.ownTurn();
        const toolUses: ToolUse[] = blocks.flatMap((b) => (b.type === 'tool_use' ? [{ id: b.id, name: b.name, input: b.input }] : []));
        if (text || toolUses.length) this.emit({ type: 'assistant', turn: this.turn, text, toolUses });
        for (const u of toolUses) {
          if (!AGENT_TOOLS.has(u.name)) continue;
          const input = (u.input ?? {}) as { prompt?: unknown; subagent_type?: unknown; description?: unknown };
          if (!this.runs.has(u.id)) this.runs.set(u.id, { background: false });
          const label = typeof input.description === 'string' && input.description.trim() ? input.description.trim() : undefined;
          this.cfg.subagents?.start(u.id, typeof input.subagent_type === 'string' && input.subagent_type ? input.subagent_type : 'general-purpose', String(input.prompt ?? ''), label ? { label } : {});
          const early = this.early.get(u.id);
          if (early) {
            this.early.delete(u.id);
            this.taskStarted(early);
          }
        }
        return;
      }
      case 'user': {
        if (!Array.isArray(m.message.content)) return;
        for (const b of m.message.content) {
          if (typeof b !== 'object' || !b || b.type !== 'tool_result') continue;
          if (m.parent_tool_use_id !== null) {
            this.cfg.subagents?.progress(m.parent_tool_use_id, { toolResult: resultText(b.content).slice(0, 500) });
            continue;
          }
          this.ownTurn();
          const raw = typeof b.content === 'string' ? b.content : JSON.stringify(b.content ?? '');
          // A subagent's report, or word that it went to the background (before the tool result, so clients know the row
          // is the task's).
          if (this.cfg.subagents?.isSubagent(b.tool_use_id)) this.agentResult(b.tool_use_id, !!b.is_error, b.content, (m as { tool_use_result?: unknown }).tool_use_result);
          // Long output: its end too, where a run's verdict usually is (devices summarize it in one line).
          const tail = raw.length > 2000 ? raw.slice(Math.max(2000, raw.length - 1500)) : undefined;
          this.emit({ type: 'tool_result', turn: this.turn, toolUseId: b.tool_use_id, isError: !!b.is_error, preview: raw.slice(0, 2000), ...(tail ? { tail } : {}) });
        }
        return;
      }
      case 'result':
        // No turn open and no model call in it: a queued command Claude Code ran without the model, which ends nothing.
        if (!this.busy && !m.num_turns) return;
        this.ownTurn();
        // The subagents Claude waited on were cut off; those in the background run on, and end with their own notices.
        this.cfg.subagents?.stopped();
        for (const [id, run] of this.runs) if (!run.background && !run.parent) this.forget(id);
        this.early.clear();
        this.emit({ type: 'turn_end', turn: this.turn, subtype: m.subtype, isError: m.is_error, interrupted: this.interrupted, durationMs: m.duration_ms, numTurns: m.num_turns });
        this.busy = false;
        this.interrupted = false;
        // What Claude Code still holds is the next turn, which it starts itself.
        this.dispatch();
        if (!this.busy && !this.pushed.length) this.cfg.onIdle?.();
        return;
    }
  }

  /**
   * A turn Claude Code started by itself, to answer something that isn't a prompt (a background subagent's report,
   * mostly): its first message comes with no turn open. It gets the next number, as a prompt's turn would.
   */
  private ownTurn(): void {
    if (this.busy) return;
    this.busy = true;
    this.turn += 1;
    this.turnNotes = [];
    // Read aloud as the hub's own turns are: as the last prompt was.
    this.voiceTurn = this.lastPromptVoice;
    this.cfg.log(`Claude Code started turn ${this.turn} by itself`);
    this.emit({ type: 'turn_start', turn: this.turn });
    this.cfg.onTurnStart?.();
  }

  /** An Agent call's result: the subagent's report, or word that it went to the background, where it runs on until its
   *  own notice says it ended. */
  private agentResult(id: string, isError: boolean, content: Parameters<typeof resultText>[0], out: unknown): void {
    const run = this.runs.get(id) ?? { background: false };
    this.runs.set(id, run);
    const status = out && typeof out === 'object' ? (out as { status?: unknown }).status : undefined;
    if (!isError && (status === 'async_launched' || (run.background && status !== 'completed'))) return this.toBackground(id, run);
    this.forget(id);
    this.cfg.subagents?.end(id, isError ? 'failed' : 'done', resultText(content), subagentOutcome(out));
  }

  /**
   * Claude Code started a subagent's task. One of Claude's own Agent calls has its task already; a subagent's own
   * subagent gets one here, under the task of the subagent that started it. Shells, monitors and workflows aren't
   * followed (yet).
   */
  private taskStarted(m: SDKTaskStartedMessage): void {
    const id = m.tool_use_id;
    const agent = m.task_type ? m.task_type === 'local_agent' : !!m.subagent_type;
    if (!id || !agent || m.subagent_type === 'main-session') return;
    const own = this.runs.get(id);
    const parent = m.parent_task_id ? this.runOf.get(m.parent_task_id) : undefined;
    if (!own && !parent) {
      // A call of Claude's whose message is still to come (kept until then, or the turn's end). Anything else was
      // started by something the hub doesn't follow, such as an agent inside a workflow.
      if (!m.parent_task_id && (m.spawn_depth ?? 1) <= 1) this.early.set(id, m);
      return;
    }
    const run: AgentRun = own ?? { background: !!m.is_backgrounded, parent };
    this.runs.set(id, run);
    run.taskId = m.task_id;
    this.runOf.set(m.task_id, id);
    if (!own) {
      this.cfg.subagents?.start(id, m.subagent_type || 'general-purpose', m.prompt || m.description, {
        label: m.description || undefined, parent, ...(m.spawn_depth ? { depth: m.spawn_depth } : {}), ...(run.background ? { background: true } : {}),
      });
    } else if (m.is_backgrounded) {
      this.toBackground(id, run);
    }
  }

  private toBackground(id: string, run: AgentRun): void {
    if (run.background) return;
    run.background = true;
    this.cfg.subagents?.background(id);
  }

  private taskUpdated(m: SDKTaskUpdatedMessage): void {
    const id = this.runOf.get(m.task_id);
    const run = id ? this.runs.get(id) : undefined;
    if (!id || !run) return;
    // Sent to the background mid-run: its call returns at once.
    if (m.patch.is_backgrounded) this.toBackground(id, run);
    const s = m.patch.status;
    if (s === 'completed' || s === 'failed' || s === 'killed') run.endedAs = s;
  }

  private taskProgress(m: SDKTaskProgressMessage): void {
    const id = m.tool_use_id ?? this.runOf.get(m.task_id);
    const run = id ? this.runs.get(id) : undefined;
    if (run) run.usage = m.usage;
  }

  /**
   * A subagent's task ended. One Claude waits on ends with its Agent call's result instead, which has the whole
   * outcome; one in the background, or a subagent's own, ends here, with its report and what it used.
   */
  private taskNotified(m: SDKTaskNotificationMessage): void {
    const id = m.tool_use_id ?? this.runOf.get(m.task_id);
    const run = id ? this.runs.get(id) : undefined;
    if (!id || !run || (!run.background && !run.parent)) return;
    this.finish(id, ENDED[m.status] ?? 'failed', m.summary ?? '', handedBack(m), m.usage ?? run.usage);
  }

  /** A subagent the hub followed ended: its task ends with its report (`report`, else `summary`) and its usage. */
  private finish(id: string, state: 'done' | 'failed' | 'cancelled', summary: string, report: string, usage?: AgentUsage): void {
    this.forget(id);
    this.cfg.subagents?.end(id, state, summary, { report, toolUses: usage?.tool_uses ?? 0, durationMs: usage?.duration_ms ?? 0, ...(usage ? { totalTokens: usage.total_tokens } : {}) });
  }

  private forget(id: string): void {
    const run = this.runs.get(id);
    if (!run) return;
    clearTimeout(run.missing);
    if (run.taskId) this.runOf.delete(run.taskId);
    this.runs.delete(id);
  }

  /** Claude Code's background work now: the whole set, each time it changes. A background subagent missing from it,
   *  with no end notice, is lost once it has been missing for LOST_AFTER_MS. */
  private backgroundChanged(taskIds: string[]): void {
    this.backgroundSet = new Set(taskIds);
    for (const [id, run] of this.runs) {
      if (!run.background || !run.taskId) continue;
      if (this.backgroundSet.has(run.taskId)) this.found(run);
      else this.missing(id, run);
    }
  }

  /** Nothing runs in Claude Code any more, background work included: a subagent still followed here was missed. (Those
   *  Claude waited on ended with its turn.) */
  private settled(): void {
    for (const [id, run] of this.runs) {
      if ((run.background || run.parent) && !(run.taskId && this.backgroundSet?.has(run.taskId))) this.missing(id, run);
    }
  }

  private missing(id: string, run: AgentRun): void {
    if (run.missing) return;
    run.missing = setTimeout(() => this.lost(id), LOST_AFTER_MS);
    run.missing.unref?.();
  }

  private found(run: AgentRun): void {
    clearTimeout(run.missing);
    run.missing = undefined;
  }

  /** Missing, with no end notice, for LOST_AFTER_MS: lost; or, if Claude Code said it ended, ended without its report. */
  private lost(id: string): void {
    const run = this.runs.get(id);
    if (!run) return;
    this.cfg.log(`subagent ${id} ended without a notice: Claude Code no longer runs it${run.endedAs ? ` (it said ${run.endedAs})` : ''}`);
    const state = run.endedAs === 'completed' ? 'done' : run.endedAs === 'killed' ? 'cancelled' : 'failed';
    this.finish(id, state, run.endedAs ? LATE_NOTE : LOST_NOTE, '', run.usage);
  }

  // Boost adds "ultrathink" to this one turn only. Voice: spoken in Talk mode, and the reply is read aloud.
  submit(text: string, by: string, boost = false, extra: { images?: Image[]; notes?: Notes; noteIds?: string[]; voice?: boolean } = {}): void {
    const q: Queued = { text: boost ? `${text}\n\nultrathink` : text, by, ...extra };
    if (this.claudeWorks() && midTurn(q)) this.send(q);
    else {
      this.queue.push(q);
      this.dispatch();
    }
    // Held: every device shows it as waiting for Claude, until Claude takes it.
    if ((this.queue.includes(q) || this.pushed.includes(q)) && by !== 'duet') {
      q.held = `q-${randomUUID().slice(0, 8)}`;
      this.emit({ type: 'queued', id: q.held, state: 'waiting', text: extra.notes ? extra.notes.items.map((n) => n.text).join('\n') : text, by, ...(extra.voice ? { voice: true } : {}) });
    }
  }

  /** Claude works, or Claude Code holds something for its next turn: what the user sends goes to Claude Code now. */
  private claudeWorks(): boolean {
    return !!this.input && (this.busy || this.pushed.length > 0);
  }

  /**
   * Send it to Claude Code while Claude works. Claude Code takes it at Claude's next tool call, or as the next turn, as
   * a message from the user (pictures and all); a waiting await_workers returns so that comes soon.
   */
  private send(q: Queued): void {
    q.sent = q.voice ? `${q.text}\n\n${SPOKEN_NOTE}` : q.text;
    this.pushed.push(q);
    this.input!.push(q.sent, q.images);
    this.cfg.onUserWaiting?.();
  }

  /** Something the user sent waits for Claude's next tool call. */
  userWaiting(): boolean {
    return this.pushed.length > 0;
  }

  /**
   * Claude Code took something the user sent while Claude worked. Mid-turn, a prompt starts the hub's next turn inside
   * Claude Code's running one (the hub's turns are one per prompt), which answers the notes taken before it too; after
   * the turn, it is a turn of its own. Notes keep the row they got when they came.
   */
  private taken(q: Queued): void {
    if (q.held) this.emit({ type: 'queued', id: q.held, state: 'taken' });
    const own = !this.busy;
    if (own || !q.notes) {
      this.busy = true;
      this.turn += 1;
      if (!q.notes) this.emit({ type: 'user', turn: this.turn, text: q.text, by: q.by, ...(q.voice ? { voice: true } : {}) });
      this.lastPromptVoice = q.voice === true;
      this.voiceTurn = q.voice === true;
      this.emit({ type: 'turn_start', turn: this.turn });
      if (own) {
        this.turnNotes = [];
        this.cfg.onTurnStart?.();
      }
    }
    this.turnNotes.push(...(q.noteIds ?? []));
    if (this.turnNotes.length && (q.noteIds?.length || !q.notes)) this.cfg.onNotesTaken?.(this.turnNotes, this.turn);
  }

  /** Claude Code is idle, so it took everything sent to it: anything not seen taken (its words changed) was. */
  private unseen(): void {
    if (!this.pushed.length) return;
    this.cfg.log(`Claude Code took ${this.pushed.length} message(s) the hub didn't see it take`);
    for (const q of this.pushed.splice(0)) if (q.held) this.emit({ type: 'queued', id: q.held, state: 'taken' });
  }

  // /compact runs as a normal turn; the compact_boundary message reports the token counts.
  compact(by: string): void {
    this.compactBy = by;
    this.submit('/compact', by);
  }

  // Clear starts a new conversation: same tools and settings, no history. The old one stays resumable.
  async clear(by: string): Promise<void> {
    if (this.busyNow) throw new Error('a turn is running; stop it first');
    await this.stopQuietly();
    // `session stopped` carried the old id; `cleared` and everything after carry the new one.
    this.sessionId = randomUUID();
    this.sessionCreated = false;
    this.state.write({ ...this.state.read(), leadSessionId: undefined });
    this.emit({ type: 'context', action: 'cleared', by });
    await this.start();
  }

  /**
   * Continue an earlier conversation: the same quiet restart as Clear, resuming that session. If it last ran in
   * another folder (that still exists), Claude moves there first.
   */
  async resume(sessionId: string, by: string): Promise<void> {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(sessionId)) throw new Error('not a session id');
    if (sessionId === this.sessionId) return;
    // Looked up before the busy check: nothing awaits between that check and closing the input.
    const info = await getSessionInfo(sessionId).catch(() => null);
    if (!info) throw new Error(`no session ${sessionId}`);
    if (this.busyNow) throw new Error('a turn is running; stop it first');
    await this.stopQuietly();
    this.sessionId = sessionId;
    this.sessionCreated = true;
    this.state.write({ ...this.state.read(), leadSessionId: sessionId });
    this.emit({ type: 'context', action: 'resumed', by, sessionId });
    const dir = info.cwd;
    if (dir && dir !== this.cfg.cwd && existsSync(dir) && statSync(dir).isDirectory()) {
      this.moveTo(dir, by);
      this.emit({ type: 'context', action: 'folder', by, path: dir });
    }
    await this.start();
  }

  /** Close the session and wait for its stream to end, without the automatic restart. */
  private async stopQuietly(): Promise<void> {
    if (!this.q) return;
    this.restartQuietly = true;
    this.input?.close();
    this.q.close?.();
    await new Promise<void>((r) => (this.onStopped = r));
  }

  /** Record a move to another folder, and tell Claude on its next prompt. */
  private moveTo(dir: string, by: string): void {
    const from = this.cfg.cwd;
    this.cfg.cwd = dir;
    const st = this.state.read();
    this.state.write({ ...st, cwd: dir, recentCwds: [dir, from, ...(st.recentCwds ?? [])].filter((d, i, a) => a.indexOf(d) === i).slice(0, 8) });
    this.folderNotice = `[duet] ${by} moved you from ${from} to ${dir}. That is your working directory now; new shells and worker tasks start there too.`;
    this.cfg.log(`${by} moved the lead to ${dir}`);
  }

  /**
   * Move Claude to another folder. The session restarts there and resumes the same conversation (Claude Code finds a
   * session by id in any project folder), and Claude is told on its next turn.
   */
  async setCwd(dir: string, by: string): Promise<void> {
    if (this.busyNow) throw new Error('a turn is running; stop it first');
    if (dir === this.cfg.cwd) return;
    this.moveTo(dir, by);
    await this.stopQuietly();
    this.emit({ type: 'context', action: 'folder', by, path: dir });
    await this.start();
  }

  /** Something to tell Claude with the user's next prompt (a note a local model answered meanwhile, say). */
  notice(text: string): void {
    this.notices.push(text);
    if (this.notices.length > 20) this.notices.shift();
  }

  private beforePrompt: HookCallback = async (input) => {
    // Something the user sent while Claude worked, which Claude Code takes now.
    const prompt = (input as { prompt?: unknown }).prompt;
    const i = this.pushed.findIndex((q) => q.sent === prompt);
    if (i >= 0) this.taken(this.pushed.splice(i, 1)[0]);
    const parts = [this.folderNotice, this.voiceTurn ? VOICE_GUIDANCE : null, ...this.notices.splice(0)].filter((p): p is string => !!p);
    this.folderNotice = null;
    this.voiceTurn = false;
    if (!parts.length) return {};
    return { hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: parts.join('\n\n') } };
  };

  async setModel(model: string, by: string): Promise<void> {
    if (!this.q) throw new Error('lead not running');
    // Aliases ("haiku"), the ids they resolve to, and the model the hub started with are all accepted.
    const rows = await this.q.supportedModels();
    const known = new Set([...rows.map((m) => m.value), ...rows.flatMap((m) => (m.resolvedModel ? [m.resolvedModel] : [])), this.cfg.model]);
    if (!known.has(model)) throw new Error(`unknown model ${model}; choose one of ${rows.map((m) => m.value).join(', ')}`);
    await this.q.setModel(model);
    this.model = model;
    this.cfg.log(`${by} set the lead model to ${model}`);
    await this.publishInfo();
  }

  /** How Claude asks before it acts. Takes effect at once, mid-turn too; with no session running, the next one starts in it. */
  async setPermissionMode(mode: PermissionMode, by: string): Promise<void> {
    if (!isMode(mode)) throw new Error(`unknown permission mode ${mode}; choose one of ${PERMISSION_MODES.join(', ')}`);
    await this.q?.setPermissionMode(mode);
    this.cfg.log(`${by} set the permission mode to ${mode}`);
    this.keepMode(mode);
    await this.publishInfo();
  }

  /** The mode as Claude Code reports it, which can change without the hub (Claude leaving plan mode). */
  private followMode(mode: string): void {
    if (mode === this.mode || !isMode(mode)) return;
    this.cfg.log(`the permission mode is ${mode} now (was ${this.mode})`);
    this.keepMode(mode);
    void this.publishInfo();
  }

  private keepMode(mode: PermissionMode): void {
    this.mode = mode;
    this.state.write({ ...this.state.read(), permissionMode: mode });
  }

  private dispatch(): void {
    if (this.busy || !this.input || !this.queue.length || this.pushed.length) return;
    const next = this.queue.shift()!;
    if (next.held) this.emit({ type: 'queued', id: next.held, state: 'taken' });
    this.busy = true;
    this.turn += 1;
    this.emit({ type: 'user', turn: this.turn, text: next.text, by: next.by, notes: next.notes, ...(next.voice ? { voice: true } : {}) });
    if (next.by !== 'duet') this.lastPromptVoice = next.voice === true;
    this.voiceTurn = next.by === 'duet' ? this.lastPromptVoice : next.voice === true;
    this.emit({ type: 'turn_start', turn: this.turn });
    this.cfg.onTurnStart?.();
    this.turnNotes = next.noteIds ?? [];
    if (next.noteIds?.length) this.cfg.onNotesTaken?.(next.noteIds, this.turn);
    // A spoken prompt carries the note itself, where it weighs more than a side note; the transcript shows only
    // what was said.
    this.input.push(next.voice ? `${next.text}\n\n${SPOKEN_NOTE}` : next.text, next.images);
  }

  approve(id: string, by: string, updatedInput?: Record<string, unknown>): void {
    const p = this.pending.get(id);
    if (!p) throw new Error(`no pending approval ${id}`);
    const edited = !!updatedInput && stableJson(updatedInput) !== stableJson(p.input);
    // An edited plan Claude Code saves to its plan file, and tells Claude so itself.
    if (edited && p.toolUseId && p.tool !== EXIT_PLAN) this.edits.set(p.toolUseId, { tool: p.tool, original: p.input, ran: updatedInput! });
    this.settle(id, { behavior: 'allow', updatedInput: updatedInput ?? p.input }, 'allow', edited, by, undefined, edited ? updatedInput : undefined);
  }

  // After each tool call: tell whoever made it when a person changed what ran (it only sees the call it made).
  private afterTool: HookCallback = async (input) => {
    if (input.hook_event_name !== 'PostToolUse' && input.hook_event_name !== 'PostToolUseFailure') return {};
    const e = this.edits.get(input.tool_use_id);
    if (!e) return {};
    this.edits.delete(input.tool_use_id);
    return { hookSpecificOutput: { hookEventName: input.hook_event_name, additionalContext: describeEdit(e) } };
  };

  // Handwritten notes, with the annotated picture. While Claude works they reach it at its next tool call, shown at
  // once where they came; otherwise they start a turn.
  addNotes(by: string, notes: Notes, text: string, image?: Image): void {
    const ids = notes.items.map((n) => n.id);
    const q: Queued = { text, by, images: image ? [image] : [], notes, noteIds: ids };
    if (this.claudeWorks()) {
      this.emit({ type: 'notes', turn: this.turn, by, notes });
      this.send(q);
      return;
    }
    this.submit(text, by, false, { images: q.images, notes, noteIds: ids });
  }

  reject(id: string, by: string, message?: string): void {
    const p = this.pending.get(id);
    if (!p) throw new Error(`no pending approval ${id}`);
    // Claude always gets a reason; clients only see a note someone actually wrote. A plan that isn't approved keeps
    // Claude in plan mode, working on the plan.
    const note = message?.trim() || undefined;
    const reason = p.tool === EXIT_PLAN
      ? `The user wants you to keep planning${note ? `: ${note}` : ", and didn't say what to change. Ask them."}`
      : note ?? 'The user rejected this tool call.';
    this.settle(id, { behavior: 'deny', message: reason }, 'deny', false, by, note);
  }

  private settle(id: string, r: PermissionResult, decision: 'allow' | 'deny', edited: boolean, by: string, message?: string, updatedInput?: Record<string, unknown>): void {
    const p = this.pending.get(id);
    if (!p) return;
    this.pending.delete(id);
    this.emit({ type: 'approval_resolved', id, decision, edited, by, message, updatedInput });
    p.resolve(r);
  }

  async interrupt(by: string): Promise<void> {
    if (!this.busy || !this.q) throw new Error('no turn is running');
    this.interrupted = true;
    this.emit({ type: 'interrupt', turn: this.turn, by });
    for (const id of [...this.pending.keys()]) this.settle(id, { behavior: 'deny', message: 'Interrupted by the user', interrupt: true }, 'deny', false, by, 'interrupted');
    await this.q.interrupt();
  }

  // Takes effect from the next turn (verified in spike 5).
  async setEffort(level: EffortLevel | null, by: string): Promise<void> {
    if (!this.q) throw new Error('lead not running');
    await this.q.applyFlagSettings({ effortLevel: level });
    this.effort = level ?? this.cfg.effort;
    this.emit({ type: 'effort', level, by, appliesFrom: 'next_turn' });
    await this.publishInfo();
  }

  async stop(): Promise<void> {
    this.stopping = true;
    this.input?.close();
    this.q?.close?.();
  }
}
