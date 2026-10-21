// Any agent that speaks the Agent Client Protocol (agentclientprotocol.com) as the lead: JSON-RPC 2.0 over stdio, one
// message per line. Cursor's CLI (`agent acp`) is the first; another ACP agent takes only a spec.
//
// ACP takes one prompt at a time: what you write while a turn runs waits for it to end and starts the next (Claude Code
// does the same with a prompt that comes too late for the running turn). Permission requests become approval cards;
// Doublet's tools are given as an HTTP MCP server through the hub's gateway, in session/new.
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createInterface } from 'node:readline';
import type { McpSdkServerConfigWithInstance } from '@anthropic-ai/claude-agent-sdk';
import { defaultScanEnv, findCursor } from '../agents.ts';
import { baseEnv } from '../lead.ts';
import type { AgentId, EffortLevel, LeadModel, PermissionMode, ToolUse } from '../protocol.ts';
import { McpGateway } from './mcp-gateway.ts';
import { REJECTED, Refused, type AgentAdapter, type AgentCaps, type AgentSession, type ApprovalAnswer, type Image, type SessionHost, type SessionOptions } from './adapter.ts';

/** One ACP agent: how to run it, and what of the hub's it maps onto its own. */
export type AcpSpec = {
  id: AgentId;
  name: string;
  /** Its executable on the hub's machine, or null. */
  find: () => string | null;
  args: string[];
  /** Environment it needs beyond the hub's base (its own API key, say). */
  env?: string[];
  /** Doublet's permission mode as one of its session modes (null: leave its mode alone). */
  mode: (m: PermissionMode) => string | null;
  /** Its session mode as Doublet's, when it changes it itself (null: not one Doublet follows). */
  fromMode?: (modeId: string) => PermissionMode | null;
};

export const ACP_CAPS: AgentCaps = {
  steerMidTurn: false, subagents: true, resume: true, fork: false, liveModelSwitch: true, effort: false,
  approvals: 'callback', promptContext: false, cost: false,
};

/** Cursor's CLI: agent, plan and ask modes. Doublet's plan mode is its plan; every other mode is its agent mode, which
 *  asks first through session/request_permission (Bypass Permissions answers those itself). */
export const CURSOR_ACP: AcpSpec = {
  id: 'cursor', name: 'Cursor', args: ['acp'], env: ['CURSOR_API_KEY'],
  find: () => findCursor(defaultScanEnv()),
  mode: (m) => (m === 'plan' ? 'plan' : 'agent'),
  fromMode: (id) => (id === 'plan' ? 'plan' : null),
};

type Rpc = { jsonrpc?: '2.0'; id?: number | string; method?: string; params?: any; result?: any; error?: { code: number; message: string } };
type PermissionOption = { optionId: string; name: string; kind: 'allow_once' | 'allow_always' | 'reject_once' | 'reject_always' };
/** Read-only kinds of tool call, which run without asking (as Read, Glob, Grep and the like do for Claude). */
const QUIET_KINDS = new Set(['read', 'search', 'think', 'fetch']);

export type AcpExtras = {
  mcpServers?: () => Record<string, McpSdkServerConfigWithInstance>;
  gateway?: McpGateway;
  /** Doublet's guidance for the lead: ACP has no system prompt, so it goes with the first prompt of a new session. */
  instructions?: () => string;
};

export class AcpAdapter implements AgentAdapter {
  readonly caps = ACP_CAPS;
  readonly spec: AcpSpec;
  private readonly extras: AcpExtras;
  constructor(spec: AcpSpec, extras: AcpExtras = {}) {
    this.spec = spec;
    this.extras = extras;
  }
  get id(): AgentId { return this.spec.id; }
  get name(): string { return this.spec.name; }
  open(opts: SessionOptions, host: SessionHost): AcpSession {
    return new AcpSession(this.spec, opts, host, this.extras);
  }
  /** ACP can't look a session up without loading it: any id is taken, and load says if it's gone. */
  async lookup(): Promise<{ cwd?: string } | null> {
    return {};
  }
}

