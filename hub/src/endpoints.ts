// OpenAI-compatible endpoints the user adds in Settings → Agents (vLLM, Ollama's /v1, LM Studio, llama.cpp, or a hosted
// API): each one is a worker. Kept in the hub's state folder (endpoints.json, readable only by the hub's user, since it
// holds API keys). A key never leaves the hub: clients see only whether one is set.
//
// The fleet file and DUET_OLLAMA_* still work as before (fleet.ts loadWorkers); these are added beside them.
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { EndpointTest, EndpointView } from './protocol.ts';
import type { WorkerDef } from './fleet.ts';

export type Endpoint = { id: string; name: string; baseUrl: string; model: string; apiKey?: string; enabled: boolean };

export type EndpointInput = { name: string; baseUrl: string; model: string; apiKey?: string; enabled?: boolean };
/** apiKey: a new key, null to remove it, or absent to keep it. */
export type EndpointChange = { name?: string; baseUrl?: string; model?: string; apiKey?: string | null; enabled?: boolean };

/** A base URL as stored: http(s), no trailing slash, ending in /v1 (where /models and /chat/completions live). */
export function normalizeBaseUrl(raw: string): string {
  const s = raw.trim().replace(/\/+$/, '');
  let u: URL;
  try { u = new URL(s); } catch { throw new Error(`${raw.trim() || 'The base URL'} isn't a URL: use one like http://127.0.0.1:8000/v1`); }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') throw new Error('The base URL must start with http:// or https://');
  if (u.search || u.hash) throw new Error('The base URL takes no ?query or #fragment');
  if (!/\/v1$/.test(u.pathname)) throw new Error(`The base URL must end in /v1 (e.g. ${u.origin}/v1)`);
  return s;
}

/** A worker id from a name: lowercase letters, digits and dashes (the proxy routes on it), not one already taken. */
export function endpointId(name: string, taken: ReadonlySet<string>): string {
  const base = name.toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 32) || 'endpoint';
  // Prefixes the hub gives its own workers.
  const safe = /^(apple|claude)-/.test(base) || base === 'auto' ? `ep-${base}` : base;
  if (!taken.has(safe)) return safe;
  for (let i = 2; ; i++) if (!taken.has(`${safe}-${i}`)) return `${safe}-${i}`;
}

export function endpointView(e: Endpoint): EndpointView {
  return { id: e.id, name: e.name, baseUrl: e.baseUrl, model: e.model, hasApiKey: Boolean(e.apiKey), enabled: e.enabled };
}

/** An endpoint as a fleet worker. Its effort table is none: OpenAI-compatible servers have no one thinking switch. */
export function endpointWorker(e: Endpoint): WorkerDef {
  return { id: e.id, label: `${e.name} · ${e.model}`, backend: 'openai', url: e.baseUrl, model: e.model, apiKey: e.apiKey, table: 'none', enabled: e.enabled };
}

export class EndpointStore {
  readonly file: string;
  private items: Endpoint[];
  /** Ids used elsewhere (the fleet file's workers), which a new endpoint mustn't take. */
  reserved: () => Iterable<string> = () => [];

  constructor(dir: string) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    this.file = join(dir, 'endpoints.json');
    this.items = existsSync(this.file) ? load(this.file) : [];
  }

  list(): Endpoint[] {
    return this.items.map((e) => ({ ...e }));
  }

  get(id: string): Endpoint | undefined {
    const e = this.items.find((x) => x.id === id);
    return e && { ...e };
  }

  add(input: EndpointInput): Endpoint {
    const name = cleanName(input.name);
    const model = cleanModel(input.model);
    const baseUrl = normalizeBaseUrl(input.baseUrl);
    const taken = new Set([...this.reserved(), ...this.items.map((e) => e.id)]);
    const apiKey = input.apiKey?.trim();
    const e: Endpoint = { id: endpointId(name, taken), name, baseUrl, model, ...(apiKey ? { apiKey } : {}), enabled: input.enabled ?? true };
    this.items.push(e);
    this.save();
    return { ...e };
  }

  update(id: string, c: EndpointChange): Endpoint {
    const i = this.items.findIndex((x) => x.id === id);
    if (i < 0) throw new Error(`no endpoint ${id}`);
    // Checked whole before anything changes: a bad URL leaves the name as it was too.
    const next: Endpoint = { ...this.items[i] };
    if (c.name !== undefined) next.name = cleanName(c.name);
    if (c.model !== undefined) next.model = cleanModel(c.model);
    if (c.baseUrl !== undefined) next.baseUrl = normalizeBaseUrl(c.baseUrl);
    if (c.enabled !== undefined) next.enabled = c.enabled;
    if (c.apiKey !== undefined) {
      const key = c.apiKey?.trim();
      if (key) next.apiKey = key;
      else delete next.apiKey;
    }
    this.items[i] = next;
    this.save();
    return { ...next };
  }

  remove(id: string): void {
    const n = this.items.length;
    this.items = this.items.filter((e) => e.id !== id);
    if (this.items.length === n) throw new Error(`no endpoint ${id}`);
    this.save();
  }

  private save(): void {
    writeFileSync(this.file + '.tmp', JSON.stringify({ endpoints: this.items }, null, 2) + '\n', { mode: 0o600 });
    renameSync(this.file + '.tmp', this.file);
  }
}

