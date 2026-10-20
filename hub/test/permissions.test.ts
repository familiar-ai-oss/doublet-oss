// Permission modes: how Claude asks before it acts. A device switches the mode live (Claude Code is told, the mode is
// saved and every device hears it); the next session starts in it; and Claude leaving plan mode is followed. Leaving
// plan mode is an approval that carries the plan: approving starts the work, rejecting keeps Claude planning.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Lead } from '../src/lead.ts';
import { PERMISSION_MODES, type EventBody, type PermissionMode } from '../src/protocol.ts';
import { StateFile } from '../src/store.ts';

const dirs: string[] = [];
after(() => { for (const d of dirs) rmSync(d, { recursive: true, force: true }); });

const cfg = { model: 'haiku', effort: 'low' as const, cwd: '/tmp', autoAllow: [], log: () => {} };

/** A lead with a saved state of its own, and a stand-in for Claude Code's session that records mode switches. */
function setup(dir = mkdtempSync(join(tmpdir(), 'duet-modes-'))) {
  dirs.push(dir);
  const events: EventBody[] = [];
  const state = new StateFile(dir);
  const lead = new Lead(cfg, (e) => events.push(e), state, 0);
  const calls: string[] = [];
  const refuse = new Set<string>();
  lead['q'] = {
    setPermissionMode: async (m: string) => {
      if (refuse.has(m)) throw new Error(`Cannot set permission mode to ${m}: not available`);
      calls.push(m);
    },
    supportedModels: async () => [],
  } as never;
  const infos = () => events.filter((e) => e.type === 'lead_info');
  return { dir, lead, events, state, calls, refuse, infos, mode: () => infos().at(-1)?.permissionMode };
}

type Card = Extract<EventBody, { type: 'approval_request' }>;
type Resolved = Extract<EventBody, { type: 'approval_resolved' }>;
const cardsOf = (events: EventBody[]) => events.filter((e): e is Card => e.type === 'approval_request');
const resolvedOf = (events: EventBody[]) => events.filter((e): e is Resolved => e.type === 'approval_resolved');
const settled = () => new Promise((r) => setImmediate(r));
const opts = (toolUseID: string) => ({ signal: new AbortController().signal, toolUseID, requestId: `r-${toolUseID}` }) as never;
const status = (permissionMode: string) => ({ type: 'system', subtype: 'status', status: null, permissionMode, uuid: 'u', session_id: 's' }) as never;

const PLAN = '# Plan\n1. Add `set_permission_mode`\n2. Test it on the sandbox';
const PLAN_FILE = '/home/you/.claude/plans/permission-modes.md';

test('a device switches the mode: Claude Code is told, the mode is saved, and every device hears it', async () => {
  const { lead, state, calls, mode } = setup();
  await lead.setPermissionMode('acceptEdits', 'ipad');
  assert.deepEqual(calls, ['acceptEdits']);
  assert.equal(state.read().permissionMode, 'acceptEdits');
  assert.equal(mode(), 'acceptEdits');
});

test('the five modes the app offers are taken; anything else is refused, and nothing changes', async () => {
  const { lead, state, calls, infos } = setup();
  for (const m of PERMISSION_MODES) await lead.setPermissionMode(m, 'mac');
  assert.deepEqual(calls, ['default', 'acceptEdits', 'auto', 'plan', 'bypassPermissions']);
  const sent = infos().length;
  await assert.rejects(lead.setPermissionMode('dontAsk' as PermissionMode, 'mac'), /unknown permission mode dontAsk; choose one of default, acceptEdits, auto, plan, bypassPermissions/);
  await assert.rejects(lead.setPermissionMode('yolo' as PermissionMode, 'mac'), /unknown permission mode yolo/);
  assert.equal(calls.length, 5, 'Claude Code was never asked');
  assert.equal(state.read().permissionMode, 'bypassPermissions');
  assert.equal(infos().length, sent, 'no device heard of it');
});

test("a mode Claude Code won't take is an error for the device that asked, and the mode stays", async () => {
  const { lead, state, refuse, mode } = setup();
  await lead.setPermissionMode('plan', 'mac');
  refuse.add('auto');
  await assert.rejects(lead.setPermissionMode('auto', 'ipad'), /Cannot set permission mode to auto/);
  assert.equal(state.read().permissionMode, 'plan');
  assert.equal(mode(), 'plan');
});