export class AcpSession implements AgentSession {
  private proc: ChildProcessWithoutNullStreams | null = null;
  private nextId = 1;
  private calls = new Map<number, { resolve: (r: any) => void; reject: (e: Error) => void; method: string }>();
  private sessionId: string | null = null;
  /** A prompt is running (its session/prompt call hasn't answered). */
  private running = false;
  /** Prompts written while one runs: the next turn, in order. */
  private waiting: unknown[][] = [];
  /** session/load replays the session's history as updates: not news. */
  private loading = false;
  /** The agent's words in this turn since its last tool call, sent as one message. */
  private text = '';
  /** Tool calls that started, by id, as the agent has described them so far: shown once they say what they are (Cursor
   *  announces an MCP call as "MCP: tool" with no input, and names it in its next update); their result comes later. */
  private open = new Map<string, { call: any; shown: boolean }>();
  private models_: LeadModel[] = [];
  /** Cursor's subagents running now (cursor/task), by their tool call. */
  private tasks = new Set<string>();
  private mode: PermissionMode;
  private tokens: string[] = [];
  private guidance: string | null = null;
  private exited: Promise<void> | null = null;
  private stderrTail: string[] = [];
  private closing = false;

  private readonly spec: AcpSpec;
  private readonly opts: SessionOptions;
  private readonly host: SessionHost;
  private readonly extras: AcpExtras;

  constructor(spec: AcpSpec, opts: SessionOptions, host: SessionHost, extras: AcpExtras = {}) {
    this.spec = spec;
    this.opts = opts;
    this.host = host;
    this.extras = extras;
    this.mode = opts.mode;
  }

  preflight(): string | null {
    return this.spec.find() ? null : `${this.spec.name} isn't installed for the hub's user: install it and sign in, or choose another lead.`;
  }

  async start(): Promise<{ subscription?: string }> {
    const env: Record<string, string> = { ...baseEnv(), NO_COLOR: '1' };
    for (const k of this.spec.env ?? []) if (process.env[k]) env[k] = process.env[k]!;
    const proc = spawn(this.spec.find()!, this.spec.args, { cwd: this.opts.cwd, env, stdio: ['pipe', 'pipe', 'pipe'] });
    this.proc = proc;
    this.exited = new Promise((r) => proc.once('exit', () => r()));
    proc.stderr.setEncoding('utf8');
    proc.stderr.on('data', (d: string) => {
      for (const line of d.split('\n').filter(Boolean)) {
        this.host.log(`[${this.spec.id}] ${line}`);
        this.stderrTail.push(line);
        if (this.stderrTail.length > 20) this.stderrTail.shift();
      }
    });
    createInterface({ input: proc.stdout }).on('line', (line) => this.receive(line));
    proc.once('exit', (code) => {
      for (const c of this.calls.values()) c.reject(new Error(`${this.spec.name} exited (${code}) during ${c.method}`));
      this.calls.clear();
    });

    const init = await this.call('initialize', {
      protocolVersion: 1, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
      clientInfo: { name: 'doublet', title: 'Doublet', version: '0.1.0' },
    });
    const mcpServers = this.mcpServers();
    let r: { sessionId?: string; models?: { availableModels: { modelId: string; name: string }[]; currentModelId?: string }; modes?: { currentModeId?: string } };
    try {
      if (this.opts.resume && init.agentCapabilities?.loadSession) {
        this.loading = true;
        r = await this.call('session/load', { sessionId: this.opts.sessionId, cwd: this.opts.cwd, mcpServers });
        r.sessionId ??= this.opts.sessionId;
      } else {
        r = await this.call('session/new', { cwd: this.opts.cwd, mcpServers });
        this.guidance = this.extras.instructions?.() ?? null;
      }
    } catch (e) {
      this.close();
      const signIn = (init.authMethods ?? []).map((m: { name: string; description?: string }) => m.description || m.name).join('; ');
      throw new Refused(`${this.spec.name} didn't start a session: ${(e as Error).message}${signIn ? ` (${signIn})` : ''}`);
    } finally {
      this.loading = false;
    }
    this.sessionId = r.sessionId!;
    this.models_ = (r.models?.availableModels ?? []).map((m) => ({ value: m.modelId, displayName: m.name, effortLevels: [] }));
    const want = this.models_.find((m) => m.value === this.opts.model || m.displayName === this.opts.model);
    if (want && want.value !== r.models?.currentModelId) await this.setModel(want.value).catch((e) => this.host.log(`${this.spec.name} kept its model: ${e}`));
    await this.applyMode().catch((e) => this.host.log(`${this.spec.name} kept its mode: ${e}`));
    this.host.event({ type: 'ready', sessionId: this.sessionId });
    return {};
  }

