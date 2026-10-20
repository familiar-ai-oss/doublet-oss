// Fleet scheduler: workers with one slot each and a FIFO queue, availability from llmd, Ollama and OpenAI-compatible
// endpoints, and a confirmation step before any task that would load a model onto a GPU (which evicts what's there).
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { appleLabel, appleReason, type AppleDevices } from './apple.ts';
import { homedir } from 'node:os';
import { isAbsolute, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { EFFORT_TABLES, tableForModel, validLevel, VERIFIED_EFFORT, type EffortTableId } from './effort.ts';
import { PROFILES, type ProfileId } from './profiles.ts';
import type { AppleStats, CatalogModel, EventBody, TaskStats, ToolCall, WorkerView } from './protocol.ts';
import type { SubagentInfo, SubagentOutcome } from './lead.ts';
import type { RequestStats, Route } from './proxy.ts';
import { evidence, runWorker, type ToolCount, type WorkerRun } from './worker.ts';
import { servedContext, tomlContexts } from './context.ts';
import { listModels } from './endpoints.ts';

export type WorkerDef = {
  id: string;
  label: string;
  // apple: a connected device's on-device model (added and removed as devices report it, never configured).
  // claude: one kind of Claude's own subagents (its Agent tool), added when Claude first starts one.
  // openai: an OpenAI-compatible server (chat completions with tool calls); url is its base URL, ending in /v1. Added
  // in Settings (endpoints.ts) or in a fleet file.
  backend: 'llmd' | 'ollama' | 'apple' | 'claude' | 'openai';
  url: string; // backend base URL
  model: string; // llmd served id, Ollama model name, or the model an OpenAI-compatible server lists
  apiKey?: string; // openai: sent as a bearer token; never shown to clients
  table: EffortTableId;
  enabled: boolean;
  temperature?: number;
  device?: string; // apple: the device that runs it
  // The tasks `auto` gives it: any, or only small ones. Unset: from its model's size (see takes()).
  takes?: 'any' | 'small';
  // The model's window in tokens, when its server can't be asked, or to try a smaller one. Normally unset: the running
  // server says (context.ts).
  context?: number;
  // At most this many turns a task, under its profile's own limit. Normally unset.
  maxTurns?: number;
};

/** How big a task is, for `auto`: small and mechanical (a rename, a docstring, one test), or anything else. */
export type TaskSize = 'small' | 'large';

/** The tasks auto gives a worker: its `takes`, else "small" for a model under 15B by its name (qwen3.5-9b,
 *  Ornith-1.5-9B), else any. A slot switched to another model follows that model. */
export function takes(w: Pick<WorkerDef, 'takes' | 'model'>): 'any' | 'small' {
  if (w.takes) return w.takes;
  const b = w.model.match(/(\d+(?:\.\d+)?)b\b/i);
  return b && Number(b[1]) < 15 ? 'small' : 'any';
}

const isLocal = (w: Pick<WorkerDef, 'backend'>) => w.backend === 'llmd' || w.backend === 'ollama' || w.backend === 'openai';

/** How often an OpenAI-compatible endpoint is asked for its models: less often than local servers, since it may be a
 *  hosted API. Adding, changing or switching one on asks at once. */
const OPENAI_CHECK_MS = 30_000;

type Candidate = Pick<WorkerDef, 'backend' | 'enabled' | 'model' | 'takes'> & { available: boolean; loaded: boolean; running: unknown; queue: unknown[] };

/**
 * auto's choice. Never a worker whose model would need loading, nor an Apple worker (text only). A large task goes to
 * an idle worker that takes any task, else waits in the shortest such queue: it never goes to a small model. A small
 * one takes an idle small worker first, then any idle worker; with every worker busy it waits in the shortest small
 * worker's queue, however long, so large work never waits behind it (the lead can name a large worker instead).
 */
export function pickAuto<W extends Candidate>(workers: W[], size: TaskSize): W | undefined {
  const fit = workers.filter((w) => w.enabled && w.available && w.loaded && isLocal(w) && (size === 'small' || takes(w) === 'any'));
  const idle = fit.filter((w) => !w.running && !w.queue.length);
  const small = size === 'small' ? fit.filter((w) => takes(w) === 'small') : [];
  const shortest = (ws: W[]) => [...ws].sort((a, b) => a.queue.length - b.queue.length)[0];
  return idle.find((w) => small.includes(w)) ?? idle[0] ?? shortest(small) ?? shortest(fit);
}

export type DelegateOpts = { cwd?: string; effort?: string; files?: string[]; size?: TaskSize; profile?: ProfileId; internal?: (o: Answered) => void };

/** How a task the hub asked itself (a note, a side chat) ended: it comes back to the hub instead of going to Claude. */
export type Answered = { taskId: string; worker: string; state: 'done' | 'failed' | 'cancelled'; result: string; output: string; error?: string };

/** Text an Apple worker gets from named files, at most (the device splits long text into passes). */
export const APPLE_INPUT_MAX = 400_000;

// With no fleet file: one worker on Ollama. Point it anywhere with DUET_OLLAMA_URL (and DUET_OLLAMA_MODEL) in
// hub/local.env; by default this machine's Ollama with qwen3:8b (`ollama pull qwen3:8b`). Without Ollama it shows as
// not reachable, and Claude uses its own subagents. Several workers go in a fleet file (see fleet.example.json).
export function defaultWorkers(env: NodeJS.ProcessEnv = process.env): WorkerDef[] {
  const url = (env.DUET_OLLAMA_URL || 'http://127.0.0.1:11434').replace(/\/+$/, '');
  const model = env.DUET_OLLAMA_MODEL || 'qwen3:8b';
  return [{ id: 'ollama', label: `${model} · Ollama`, backend: 'ollama', url, model, table: 'ollama-onoff', enabled: true }];
}

export type FleetConfig = {
  workers: WorkerDef[];
  llmdAdmin: string; // e.g. http://127.0.0.1:8801; empty: no llmd
  modelsToml: string; // read-only, for model -> device
  claimsAllDevices: string[]; // models that take every GPU when loaded
  defaultCwd: string;
  proxyBaseUrl: (worker: string) => string;
  log: (m: string) => void;
  apple?: AppleDevices;
  /** Whether the lead sees Apple's on-device workers in its fleet listing (DUET_APPLE_FOR_LEAD); the user always does. */
  appleForLead?: boolean;
  /** The live conversation, captured by each task when it starts (its events keep that tag after a Clear). */
  currentConversation?: () => string | undefined;
};

type Task = {
  id: string;
  worker: string;
  prompt: string;
  cwd: string;
  effort: string;
  by: string;
  conversationId?: string;
  // Local workers: the harness it runs with (tools, turns, instructions). Unset: general.
  profile?: ProfileId;
  state: 'queued' | 'awaiting_swap' | 'running' | 'done' | 'failed' | 'cancelled';
  swapId?: string;
  swapApproved?: boolean;
  abort?: AbortController;
  requests: RequestStats[];
  startedAt?: number;
  // Everything the worker wrote, in order: the lead gets it with the RESULT.
  output: string[];
  // Apple workers: files whose text goes with the task, and the device's measurements.
  files?: string[];
  // Local workers: the files the task names outside its folder, which its guard lets it read.
  readable?: string[];
  appleStats?: AppleStats;
  // Claude's subagents: tokens by API message (each message's blocks arrive separately, with the same usage).
  usage?: Map<string, { input: number; output: number }>;
  outcome?: SubagentOutcome; // Claude Code's own totals, when it reports them
  // Claude's subagents: the few words Claude gave it; whether it runs in the background (its call returned at once, and
  // it ends with its own notice); and, for one another subagent started, that one's task and how deep it is.
  label?: string;
  background?: boolean;
  parentId?: string;
  depth?: number;
  // The hub's own question (a note, a side chat): its outcome comes back here, not to Claude.
  internal?: (o: Answered) => void;
};

// What the dialogue layer gives each worker session, and hears back when a task ends.
export type FleetBridge = {
  extras(taskId: string, worker: string): Pick<WorkerRun, 'mcpServers' | 'hooks'>;
  /** `stopped`: it ran out of turns or of room, and is done with what it had. `tools`: a local worker's tool calls, as
   *  the hub counted them, and its profile. */
  onTaskEnd(taskId: string, worker: string, state: string, result: string, evidence: string, output: string, stopped?: Stopped, tools?: ToolsUsed): void;
};

type WorkerState = WorkerDef & {
  effort: string; available: boolean; loaded: boolean; running: Task | null; queue: Task[]; tokPerS: number | null;
  active?: Task[]; // claude: every subagent of this kind running now
  fromSettings?: boolean; // an endpoint added in Settings (syncEndpoints), not the fleet file
  checkedAt?: number; // openai: when its models were last listed
};

/** The task a subagent call is shown as, from Claude's Agent tool call id (clients derive it the same way). */
export const subagentTaskId = (toolUseId: string) => `sa-${toolUseId.slice(-8)}`;
/** "claude-explore" for the Explore kind. */
export const subagentWorkerId = (kind: string) => `claude-${kind.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'subagent'}`;
const SUBAGENT_EVIDENCE = 'not measured: a Claude subagent works in Claude\'s folder alongside Claude';
const SUBAGENT_STOPPED = 'Stopped: Claude Code restarted while it ran (a restart, a Clear, another conversation or folder).';
const SUBAGENT_ORPHANED = 'Stopped: the hub restarted while it ran.';

/** A subagent's report from its tool result: Claude Code frames it with a notice and indents every line. */
export function subagentReport(text: string): string {
  const marker = 'The report follows:\n';
  const at = text.startsWith('[Subagent hand-back]') ? text.indexOf(marker) : -1;
  if (at < 0) return text.trim();
  return text.slice(at + marker.length).split('\n').map((l) => l.replace(/^ {2}/, '')).join('\n').replace(/\n*agentId: \S+[\s\S]*$/, '').trim();
}

export class Fleet {
  private workers = new Map<string, WorkerState>();
  private tasks = new Map<string, Task>();
  private swaps = new Map<string, string>(); // swap id -> task id
  private devices = new Map<string, string>(); // llmd model -> device
  private readyOnDevice = new Map<string, string[]>(); // device -> READY served ids
  // Each running model's window as its server says (key: where and how it runs, so a reload asks again), and as
  // models.toml sets it.
  private served = new Map<string, { key: string; tokens: number }>();
  private configured = new Map<string, number>();
  private lastFleet = '';
  private lastCatalog = '';
  private chatModels: string[] = []; // llmd models from models.toml that have an effort table
  private timer: NodeJS.Timeout | null = null;
  private refreshing: Promise<void> | null = null;
  private cfg: FleetConfig;
  private emit: (e: EventBody) => void;
  private bridge: FleetBridge | null = null;

  constructor(cfg: FleetConfig, emit: (e: EventBody) => void) {
    this.cfg = cfg;
    this.emit = emit;
    for (const w of cfg.workers) {
      this.workers.set(w.id, { ...w, effort: EFFORT_TABLES[w.table].default, available: false, loaded: false, running: null, queue: [], tokPerS: null });
    }
    this.readDevices();
  }

  setBridge(b: FleetBridge): void {
    this.bridge = b;
  }

  /** `ahead`: for a task that waits, the tasks its worker runs first (the one running, then the queue before it). */
  taskInfo(taskId: string): { worker: string; state: string; by: string; conversationId?: string; ahead?: string[] } | undefined {
    const t = this.tasks.get(taskId);
    if (!t) return undefined;
    const w = this.workers.get(t.worker);
    const waits = w && (t.state === 'queued' || t.state === 'awaiting_swap');
    const ahead = waits ? [...(w.running ? [w.running.id] : []), ...w.queue.slice(0, Math.max(0, w.queue.indexOf(t))).map((q) => q.id)] : undefined;
    return { worker: t.worker, state: t.state, by: t.by, conversationId: t.conversationId, ...(ahead ? { ahead } : {}) };
  }

  /** Emit an event of a task's, tagged with the conversation the task started in. */
  private emitFor(t: Task | undefined, e: EventBody): void {
    this.emit(t?.conversationId ? { ...e, conversationId: t.conversationId } : e);
  }

  // Claude's own subagents aren't counted: they end within the tool call that started them, or run in the background
  // and come back to Claude by themselves.
  activeTasks(by: string): string[] {
    return [...this.tasks.values()].filter((t) => t.by === by && !t.worker.startsWith('claude-') && ['queued', 'awaiting_swap', 'running'].includes(t.state)).map((t) => t.id);
  }

  // Plain-text fleet summary for the lead's fleet() tool and prompt context.
  describe(): string {
    const lines = [...this.workers.values()].filter((w) => w.backend !== 'claude' && (w.backend !== 'apple' || this.cfg.appleForLead)).map((w) => {
      const apple = w.backend === 'apple' ? this.cfg.apple?.info(w.device ?? '') : undefined;
      const status = !w.enabled ? 'disabled'
        : !w.available ? (w.backend === 'apple' ? `unavailable (${apple ? appleReason(apple.reason) : 'device not connected'})` : 'unavailable')
        : !w.loaded ? 'not loaded (delegating asks the user to approve a GPU swap, which unloads what that GPU has)'
        : w.running ? `busy with ${w.running.id}${w.queue.length ? `, then ${w.queue.map((q) => q.id).join(', ')}` : ''}` : 'idle';
      if (w.backend === 'apple') {
        return `- ${w.id}: ${w.label}, Apple's on-device model (${apple?.variant ? `${apple.variant}, ` : ''}${apple?.contextSize ? `${apple.contextSize}-token context` : 'a 4K–8K context'}) — ${status}; text only: summaries, extraction, classification. It can't run tools or read files: pass \`files\` and the hub sends their text (long text is read in parts).`;
      }
      const fit = takes(w) === 'small' ? 'small, mechanical tasks only' : 'any task';
      const levels = EFFORT_TABLES[w.table].levels;
      const effort = levels.length ? `effort levels ${levels.join('/')} (default ${w.effort})` : 'no effort setting';
      return `- ${w.id}: ${w.label} — ${status}; ${fit}; ${effort}`;
    });
    if (!lines.length) return '';
    return ['Each worker is one model on its own hardware and runs ONE task at a time; more tasks for it wait in its queue. Spread parallel work across workers.', ...lines].join('\n');
  }

  /**
   * A question the hub itself puts to a local worker (a note, a side chat): queued like any task (one per GPU) and
   * shown like one, but its outcome comes back here instead of going to Claude as a RESULT. `onTask` hears the task's
   * id at once, so it can be stopped.
   */
  ask(sel: string, prompt: string, by: string, opts: Omit<DelegateOpts, 'internal'> = {}, onTask?: (taskId: string) => void): Promise<Answered> {
    return new Promise((resolve, reject) => {
      try {
        // Queued first, then reported: `onTask?.(this.delegate(…))` would skip queuing it when there's no onTask.
        const taskId = this.delegate(sel, prompt, by, { ...opts, internal: resolve });
        onTask?.(taskId);
      } catch (e) {
        reject(e);
      }
    });
  }

  /** Local workers that would start a task now (enabled, up, loaded, idle), with the tasks auto gives them. */
  idleLocal(): { id: string; takes: 'any' | 'small' }[] {
    return [...this.workers.values()]
      .filter((w) => isLocal(w) && w.enabled && w.available && w.loaded && !w.running && !w.queue.length)
      .map((w) => ({ id: w.id, takes: takes(w) }));
  }

  /** Apple workers follow the devices that report Apple Intelligence: one per device, kept (as unavailable) when it goes. */
  syncApple(): void {
    const apple = this.cfg.apple;
    if (!apple) return;
    for (const [device, s] of apple.devices()) {
      const id = `apple-${device}`;
      if (!this.workers.has(id)) {
        this.workers.set(id, {
          id, label: appleLabel(s), backend: 'apple', url: '', model: 'on-device', table: 'apple-none', enabled: true, device,
          effort: 'default', available: false, loaded: false, running: null, queue: [], tokPerS: null,
        });
      }
      this.workers.get(id)!.label = appleLabel(s);
    }
    for (const w of this.workers.values()) {
      if (w.backend !== 'apple') continue;
      w.available = apple.info(w.device ?? '')?.available ?? false;
      w.loaded = w.available;
    }
    this.publish();
    for (const w of this.workers.values()) if (w.backend === 'apple') this.schedule(w);
  }

  async start(): Promise<void> {
    await this.refresh();
    this.timer = setInterval(() => void this.refresh(), 5000);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    for (const t of this.tasks.values()) t.abort?.abort();
  }

  // models.toml is read-only input: which device each llmd model lives on.
  private readDevices(): void {
    if (!existsSync(this.cfg.modelsToml)) return;
    let current: string | null = null;
    const text = readFileSync(this.cfg.modelsToml, 'utf8');
    this.configured = tomlContexts(text);
    for (const line of text.split('\n')) {
      const sec = line.match(/^\[models\."([^"]+)"\]\s*$/);
      if (sec) { current = sec[1]; continue; }
      if (line.startsWith('[')) { current = null; continue; }
      const dev = current && line.match(/^device\s*=\s*"([^"]+)"/);
      if (dev && current) this.devices.set(current, dev[1]);
    }
    this.chatModels = [...this.devices.keys()].filter((id) => tableForModel(id) !== null);
  }

  // Loaded models that loading `model` would push out (the same rule the swap card uses).
  private evictsFor(model: string): string[] {
    const device = this.devices.get(model) ?? 'unknown';
    if (this.cfg.claimsAllDevices.includes(model) || device === 'unknown') return [...this.readyOnDevice.values()].flat().filter((m) => m !== model);
    return (this.readyOnDevice.get(device) ?? []).filter((m) => m !== model);
  }

  catalog(): CatalogModel[] {
    const ready = new Set([...this.readyOnDevice.values()].flat());
    return this.chatModels.map((id) => ({
      id, device: this.devices.get(id) ?? 'unknown', loaded: ready.has(id), evicts: ready.has(id) ? [] : this.evictsFor(id),
      effortLevels: EFFORT_TABLES[tableForModel(id)!].levels, verified: VERIFIED_EFFORT.has(id),
    }));
  }

  /** One refresh at a time: a forced one (an endpoint added) waits for the one under way, then runs. */
  async refresh(): Promise<void> {
    while (this.refreshing) await this.refreshing;
    this.refreshing = this.refreshOnce().finally(() => { this.refreshing = null; });
    return this.refreshing;
  }

  private async refreshOnce(): Promise<void> {
    const ready = new Set<string>();
    let llmdUp = false;
    if (this.cfg.llmdAdmin) try {
      const s = await (await fetch(`${this.cfg.llmdAdmin}/admin/v1/status`, { signal: AbortSignal.timeout(3000) })).json() as { backends: { served_id: string; state: string; device: string; port?: number; profile?: string }[] };
      llmdUp = true;
      this.readyOnDevice.clear();
      for (const b of s.backends) {
        if (b.state !== 'READY') continue;
        ready.add(b.served_id);
        this.readyOnDevice.set(b.device, [...(this.readyOnDevice.get(b.device) ?? []), b.served_id]);
        await this.learnContext(b);
      }
    } catch { /* llmd down: llmd workers unavailable */ }
    for (const w of this.workers.values()) {
      if (w.backend === 'claude') {
        continue; // always available: they run on Claude
      } else if (w.backend === 'apple') {
        w.available = this.cfg.apple?.info(w.device ?? '')?.available ?? false;
        w.loaded = w.available;
      } else if (w.backend === 'llmd') {
        w.available = llmdUp;
        w.loaded = ready.has(w.model);
      } else if (w.backend === 'openai') {
        if (!w.enabled) { w.available = false; w.loaded = false; continue; }
        if (w.checkedAt && Date.now() - w.checkedAt < OPENAI_CHECK_MS) continue;
        w.checkedAt = Date.now();
        try {
          const models = await listModels(w.url, w.apiKey, 4000);
          w.available = true;
          // A server that lists nothing (some don't) is taken at its word that the model is there.
          const m = models.find((x) => x.id === w.model);
          w.loaded = !models.length || Boolean(m);
          if (m?.context) this.served.set(w.model, { key: `openai:${w.url}`, tokens: m.context });
        } catch { w.available = false; w.loaded = false; }
      } else if (w.enabled) {
        try {
          const tags = await (await fetch(`${w.url}/api/tags`, { signal: AbortSignal.timeout(2000) })).json() as { models: { name: string }[] };
          w.available = true;
          w.loaded = tags.models.some((m) => m.name === w.model);
        } catch { w.available = false; w.loaded = false; }
      } else {
        w.available = false; w.loaded = false;
      }
    }
    this.publish();
    for (const w of this.workers.values()) this.schedule(w);
  }

  /** Ask a model's server how much it holds, once each time it (re)starts. */
  private async learnContext(b: { served_id: string; port?: number; profile?: string }): Promise<void> {
    if (!b.port) return;
    const key = `${b.port}:${b.profile ?? ''}`;
    if (this.served.get(b.served_id)?.key === key) return;
    const n = await servedContext(new URL(this.cfg.llmdAdmin).hostname, b.port, b.served_id);
    this.served.set(b.served_id, { key, tokens: n ?? 0 });
    if (n) this.cfg.log(`${b.served_id} holds ${n} tokens`);
  }

  /** The window a worker's model holds: its configured override, else what its server says, else models.toml. */
  contextFor(w: Pick<WorkerDef, 'model' | 'context'>): number | undefined {
    return w.context || this.served.get(w.model)?.tokens || this.configured.get(w.model) || undefined;
  }

  private view(w: WorkerState): WorkerView {
    const v: WorkerView = {
      id: w.id, label: w.label, backend: w.backend, model: w.model, enabled: w.enabled, available: w.available, loaded: w.loaded,
      effort: w.effort, effortLevels: EFFORT_TABLES[w.table].levels, temperature: w.temperature,
      tokPerS: w.tokPerS, verifiedEffort: w.backend === 'apple' || VERIFIED_EFFORT.has(w.model),
      running: w.running?.id ?? null, queue: w.queue.map((t) => t.id),
    };
    if (w.fromSettings) v.fromSettings = true;
    if (w.backend === 'claude') {
      v.active = (w.active ?? []).map((t) => t.id);
      v.running = v.active[0] ?? null;
    }
    if (w.backend === 'apple') {
      const s = this.cfg.apple?.info(w.device ?? '');
      v.device = w.device;
      if (s?.variant) v.variant = s.variant;
      if (s?.contextSize) v.contextSize = s.contextSize;
      if (s?.capabilities?.length) v.capabilities = s.capabilities;
      if (!w.available) v.unavailableReason = s ? appleReason(s.reason) : 'not connected';
    }
    return v;
  }

  // Emit a fleet snapshot only when something visible changed.
  private publish(): void {
    const workers = [...this.workers.values()].map((w) => this.view(w));
    const key = JSON.stringify(workers);
    if (key !== this.lastFleet) {
      this.lastFleet = key;
      this.emit({ type: 'fleet', workers });
    }
    const models = this.catalog();
    const ckey = JSON.stringify(models);
    if (ckey !== this.lastCatalog) {
      this.lastCatalog = ckey;
      this.emit({ type: 'model_catalog', models });
    }
  }

  // ---- Claude's own subagents: one worker per kind, each Agent call a task with its own thread ----

  /** Kinds seen before a restart keep their place in the fleet (published with the first refresh, once what's
   *  loaded is known). */
  seedSubagents(workerIds: string[]): void {
    for (const id of new Set(workerIds)) if (id.startsWith('claude-')) this.subagentWorker(id.slice('claude-'.length));
  }

  private subagentWorker(kind: string): WorkerState {
    const id = subagentWorkerId(kind);
    let w = this.workers.get(id);
    if (!w) {
      const name = kind.charAt(0).toUpperCase() + kind.slice(1);
      w = {
        id, label: `${name} · Claude subagent`, backend: 'claude', url: '', model: 'claude', table: 'none', enabled: true,
        effort: 'default', available: true, loaded: true, running: null, queue: [], tokPerS: null, active: [],
      };
      this.workers.set(id, w);
    }
    return w;
  }

  /**
   * Claude started a subagent, or (`info.parent`) one of its subagents did. Its messages arrive as the task's progress.
   * The TASK card shows in Claude's thread; a subagent's own subagent's comes from that subagent, so it stays out of it.
   */
  subagentStart(toolUseId: string, kind: string, prompt: string, info: SubagentInfo = {}): void {
    if (this.tasks.has(subagentTaskId(toolUseId))) return;
    const parent = info.parent ? this.tasks.get(subagentTaskId(info.parent)) : undefined;
    if (info.parent && !parent) return;
    const w = this.subagentWorker(kind);
    const t: Task = {
      id: subagentTaskId(toolUseId), worker: w.id, prompt, cwd: this.cfg.defaultCwd, effort: 'default', by: 'lead', state: 'running',
      conversationId: parent ? parent.conversationId : this.cfg.currentConversation?.(), requests: [], output: [], startedAt: Date.now(), usage: new Map(),
      ...(info.label ? { label: info.label } : {}), ...(info.background ? { background: true } : {}),
      ...(parent ? { parentId: parent.id, depth: info.depth ?? (parent.depth ?? 1) + 1 } : {}),
    };
    this.tasks.set(t.id, t);
    w.active!.push(t);
    w.running = w.active![0];
    this.emitFor(t, {
      type: 'task', taskId: t.id, worker: w.id, state: 'running', prompt, by: 'lead', effort: t.effort, cwd: t.cwd,
      ...(t.label ? { label: t.label } : {}), ...(t.background ? { background: true } : {}), ...(parent ? { parentId: t.parentId, depth: t.depth } : {}),
    });
    this.emitFor(t, { type: 'dialogue', id: `${t.id}-task`, kind: 'TASK', taskId: t.id, from: parent?.worker ?? 'lead', to: w.id, text: prompt });
    this.publish();
  }

  /** It runs in the background now: its Agent call has returned, and it ends with its own notice (or when it's lost). */
  subagentBackground(toolUseId: string): void {
    const t = this.tasks.get(subagentTaskId(toolUseId));
    if (!t || t.state !== 'running' || t.background || !t.worker.startsWith('claude-')) return;
    t.background = true;
    this.emitFor(t, { type: 'task', taskId: t.id, worker: t.worker, state: 'running', background: true });
  }

  /** What a subagent said or did. Unknown ids (a subagent the hub doesn't follow) are ignored. */
  subagentProgress(toolUseId: string, p: { text?: string; toolUses?: ToolCall[]; toolResult?: string; usage?: { messageId: string; input: number; output: number } }): void {
    const t = this.tasks.get(subagentTaskId(toolUseId));
    if (!t || t.state !== 'running') return;
    if (p.usage) t.usage!.set(p.usage.messageId, { input: p.usage.input, output: p.usage.output });
    if (p.text) t.output.push(p.text);
    if (!p.text && !p.toolUses?.length && !p.toolResult) return;
    this.emitFor(t, {
      type: 'task_progress', taskId: t.id, worker: t.worker,
      ...(p.text ? { text: p.text } : {}),
      ...(p.toolUses?.length ? { toolUses: p.toolUses, tools: p.toolUses.map((u) => `${u.name} ${JSON.stringify(u.input).slice(0, 160)}`) } : {}),
      ...(p.toolResult ? { toolResult: p.toolResult } : {}),
    });
  }

  isSubagent(toolUseId: string): boolean {
    return this.tasks.get(subagentTaskId(toolUseId))?.worker.startsWith('claude-') ?? false;
  }

  /** The subagent's result reached Claude, or its end notice came (a background one, or a subagent's own); or the turn
   *  ended first: cancelled. */
  subagentEnd(toolUseId: string, state: 'done' | 'failed' | 'cancelled', result: string, outcome?: SubagentOutcome): void {
    const t = this.tasks.get(subagentTaskId(toolUseId));
    if (!t || t.state !== 'running') return;
    const w = this.workers.get(t.worker)!;
    t.state = state;
    t.outcome = outcome;
    w.active = w.active!.filter((x) => x !== t);
    w.running = w.active[0] ?? null;
    const text = (outcome?.report || subagentReport(result)).slice(0, 8000);
    const e = outcome?.edits;
    const evidence = e ? (e.files ? `${e.files} file${e.files === 1 ? '' : 's'} edited, +${e.added} −${e.removed} lines (Claude Code's count)` : 'no changes') : SUBAGENT_EVIDENCE;
    this.emitFor(t, { type: 'task', taskId: t.id, worker: w.id, state, result: text || undefined, evidence, stats: this.stats(t) });
    if (state !== 'cancelled') {
      const to = (t.parentId && this.tasks.get(t.parentId)?.worker) || 'lead';
      this.emitFor(t, { type: 'dialogue', id: `${t.id}-result`, kind: 'RESULT', taskId: t.id, from: w.id, to, text: `${state === 'done' ? 'Finished' : 'Failed'}: ${text || '(no report)'}` });
    }
    this.publish();
  }

  /**
   * Claude's turn ended: the subagents it waited on were cut off, with their own. Those in the background, and theirs,
   * run on and end with their own notices. `all`: Claude Code stopped, and every subagent with it (they run in its
   * process).
   */
  subagentsStopped(all = false): void {
    for (const t of this.tasks.values()) {
      if (t.state !== 'running' || !t.worker.startsWith('claude-') || (!all && this.detached(t))) continue;
      this.subagentEnd(t.id.slice(3), 'cancelled', all ? SUBAGENT_STOPPED : '');
    }
  }

  /** It runs in the background, or under one that does: Claude's turn ending doesn't stop it. */
  private detached(t: Task): boolean {
    for (let x: Task | undefined = t; x; x = x.parentId ? this.tasks.get(x.parentId) : undefined) if (x.background) return true;
    return false;
  }

  /**
   * Claude's subagents the log shows still running as the hub starts: they ran in Claude Code's process, which ended
   * with the hub. They end as stopped, so no device shows them running for good.
   */
  endOrphans(log: readonly EventBody[]): void {
    const last = new Map<string, Extract<EventBody, { type: 'task' }>>();
    for (const e of log) if (e.type === 'task' && e.worker.startsWith('claude-')) last.set(e.taskId, e);
    for (const e of last.values()) {
      if (e.state !== 'running' || this.tasks.has(e.taskId)) continue;
      this.emit({ type: 'task', taskId: e.taskId, worker: e.worker, state: 'cancelled', result: SUBAGENT_ORPHANED, ...(e.conversationId ? { conversationId: e.conversationId } : {}) });
    }
  }

  /** Where tasks given without a folder run: Claude's folder. */
  setDefaultCwd(dir: string): void {
    this.cfg.defaultCwd = dir;
  }

  snapshot(): WorkerView[] {
    return [...this.workers.values()].map((w) => this.view(w));
  }

  delegate(sel: string, prompt: string, by: string, opts: DelegateOpts = {}): string {
    if (!prompt.trim()) throw new Error('empty task');
    const { cwd, effort, profile } = opts;
    let { files } = opts;
    const size = opts.size ?? 'large';
    const w = sel === 'auto' ? pickAuto([...this.workers.values()], size) : this.workers.get(sel);
    if (!w) throw new Error(sel === 'auto' ? this.noAuto(size) : `unknown worker ${sel}`);
    if (w.backend === 'claude') throw new Error(`${w.id} is one of Claude's own subagents: Claude starts those itself, so ask Claude`);
    if (!w.enabled) throw new Error(`worker ${w.id} is disabled`);
    if (w.backend === 'apple' && !w.available) throw new Error(`${w.id} is unavailable: ${this.view(w).unavailableReason}`);
    if (profile !== undefined && !Object.hasOwn(PROFILES, profile)) throw new Error(`unknown profile ${profile} (${Object.keys(PROFILES).join(', ')})`);
    if (w.backend === 'apple' && profile !== undefined && profile !== 'general') throw new Error(`${w.id} takes text tasks only (summaries, extraction, classification), with no tools: leave out profile`);
    if (effort !== undefined && w.backend !== 'apple' && !validLevel(w.table, effort)) throw new Error(`effort ${effort} not offered by ${w.id} (${EFFORT_TABLES[w.table].levels.join(', ')})`);
    const dir = cwd ?? this.cfg.defaultCwd;
    if (!existsSync(dir) || !statSync(dir).isDirectory()) throw new Error(`cwd ${dir} does not exist`);
    // An Apple worker gets the files' text (those the task names by path, if none are given); a local worker reads them
    // itself, and may read those outside its folder (only those, and only read them).
    if (w.backend === 'apple' && !files?.length) files = filesNamedIn(prompt, dir);
    const readable = w.backend !== 'apple' && files?.length ? readableOutside(files, dir) : [];
    if (files?.length && w.backend === 'apple') appleInput(files);
    else if (files?.length) prompt = `${prompt}\n\nFiles: ${files.map((f) => readable.includes(resolve(dir, f)) ? `${f} (outside your folder: you may read it, not change it)` : f).join(', ')}`;
    const t: Task = {
      id: `t-${randomUUID().slice(0, 6)}`, worker: w.id, prompt, cwd: dir, effort: effort ?? w.effort, by, state: 'queued',
      conversationId: this.cfg.currentConversation?.(), requests: [], output: [], ...(w.backend === 'apple' && files?.length ? { files } : {}),
      ...(isLocal(w) ? { profile: profile ?? 'general' } : {}), ...(readable.length ? { readable } : {}), ...(opts.internal ? { internal: opts.internal } : {}),
    };
    this.tasks.set(t.id, t);
    w.queue.push(t);
    this.emitFor(t, {
      type: 'task', taskId: t.id, worker: w.id, state: 'queued', prompt, by, effort: t.effort, cwd: dir, ...(t.files ? { files: t.files } : {}),
      ...(t.profile ? { profile: t.profile } : {}), queuePosition: w.queue.length - (w.running ? 0 : 1),
    });
    this.schedule(w);
    this.publish();
    return t.id;
  }

  /** Why auto found no worker, worker by worker, and what to do instead. Being busy never rules a worker out (the task
   *  would wait in its queue), so the message never blames that. */
  private noAuto(size: TaskSize): string {
    const local = [...this.workers.values()].filter(isLocal);
    const head = `auto found no local worker for this ${size} task (a busy one would just have queued it)`;
    if (!local.length) return `${head}: there are no local workers.`;
    // A worker that is on, reachable and loaded is out only because it's small and the task is large.
    const reason = (w: WorkerState) => !w.enabled ? `${w.id} is switched off`
      : !w.available ? `${w.id} isn't reachable`
      : !w.loaded ? `${w.id}'s model isn't loaded`
      : `${w.id} takes small, mechanical tasks only`;
    const unloaded = local.filter((w) => w.backend === 'llmd' && w.enabled && w.available && !w.loaded).map((w) => w.id);
    const advice = [
      local.some((w) => w.enabled && w.available && w.loaded) ? 'Pass size "small" if the task is short and mechanical.' : '',
      unloaded.length ? `Name ${unloaded.join(' or ')} to ask the user to load ${unloaded.length === 1 ? 'its model' : 'a model'}.` : '',
    ].filter(Boolean).join(' ');
    return `${head}: ${local.map(reason).join('; ')}.${advice ? ` ${advice}` : ''}`;
  }

  private schedule(w: WorkerState): void {
    if (w.running || !w.queue.length) return;
    const t = w.queue[0];
    if (w.backend === 'llmd' && !w.loaded && !t.swapApproved) {
      if (t.state === 'awaiting_swap' || !w.available) return;
      t.state = 'awaiting_swap';
      t.swapId = `s-${randomUUID().slice(0, 6)}`;
      this.swaps.set(t.swapId, t.id);
      const device = this.devices.get(w.model) ?? 'unknown';
      const evicts = this.evictsFor(w.model);
      this.emitFor(t, { type: 'task', taskId: t.id, worker: w.id, state: 'awaiting_swap' });
      this.emitFor(t, { type: 'swap_request', id: t.swapId, taskId: t.id, worker: w.id, model: w.model, device, evicts });
      return;
    }
    w.queue.shift();
    w.running = t;
    void this.execute(w, t);
    w.queue.forEach((q, i) => this.emitFor(q, { type: 'task', taskId: q.id, worker: w.id, state: 'queued', queuePosition: i + 1 }));
    this.publish();
  }

  private async execute(w: WorkerState, t: Task): Promise<void> {
    t.state = 'running';
    t.startedAt = Date.now();
    t.abort = new AbortController();
    this.emitFor(t, { type: 'task', taskId: t.id, worker: w.id, state: 'running', effort: t.effort });
    if (w.backend === 'apple') return this.executeApple(w, t);
    const p = PROFILES[t.profile ?? 'general'];
    const turns = w.maxTurns ? Math.min(p.maxTurns, w.maxTurns) : p.maxTurns;
    const out = await runWorker({
      cwd: t.cwd,
      prompt: t.prompt,
      baseUrl: this.cfg.proxyBaseUrl(w.id),
      tools: p.tools,
      maxTurns: turns,
      contextTokens: this.contextFor(w),
      log: (m) => this.cfg.log(`${t.id} on ${w.id}: ${m}`),
      readOnly: p.readOnly,
      readable: t.readable,
      signal: t.abort.signal,
      onProgress: (p) => {
        if (p.text) t.output.push(p.text);
        this.emitFor(t, { type: 'task_progress', taskId: t.id, worker: w.id, ...p });
      },
      // The hub's own questions get no duet tools: nobody to ask, and the answer comes straight back.
      ...(t.internal ? {} : this.bridge?.extras(t.id, w.id)),
    });
    const ev = await evidence(t.cwd);
    // Out of turns, or out of room (the conversation kept outgrowing the model even after compacting): not a failure.
    // The task ends with what it got done (its report if it made one, else its own last words), marked as stopped and
    // why, so the lead knows the work may be partial.
    const stopped: Stopped | undefined = t.abort.signal.aborted || out.ok ? undefined
      : out.subtype === 'error_max_turns' ? { reason: 'turn_limit', turns }
      : OUT_OF_ROOM.test(`${out.error ?? ''}\n${out.result}`) ? { reason: 'context', turns, context: this.contextFor(w) }
      : undefined;
    t.state = t.abort.signal.aborted ? 'cancelled' : out.ok || stopped ? 'done' : 'failed';
    const progress = stopped ? stoppedResult(stopped, t.output) : '';
    // The lead's RESULT says why it stopped in its first words; its summary is then just what the worker said.
    const toLead = stopped ? stoppedWords(t.output) || '(it wrote nothing about its progress; the changes below are what it did)' : out.result;
    this.emitFor(t, { type: 'task', taskId: t.id, worker: w.id, state: t.state, result: (stopped ? progress : out.result) || undefined, evidence: ev, error: out.ok || stopped ? undefined : out.error ?? out.subtype, stats: this.stats(t), ...(stopped ? { stopped: stopped.reason } : {}) });
    w.running = null;
    const cut = stopped?.reason === 'turn_limit' ? `Stopped at the ${p.id} profile's limit of ${turns} turns, before it finished.` : '';
    if (t.internal) t.internal({ taskId: t.id, worker: w.id, state: (stopped ? 'failed' : t.state) as Answered['state'], result: out.result || '', output: t.output.join('\n\n'), error: out.error ?? (cut || undefined) });
    else this.bridge?.onTaskEnd(t.id, w.id, t.state, toLead, ev, t.output.join('\n\n'), stopped, { used: out.tools, profile: p.id });
    this.publish();
    this.schedule(w);
  }

  /** An Apple worker's task runs on its device; nothing on the hub machine changes, so there's no diff to measure. */
  private async executeApple(w: WorkerState, t: Task): Promise<void> {
    let out: { ok: boolean; result: string; error?: string; stats?: AppleStats };
    try {
      const input = t.files?.length ? appleInput(t.files) : undefined;
      out = await this.cfg.apple!.run(w.device ?? '', t.id, { prompt: t.prompt, input, temperature: w.temperature }, (text) => {
        t.output.push(text);
        this.emitFor(t, { type: 'task_progress', taskId: t.id, worker: w.id, text });
      }, t.abort!.signal);
    } catch (e) {
      out = { ok: false, result: '', error: e instanceof Error ? e.message : String(e) };
    }
    t.appleStats = out.stats;
    const speed = appleTokPerS(out.stats);
    if (speed !== null && out.stats!.outputTokens >= 16) w.tokPerS = speed;
    t.state = t.abort!.signal.aborted ? 'cancelled' : out.ok ? 'done' : 'failed';
    const ev = 'not applicable: an Apple worker reads and writes no files';
    this.emitFor(t, { type: 'task', taskId: t.id, worker: w.id, state: t.state, result: out.result || undefined, evidence: ev, error: out.ok ? undefined : out.error, stats: this.stats(t) });
    w.running = null;
    // The answer is the result (its progress lines were the passes over the input); on failure, the device's error is.
    this.bridge?.onTaskEnd(t.id, w.id, t.state, out.ok ? out.result : out.error ?? '', ev, '');
    this.publish();
    this.schedule(w);
  }

  /** The folder a task works in (for its diff). */
  taskCwd(taskId: string): string | undefined {
    return this.tasks.get(taskId)?.cwd;
  }

  private stats(t: Task): TaskStats {
    const o = t.outcome;
    if (o?.inputTokens !== undefined) {
      return { requests: Math.max(t.usage?.size ?? 0, 1), inputTokens: o.inputTokens, outputTokens: o.outputTokens ?? 0, genTokPerS: null, wallMs: o.durationMs || Date.now() - (t.startedAt ?? Date.now()), firstTokenMs: null };
    }
    if (t.usage) {
      // A background subagent's notice counts only its tokens in all: these are the messages of its that Duet saw. Its
      // time is Claude Code's.
      const u = [...t.usage.values()];
      return {
        requests: u.length, inputTokens: u.reduce((a, x) => a + x.input, 0), outputTokens: u.reduce((a, x) => a + x.output, 0),
        genTokPerS: null, wallMs: o?.durationMs || Date.now() - (t.startedAt ?? Date.now()), firstTokenMs: null,
      };
    }
    if (t.appleStats) {
      const a = t.appleStats;
      return {
        requests: a.parts ?? 1, inputTokens: a.inputTokens, outputTokens: a.outputTokens,
        genTokPerS: appleTokPerS(a),
        wallMs: Date.now() - (t.startedAt ?? Date.now()), firstTokenMs: a.firstTokenMs ?? null,
      };
    }
    const r = t.requests.filter((x) => x.status === 200);
    const out = r.reduce((a, x) => a + x.outputTokens, 0);
    const genMs = r.reduce((a, x) => a + (x.totalMs - x.ttfbMs), 0);
    return {
      requests: t.requests.length,
      inputTokens: r.reduce((a, x) => a + x.inputTokens, 0),
      outputTokens: out,
      genTokPerS: genMs > 0 && out > 0 ? Math.round((out / genMs) * 10000) / 10 : null,
      wallMs: Date.now() - (t.startedAt ?? Date.now()),
      firstTokenMs: t.requests[0] ? t.requests[0].ttfbMs : null,
    };
  }

  // Called by the proxy for every request a worker's CLI makes.
  route(workerId: string): Route | { refuse: string } {
    const w = this.workers.get(workerId);
    if (!w) return { refuse: `unknown worker ${workerId}` };
    const t = w.running;
    if (!t) return { refuse: `worker ${workerId} has no running task` };
    if (w.backend === 'llmd' && !w.loaded && !t.swapApproved) return { refuse: `${w.model} is not loaded and no swap was approved` };
    return {
      upstream: w.url, model: w.model, table: w.table, level: t.effort, temperature: w.temperature, taskId: t.id,
      ...(w.backend === 'openai' ? { api: 'openai' as const, apiKey: w.apiKey } : {}),
    };
  }

  recordRequest(s: RequestStats): void {
    const t = s.taskId ? this.tasks.get(s.taskId) : undefined;
    t?.requests.push(s);
    const w = this.workers.get(s.worker);
    if (w && s.tokPerS !== null && s.outputTokens >= 16) { w.tokPerS = s.tokPerS; this.publish(); }
    this.emitFor(t, { type: 'worker_request', taskId: s.taskId, worker: s.worker, status: s.status, ttfbMs: s.ttfbMs, totalMs: s.totalMs, inputTokens: s.inputTokens, outputTokens: s.outputTokens, tokPerS: s.tokPerS, sent: s.sent });
  }

  cancel(taskId: string, by: string): void {
    const t = this.tasks.get(taskId);
    if (!t) throw new Error(`unknown task ${taskId}`);
    const w = this.workers.get(t.worker)!;
    if (w.backend === 'claude') throw new Error('a Claude subagent stops with Claude\'s turn: stop Claude instead');
    if (t.state === 'running') { t.abort?.abort(); return; } // execute() emits the final state
    if (t.state !== 'queued' && t.state !== 'awaiting_swap') throw new Error(`task ${taskId} already ${t.state}`);
    w.queue = w.queue.filter((q) => q !== t);
    if (t.swapId && this.swaps.delete(t.swapId)) this.emitFor(t, { type: 'swap_resolved', id: t.swapId, decision: 'deny', by });
    t.state = 'cancelled';
    this.emitFor(t, { type: 'task', taskId, worker: w.id, state: 'cancelled', by });
    if (t.internal) t.internal({ taskId, worker: w.id, state: 'cancelled', result: '', output: '' });
    else this.bridge?.onTaskEnd(taskId, w.id, 'cancelled', '', '', '');
    this.publish();
    this.schedule(w);
  }

  resolveSwap(id: string, allow: boolean, by: string): void {
    const taskId = this.swaps.get(id);
    if (!taskId) throw new Error(`no pending swap ${id}`);
    this.swaps.delete(id);
    const t = this.tasks.get(taskId)!;
    this.emitFor(t, { type: 'swap_resolved', id, decision: allow ? 'allow' : 'deny', by });
    if (!allow) return this.cancel(taskId, by);
    t.swapApproved = true;
    t.state = 'queued';
    this.schedule(this.workers.get(t.worker)!);
  }

  /** Whether a worker has a task running or waiting. */
  busy(id: string): boolean {
    const w = this.workers.get(id);
    return Boolean(w && (w.running || w.queue.length || w.active?.length));
  }

  /** Ids in use: the fleet file's workers, Apple's and Claude's, and endpoints'. */
  workerIds(): string[] {
    return [...this.workers.keys()];
  }

  /**
   * The workers added in Settings, the whole set each time (endpoints.ts): new ones join, removed ones go, changed ones
   * take their new URL, key, model or name (a running task's next request goes to the new place). A fleet file's worker
   * with the same id wins. Its effort and temperature stay as set here.
   */
  syncEndpoints(defs: WorkerDef[]): void {
    const want = new Map(defs.map((d) => [d.id, d]));
    for (const w of [...this.workers.values()]) {
      if (!w.fromSettings || want.has(w.id)) continue;
      for (const t of w.queue) this.cancel(t.id, 'duet');
      w.running?.abort?.abort();
      this.workers.delete(w.id);
    }
    for (const d of defs) {
      const w = this.workers.get(d.id);
      if (w && !w.fromSettings) continue;
      if (!w) {
        this.workers.set(d.id, { ...d, effort: EFFORT_TABLES[d.table].default, available: false, loaded: false, running: null, queue: [], tokPerS: null, fromSettings: true });
        continue;
      }
      const moved = w.url !== d.url || w.model !== d.model || w.apiKey !== d.apiKey;
      Object.assign(w, { label: d.label, url: d.url, model: d.model, apiKey: d.apiKey, enabled: d.enabled });
      if (moved) { w.checkedAt = undefined; w.tokPerS = null; w.loaded = false; }
      if (!d.enabled) w.checkedAt = undefined;
    }
    this.publish();
    void this.refresh();
  }

  setWorker(id: string, opts: { effort?: string; temperature?: number | null; enabled?: boolean; model?: string }): void {
    const w = this.workers.get(id);
    if (!w) throw new Error(`unknown worker ${id}`);
    // Switching model loads nothing now: the next task on an unloaded model raises a swap card first.
    if (opts.model !== undefined && opts.model !== w.model) {
      if (w.backend !== 'llmd') throw new Error(`${id}'s model is fixed`);
      const table = tableForModel(opts.model);
      if (!table || !this.chatModels.includes(opts.model)) throw new Error(`${opts.model} is not a worker model`);
      if (w.running || w.queue.length) throw new Error(`${id} is busy; switch models when it is idle`);
      w.model = opts.model;
      w.loaded = [...this.readyOnDevice.values()].flat().includes(opts.model);
      w.table = table;
      w.effort = EFFORT_TABLES[table].default;
      w.tokPerS = null;
      void this.refresh();
    }
    if (opts.effort !== undefined && opts.effort !== w.effort) {
      if (!validLevel(w.table, opts.effort)) throw new Error(`effort ${opts.effort} not offered by ${id}`);
      w.effort = opts.effort;
    }
    if (opts.temperature !== undefined) w.temperature = opts.temperature ?? undefined;
    if (opts.enabled !== undefined) w.enabled = opts.enabled;
    if (opts.enabled) w.checkedAt = undefined;
    this.publish();
    if (opts.enabled) void this.refresh();
  }
}

