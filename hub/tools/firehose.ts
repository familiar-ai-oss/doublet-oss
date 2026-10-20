// A stand-in hub for pressure tests (docs/diagnostics.md): speaks the app's protocol and makes Claude's side up, fast
// and with no model, so the app's UI tests can stream long replies and pile up history on demand.
//
//   node --experimental-strip-types tools/firehose.ts [--port 7898] [--history 150] [--diagrams 25] [--diagnostics <file.jsonl>]
//
// - A connecting device gets a conversation of `--history` finished turns (markdown, code, tables, tool runs).
// - Every `--diagrams`th turn, counting back from the last, Claude also draws a diagram (Mermaid; an HTML page every
//   100 turns), and the last turn draws one and revises it, so the conversation opens on two diagram cards.
//   `--diagrams 0`: none.
// - A prompt from the app starts a streamed turn: text deltas at `rate` a second, with a tool run and a long output
//   every so often. Interrupt stops it.
// - GET /stream?chars=20000&rate=60&tools=6 starts one too (for tests that don't type); GET /stop ends it.
// - GET /burst?events=5000 sends that many deltas at once, as fast as the socket takes them.
// - Any token is accepted. Every other message is acked ok. Crash and freeze reports (`diagnostic`) are kept in
//   `--diagnostics` (one JSON line each) and listed at GET /diagnostics.
// - `--root <folder>`: Claude's folder is that one, and the Explorer and file viewer read it, through the hub's own
//   fs code (listings with git status, files with their changed lines), so their speed can be measured too.
import { createServer } from 'node:http';
import { appendFileSync } from 'node:fs';
import { WebSocketServer, type WebSocket } from 'ws';
import { listDir, readFile } from '../src/fs.ts';

const arg = (name: string, dflt: string) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : dflt;
};
const port = Number(arg('port', '7898'));
const historyTurns = Number(arg('history', '150'));
const diagramEvery = Number(arg('diagrams', '25'));
const diagFile = arg('diagnostics', '');
const root = arg('root', '');
const log = (m: string) => process.stderr.write(`${new Date().toISOString()} firehose ${m}\n`);

const conversationId = 'f1re-h05e-0000-4000-8000-000000000001';
type Ev = Record<string, unknown> & { type: string; seq: number; ts: number };
const events: Ev[] = [];
const clients = new Set<WebSocket>();
const diagnostics: unknown[] = [];
let turn = 0;

function emit(body: Record<string, unknown> & { type: string }): void {
  const e = { ...body, conversationId, seq: events.length + 1, ts: Date.now() } as Ev;
  events.push(e);
  const text = JSON.stringify(e);
  for (const c of clients) if (c.readyState === c.OPEN) c.send(text);
}

// Text that exercises the renderer: headings, lists, inline code, a code block, a table, a long paragraph.
const WORDS = 'the parser keeps every token with its range so a diagnostic can point at the exact column while the lexer streams states through the hub to each device'.split(' ');
function paragraph(n: number, seed: number): string {
  return Array.from({ length: n }, (_, i) => WORDS[(seed * 7 + i * 13) % WORDS.length]).join(' ').replace(/^./, (c) => c.toUpperCase()) + '.';
}
function richReply(i: number, size = 1): string {
  const parts = [`## Step ${i}: what changed`, paragraph(40 * size, i), `- \`Lexer.swift\`: ${paragraph(12, i + 1)}`, `- \`Parser.swift\`: ${paragraph(12, i + 2)}`,
    '```swift\n' + Array.from({ length: 12 * size }, (_, k) => `    let token${k} = lexer.next() // ${WORDS[(i + k) % WORDS.length]}`).join('\n') + '\n```',
    '| File | Lines | Status |\n|---|---|---|\n' + Array.from({ length: 6 }, (_, k) => `| src/f${k}.ts | ${k * 37 + i} | ${k % 2 ? 'ok' : 'changed'} |`).join('\n'),
    paragraph(60 * size, i + 3)];
  return parts.join('\n\n');
}
function longOutput(lines: number, seed: number): string {
  return Array.from({ length: lines }, (_, k) => `[${String(k).padStart(5, '0')}] test case ${seed}.${k} ${k % 97 === 0 ? 'FAILED: expected 3, got 4' : 'passed'} (${(k % 13) * 0.7}ms)`).join('\n');
}

