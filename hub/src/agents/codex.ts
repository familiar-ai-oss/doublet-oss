// OpenAI's Codex CLI as the lead, through `codex app-server`: JSON-RPC over stdio (one JSON object per line, without a
// "jsonrpc" field). A thread is the conversation; each prompt starts a turn, and what you write while it works steers
// the running turn (turn/steer), as Claude Code takes a prompt mid-turn. Approvals come as requests from the server.
// Doublet's tools reach it through the hub's MCP gateway over HTTP, set in the thread's config.
//
// Protocol: the types `codex app-server generate-ts` writes for the version in TESTED_CODEX (docs/agents/codex.md has
// the sources). Only the fields used here are typed below.
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import type { McpSdkServerConfigWithInstance } from '@anthropic-ai/claude-agent-sdk';
import { agentDirs } from '../agents.ts';
import { findIn } from '../claude.ts';
import { baseEnv } from '../lead.ts';
import { EFFORT_LEVELS, type EffortLevel, type LeadModel, type PermissionMode, type ToolUse } from '../protocol.ts';
import { McpGateway } from './mcp-gateway.ts';
import { REJECTED, Refused, type AgentAdapter, type AgentCaps, type AgentSession, type Image, type SessionHost, type SessionOptions } from './adapter.ts';

/** The app-server version this adapter was written and tested against. */
export const TESTED_CODEX = '0.156.1';

export const CODEX_CAPS: AgentCaps = {
  steerMidTurn: true, subagents: true, resume: true, fork: true, liveModelSwitch: true, effort: true,
  approvals: 'callback', promptContext: false, cost: false,
};

/** Codex's plan mode, its questions and its plan come through the experimental API (collaborationMode on turn/start),
 *  as in Codex's own app. */
const EXPERIMENTAL = true;

/** The `codex` to run: DUET_CODEX_PATH, else the first on PATH or where its installers put it. */
export function codexPath(env: NodeJS.ProcessEnv = process.env, home = homedir()): string | null {
  return env.DUET_CODEX_PATH || findIn('codex', agentDirs(env, home));
}

/** Doublet's permission modes as Codex's approval policy and sandbox. Plan mode is also Codex's own plan collaboration
 *  mode (turn/start's collaborationMode), read-only and asking first. */
export function codexPolicy(mode: PermissionMode, cwd: string): { approvalPolicy: string; sandbox: string; sandboxPolicy: Record<string, unknown> } {
  const write = { type: 'workspaceWrite', writableRoots: [cwd], networkAccess: false, excludeTmpdirEnvVar: false, excludeSlashTmp: false };
  switch (mode) {
    case 'bypassPermissions': return { approvalPolicy: 'never', sandbox: 'danger-full-access', sandboxPolicy: { type: 'dangerFullAccess' } };
    case 'plan': return { approvalPolicy: 'untrusted', sandbox: 'read-only', sandboxPolicy: { type: 'readOnly', networkAccess: false } };
    case 'acceptEdits':
    case 'auto': return { approvalPolicy: 'on-request', sandbox: 'workspace-write', sandboxPolicy: write };
    default: return { approvalPolicy: 'untrusted', sandbox: 'workspace-write', sandboxPolicy: write };
  }
}

/** Codex's effort names are model-dependent strings (low to max, and ultra on some); Doublet's map straight across. */
const effortFor = (e: EffortLevel | null) => e;
const isEffort = (e: string): e is EffortLevel => (EFFORT_LEVELS as readonly string[]).includes(e);

type Rpc = { id?: number | string; method?: string; params?: any; result?: any; error?: { code: number; message: string } };
type Item = { type: string; id: string; [k: string]: any };

export type CodexExtras = {
  /** Doublet's servers, served to Codex through the gateway. */
  mcpServers?: () => Record<string, McpSdkServerConfigWithInstance>;
  gateway?: McpGateway;
  /** Doublet's guidance for the lead, as the thread's developer instructions. */
  instructions?: () => string;
};