test('the next session starts in the saved mode, with Bypass Permissions there to switch on', async () => {
  const first = setup();
  const fresh = first.lead['options']();
  assert.equal(fresh.permissionMode, 'default', 'a hub that never had a mode asks about each call');
  assert.equal(fresh.allowDangerouslySkipPermissions, true);

  await first.lead.setPermissionMode('plan', 'mac');
  const restarted = setup(first.dir);
  const o = restarted.lead['options']();
  assert.equal(o.permissionMode, 'plan');
  assert.equal(o.allowDangerouslySkipPermissions, true);
  await restarted.lead['publishInfo']();
  assert.equal(restarted.mode(), 'plan', 'devices hear the mode the restarted lead is in');

  // A state file with a mode this hub doesn't know starts in the default.
  const odd = mkdtempSync(join(tmpdir(), 'duet-modes-'));
  writeFileSync(join(odd, 'state.json'), JSON.stringify({ permissionMode: 'dontAsk' }));
  assert.equal(setup(odd).lead['options']().permissionMode, 'default');
});

test('the mode Claude Code reports is followed: Claude leaving plan mode is saved and sent to every device', async () => {
  const { lead, state, infos, mode } = setup();
  await lead.setPermissionMode('plan', 'mac');
  lead['handle'](status('acceptEdits'));
  await settled();
  assert.equal(mode(), 'acceptEdits');
  assert.equal(state.read().permissionMode, 'acceptEdits');

  const sent = infos().length;
  lead['handle'](status('acceptEdits'));
  lead['handle'](status('dontAsk'));
  await settled();
  assert.equal(infos().length, sent, 'the same mode again, or one Duet has no use for, changes nothing');

  // Each turn's init carries the mode too.
  lead['sessionId'] = 's-1';
  lead['sessionCreated'] = true;
  lead['handle']({ type: 'system', subtype: 'init', apiKeySource: 'none', session_id: 's-1', permissionMode: 'default' } as never);
  await settled();
  assert.equal(mode(), 'default');
  assert.equal(state.read().permissionMode, 'default');
});

test('leaving plan mode: the card carries the plan, and approving hands Claude Code the call as it was (an unchanged plan)', async () => {
  const { lead, events } = setup();
  const decided = lead['ask']('ExitPlanMode', { plan: PLAN, planFilePath: PLAN_FILE }, opts('tu-1'));
  const [card] = cardsOf(events);
  assert.equal(card.plan, PLAN);
  assert.equal(card.tool, 'ExitPlanMode');
  lead.approve(card.id, 'ipad');
  assert.deepEqual(await decided, { behavior: 'allow', updatedInput: { plan: PLAN, planFilePath: PLAN_FILE } });
});

test('an edited plan goes to Claude Code as the plan, without the edit note other calls get', async () => {
  const { lead, events } = setup();
  const decided = lead['ask']('ExitPlanMode', { plan: PLAN, planFilePath: PLAN_FILE }, opts('tu-2'));
  const edited = `${PLAN}\n3. Ask before Bypass Permissions`;
  lead.approve(cardsOf(events)[0].id, 'ipad', { plan: edited, planFilePath: PLAN_FILE });
  assert.deepEqual(await decided, { behavior: 'allow', updatedInput: { plan: edited, planFilePath: PLAN_FILE } });
  assert.equal(lead['edits'].size, 0, 'Claude Code tells Claude the plan was edited itself');
  assert.equal(resolvedOf(events)[0].edited, true);
});

test('a plan that is not approved keeps Claude planning: with the note, or told to ask what to change', async () => {
  const { lead, events } = setup();
  const withNote = lead['ask']('ExitPlanMode', { plan: PLAN, planFilePath: PLAN_FILE }, opts('tu-3'));
  lead.reject(cardsOf(events)[0].id, 'ipad', '  Use a queue instead ');
  assert.deepEqual(await withNote, { behavior: 'deny', message: 'The user wants you to keep planning: Use a queue instead' });
  assert.equal(resolvedOf(events)[0].message, 'Use a queue instead', 'devices see the note as written');

  const bare = lead['ask']('ExitPlanMode', { plan: PLAN, planFilePath: PLAN_FILE }, opts('tu-4'));
  lead.reject(cardsOf(events)[1].id, 'mac');
  const r = (await bare) as { behavior: string; message?: string };
  assert.equal(r.behavior, 'deny');
  assert.match(r.message ?? '', /keep planning, and didn't say what to change\. Ask them\./);
});

test("other calls' cards carry no plan, and a rejection without a note reads as before", async () => {
  const { lead, events } = setup();
  const decided = lead['ask']('Bash', { command: 'ls', plan: 'not a plan' }, opts('tu-5'));
  const [card] = cardsOf(events);
  assert.ok(!('plan' in card), 'only ExitPlanMode carries a plan');
  lead.reject(card.id, 'mac');
  assert.deepEqual(await decided, { behavior: 'deny', message: 'The user rejected this tool call.' });
});