  /** Doublet's servers through the gateway, as ACP's HTTP MCP servers. */
  private mcpServers(): unknown[] {
    const servers = this.extras.mcpServers?.();
    const g = this.extras.gateway;
    if (!servers || !g) return [];
    return Object.keys(servers).map((name) => {
      const { token, url } = g.register(() => this.extras.mcpServers!()[name]);
      this.tokens.push(token);
      return { type: 'http', name, url, headers: [] };
    });
  }

  async run(): Promise<void> {
    await this.exited;
    const tail = this.stderrTail.at(-1);
    this.host.event({ type: 'closed', ...(this.closing ? {} : { error: `${this.spec.name} ended${tail ? `: ${tail.slice(0, 300)}` : ''}` }) });
  }

  // ---- the wire ----

  private call<T = any>(method: string, params: unknown): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.calls.set(id, { resolve, reject, method });
      this.write({ jsonrpc: '2.0', id, method, params });
    });
  }

  private write(m: Rpc): void {
    if (!this.proc || this.proc.stdin.destroyed) return;
    this.proc.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', ...m })}\n`);
  }

  private receive(line: string): void {
    // DUET_ACP_TRACE=1: every message the agent sends, to see what a new version changed.
    if (process.env.DUET_ACP_TRACE) this.host.log(`[${this.spec.id} <] ${line.slice(0, 4000)}`);
    let m: Rpc;
    try { m = JSON.parse(line); } catch { return this.host.log(`[${this.spec.id}] not JSON: ${line.slice(0, 200)}`); }
    if (m.id !== undefined && !m.method) {
      const c = this.calls.get(m.id as number);
      if (!c) return;
      this.calls.delete(m.id as number);
      return m.error ? c.reject(new Error(m.error.message)) : c.resolve(m.result);
    }
    if (m.id !== undefined && m.method) return this.request(m.id, m.method, m.params);
    if (m.method === 'session/update') this.update(m.params?.update ?? {});
    if (m.method === 'cursor/task') this.task(m.params ?? {});
  }

  /** Exposed for tests: one line from the agent. */
  handle(m: Rpc): void {
    this.receive(JSON.stringify(m));
  }

  // ---- what the agent says ----

  private update(u: any): void {
    if (this.loading) return;
    const ev = this.host.event;
    switch (u.sessionUpdate) {
      case 'agent_message_chunk':
        if (u.content?.type !== 'text') return;
        this.text += u.content.text;
        ev({ type: 'activity' });
        return ev({ type: 'text', delta: u.content.text });
      case 'tool_call':
        ev({ type: 'activity' });
        this.flush();
        this.open.set(u.toolCallId, { call: u, shown: false });
        return this.toolChanged(u.toolCallId, u);
      case 'tool_call_update':
        return this.toolChanged(u.toolCallId, u);
      case 'current_mode_update': {
        const m = this.spec.fromMode?.(u.currentModeId);
        if (m && m !== this.mode) ev({ type: 'mode', mode: m });
        else if (!m && this.mode === 'plan') ev({ type: 'mode', mode: 'default' });
        return;
      }
    }
  }

  /** A tool call started or changed: shown once it says what it is (it has input, or it's running), ended once done. */
  private toolChanged(id: string, u: any): void {
    const t = this.open.get(id);
    if (!t) return;
    const raw = u.rawInput && typeof u.rawInput === 'object' && Object.keys(u.rawInput).length ? u.rawInput : undefined;
    t.call = { ...t.call, ...u, ...(raw ? { rawInput: raw } : { rawInput: t.call.rawInput }) };
    const done = u.status === 'completed' || u.status === 'failed';
    const described = !!t.call.rawInput && Object.keys(t.call.rawInput).length > 0;
    if (!t.shown && (described || done || (u.status && u.status !== 'pending'))) {
      t.shown = true;
      this.host.event({ type: 'activity' });
      this.host.event({ type: 'message', text: '', toolUses: [toolUse(t.call)] });
    }
    if (done) this.toolEnd(t.call);
  }

  /** Cursor started a subagent (cursor/task): a worker, until its tool call ends. */
  private task(p: { toolCallId?: string; description?: string; prompt?: string; subagentType?: unknown }): void {
    if (this.loading || !p.toolCallId || this.tasks.has(p.toolCallId)) return;
    this.tasks.add(p.toolCallId);
    const kind = typeof p.subagentType === 'string' ? p.subagentType : (p.subagentType as { custom?: string } | undefined)?.custom ?? 'unspecified';
    this.host.subagents?.start(p.toolCallId, kind === 'unspecified' ? 'general-purpose' : kind, p.prompt ?? p.description ?? '', p.description ? { label: p.description } : {});
  }

  private toolEnd(u: any): void {
    if (!this.open.delete(u.toolCallId)) return;
    this.host.event({ type: 'activity' });
    const output = toolText(u);
    if (this.tasks.delete(u.toolCallId)) this.host.subagents?.end(u.toolCallId, u.status === 'failed' ? 'failed' : 'done', output);
    this.host.event({ type: 'tool_end', toolUseId: u.toolCallId, isError: u.status === 'failed', output });
    // Clears an edit the hub kept for this call: ACP agents run the call they asked about, so there's none to report.
    this.host.afterTool(u.toolCallId);
  }

  /** The words since the last tool call, as one message. */
  private flush(): void {
    if (!this.text) return;
    this.host.event({ type: 'message', text: this.text, toolUses: [] });
    this.text = '';
  }

  /** A request from the agent: a permission becomes an approval card (or runs, for read-only kinds and Bypass
   *  Permissions), Cursor's plan and questions their cards; anything Doublet can't do is refused. Every request is
   *  answered, or the agent waits for ever. */
  private request(id: number | string, method: string, p: any): void {
    if (method === 'cursor/create_plan') return this.planReady(id, p);
    if (method === 'cursor/ask_question') return this.questions(id, p);
    if (method !== 'session/request_permission') {
      this.host.log(`${this.spec.name} asked ${method}, which Doublet doesn't handle: refused`);
      return this.write({ id, error: { code: -32601, message: `Doublet doesn't handle ${method}` } });
    }
    const options: PermissionOption[] = p.options ?? [];
    const pick = (kinds: PermissionOption['kind'][]) => kinds.map((k) => options.find((o) => o.kind === k)).find(Boolean);
    const choose = (o: PermissionOption | undefined) => this.write({ id, result: { outcome: o ? { outcome: 'selected', optionId: o.optionId } : { outcome: 'cancelled' } } });
    const call = p.toolCall ?? {};
    if (this.mode === 'bypassPermissions' || QUIET_KINDS.has(call.kind) || isDoublets(call)) return choose(pick(['allow_once', 'allow_always']));
    const use = toolUse(call);
    let done = false;
    this.host.event({
      type: 'approval', tool: use.name, input: use.input as Record<string, unknown>, toolUseId: call.toolCallId, ...(call.title ? { title: call.title } : {}),
      respond: (a: ApprovalAnswer) => {
        if (done) return;
        done = true;
        // An agent can't run an edited call: this one is refused, and it's told what you want run instead.
        if (a.allow) {
          const command = a.input.command;
          if (use.name !== 'Bash' || typeof command !== 'string' || command === (use.input as { command?: unknown }).command) return choose(pick(['allow_once', 'allow_always']));
          choose(pick(['reject_once', 'reject_always']));
          return this.tell(`[duet] The user edited that command before approving it. Run this instead: ${command}`);
        }
        choose(a.interrupt ? undefined : pick(['reject_once', 'reject_always']));
        if (!a.interrupt && a.message && a.message !== REJECTED) this.tell(`[duet] The user rejected that call: ${a.message}`);
      },
      onWithdrawn: () => {},
    });
  }

  /** Cursor's plan (cursor/create_plan, in plan mode): the plan's approval card, as Claude's ExitPlanMode. Approving
   *  leaves plan mode and starts the work, as Cursor's Build does; rejecting keeps it planning, with your note. */
  private planReady(id: number | string, p: { plan?: string; name?: string; overview?: string; todos?: unknown[] }): void {
    const plan = p.plan || [p.name, p.overview].filter(Boolean).join('\n\n');
    let done = false;
    this.host.event({
      type: 'approval', tool: 'ExitPlanMode', input: { plan, ...(p.name ? { name: p.name } : {}) }, toolUseId: (p as { toolCallId?: string }).toolCallId,
      respond: (a: ApprovalAnswer) => {
        if (done) return;
        done = true;
        // Answers nest their outcome, as ACP's permission answers do: { outcome: { outcome: "accepted" } }.
        if (!a.allow) return this.write({ id, result: { outcome: a.interrupt ? { outcome: 'cancelled' } : { outcome: 'rejected', reason: a.message } } });
        this.write({ id, result: { outcome: { outcome: 'accepted' } } });
        const edited = typeof a.input.plan === 'string' && a.input.plan !== plan ? a.input.plan : null;
        this.mode = 'default';
        this.host.event({ type: 'mode', mode: 'default' });
        void this.applyMode().catch((e) => this.host.log(`${this.spec.name} kept its mode: ${e}`));
        this.tell(edited ? `[duet] The user approved your plan, with their edits. Implement this plan now:\n\n${edited}` : '[duet] The user approved your plan. Implement it now.');
      },
      onWithdrawn: () => {},
    });
  }

  /** Cursor's questions (cursor/ask_question): the question card, as Claude's AskUserQuestion. Answers go back by
   *  option id. */
  private questions(id: number | string, p: { toolCallId?: string; title?: string; questions?: { id: string; prompt: string; options?: { id: string; label: string }[]; allowMultiple?: boolean }[] }): void {
    const qs = p.questions ?? [];
    let done = false;
    this.host.event({
      type: 'approval', tool: 'AskUserQuestion', toolUseId: p.toolCallId,
      input: { questions: qs.map((q) => ({ question: q.prompt, ...(p.title ? { header: p.title } : {}), options: (q.options ?? []).map((o) => ({ label: o.label })), multiSelect: !!q.allowMultiple })) },
      respond: (a: ApprovalAnswer) => {
        if (done) return;
        done = true;
        if (!a.allow) return this.write({ id, result: { outcome: a.interrupt ? { outcome: 'cancelled' } : { outcome: 'skipped', reason: a.message } } });
        const given = (a.input.answers ?? {}) as Record<string, string>;
        const answers = qs.map((q) => {
          const picked = (given[q.prompt] ?? '').split(',').map((x) => x.trim()).filter(Boolean);
          return { questionId: q.id, selectedOptionIds: (q.options ?? []).filter((o) => picked.includes(o.label)).map((o) => o.id) };
        });
        this.write({ id, result: { outcome: { outcome: 'answered', answers } } });
      },
      onWithdrawn: () => {},
    });
  }

  /** Something the hub tells the agent itself: the next prompt (ACP takes one at a time). */
  private tell(text: string): void {
    const prompt = [{ type: 'text', text }];
    if (this.running) this.waiting.push(prompt);
    else this.prompt(prompt, undefined, true);
  }

  // ---- what the hub asks ----

  send(text: string, images: Image[] = []): void {
    const prompt = [
      ...images.map((i) => ({ type: 'image', mimeType: i.type, data: i.data })),
      { type: 'text', text },
    ];
    if (this.running) return void this.waiting.push(prompt);
    this.prompt(prompt, text);
  }

  /** Runs one prompt as a turn. The hub hears it was taken now, with anything to add (ACP has no hidden context, so it
   *  goes in the prompt), and Doublet's guidance goes with a new session's first prompt. */
  private prompt(prompt: unknown[], text?: string, own = false): void {
    // The hub's own message isn't one of yours, so it isn't announced as taken (the hub opens a turn for it).
    const extra = own ? undefined : this.host.beforePrompt(text ?? (prompt.find((b: any) => b.type === 'text') as { text?: string } | undefined)?.text);
    const blocks = [...(this.guidance ? [{ type: 'text', text: this.guidance }] : []), ...prompt, ...(extra ? [{ type: 'text', text: extra }] : [])];
    this.guidance = null;
    this.running = true;
    this.host.event({ type: 'activity' });
    const started = Date.now();
    this.call<{ stopReason: string }>('session/prompt', { sessionId: this.sessionId, prompt: blocks }).then(
      (r) => this.turnEnded(r.stopReason, started),
      (e) => {
        this.host.log(`${this.spec.name} turn failed: ${e}`);
        this.turnEnded('error', started);
      },
    );
  }

  private turnEnded(stopReason: string, started: number): void {
    this.running = false;
    this.flush();
    this.host.event({
      type: 'turn_end', subtype: stopReason === 'end_turn' ? 'success' : stopReason === 'cancelled' ? 'interrupted' : 'error_during_execution',
      isError: stopReason === 'error' || stopReason === 'refusal', durationMs: Date.now() - started, numTurns: 1,
    });
    const next = this.waiting.shift();
    if (next) this.prompt(next);
  }

  async interrupt(): Promise<void> {
    if (!this.running) return;
    this.write({ method: 'session/cancel', params: { sessionId: this.sessionId } });
  }

  async models(): Promise<LeadModel[]> {
    return this.models_;
  }

  async setModel(model: string): Promise<void> {
    await this.call('session/set_model', { sessionId: this.sessionId, modelId: model });
  }

  async setMode(mode: PermissionMode): Promise<void> {
    this.mode = mode;
    await this.applyMode();
  }

  private async applyMode(): Promise<void> {
    const id = this.spec.mode(this.mode);
    if (id) await this.call('session/set_mode', { sessionId: this.sessionId, modeId: id });
  }

  async setEffort(_level: EffortLevel | null): Promise<void> {}

  /** Subagents end with their turn. */
  endTurn(): void {
    if (this.tasks.size) this.host.subagents?.stopped();
    this.tasks.clear();
  }

  release(): void {
    if (this.tasks.size) this.host.subagents?.stopped(true);
    this.tasks.clear();
    for (const t of this.tokens.splice(0)) this.extras.gateway?.unregister(t);
  }

  close(): void {
    this.closing = true;
    this.proc?.stdin.end();
    this.proc?.kill('SIGTERM');
  }
}

