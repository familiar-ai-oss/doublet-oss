// Reconnecting hub client: tracks lastSeq, drops duplicates, and reports gaps. Used by cli.ts and the tests;
// the Swift client implements the same rules.
import { EventEmitter } from 'node:events';
import WebSocket from 'ws';
import { PROTOCOL_VERSION, isSequenced, type ClientMsg, type ControlFrame, type HubEvent, type ServerFrame } from './protocol.ts';

export type ClientOptions = { url: string; device: string; token: string; lastSeq?: number; reconnect?: boolean; reconnectDelayMs?: number; headers?: Record<string, string> };

type DistributiveOmit<T, K extends keyof never> = T extends unknown ? Omit<T, K> : never;
export type Ack = Extract<ControlFrame, { type: 'ack' }>;
export type Command = DistributiveOmit<Exclude<ClientMsg, { type: 'hello' }>, 'ref'>;

export class HubClient extends EventEmitter {
  lastSeq: number;
  gaps: { expected: number; got: number }[] = [];
  duplicates = 0;
  private ws: WebSocket | null = null;
  private closedByUser = false;
  private nextRef = 1;
  private acks = new Map<string, { resolve: (a: Ack) => void; reject: (e: Error) => void }>();
  private backoff = 250;

  private opts: ClientOptions;

  constructor(opts: ClientOptions) {
    super();
    this.opts = opts;
    this.lastSeq = opts.lastSeq ?? 0;
  }

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.opts.url, { headers: this.opts.headers });
      this.ws = ws;
      let welcomed = false;
      ws.on('open', () => {
        ws.send(JSON.stringify({ type: 'hello', protocol: PROTOCOL_VERSION, token: this.opts.token, device: this.opts.device, lastSeq: this.lastSeq } satisfies ClientMsg));
      });
      ws.on('message', (raw) => {
        const f = JSON.parse(String(raw)) as ServerFrame;
        if (isSequenced(f)) return this.onEvent(f);
        this.onControl(f);
        if (f.type === 'replay_done' && !welcomed) { welcomed = true; this.backoff = 250; resolve(); }
        if (f.type === 'fatal') reject(new Error(f.error));
      });
      ws.on('unexpected-response', (_req, res) => reject(new Error(`upgrade refused: HTTP ${res.statusCode}`)));
      ws.on('error', (e) => { if (!welcomed) reject(e); });
      ws.on('close', (code) => {
        for (const a of this.acks.values()) a.reject(new Error('connection closed'));
        this.acks.clear();
        this.emit('disconnected', code);
        if (welcomed && !this.closedByUser && this.opts.reconnect !== false) setTimeout(() => this.reconnectLoop(), this.opts.reconnectDelayMs ?? this.backoff);
      });
    });
  }

  private async reconnectLoop(): Promise<void> {
    while (!this.closedByUser) {
      try {
        await this.connect();
        this.emit('reconnected', this.lastSeq);
        return;
      } catch {
        this.backoff = Math.min(this.backoff * 2, 10_000);
        await new Promise((r) => setTimeout(r, this.backoff));
      }
    }
  }

  private onEvent(e: HubEvent): void {
    if (e.seq <= this.lastSeq) { this.duplicates++; return; }
    if (e.seq !== this.lastSeq + 1) this.gaps.push({ expected: this.lastSeq + 1, got: e.seq });
    this.lastSeq = e.seq;
    this.emit('event', e);
  }

  private onControl(f: ControlFrame): void {
    if (f.type === 'welcome' && f.reset) this.lastSeq = 0;
    if (f.type === 'ack') {
      const a = this.acks.get(f.ref);
      this.acks.delete(f.ref);
      if (f.ok) a?.resolve(f); else a?.reject(new Error(f.error));
    }
    this.emit('control', f);
  }

  send(cmd: Command): Promise<Ack> {
    const ref = String(this.nextRef++);
    return new Promise((resolve, reject) => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return reject(new Error('not connected'));
      this.acks.set(ref, { resolve, reject });
      this.ws.send(JSON.stringify({ ...cmd, ref }));
    });
  }

  // Drop the socket without a close handshake, as a network failure would. Reconnect follows if enabled.
  dropConnection(): void {
    this.ws?.terminate();
  }

  close(): void {
    this.closedByUser = true;
    this.ws?.close();
  }

  // Resolve with the first event matching pred (from now on).
  waitFor<T extends HubEvent>(pred: (e: HubEvent) => e is T, timeoutMs?: number): Promise<T>;
  waitFor(pred: (e: HubEvent) => boolean, timeoutMs?: number): Promise<HubEvent>;
  waitFor(pred: (e: HubEvent) => boolean, timeoutMs = 120_000): Promise<HubEvent> {
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => { this.off('event', on); reject(new Error(`timed out after ${timeoutMs}ms`)); }, timeoutMs);
      const on = (e: HubEvent) => {
        if (pred(e)) { clearTimeout(t); this.off('event', on); resolve(e); }
      };
      this.on('event', on);
    });
  }
}
