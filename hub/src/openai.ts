// Workers on OpenAI-compatible endpoints (vLLM, Ollama's /v1, LM Studio, llama.cpp, hosted APIs). A worker is Claude
// Code, which speaks Anthropic's Messages API; the worker proxy (proxy.ts) hands its requests here, and they go on as
// OpenAI chat completions with tool calls, the answer (streamed or whole) coming back in Messages form.
//
// What carries over: the system prompt, text, images, tool definitions, tool calls and their results, max_tokens,
// temperature, top_p, stop sequences and tool_choice. What doesn't: thinking blocks (a server's reasoning output is
// dropped, since Claude Code would send it back needing a signature), prompt caching, and Anthropic's server tools.
import type http from 'node:http';
import { randomUUID } from 'node:crypto';
import { overflowAsPromptTooLong } from './context.ts';
import { authHeaders, errorMessage } from './endpoints.ts';
import type { RequestStats, Route } from './proxy.ts';

type Obj = Record<string, unknown>;
type Block = Obj & { type?: string };

const newId = (prefix: string) => `${prefix}${randomUUID().replace(/-/g, '').slice(0, 24)}`;

function systemText(system: unknown): string {
  if (typeof system === 'string') return system;
  if (Array.isArray(system)) return (system as Block[]).filter((b) => b?.type === 'text').map((b) => String(b.text ?? '')).join('\n\n');
  return '';
}

function imagePart(b: Block): Obj | null {
  const src = b.source as { type?: string; media_type?: string; data?: string; url?: string } | undefined;
  if (src?.type === 'base64' && src.data) return { type: 'image_url', image_url: { url: `data:${src.media_type ?? 'image/png'};base64,${src.data}` } };
  if (src?.type === 'url' && src.url) return { type: 'image_url', image_url: { url: src.url } };
  return null;
}

/** A tool result's content as text (OpenAI tool messages take a string), and any images in it (sent after, as the user's). */
function toolResultContent(b: Block): { text: string; images: Obj[] } {
  const c = b.content;
  const images: Obj[] = [];
  let text: string;
  if (typeof c === 'string') text = c;
  else if (Array.isArray(c)) {
    text = (c as Block[]).map((x) => {
      if (x?.type === 'text') return String(x.text ?? '');
      if (x?.type === 'image') { const p = imagePart(x); if (p) images.push(p); return '[image: attached below]'; }
      return '';
    }).filter(Boolean).join('\n');
  } else text = c === undefined ? '' : JSON.stringify(c);
  if (b.is_error) text = `Error: ${text}`;
  return { text, images };
}

/** User content as OpenAI wants it: a plain string when it's all text (some servers take nothing else), else parts. */
function userContent(parts: Obj[]): string | Obj[] {
  return parts.every((p) => p.type === 'text') ? parts.map((p) => String(p.text)).join('\n\n') : parts;
}

/** An Anthropic Messages request as an OpenAI chat-completions request for `model`. `temperature`: the worker's own,
 *  which wins over the request's. */
