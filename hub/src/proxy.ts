// Per-worker rewrite proxy. Each worker's Claude Code points ANTHROPIC_BASE_URL at http://127.0.0.1:<port>/w/<workerId>.
// The proxy forces the backend model, applies the worker's effort and temperature, refuses requests a swap
// hasn't been approved for, and measures each request (TTFB, tokens, tok/s) for the UI. A local server's "doesn't fit
// in my context" error goes back as Anthropic's "prompt is too long", which Claude Code answers by compacting and
// trying again (context.ts). A worker on an OpenAI-compatible endpoint has its requests translated to chat completions
// and back (openai.ts).
import http from 'node:http';
import { applyEffort, type EffortTableId } from './effort.ts';
import { overflowAsPromptTooLong } from './context.ts';
import { forwardOpenAI } from './openai.ts';

export type Route = {
  upstream: string; // base URL, e.g. http://127.0.0.1:8800
  model: string; // model name the backend expects
  table: EffortTableId;
  level: string;
  temperature?: number;
  taskId?: string;
  /** The API the upstream speaks: Anthropic's Messages (llmd, Ollama's /v1/messages; the default) or OpenAI's chat
   *  completions (an endpoint added in Settings, whose upstream is its base URL ending in /v1). */
  api?: 'anthropic' | 'openai';
  /** openai: the endpoint's key, sent as a bearer token. */
  apiKey?: string;
};

export type RequestStats = {
  worker: string;
  taskId?: string;
  path: string;
  status: number;
  ttfbMs: number;
  totalMs: number;
  inputTokens: number;
  outputTokens: number;
  tokPerS: number | null;
  sent: Record<string, unknown>; // the effort/temperature fields actually sent
};

// Returns the route, or a refusal reason (e.g. the model isn't loaded and no swap was approved).
export type Resolver = (worker: string) => Route | { refuse: string };

export async function startWorkerProxy(resolve: Resolver, onRequest: (s: RequestStats) => void, port = 0): Promise<{ port: number; baseUrl: (worker: string) => string; close: () => Promise<void> }> {
  const server = http.createServer((req, res) => {
    const m = req.url?.match(/^\/w\/([a-z0-9-]+)(\/.*)$/);
    const route = m ? resolve(m[1]) : { refuse: 'unknown route' };
    if (!m || 'refuse' in route) {
      res.writeHead(403, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ type: 'error', error: { type: 'permission_error', message: `duet proxy: ${'refuse' in route ? route.refuse : 'bad path'}` } }));
      return;
    }
    const [, worker, path] = m;
    const chunks: Buffer[] = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      let body = Buffer.concat(chunks);
      if (route.api === 'openai') {
        void forwardOpenAI(route, worker, path, body, res, onRequest).catch((e) => {
          if (!res.headersSent) res.writeHead(500, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ type: 'error', error: { type: 'api_error', message: `duet proxy: ${e instanceof Error ? e.message : e}` } }));
        });
        return;
      }
      let sent: Record<string, unknown> = {};
      if (body.length && /json/.test(req.headers['content-type'] ?? '')) {
        const j = JSON.parse(body.toString()) as Record<string, unknown>;
        j.model = route.model;
        if (path.startsWith('/v1/messages') && !path.includes('count_tokens')) {
          applyEffort(j, route.table, route.level, route.temperature);
          sent = { chat_template_kwargs: j.chat_template_kwargs, thinking: j.thinking, temperature: j.temperature, output_config: j.output_config };
        }
        body = Buffer.from(JSON.stringify(j));
      }
      const up = new URL(path, route.upstream);
      const t0 = Date.now();
      let ttfb = 0;
      let tail = '';
      const headers = { ...req.headers, host: up.host, 'content-length': String(body.length) };
      const upReq = http.request(up, { method: req.method, headers }, (upRes) => {
        const status = upRes.statusCode ?? 502;
        const messages = path.startsWith('/v1/messages') && !path.includes('count_tokens');
        if (status >= 400 && messages) {
          // An error is a short JSON body: read it whole, and put a context overflow in Claude Code's words.
          const err: Buffer[] = [];
          upRes.on('data', (c: Buffer) => err.push(c));
          upRes.on('end', () => {
            const raw = Buffer.concat(err);
            const fit = overflowAsPromptTooLong(status, raw.toString());
            if (fit) res.writeHead(400, { 'content-type': 'application/json' }).end(fit);
            else res.writeHead(status, upRes.headers).end(raw);
            onRequest({ worker, taskId: route.taskId, path, status, ttfbMs: Date.now() - t0, totalMs: Date.now() - t0, inputTokens: 0, outputTokens: 0, tokPerS: null, sent });
          });
          return;
        }
        res.writeHead(status, upRes.headers);
        upRes.on('data', (c: Buffer) => {
          if (!ttfb) ttfb = Date.now() - t0;
          tail = (tail + c.toString()).slice(-100_000);
          res.write(c);
        });
        upRes.on('end', () => {
          res.end();
          if (!path.startsWith('/v1/messages') || path.includes('count_tokens')) return;
          const totalMs = Date.now() - t0;
          const u = usageOf(tail);
          const genMs = totalMs - ttfb;
          onRequest({
            worker, taskId: route.taskId, path, status: upRes.statusCode ?? 0, ttfbMs: ttfb, totalMs,
            inputTokens: u.input, outputTokens: u.output, tokPerS: u.output > 1 && genMs > 0 ? Math.round((u.output / genMs) * 10000) / 10 : null, sent,
          });
        });
      });
      upReq.on('error', (e) => {
        if (!res.headersSent) res.writeHead(502, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ type: 'error', error: { type: 'api_error', message: `duet proxy upstream: ${e.message}` } }));
      });
      // The worker went away mid-response (cancel or crash): stop generating upstream.
      res.on('close', () => { if (!res.writableEnded) upReq.destroy(); });
      upReq.end(body);
    });
  });
  await new Promise<void>((r) => server.listen(port, '127.0.0.1', r));
  const p = (server.address() as { port: number }).port;
  return { port: p, baseUrl: (w) => `http://127.0.0.1:${p}/w/${w}`, close: () => new Promise((r) => server.close(() => r())) };
}

// Input/output token counts from a JSON body or the tail of an SSE stream (last usage object wins per field).
function usageOf(text: string): { input: number; output: number } {
  let input = 0, output = 0;
  for (const m of text.matchAll(/"usage"\s*:\s*(\{[^{}]*\})/g)) {
    try {
      const u = JSON.parse(m[1]);
      if (u.input_tokens) input = u.input_tokens + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
      if (u.output_tokens) output = u.output_tokens;
    } catch { /* partial object at the tail boundary */ }
  }
  return { input, output };
}
