// The lead: one long-lived session of a coding agent (Claude Code, through agents/claude.ts), whichever agent it is.
// Turns are 1:1 with prompts: the hub queues them while the agent can't take them, and sends what you write while
// it works straight to it (Claude Code takes it at Claude's next tool call). Tool approvals become cards on every device.
import type { HookCallbackMatcher, HookEvent, McpSdkServerConfigWithInstance } from '@anthropic-ai/claude-agent-sdk';
import { randomUUID } from 'node:crypto';
import { existsSync, statSync } from 'node:fs';
import { PERMISSION_MODES, type EffortLevel, type EventBody, type HubEvent, type Notes, type PermissionMode, type ToolCall } from './protocol.ts';
import type { StateFile } from './store.ts';
import { REJECTED, Refused, type AgentAdapter, type AgentEvent, type AgentSession, type ApprovalAnswer, type Image, type SessionHost, type SessionOptions } from './agents/adapter.ts';
import { ClaudeAdapter, type ClaudeExtras } from './agents/claude.ts';

export type { Image } from './agents/adapter.ts';
export { LOST_AFTER_MS, LOST_NOTE } from './agents/claude.ts';

export type LeadConfig = {
  model: string;
  effort: EffortLevel;
  cwd: string;
  // Tools that run without asking. Everything else becomes an approval card.
  autoAllow: string[];
  // Built-in tools Claude doesn't get.
  disallowedTools?: string[];
  log: (msg: string) => void;
  // Dialogue layer (Phase 3), for Claude Code. A factory, because a restarted session needs fresh MCP server instances.
  mcpServers?: () => Record<string, McpSdkServerConfigWithInstance>;
  hooks?: Partial<Record<HookEvent, HookCallbackMatcher[]>>;
  /** The agent that leads. Default: Claude Code, with mcpServers and hooks above. */
  adapter?: AgentAdapter;
  /** Claude Code reaches mcpServers through the hub's gateway, as other agents do, instead of in-process. */
  mcpGateway?: ClaudeExtras['gateway'];
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

/** Claude asks to leave plan mode with its plan, which Claude Code reads from its plan file into the call's input. */
const EXIT_PLAN = 'ExitPlanMode';

const isMode = (m: unknown): m is PermissionMode => (PERMISSION_MODES as readonly unknown[]).includes(m);

type Pending = { resolve: (a: ApprovalAnswer) => void; input: Record<string, unknown>; tool: string; toolUseId?: string };
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

export class Lead {
  private readonly adapter: AgentAdapter;
  private session: AgentSession | null = null;
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
  private cfg: LeadConfig;
  private host: SessionHost;
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
    this.adapter = cfg.adapter ?? new ClaudeAdapter({ mcpServers: cfg.mcpServers, hooks: cfg.hooks, gateway: cfg.mcpGateway });
    // What the session calls back with. Its events arrive in the order they happen.
    this.host = {
      event: (e) => this.onEvent(e),
      beforePrompt: (prompt) => this.beforePrompt(prompt),
      afterTool: (toolUseId) => this.afterTool(toolUseId),
      subagents: cfg.subagents,
      log: (msg) => cfg.log(msg),
    };
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
    const session = this.adapter.open(this.sessionOptions(), this.host);
    const cannot = session.preflight();
    if (cannot) {
      this.emit({ type: 'error', message: cannot });
      this.emit({ type: 'session', state: 'stopped', reason: cannot });
      throw new Error(cannot);
    }
    this.session = session;
    let account: { subscription?: string };
    try {
      account = await session.start();
    } catch (e) {
      // It won't run (DUET_LEAD_AUTH rules its sign-in out): said once, and no restart.
      if (!(e instanceof Refused)) throw e;
      this.emit({ type: 'error', message: e.message });
      this.emit({ type: 'session', state: 'stopped', reason: e.message });
      throw new Error(e.message);
    }
    this.emit({ type: 'session', state: 'ready', sessionId: this.sessionId, model: this.model, account: { subscription: account.subscription } });
    await this.publishInfo();
    void session.run();
  }

  /** What a new session of the agent starts with: built for each start (the folder, model and mode may have changed). */
  private sessionOptions(): SessionOptions {
    return {
      sessionId: this.sessionId!, resume: this.sessionCreated, cwd: this.cfg.cwd, model: this.model, effort: this.effort, mode: this.mode,
      autoAllow: this.cfg.autoAllow, ...(this.cfg.disallowedTools?.length ? { disallowedTools: this.cfg.disallowedTools } : {}),
    };
  }


  // Each call that needs an OK becomes an approval card on every device. Leaving plan mode carries the plan.
  private approval(e: Extract<AgentEvent, { type: 'approval' }>): void {
    const id = randomUUID().slice(0, 8);
    this.pending.set(id, { resolve: e.respond, input: e.input, tool: e.tool, toolUseId: e.toolUseId });
    const plan = e.tool === EXIT_PLAN && typeof e.input.plan === 'string' ? e.input.plan : undefined;
    this.emit({
      type: 'approval_request', id, turn: this.turn, tool: e.tool, input: e.input, title: e.title, description: e.description,
      toolUseId: e.toolUseId, displayName: e.displayName, defaultToNo: e.defaultToNo || undefined, ...(plan !== undefined ? { plan } : {}),
    });
    e.onWithdrawn(() => this.settle(id, { allow: false, message: 'Aborted' }, 'deny', false, 'abort'));
  }

  /** The agent's process ended: what it held is denied or handed to the next one, which starts in 3 s. */
  private closed(error: string | undefined): void {
    if (error) this.emit({ type: 'error', message: error });
    for (const id of [...this.pending.keys()]) this.settle(id, { allow: false, message: 'Session ended' }, 'deny', false, 'session_end');
    this.session?.release();
    // Sent to an agent that's gone: the next one gets them.
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
    if (!this.session) return;
    let models: Awaited<ReturnType<AgentSession['models']>> = [];
    try {
      models = await this.session.models();
    } catch (e) {
      this.cfg.log(`supportedModels failed: ${e}`);
    }
    const st = this.state.read();
    this.emit({ type: 'lead_info', model: this.model, effort: this.effort, models, cwd: this.cfg.cwd, recentCwds: st.recentCwds ?? [], conversationId: this.sessionId, permissionMode: this.mode });
  }

  private onEvent(e: AgentEvent): void {
    switch (e.type) {
      case 'activity':
        return this.ownTurn();
      case 'ready':
        if (e.sessionId !== this.sessionId) {
          // The agent chose another id (it shouldn't: the hub names new sessions and resumes old ones). Follow it.
          this.cfg.log(`lead session is ${e.sessionId}, not ${this.sessionId}; following the agent`);
          this.sessionId = e.sessionId;
          this.emit({ type: 'session', state: 'ready', sessionId: e.sessionId, model: this.model });
        }
        if (!this.sessionCreated) {
          // The agent has the transcript now: a restart resumes it. (Not before: resuming a session with no
          // transcript fails, and a hub that died before the first turn would crash-loop.)
          this.sessionCreated = true;
          this.state.write({ ...this.state.read(), leadSessionId: this.sessionId });
        }
        return;
      case 'mode':
        return this.followMode(e.mode);
      case 'fatal':
        this.emit({ type: 'error', message: e.message });
        void this.stop();
        return;
      case 'compacted':
        this.emit({ type: 'context', action: 'compacted', by: this.compactBy ?? 'auto', preTokens: e.preTokens, postTokens: e.postTokens });
        this.compactBy = null;
        return;
      case 'idle':
        return this.unseen();
      case 'text':
        return this.emit({ type: 'text_delta', turn: this.turn, text: e.delta });
      case 'message':
        return this.emit({ type: 'assistant', turn: this.turn, text: e.text, toolUses: e.toolUses });
      case 'tool_end': {
        // Long output: its end too, where a run's verdict usually is (devices summarize it in one line).
        const raw = e.output;
        const tail = raw.length > 2000 ? raw.slice(Math.max(2000, raw.length - 1500)) : undefined;
        return this.emit({ type: 'tool_result', turn: this.turn, toolUseId: e.toolUseId, isError: e.isError, preview: raw.slice(0, 2000), ...(tail ? { tail } : {}) });
      }
      case 'approval':
        return this.approval(e);
      case 'turn_end':
        // No turn open and no model call in it: a queued command the agent ran without the model, which ends nothing.
        if (!this.busy && !e.numTurns) return;
        this.ownTurn();
        this.session?.endTurn();
        this.emit({ type: 'turn_end', turn: this.turn, subtype: e.subtype, isError: e.isError, interrupted: this.interrupted, durationMs: e.durationMs, numTurns: e.numTurns });
        this.busy = false;
        this.interrupted = false;
        // What the agent still holds is the next turn, which it starts itself.
        this.dispatch();
        if (!this.busy && !this.pushed.length) this.cfg.onIdle?.();
        return;
      case 'closed':
        return this.closed(e.error);
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
    this.cfg.log(`the agent started turn ${this.turn} by itself`);
    this.emit({ type: 'turn_start', turn: this.turn });
    this.cfg.onTurnStart?.();
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
    return !!this.session && (this.busy || this.pushed.length > 0);
  }

  /**
   * Send it to Claude Code while Claude works. Claude Code takes it at Claude's next tool call, or as the next turn, as
   * a message from the user (pictures and all); a waiting await_workers returns so that comes soon.
   */
  private send(q: Queued): void {
    q.sent = q.voice ? `${q.text}\n\n${SPOKEN_NOTE}` : q.text;
    this.pushed.push(q);
    this.session!.send(q.sent, q.images);
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

  // Claude Code runs /compact as a normal turn, and its compact_boundary message reports the token counts. An agent
  // with its own compaction (Codex) is asked for it; one with none (ACP agents) says so.
  compact(by: string): void {
    this.compactBy = by;
    if (this.adapter.id === 'claude') return this.submit('/compact', by);
    if (!this.session?.compact) {
      this.compactBy = null;
      this.emit({ type: 'error', message: `${this.adapter.name} can't compact on request; it summarizes by itself when its context fills.` });
      return;
    }
    this.session.compact().catch((e) => {
      this.compactBy = null;
      this.emit({ type: 'error', message: `${this.adapter.name} didn't compact: ${e instanceof Error ? e.message : e}` });
    });
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
    const info = await this.adapter.lookup(sessionId);
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
    if (!this.session) return;
    this.restartQuietly = true;
    this.session.close();
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

  /** The agent takes a prompt: what to tell it with it (a folder move, Talk mode, notices). */
  private beforePrompt(prompt: unknown): string | undefined {
    // Something the user sent while Claude worked, which Claude Code takes now.
    const i = this.pushed.findIndex((q) => q.sent === prompt);
    if (i >= 0) this.taken(this.pushed.splice(i, 1)[0]);
    const parts = [this.folderNotice, this.voiceTurn ? VOICE_GUIDANCE : null, ...this.notices.splice(0)].filter((p): p is string => !!p);
    this.folderNotice = null;
    this.voiceTurn = false;
    return parts.length ? parts.join('\n\n') : undefined;
  }

  async setModel(model: string, by: string): Promise<void> {
    if (!this.session) throw new Error('lead not running');
    // Aliases ("haiku"), the ids they resolve to, and the model the hub started with are all accepted.
    const rows = await this.session.models();
    const known = new Set([...rows.map((m) => m.value), ...rows.flatMap((m) => (m.resolved ? [m.resolved] : [])), this.cfg.model]);
    if (!known.has(model)) throw new Error(`unknown model ${model}; choose one of ${rows.map((m) => m.value).join(', ')}`);
    await this.session.setModel(model);
    this.model = model;
    this.cfg.log(`${by} set the lead model to ${model}`);
    await this.publishInfo();
  }

  /** How Claude asks before it acts. Takes effect at once, mid-turn too; with no session running, the next one starts in it. */
  async setPermissionMode(mode: PermissionMode, by: string): Promise<void> {
    if (!isMode(mode)) throw new Error(`unknown permission mode ${mode}; choose one of ${PERMISSION_MODES.join(', ')}`);
    await this.session?.setMode(mode);
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
    if (this.busy || !this.session || !this.queue.length || this.pushed.length) return;
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
    this.session.send(next.voice ? `${next.text}\n\n${SPOKEN_NOTE}` : next.text, next.images);
  }

  approve(id: string, by: string, updatedInput?: Record<string, unknown>): void {
    const p = this.pending.get(id);
    if (!p) throw new Error(`no pending approval ${id}`);
    const edited = !!updatedInput && stableJson(updatedInput) !== stableJson(p.input);
    // An edited plan Claude Code saves to its plan file, and tells Claude so itself.
    if (edited && p.toolUseId && p.tool !== EXIT_PLAN) this.edits.set(p.toolUseId, { tool: p.tool, original: p.input, ran: updatedInput! });
    this.settle(id, { allow: true, input: updatedInput ?? p.input }, 'allow', edited, by, undefined, edited ? updatedInput : undefined);
  }

  // After each tool call: tell whoever made it when a person changed what ran (it only sees the call it made).
  private afterTool(toolUseId: string): string | undefined {
    const e = this.edits.get(toolUseId);
    if (!e) return undefined;
    this.edits.delete(toolUseId);
    return describeEdit(e);
  }

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
      : note ?? REJECTED;
    this.settle(id, { allow: false, message: reason }, 'deny', false, by, note);
  }

  private settle(id: string, r: ApprovalAnswer, decision: 'allow' | 'deny', edited: boolean, by: string, message?: string, updatedInput?: Record<string, unknown>): void {
    const p = this.pending.get(id);
    if (!p) return;
    this.pending.delete(id);
    this.emit({ type: 'approval_resolved', id, decision, edited, by, message, updatedInput });
    p.resolve(r);
  }

  async interrupt(by: string): Promise<void> {
    if (!this.busy || !this.session) throw new Error('no turn is running');
    this.interrupted = true;
    this.emit({ type: 'interrupt', turn: this.turn, by });
    for (const id of [...this.pending.keys()]) this.settle(id, { allow: false, message: 'Interrupted by the user', interrupt: true }, 'deny', false, by, 'interrupted');
    await this.session.interrupt();
  }

  // Takes effect from the next turn (verified in spike 5).
  async setEffort(level: EffortLevel | null, by: string): Promise<void> {
    if (!this.session) throw new Error('lead not running');
    await this.session.setEffort(level);
    this.effort = level ?? this.cfg.effort;
    this.emit({ type: 'effort', level, by, appliesFrom: 'next_turn' });
    await this.publishInfo();
  }

  async stop(): Promise<void> {
    this.stopping = true;
    this.session?.close();
  }
}