export function toChatRequest(body: Obj, model: string, temperature?: number): Obj {
  const messages: Obj[] = [];
  const sys = systemText(body.system);
  if (sys) messages.push({ role: 'system', content: sys });
  for (const m of (body.messages ?? []) as { role: string; content: unknown }[]) {
    if (typeof m.content === 'string') { messages.push({ role: m.role, content: m.content }); continue; }
    const blocks = (Array.isArray(m.content) ? m.content : []) as Block[];
    if (m.role === 'assistant') {
      const text = blocks.filter((b) => b.type === 'text').map((b) => String(b.text ?? '')).join('');
      const calls = blocks.filter((b) => b.type === 'tool_use').map((b) => ({
        id: String(b.id), type: 'function', function: { name: String(b.name), arguments: JSON.stringify(b.input ?? {}) },
      }));
      if (!text && !calls.length) continue;
      messages.push({ role: 'assistant', content: text || null, ...(calls.length ? { tool_calls: calls } : {}) });
      continue;
    }
    // A user turn: its tool results first, each its own tool message (they must follow the assistant's calls), then
    // what the user said, with any images the tool results held.
    const parts: Obj[] = [];
    const later: Obj[] = [];
    for (const b of blocks) {
      if (b.type === 'tool_result') {
        const r = toolResultContent(b);
        messages.push({ role: 'tool', tool_call_id: String(b.tool_use_id), content: r.text });
        later.push(...r.images);
      } else if (b.type === 'text') {
        parts.push({ type: 'text', text: String(b.text ?? '') });
      } else if (b.type === 'image') {
        const p = imagePart(b);
        if (p) parts.push(p);
      } else if (b.type === 'document') {
        const src = b.source as { type?: string; data?: string } | undefined;
        if (src?.type === 'text' && src.data) parts.push({ type: 'text', text: src.data });
      }
    }
    parts.push(...later);
    if (parts.length) messages.push({ role: 'user', content: userContent(parts) });
  }
  const tools = ((body.tools ?? []) as Obj[]).filter((t) => t.input_schema).map((t) => ({
    type: 'function', function: { name: t.name, ...(t.description ? { description: t.description } : {}), parameters: t.input_schema },
  }));
  const out: Obj = { model, messages };
  if (tools.length) {
    out.tools = tools;
    const tc = body.tool_choice as { type?: string; name?: string } | undefined;
    if (tc?.type === 'any') out.tool_choice = 'required';
    else if (tc?.type === 'tool' && tc.name) out.tool_choice = { type: 'function', function: { name: tc.name } };
    else if (tc?.type === 'none') out.tool_choice = 'none';
    else if (tc?.type === 'auto') out.tool_choice = 'auto';
  }
  if (typeof body.max_tokens === 'number') out.max_tokens = body.max_tokens;
  const temp = temperature ?? body.temperature;
  if (typeof temp === 'number') out.temperature = temp;
  if (typeof body.top_p === 'number') out.top_p = body.top_p;
  if (Array.isArray(body.stop_sequences) && body.stop_sequences.length) out.stop = body.stop_sequences;
  if (body.stream === true) {
    out.stream = true;
    out.stream_options = { include_usage: true };
  }
  return out;
}

/** A tool call's arguments, which servers send as a JSON string (or, some, as an object). Unparseable: kept under
 *  `_raw`, so Claude Code's input check fails and tells the model, rather than running the tool with nothing. */
export function parseArgs(a: unknown): Obj {
  if (a && typeof a === 'object' && !Array.isArray(a)) return a as Obj;
  if (typeof a !== 'string' || !a.trim()) return {};
  try {
    const j = JSON.parse(a);
    return j && typeof j === 'object' && !Array.isArray(j) ? j : { _raw: a };
  } catch {
    return { _raw: a };
  }
}

export function stopReason(finish: unknown, calledTools: boolean): string {
  if (finish === 'length') return 'max_tokens';
  // Some servers end a turn of tool calls with "stop".
  if (finish === 'tool_calls' || finish === 'function_call' || calledTools) return 'tool_use';
  return 'end_turn';
}

type Usage = { prompt_tokens?: number; completion_tokens?: number };

/** A whole (unstreamed) chat completion as a Messages response. */
export function fromChatResponse(j: Obj, model: string): Obj {
  const choice = ((j.choices ?? []) as Obj[])[0] ?? {};
  const msg = (choice.message ?? {}) as { content?: unknown; tool_calls?: { id?: string; function?: { name?: string; arguments?: unknown } }[] };
  const content: Obj[] = [];
  if (typeof msg.content === 'string' && msg.content) content.push({ type: 'text', text: msg.content });
  for (const tc of msg.tool_calls ?? []) {
    content.push({ type: 'tool_use', id: tc.id || newId('toolu_'), name: tc.function?.name ?? '', input: parseArgs(tc.function?.arguments) });
  }
  const calledTools = content.some((b) => b.type === 'tool_use');
  if (!content.length) content.push({ type: 'text', text: '' });
  const u = (j.usage ?? {}) as Usage;
  return {
    id: newId('msg_'), type: 'message', role: 'assistant', model, content,
    stop_reason: stopReason(choice.finish_reason, calledTools), stop_sequence: null,
    usage: { input_tokens: u.prompt_tokens ?? 0, output_tokens: u.completion_tokens ?? 0 },
  };
}

export function sse(event: string, data: Obj): string {
  return `event: ${event}\ndata: ${JSON.stringify({ type: event, ...data })}\n\n`;
}

/** Complete SSE events' data from a buffer, and what's left of it (an event not yet ended). */
export function splitSse(buf: string): { data: string[]; rest: string } {
  const parts = buf.split(/\r?\n\r?\n/);
  const rest = parts.pop() ?? '';
  const data = parts.flatMap((ev) => {
    const lines = ev.split(/\r?\n/).filter((l) => l.startsWith('data:')).map((l) => l.slice(5).replace(/^ /, ''));
    return lines.length ? [lines.join('\n')] : [];
  });
  return { data, rest };
}