export class CodexAdapter implements AgentAdapter {
  readonly id = 'codex' as const;
  readonly name = 'Codex';
  readonly caps = CODEX_CAPS;
  private readonly extras: CodexExtras;
  constructor(extras: CodexExtras = {}) {
    this.extras = extras;
  }
  open(opts: SessionOptions, host: SessionHost): CodexSession {
    return new CodexSession(opts, host, this.extras);
  }
  /** Codex keeps a thread's rollout under ~/.codex/sessions/YYYY/MM/DD/, named with its id. */
  async lookup(threadId: string): Promise<{ cwd?: string } | null> {
    const root = join(process.env.CODEX_HOME || join(homedir(), '.codex'), 'sessions');
    const walk = (dir: string, depth: number): boolean => {
      if (!existsSync(dir)) return false;
      for (const e of readdirSync(dir, { withFileTypes: true })) {
        if (e.isDirectory() && depth < 3 && walk(join(dir, e.name), depth + 1)) return true;
        if (e.isFile() && e.name.includes(threadId)) return true;
      }
      return false;
    };
    return walk(root, 0) ? {} : null;
  }
}

export class CodexSession implements AgentSession {
  private proc: ChildProcessWithoutNullStreams | null = null;
  private nextId = 1;
  private calls = new Map<number, { resolve: (r: any) => void; reject: (e: Error) => void; method: string }>();
  private threadId: string | null = null;
  /** The running turn, which a prompt written now steers. */
  private turnId: string | null = null;
  /** Items as they started, by id: a file change's diff is on its item, not its approval request. */
  private items = new Map<string, Item>();
  /** Agent message text so far, by item, for a message that ends without its whole text. */
  private said = new Map<string, string>();
  private tokens: string[] = [];
  private model: string;
  private effort: string | null;
  private mode: PermissionMode;
  private exited: Promise<void> | null = null;
  private stderrTail: string[] = [];

  private readonly opts: SessionOptions;
  private readonly host: SessionHost;
  private readonly extras: CodexExtras;

  constructor(opts: SessionOptions, host: SessionHost, extras: CodexExtras = {}) {
    this.opts = opts;
    this.host = host;
    this.extras = extras;
    this.model = opts.model;
    this.effort = effortFor(opts.effort);
    this.mode = opts.mode;
  }

  preflight(): string | null {
    return codexPath() ? null : "Codex isn't installed for the hub's user: install it and run `codex login`, or choose another lead.";
  }

  async start(): Promise<{ subscription?: string }> {
    const exe = codexPath()!;
    const env = { ...baseEnv() };
    for (const k of ['OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_HOME', 'OPENAI_BASE_URL']) if (process.env[k]) env[k] = process.env[k]!;
    const proc = spawn(exe, ['app-server'], { cwd: this.opts.cwd, env, stdio: ['pipe', 'pipe', 'pipe'] });
    this.proc = proc;
    this.exited = new Promise((r) => proc.once('exit', () => r()));
    proc.stderr.setEncoding('utf8');
    proc.stderr.on('data', (d: string) => {
      for (const line of d.split('\n').filter(Boolean)) {
        this.host.log(`[codex] ${line}`);
        this.stderrTail.push(line);
        if (this.stderrTail.length > 20) this.stderrTail.shift();
      }
    });
    createInterface({ input: proc.stdout }).on('line', (line) => this.receive(line));
    proc.once('exit', (code) => {
      for (const c of this.calls.values()) c.reject(new Error(`codex app-server exited (${code}) during ${c.method}`));
      this.calls.clear();
    });

    await this.call('initialize', { clientInfo: { name: 'doublet', title: 'Doublet', version: '0.1.0' }, capabilities: { experimentalApi: EXPERIMENTAL, requestAttestation: false } });
    this.notify('initialized', {});

    const policy = codexPolicy(this.mode, this.opts.cwd);
    const thread = {
      model: this.model || null, cwd: this.opts.cwd, approvalPolicy: policy.approvalPolicy, sandbox: policy.sandbox,
      config: this.config(), ...(this.extras.instructions ? { developerInstructions: this.extras.instructions() } : {}),
    };
    let r: { thread: { id: string }; model: string; reasoningEffort: string | null };
    try {
      r = this.opts.resume ? await this.call('thread/resume', { threadId: this.opts.sessionId, ...thread }) : await this.call('thread/start', thread);
    } catch (e) {
      this.close();
      throw new Refused(`Codex didn't start a thread: ${String((e as Error).message ?? e)}. Is it signed in (\`codex login status\`)?`);
    }
    this.threadId = r.thread.id;
    this.model = r.model;
    this.effort ??= r.reasoningEffort;
    this.host.event({ type: 'ready', sessionId: r.thread.id });
    return {};
  }

