// Headless test client for duet-hub.
//   DUET_TOKEN=... node --experimental-strip-types src/cli.ts [--url ws://127.0.0.1:7811/ws] [--device cli] [--from 0]
// Type a line to prompt the lead. Commands:
//   /approve [id]              allow (the latest pending approval when id is omitted)
//   /edit <id> <json>          allow with an edited input, e.g. /edit ab12 {"command":"ls"}
//   /reject <id> [message]     deny, with an optional note to the model
//   /interrupt                 stop the running turn
//   /effort <level|auto>       low · medium · high · xhigh · max, or auto to clear
//   /mode <mode>               default · acceptEdits · auto · plan · bypassPermissions
//   /drop                      drop the connection (tests resume)
//   /quit
import { createInterface } from 'node:readline';
import { HubClient } from './client.ts';
import type { EffortLevel, HubEvent, PermissionMode } from './protocol.ts';

const arg = (name: string, dflt: string) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : dflt;
};
const token = process.env.DUET_TOKEN;
if (!token) {
  console.error('set DUET_TOKEN (create one with: src/main.ts token add <device>)');
  process.exit(2);
}

const client = new HubClient({ url: arg('url', 'ws://127.0.0.1:7811/ws'), device: arg('device', 'cli'), token, lastSeq: Number(arg('from', '0')) });
const pendingApprovals: string[] = [];
let streaming = false;

const dim = (s: string) => `\x1b[2m${s}\x1b[0m`;
const endStream = () => { if (streaming) { process.stdout.write('\n'); streaming = false; } };

function render(e: HubEvent): void {
  switch (e.type) {
    case 'text_delta':
      process.stdout.write(e.text);
      streaming = true;
      return;
    case 'assistant':
      endStream();
      for (const t of e.toolUses) console.log(dim(`  ⚙ ${t.name} ${JSON.stringify(t.input).slice(0, 200)}`));
      return;
    case 'approval_request':
      endStream();
      pendingApprovals.push(e.id);
      if (e.plan !== undefined) console.log(`\x1b[33m? approval ${e.id}: leave plan mode with this plan:\x1b[0m\n${e.plan}\n  (/approve ${e.id} · /reject ${e.id} [what to change])`);
      else console.log(`\x1b[33m? approval ${e.id}: ${e.tool} ${JSON.stringify(e.input).slice(0, 300)}\x1b[0m  (/approve ${e.id} · /edit ${e.id} {...} · /reject ${e.id})`);
      return;
    case 'approval_resolved': {
      const i = pendingApprovals.indexOf(e.id);
      if (i >= 0) pendingApprovals.splice(i, 1);
      console.log(dim(`  ${e.decision === 'allow' ? '✓' : '✗'} ${e.id} ${e.decision}${e.edited ? ' (edited)' : ''} by ${e.by}${e.message ? `: ${e.message}` : ''}`));
      return;
    }
    case 'tool_result':
      console.log(dim(`  → ${e.isError ? 'ERROR ' : ''}${e.preview.slice(0, 300).replace(/\n/g, '⏎')}`));
      return;
    case 'user':
      endStream();
      console.log(`\x1b[36m[${e.by}] ${e.text}\x1b[0m`);
      return;
    case 'turn_end':
      endStream();
      console.log(dim(`— turn ${e.turn} ${e.subtype}${e.interrupted ? ' (interrupted)' : ''}${e.durationMs ? ` ${(e.durationMs / 1000).toFixed(1)}s` : ''} · seq ${e.seq}`));
      return;
    default:
      if (e.type !== 'turn_start') { endStream(); console.log(dim(`  [${e.type}] ${JSON.stringify(e).slice(0, 300)}`)); }
  }
}

client.on('event', render);
client.on('disconnected', (code) => console.log(dim(`(disconnected ${code}; reconnecting from seq ${client.lastSeq})`)));
client.on('reconnected', (seq) => console.log(dim(`(resumed at seq ${seq}; gaps ${client.gaps.length}, duplicates ${client.duplicates})`)));

await client.connect();
console.log(dim(`connected, at seq ${client.lastSeq}`));

const rl = createInterface({ input: process.stdin });
for await (const line of rl) {
  const [cmd, ...rest] = line.trim().split(' ');
  try {
    if (!line.trim()) continue;
    else if (cmd === '/quit') break;
    else if (cmd === '/drop') client.dropConnection();
    else if (cmd === '/approve') await client.send({ type: 'approve', id: rest[0] || pendingApprovals.at(-1) || '' });
    else if (cmd === '/edit') await client.send({ type: 'approve', id: rest[0], updatedInput: JSON.parse(rest.slice(1).join(' ')) });
    else if (cmd === '/reject') await client.send({ type: 'reject', id: rest[0], message: rest.slice(1).join(' ') || undefined });
    else if (cmd === '/interrupt') await client.send({ type: 'interrupt' });
    else if (cmd === '/effort') await client.send({ type: 'set_effort', level: rest[0] === 'auto' ? null : (rest[0] as EffortLevel) });
    else if (cmd === '/mode') await client.send({ type: 'set_permission_mode', mode: rest[0] as PermissionMode });
    else if (cmd.startsWith('/')) console.log('unknown command');
    else await client.send({ type: 'prompt', text: line });
  } catch (err) {
    console.log(`\x1b[31m${err instanceof Error ? err.message : err}\x1b[0m`);
  }
}
client.close();