/**
 * A streamed chat completion as a Messages stream: message_start, then a content block for the text and one per tool
 * call (each opened, given its deltas, and closed in turn), then message_delta with the stop reason and usage, and
 * message_stop. Feed it each chunk's JSON; `end()` finishes the stream.
 */
export class StreamTranslator {
  private started = false;
  private next = 0;
  private open: { index: number; kind: 'text' | 'tool' } | null = null;
  private tools = new Map<number, number>(); // OpenAI tool call index -> content block index
  private finish: unknown = null;
  private calledTools = false;
  private failed = false;
  readonly usage = { input: 0, output: 0 };
  private readonly model: string;
  constructor(model: string) {
    this.model = model;
  }

  private start(): string {
    if (this.started) return '';
    this.started = true;
    return sse('message_start', {
      message: { id: newId('msg_'), type: 'message', role: 'assistant', model: this.model, content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 0, output_tokens: 0 } },
    });
  }

  private close(): string {
    if (!this.open) return '';
    const out = sse('content_block_stop', { index: this.open.index });
    this.open = null;
    return out;
  }

  push(chunk: Obj): string {
    if (this.failed) return '';
    let out = this.start();
    if (chunk.error) return out + this.fail(errorMessage(JSON.stringify(chunk)) || 'the model server reported an error');
    const u = chunk.usage as Usage | undefined;
    if (u) {
      if (typeof u.prompt_tokens === 'number') this.usage.input = u.prompt_tokens;
      if (typeof u.completion_tokens === 'number') this.usage.output = u.completion_tokens;
    }
    for (const choice of (chunk.choices ?? []) as Obj[]) {
      const delta = (choice.delta ?? {}) as { content?: unknown; tool_calls?: { index?: number; id?: string; function?: { name?: string; arguments?: unknown } }[] };
      if (typeof delta.content === 'string' && delta.content) {
        if (this.open?.kind !== 'text') {
          out += this.close();
          this.open = { index: this.next++, kind: 'text' };
          out += sse('content_block_start', { index: this.open.index, content_block: { type: 'text', text: '' } });
        }
        out += sse('content_block_delta', { index: this.open.index, delta: { type: 'text_delta', text: delta.content } });
      }
      for (const tc of delta.tool_calls ?? []) {
        const at = tc.index ?? 0;
        let index = this.tools.get(at);
        if (index === undefined) {
          out += this.close();
          index = this.next++;
          this.tools.set(at, index);
          this.calledTools = true;
          this.open = { index, kind: 'tool' };
          out += sse('content_block_start', { index, content_block: { type: 'tool_use', id: tc.id || newId('toolu_'), name: tc.function?.name ?? '', input: {} } });
        }
        const args = tc.function?.arguments;
        const partial = typeof args === 'string' ? args : args && typeof args === 'object' ? JSON.stringify(args) : '';
        if (partial) out += sse('content_block_delta', { index, delta: { type: 'input_json_delta', partial_json: partial } });
      }
      if (choice.finish_reason) this.finish = choice.finish_reason;
    }
    return out;
  }

  end(): string {
    if (this.failed) return '';
    let out = this.start();
    // A reply with nothing in it still has one (empty) text block.
    if (this.next === 0) {
      out += sse('content_block_start', { index: 0, content_block: { type: 'text', text: '' } });
      this.open = { index: this.next++, kind: 'text' };
    }
    out += this.close();
    out += sse('message_delta', { delta: { stop_reason: stopReason(this.finish, this.calledTools), stop_sequence: null }, usage: { input_tokens: this.usage.input, output_tokens: this.usage.output } });
    out += sse('message_stop', {});
    return out;
  }

  /** The stream broke off: an error event, which Claude Code reports (and may retry). */
  fail(message: string): string {
    if (this.failed) return '';
    this.failed = true;
    return this.start() + this.close() + sse('error', { error: { type: 'api_error', message } });
  }
}

/** A rough token count (four characters a token) for count_tokens, which OpenAI-compatible servers don't offer. */
export function estimateTokens(body: Obj): number {
  const text = JSON.stringify([body.system ?? '', body.messages ?? [], body.tools ?? []]);
  return Math.ceil(text.length / 4);
}

const ERROR_TYPES: Record<number, string> = { 400: 'invalid_request_error', 401: 'authentication_error', 403: 'permission_error', 404: 'not_found_error', 413: 'request_too_large', 429: 'rate_limit_error' };

