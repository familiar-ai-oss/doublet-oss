// duet-hub entry point.
//   node --experimental-strip-types src/main.ts                 run the hub
//   node --experimental-strip-types src/main.ts token add NAME  create a device token (printed once)
//   node --experimental-strip-types src/main.ts token rm NAME
import './localenv.ts';
import { existsSync, readFileSync, statSync } from 'node:fs';
import http from 'node:http';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { WebSocketServer, type WebSocket } from 'ws';
import { Apns } from './apns.ts';
import { checkUpgrade, Tokens } from './auth.ts';
import { Devices } from './devices.ts';
import { Dialogue, leadGuidance, TODO_TOOLS } from './dialogue.ts';
import { defaultFleetFile, Fleet, loadWorkers } from './fleet.ts';
import { droppedAtStart, Lead, leadAuth, leadEnv } from './lead.ts';
import { claudePath, claudeVersion, NO_CLAUDE, olderThan, sdkClaudeVersion } from './claude.ts';
import { LiveActivities } from './live.ts';
import { notesPrompt } from './notes.ts';
import { startWorkerProxy } from './proxy.ts';
import { Terminals, type Sink } from './pty.ts';
import { EFFORT_LEVELS, PROTOCOL_VERSION, type Annotation, type ClientMsg, type EffortLevel, type ServerFrame } from './protocol.ts';
import { EventLog, StateFile } from './store.ts';
import { Annotations } from './annotations.ts';
import { AppleDevices } from './apple.ts';
import { checkFolder, listDir, listFiles, readFile } from './fs.ts';
import { SideChats } from './sidechat.ts';
import { NoteQuestions, noteThread } from './questions.ts';
import { OutsideSessions, type OutsideSink } from './outside.ts';
import { RouteLog } from './routelog.ts';
import { Diagnostics, describeDiagnostics } from './diagnostics.ts';
import { fetchRules } from './web.ts';
import { PROFILE_IDS, type ProfileId } from './profiles.ts';
import { FolderWatch } from './watch.ts';
import { fullDiff } from './worker.ts';
import { EndpointStore } from './endpoints.ts';
import { isSettingsMsg, Settings } from './settings.ts';
import { McpGateway } from './agents/mcp-gateway.ts';
import { CodexAdapter } from './agents/codex.ts';
import { AcpAdapter, CURSOR_ACP } from './agents/acp.ts';
import { AcpAside, CodexAside } from './agents/aside.ts';

const env = process.env;
const cfg = {
  port: Number(env.DUET_PORT || 7811),
  stateDir: env.DUET_STATE_DIR || join(homedir(), '.local/state/duet'),
  tokenFile: env.DUET_TOKENS || join(homedir(), '.config/duet/tokens.json'),
  allowedLogins: (env.DUET_ALLOWED_LOGINS || '').split(',').map((s) => s.trim()).filter(Boolean),
  model: env.DUET_LEAD_MODEL || 'claude-opus-5-5',
  effort: (env.DUET_LEAD_EFFORT || 'high') as EffortLevel,
  cwd: env.DUET_PROJECT_DIR || homedir(),
  // llmd, a model server that swaps models on the GPUs (optional): its admin URL, its models.toml (which GPU each
  // model lives on), and the models that take every GPU when loaded.
  llmdAdmin: env.DUET_LLMD_ADMIN || '',
  modelsToml: env.DUET_MODELS_TOML || '',
  llmdClaimsAll: (env.DUET_LLMD_CLAIMS_ALL || '').split(',').map((s) => s.trim()).filter(Boolean),
  fleetFile: env.DUET_FLEET || defaultFleetFile(),
  proxyPort: Number(env.DUET_PROXY_PORT || 0),
  // Live Activity pushes: a token-based APNs key (.p8) and its key id, from env or ~/.config/duet/apns.json.
  apnsKeyFile: env.DUET_APNS_KEY_FILE || join(homedir(), '.config/duet/apns.p8'),
  apnsFile: join(homedir(), '.config/duet/apns.json'),
};

const log = (msg: string) => process.stderr.write(`${new Date().toISOString()} ${msg}\n`);
const tokens = new Tokens(cfg.tokenFile);

// The user's own Claude Code, which the lead, side chats and workers all run.
function checkClaude(): void {
  const path = claudePath();
  if (!path) {
    log(NO_CLAUDE);
    return;
  }
  const have = claudeVersion(), want = sdkClaudeVersion();
  log(`claude: ${path} (${have ?? 'version unknown'}, sign-in: ${leadAuth() === 'any' ? 'whatever Claude Code uses' : `DUET_LEAD_AUTH=${leadAuth()}`})`);
  if (have && want && olderThan(have, want)) log(`claude ${have} is older than the ${want} this hub is built for: run \`claude update\``);
}