// Diagrams of the kinds Claude draws (flowchart, sequence, state, class), sized with the turn.
function mermaid(i: number, version = 1): string {
  const n = 4 + (i % 5) + version;
  switch (i % 4) {
    case 0: return 'flowchart TD\n' + Array.from({ length: n }, (_, k) => `    N${k}["${WORDS[(i + k) % WORDS.length]} ${k}"] --> N${k + 1}`).join('\n') + `\n    N${n} --> N0`;
    case 1: return 'sequenceDiagram\n    participant App\n    participant Hub\n    participant Lead\n' +
      Array.from({ length: n }, (_, k) => `    ${['App->>Hub', 'Hub->>Lead', 'Lead-->>Hub', 'Hub-->>App'][k % 4]}: ${WORDS[(i + k) % WORDS.length]} ${k}`).join('\n');
    case 2: return 'stateDiagram-v2\n    [*] --> S0\n' + Array.from({ length: n }, (_, k) => `    S${k} --> S${k + 1}: ${WORDS[(i + k) % WORDS.length]}`).join('\n') + `\n    S${n} --> [*]`;
    default: return 'classDiagram\n' + Array.from({ length: n }, (_, k) => `    class C${k} {\n        +${WORDS[(i + k) % WORDS.length]}: Int\n        +next() C${k + 1}\n    }\n    C${k} --> C${k + 1}`).join('\n');
  }
}
// Now and then one of Claude's own HTML pages instead.
function page(i: number): string {
  const boxes = Array.from({ length: 4 + (i % 4) }, (_, k) => `<div class="b">${WORDS[(i + k) % WORDS.length]} ${k}</div>`).join('<div class="a">→</div>');
  return `<!doctype html><html><head><meta name="viewport" content="width=device-width"><style>body{font:15px -apple-system,sans-serif;margin:16px;color-scheme:light dark}
.r{display:flex;flex-wrap:wrap;gap:8px;align-items:center}.b{padding:10px 14px;border-radius:10px;background:#8b5cf633;border:1px solid #8b5cf6}.a{color:#888}</style></head>
<body><h3>Step ${i}</h3><div class="r">${boxes}</div></body></html>`;
}
function diagram(i: number, version = 1): void {
  const html = i !== historyTurns && i % 100 === 50;
  emit({ type: 'diagram', id: `fh-${i}`, version, title: `How step ${i} flows`, kind: html ? 'html' : 'mermaid', source: html ? page(i) : mermaid(i, version),
    caption: version > 1 ? 'With the step the tests added' : `What step ${i} changed, drawn`, by: 'lead',
    explains: [{ path: `/home/you/projects/parser/Sources/Parser/Step${i}.swift`, start: 1, end: 40 }] });
}

function finishedTurn(i: number): void {
  turn++;
  emit({ type: 'user', turn, text: `Question ${i}: ${paragraph(18, i)}`, by: 'ipad' });
  emit({ type: 'turn_start', turn });
  const tool = { id: `toolu_hist_${i}`, name: 'Bash', input: { command: `swift test --filter Case${i}`, description: 'Run the tests' } };
  emit({ type: 'assistant', turn, text: '', toolUses: [tool] });
  const out = longOutput(400, i);
  emit({ type: 'tool_result', turn, toolUseId: tool.id, isError: false, preview: out.slice(0, 2000), tail: out.slice(-1500) });
  emit({ type: 'assistant', turn, text: richReply(i), toolUses: [] });
  // After the reply, so the last turn's diagrams are at the bottom of the thread, where it opens.
  if (diagramEvery > 0 && (historyTurns - i) % diagramEvery === 0) {
    diagram(i);
    if (i === historyTurns) diagram(i, 2);
  }
  emit({ type: 'turn_end', turn, subtype: 'success', isError: false, interrupted: false, durationMs: 4200, numTurns: 2 });
}

emit({ type: 'session', state: 'ready', sessionId: conversationId, model: 'claude-haiku-5-5' });
if (root) emit({ type: 'lead_info', model: 'claude-haiku-5-5', effort: 'medium', models: [], cwd: root });
emit({ type: 'dialogue_state', used: 0, limit: 12, paused: false, openQuestions: 0, leadInbox: 0 });
for (let i = 1; i <= historyTurns; i++) finishedTurn(i);

// The streamed turn.
let streaming: { timer: NodeJS.Timeout; turn: number; text: string } | null = null;
function startStream(chars = 20000, rate = 60, tools = 6, prompt = 'Explain the whole parser, file by file.'): boolean {
  if (streaming) return false;
  turn++;
  const t = turn;
  emit({ type: 'user', turn: t, text: prompt, by: 'ipad' });
  emit({ type: 'turn_start', turn: t });
  let n = 0;
  const target = richReply(t, Math.max(1, Math.ceil(chars / 2500))).repeat(Math.max(1, Math.ceil(chars / (2500 * Math.ceil(chars / 2500)))));
  const chunks = target.match(/[\s\S]{1,24}/g) ?? [];
  const toolEvery = tools > 0 ? Math.max(1, Math.floor(chunks.length / (tools + 1))) : Infinity;
  const tick = () => {
    if (!streaming) return;
    if (n >= chunks.length || streaming.text.length >= chars) return endStream(false);
    const piece = chunks[n++];
    streaming.text += piece;
    emit({ type: 'text_delta', turn: t, text: piece });
    if (n % toolEvery === 0) {
      const id = `toolu_live_${t}_${n}`;
      emit({ type: 'assistant', turn: t, text: '', toolUses: [{ id, name: 'Bash', input: { command: `npm test -- --shard ${n}`, description: 'Run a shard' } }] });
      const out = longOutput(3000, n);
      emit({ type: 'tool_result', turn: t, toolUseId: id, isError: n % 2 === 0, preview: out.slice(0, 2000), tail: out.slice(-1500) });
    }
  };
  streaming = { timer: setInterval(tick, Math.max(1, Math.round(1000 / rate))), turn: t, text: '' };
  log(`stream: turn ${t}, ${chars} chars at ${rate}/s, ${tools} tool runs`);
  return true;
}
function endStream(interrupted: boolean): void {
  if (!streaming) return;
  clearInterval(streaming.timer);
  const { turn: t, text } = streaming;
  streaming = null;
  if (interrupted) emit({ type: 'interrupt', turn: t, by: 'ipad' });
  emit({ type: 'assistant', turn: t, text, toolUses: [] });
  emit({ type: 'turn_end', turn: t, subtype: interrupted ? 'error_during_execution' : 'success', isError: interrupted, interrupted, durationMs: 1000, numTurns: 1 });
  log(`stream: turn ${t} ended${interrupted ? ' (interrupted)' : ''}`);
}

