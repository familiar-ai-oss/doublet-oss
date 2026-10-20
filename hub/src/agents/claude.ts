// Claude Code as the lead, through the Agent SDK: one long-lived query per session. Prompts go in on an input stream
// that stays open (Claude Code takes one sent mid-turn at Claude's next tool call); approvals come from canUseTool;
// Doublet's tools are in-process MCP servers. Claude's own subagents (its Agent tool) are followed here, from Claude
// Code's task messages, and reported to the hub's SubagentPort as workers.
import { getSessionInfo, query } from '@anthropic-ai/claude-agent-sdk';
import type {
  CanUseTool, HookCallback, HookCallbackMatcher, HookEvent, McpSdkServerConfigWithInstance, Options, PermissionResult, Query, SDKMessage,
  SDKTaskNotificationMessage, SDKTaskProgressMessage, SDKTaskStartedMessage, SDKTaskUpdatedMessage, SDKUserMessage,
} from '@anthropic-ai/claude-agent-sdk';
import { claudeExecutable, claudePath, NO_CLAUDE } from '../claude.ts';
import type { EffortLevel, LeadModel, PermissionMode, ToolUse } from '../protocol.ts';
import { clip, resultText } from '../worker.ts';
import { leadAuth, leadEnv, type SubagentOutcome } from '../lead.ts';
import { McpGateway } from './mcp-gateway.ts';
import { Refused, type AgentAdapter, type AgentCaps, type AgentSession, type Image, type SessionHost, type SessionOptions } from './adapter.ts';

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