/** The text of files for an Apple worker, each under its path; refused if any can't be read or it's all too long. */
export function appleInput(files: string[]): string {
  let out = '';
  for (const f of files) {
    if (!existsSync(f) || !statSync(f).isFile()) throw new Error(`${f} is not a file`);
    if (statSync(f).size > APPLE_INPUT_MAX * 2) throw new Error(`${f} is too big for an Apple worker (${Math.round(statSync(f).size / 1000)} KB)`);
    const text = readFileSync(f, 'utf8');
    if (text.slice(0, 8192).includes('\0')) throw new Error(`${f} isn't text`);
    out += `${out ? '\n\n' : ''}=== ${f} ===\n${text}`;
  }
  if (out.length > APPLE_INPUT_MAX) throw new Error(`the files come to ${Math.round(out.length / 1000)} KB of text; an Apple worker takes up to ${APPLE_INPUT_MAX / 1000} KB`);
  return out;
}

/** Tokens written per second spent writing, as the device timed it; unknown when it didn't (time spent reading a
 *  long input would make a speed from the whole run meaningless). */
function appleTokPerS(a?: AppleStats): number | null {
  return a?.genMs && a.genMs > 0 && a.outputTokens > 0 ? Math.round((a.outputTokens / a.genMs) * 10000) / 10 : null;
}