/** One of Doublet's own tools (its MCP server is "duet"): they never wait for an OK. */
function isDoublets(call: { title?: string; rawInput?: unknown; _meta?: unknown }): boolean {
  return /\bduet\b|mcp__duet__/.test(`${call.title ?? ''}`);
}

/** An ACP tool call as Doublet shows one: Bash for commands, Edit for edits, Read, Grep; else its title. */
function toolUse(u: { toolCallId: string; kind?: string; title?: string; rawInput?: any }): ToolUse {
  const raw = u.rawInput && typeof u.rawInput === 'object' ? u.rawInput : {};
  // An MCP call, as Cursor describes one: named as Claude Code names them.
  if (typeof raw.providerIdentifier === 'string' && typeof raw.toolName === 'string') {
    return { id: u.toolCallId, name: `mcp__${raw.providerIdentifier}__${raw.toolName}`, input: raw.args ?? {} };
  }
  switch (u.kind) {
    case 'execute': return { id: u.toolCallId, name: 'Bash', input: { command: raw.command ?? u.title ?? '', ...raw } };
    case 'edit': case 'delete': case 'move': return { id: u.toolCallId, name: 'Edit', input: { ...raw, title: u.title } };
    case 'read': return { id: u.toolCallId, name: 'Read', input: { ...raw, title: u.title } };
    case 'search': return { id: u.toolCallId, name: 'Grep', input: { ...raw, title: u.title } };
    case 'fetch': return { id: u.toolCallId, name: 'WebFetch', input: { ...raw, title: u.title } };
    default: return { id: u.toolCallId, name: u.title || u.kind || 'tool', input: { ...raw } };
  }
}

/** A tool call's result as text: its text content, diffs as path and new text, else its raw output. */
function toolText(u: { content?: any[]; rawOutput?: unknown }): string {
  const parts = (u.content ?? []).map((c) => {
    if (c.type === 'content' && c.content?.type === 'text') return c.content.text as string;
    if (c.type === 'diff') return `${c.path}\n${c.newText ?? ''}`;
    if (c.type === 'terminal') return `(terminal ${c.terminalId})`;
    return '';
  }).filter(Boolean);
  if (parts.length) return parts.join('\n');
  return u.rawOutput === undefined ? '' : typeof u.rawOutput === 'string' ? u.rawOutput : JSON.stringify(u.rawOutput);
}