function withHooks(base: ClaudeExtras['hooks'], extra: Partial<Record<HookEvent, HookCallbackMatcher[]>>): Partial<Record<HookEvent, HookCallbackMatcher[]>> {
  const out: Partial<Record<HookEvent, HookCallbackMatcher[]>> = { ...base };
  for (const [k, v] of Object.entries(extra) as [HookEvent, HookCallbackMatcher[]][]) out[k] = [...(out[k] ?? []), ...v];
  return out;
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

/** What only Claude Code takes: Doublet's tools as in-process MCP servers (a factory: a restarted session needs fresh
 *  instances), and the hub's own SDK hooks. */
export type ClaudeExtras = {
  mcpServers?: () => Record<string, McpSdkServerConfigWithInstance>;
  hooks?: Partial<Record<HookEvent, HookCallbackMatcher[]>>;
  /** Doublet's servers through the hub's gateway (over HTTP, or the stdio relay), as other agents get them, instead
   *  of in-process. For checking that both give Claude the same tools (DUET_MCP_TRANSPORT). */
  gateway?: { gateway: McpGateway; transport: 'http' | 'stdio' };
};

export const CLAUDE_CAPS: AgentCaps = {
  steerMidTurn: true, subagents: true, resume: true, fork: true, liveModelSwitch: true, effort: true,
  approvals: 'callback', promptContext: true, cost: true,
};

export class ClaudeAdapter implements AgentAdapter {
  readonly id = 'claude' as const;
  readonly name = 'Claude Code';
  readonly caps = CLAUDE_CAPS;
  private readonly extras: ClaudeExtras;
  constructor(extras: ClaudeExtras = {}) {
    this.extras = extras;
  }
  open(opts: SessionOptions, host: SessionHost): ClaudeSession {
    return new ClaudeSession(opts, host, this.extras);
  }
  async lookup(sessionId: string): Promise<{ cwd?: string } | null> {
    const info = await getSessionInfo(sessionId).catch(() => null);
    return info ? { cwd: info.cwd } : null;
  }
}

export class ClaudeSession implements AgentSession {
  private q: Query | null = null;
  private input: InputQueue | null = null;
  /** Claude's subagents running in Claude Code, by the Agent call that started each, and Claude Code's task ids for them. */
  private runs = new Map<string, AgentRun>();
  private runOf = new Map<string, string>();
  /** task_started for an Agent call of Claude's that the hub hasn't seen yet (the call's message comes first, normally). */
  private early = new Map<string, SDKTaskStartedMessage>();
  /** Claude Code's live background tasks (their task ids): the whole set each time it changes. Unknown until it first
   *  says, in each of its processes. */
  private backgroundSet: Set<string> | null = null;
  /** This session's servers on the gateway, until its process ends. */
  private tokens: string[] = [];

  private readonly opts: SessionOptions;
  private readonly host: SessionHost;
  private readonly extras: ClaudeExtras;

  constructor(opts: SessionOptions, host: SessionHost, extras: ClaudeExtras = {}) {
    this.opts = opts;
    this.host = host;
    this.extras = extras;
  }

  preflight(): string | null {
    return claudePath() ? null : NO_CLAUDE;
  }

  async start(): Promise<{ subscription?: string }> {
    this.input = new InputQueue();
    this.q = query({ prompt: this.input, options: this.options() });
    // With DUET_LEAD_AUTH set, check the login before accepting any prompt.
    const account = await this.q.accountInfo();
    const auth = leadAuth();
    const plan = account.apiProvider === 'firstParty' && !!account.subscriptionType;
    if ((auth === 'subscription' && !plan) || (auth === 'max' && !(plan && /max/i.test(account.subscriptionType ?? '')))) {
      this.input.close();
      throw new Refused(`DUET_LEAD_AUTH=${auth}, but Claude Code is signed in with subscription=${account.subscriptionType}, provider=${account.apiProvider}`);
    }
    return { subscription: account.subscriptionType };
  }

  run(): Promise<void> {
    return this.pump(this.q!);
  }

  /** A session's options: built for each start, since a restarted session needs fresh MCP server instances. */
  private options(): Options {
    const o = this.opts;
    return {
      cwd: o.cwd,
      // Claude Code says when nothing at all runs any more, background work included (session_state_changed idle).
      ...claudeExecutable(),
      env: { ...leadEnv(), CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS: '1' },
      model: o.model,
      effort: o.effort,
      settingSources: [],
      settings: { crossSessionInbound: 'refuse' },
      // Bypass Permissions can only be switched on later in a session that starts allowing it.
      permissionMode: o.mode,
      allowDangerouslySkipPermissions: true,
      allowedTools: o.autoAllow,
      ...(o.disallowedTools?.length ? { disallowedTools: o.disallowedTools } : {}),
      canUseTool: this.ask,
      mcpServers: this.mcpServers(),
      hooks: withHooks(this.extras.hooks, {
        PostToolUse: [{ hooks: [this.afterTool] }],
        PostToolUseFailure: [{ hooks: [this.afterTool] }],
        UserPromptSubmit: [{ hooks: [this.beforePrompt] }],
      }),
      includePartialMessages: true,
      // Resume a session Claude Code has; give a new one its id (the two options exclude each other).
      ...(o.resume ? { resume: o.sessionId } : { sessionId: o.sessionId }),
      stderr: (d) => this.host.log(`[claude] ${d.trimEnd()}`),
    };
  }

  /** Doublet's servers: in-process, or registered on the gateway and reached at their URL. */
  private mcpServers(): Options['mcpServers'] {
    const servers = this.extras.mcpServers?.();
    const via = this.extras.gateway;
    if (!servers || !via) return servers;
    return Object.fromEntries(Object.entries(servers).map(([name, like]) => {
      const { token, url } = via.gateway.register(() => this.extras.mcpServers!()[name]);
      this.tokens.push(token);
      return [name, via.transport === 'http' ? McpGateway.http(url, like) : McpGateway.stdio(url, like)];
    }));
  }

  // Each call that needs an OK goes to the hub, which makes it an approval card on every device.
  private ask: CanUseTool = (tool, input, opts) =>
    new Promise<PermissionResult>((resolve) => {
      this.host.event({
        type: 'approval', tool, input, toolUseId: opts.toolUseID, title: opts.title, description: opts.description,
        displayName: opts.displayName, defaultToNo: opts.defaultToNo,
        respond: (a) => resolve(a.allow ? { behavior: 'allow', updatedInput: a.input } : { behavior: 'deny', message: a.message, ...(a.interrupt ? { interrupt: true } : {}) }),
        onWithdrawn: (f) => opts.signal.addEventListener('abort', f),
      });
    });

  private beforePrompt: HookCallback = async (input) => {
    const extra = this.host.beforePrompt((input as { prompt?: unknown }).prompt);
    return extra ? { hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: extra } } : {};
  };

  // After each tool call: tell whoever made it when a person changed what ran (it only sees the call it made).
  private afterTool: HookCallback = async (input) => {
    if (input.hook_event_name !== 'PostToolUse' && input.hook_event_name !== 'PostToolUseFailure') return {};
    const extra = this.host.afterTool(input.tool_use_id);
    return extra ? { hookSpecificOutput: { hookEventName: input.hook_event_name, additionalContext: extra } } : {};
  };

  private async pump(q: Query): Promise<void> {
    let error: string | undefined;
    try {
      for await (const m of q) this.handle(m);
      this.host.log('lead stream ended');
    } catch (err) {
      error = `lead session failed: ${String(err).slice(0, 500)}`;
    }
    this.host.event({ type: 'closed', ...(error ? { error } : {}) });
  }

  send(text: string, images?: Image[]): void {
    this.input!.push(text, images);
  }

  async interrupt(): Promise<void> {
    await this.q!.interrupt();
  }

  async models(): Promise<LeadModel[]> {
    return (await this.q!.supportedModels()).map((m) => ({ value: m.value, displayName: m.displayName, effortLevels: m.supportedEffortLevels ?? [], resolved: m.resolvedModel }));
  }

  async setModel(model: string): Promise<void> {
    await this.q!.setModel(model);
  }

  async setMode(mode: PermissionMode): Promise<void> {
    await this.q?.setPermissionMode(mode);
  }

  // Takes effect from the next turn (verified in spike 5).
  async setEffort(level: EffortLevel | null): Promise<void> {
    await this.q!.applyFlagSettings({ effortLevel: level });
  }

  close(): void {
    this.input?.close();
    this.q?.close?.();
  }

  /** The subagents Claude waited on were cut off; those in the background run on, and end with their own notices. */
  endTurn(): void {
    this.host.subagents?.stopped();
    for (const [id, run] of this.runs) if (!run.background && !run.parent) this.forget(id);
    this.early.clear();
  }

  /** Claude's subagents run in Claude Code's process: they stopped with it. The next process says nothing of its
   *  background work until that changes. */
  release(): void {
    this.host.subagents?.stopped(true);
    for (const id of [...this.runs.keys()]) this.forget(id);
    this.early.clear();
    this.backgroundSet = null;
    for (const t of this.tokens.splice(0)) this.extras.gateway?.gateway.unregister(t);
  }

  handle(m: SDKMessage): void {
    const ev = this.host.event;
    switch (m.type) {
      case 'system':
        if (m.subtype === 'compact_boundary') return ev({ type: 'compacted', preTokens: m.compact_metadata.pre_tokens, postTokens: m.compact_metadata.post_tokens });
        // Claude Code says whenever the mode changes: set from a device, or by Claude leaving plan mode.
        if (m.subtype === 'status') return m.permissionMode ? ev({ type: 'mode', mode: m.permissionMode }) : undefined;
        if (m.subtype === 'init') {
          ev({ type: 'mode', mode: m.permissionMode });
          if (leadAuth() !== 'any' && m.apiKeySource !== 'none') {
            return ev({ type: 'fatal', message: `lead apiKeySource is ${m.apiKeySource}, but DUET_LEAD_AUTH=${leadAuth()} expects a Claude plan; stopping` });
          }
          return ev({ type: 'ready', sessionId: m.session_id });
        }
        // Claude's subagents as Claude Code runs them: started, sent to the background, ended.
        if (m.subtype === 'task_started') return this.taskStarted(m);
        if (m.subtype === 'task_updated') return this.taskUpdated(m);
        if (m.subtype === 'task_progress') return this.taskProgress(m);
        if (m.subtype === 'task_notification') return this.taskNotified(m);
        if (m.subtype === 'background_tasks_changed') return this.backgroundChanged(m.tasks.map((t) => t.task_id));
        // Idle: nothing runs in Claude Code any more, background work included. (Claude Code says "running" for as long as
        // background work runs, so it doesn't mark the turns it starts itself: the hub's `activity` does.)
        if (m.subtype === 'session_state_changed' && m.state === 'idle') {
          ev({ type: 'idle' });
          return this.settled();
        }
        return;
      case 'stream_event': {
        if (m.parent_tool_use_id !== null) return;
        ev({ type: 'activity' });
        const e = m.event;
        if (e.type === 'content_block_delta' && e.delta.type === 'text_delta') ev({ type: 'text', delta: e.delta.text });
        return;
      }
      case 'assistant': {
        const blocks = m.message.content;
        const text = blocks.flatMap((b) => (b.type === 'text' ? [b.text] : [])).join('');
        if (m.parent_tool_use_id !== null) {
          // One of Claude's subagents at work: its task's progress.
          const u = m.message.usage;
          this.host.subagents?.progress(m.parent_tool_use_id, {
            text: text || undefined,
            toolUses: blocks.flatMap((b) => (b.type === 'tool_use' ? [{ name: b.name, input: clip(b.input) }] : [])),
            usage: u ? { messageId: m.message.id, input: (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0), output: u.output_tokens ?? 0 } : undefined,
          });
          return;
        }
        ev({ type: 'activity' });
        const toolUses: ToolUse[] = blocks.flatMap((b) => (b.type === 'tool_use' ? [{ id: b.id, name: b.name, input: b.input }] : []));
        if (text || toolUses.length) ev({ type: 'message', text, toolUses });
        for (const u of toolUses) {
          if (!AGENT_TOOLS.has(u.name)) continue;
          const input = (u.input ?? {}) as { prompt?: unknown; subagent_type?: unknown; description?: unknown };
          if (!this.runs.has(u.id)) this.runs.set(u.id, { background: false });
          const label = typeof input.description === 'string' && input.description.trim() ? input.description.trim() : undefined;
          this.host.subagents?.start(u.id, typeof input.subagent_type === 'string' && input.subagent_type ? input.subagent_type : 'general-purpose', String(input.prompt ?? ''), label ? { label } : {});
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
            this.host.subagents?.progress(m.parent_tool_use_id, { toolResult: resultText(b.content).slice(0, 500) });
            continue;
          }
          ev({ type: 'activity' });
          // A subagent's report, or word that it went to the background (before the tool result, so clients know the row
          // is the task's).
          if (this.host.subagents?.isSubagent(b.tool_use_id)) this.agentResult(b.tool_use_id, !!b.is_error, b.content, (m as { tool_use_result?: unknown }).tool_use_result);
          ev({ type: 'tool_end', toolUseId: b.tool_use_id, isError: !!b.is_error, output: typeof b.content === 'string' ? b.content : JSON.stringify(b.content ?? '') });
        }
        return;
      }
      case 'result':
        return ev({ type: 'turn_end', subtype: m.subtype, isError: m.is_error, durationMs: m.duration_ms, numTurns: m.num_turns });
    }
  }

  /** An Agent call's result: the subagent's report, or word that it went to the background, where it runs on until its
   *  own notice says it ended. */
  private agentResult(id: string, isError: boolean, content: Parameters<typeof resultText>[0], out: unknown): void {
    const run = this.runs.get(id) ?? { background: false };
    this.runs.set(id, run);
    const status = out && typeof out === 'object' ? (out as { status?: unknown }).status : undefined;
    if (!isError && (status === 'async_launched' || (run.background && status !== 'completed'))) return this.toBackground(id, run);
    this.forget(id);
    this.host.subagents?.end(id, isError ? 'failed' : 'done', resultText(content), subagentOutcome(out));
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
      this.host.subagents?.start(id, m.subagent_type || 'general-purpose', m.prompt || m.description, {
        label: m.description || undefined, parent, ...(m.spawn_depth ? { depth: m.spawn_depth } : {}), ...(run.background ? { background: true } : {}),
      });
    } else if (m.is_backgrounded) {
      this.toBackground(id, run);
    }
  }

  private toBackground(id: string, run: AgentRun): void {
    if (run.background) return;
    run.background = true;
    this.host.subagents?.background(id);
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
    this.host.subagents?.end(id, state, summary, { report, toolUses: usage?.tool_uses ?? 0, durationMs: usage?.duration_ms ?? 0, ...(usage ? { totalTokens: usage.total_tokens } : {}) });
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
    this.host.log(`subagent ${id} ended without a notice: Claude Code no longer runs it${run.endedAs ? ` (it said ${run.endedAs})` : ''}`);
    const state = run.endedAs === 'completed' ? 'done' : run.endedAs === 'killed' ? 'cancelled' : 'failed';
    this.finish(id, state, run.endedAs ? LATE_NOTE : LOST_NOTE, '', run.usage);
  }
}
