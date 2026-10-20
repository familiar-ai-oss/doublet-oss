// Doublet's own tools (plan, delegate, await_workers, notes, diagrams…) for agents that can't take an in-process MCP
// server, as Claude Code does through the Agent SDK. The hub serves the very same servers over MCP's Streamable HTTP
// transport on 127.0.0.1, one fresh server instance per MCP session, at /mcp/<token>: each registration (one agent
// session's server) gets its own random token, so a caller reaches only the server it was given. Agents that take
// only stdio run mcp-stdio.ts, which relays to that URL.
//
// The token is the only guard, so it stays out of logs; on a machine shared with other users it can show in the
// agent's command line (as any MCP config does). The in-process server stays Claude's default.
import { randomBytes, randomUUID } from 'node:crypto';
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http';
import { fileURLToPath } from 'node:url';
import type { McpHttpServerConfig, McpSdkServerConfigWithInstance, McpStdioServerConfig } from '@anthropic-ai/claude-agent-sdk';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';

/** Builds the server afresh: each MCP session gets its own instance (an instance serves one connection). */
export type ServerFactory = () => McpSdkServerConfigWithInstance;

type Session = { token: string; transport: StreamableHTTPServerTransport };

/** The bodies the hub accepts: MCP messages are small; a diagram's HTML is the largest. */
const MAX_BODY = 8 * 1024 * 1024;

export class McpGateway {
  private readonly factories = new Map<string, ServerFactory>();
  private readonly sessions = new Map<string, Session>();
  private server: Server | null = null;
  private port = 0;
  private readonly log: (msg: string) => void;

  constructor(log: (msg: string) => void = () => {}) {
    this.log = log;
  }

  /** Listens on 127.0.0.1, on a port the system picks. */
  async listen(): Promise<number> {
    if (this.server) return this.port;
    const server = createServer((req, res) => void this.handle(req, res).catch((e) => this.fail(res, 500, String(e))));
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', () => resolve());
    });
    this.server = server;
    this.port = (server.address() as { port: number }).port;
    return this.port;
  }

  /** Serves a server until `unregister`: its URL, with the token in it. */
  register(factory: ServerFactory): { token: string; url: string } {
    if (!this.server) throw new Error('the MCP gateway is not listening');
    const token = randomBytes(24).toString('base64url');
    this.factories.set(token, factory);
    return { token, url: `http://127.0.0.1:${this.port}/mcp/${token}` };
  }

  /** Stops serving it, and closes its open sessions. */
  unregister(token: string): void {
    this.factories.delete(token);
    for (const [id, s] of this.sessions) {
      if (s.token !== token) continue;
      this.sessions.delete(id);
      void s.transport.close();
    }
  }

  /** How an agent reaches a registered server: over HTTP, or through the stdio relay. `like`: the in-process server,
   *  whose tool timeout carries over. (Its alwaysLoad is on each tool, as `_meta`, which MCP itself carries.) */
  static http(url: string, like?: McpSdkServerConfigWithInstance): McpHttpServerConfig {
    return { type: 'http', url, ...carried(like) };
  }

  static stdio(url: string, like?: McpSdkServerConfigWithInstance): McpStdioServerConfig {
    return { type: 'stdio', command: process.execPath, args: ['--experimental-strip-types', '--no-warnings', STDIO_RELAY], env: { DOUBLET_MCP_URL: url }, ...carried(like) };
  }

  async close(): Promise<void> {
    for (const token of [...this.factories.keys()]) this.unregister(token);
    await new Promise<void>((r) => (this.server ? this.server.close(() => r()) : r()));
    this.server = null;
  }

  private async handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const m = /^\/mcp\/([A-Za-z0-9_-]+)$/.exec(new URL(req.url ?? '/', 'http://x').pathname);
    const token = m?.[1];
    const factory = token ? this.factories.get(token) : undefined;
    // An unknown token looks like no server at all.
    if (!token || !factory) return this.fail(res, 404, 'not found');
    const body = req.method === 'POST' ? await readJson(req) : undefined;
    const id = req.headers['mcp-session-id'];
    if (typeof id === 'string') {
      const s = this.sessions.get(id);
      if (!s || s.token !== token) return this.fail(res, 404, 'unknown MCP session');
      return s.transport.handleRequest(req, res, body);
    }
    // No session yet: only an initialize starts one.
    if (req.method !== 'POST' || !isInitialize(body)) return this.fail(res, 400, 'start with initialize');
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: () => randomUUID(),
      onsessioninitialized: (sid) => void this.sessions.set(sid, { token, transport }),
    });
    transport.onclose = () => {
      if (transport.sessionId) this.sessions.delete(transport.sessionId);
    };
    await factory().instance.connect(transport);
    await transport.handleRequest(req, res, body);
  }

  private fail(res: ServerResponse, status: number, message: string): void {
    if (status >= 500) this.log(`MCP gateway: ${message}`);
    if (res.headersSent) return void res.end();
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ jsonrpc: '2.0', error: { code: -32000, message }, id: null }));
  }
}

const STDIO_RELAY = fileURLToPath(new URL('./mcp-stdio.ts', import.meta.url));

function carried(like?: McpSdkServerConfigWithInstance): { timeout?: number } {
  const timeout = (like as { timeout?: number } | undefined)?.timeout;
  return timeout ? { timeout } : {};
}

function isInitialize(body: unknown): boolean {
  const msgs = Array.isArray(body) ? body : [body];
  return msgs.some((m) => !!m && typeof m === 'object' && (m as { method?: unknown }).method === 'initialize');
}

function readJson(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on('data', (c: Buffer) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Error('request too large'));
        req.destroy();
      } else chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : undefined); } catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}
