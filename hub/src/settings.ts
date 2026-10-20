// The hub's side of Settings → Agents: the coding agents on its machine (agents.ts) and the OpenAI-compatible endpoints
// it keeps (endpoints.ts), which join the fleet as workers.
import { AgentScanner } from './agents.ts';
import { EndpointStore, endpointView, endpointWorker, testEndpoint } from './endpoints.ts';
import type { WorkerDef } from './fleet.ts';
import type { ClientMsg, ControlFrame, EndpointView } from './protocol.ts';

/** What Settings needs of the fleet (Fleet has all of it). */
export type SettingsFleet = {
  syncEndpoints(defs: WorkerDef[]): void;
  busy(id: string): boolean;
  workerIds(): string[];
};

export type SettingsMsg = Extract<ClientMsg, { type: 'agents_list' | 'agents_scan' | 'endpoints_list' | 'endpoint_add' | 'endpoint_update' | 'endpoint_remove' | 'endpoint_test' }>;
type Ack = Extract<ControlFrame, { type: 'ack' }>;
export type SettingsReply = Pick<Ack, 'scan' | 'endpoints' | 'endpoint' | 'test'>;

const SETTINGS_TYPES: ReadonlySet<string> = new Set(['agents_list', 'agents_scan', 'endpoints_list', 'endpoint_add', 'endpoint_update', 'endpoint_remove', 'endpoint_test']);
export const isSettingsMsg = (m: ClientMsg): m is SettingsMsg => SETTINGS_TYPES.has(m.type);

export class Settings {
  private readonly store: EndpointStore;
  private readonly fleet: SettingsFleet;
  private readonly scanner: AgentScanner;
  /** To every connected device, when the endpoints change. */
  private readonly broadcast: (f: ControlFrame) => void;

  constructor(store: EndpointStore, fleet: SettingsFleet, broadcast: (f: ControlFrame) => void, scanner = new AgentScanner()) {
    this.store = store;
    this.fleet = fleet;
    this.broadcast = broadcast;
    this.scanner = scanner;
    // A new endpoint's id mustn't be one of the fleet file's workers.
    store.reserved = () => {
      const mine = new Set(store.list().map((e) => e.id));
      return fleet.workerIds().filter((id) => !mine.has(id));
    };
  }

  /** The endpoints into the fleet, as they are now (at start, and after each change). */
  sync(): void {
    this.fleet.syncEndpoints(this.store.list().map(endpointWorker));
  }

  views(): EndpointView[] {
    return this.store.list().map(endpointView);
  }

  private changed(): void {
    this.sync();
    this.broadcast({ type: 'endpoints', endpoints: this.views() });
  }

  /** One Settings message: what goes in its ack. Throws with a message for people. */
  async handle(msg: SettingsMsg): Promise<SettingsReply> {
    switch (msg.type) {
      case 'agents_list':
        return { scan: await this.scanner.list() };
      case 'agents_scan':
        return { scan: await this.scanner.scan() };
      case 'endpoints_list':
        return { endpoints: this.views() };
      case 'endpoint_add': {
        const e = this.store.add({ name: msg.name, baseUrl: msg.baseUrl, model: msg.model, apiKey: msg.apiKey, enabled: msg.enabled });
        this.changed();
        return { endpoint: endpointView(e) };
      }
      case 'endpoint_update': {
        const e = this.store.update(msg.id, { name: msg.name, baseUrl: msg.baseUrl, model: msg.model, apiKey: msg.apiKey, enabled: msg.enabled });
        this.changed();
        return { endpoint: endpointView(e) };
      }
      case 'endpoint_remove': {
        const e = this.store.get(msg.id);
        if (!e) throw new Error(`no endpoint ${msg.id}`);
        if (this.fleet.busy(msg.id)) throw new Error(`${e.name} has a task running or waiting: stop it (or let it finish), then remove it`);
        this.store.remove(msg.id);
        this.changed();
        return {};
      }
      case 'endpoint_test': {
        const saved = msg.id ? this.store.get(msg.id) : undefined;
        if (msg.id && !saved) throw new Error(`no endpoint ${msg.id}`);
        const baseUrl = msg.baseUrl ?? saved?.baseUrl;
        if (!baseUrl) throw new Error('Give a base URL (or the id of a saved endpoint) to test');
        return { test: await testEndpoint(baseUrl, msg.apiKey ?? saved?.apiKey) };
      }
    }
  }
}
