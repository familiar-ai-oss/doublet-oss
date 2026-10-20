// The gateway serves Doublet's in-process MCP servers to agents that can't load one: over HTTP on 127.0.0.1 and
// through the stdio relay, with the same tools, instructions and answers as in-process, and only to a caller with the
// registration's token.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { z } from 'zod';
import { McpGateway } from '../src/agents/mcp-gateway.ts';

const gateway = new McpGateway();
after(() => gateway.close());

let built = 0;
/** A stand-in for dialogue.leadServer(): a factory, as each MCP session needs its own instance. */
const duet = () => {
  built++;
  return createSdkMcpServer({
    name: 'duet', alwaysLoad: true, timeout: 120_000, instructions: 'Plan before you delegate.',
    tools: [
      tool('plan', 'Your plan.', { steps: z.array(z.string()) }, async (a) => ({ content: [{ type: 'text', text: `planned ${a.steps.length}` }] })),
      tool('fleet', 'List workers.', {}, async () => ({ content: [{ type: 'text', text: 'qwen: idle' }] })),
    ],
  });
};

async function connect(transport: StreamableHTTPClientTransport | StdioClientTransport) {
  const client = new Client({ name: 'test-agent', version: '1' });
  await client.connect(transport);
  return client;
}

test('over HTTP: the same tools and instructions, and calls answered', async () => {
  await gateway.listen();
  const { url } = gateway.register(duet);
  assert.match(url, /^http:\/\/127\.0\.0\.1:\d+\/mcp\/[A-Za-z0-9_-]{32}$/);
  const client = await connect(new StreamableHTTPClientTransport(new URL(url)));
  assert.equal(client.getInstructions(), 'Plan before you delegate.');
  const tools = (await client.listTools()).tools;
  assert.deepEqual(tools.map((t) => t.name).sort(), ['fleet', 'plan']);
  // alwaysLoad rides on each tool, so Claude Code never defers them behind tool search, in-process or not.
  assert.ok(tools.every((t) => t._meta?.['anthropic/alwaysLoad'] === true));
  const r = await client.callTool({ name: 'plan', arguments: { steps: ['find', 'rename'] } });
  assert.deepEqual(r.content, [{ type: 'text', text: 'planned 2' }]);
  await client.close();
});

test('the stdio relay passes everything through to the hub', async () => {
  const { url } = gateway.register(duet);
  const cfg = McpGateway.stdio(url, duet());
  assert.equal(cfg.timeout, 120_000, "the in-process server's tool timeout carries over");
  const client = await connect(new StdioClientTransport({ command: cfg.command, args: cfg.args, env: { ...process.env, ...cfg.env } as Record<string, string> }));
  assert.deepEqual((await client.listTools()).tools.map((t) => t.name).sort(), ['fleet', 'plan']);
  assert.deepEqual((await client.callTool({ name: 'fleet', arguments: {} })).content, [{ type: 'text', text: 'qwen: idle' }]);
  await client.close();
});

test('only the token reaches a server, each session gets its own instance, and unregistering ends them', async () => {
  const a = gateway.register(duet);
  const b = gateway.register(duet);
  const before = built;
  const one = await connect(new StreamableHTTPClientTransport(new URL(a.url)));
  const two = await connect(new StreamableHTTPClientTransport(new URL(a.url)));
  assert.equal(built - before, 2, 'a fresh server instance per MCP session');

  const wrong = a.url.replace(/[^/]+$/, 'not-a-token');
  await assert.rejects(connect(new StreamableHTTPClientTransport(new URL(wrong))), /404|not found/i);
  // A session id is no use with another registration's token.
  const sessionId = (one.transport as StreamableHTTPClientTransport).sessionId!;
  const crossed = await fetch(b.url, { method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', 'mcp-session-id': sessionId }, body: JSON.stringify({ jsonrpc: '2.0', id: 9, method: 'tools/list' }) });
  assert.equal(crossed.status, 404);
  // Without a session, only initialize is taken.
  const cold = await fetch(a.url, { method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) });
  assert.equal(cold.status, 400);

  gateway.unregister(a.token);
  await assert.rejects(one.listTools());
  await assert.rejects(connect(new StreamableHTTPClientTransport(new URL(a.url))), /404|not found/i);
  await two.close().catch(() => {});
  await one.close().catch(() => {});
});
