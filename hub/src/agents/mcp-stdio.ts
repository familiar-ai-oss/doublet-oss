// The stdio relay for Doublet's tools: an agent that runs MCP servers only as commands runs this one, and it passes
// each message on to the hub's gateway (mcp-gateway.ts) at DOUBLET_MCP_URL, and the answers back. It holds no state.
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const url = process.env.DOUBLET_MCP_URL;
if (!url) {
  process.stderr.write('doublet mcp relay: DOUBLET_MCP_URL is not set\n');
  process.exit(2);
}

const hub = new StreamableHTTPClientTransport(new URL(url));
const agent = new StdioServerTransport();
const quit = (why: string, code = 0) => {
  if (why) process.stderr.write(`doublet mcp relay: ${why}\n`);
  void hub.close();
  process.exit(code);
};

agent.onmessage = (m) => void hub.send(m).catch((e) => quit(`the hub didn't take a message: ${e}`, 1));
hub.onmessage = (m) => {
  // The protocol version the hub answered initialize with goes with every later request, as MCP asks.
  const v = (m as { result?: { protocolVersion?: unknown } }).result?.protocolVersion;
  if (typeof v === 'string') hub.setProtocolVersion(v);
  void agent.send(m);
};
hub.onerror = (e) => process.stderr.write(`doublet mcp relay: ${e}\n`);
agent.onclose = () => quit('');
hub.onclose = () => quit('the hub closed the connection', 1);

await hub.start();
await agent.start();