if (process.argv[2] === 'token') {
  const [, , , op, name] = process.argv;
  if (op === 'add' && name) console.log(tokens.add(name));
  else if (op === 'rm' && name) console.log(tokens.remove(name) ? 'removed' : 'no such device');
  else console.error('usage: token add|rm <device>');
  process.exit(0);
}
// The devices' crash and freeze reports, newest last: `diagnostics [count]`.
if (process.argv[2] === 'diagnostics') {
  const n = Number(process.argv[3] ?? 20) || 20;
  const d = new Diagnostics(cfg.stateDir);
  console.log(describeDiagnostics(d.list().slice(-n)) || 'no reports');
  console.log(`(${d.dir})`);
  process.exit(0);
}

checkClaude();
const events = new EventLog(cfg.stateDir);
const state = new StateFile(cfg.stateDir);
// The folder Claude was last moved to, if it's still there; else the configured one.
const savedCwd = state.read().cwd;
const startCwd = savedCwd && existsSync(savedCwd) && statSync(savedCwd).isDirectory() ? savedCwd : cfg.cwd;
const lastTurn = events.since(0).reduce((t, e) => ('turn' in e && typeof e.turn === 'number' ? Math.max(t, e.turn) : t), 0);
// Apple workers: connected devices' on-device models. They're the user's (by @mention); Claude only hands them work
// with DUET_APPLE_FOR_LEAD=1, since local workers are free too and far stronger.
const apple = new AppleDevices(log);
const appleForLead = env.DUET_APPLE_FOR_LEAD === '1';
// OpenAI-compatible endpoints added in Settings, kept in the state folder. They join the fleet file's workers (or, with
// no fleet file, stand in for the default Ollama worker).
const endpoints = new EndpointStore(cfg.stateDir);
// Workers reach their backends only through this proxy; the fleet decides each request's route.
let fleet: Fleet;
const proxy = await startWorkerProxy((w) => fleet.route(w), (s) => fleet.recordRequest(s), cfg.proxyPort);
fleet = new Fleet(
  {
    workers: loadWorkers(cfg.fleetFile, { hasEndpoints: endpoints.list().length > 0 }),
    llmdAdmin: cfg.llmdAdmin,
    modelsToml: cfg.modelsToml,
    claimsAllDevices: cfg.llmdClaimsAll,
    defaultCwd: startCwd,
    proxyBaseUrl: proxy.baseUrl,
    log,
    apple,
    appleForLead,
    // Bound late: tasks start well after the lead exists.
    currentConversation: () => lead.conversationId,
  },
  (b) => events.append(b),
);

// Kinds of Claude subagent that ran before keep their place in the fleet. Any still running stopped with the hub.
fleet.seedSubagents(events.since(0).flatMap((e) => (e.type === 'task' && e.worker.startsWith('claude-') ? [e.worker] : [])));
fleet.endOrphans(events.since(0));

// Every connected device's sender, for frames that go to all of them (the endpoints, as Settings changes them).
const clients = new Set<(f: ServerFrame) => void>();
const settings = new Settings(endpoints, fleet, (f) => { for (const c of clients) c(f); });
settings.sync();

const dialogue = new Dialogue((b) => events.append(b));
dialogue.appleForLead = appleForLead;
dialogue.seedDiagrams(events.since(0).flatMap((e) => (e.type === 'diagram' ? [{ id: e.id, version: e.version }] : [])));
dialogue.seedPlans(events.since(0).flatMap((e) => (e.type === 'plan' ? [{ conversationId: e.conversationId, steps: e.steps }] : [])));

