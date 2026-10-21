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
import { Refused, type AgentAdapter, type AgentCaps, type AgentSession, type Image, type SessionHost, type SessionOptions } from './adapter.ts';

/** The app-server version this adapter was written and tested against. */
export const TESTED_CODEX = '0.156.1';

export const CODEX_CAPS: AgentCaps = {
  steerMidTurn: true, subagents: false, resume: true, fork: true, liveModelSwitch: true, effort: true,
  approvals: 'callback', promptContext: false, cost: false,
};

/** The `codex` to run: DUET_CODEX_PATH, else the first on PATH or where its installers put it. */
export function codexPath(env: NodeJS.ProcessEnv = process.env, home = homedir()): string | null {
  return env.DUET_CODEX_PATH || findIn('codex', agentDirs(env, home));
}

/** Doublet's permission modes as Codex's approval policy and sandbox. Codex has no plan mode of its own: plan is
 *  read-only, asking first. */
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

    await this.call('initialize', { clientInfo: { name: 'doublet', title: 'Doublet', version: '0.1.0' }, capabilities: { experimentalApi: false, requestAttestation: false } });
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
        return ev({
          type: 'turn_end', subtype: t.status === 'completed' ? 'success' : t.status === 'interrupted' ? 'interrupted' : 'error_during_execution',
          isError: t.status === 'failed', durationMs: t.durationMs ?? undefined, numTurns: 1,
        });
      }
      case 'thread/status/changed':
        if (p.status?.type === 'idle') ev({ type: 'idle' });
        return;
      case 'thread/compacted':
        return ev({ type: 'compacted', preTokens: 0 });
      case 'error':
        if (!p.willRetry) this.host.log(`codex error: ${p.error?.message}`);
        return;
    }
  }

  private itemStarted(item: Item): void {
    this.items.set(item.id, item);
    const use = toolUse(item);
    if (!use) return;
    this.host.event({ type: 'activity' });
    this.host.event({ type: 'message', text: '', toolUses: [use] });
  }

  private itemCompleted(item: Item): void {
    this.items.delete(item.id);
    if (item.type === 'agentMessage') {
      const text = item.text || this.said.get(item.id) || '';
      this.said.delete(item.id);
      if (!text) return;
      this.host.event({ type: 'activity' });
      return this.host.event({ type: 'message', text, toolUses: [] });
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
        return this.approve(id, 'Bash', { command: p.command ?? '', ...(p.cwd ? { cwd: p.cwd } : {}) }, p.itemId, p.reason);
      case 'item/fileChange/requestApproval': {
        const item = this.items.get(p.itemId);
        return this.approve(id, 'Edit', { changes: (item?.changes ?? []).map((c: { path: string; kind: unknown; diff: string }) => ({ path: c.path, kind: c.kind, diff: c.diff })) }, p.itemId, p.reason);
      }
      case 'mcpServer/elicitation/request':
        return answer({ action: 'decline', content: null, _meta: null });
      case 'item/tool/requestUserInput':
        return answer({ answers: {} });
      default:
        this.host.log(`codex asked ${method}, which Doublet doesn't handle: declined`);
        return this.write({ id, error: { code: -32601, message: `Doublet doesn't handle ${method}` } });
    }
  }

  private approve(id: number | string, tool: string, input: Record<string, unknown>, itemId: string, reason?: string | null): void {
    let done = false;
    this.host.event({
      type: 'approval', tool, input, toolUseId: itemId, ...(reason ? { description: reason } : {}),
      // Codex can't run an edited call: an edit is taken as an OK of the call as it was (the card says what ran).
      respond: (a) => {
        if (done) return;
        done = true;
        this.write({ id, result: { decision: a.allow ? 'accept' : a.interrupt ? 'cancel' : 'decline' } });
      },
      onWithdrawn: () => {},
    });
  }

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
    const r = await this.call('turn/start', {
      threadId: this.threadId, input, model: this.model, ...(this.effort ? { effort: this.effort } : {}),
      approvalPolicy: policy.approvalPolicy, sandboxPolicy: policy.sandboxPolicy,
    });
    this.turnId ??= r.turn?.id ?? null;
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
    for (const t of this.tokens.splice(0)) this.extras.gateway?.unregister(t);
  }

  private closing = false;
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