/** An upstream error in Anthropic's shape, same status (so Claude Code retries 429s and 5xx as it would). */
export function anthropicError(status: number, message: string): string {
  return JSON.stringify({ type: 'error', error: { type: ERROR_TYPES[status] ?? (status >= 500 ? 'api_error' : 'invalid_request_error'), message } });
}

/**
 * One request from a worker's Claude Code to an OpenAI-compatible endpoint: /v1/messages goes on as /chat/completions,
 * count_tokens is estimated here, and anything else is refused. Measured for the UI like any worker request.
 */
export async function forwardOpenAI(route: Route, worker: string, path: string, raw: Buffer, res: http.ServerResponse, onRequest: (s: RequestStats) => void): Promise<void> {
  const t0 = Date.now();
  const json = { 'content-type': 'application/json' };
  let body: Obj;
  try {
    body = raw.length ? JSON.parse(raw.toString()) : {};
  } catch {
    res.writeHead(400, json).end(anthropicError(400, 'duet proxy: the request is not JSON'));
    return;
  }
  if (path.startsWith('/v1/messages/count_tokens')) {
    res.writeHead(200, json).end(JSON.stringify({ input_tokens: estimateTokens(body) }));
    return;
  }
  if (!/^\/v1\/messages(\?|$)/.test(path)) {
    res.writeHead(404, json).end(anthropicError(404, `duet proxy: ${path} isn't offered by an OpenAI-compatible worker`));
    return;
  }
  const req = toChatRequest(body, route.model, route.temperature);
  const sent: Record<string, unknown> = req.temperature !== undefined ? { temperature: req.temperature } : {};
  let ttfb = 0;
  const report = (status: number, input = 0, output = 0) => {
    const totalMs = Date.now() - t0;
    const genMs = totalMs - (ttfb || totalMs);
    onRequest({
      worker, taskId: route.taskId, path, status, ttfbMs: ttfb || totalMs, totalMs, inputTokens: input, outputTokens: output,
      tokPerS: output > 1 && genMs > 0 ? Math.round((output / genMs) * 10000) / 10 : null, sent,
    });
  };
  const ac = new AbortController();
  // The worker went away mid-response (cancel or crash): stop generating upstream.
  res.on('close', () => { if (!res.writableEnded) ac.abort(); });
  let up: Response;
  try {
    up = await fetch(`${route.upstream}/chat/completions`, {
      method: 'POST',
      headers: { ...json, accept: req.stream ? 'text/event-stream' : 'application/json', ...authHeaders(route.apiKey) },
      body: JSON.stringify(req),
      signal: ac.signal,
    });
  } catch (e) {
    if (ac.signal.aborted) return;
    res.writeHead(502, json).end(anthropicError(502, `duet proxy upstream: ${(e as { cause?: { message?: string } }).cause?.message ?? (e as Error).message}`));
    report(502);
    return;
  }
  ttfb = Date.now() - t0;
  if (!up.ok) {
    const text = await up.text().catch(() => '');
    // Too long for the model's window: in Claude Code's words, so it compacts and tries again (context.ts).
    const fit = overflowAsPromptTooLong(up.status, text);
    if (fit) res.writeHead(400, json).end(fit);
    else res.writeHead(up.status, json).end(anthropicError(up.status, errorMessage(text) || `the model server answered HTTP ${up.status}`));
    report(up.status);
    return;
  }
  if (!req.stream) {
    try {
      const msg = fromChatResponse(await up.json() as Obj, route.model);
      res.writeHead(200, json).end(JSON.stringify(msg));
      const u = msg.usage as { input_tokens: number; output_tokens: number };
      report(200, u.input_tokens, u.output_tokens);
    } catch (e) {
      res.writeHead(502, json).end(anthropicError(502, `duet proxy: the model server's answer wasn't a chat completion (${(e as Error).message})`));
      report(502);
    }
    return;
  }
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
  const tr = new StreamTranslator(route.model);
  const dec = new TextDecoder();
  let buf = '';
  try {
    for await (const piece of up.body as unknown as AsyncIterable<Uint8Array>) {
      buf += dec.decode(piece, { stream: true });
      const { data, rest } = splitSse(buf);
      buf = rest;
      for (const d of data) {
        if (d === '[DONE]') continue;
        let chunk: Obj;
        try { chunk = JSON.parse(d); } catch { continue; }
        const out = tr.push(chunk);
        if (out) res.write(out);
      }
    }
    res.end(tr.end());
  } catch (e) {
    if (!ac.signal.aborted) res.end(tr.fail(`the model server's stream broke off: ${(e as Error).message}`));
  }
  report(200, tr.usage.input, tr.usage.output);
}