// Lock Screen pushes need an APNs key; without one, apps still update their own Live Activity while they run.
function loadApns(): Apns | null {
  let file: { keyId?: string; teamId?: string; bundleId?: string } = {};
  try {
    if (existsSync(cfg.apnsFile)) file = JSON.parse(readFileSync(cfg.apnsFile, 'utf8'));
  } catch (e) {
    log(`live activity pushes off: ${cfg.apnsFile} isn't valid JSON (${e instanceof Error ? e.message : e})`);
    return null;
  }
  const keyId = env.DUET_APNS_KEY_ID || file.keyId;
  if (!keyId || !existsSync(cfg.apnsKeyFile)) {
    log('live activity pushes off: no APNs key (see docs/deploy.md)');
    return null;
  }
  const teamId = env.DUET_APNS_TEAM_ID || file.teamId;
  const bundleId = env.DUET_APNS_BUNDLE || file.bundleId;
  if (!teamId || !bundleId) {
    log('live activity pushes off: set DUET_APNS_TEAM_ID and DUET_APNS_BUNDLE (hub/local.env) or teamId and bundleId in apns.json');
    return null;
  }
  log(`live activity pushes on: key ${keyId}, team ${teamId}, ${bundleId}`);
  return new Apns({ keyFile: cfg.apnsKeyFile, keyId, teamId, bundleId }, log);
}
const apns = loadApns();
// The user's devices: which have the app connected now, when each was last seen, and places sent between them.
const devices = new Devices(join(cfg.stateDir, 'devices.json'), () => tokens.names(), log);
const live = new LiveActivities(join(cfg.stateDir, 'live.json'), apns, log, { connected: (d) => devices.online(d) });
for (const e of events.since(0)) live.status.apply(e);
events.subscribe(events.headSeq, (e) => live.onEvent(e));
// Handwritten notes, kept with what they were written on and Claude's answer.
const annotations = new Annotations(cfg.stateDir, (b) => events.append(b));
annotations.seed(events.since(0));
events.subscribe(events.headSeq, (e) => annotations.onEvent(e));
// DUET_MCP_TRANSPORT=http or stdio: Claude reaches Doublet's tools through the gateway other agents use, instead of
// in-process (to check both give it the same tools). Unset: in-process.
const mcpTransport = process.env.DUET_MCP_TRANSPORT === 'http' || process.env.DUET_MCP_TRANSPORT === 'stdio' ? process.env.DUET_MCP_TRANSPORT : null;
// DUET_LEAD_AGENT=codex or cursor: that agent leads instead of Claude Code (until the app picks the lead per
// conversation), with Doublet's tools through the gateway. DUET_LEAD_MODEL is then one of its models.
const LEAD_AGENTS = ['claude', 'codex', 'cursor'] as const;
const leadAgent = (LEAD_AGENTS as readonly string[]).includes(process.env.DUET_LEAD_AGENT ?? '') ? process.env.DUET_LEAD_AGENT as typeof LEAD_AGENTS[number] : 'claude';
const mcpGateway = mcpTransport || leadAgent !== 'claude' ? new McpGateway(log) : null;
if (mcpGateway) log(`Doublet's tools for the ${leadAgent} lead: over ${mcpTransport ?? 'http'}, gateway on 127.0.0.1:${await mcpGateway.listen()}`);
const lead = new Lead(
  {
    model: cfg.model,
    effort: cfg.effort,
    cwd: startCwd,
    // Reading, searching the web and opening documentation pages never wait for an approval; anything else does.
    autoAllow: ['Read', 'Glob', 'Grep', 'mcp__duet', 'WebSearch', ...fetchRules()],
    // The duet plan is Claude's one checklist (it shows beside the conversation, with each step's worker and task).
    disallowedTools: TODO_TOOLS,
    log,
    mcpServers: () => ({ duet: dialogue.leadServer() }),
    hooks: dialogue.leadHooks(),
    ...(mcpGateway && mcpTransport ? { mcpGateway: { gateway: mcpGateway, transport: mcpTransport } } : {}),
    ...(leadAgent !== 'claude' && mcpGateway ? (() => {
      const extras = { mcpServers: () => ({ duet: dialogue.leadServer() }), gateway: mcpGateway, instructions: () => leadGuidance(dialogue.appleForLead) };
      return { adapter: leadAgent === 'codex' ? new CodexAdapter(extras) : new AcpAdapter(CURSOR_ACP, extras) };
    })() : {}),
    onTurnStart: () => dialogue.onLeadTurnStart(),
    onIdle: () => { dialogue.onLeadIdle(); void continueWaiting(); },
    onNotesTaken: (ids, turn) => annotations.taken(ids, turn),
    onUserWaiting: () => dialogue.userWrote(),
    subagents: {
      start: (id, kind, prompt, info) => fleet.subagentStart(id, kind, prompt, info),
      progress: (id, p) => fleet.subagentProgress(id, p),
      isSubagent: (id) => fleet.isSubagent(id),
      background: (id) => fleet.subagentBackground(id),
      // A call the hub turned away (to a local worker, or until there's a plan) never ran: cancelled, not failed.
      end: (id, state, result, outcome) => fleet.subagentEnd(id, dialogue.wasTurnedAway(id) ? 'cancelled' : state, result, outcome),
      stopped: (all) => fleet.subagentsStopped(all),
    },
  },
  (b) => events.append(b),
  state,
  lastTurn,
);
// Every event belongs to the live conversation unless its emitter says otherwise.
events.conversation = () => lead.conversationId;
// Prompts the hub held for Claude went with the last run (the queue lives in memory): their rows say so.
for (const e of droppedAtStart(events.since(0))) events.append(e);
dialogue.attach(fleet, {
  busy: () => lead.busyNow, submit: (text, by) => lead.submit(text, by), conversation: () => lead.conversationId,
  userWaiting: () => lead.userWaiting(),
});
fleet.setBridge({
  extras: (taskId, worker) => ({ mcpServers: { duet: dialogue.workerServer(taskId, worker) }, hooks: dialogue.workerHooks(taskId) }),
  onTaskEnd: (taskId, worker, st, result, ev, output, stopped, tools) => dialogue.onTaskEnd(taskId, worker, st, result, ev, output, stopped, tools),
});

