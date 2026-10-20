// Apple workers: each connected device whose Apple Intelligence is available can run tasks on its on-device model.
// The hub sends a task (its prompt and the text of any files named) to that device's connection; the device streams
// progress and reports the outcome. A task belongs to the device it was sent to, and ends if that device goes away.
import type { AppleStats, AppleStatus, ControlFrame } from './protocol.ts';

export type AppleOutcome = { ok: boolean; result: string; error?: string; stats?: AppleStats };

type Conn = { send: (f: ControlFrame) => void; status: AppleStatus };
type Run = { device: string; send: (f: ControlFrame) => void; resolve: (o: AppleOutcome) => void; onProgress: (text: string) => void; timer: NodeJS.Timeout };

/** How long a device may take with one task (a long input is many passes of the model). */
const RUN_LIMIT_MS = 15 * 60_000;

export class AppleDevices {
  private conns = new Map<string, Conn>();
  private runs = new Map<string, Run>();
  private log: (m: string) => void;
  /** Called whenever a device's availability changes (the fleet updates its workers). */
  onChange: () => void = () => {};

  constructor(log: (m: string) => void) {
    this.log = log;
  }

  /** A device reported its on-device model. The latest connection to report is the one tasks go to. */
  status(device: string, send: (f: ControlFrame) => void, s: AppleStatus): void {
    const before = this.conns.get(device)?.status;
    this.conns.set(device, { send, status: s });
    if (JSON.stringify(before) !== JSON.stringify(s)) this.log(`${device}: Apple Intelligence ${s.available ? `available (${s.variant ? `${s.variant}, ` : ''}${s.contextSize ?? '?'} tokens)` : `unavailable (${s.reason ?? 'no reason given'})`}`);
    this.onChange();
  }

  /** A connection closed. If it was the one that reported, the device's model is gone, and so are its tasks. */
  disconnected(device: string, send: (f: ControlFrame) => void): void {
    if (this.conns.get(device)?.send !== send) return;
    this.conns.delete(device);
    for (const [id, r] of this.runs) if (r.device === device) this.finish(id, { ok: false, result: '', error: `${device} disconnected before the task finished` });
    this.onChange();
  }

  info(device: string): AppleStatus | undefined {
    return this.conns.get(device)?.status;
  }

  devices(): [string, AppleStatus][] {
    return [...this.conns.entries()].map(([d, c]) => [d, c.status]);
  }

  run(device: string, taskId: string, task: { prompt: string; input?: string; temperature?: number }, onProgress: (text: string) => void, signal: AbortSignal): Promise<AppleOutcome> {
    const c = this.conns.get(device);
    if (!c?.status.available) return Promise.resolve({ ok: false, result: '', error: `${device}'s Apple Intelligence isn't available` });
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        c.send({ type: 'apple_cancel', taskId });
        this.finish(taskId, { ok: false, result: '', error: `no answer from ${device} in ${RUN_LIMIT_MS / 60_000} minutes` });
      }, RUN_LIMIT_MS);
      this.runs.set(taskId, { device, send: c.send, resolve, onProgress, timer });
      signal.addEventListener('abort', () => {
        c.send({ type: 'apple_cancel', taskId });
        this.finish(taskId, { ok: false, result: '', error: 'cancelled' });
      });
      c.send({ type: 'apple_task', taskId, prompt: task.prompt, ...(task.input ? { input: task.input } : {}), ...(task.temperature !== undefined ? { temperature: task.temperature } : {}) });
    });
  }

  /** Progress from the device running a task (anyone else's is ignored). */
  progress(device: string, taskId: string, text: string): void {
    const r = this.runs.get(taskId);
    if (r?.device === device && text.trim()) r.onProgress(text);
  }

  done(device: string, taskId: string, o: AppleOutcome): void {
    if (this.runs.get(taskId)?.device === device) this.finish(taskId, o);
  }

  private finish(taskId: string, o: AppleOutcome): void {
    const r = this.runs.get(taskId);
    if (!r) return;
    this.runs.delete(taskId);
    clearTimeout(r.timer);
    r.resolve(o);
  }
}

/** "Apple Intelligence · iPad", "· Mac Simulator"…: the device's kind, as the fleet shows it. */
export function appleLabel(s: AppleStatus): string {
  const kind = s.platform === 'mac' ? 'Mac' : s.platform === 'ipad' ? 'iPad' : 'iPhone';
  return `Apple Intelligence · ${kind}${s.simulator ? ' Simulator' : ''}`;
}

/** Why a device's model can't run, in words. */
export function appleReason(reason?: string): string {
  switch (reason) {
    case 'deviceNotEligible': return 'this device does not support Apple Intelligence';
    case 'appleIntelligenceNotEnabled': return 'Apple Intelligence is off in Settings';
    case 'modelNotReady': return 'the model is still downloading or getting ready';
    case undefined: return 'unavailable';
    default: return reason;
  }
}