/** A local worker's tool calls as the hub counted them, and the profile that set its tools. */
export type ToolsUsed = { used: ToolCount[]; profile: ProfileId };

/**
 * The files a local task names (delegate's `files`) that lie outside its folder, as absolute paths: its guard lets it
 * read exactly these. Each must be a file that exists, since that's all the worker could do with it; anything else is
 * refused here, by name, rather than by the guard once the worker is under way.
 */
export function readableOutside(files: string[], cwd: string): string[] {
  const root = resolve(cwd);
  const outside = [...new Set(files.map((f) => resolve(root, f)))].filter((f) => f !== root && !f.startsWith(root + sep));
  const bad = outside.filter((f) => {
    try {
      return !statSync(f).isFile();
    } catch {
      return true;
    }
  });
  if (!bad.length) return outside;
  const what = bad.length === 1 ? `${bad[0]} is outside the task's folder ${root} and isn't a file` : `${bad.join(', ')} are outside the task's folder ${root} and aren't files`;
  throw new Error(`${what}. A worker can read files outside its folder that you pass in \`files\`, but never folders or missing paths there: pass the files themselves, set cwd to that folder, or do that part yourself.`);
}

/** Files a task names by path (absolute, `~/…`, or relative to its folder, with any `:line` dropped) that exist. */
export function filesNamedIn(prompt: string, cwd: string): string[] {
  const found = new Set<string>();
  for (const word of prompt.split(/\s+/)) {
    const p = word.replace(/^[("'`<[]+/, '').replace(/[)"'`>\],;!?]+$/, '').replace(/:\d+(?:[-–]\d+)?$/, '').replace(/[.:]+$/, '');
    if (!p || !(p.includes('/') || /\.\w{1,8}$/.test(p))) continue;
    const full = p.startsWith('~/') ? join(homedir(), p.slice(2)) : isAbsolute(p) ? p : join(cwd, p);
    try {
      if (statSync(full).isFile()) found.add(full);
    } catch {
      // Not a file: just a word with a slash or a dot.
    }
    if (found.size === 8) break;
  }
  return [...found];
}

/** Why a worker task stopped before finishing: its turns ran out, or its model's room did. */
export type Stopped = { reason: 'turn_limit' | 'context'; turns: number; context?: number };

/** Claude Code's ways of saying the conversation no longer fits, even after compacting. */
export const OUT_OF_ROOM = /Autocompact is thrashing|prompt is too long|context (?:window|length) (?:exceeded|is too)|too large for the context/i;

/** A stopped worker's own last words: what it last wrote (the end of it), without Claude Code's error. */
export function stoppedWords(output: string[]): string {
  const said = output.filter((x) => x.trim() && !OUT_OF_ROOM.test(x)).slice(-3).join('\n\n').trim();
  return said.length > 1500 ? `…${said.slice(-1500)}` : said;
}

/** A stopped task's result: why it stopped, then its own last words. */
export function stoppedResult(s: Stopped, output: string[]): string {
  const tail = stoppedWords(output);
  const why = s.reason === 'turn_limit'
    ? `Stopped at its ${s.turns}-turn limit before finishing.`
    : `Stopped before finishing: the work kept outgrowing its model's ${s.context ? `${s.context.toLocaleString('en-US')}-token ` : ''}context, even after compacting. Give it smaller pieces, or a model with more room.`;
  return `${why}${tail ? ` Its progress so far, in its own words:\n${tail}` : ' It wrote nothing about its progress; the changes below are what it did.'}`;
}

/**
 * The workers from configuration: a fleet file's, exactly as before; with none, the one Ollama worker defaultWorkers()
 * makes. `hasEndpoints`: endpoints were added in Settings, which then stand in for that implicit default (unless
 * DUET_OLLAMA_URL or DUET_OLLAMA_MODEL asks for it). Settings' endpoints join these (Fleet.syncEndpoints).
 */
export function loadWorkers(file: string, opts: { hasEndpoints?: boolean; env?: NodeJS.ProcessEnv } = {}): WorkerDef[] {
  const env = opts.env ?? process.env;
  if (!existsSync(file)) return opts.hasEndpoints && !env.DUET_OLLAMA_URL && !env.DUET_OLLAMA_MODEL ? [] : defaultWorkers(env);
  const j = JSON.parse(readFileSync(file, 'utf8')) as { workers: WorkerDef[] };
  return j.workers;
}

export const DEFAULT_FLEET_FILE = join(homedir(), '.config/duet/fleet.json');
/** A fleet kept beside the hub's code (git-ignored; `make deploy-hub` copies it with the code). */
export const LOCAL_FLEET_FILE = fileURLToPath(new URL('../fleet.local.json', import.meta.url));

/** The fleet file to use when DUET_FLEET isn't set: ~/.config/duet/fleet.json, else hub/fleet.local.json. Neither:
 *  defaultWorkers(). */
export function defaultFleetFile(): string {
  return existsSync(DEFAULT_FLEET_FILE) ? DEFAULT_FLEET_FILE : LOCAL_FLEET_FILE;
}