// Questions on notes and in side chats: a local model answers first when it's about the code, and its citations are
// checked; Claude answers what needs judgment, and what a local answer couldn't settle (routing.ts, scout.ts).
const routeLog = new RouteLog(cfg.stateDir, log);
const diagnostics = new Diagnostics(cfg.stateDir, log);
const askLocal = (prompt: string, size: 'small' | 'large', by: string, onTask?: (taskId: string) => void) =>
  fleet.ask('auto', prompt, by, { cwd: lead.cwd, profile: 'explore', size }, onTask)
    .then((a) => ({ ok: a.state === 'done', result: a.result, worker: a.worker, taskId: a.taskId, error: a.error }))
    .catch((e: unknown) => ({ ok: false, result: '', worker: '', error: e instanceof Error ? e.message : String(e) }));
/** A diagram's title and source as last drawn: what a thread about one of its elements is about. Rare, so it reads the log. */
const diagramOf = (id: string) => {
  const all = events.since(0);
  for (let i = all.length - 1; i >= 0; i--) {
    const e = all[i];
    if (e.type === 'diagram' && e.id === id) return { title: e.title, source: e.source };
  }
  return undefined;
};
/** A note's thread, opened if it has none yet: a side chat that continues the note (its question, and its answer if it has one). */
const openThread = (a: Annotation): string => {
  if (a.chatId && sides.has(a.chatId)) return a.chatId;
  const chatId = sides.thread(noteThread(a, annotations.conversationOf(a.id), diagramOf));
  annotations.thread(a.id, chatId);
  return chatId;
};
const questions = new NoteQuestions({
  annotations,
  ask: (sel, prompt, by, opts) => fleet.ask(sel, prompt, by, opts),
  threads: { open: openThread, busy: (chatId) => sides.busy(chatId), claude: (chatId, text, o) => sides.answerNote(chatId, text, o) },
  notice: (text) => lead.notice(text),
  cwd: () => lead.cwd,
  routes: routeLog,
  log,
});

// Side chats: quick questions beside the conversation, answered in a copy of it (read-only), or by a local model.
/** The live conversation as text, for an agent that can't copy it (an ACP agent's side chats): its last prompts and
 *  replies, newest last, at most 30,000 characters. */
function transcript(): string {
  const id = lead.conversationId;
  const lines = events.since(0).flatMap((e) => {
    if (e.conversationId !== id) return [];
    if (e.type === 'user' && e.text) return [`User: ${e.text}`];
    if (e.type === 'assistant' && e.text.trim()) return [`You: ${e.text.trim()}`];
    return [];
  });
  return lines.slice(-80).join('\n\n').slice(-30_000);
}
// Side chats and notes' answers come from the lead's own agent.
const aside = leadAgent === 'codex' ? new CodexAside({ model: () => cfg.model, gateway: mcpGateway ?? undefined, log })
  : leadAgent === 'cursor' ? new AcpAside(CURSOR_ACP, { model: () => cfg.model, readOnlyMode: 'ask', gateway: mcpGateway ?? undefined, log })
  : undefined;
const sides = new SideChats({
  source: () => ({ sessionId: lead.conversationId, transcribed: lead.transcribed, busy: lead.busyNow, cwd: lead.cwd, transcript }), env: leadEnv, log,
  ...(aside ? { aside } : {}),
  local: {
    ask: (prompt, size, by, onTask) => askLocal(prompt, size, by, onTask),
    free: (size) => fleet.idleLocal().some((w) => size === 'small' || w.takes === 'any'),
    cancel: (taskId) => { try { fleet.cancel(taskId, 'duet'); } catch { /* already ended */ } },
  },
  routes: routeLog,
  diagrams: (drawn) => dialogue.diagramServer(drawn),
}, (b) => events.append(b));
// Claude Code sessions started outside Duet on this machine: listed live, followed live, continued here (outside.ts).
const outside = new OutsideSessions({ ours: (id) => id === lead.conversationId, log, programmatic: process.env.DUET_OUTSIDE_PROGRAMMATIC === '1' });
outside.start();
/** How many of an outside session's last messages come along when it's continued here. */
const IMPORTED = 40;
sides.seed(events.since(0));

const terminals = new Terminals(startCwd, log);

// What a device asks over plain HTTP, with its token, when it has no WebSocket: the Lock Screen's Approve and
// Reject buttons (an App Intent), and a Live Activity's token from a background launch.
const routes: Record<string, (device: string, body: Record<string, unknown>) => void> = {
  '/api/decide': (device, body) => {
    const id = typeof body.id === 'string' ? body.id : '';
    if (!id) throw new Error('no approval id');
    if (body.decision === 'allow') lead.approve(id, device);
    else if (body.decision === 'deny') lead.reject(id, device, typeof body.message === 'string' ? body.message : undefined);
    else throw new Error('decision must be allow or deny');
    log(`${device} decided ${id} (${body.decision}) from its Live Activity`);
  },
  '/api/live': (device, body) => {
    const env = body.environment === 'production' ? 'production' : 'development';
    const str = (v: unknown) => (typeof v === 'string' && v ? v : undefined);
    live.register(device, { token: str(body.token), startToken: str(body.startToken), env });
  },
};

