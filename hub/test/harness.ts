// Shared test harness: runs a real hub as a child process (own port, state dir, tokens and temp project)
// and one client that keeps every event it accepts.
import { spawn, execFileSync, type ChildProcess } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { deleteSession } from '@anthropic-ai/claude-agent-sdk';
import { HubClient } from '../src/client.ts';
import type { HubEvent } from '../src/protocol.ts';

const ROOT = new URL('..', import.meta.url).pathname;
type Ev<T extends HubEvent['type']> = Extract<HubEvent, { type: T }>;

export function createHarness(name: string, extraEnv: Record<string, string> = {}, fleet?: unknown) {
  const port = 7900 + Math.floor(Math.random() * 90);
  const work = mkdtempSync(join(tmpdir(), `duet-${name}-`));
  const stateDir = join(work, 'state');
  const projectDir = join(work, 'project');
  mkdirSync(projectDir, { recursive: true });
  const env: Record<string, string> = {
    ...(process.env as Record<string, string>),
    DUET_PORT: String(port),
    DUET_STATE_DIR: stateDir,
    DUET_TOKENS: join(work, 'tokens.json'),
    DUET_PROJECT_DIR: projectDir,
    DUET_LEAD_MODEL: process.env.DUET_TEST_MODEL || 'claude-haiku-5-5',
    DUET_LEAD_EFFORT: 'low',
    DUET_ALLOWED_LOGINS: 'tester@example',
    ...extraEnv,
  };
  if (fleet) {
    writeFileSync(join(work, 'fleet.json'), JSON.stringify(fleet));
    env.DUET_FLEET = join(work, 'fleet.json');
  }
  const token = execFileSync(process.execPath, ['--experimental-strip-types', 'src/main.ts', 'token', 'add', 'test'], { cwd: ROOT, env, encoding: 'utf8' }).trim();
  const url = `ws://127.0.0.1:${port}/ws`;

  let hub: ChildProcess;
  const hubLog: string[] = [];
  const events: HubEvent[] = [];
  const client = new HubClient({ url, device: 'test', token, reconnectDelayMs: 2000 });
  client.on('event', (e: HubEvent) => events.push(e));
  // With DUET_FIXTURES_DIR set, every frame this client accepts is recorded in arrival order for the Swift tests.
  const fixtures = process.env.DUET_FIXTURES_DIR;
  if (fixtures) {
    mkdirSync(fixtures, { recursive: true });
    const file = join(fixtures, `${name}.jsonl`);
    writeFileSync(file, '');
    const record = (f: unknown) => appendFileSync(file, JSON.stringify(f) + '\n');
    client.on('event', record);
    client.on('control', record);
  }

  async function startHub(): Promise<void> {
    hub = spawn(process.execPath, ['--experimental-strip-types', 'src/main.ts'], { cwd: ROOT, env, stdio: ['ignore', 'inherit', 'pipe'] });
    hub.stderr!.on('data', (d) => hubLog.push(String(d)));
    for (let i = 0; i < 100; i++) {
      try { if ((await fetch(`http://127.0.0.1:${port}/health`)).ok) return; } catch {}
      await new Promise((r) => setTimeout(r, 100));
    }
    throw new Error('hub did not start:\n' + hubLog.join(''));
  }

  async function stopHub(): Promise<void> {
    const exited = new Promise((r) => hub.once('exit', r));
    hub.kill('SIGTERM');
    await exited;
  }

  const describe = (e: HubEvent) =>
    `${e.seq}:${e.type}` +
    (e.type === 'assistant' ? ` ${JSON.stringify(e.text.slice(0, 80))} tools=${e.toolUses.map((t) => t.name)}` : '') +
    (e.type === 'tool_result' ? ` ${JSON.stringify(e.preview.slice(0, 80))}` : '') +
    (e.type === 'task' ? ` ${e.taskId} ${e.worker} ${e.state}${e.error ? ` ${e.error}` : ''}` : '') +
    (e.type === 'task_progress' ? ` ${e.taskId} ${JSON.stringify((e.text ?? e.tools?.join(' ') ?? e.toolResult ?? '').slice(0, 80))}` : '');

  // First event of this type matching pred at index >= from (already received or still to come).
  function next<T extends HubEvent['type']>(type: T, pred: (e: Ev<T>) => boolean = () => true, from = 0, timeoutMs = 180_000): Promise<Ev<T>> {
    const match = (e: HubEvent): e is Ev<T> => e.type === type && pred(e as Ev<T>);
    const found = events.slice(from).find(match);
    if (found) return Promise.resolve(found);
    return client.waitFor(match, timeoutMs).catch((err) => {
      throw new Error(`${err.message} waiting for ${type}; recent events:\n  ${events.slice(-15).map(describe).join('\n  ')}`);
    });
  }

  function all<T extends HubEvent['type']>(type: T, pred: (e: Ev<T>) => boolean = () => true): Ev<T>[] {
    return events.filter((e): e is Ev<T> => e.type === type && pred(e as Ev<T>));
  }

  async function cleanup(): Promise<void> {
    client.close();
    await stopHub().catch(() => {});
    // Every session this run made (a Clear leaves the earlier one resumable), plus the one state.json names.
    const sids = new Set<string>(events.flatMap((e) => (e.type === 'session' && e.sessionId ? [e.sessionId] : [])));
    try {
      const sid = JSON.parse(readFileSync(join(stateDir, 'state.json'), 'utf8')).leadSessionId;
      if (sid) sids.add(sid);
    } catch {}
    for (const sid of sids) await deleteSession(sid, { dir: projectDir }).catch(() => {});
    // Claude Code keeps a per-cwd project folder; remove the one for this run's temp project.
    rmSync(join(homedir(), '.claude/projects', projectDir.replaceAll('/', '-')), { recursive: true, force: true });
    rmSync(work, { recursive: true, force: true });
  }

  return { port, url, token, work, stateDir, projectDir, env, events, client, startHub, stopHub, next, all, cleanup, hubLog };
}