  /** Doublet's servers for this thread, through the gateway (Codex takes MCP servers only as commands or URLs). */
  private config(): Record<string, unknown> {
    const servers = this.extras.mcpServers?.();
    const g = this.extras.gateway;
    if (!servers || !g) return {};
    const mcp: Record<string, unknown> = {};
    for (const [name, like] of Object.entries(servers)) {
      const { token, url } = g.register(() => this.extras.mcpServers!()[name]);
      this.tokens.push(token);
      const timeout = (like as { timeout?: number }).timeout;
      mcp[name] = { url, required: true, ...(timeout ? { tool_timeout_sec: Math.ceil(timeout / 1000) } : {}) };
    }
    return { mcp_servers: mcp };
  }

  async run(): Promise<void> {
    await this.exited;
    const tail = this.stderrTail.at(-1);
    this.host.event({ type: 'closed', ...(this.closing ? {} : { error: `codex app-server ended${tail ? `: ${tail.slice(0, 300)}` : ''}` }) });
  }

  // ---- the wire ----

  private call<T = any>(method: string, params: unknown): Promise<T> {
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.calls.set(id, { resolve, reject, method });
      this.write({ id, method, params });
    });
  }

  private notify(method: string, params: unknown): void {
    this.write({ method, params });
  }

  private write(m: Rpc): void {
    if (!this.proc || this.proc.stdin.destroyed) return;
    this.proc.stdin.write(`${JSON.stringify(m)}\n`);
  }

  private receive(line: string): void {
    let m: Rpc;
    try { m = JSON.parse(line); } catch { return this.host.log(`[codex] not JSON: ${line.slice(0, 200)}`); }
    if (m.id !== undefined && !m.method) {
      const c = this.calls.get(m.id as number);
      if (!c) return;
      this.calls.delete(m.id as number);
      return m.error ? c.reject(new Error(m.error.message)) : c.resolve(m.result);
    }
    if (m.id !== undefined && m.method) return this.request(m.id, m.method, m.params);
    if (m.method) this.notification(m.method, m.params);
  }

  /** Exposed for tests: one line from codex app-server. */
  handle(m: Rpc): void {
    this.receive(JSON.stringify(m));
  }

  // ---- what Codex says ----

  private notification(method: string, p: any): void {
    const ev = this.host.event;
    switch (method) {
      case 'turn/started':
        this.turnId = p.turn.id;
        return ev({ type: 'activity' });
      case 'item/agentMessage/delta':
        this.said.set(p.itemId, (this.said.get(p.itemId) ?? '') + p.delta);
        ev({ type: 'activity' });
        return ev({ type: 'text', delta: p.delta });
      case 'item/started':
        return this.itemStarted(p.item as Item);
      case 'item/completed':
        return this.itemCompleted(p.item as Item);
      case 'turn/completed': {
        const t = p.turn as { id: string; status: string; error: { message: string } | null; durationMs: number | null };
        if (t.id === this.turnId) this.turnId = null;
        if (t.error) this.host.log(`codex turn ${t.id} ${t.status}: ${t.error.message}`);
        ev({
          type: 'turn_end', subtype: t.status === 'completed' ? 'success' : t.status === 'interrupted' ? 'interrupted' : 'error_during_execution',
          isError: t.status === 'failed', durationMs: t.durationMs ?? undefined, numTurns: 1,
        });
        const next = this.afterTurn.shift();
        if (next) void this.deliver(next).catch((e) => this.host.log(`codex didn't take a message: ${e}`));
        return;
      }
      case 'thread/status/changed':
        if (p.status?.type === 'idle') ev({ type: 'idle' });
        return;
      case 'thread/compacted':
        // Older versions say so here; newer ones with a contextCompaction item (itemCompleted). Counted once.
        if (this.compacted) return void (this.compacted = false);
        return ev({ type: 'compacted', preTokens: 0 });
      case 'error':
        if (!p.willRetry) this.host.log(`codex error: ${p.error?.message}`);
        return;
    }
  }

  /** Codex's own subagents (collab agents), by their thread: shown as workers, as Claude's are. */
  private agents = new Set<string>();

  private collab(item: Item): void {
    if (item.type === 'subAgentActivity') {
      if (item.kind === 'started') this.agentStarted(item.agentThreadId, item.agentPath || 'codex agent', '');
      if (item.kind === 'completed' || item.kind === 'interrupted') this.agentEnded(item.agentThreadId, item.kind === 'completed' ? 'done' : 'cancelled', '');
      return;
    }
    if (item.type !== 'collabAgentToolCall') return;
    if (item.tool === 'spawnAgent') for (const id of item.receiverThreadIds ?? []) this.agentStarted(id, item.model || 'codex agent', item.prompt ?? '');
    for (const [id, st] of Object.entries((item.agentsStates ?? {}) as Record<string, { status: string; message: string | null }>)) {
      const end = st.status === 'completed' ? 'done' : st.status === 'errored' || st.status === 'notFound' ? 'failed' : st.status === 'interrupted' || st.status === 'shutdown' ? 'cancelled' : null;
      if (end) this.agentEnded(id, end, st.message ?? '');
    }
  }

  private agentStarted(id: string, kind: string, prompt: string): void {
    if (!id || this.agents.has(id)) return;
    this.agents.add(id);
    const label = prompt.split('\n').find((l) => l.trim())?.trim().slice(0, 80);
    this.host.subagents?.start(id, kind, prompt, label ? { label } : {});
  }

  private agentEnded(id: string, state: 'done' | 'failed' | 'cancelled', report: string): void {
    if (!this.agents.delete(id)) return;
    this.host.subagents?.end(id, state, report);
  }

  private itemStarted(item: Item): void {
    this.items.set(item.id, item);
    this.collab(item);
    const use = toolUse(item);
    if (!use) return;
    this.host.event({ type: 'activity' });
    this.host.event({ type: 'message', text: '', toolUses: [use] });
  }

  private itemCompleted(item: Item): void {
    this.items.delete(item.id);
    this.collab(item);
    if (item.type === 'agentMessage') {
      const text = item.text || this.said.get(item.id) || '';
      this.said.delete(item.id);
      if (text) {
        this.host.event({ type: 'activity' });
        this.host.event({ type: 'message', text, toolUses: [] });
      }
      // Questions it asks you (in plan mode): the question card. Codex doesn't wait for them; your answers go to it as
      // your next message.
      if (Array.isArray(item.questions) && item.questions.length) this.questions(item.id, item.questions);
      return;
    }
    // Its plan, in plan mode: the plan's approval card, as Claude's ExitPlanMode.
    if (item.type === 'plan' && item.text) return this.planReady(item.id, item.text);
    if (item.type === 'contextCompaction') {
      this.compacted = true;
      return this.host.event({ type: 'compacted', preTokens: 0 });
    }
    const out = toolOutput(item);
    if (!out) return;
    this.host.event({ type: 'activity' });
    this.host.event({ type: 'tool_end', toolUseId: item.id, ...out });
    // Clears an edit the hub kept for this call: Codex ran it as it was, so there's no edit to tell it about.
    this.host.afterTool(item.id);
  }

  /** A request from Codex: an approval becomes a card; anything else Doublet can't answer is declined. Every request
   *  gets an answer, or the turn waits for ever. */
  private request(id: number | string, method: string, p: any): void {
    const answer = (result: unknown) => this.write({ id, result });
    switch (method) {
      case 'item/commandExecution/requestApproval':
        return this.approve(id, 'Bash', { command: p.command ?? '', ...(p.cwd ? { cwd: p.cwd } : {}) }, p.itemId, p.reason, p.availableDecisions);
      case 'item/fileChange/requestApproval': {
        const item = this.items.get(p.itemId);
        return this.approve(id, 'Edit', { changes: (item?.changes ?? []).map((c: { path: string; kind: unknown; diff: string }) => ({ path: c.path, kind: c.kind, diff: c.diff })) }, p.itemId, p.reason, p.availableDecisions);
      }
      case 'mcpServer/elicitation/request':
        return answer({ action: 'decline', content: null, _meta: null });
      case 'item/tool/requestUserInput': {
        // Questions it waits on: the question card, answered by option label (or your own words for "other").
        const qs = (p.questions ?? []) as { id: string; header: string; question: string; options: { label: string; description: string }[] | null }[];
        return this.ask(qs.map((q) => ({ question: q.question, header: q.header, options: (q.options ?? []).map((o) => ({ label: o.label, description: o.description })), multiSelect: false })), p.itemId, (answers) => {
          answer({ answers: Object.fromEntries(qs.map((q) => [q.id, { answers: answers?.[q.question] ? [answers[q.question]] : [] }])) });
        });
      }
      default:
        this.host.log(`codex asked ${method}, which Doublet doesn't handle: declined`);
        return this.write({ id, error: { code: -32601, message: `Doublet doesn't handle ${method}` } });
    }
  }

  /** A call that needs an OK: the approval card. Codex can't run an edited call, so an edit refuses this one and tells
   *  Codex what you want run instead. Its request lists the decisions it takes (not always decline). */
  private approve(id: number | string, tool: string, input: Record<string, unknown>, itemId: string, reason?: string | null, decisions?: unknown[]): void {
    let done = false;
    const can = (d: string) => !decisions || decisions.includes(d);
    const refuse = can('decline') ? 'decline' : 'cancel';
    this.host.event({
      type: 'approval', tool, input, toolUseId: itemId, ...(reason ? { description: reason } : {}),
      respond: (a) => {
        if (done) return;
        done = true;
        if (a.allow) {
          const command = a.input.command;
          if (tool !== 'Bash' || typeof command !== 'string' || command === input.command) return this.write({ id, result: { decision: 'accept' } });
          this.write({ id, result: { decision: refuse } });
          return this.tell(`[duet] The user edited that command before approving it. Run this instead: ${command}`);
        }
        this.write({ id, result: { decision: a.interrupt ? 'cancel' : refuse } });
        if (!a.interrupt && a.message && a.message !== REJECTED) this.tell(`[duet] The user rejected that call: ${a.message}`);
      },
      onWithdrawn: () => {},
    });
  }

  /** Questions for you: the question card (as Claude's AskUserQuestion). `then` gets your answers, question → choice,
   *  or null if you didn't answer. */
  private ask(questions: { question: string; header?: string; options: { label: string; description?: string }[]; multiSelect: boolean }[], itemId: string, then: (answers: Record<string, string> | null) => void): void {
    let done = false;
    this.host.event({
      type: 'approval', tool: 'AskUserQuestion', input: { questions }, toolUseId: itemId,
      respond: (a) => {
        if (done) return;
        done = true;
        then(a.allow ? ((a.input.answers ?? {}) as Record<string, string>) : null);
      },
      onWithdrawn: () => {},
    });
  }

  /** Questions in a message (plan mode), which Codex doesn't wait on: your answers go to it as your next message. */
  private questions(itemId: string, qs: { title: string; options?: string[] }[]): void {
    this.ask(qs.map((q) => ({ question: q.title, options: (q.options ?? []).map((label) => ({ label })), multiSelect: false })), itemId, (answers) => {
      if (!answers) return this.tell("[duet] The user didn't answer your question; go on with your best judgment, and say what you assumed.");
      this.tell(`[duet] The user's answers:\n${qs.map((q) => `- ${q.title} ${answers[q.title] ?? '(no answer)'}`).join('\n')}`);
    });
  }

  /** Its plan, in plan mode: the plan's approval card. Approving leaves plan mode and starts the work (an edited plan
   *  goes with it); rejecting keeps it planning, with your note. */
  private planReady(itemId: string, plan: string): void {
    let done = false;
    this.host.event({
      type: 'approval', tool: 'ExitPlanMode', input: { plan }, toolUseId: itemId,
      respond: (a) => {
        if (done) return;
        done = true;
        if (!a.allow) return this.tell(a.message);
        const edited = typeof a.input.plan === 'string' && a.input.plan !== plan ? a.input.plan : null;
        this.mode = 'default';
        this.host.event({ type: 'mode', mode: 'default' });
        // A turn of its own, out of plan mode: steering the planning turn would keep it read-only.
        this.tell(edited ? `[duet] The user approved your plan, with their edits. Implement this plan now:\n\n${edited}` : '[duet] The user approved your plan. Implement it now.', true);
      },
      onWithdrawn: () => {},
    });
  }

  /** Something the hub tells Codex itself: into the running turn, or as a turn of its own (`own`: always its own turn,
   *  after the running one ends, so it runs with the mode as it is now). */
  private tell(text: string, own = false): void {
    const input = [{ type: 'text', text, text_elements: [] }];
    if (own && this.turnId) return void this.afterTurn.push(input);
    void this.deliver(input).catch((e) => this.host.log(`codex didn't take a message: ${e}`));
  }

  /** Turns to start once the running one ends. */
  private afterTurn: unknown[][] = [];

  // ---- what the hub asks ----

  send(text: string, images: Image[] = []): void {
    const extra = this.host.beforePrompt(text);
    const input = [
      ...images.map((i) => ({ type: 'image', url: `data:${i.type};base64,${i.data}` })),
      { type: 'text', text, text_elements: [] },
      ...(extra ? [{ type: 'text', text: extra, text_elements: [] }] : []),
    ];
    void this.deliver(input).catch((e) => this.host.log(`codex didn't take a prompt: ${e}`));
  }

  /** Steers the running turn; with none (or it just ended), starts the next. */
  private async deliver(input: unknown[]): Promise<void> {
    if (this.turnId) {
      try {
        await this.call('turn/steer', { threadId: this.threadId, input, expectedTurnId: this.turnId });
        return;
      } catch (e) {
        this.host.log(`codex turn ${this.turnId} didn't take the steer (${(e as Error).message}); starting a turn`);
      }
    }
    const policy = codexPolicy(this.mode, this.opts.cwd);
    const settings = { model: this.model, reasoning_effort: this.effort ?? null, developer_instructions: null };
    const r = await this.call('turn/start', {
      threadId: this.threadId, input, model: this.model, ...(this.effort ? { effort: this.effort } : {}),
      approvalPolicy: policy.approvalPolicy, sandboxPolicy: policy.sandboxPolicy,
      ...(EXPERIMENTAL ? { collaborationMode: { mode: this.mode === 'plan' ? 'plan' : 'default', settings } } : {}),
    });
    this.turnId ??= r.turn?.id ?? null;
  }

  /** Summarizes the thread to free its context (`thread/compacted` says when it's done). */
  async compact(): Promise<void> {
    await this.call('thread/compact/start', { threadId: this.threadId });
  }

  async interrupt(): Promise<void> {
    if (!this.turnId) return;
    await this.call('turn/interrupt', { threadId: this.threadId, turnId: this.turnId });
  }

  async models(): Promise<LeadModel[]> {
    const r = await this.call<{ data: { id: string; model: string; displayName: string; hidden: boolean; supportedReasoningEfforts: { reasoningEffort: string }[] }[] }>('model/list', {});
    return r.data.filter((m) => !m.hidden).map((m) => ({ value: m.model, displayName: m.displayName, effortLevels: m.supportedReasoningEfforts.map((e) => e.reasoningEffort).filter(isEffort), resolved: m.id }));
  }

  /** From the next turn (Codex takes model, effort and policy with each turn). */
  async setModel(model: string): Promise<void> {
    this.model = model;
  }

  async setMode(mode: PermissionMode): Promise<void> {
    this.mode = mode;
  }

  async setEffort(level: EffortLevel | null): Promise<void> {
    this.effort = effortFor(level);
  }

  endTurn(): void {}

  release(): void {
    if (this.agents.size) this.host.subagents?.stopped(true);
    this.agents.clear();
    for (const t of this.tokens.splice(0)) this.extras.gateway?.unregister(t);
  }

  private closing = false;
  /** A contextCompaction item said it compacted: a thread/compacted after it is the same one. */
  private compacted = false;
  close(): void {
    this.closing = true;
    this.proc?.stdin.end();
    this.proc?.kill('SIGTERM');
  }
}