async function deviceRequest(req: http.IncomingMessage, res: http.ServerResponse, route: (device: string, body: Record<string, unknown>) => void): Promise<void> {
  const reply = (status: number, body: object) => res.writeHead(status, { 'content-type': 'application/json' }).end(JSON.stringify(body));
  const device = String(req.headers['x-duet-device'] ?? '');
  const token = String(req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
  if (checkUpgrade(req, cfg.allowedLogins) || !tokens.verify(device, token)) return void reply(403, { ok: false, error: 'not allowed' });
  let raw = '';
  for await (const chunk of req) {
    raw += chunk;
    if (raw.length > 64 << 10) return void reply(413, { ok: false, error: 'too large' });
  }
  let body: Record<string, unknown>;
  try { body = JSON.parse(raw); } catch { return void reply(400, { ok: false, error: 'bad json' }); }
  try {
    route(device, body ?? {});
    reply(200, { ok: true });
  } catch (e) {
    // Most often: already decided, on another device or by a second tap.
    reply(409, { ok: false, error: e instanceof Error ? e.message : String(e) });
  }
}

const server = http.createServer((req, res) => {
  const route = req.method === 'POST' ? routes[req.url ?? ''] : undefined;
  if (route) {
    void deviceRequest(req, res, route);
    return;
  }
  if (req.url === '/health') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, headSeq: events.headSeq, turn: lead.currentTurn, busy: lead.busyNow, conversation: lead.conversationId, fleet: fleet.snapshot(), dialogue: dialogue.snapshot() }));
    return;
  }
  res.writeHead(404).end();
});

// Notes carry a picture of the annotated diagram, so messages can be a few megabytes.
const wss = new WebSocketServer({ noServer: true, maxPayload: 8 << 20 });
server.on('upgrade', (req, socket, head) => {
  const deny = new URL(req.url ?? '/', 'http://x').pathname !== '/ws' ? 'bad path' : checkUpgrade(req, cfg.allowedLogins);
  if (deny) {
    log(`upgrade refused: ${deny}`);
    socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => onConnection(ws, req.headers['tailscale-user-login'] as string | undefined));
});

/** A session from outside Duet asked to be continued while a turn ran here: continued when the lead goes idle. */
let waitingContinue: { sessionId: string; by: string } | null = null;

/** Continued here as the conversation: a fork while it still runs there, the session itself once it has ended. Its
 *  last messages come along, shown at the start of this conversation. */
async function continueOutside(sessionId: string, by: string) {
  const messages = await outside.recent(sessionId, IMPORTED);
  const c = await outside.continueAs(sessionId);
  await lead.resume(c.sessionId, by);
  events.append({ type: 'conversation_import', from: c.from, forked: c.forked, messages });
  outside.continued(sessionId);
  return c;
}

async function continueWaiting(): Promise<void> {
  const w = waitingContinue;
  if (!w || lead.busyNow) return;
  waitingContinue = null;
  try {
    await continueOutside(w.sessionId, w.by);
  } catch (e) {
    events.append({ type: 'notice', text: `Couldn't continue that session here: ${e instanceof Error ? e.message : e}` });
  }
}

const MAX_BUFFERED = 8 << 20;