const server = createServer((req, res) => {
  const url = new URL(req.url ?? '/', 'http://x');
  const num = (k: string, d: number) => Number(url.searchParams.get(k) ?? d) || d;
  const json = (o: unknown) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end(JSON.stringify(o)); };
  switch (url.pathname) {
    case '/health': return json({ ok: true, headSeq: events.length, clients: clients.size, streaming: !!streaming });
    case '/stream': return json({ started: startStream(num('chars', 20000), num('rate', 60), num('tools', 6)) });
    case '/stop': endStream(true); return json({ ok: true });
    case '/burst': {
      const n = num('events', 5000);
      turn++;
      emit({ type: 'turn_start', turn });
      for (let i = 0; i < n; i++) emit({ type: 'text_delta', turn, text: `${WORDS[i % WORDS.length]} ` });
      emit({ type: 'assistant', turn, text: Array.from({ length: n }, (_, i) => `${WORDS[i % WORDS.length]} `).join(''), toolUses: [] });
      emit({ type: 'turn_end', turn, subtype: 'success', isError: false, interrupted: false, durationMs: 1, numTurns: 1 });
      return json({ sent: n });
    }
    case '/diagnostics': return json(diagnostics);
    default: res.writeHead(404); res.end();
  }
});

const wss = new WebSocketServer({ noServer: true, maxPayload: 8 << 20 });
server.on('upgrade', (req, socket, head) => wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws)));
wss.on('connection', (ws: WebSocket) => {
  let device = '';
  const send = (o: unknown) => { if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(o)); };
  ws.on('close', () => { clients.delete(ws); if (device) log(`${device} disconnected`); });
  ws.on('message', (raw) => {
    let msg: Record<string, any>;
    try { msg = JSON.parse(String(raw)); } catch { return ws.close(4002, 'bad json'); }
    if (!device) {
      if (msg.type !== 'hello') return ws.close(4003, 'hello first');
      device = String(msg.device ?? 'device');
      const head = events.length;
      const reset = msg.lastSeq > head || msg.lastSeq < 0;
      const from = reset ? 0 : Number(msg.lastSeq) || 0;
      send({ type: 'welcome', protocol: 1, device, headSeq: head, replayFrom: from, reset, devices: [{ device, online: true, kind: msg.kind ?? 'ipad' }] });
      for (const e of events.slice(from)) send(e);
      send({ type: 'pty_list', terminals: [] });
      send({ type: 'replay_done', headSeq: head });
      clients.add(ws);
      log(`${device} connected, replayed ${head - from}`);
      return;
    }
    const ref = msg.ref ?? '';
    switch (msg.type) {
      case 'prompt': startStream(20000, 60, 6, String(msg.text ?? '')); break;
      case 'interrupt': endStream(true); break;
      case 'fs_list':
      case 'fs_read': {
        if (!root) break;
        const t0 = performance.now();
        (msg.type === 'fs_list' ? listDir(msg.path || root, root).then((listing) => ({ listing })) : readFile(msg.path, root).then((file) => ({ file })))
          .then((r) => send({ type: 'ack', ref, ok: true, ...r }), (e: Error) => send({ type: 'ack', ref, ok: false, error: e.message }))
          .finally(() => log(`${msg.type} ${msg.path ?? root} in ${Math.round(performance.now() - t0)} ms`));
        return;
      }
      case 'diagnostic': {
        const entry = { device, received: new Date().toISOString(), ...msg, payload: msg.payload ? `${String(msg.payload).length} chars` : undefined };
        diagnostics.push(entry);
        if (diagFile) appendFileSync(diagFile, JSON.stringify(entry) + '\n');
        log(`diagnostic from ${device}: ${msg.summary}`);
        break;
      }
    }
    if (ref) send({ type: 'ack', ref, ok: true });
  });
});

server.listen(port, '127.0.0.1', () => log(`on 127.0.0.1:${port}, ${events.length} events of history (${historyTurns} turns, ${events.filter((e) => e.type === 'diagram').length} diagrams)`));