/** A Codex item as the tool call Doublet shows: Bash for commands, Edit for file changes, mcp__server__tool for MCP. */
function toolUse(item: Item): ToolUse | null {
  switch (item.type) {
    case 'commandExecution': return { id: item.id, name: 'Bash', input: { command: item.command, cwd: item.cwd } };
    case 'fileChange': return { id: item.id, name: 'Edit', input: { changes: item.changes } };
    case 'mcpToolCall': return { id: item.id, name: `mcp__${item.server}__${item.tool}`, input: item.arguments };
    case 'webSearch': return { id: item.id, name: 'WebSearch', input: { query: item.query } };
    default: return null;
  }
}

function toolOutput(item: Item): { isError: boolean; output: string } | null {
  switch (item.type) {
    case 'commandExecution':
      return { isError: item.status !== 'completed' || (item.exitCode ?? 0) !== 0, output: item.aggregatedOutput ?? '' };
    case 'fileChange':
      return { isError: item.status === 'failed' || item.status === 'declined', output: (item.changes ?? []).map((c: { path: string; diff: string }) => `${c.path}\n${c.diff}`).join('\n') };
    case 'mcpToolCall': {
      const text = (item.result?.content ?? []).map((c: { text?: string }) => c.text ?? JSON.stringify(c)).join('\n');
      return { isError: !!item.error || item.status === 'failed', output: item.error?.message ?? text };
    }
    case 'webSearch':
      return { isError: false, output: '' };
    default:
      return null;
  }
}