function onConnection(ws: WebSocket, login: string | undefined): void {
  let device: string | null = null;
  let unsubscribe = () => {};
  let alive = true;
  const send = (f: ServerFrame) => {
    if (ws.readyState !== ws.OPEN) return;
    // A client this far behind resumes from its lastSeq instead of buffering without bound.
    if (ws.bufferedAmount > MAX_BUFFERED) return ws.terminate();
    ws.send(JSON.stringify(f));
  };
  const helloTimer = setTimeout(() => !device && ws.close(4001, 'hello timeout'), 10_000);
  const ping = setInterval(() => {
    if (!alive) return ws.terminate();
    alive = false;
    ws.ping();
  }, 15_000);
  ws.on('pong', () => (alive = true));
  // Terminal output goes only to clients attached to that terminal, as unsequenced frames.
  const sink: Sink = { data: (id, data) => send({ type: 'pty_data', id, data }), exit: (id, code) => send({ type: 'pty_exit', id, code }) };
  // The folders this client's explorer shows: a change in one is sent to it, and it lists that folder again.
  const folders = new FolderWatch((path) => send({ type: 'fs_changed', path }));
  // Sessions running outside Duet: the list, and the messages of those this client follows.
  const outsideSink: OutsideSink = {
    sessions: (sessions) => send({ type: 'outside_sessions', sessions }),
    messages: (sessionId, messages) => send({ type: 'outside_messages', sessionId, messages }),
  };
  let detachOutside = () => {};
  ws.on('close', () => {
    clearTimeout(helloTimer);
    clearInterval(ping);
    unsubscribe();
    terminals.detachAll(sink);
    folders.close();
    detachOutside();
    clients.delete(send);
    if (device) {
      apple.disconnected(device, send);
      devices.disconnected(device, send);
      log(`${device} disconnected`);
    }
  });

  ws.on('message', async (raw) => {
    let msg: ClientMsg;
    try { msg = JSON.parse(String(raw)); } catch { return ws.close(4002, 'bad json'); }

    if (!device) {
      if (msg.type !== 'hello') return ws.close(4003, 'hello first');
      if (msg.protocol !== PROTOCOL_VERSION) { send({ type: 'fatal', error: `protocol ${msg.protocol} unsupported; hub speaks ${PROTOCOL_VERSION}` }); return ws.close(4004); }
      if (!tokens.verify(msg.device, msg.token)) { send({ type: 'fatal', error: 'bad device token' }); return ws.close(4005, 'auth'); }
      device = msg.device;
      clients.add(send);
      devices.connected(device, send, msg.kind);
      // A client ahead of the log saw a previous hub's log; start it over from the beginning.
      const reset = msg.lastSeq > events.headSeq || msg.lastSeq < 0;
      const from = reset ? 0 : msg.lastSeq;
      const sub = events.subscribe(from, (e) => send(e));
      unsubscribe = sub.unsubscribe;
      send({ type: 'welcome', protocol: PROTOCOL_VERSION, device, headSeq: events.headSeq, replayFrom: from, reset, devices: devices.list() });
      for (const e of sub.backlog) send(e);
      // Live terminals before replay_done, so a client knows them by the time it counts as connected.
      send({ type: 'pty_list', terminals: terminals.list() });
      detachOutside = outside.attach(outsideSink);
      send({ type: 'replay_done', headSeq: events.headSeq });
      // A place sent here while it was away, now that it has caught up.
      devices.deliverWaiting(device, send);
      log(`${device} connected${login ? ` as ${login}` : ''}, replayed ${sub.backlog.length} from ${from}`);
      return;
    }

    const by = device;
    const ref = ('ref' in msg && msg.ref) || '';
    try {
      if (isSettingsMsg(msg)) {
        send({ type: 'ack', ref, ok: true, ...await settings.handle(msg) });
        return;
      }
      switch (msg.type) {
        case 'prompt':
          if (!msg.text?.trim()) throw new Error('empty prompt');
          dialogue.onUserMessage();
          lead.submit(msg.text, by, msg.boost === true, { voice: msg.voice === true });
          break;
        case 'approve':
          lead.approve(msg.id, by, msg.updatedInput);
          break;
        case 'reject':
          lead.reject(msg.id, by, msg.message);
          break;
        case 'interrupt':
          await lead.interrupt(by);
          break;
        case 'set_effort':
          if (msg.level !== null && !EFFORT_LEVELS.includes(msg.level)) throw new Error(`unknown effort ${msg.level}`);
          await lead.setEffort(msg.level, by);
          break;
        case 'delegate': {
          const profile = msg.profile?.trim() || undefined;
          if (profile && !(PROFILE_IDS as readonly string[]).includes(profile)) throw new Error(`unknown profile ${profile} (${PROFILE_IDS.join(', ')})`);
          const r = dialogue.delegate(by, msg.worker, msg.prompt, { cwd: msg.cwd, effort: msg.effort, files: msg.files, profile: profile as ProfileId | undefined });
          if (r.refused) throw new Error(r.refused);
          const taskId = r.taskId;
          send({ type: 'ack', ref, ok: true, taskId });
          return;
        }
        case 'cancel_task':
          dialogue.cancel(by, msg.taskId);
          break;
        case 'answer': {
          const refused = dialogue.answer(by, msg.questionId, msg.text);
          if (refused) throw new Error(refused);
          break;
        }
        case 'steer': {
          const refused = dialogue.steer(by, msg.taskId, msg.text);
          if (refused) throw new Error(refused);
          break;
        }
        case 'set_pause':
          dialogue.setPaused(msg.paused);
          break;
        case 'clear':
          await lead.clear(by);
          break;
        case 'resume_session': {
          // Resuming may move Claude back to that conversation's folder; shells and worker tasks follow.
          const before = lead.cwd;
          await lead.resume(msg.sessionId, by);
          if (lead.cwd !== before) { fleet.setDefaultCwd(lead.cwd); terminals.setCwd(lead.cwd); }
          break;
        }
        case 'annotation_update': {
          // "Ask Claude" about a note a local model answered.
          if (msg.reroute === 'claude') {
            questions.reroute(msg.id, by);
            break;
          }
          // A deleted note takes its thread with it.
          const thread = msg.delete ? annotations.get(msg.id)?.chatId : undefined;
          annotations.update(msg.id, { status: msg.status, delete: msg.delete });
          if (thread) sides.remove(thread);
          break;
        }
        case 'note_reply': {
          // A reply to a note goes on in its thread: a side chat that starts with the note's question and answer.
          const a = annotations.get(msg.id);
          if (!a) throw new Error(`no note ${msg.id}`);
          if (!msg.text?.trim() && !msg.image) throw new Error('empty reply');
          if (a.status === 'open' && !(a.chatId && sides.has(a.chatId))) throw new Error('the note is still being answered; reply once it is');
          const chatId = openThread(a);
          sides.ask(by, { chatId, text: msg.text ?? '', image: msg.image ? { data: msg.image, type: msg.imageType ?? 'image/png' } : undefined });
          send({ type: 'ack', ref, ok: true, chatId });
          return;
        }
        case 'annotation_ink':
          send({ type: 'ack', ref, ok: true, image: annotations.ink(msg.id) });
          return;
        case 'fs_list':
          send({ type: 'ack', ref, ok: true, listing: await listDir(msg.path || lead.cwd, lead.cwd) });
          return;
        case 'fs_read':
          send({ type: 'ack', ref, ok: true, file: await readFile(msg.path, lead.cwd) });
          return;
        case 'set_cwd': {
          const dir = await checkFolder(msg.path, lead.cwd);
          await lead.setCwd(dir, by);
          fleet.setDefaultCwd(dir);
          terminals.setCwd(dir);
          break;
        }
        case 'compact':
          lead.compact(by);
          break;
        case 'set_model':
          await lead.setModel(msg.model, by);
          break;
        case 'set_permission_mode':
          await lead.setPermissionMode(msg.mode, by);
          break;
        case 'broadcast': {
          // @all: the lead gets it as a prompt, and every running worker gets it as a STEER.
          if (!msg.text?.trim()) throw new Error('empty message');
          dialogue.onUserMessage();
          lead.submit(msg.text, by);
          // An Apple worker can't take a message mid-task.
          for (const w of fleet.snapshot()) if (w.running && w.backend !== 'apple') dialogue.steer(by, w.running, msg.text);
          break;
        }
        case 'pty_open': {
          const ptyId = terminals.open(msg.kind, msg.cols, msg.rows, sink, by, msg.cwd ? await checkFolder(msg.cwd, lead.cwd) : undefined);
          send({ type: 'ack', ref, ok: true, ptyId });
          return;
        }
        case 'pty_attach':
          terminals.attach(msg.id, sink);
          break;
        case 'pty_input':
          terminals.input(msg.id, msg.data);
          break;
        case 'pty_resize':
          terminals.resize(msg.id, msg.cols, msg.rows);
          break;
        case 'pty_close':
          terminals.close(msg.id);
          break;
        case 'apple_status':
          apple.status(by, send, { available: msg.available === true, reason: msg.reason, variant: msg.variant, contextSize: msg.contextSize, capabilities: msg.capabilities, platform: msg.platform, simulator: msg.simulator });
          break;
        case 'apple_progress':
          apple.progress(by, msg.taskId, String(msg.text ?? ''));
          break;
        case 'apple_done':
          apple.done(by, msg.taskId, { ok: msg.ok === true, result: msg.result ?? '', error: msg.error, stats: msg.stats });
          break;
        case 'set_worker':
          fleet.setWorker(msg.worker, { effort: msg.effort, temperature: msg.temperature, enabled: msg.enabled, model: msg.model });
          break;
        case 'approve_swap':
          fleet.resolveSwap(msg.id, true, by);
          break;
        case 'notes': {
          if (!msg.items?.length) throw new Error('no notes');
          if (msg.surface?.kind === 'plan') {
            if (typeof msg.surface.conversationId !== 'string') throw new Error("a note on a plan needs the plan's conversation");
            // Redirecting the work is for the plan being worked on; a question about an earlier one is still answered.
            if (msg.surface.conversationId !== lead.conversationId && msg.items.some((n) => n.intent !== 'question')) {
              throw new Error("that plan is from an earlier conversation; continue that conversation to change its plan");
            }
          }
          // Kept as annotations (with their handwriting); the handwriting isn't sent on to Claude or the log.
          annotations.add(by, msg.surface, msg.items);
          const items = msg.items.map(({ ink: _ink, ...n }) => n);
          // Notes on a running worker's diff steer that worker.
          const task = msg.surface.kind === 'diff' ? fleet.taskInfo(msg.surface.taskId) : undefined;
          if (task && ['queued', 'running', 'awaiting_swap'].includes(task.state)) {
            const refused = dialogue.steer(by, msg.surface.kind === 'diff' ? msg.surface.taskId : '', notesPrompt(by, { surface: msg.surface, items, hasImage: !!msg.image }));
            if (refused) throw new Error(refused);
            break;
          }
          // Questions about a file's code: a local model answers first. Other questions: Claude, in each note's thread,
          // with the picture. Notes asking for work: Claude, in the conversation, which acts on them.
          const image = msg.image ? { data: msg.image, type: msg.imageType ?? 'image/png' as const } : undefined;
          const local = questions.local(msg.surface, items);
          for (const n of local) void questions.answer(by, msg.surface, n);
          questions.direct(by, items.filter((n) => n.intent === 'question' && !local.includes(n)), image);
          const work = items.filter((n) => n.intent !== 'question');
          if (work.length) {
            const notes = { surface: msg.surface, items: work, hasImage: !!msg.image };
            dialogue.onUserMessage();
            lead.addNotes(by, notes, notesPrompt(by, notes), image);
          }
          break;
        }
        case 'task_diff': {
          const cwd = fleet.taskCwd(msg.taskId);
          if (!cwd) throw new Error(`unknown task ${msg.taskId}`);
          const d = await fullDiff(cwd);
          if (d.error) throw new Error(d.error);
          send({ type: 'ack', ref, ok: true, diff: d.diff, truncated: d.truncated });
          return;
        }
        case 'live_activity':
          live.register(by, { token: msg.token, startToken: msg.startToken, env: msg.environment });
          send({ type: 'ack', ref, ok: true, error: live.enabled ? undefined : 'the hub has no APNs key yet, so it cannot push updates' });
          return;
        case 'live_activity_end':
          live.forget(by);
          break;
        case 'side_ask': {
          const chatId = sides.ask(by, { chatId: msg.chatId, text: msg.text ?? '', about: msg.about, model: msg.model, image: msg.image ? { data: msg.image, type: msg.imageType ?? 'image/png' } : undefined, voice: msg.voice === true });
          send({ type: 'ack', ref, ok: true, chatId });
          return;
        }
        case 'side_reroute':
          sides.reroute(by, msg.chatId);
          break;
        case 'send_place': {
          const r = devices.sendPlace(by, msg.to, msg.place, msg.title, msg.write);
          send({ type: 'ack', ref, ok: true, ...(r.queued ? { queued: true } : {}) });
          return;
        }
        case 'place_seen':
          devices.seen(by, msg.id);
          break;
        case 'open_places':
          devices.report(by, msg.places, msg.current, send);
          break;
        case 'side_stop':
          sides.stop(msg.chatId);
          break;
        case 'side_title':
          sides.retitle(msg.chatId, msg.title);
          break;
        case 'diagnostic':
          diagnostics.add(by, msg);
          break;
        case 'outside_follow': {
          const r = await outside.follow(outsideSink, msg.sessionId);
          send({ type: 'ack', ref, ok: true, ...(r.session ? { session: r.session } : {}), messages: r.messages });
          return;
        }
        case 'outside_unfollow':
          outside.unfollow(outsideSink, msg.sessionId);
          break;
        case 'outside_continue': {
          // While a turn runs here (or waits on an approval), it's continued the moment that turn ends, not refused.
          if (lead.busyNow) {
            const name = outside.list().find((x) => x.sessionId === msg.sessionId)?.name ?? 'that session';
            waitingContinue = { sessionId: msg.sessionId, by };
            lead.notice(`[duet] ${by} asked to continue "${name}" here; it takes over once this turn ends.`);
            events.append({ type: 'notice', text: `"${name}" continues here once Claude's current turn ends.` });
            send({ type: 'ack', ref, ok: true, queued: true });
            return;
          }
          const c = await continueOutside(msg.sessionId, by);
          send({ type: 'ack', ref, ok: true, sessionId: c.sessionId, forked: c.forked });
          return;
        }
        case 'fs_watch':
          folders.set(Array.isArray(msg.paths) ? msg.paths : []);
          break;
        case 'fs_files':
          send({ type: 'ack', ref, ok: true, files: await listFiles(msg.path || lead.cwd, lead.cwd) });
          return;
        case 'reject_swap':
          fleet.resolveSwap(msg.id, false, by);
          break;
        default:
          throw new Error(`unknown message type ${(msg as { type: string }).type}`);
      }
      send({ type: 'ack', ref, ok: true });
    } catch (err) {
      send({ type: 'ack', ref, ok: false, error: err instanceof Error ? err.message : String(err) });
    }
  });
}

server.listen(cfg.port, '127.0.0.1', () => log(`duet-hub on 127.0.0.1:${cfg.port}, state ${cfg.stateDir}, head seq ${events.headSeq}`));
// Without a lead the hub is useless; exit and let systemd retry (and show the reason in the log).
apple.onChange = () => fleet.syncApple();
void fleet.start();
lead.start().catch((e) => {
  log(`lead failed to start: ${e}`);
  process.exit(1);
});

const shutdown = async () => {
  log('shutting down');
  fleet.stop();
  sides.stopAll();
  outside.stop();
  terminals.closeAll();
  await lead.stop();
  await proxy.close();
  apns?.close();
  wss.clients.forEach((c) => c.close(1001, 'hub shutting down'));
  server.close();
  setTimeout(() => process.exit(0), 500);
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
