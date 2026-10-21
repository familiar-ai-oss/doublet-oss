// Asides: a side chat's answer or a note's, from the lead's own agent. Read-only (read and search files, search the
// web, open documentation pages, draw a diagram with Doublet's tool), in a copy of the conversation where the agent
// can make one, so it knows what's been said without the conversation seeing the question. A follow-up continues the
// aside's own session. sidechat.ts decides who answers and what to say; this runs one answer with one agent.
//
// Claude Code forks the lead's session (the Agent SDK); Codex forks its thread (thread/fork); an ACP agent can't fork, so
// it starts a session in its read-only mode with the conversation so far from the hub's log.
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { forkSession, getSessionMessages, query, type McpSdkServerConfigWithInstance, type SDKMessage, type SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';
import { claudeExecutable } from '../claude.ts';
import { baseEnv } from '../lead.ts';
import type { Image } from './adapter.ts';
import { codexPath } from './codex.ts';
import type { AcpSpec } from './acp.ts';
import { McpGateway } from './mcp-gateway.ts';

/** How much of the conversation the copy has seen: all of it, up to the turn in progress, or nothing yet. */
export type Forked = 'whole' | 'before_turn' | 'none';

/** The conversation a new aside copies: the lead's session, whether the agent has its transcript yet, whether a turn
 *  is in progress, its folder, and (for an agent that can't copy it) the conversation so far as text. */
export type ForkSource = { sessionId?: string; transcribed: boolean; busy: boolean; cwd: string; transcript?: () => string };

export type AsideEvent =
  /** The aside's own session: a follow-up continues it. */
  | { type: 'session'; id: string }
  | { type: 'text'; delta: string }
  /** A whole message: its words, and the tool it calls next, if any. */
  | { type: 'message'; id?: string; text: string; tool?: { name: string; input: unknown } }
  /** It stopped short (out of steps, refused): why, for the user. */
  | { type: 'error'; message: string };

export type AsideRequest = {
  prompt: string;
  image?: Image;
  cwd: string;
  model: string;
  /** Continue this aside's session; else start from `from` (a copy of the conversation), or afresh. */
  resume?: string;
  from?: string;
  /** Doublet's diagram tool, for a note's answer. */
  diagrams?: McpSdkServerConfigWithInstance;
  maxTurns: number;
  signal: AbortSignal;
};

/** One agent answering asides. */
export interface Aside {
  /** "Claude", "Codex", "Cursor": who the user is told answered. */
  name: string;
  /** Its models for a quick answer and for one that needs judgment. */
  quick: string;
  judgment: string;
  /** A copy of the conversation to start a new aside from. */
  fork(src: ForkSource): Promise<{ from?: string; forked: Forked }>;
  run(req: AsideRequest, on: (e: AsideEvent) => void): Promise<void>;
}

// ---- Claude Code ----

const SIDE_TOOLS = ['Read', 'Glob', 'Grep', 'WebSearch', 'WebFetch'];

export type ClaudeAsideDeps = { query: typeof query; forkSession: typeof forkSession; getSessionMessages: typeof getSessionMessages };

type Message = { type: string; uuid: string; message: unknown; parent_tool_use_id: string | null };

/** The last of Claude's replies that ends a turn (text, no tool call), and whether it's the transcript's last message. */
export function lastReply(messages: Message[]): { uuid: string; last: boolean } | null {
  const main = messages.filter((m) => m.parent_tool_use_id === null);
  for (let i = main.length - 1; i >= 0; i--) {
    const m = main[i];
    if (m.type !== 'assistant') continue;
    const content = (m.message as { content?: unknown })?.content;
    const blocks = Array.isArray(content) ? (content as { type?: string; text?: string }[]) : [];
    if (blocks.some((b) => b.type === 'tool_use')) continue;
    if (!blocks.some((b) => b.type === 'text' && b.text?.trim())) continue;
    return { uuid: m.uuid, last: i === main.length - 1 };
  }
  return null;
}

/** Claude Code: a fork of the lead's session, Haiku for a quick answer and Sonnet for one that needs judgment. */
export class ClaudeAside implements Aside {
  readonly name = 'Claude';
  readonly quick = 'haiku';
  readonly judgment = 'sonnet';
  private readonly deps: ClaudeAsideDeps;
  private readonly env: () => Record<string, string>;
  private readonly allowed: string[];
  private readonly log: (m: string) => void;

  /** `allowed`: what runs without asking (an aside can't ask, so anything else is refused). */
  constructor(o: { env: () => Record<string, string>; allowed: string[]; log: (m: string) => void; deps?: Partial<ClaudeAsideDeps> }) {
    this.env = o.env;
    this.allowed = o.allowed;
    this.log = o.log;
    this.deps = { query, forkSession, getSessionMessages, ...o.deps };
  }

  // A copy of the conversation, up to Claude's last reply: all of it between turns, and everything before the turn in
  // progress during one (a copy can't start inside a turn). None when there's no conversation yet.
  async fork(src: ForkSource): Promise<{ from?: string; forked: Forked }> {
    if (!src.sessionId || !src.transcribed) return { forked: 'none' };
    try {
      const messages = await this.deps.getSessionMessages(src.sessionId, { dir: src.cwd });
      const at = lastReply(messages as Message[]);
      if (!at) return { forked: 'none' };
      const { sessionId } = await this.deps.forkSession(src.sessionId, { dir: src.cwd, upToMessageId: at.uuid });
      return { from: sessionId, forked: at.last && !src.busy ? 'whole' : 'before_turn' };
    } catch (e) {
      this.log(`side chat: couldn't copy the conversation: ${e}`);
      return { forked: 'none' };
    }
  }

  async run(req: AsideRequest, on: (e: AsideEvent) => void): Promise<void> {
    const resume = req.resume ?? req.from;
    const abort = new AbortController();
    req.signal.addEventListener('abort', () => abort.abort());
    const q = this.deps.query({
      prompt: once(userMessage(req.prompt, req.image)),
      options: {
        ...claudeExecutable(),
        cwd: req.cwd, env: this.env(), model: req.model, effort: 'low',
        tools: SIDE_TOOLS, allowedTools: req.diagrams ? [...this.allowed, 'mcp__duet__diagram'] : this.allowed, permissionMode: 'dontAsk',
        ...(req.diagrams ? { mcpServers: { duet: req.diagrams } } : {}),
        settingSources: [], settings: { crossSessionInbound: 'refuse' },
        includePartialMessages: true, maxTurns: req.maxTurns, abortController: abort,
        ...(resume ? { resume } : {}),
      },
    });
    for await (const m of q as AsyncIterable<SDKMessage>) {
      if (m.type === 'system' && m.subtype === 'init') {
        on({ type: 'session', id: m.session_id });
      } else if (m.type === 'stream_event' && m.parent_tool_use_id === null) {
        const ev = m.event;
        if (ev.type === 'content_block_delta' && ev.delta.type === 'text_delta') on({ type: 'text', delta: ev.delta.text });
      } else if (m.type === 'assistant' && m.parent_tool_use_id === null) {
        const text = m.message.content.flatMap((b) => (b.type === 'text' ? [b.text] : [])).join('');
        const call = m.message.content.find((b) => b.type === 'tool_use');
        on({ type: 'message', id: m.message.id, text, ...(call && call.type === 'tool_use' ? { tool: { name: call.name, input: call.input } } : {}) });
      } else if (m.type === 'result' && m.subtype !== 'success') {
        on({ type: 'error', message: m.subtype === 'error_max_turns' ? `Stopped after ${req.maxTurns} steps; ask it to go on.` : `Claude couldn't answer (${m.subtype}).` });
      }
    }
  }
}

function userMessage(text: string, image: Image | undefined): SDKUserMessage {
  const content = image
    ? [{ type: 'image' as const, source: { type: 'base64' as const, media_type: image.type, data: image.data } }, { type: 'text' as const, text: text || 'About this picture.' }]
    : text;
  return { type: 'user', message: { role: 'user', content }, parent_tool_use_id: null, session_id: '', origin: { kind: 'human' } } as SDKUserMessage;
}

async function* once<T>(item: T): AsyncIterable<T> {
  yield item;
}

// ---- JSON-RPC over stdio, for one aside's process ----

type Rpc = { id?: number | string; method?: string; params?: any; result?: any; error?: { message: string } };

/** A short-lived agent process for one answer: calls, notifications, and an answer to every request it makes. */
class Wire {
  private next = 1;
  private calls = new Map<number, { resolve: (r: any) => void; reject: (e: Error) => void }>();
  private readonly proc;
  private readonly json: boolean;
  onNotify: (method: string, params: any) => void = () => {};
  onRequest: (id: number | string, method: string, params: any) => unknown = () => ({ error: 'not handled' });

  constructor(file: string, args: string[], cwd: string, env: Record<string, string>, jsonrpc: boolean, log: (m: string) => void) {
    this.json = jsonrpc;
    this.proc = spawn(file, args, { cwd, env, stdio: ['pipe', 'pipe', 'pipe'] });
    this.proc.stderr.on('data', (d: Buffer) => log(`[aside] ${String(d).trim().slice(0, 300)}`));
    createInterface({ input: this.proc.stdout }).on('line', (line) => {
      let m: Rpc;
      try { m = JSON.parse(line); } catch { return; }
      if (m.id !== undefined && !m.method) {
        const c = this.calls.get(m.id as number);
        this.calls.delete(m.id as number);
        return m.error ? c?.reject(new Error(m.error.message)) : c?.resolve(m.result);
      }
      if (m.id !== undefined && m.method) {
        const r = this.onRequest(m.id, m.method, m.params) as { error?: string } | undefined;
        return this.write(r && 'error' in r ? { id: m.id, error: { code: -32601, message: String(r.error) } } as never : { id: m.id, result: r });
      }
      if (m.method) this.onNotify(m.method, m.params);
    });
    this.proc.once('exit', (code) => {
      for (const c of this.calls.values()) c.reject(new Error(`the agent exited (${code})`));
      this.calls.clear();
    });
  }

  call<T = any>(method: string, params: unknown): Promise<T> {
    const id = this.next++;
    return new Promise<T>((resolve, reject) => {
      this.calls.set(id, { resolve, reject });
      this.write({ id, method, params });
    });
  }

  notify(method: string, params: unknown): void {
    this.write({ method, params });
  }

  private write(m: Rpc): void {
    if (!this.proc.stdin.destroyed) this.proc.stdin.write(`${JSON.stringify(this.json ? { jsonrpc: '2.0', ...m } : m)}\n`);
  }

  close(): void {
    this.proc.stdin.end();
    this.proc.kill('SIGTERM');
  }
}

/** Doublet's diagram tool for one answer, through the gateway: its URL, and how to stop serving it. */
function served(gateway: McpGateway | undefined, diagrams: McpSdkServerConfigWithInstance | undefined): { url?: string; done: () => void } {
  if (!gateway || !diagrams) return { done: () => {} };
  const { token, url } = gateway.register(() => diagrams);
  return { url, done: () => gateway.unregister(token) };
}

// ---- Codex ----

/** Codex: a fork of the lead's thread (thread/fork), read-only and never asking, at low effort for a quick answer. */
export class CodexAside implements Aside {
  readonly name = 'Codex';
  readonly quick: string;
  readonly judgment: string;
  private readonly gateway?: McpGateway;
  private readonly log: (m: string) => void;

  constructor(o: { model: () => string; gateway?: McpGateway; log: (m: string) => void }) {
    this.quick = o.model();
    this.judgment = o.model();
    this.gateway = o.gateway;
    this.log = o.log;
  }

  /** Codex copies the whole thread when the aside starts, so there's nothing to do here but say what it will see. */
  async fork(src: ForkSource): Promise<{ from?: string; forked: Forked }> {
    if (!src.sessionId || !src.transcribed) return { forked: 'none' };
    return { from: src.sessionId, forked: src.busy ? 'before_turn' : 'whole' };
  }

  async run(req: AsideRequest, on: (e: AsideEvent) => void): Promise<void> {
    const exe = codexPath();
    if (!exe) throw new Error("Codex isn't installed for the hub's user");
    const env = { ...baseEnv() };
    for (const k of ['OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_HOME']) if (process.env[k]) env[k] = process.env[k]!;
    const wire = new Wire(exe, ['app-server'], req.cwd, env, false, this.log);
    const tool = served(this.gateway, req.diagrams);
    const stop = () => wire.close();
    req.signal.addEventListener('abort', stop);
    try {
      await wire.call('initialize', { clientInfo: { name: 'doublet', title: 'Doublet', version: '0.1.0' }, capabilities: { experimentalApi: true, requestAttestation: false } });
      wire.notify('initialized', {});
      const thread = {
        model: req.model, cwd: req.cwd, approvalPolicy: 'never', sandbox: 'read-only',
        config: tool.url ? { mcp_servers: { duet: { url: tool.url } } } : {},
      };
      const r = req.resume
        ? await wire.call('thread/resume', { threadId: req.resume, ...thread })
        : req.from ? await wire.call('thread/fork', { threadId: req.from, ...thread }) : await wire.call('thread/start', thread);
      on({ type: 'session', id: r.thread.id });
      let steps = 0;
      const finished = new Promise<void>((resolve) => {
        wire.onNotify = (method, p) => {
          if (method === 'item/agentMessage/delta') on({ type: 'text', delta: p.delta });
          else if (method === 'item/completed' && p.item.type === 'agentMessage' && p.item.text) on({ type: 'message', id: p.item.id, text: p.item.text });
          else if (method === 'item/started' && ['commandExecution', 'mcpToolCall', 'webSearch'].includes(p.item.type)) {
            if (++steps > req.maxTurns) {
              on({ type: 'error', message: `Stopped after ${req.maxTurns} steps; ask it to go on.` });
              void wire.call('turn/interrupt', { threadId: r.thread.id, turnId: p.turnId }).catch(() => {});
            }
            const name = p.item.type === 'mcpToolCall' ? `mcp__${p.item.server}__${p.item.tool}` : p.item.type === 'webSearch' ? 'WebSearch' : 'Bash';
            on({ type: 'message', text: '', tool: { name, input: p.item.arguments ?? { command: p.item.command, query: p.item.query } } });
          } else if (method === 'turn/completed') {
            if (p.turn.status === 'failed') on({ type: 'error', message: `Codex couldn't answer: ${p.turn.error?.message ?? 'it failed'}` });
            resolve();
          }
        };
        wire.onRequest = () => ({ error: 'an aside asks for nothing' });
      });
      const input = [
        ...(req.image ? [{ type: 'image', url: `data:${req.image.type};base64,${req.image.data}` }] : []),
        { type: 'text', text: req.prompt || 'About this picture.', text_elements: [] },
      ];
      await wire.call('turn/start', { threadId: r.thread.id, input, model: req.model, effort: 'low', approvalPolicy: 'never', sandboxPolicy: { type: 'readOnly', networkAccess: false }, collaborationMode: { mode: 'default', settings: { model: req.model, reasoning_effort: 'low', developer_instructions: null } } });
      await finished;
    } finally {
      req.signal.removeEventListener('abort', stop);
      tool.done();
      wire.close();
    }
  }
}

// ---- ACP (Cursor) ----

/** An ACP agent: it can't copy a session, so a new aside starts in its read-only mode with the conversation so far, as
 *  the hub's log has it. A follow-up loads the aside's own session. */
export class AcpAside implements Aside {
  readonly name: string;
  readonly quick: string;
  readonly judgment: string;
  private readonly spec: AcpSpec;
  private readonly readOnlyMode: string;
  private readonly gateway?: McpGateway;
  private readonly log: (m: string) => void;
  /** The conversation so far, for new asides: their first prompt starts with it. */
  private seen = new Map<string, string>();

  constructor(spec: AcpSpec, o: { model: () => string; readOnlyMode: string; gateway?: McpGateway; log: (m: string) => void }) {
    this.spec = spec;
    this.name = spec.name;
    this.quick = o.model();
    this.judgment = o.model();
    this.readOnlyMode = o.readOnlyMode;
    this.gateway = o.gateway;
    this.log = o.log;
  }

  async fork(src: ForkSource): Promise<{ from?: string; forked: Forked }> {
    const text = src.sessionId ? src.transcript?.() ?? '' : '';
    if (!text.trim()) return { forked: 'none' };
    const key = `t-${this.seen.size + 1}`;
    this.seen.set(key, text);
    return { from: key, forked: src.busy ? 'before_turn' : 'whole' };
  }

  async run(req: AsideRequest, on: (e: AsideEvent) => void): Promise<void> {
    const exe = this.spec.find();
    if (!exe) throw new Error(`${this.spec.name} isn't installed for the hub's user`);
    const env: Record<string, string> = { ...baseEnv(), NO_COLOR: '1' };
    for (const k of this.spec.env ?? []) if (process.env[k]) env[k] = process.env[k]!;
    const wire = new Wire(exe, this.spec.args, req.cwd, env, true, this.log);
    const tool = served(this.gateway, req.diagrams);
    let sessionId = '';
    const stop = () => {
      if (sessionId) wire.notify('session/cancel', { sessionId });
      setTimeout(() => wire.close(), 500).unref();
    };
    req.signal.addEventListener('abort', stop);
    let loading = false;
    let text = '';
    let steps = 0;
    try {
      const init = await wire.call('initialize', { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false } });
      const mcpServers = tool.url ? [{ type: 'http', name: 'duet', url: tool.url, headers: [] }] : [];
      wire.onNotify = (method, p) => {
        if (method !== 'session/update' || loading) return;
        const u = p.update;
        if (u.sessionUpdate === 'agent_message_chunk' && u.content?.type === 'text') {
          text += u.content.text;
          on({ type: 'text', delta: u.content.text });
        } else if (u.sessionUpdate === 'tool_call') {
          if (text) on({ type: 'message', text });
          text = '';
          if (++steps > req.maxTurns) {
            on({ type: 'error', message: `Stopped after ${req.maxTurns} steps; ask it to go on.` });
            wire.notify('session/cancel', { sessionId });
          }
          on({ type: 'message', text: '', tool: { name: u.title || u.kind || 'tool', input: u.rawInput ?? {} } });
        }
      };
      // Read-only kinds run, and Doublet's diagram tool; nothing else (an aside can't ask).
      wire.onRequest = (_id, method, p) => {
        if (method !== 'session/request_permission') return { error: 'an aside asks for nothing' };
        const ok = ['read', 'search', 'think', 'fetch'].includes(p.toolCall?.kind) || /\bduet\b/.test(p.toolCall?.title ?? '');
        const o = (p.options ?? []).find((x: { kind: string }) => x.kind === (ok ? 'allow_once' : 'reject_once'));
        return { outcome: o ? { outcome: 'selected', optionId: o.optionId } : { outcome: 'cancelled' } };
      };
      if (req.resume && init.agentCapabilities?.loadSession) {
        loading = true;
        await wire.call('session/load', { sessionId: req.resume, cwd: req.cwd, mcpServers });
        loading = false;
        sessionId = req.resume;
      } else {
        sessionId = (await wire.call('session/new', { cwd: req.cwd, mcpServers })).sessionId;
      }
      on({ type: 'session', id: sessionId });
      await wire.call('session/set_mode', { sessionId, modeId: this.readOnlyMode }).catch((e) => this.log(`aside kept its mode: ${e}`));
      const models = req.model ? [req.model] : [];
      for (const m of models) await wire.call('session/set_model', { sessionId, modelId: m }).catch(() => {});
      const seen = req.from ? this.seen.get(req.from) : undefined;
      if (req.from) this.seen.delete(req.from);
      const prompt = [
        ...(seen ? [{ type: 'text', text: `[duet] Our conversation so far, for context (you are answering beside it, read-only):\n\n${seen}` }] : []),
        ...(req.image ? [{ type: 'image', mimeType: req.image.type, data: req.image.data }] : []),
        { type: 'text', text: req.prompt || 'About this picture.' },
      ];
      const r = await wire.call<{ stopReason: string }>('session/prompt', { sessionId, prompt });
      if (text) on({ type: 'message', text });
      if (r.stopReason !== 'end_turn' && r.stopReason !== 'cancelled') on({ type: 'error', message: `${this.spec.name} couldn't answer (${r.stopReason}).` });
    } finally {
      req.signal.removeEventListener('abort', stop);
      tool.done();
      wire.close();
    }
  }
}