function load(file: string): Endpoint[] {
  const j = JSON.parse(readFileSync(file, 'utf8')) as { endpoints?: Partial<Endpoint>[] };
  return (j.endpoints ?? []).filter((e): e is Endpoint => typeof e.id === 'string' && typeof e.baseUrl === 'string' && typeof e.model === 'string')
    .map((e) => ({ ...e, name: e.name || e.id, enabled: e.enabled !== false }));
}

function cleanName(s: string): string {
  const n = (s ?? '').trim();
  if (!n) throw new Error('Give the endpoint a name');
  if (n.length > 60) throw new Error('Keep the name under 60 characters');
  return n;
}

function cleanModel(s: string): string {
  const m = (s ?? '').trim();
  if (!m) throw new Error('Pick a model (Test Connection lists what the server has)');
  return m;
}

/** The headers an endpoint's requests carry: its key as a bearer token, when it has one. */
export function authHeaders(apiKey?: string): Record<string, string> {
  return apiKey ? { authorization: `Bearer ${apiKey}` } : {};
}

/** A model as GET /v1/models lists it, with the window some servers report (vLLM max_model_len, OpenRouter and LM
 *  Studio context_length). */
export type ListedModel = { id: string; context?: number };

export function modelsIn(body: unknown): ListedModel[] {
  const data = (body as { data?: unknown })?.data ?? (body as { models?: unknown })?.models;
  if (!Array.isArray(data)) return [];
  return data.flatMap((m) => {
    const id = typeof m === 'string' ? m : (m as { id?: unknown })?.id;
    if (typeof id !== 'string' || !id) return [];
    const r = m as { max_model_len?: unknown; context_length?: unknown; max_context_length?: unknown };
    const ctx = [r.max_model_len, r.context_length, r.max_context_length].find((n) => typeof n === 'number' && n > 0) as number | undefined;
    return [{ id, ...(ctx ? { context: ctx } : {}) }];
  });
}

/** GET {baseUrl}/models: the models it lists. Throws with a message for people. */
export async function listModels(baseUrl: string, apiKey?: string, timeoutMs = 8000): Promise<ListedModel[]> {
  let r: Response;
  try {
    r = await fetch(`${baseUrl}/models`, { headers: { accept: 'application/json', ...authHeaders(apiKey) }, signal: AbortSignal.timeout(timeoutMs) });
  } catch (e) {
    throw new Error(fetchError(e, baseUrl, timeoutMs));
  }
  const text = await r.text();
  if (!r.ok) {
    const why = r.status === 401 || r.status === 403 ? (apiKey ? 'the API key was refused' : 'it needs an API key') : `HTTP ${r.status}`;
    throw Object.assign(new Error(`${why}${errorMessage(text) ? `: ${errorMessage(text)}` : ''}`), { status: r.status });
  }
  let body: unknown;
  try { body = JSON.parse(text); } catch { throw Object.assign(new Error('It answered, but not with JSON: is this an OpenAI-compatible /v1 URL?'), { status: r.status }); }
  return modelsIn(body);
}

/** Test Connection: GET /v1/models, and how long it took. */
export async function testEndpoint(baseUrlRaw: string, apiKey?: string): Promise<EndpointTest> {
  const t0 = Date.now();
  let baseUrl: string;
  try { baseUrl = normalizeBaseUrl(baseUrlRaw); } catch (e) { return { ok: false, models: [], error: (e as Error).message, ms: 0 }; }
  try {
    const models = (await listModels(baseUrl, apiKey)).map((m) => m.id);
    return { ok: true, models, ms: Date.now() - t0 };
  } catch (e) {
    const status = (e as { status?: number }).status;
    return { ok: false, models: [], error: (e as Error).message, ms: Date.now() - t0, ...(status ? { status } : {}) };
  }
}

function fetchError(e: unknown, baseUrl: string, timeoutMs: number): string {
  const err = e as { name?: string; cause?: { code?: string; message?: string } };
  if (err.name === 'TimeoutError' || err.name === 'AbortError') return `No answer from ${baseUrl} within ${timeoutMs / 1000} s`;
  const code = err.cause?.code;
  if (code === 'ECONNREFUSED') return `Nothing is listening at ${new URL(baseUrl).host} (connection refused): is the server running?`;
  if (code === 'ENOTFOUND' || code === 'EAI_AGAIN') return `${new URL(baseUrl).hostname} can't be found from the hub's machine`;
  return `Can't reach ${baseUrl}: ${err.cause?.message ?? (e as Error).message}`;
}

/** The message in an OpenAI-style error body ({"error":{"message":…}} or {"error":"…"}), or its start. */
export function errorMessage(text: string): string {
  try {
    const j = JSON.parse(text) as { error?: { message?: string } | string; message?: string; detail?: string };
    const m = typeof j.error === 'string' ? j.error : j.error?.message ?? j.message ?? j.detail;
    if (typeof m === 'string') return m.slice(0, 300);
  } catch { /* not JSON */ }
  return text.trim().slice(0, 200);
}
