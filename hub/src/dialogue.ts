// The dialogue bus between the lead (or you) and local workers.
// Every message is a typed card in a task thread: TASK · STEER · QUESTION · ANSWER · STATUS · RESULT · CANCEL · ESCALATE.
//
// Lead side: in-process MCP tools (plan, delegate, await_workers, answer, escalate, steer, cancel, fleet, diagram) plus
//   hooks: PreToolUse keeps Claude's own subagents off the duet tools, and turns an Agent call away before there's a
//   plan or while an idle local worker could take it; PostToolUse injects waiting worker messages mid-turn; Stop keeps
//   the turn going while workers are active or messages are unread, and once for a plan that's out of date (at most
//   MAX_STOP_BLOCKS per turn, under Claude Code's own cap of 8); UserPromptSubmit adds the fleet and the plan.
//   await_workers also returns as soon as you write mid-turn, so Claude Code can hand Claude your message (lead.ts).
// Worker side: ask_lead (blocks until answered) and report, plus hooks: PostToolUse injects STEERs,
//   Stop blocks once until report(final) has been called.
// Loop guards: 12 dialogue messages per message you send; one open question per worker; Pause stops handoffs.
import { createSdkMcpServer, tool } from '@anthropic-ai/claude-agent-sdk';
import type { HookCallbackMatcher, HookEvent, McpSdkServerConfigWithInstance } from '@anthropic-ai/claude-agent-sdk';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { DelegateOpts, ToolsUsed } from './fleet.ts';
import { describeProfiles, PROFILE_IDS, PROFILES, type ProfileId } from './profiles.ts';
import type { CodeRef, DiagramKind, DialogueKind, EventBody, PlanStep } from './protocol.ts';

export const BUDGET_PER_USER_MESSAGE = 12;
export const MAX_STOP_BLOCKS = 7; // Claude Code caps Stop continuations at 8 and reports nothing when it does
export const LEAD = 'lead';
/** Who drew a diagram in a note's thread (not the lead's turn, so it isn't credited to notes in the conversation). */
export const THREAD = 'thread';
/** Who an ESCALATE card is for: you, whichever device you answer on. */
export const YOU = 'you';
const AWAIT_MAX_S = 600;
const ASK_TIMEOUT_MS = 30 * 60_000;
const OUTPUT_MAX = 4000;
/** Claude Code's tool for starting a subagent (called Task in older versions). */
const AGENT_TOOLS = new Set(['Agent', 'Task']);
/** The profile a local worker would use for each kind of Claude subagent. */
const AGENT_PROFILES: Record<string, ProfileId> = { explore: 'explore', plan: 'explore', 'general-purpose': 'general' };
/** An Agent call whose prompt starts like this runs as Claude's own subagent even while a local worker is idle. */
const NEEDS_CLAUDE = /^\s*needs claude\s*:/i;
/** Claude Code's own checklists (the older TodoWrite and the newer task tools). The lead has plan() instead, so there's
 *  one list, and it knows each step's worker and task. */
export const TODO_TOOLS = ['TodoWrite', 'TaskCreate', 'TaskUpdate', 'TaskList', 'TaskGet'];

// When the lead hands work out on its own, and how. Sent as the duet server's instructions.
/** For the lead: Apple's on-device workers, when the user lets it use them (DUET_APPLE_FOR_LEAD). */
const APPLE_FOR_LEAD = "apple-* workers are Apple's on-device model on the user's own iPhone, iPad or Mac: free and private, but small (a 4K context, 8K on newer devices, no tools) and slow on long text (a long log takes minutes). Use them for the gist of logs, outputs and documents you'd otherwise read yourself, and to classify or extract from short text (a few KB, read in one pass): pass the paths as `files` and the hub sends their text. Longer text is read in parts and answered from notes on each part, so counts and totals across it are unreliable: count with grep yourself, and check any number that matters. Not for code changes.";
/** Otherwise long text goes to a local worker: free, with tools and a much bigger context. */
const APPLE_NOT_FOR_LEAD = "For the gist of long logs, outputs and documents, hand them to an idle local worker (profile explore) rather than reading them all yourself. The apple-* workers in fleet() are the user's own on-device model, for the user to give tasks; don't delegate to them.";
const APPLE_LINE = '\u0000apple';
const LEAD_GUIDANCE_PARTS = [
  'Doublet: you lead local worker agents running on GPUs on this machine; fleet() lists them.',
  "Local workers are the default for handing work out: they are free and private. Your own subagents (the Agent tool) are Claude and spend the user's Max plan, so while a local worker that could do the work is idle the hub turns an Agent call away, unless its prompt starts with \"Needs Claude:\" and the reason (judgment a local model lacks, searching the web, or every worker is busy and it can't wait).",
  "Each local worker is one model on its own GPU and runs ONE task at a time: a task for a busy worker waits in its queue. For parallel work, spread tasks across different workers; never count on two tasks for one worker running together. A worker whose model isn't loaded needs a GPU swap, which unloads another model and waits for the user's approval.",
  "Hand self-contained, clearly specified work to an idle worker on your own initiative: tests, boilerplate, mechanical edits and refactors, docs, summaries, and reading or searching code, especially when it can run while you do something else. Don't hand out what you can finish in one or two tool calls (one file to read, one search): the handoff costs more than it saves.",
  'Give each task a profile (explore, research, implement, test, review, docs or general: it sets the worker\'s tools and what its report must say), complete instructions (the worker sees nothing else: the goal, the files and folder, what to leave alone) and done_when, a check the worker can run to know it is finished. With worker "auto", say whether the task is small (short and mechanical: it may go to a small model) or large (the default: it waits for a large model). Keep design decisions, anything ambiguous or risky, and the final review yourself.',
  "What workers can't do: commit, push, use the network (curl, wget, ssh, rsync) or sudo; and their file tools can't leave the task's cwd, except to read files you pass in `files`. The explore, research and docs profiles have no shell, so they can't run commands: a task that runs commands needs review (read-only) or general. The hub turns such calls away mid-task, so never brief a worker to do them: set cwd to the folder the work is in, and commit yourself after you review.",
  "Before you hand out any work, set out your plan with plan(): one step per piece of work, each with its owner (\"lead\" for you, or a worker id). The user watches it beside the conversation: what each worker is doing and has done, and what you'll do next. Delegate each worker step with its step id, and keep the plan current: mark your own steps in_progress and completed as you go, add steps you discover, and finish with every step completed or explained in its note.",
  APPLE_LINE,
  "For the web: search with WebSearch yourself (the results are short). Pages on documentation and code-hosting sites open with WebFetch without asking; other sites need the user's approval. (Apple's documentation pages render with JavaScript: fetch developer.apple.com/tutorials/data/documentation/<path>.json for developer.apple.com/documentation/<path>.) To read long pages, give a local worker the research profile and the URLs, and it reports the answer with quotes. Prefer official documentation, and use the web when an answer depends on something that changes (versions, APIs, prices) rather than recalling it.",
  "Ground what you tell the user: name the file and line for claims about code, and the page for anything from the web. When it's cheap, check rather than recall (read the file, run the test), and when you haven't verified something, say so plainly instead of guessing.",
  'delegate() returns at once with a task id; then call await_workers() to wait for questions and results.',
  "When a worker asks a question, answer it with answer() if the task, the code or what the user said settles it. If it is the user's call (a product or design choice, anything risky or hard to undo, or something you would only be guessing at), call escalate() and ask the user in your reply: they answer on the question's card, or tell you and you pass it on with answer(). Never make up the user's preferences.",
  "Review every RESULT before you finish: it includes the worker's report, what the worker wrote, and the hub-measured changes. Then tell the user what each worker did and what you checked, and fix or re-delegate what is wrong.",
  'When a picture would explain something better than prose (an architecture, a flow, a sequence, a state machine, a comparison, data), call diagram() with Mermaid or one self-contained HTML page, then refer to it instead of repeating it in text. When it explains code, pass `explains` (the files and lines) and `links` (each node to the code it stands for), so the user can go from the picture to the code. The user can annotate diagrams and code with Apple Pencil; those notes come back to you as messages naming the element or lines they were written on, and your answer is kept with the note.',
];
/** The lead's guidance, with or without Apple's on-device workers. */
export function leadGuidance(apple: boolean): string {
  return LEAD_GUIDANCE_PARTS.map((l) => (l === APPLE_LINE ? (apple ? APPLE_FOR_LEAD : APPLE_NOT_FOR_LEAD) : l)).join(' ');
}
const DIAGRAM_MAX = 300_000;
// The same idea in one line, with the fleet's state and the plan at every prompt.
const DELEGATE_NUDGE = 'Start with plan() when the work has more than one step or you will hand any of it out. Hand suitable self-contained work to idle local workers (one task per worker at a time); keep design, risky changes and review yourself.';

// What the worker wrote, for the lead: a text deliverable (an answer, a poem) often lives there rather than in its report.
// Left out when the report already has it, ignoring Markdown and a line or two around it.
export function workerOutput(output: string, summary: string): string {
  const o = output.trim();
  if (!o) return '';
  const plain = (s: string) => s.replace(/[*_`#>]/g, '').replace(/\s+/g, ' ').trim().toLowerCase();
  const said = plain(summary);
  const lines = o.split('\n').map(plain).filter((l) => l.length >= 12);
  const covered = lines.filter((l) => said.includes(l)).length;
  if (said.includes(plain(o)) || (lines.length > 0 && covered / lines.length >= 0.75)) return '';
  return o.length > OUTPUT_MAX ? `[…earlier output trimmed]\n${o.slice(-OUTPUT_MAX)}` : o;
}

// Results, cancels and escalations end or pass on a thread; they never spend budget, so a task's outcome (and a
// question for you) always gets through.
const FREE: DialogueKind[] = ['RESULT', 'CANCEL', 'ESCALATE'];

export type Msg = { id: string; kind: DialogueKind; taskId: string; from: string; to: string; text: string; replyTo?: string; options?: string[] };

export type FleetPort = {
  delegate(worker: string, prompt: string, by: string, opts?: DelegateOpts): string;
  cancel(taskId: string, by: string): void;
  taskInfo(taskId: string): { worker: string; state: string; by: string; conversationId?: string; ahead?: string[] } | undefined;
  activeTasks(by: string): string[];
  describe(): string;
  idleLocal(): { id: string; takes: 'any' | 'small' }[];
};

export type LeadPort = {
  busy(): boolean; submit(text: string, by: string): void; conversation(): string | undefined;
  /** A prompt or note from the user waits for Claude's next tool call (await_workers stops waiting for it). */
  userWaiting?(): boolean;
};

// forUser: Claude passed it on to you (the worker still waits).
type Question = { id: string; taskId: string; worker: string; text: string; resolve: (answer: string) => void; forUser?: boolean };
type TaskThread = {
  final?: { summary: string; files?: string[]; commands?: string[]; outcome?: string };
  stopBlocked: boolean;
  steers: Msg[];
  question?: Question;
  // Your answers to its questions when Claude owns the task: Claude didn't see them, so its RESULT carries them.
  yours: string[];
};

export class Dialogue {
  /**
   * Whether Claude may hand work to Apple's on-device workers (DUET_APPLE_FOR_LEAD). Off: they're the user's, by
   * @mention; Claude's long text goes to local workers, which are free too and much stronger.
   */
  appleForLead = false;
  used = 0;
  paused = false;
  private leadInbox: Msg[] = [];
  private waiters = new Set<() => void>();
  private questions = new Map<string, Question>();
  private threads = new Map<string, TaskThread>();
  // Diagram id -> latest version, so an update gets the next version number.
  private diagrams = new Map<string, number>();
  // Claude's plan by conversation: the latest list.
  private plans = new Map<string, PlanStep[]>();
  // Tasks of plan steps that ended since Claude last sent its plan: what makes the plan out of date.
  private endedSincePlan = new Set<string>();
  private stopBlocks = 0;
  private planNudged = false;
  // Agent calls turned away this turn (tool-use ids): their subagent never ran.
  private turnedAway = new Set<string>();
  private fleet!: FleetPort;
  private lead!: LeadPort;
  private emit: (e: EventBody) => void;

  constructor(emit: (e: EventBody) => void) {
    this.emit = emit;
  }

  attach(fleet: FleetPort, lead: LeadPort): void {
    this.fleet = fleet;
    this.lead = lead;
  }

  private state(): void {
    this.emit({ type: 'dialogue_state', used: this.used, limit: BUDGET_PER_USER_MESSAGE, paused: this.paused, openQuestions: this.questions.size, leadInbox: this.leadInbox.length });
  }

  snapshot() {
    return { used: this.used, limit: BUDGET_PER_USER_MESSAGE, paused: this.paused, openQuestions: this.questions.size, leadInbox: this.leadInbox.length, threads: this.threads.size };
  }

  // A message from you (not the hub's own auto-turns) starts a fresh budget.
  onUserMessage(): void {
    this.used = 0;
    this.state();
  }

  onLeadTurnStart(): void {
    this.stopBlocks = 0;
    this.planNudged = false;
    this.turnedAway.clear();
  }

  /** The hub turned this Agent call away, so the subagent it shows never ran. */
  wasTurnedAway(toolUseId: string): boolean {
    return this.turnedAway.has(toolUseId);
  }

  // Spend one message of budget, or say why not. Refusals are cards too, so the UI shows them.
  private spend(kind: DialogueKind, human: boolean): string | null {
    if (FREE.includes(kind) || human) return null;
    if (this.used >= BUDGET_PER_USER_MESSAGE) return `Dialogue budget used up (${BUDGET_PER_USER_MESSAGE} messages per user message). Stop and summarize for the user; they can continue it.`;
    this.used++;
    return null;
  }

  // Post a card. Returns the refusal reason when the budget is spent.
  post(m: Omit<Msg, 'id'>, human = false): { msg: Msg; refused: string | null } {
    const msg = { ...m, id: `${m.kind[0].toLowerCase()}-${randomUUID().slice(0, 6)}` };
    const refused = this.spend(m.kind, human);
    // A card belongs to its task's conversation, even when that task outlives a Clear.
    this.emit({ type: 'dialogue', ...msg, refused: refused ?? undefined, conversationId: this.fleet.taskInfo(m.taskId)?.conversationId });
    this.state();
    if (refused) return { msg, refused };
    if (m.to === LEAD) {
      this.leadInbox.push(msg);
      for (const w of this.waiters) w();
      this.maybeWakeLead();
    }
    return { msg, refused: null };
  }

  /** The user wrote while Claude works: a waiting await_workers returns, so Claude's next tool call brings it in. */
  userWrote(): void {
    for (const w of this.waiters) w();
  }

  private thread(taskId: string): TaskThread {
    let t = this.threads.get(taskId);
    if (!t) this.threads.set(taskId, (t = { stopBlocked: false, steers: [], yours: [] }));
    return t;
  }

  private ownerOf(taskId: string): string {
    return this.fleet.taskInfo(taskId)?.by ?? LEAD;
  }

  /** The task waits only for your answer to a question Claude passed on. */
  private waitsOnYou(taskId: string): boolean {
    return this.threads.get(taskId)?.question?.forUser === true;
  }

  // ---- the plan ----

  /** The live conversation's plan. */
  plan(): PlanStep[] {
    return this.plans.get(this.lead.conversation() ?? '') ?? [];
  }

  // After a restart, each conversation's plan continues from the log (its latest list).
  seedPlans(seen: { conversationId?: string; steps: PlanStep[] }[]): void {
    for (const p of seen) this.plans.set(p.conversationId ?? '', p.steps);
  }

  /** Claude's whole plan, replacing the last. Steps keep the tasks they were handed to. */
  setPlan(by: string, steps: Omit<PlanStep, 'taskId'>[]): PlanStep[] {
    const ids = steps.map((s) => s.id.trim());
    if (!steps.length) throw new Error('a plan needs at least one step');
    if (ids.some((id) => !id)) throw new Error('every step needs an id');
    if (new Set(ids).size !== ids.length) throw new Error(`step ids must be unique (${ids.join(', ')})`);
    const before = new Map(this.plan().map((s) => [s.id, s]));
    const next = steps.map((s, i): PlanStep => {
      const taskId = before.get(ids[i])?.taskId;
      // A step's task decides who does it ("auto" became a worker).
      const owner = (taskId && this.fleet.taskInfo(taskId)?.worker) || s.owner.trim() || LEAD;
      return { id: ids[i], text: s.text.trim(), owner, status: s.status, ...(taskId ? { taskId } : {}), ...(s.note?.trim() ? { note: s.note.trim() } : {}) };
    });
    this.endedSincePlan.clear();
    this.putPlan(next, by);
    return next;
  }

  private putPlan(steps: PlanStep[], by: string): void {
    const conversationId = this.lead.conversation();
    this.plans.set(conversationId ?? '', steps);
    this.emit({ type: 'plan', steps, by, ...(conversationId ? { conversationId } : {}) });
  }

  // A task Claude handed out joins its plan step (a new one when it names none), so you see who is doing what.
  private linkStep(step: string | undefined, taskId: string, worker: string, task: string): string {
    const steps = [...this.plan()];
    const i = step ? steps.findIndex((s) => s.id === step) : -1;
    const id = i >= 0 ? steps[i].id : step?.trim() || nextStepId(steps);
    const linked: PlanStep = i >= 0
      ? { ...steps[i], owner: worker, status: 'in_progress', taskId }
      : { id, text: firstLine(task), owner: worker, status: 'in_progress', taskId };
    if (i >= 0) steps[i] = linked; else steps.push(linked);
    this.putPlan(steps, LEAD);
    return id;
  }

  /** Steps that no longer say what's happening: one of Claude's own still in progress as it stops, or a step whose
   *  task ended since Claude last sent its plan. */
  private stalePlanSteps(): string[] {
    return this.plan().filter((s) => s.status !== 'completed' && (
      (s.owner === LEAD && s.status === 'in_progress') || (s.taskId !== undefined && this.endedSincePlan.has(s.taskId)))).map((s) => s.id);
  }

  // ---- shared actions (lead tools and client commands both land here) ----

  delegate(by: string, worker: string, task: string, opts: DelegateOpts & { step?: string; doneWhen?: string } = {}): { taskId?: string; refused?: string; step?: string } {
    const human = by !== LEAD;
    if (this.paused && !human) return { refused: 'Handoffs are paused by the user.' };
    if (!human && isApple(worker) && !this.appleForLead) {
      return { refused: `${worker} is the user's on-device model, for the user to give tasks with @${worker}. Hand long text to an idle local worker (profile explore) instead.` };
    }
    if (!human && this.used >= BUDGET_PER_USER_MESSAGE) return { refused: this.spend('TASK', false)! };
    if (!human && !this.plan().length) return { refused: 'Set out your plan with plan() first: one step per piece of work, with who does each ("lead" for you, or a worker id). Then delegate this with its step id.' };
    const doneWhen = opts.doneWhen?.trim();
    // An Apple worker is one model pass (or several, over long input) with no tools: it gets just the task.
    const prompt = isApple(worker) ? task : wrapTask(task, opts.profile ?? 'general', doneWhen);
    const taskId = this.fleet.delegate(worker, prompt, by, opts);
    const assigned = this.fleet.taskInfo(taskId)!.worker;
    this.thread(taskId);
    this.post({ kind: 'TASK', taskId, from: by, to: assigned, text: doneWhen ? `${task}\n\nDone when: ${doneWhen}` : task }, human);
    return { taskId, step: human ? undefined : this.linkStep(opts.step, taskId, assigned, task) };
  }

  // What delegate tells Claude: when the task starts (each worker runs one at a time), and its plan step.
  private delegated(taskId: string, step?: string): string {
    const info = this.fleet.taskInfo(taskId)!;
    const when = info.state === 'awaiting_swap'
      ? `${info.worker}'s model isn't loaded, so the user is asked to approve loading it (which unloads another model); the task waits until then`
      : info.ahead?.length
        ? `${info.worker} runs one task at a time and has ${info.ahead.join(', ')} to finish first, so this one waits in its queue`
        : `${info.worker} has started it`;
    return `Delegated as ${taskId}${step ? ` (plan step ${step})` : ''}: ${when}. Call await_workers to wait for it.`;
  }

  answer(by: string, questionId: string, text: string): string | null {
    const q = this.questions.get(questionId);
    if (!q) throw new Error(`no open question ${questionId}`);
    const { refused } = this.post({ kind: 'ANSWER', taskId: q.taskId, from: by, to: q.worker, text, replyTo: q.id }, by !== LEAD);
    if (refused) return refused;
    if (by !== LEAD && this.ownerOf(q.taskId) === LEAD) this.thread(q.taskId).yours.push(`"${q.text}" → ${text}`);
    this.closeQuestion(q, text);
    return null;
  }

  // Claude passes a worker's question on to you: the worker keeps waiting for the answer, and Claude may end its turn.
  escalate(by: string, questionId: string, why: string): void {
    const q = this.questions.get(questionId);
    if (!q) throw new Error(`no open question ${questionId}`);
    if (q.forUser) return;
    q.forUser = true;
    this.post({ kind: 'ESCALATE', taskId: q.taskId, from: by, to: YOU, text: why.trim() || 'This is your call.', replyTo: q.id });
  }

  steer(by: string, taskId: string, text: string): string | null {
    const info = this.fleet.taskInfo(taskId);
    if (!info || !['queued', 'running', 'awaiting_swap'].includes(info.state)) throw new Error(`task ${taskId} is not active`);
    if (isApple(info.worker)) throw new Error(`${info.worker} can't take messages mid-task; cancel it and delegate again`);
    if (info.worker.startsWith('claude-')) throw new Error(`${info.worker} is one of Claude's subagents, which can't take messages mid-task`);
    const { msg, refused } = this.post({ kind: 'STEER', taskId, from: by, to: info.worker, text }, by !== LEAD);
    if (!refused) this.thread(taskId).steers.push(msg);
    return refused;
  }

  cancel(by: string, taskId: string): void {
    const info = this.fleet.taskInfo(taskId);
    if (!info) throw new Error(`unknown task ${taskId}`);
    this.fleet.cancel(taskId, by);
    this.post({ kind: 'CANCEL', taskId, from: by, to: info.worker, text: 'Task cancelled.' }, by !== LEAD);
  }

  setPaused(p: boolean): void {
    this.paused = p;
    this.state();
    if (!p) this.maybeWakeLead();
  }

  private closeQuestion(q: Question, answer: string): void {
    this.questions.delete(q.id);
    const t = this.threads.get(q.taskId);
    if (t?.question === q) t.question = undefined;
    q.resolve(answer);
    this.state();
  }

  // ---- fleet callbacks ----

  // The task ended (done, failed or cancelled). Close its question, drop its undelivered messages, and send the RESULT.
  // `stopped`: it ran out of turns or of room, and ends with what it got done.
  // `tools`: a local worker's tool calls as the hub counted them, for one line the worker's report can't change.
  onTaskEnd(taskId: string, worker: string, state: string, resultText: string, evidence: string, output = '', stopped?: { reason: 'turn_limit' | 'context'; turns: number }, tools?: ToolsUsed): void {
    const t = this.threads.get(taskId);
    if (t?.question) this.closeQuestion(t.question, 'The task was cancelled; stop now.');
    if (this.plan().some((s) => s.taskId === taskId)) this.endedSincePlan.add(taskId);
    if (state === 'cancelled') {
      this.leadInbox = this.leadInbox.filter((m) => m.taskId !== taskId);
      this.threads.delete(taskId);
      this.state();
      return;
    }
    const summary = t?.final?.summary ?? (resultText || '(the worker gave no summary)');
    const outcome = t?.final?.outcome && t.final.outcome !== 'done' ? `\nOutcome (worker says): ${t.final.outcome}` : '';
    const files = t?.final?.files?.length ? `\nFiles (worker says): ${t.final.files.join(', ')}` : '';
    const yours = t?.yours.length ? `\nThe user answered its questions: ${t.yours.join('; ')}` : '';
    const said = workerOutput(output, summary);
    const used = tools ? `\n${toolsLine(tools, t?.final?.commands)}` : '';
    const limit = stopped?.reason === 'context' ? "its model's context" : `its ${stopped?.turns}-turn limit`;
    const head = state !== 'done' ? 'Failed'
      : !stopped ? 'Finished'
      : t?.final ? `Finished at ${limit} (it reported before stopping)`
      : `Stopped at ${limit} before finishing (partial; continue it with a new task if more is needed)`;
    const text = `${head}: ${summary}${outcome}${files}${yours}${used}${said ? `\nWorker's output:\n${said}` : ''}\nHub-measured changes:\n${evidence}`;
    this.post({ kind: 'RESULT', taskId, from: worker, to: this.ownerOf(taskId), text });
    this.threads.delete(taskId);
  }

  // ---- diagrams ----

  showDiagram(a: { title: string; kind: DiagramKind; source: string; caption?: string; id?: string; explains?: CodeRef[]; links?: Record<string, string> }, by = LEAD): { id: string; version: number } {
    if (!a.source.trim()) throw new Error('the diagram source is empty');
    if (a.source.length > DIAGRAM_MAX) throw new Error(`the diagram source is ${a.source.length} characters; keep it under ${DIAGRAM_MAX}`);
    const id = a.id ?? `g-${randomUUID().slice(0, 8)}`;
    const version = (this.diagrams.get(id) ?? 0) + 1;
    this.diagrams.set(id, version);
    const explains = a.explains?.filter((r) => r.path.trim()).slice(0, 20);
    const links = a.links && Object.keys(a.links).length ? Object.fromEntries(Object.entries(a.links).slice(0, 200)) : undefined;
    this.emit({ type: 'diagram', id, version, title: a.title, kind: a.kind, source: a.source, caption: a.caption, by, ...(explains?.length ? { explains } : {}), ...(links ? { links } : {}) });
    return { id, version };
  }

  // After a restart, revisions continue from the log's versions.
  seedDiagrams(seen: { id: string; version: number }[]): void {
    for (const d of seen) this.diagrams.set(d.id, Math.max(this.diagrams.get(d.id) ?? 0, d.version));
  }

  // ---- lead side ----

  private takeInbox(taskIds?: string[]): Msg[] {
    const take = this.leadInbox.filter((m) => !taskIds?.length || taskIds.includes(m.taskId));
    this.leadInbox = this.leadInbox.filter((m) => !take.includes(m));
    this.state();
    return take;
  }

  // If the lead is idle when its workers need it, start a turn for it (and tell the user it happened).
  private maybeWakeLead(): void {
    if (this.paused || !this.leadInbox.length || this.lead.busy()) return;
    if (this.used >= BUDGET_PER_USER_MESSAGE && this.leadInbox.every((m) => !FREE.includes(m.kind))) return;
    this.emit({ type: 'notice', text: `The lead started a turn without you to handle ${this.leadInbox.length} worker message(s).` });
    this.lead.submit('[duet] Worker messages are waiting. Call mcp__duet__await_workers to read them, then act on them: answer or escalate questions, review results, and bring your plan up to date.', 'duet');
  }

  onLeadIdle(): void {
    this.maybeWakeLead();
  }

  /** The fleet and the plan, as Claude sees them at each prompt. */
  private context(): string {
    const plan = this.plan();
    const state = (id: string) => this.fleet.taskInfo(id)?.state;
    return [`[duet] Fleet now:\n${this.fleet.describe()}`, plan.length ? `Your plan:\n${formatPlan(plan, state)}` : 'No plan yet.', DELEGATE_NUDGE].join('\n');
  }

  // Why an Agent call (one of Claude's own subagents) should wait for a plan or go to a local worker; null lets it run.
  private agentRefusal(input: unknown): string | null {
    const a = (input ?? {}) as { prompt?: unknown; subagent_type?: unknown };
    if (this.paused) return null;
    if (!this.plan().length) return '[duet] Set out your plan with mcp__duet__plan before you hand out work, to local workers or to your own subagents (give this one a step with owner "claude"). Then make this call again.';
    const prompt = typeof a.prompt === 'string' ? a.prompt : '';
    const idle = this.fleet.idleLocal();
    if (NEEDS_CLAUDE.test(prompt) || !idle.length || this.used >= BUDGET_PER_USER_MESSAGE) return null;
    const kind = typeof a.subagent_type === 'string' && a.subagent_type ? a.subagent_type : 'general-purpose';
    const profile = AGENT_PROFILES[kind.toLowerCase()] ?? 'general';
    const workers = idle.map((w) => `${w.id} (${w.takes === 'small' ? 'small, mechanical tasks only' : 'any task'})`).join(', ');
    const pick = idle.find((w) => w.takes === 'any') ?? idle[0];
    return `[duet] A local worker is idle: ${workers}. Hand this to it with mcp__duet__delegate (worker "${pick.id}", profile "${profile}", the same instructions) instead, or do it yourself if it takes a call or two: local workers are free, and your subagents spend the user's Max plan. If it really needs Claude (judgment a local model lacks, web access, or it can't wait), make the call again with a prompt that starts with "Needs Claude:" and the reason.`;
  }

  /**
   * await_workers: returns as soon as worker messages arrive, or at the timeout. It returns as soon as the user writes
   * too (a prompt or a note): Claude Code hands Claude their message, pictures and all, once this call returns.
   */
  async awaitWorkers(ids: string[] | undefined, timeoutS: number | undefined, signal?: AbortSignal): Promise<AwaitResult> {
    const deadline = Date.now() + Math.min(timeoutS ?? 300, AWAIT_MAX_S) * 1000;
    while (true) {
      const msgs = this.takeInbox(ids);
      const active = this.fleet.activeTasks(LEAD).filter((t) => !ids?.length || ids.includes(t));
      const wrote = this.lead.userWaiting?.() ?? false;
      if (msgs.length || wrote) {
        const running = active.length ? `, then call await_workers again: ${active.join(', ')} ${active.length === 1 ? 'is' : 'are'} still running` : '';
        const parts = [
          msgs.length ? formatForLead(msgs) : '',
          wrote ? `[duet] The user wrote to you while you waited; their message follows this result. Answer it or act on it now${running}.` : '',
        ].filter(Boolean);
        return awaitText(parts.join('\n\n'));
      }
      if (!active.length) return awaitText('No active tasks and no waiting messages.');
      if (active.every((t) => this.waitsOnYou(t))) {
        return awaitText(`${active.join(', ')} ${active.length === 1 ? 'waits' : 'wait'} only for the user's answer to a question you passed on. Ask them in your reply and end your turn: their answer goes to the worker, and its RESULT starts a turn for you.`);
      }
      if (Date.now() >= deadline || signal?.aborted) return awaitText(`Still working: ${active.join(', ')}. No messages yet.`);
      await new Promise<void>((resolve) => {
        const done = () => { this.waiters.delete(done); clearTimeout(timer); resolve(); };
        const timer = setTimeout(done, Math.min(5000, Math.max(0, deadline - Date.now())));
        this.waiters.add(done);
        signal?.addEventListener('abort', done, { once: true });
      });
    }
  }

  leadServer(): McpSdkServerConfigWithInstance {
    const text = (s: string, isError = false) => ({ content: [{ type: 'text' as const, text: s }], isError });
    return createSdkMcpServer({
      name: 'duet',
      timeout: (AWAIT_MAX_S + 60) * 1000,
      alwaysLoad: true,
      instructions: leadGuidance(this.appleForLead),
      tools: [
        tool('plan', "Your plan for the work in hand, shown to the user beside the conversation: what each worker is doing and has done, and what you'll do next. Call it before you hand out any work, and again whenever a step starts, finishes or changes. Send the whole list each time; it replaces the last. A step you delegated keeps its task, and the user sees the task's own state (queued, running, done) beside it.", {
          steps: z.array(z.object({
            id: z.string().describe('Short and stable across updates: "1", "2", "tests"'),
            text: z.string().describe('What the step does, in a few words'),
            owner: z.string().describe('"lead" for your own steps, a worker id from fleet() (or "auto") for one you\'ll hand out, "claude" for one of your subagents'),
            status: z.enum(['pending', 'in_progress', 'completed']).describe('Keep one of your own steps in_progress while you work on it'),
            note: z.string().optional().describe('One line of detail: what you found, what is left, why it stopped'),
          })).describe('Every step, in order'),
        }, async (a) => {
          try {
            const steps = this.setPlan(LEAD, a.steps);
            const count = (s: PlanStep['status']) => steps.filter((x) => x.status === s).length;
            return text(`Plan shown to the user: ${steps.length} step${steps.length === 1 ? '' : 's'} (${count('completed')} completed, ${count('in_progress')} in progress, ${count('pending')} pending).`);
          } catch (e) { return text(String(e instanceof Error ? e.message : e), true); }
        }),
        tool('delegate', `Hand a self-contained task to a worker; it returns at once with a task id and the worker runs in the background. Work goes to a local GPU worker (each runs one task at a time, so a busy one queues it)${this.appleForLead ? "; summarizing, extracting from or classifying short text can go to an apple-* worker (Apple's on-device model on the user's device)" : ''}. Set out your plan with plan() first.`, {
          worker: z.string().describe('Worker id from fleet(), or "auto": an idle local worker that fits the size (never an apple-* worker)'),
          task: z.string().describe('Complete instructions; the worker sees nothing else: the goal, the files and folder, what to leave alone'),
          done_when: z.string().optional().describe('A check the worker can run to know it is finished, e.g. "npm test passes" or "the answer names the function and its file:line". It reports whether it holds.'),
          profile: z.enum(PROFILE_IDS).optional().describe(`What kind of task it is (default "general"): it sets the worker's tools and what its report must say. ${describeProfiles()} Not for apple-* workers.`),
          size: z.enum(['small', 'large']).optional().describe('For "auto": "small" for a short, mechanical task, which may go to a small model; "large" (the default) for anything else, which waits for a large model rather than going to a small one'),
          step: z.string().optional().describe('The id of the plan step this task does; without one, the hub adds a step for it'),
          cwd: z.string().optional().describe('Absolute project directory'),
          effort: z.string().optional().describe("One of the worker's effort levels"),
          files: z.array(z.string()).optional().describe('Absolute paths of files the task is about. An apple-* worker can\'t read files, so the hub sends their text (up to 400 KB; long text is read in parts); a local worker gets the paths, and may read (only read) those outside its cwd, which must be existing files.'),
        }, async (a) => {
          try {
            const r = this.delegate(LEAD, a.worker, a.task, { cwd: a.cwd, effort: a.effort, files: a.files, size: a.size, profile: a.profile, step: a.step, doneWhen: a.done_when });
            return r.refused ? text(r.refused, true) : text(this.delegated(r.taskId!, r.step));
          } catch (e) { return text(String(e instanceof Error ? e.message : e), true); }
        }),
        tool('await_workers', 'Wait for worker messages (questions, status, results). Returns as soon as any arrive, or at the timeout.', {
          task_ids: z.array(z.string()).optional(),
          timeout_s: z.number().optional().describe(`Max wait, default 300, max ${AWAIT_MAX_S}`),
        }, (a, extra) => this.awaitWorkers(a.task_ids, a.timeout_s, (extra as { signal?: AbortSignal } | undefined)?.signal)),
        tool('answer', "Answer a worker's question. The worker is blocked until you do.", { question_id: z.string(), text: z.string() }, async (a) => {
          try {
            const refused = this.answer(LEAD, a.question_id, a.text);
            return refused ? text(refused, true) : text('Answered; the worker continues.');
          } catch (e) { return text(String(e instanceof Error ? e.message : e), true); }
        }),
        tool('escalate', "Pass a worker's question on to the user instead of answering it: when it is their call (a product or design choice, anything risky or hard to undo) or you would only be guessing. The worker keeps waiting; the user answers on the question's card, or tells you and you pass it on with answer(). Ask them in your reply too.", {
          question_id: z.string(),
          why: z.string().describe('One line for the user: why this is their call'),
        }, async (a) => {
          try {
            this.escalate(LEAD, a.question_id, a.why);
            return text('Passed on to the user. Ask them in your reply; you can end your turn, and the worker waits for their answer.');
          } catch (e) { return text(String(e instanceof Error ? e.message : e), true); }
        }),
        tool('steer', 'Send guidance to a running worker. It sees it after its next tool call.', { task_id: z.string(), text: z.string() }, async (a) => {
          try {
            const refused = this.steer(LEAD, a.task_id, a.text);
            return refused ? text(refused, true) : text('Sent.');
          } catch (e) { return text(String(e instanceof Error ? e.message : e), true); }
        }),
        tool('cancel', 'Cancel a worker task.', { task_id: z.string() }, async (a) => {
          try { this.cancel(LEAD, a.task_id); return text('Cancelled.'); } catch (e) { return text(String(e instanceof Error ? e.message : e), true); }
        }),
        tool('fleet', 'List workers: availability, model, what each is running and what waits in its queue (each runs one task at a time), the tasks it suits, and its effort levels.', {}, async () => text(this.fleet.describe()), { annotations: { readOnlyHint: true } }),
        this.diagramTool(),
      ],
    });
  }

  /** The diagram tool: the lead's, and Claude's when it answers a note in the note's thread (`by` says who drew it,
   *  and `drawn` hears each one's id). */
  private diagramTool(by = LEAD, drawn?: (id: string) => void) {
    const text = (s: string, isError = false) => ({ content: [{ type: 'text' as const, text: s }], isError });
    return tool('diagram', 'Show the user a diagram on all their devices (iPhone, iPad, Mac). kind "mermaid": Mermaid source for a flowchart, sequence, class, state, ER, gantt, mindmap, timeline, pie, quadrant, journey or git graph. kind "html": one self-contained page with inline CSS and JS and no external files, for anything Mermaid cannot draw. To revise a diagram you showed earlier, pass its id. Returns the diagram id.', {
      title: z.string().describe('Short title'),
      kind: z.enum(['mermaid', 'html']),
      source: z.string().describe('The Mermaid source, or the whole HTML page'),
      caption: z.string().optional().describe('One line shown under it'),
      id: z.string().optional().describe('The id of a diagram to revise'),
      explains: z.array(z.object({ path: z.string(), start: z.number().int().optional(), end: z.number().int().optional() })).optional()
        .describe('The code this diagram explains: absolute file paths and line ranges. The user can open them from the diagram.'),
      links: z.record(z.string(), z.string()).optional()
        .describe('What each element stands for in the code: element id (the Mermaid node id) to "path:line" or "path:start-end". Tapping the element opens that code.'),
    }, async (a) => {
      try {
        const d = this.showDiagram(a, by);
        drawn?.(d.id);
        return text(`Shown to the user as diagram ${d.id} (version ${d.version}); pass the id to revise it. They see it beside your reply, so don't point them to it or give them the id.`);
      } catch (e) { return text(String(e instanceof Error ? e.message : e), true); }
    });
  }

  /** Just the diagram tool, for Claude answering a note in its thread: what it draws goes with the note's answer. */
  diagramServer(drawn: (id: string) => void): McpSdkServerConfigWithInstance {
    return createSdkMcpServer({ name: 'duet', alwaysLoad: true, tools: [this.diagramTool(THREAD, drawn)] });
  }

  leadHooks(): Partial<Record<HookEvent, HookCallbackMatcher[]>> {
    const deny = (reason: string) => ({ hookSpecificOutput: { hookEventName: 'PreToolUse' as const, permissionDecision: 'deny' as const, permissionDecisionReason: reason } });
    return {
      PreToolUse: [{
        hooks: [async (input) => {
          if (input.hook_event_name !== 'PreToolUse') return {};
          // Hooks fire inside Claude's subagents too. They work for Claude: handing out work, the workers' messages and
          // the plan stay Claude's own.
          if (input.agent_id) {
            return input.tool_name.startsWith('mcp__duet__') ? deny('The duet tools belong to the lead that started you. Do your task with your other tools and put what you found in your final report.') : {};
          }
          if (!AGENT_TOOLS.has(input.tool_name)) return {};
          const reason = this.agentRefusal(input.tool_input);
          if (!reason) return {};
          this.turnedAway.add(input.tool_use_id);
          return deny(reason);
        }],
      }],
      // Worker messages that arrive mid-turn reach the lead's next model call (never a subagent's: it would keep them).
      PostToolUse: [{
        hooks: [async (input) => {
          if (input.hook_event_name !== 'PostToolUse' || input.agent_id || input.tool_name === 'mcp__duet__await_workers') return {};
          const msgs = this.takeInbox();
          if (!msgs.length) return {};
          return { hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: formatForLead(msgs) } };
        }],
      }],
      Stop: [{
        hooks: [async () => {
          if (this.paused || this.stopBlocks >= MAX_STOP_BLOCKS) return {};
          const unread = this.leadInbox.length;
          // A task waiting only for your answer doesn't keep Claude's turn going: Claude asks you and stops.
          const active = this.fleet.activeTasks(LEAD).filter((t) => !this.waitsOnYou(t));
          const stale = unread || active.length || this.planNudged ? [] : this.stalePlanSteps();
          if (!unread && !active.length && !stale.length) return {};
          this.stopBlocks++;
          if (stale.length) this.planNudged = true;
          const reason = unread
            ? `[duet] ${unread} worker message(s) are unread. Call mcp__duet__await_workers, handle them, and review any RESULT before finishing.`
            : active.length
              ? `[duet] Your workers are still running (${active.join(', ')}). Call mcp__duet__await_workers to wait for them, or cancel them.`
              : `[duet] Your plan is out of date (step${stale.length === 1 ? '' : 's'} ${stale.join(', ')}). Call mcp__duet__plan with each step's status before you finish: mark what's done completed, and say in a step's note what's left or why it stopped.`;
          return { decision: 'block', reason };
        }],
      }],
      UserPromptSubmit: [{
        hooks: [async () => ({ hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: this.context() } })],
      }],
    };
  }

  // ---- worker side ----

  /** A worker's question. It waits for the answer from Claude or you (ASK_TIMEOUT_MS at most, then goes ahead). */
  async ask(taskId: string, worker: string, question: string, options?: string[], signal?: AbortSignal): Promise<{ text: string; isError?: boolean }> {
    const t = this.thread(taskId);
    if (t.question) return { text: 'You already have an open question; wait for its answer.', isError: true };
    const q: Question = { id: '', taskId, worker, text: question, resolve: () => {} };
    const answered = new Promise<string>((resolve) => (q.resolve = resolve));
    const { msg, refused } = this.post({ kind: 'QUESTION', taskId, from: worker, to: this.ownerOf(taskId), text: question, options });
    if (refused) return { text: `${refused} Proceed with your best judgment.`, isError: true };
    q.id = msg.id;
    t.question = q;
    this.questions.set(q.id, q);
    this.state();
    signal?.addEventListener('abort', () => this.closeQuestion(q, 'Cancelled.'), { once: true });
    // Unanswered in time: the card says so (closing the question everywhere), and the worker goes ahead.
    const timer = setTimeout(() => {
      if (!this.questions.has(q.id)) return;
      this.post({ kind: 'ANSWER', taskId, from: 'duet', to: worker, text: `No answer in ${ASK_TIMEOUT_MS / 60_000} minutes: the worker goes ahead with its best judgment.`, replyTo: q.id }, true);
      this.closeQuestion(q, 'No answer in time. Proceed with your best judgment and say so in your report.');
    }, ASK_TIMEOUT_MS);
    timer.unref();
    const answer = await answered;
    clearTimeout(timer);
    return { text: `Answer: ${answer}` };
  }

  workerServer(taskId: string, worker: string): McpSdkServerConfigWithInstance {
    const text = (s: string, isError = false) => ({ content: [{ type: 'text' as const, text: s }], isError });
    const t = this.thread(taskId);
    return createSdkMcpServer({
      name: 'duet',
      timeout: ASK_TIMEOUT_MS + 60_000,
      alwaysLoad: true,
      tools: [
        tool('ask_lead', 'Ask whoever assigned this task a question and wait for the answer. Use it only when you are genuinely blocked on a decision.', {
          question: z.string(),
          options: z.array(z.string()).optional(),
        }, async (a, extra) => {
          const r = await this.ask(taskId, worker, a.question, a.options, (extra as { signal?: AbortSignal } | undefined)?.signal);
          return text(r.text, r.isError);
        }),
        tool('report', 'Report progress (kind "status") or your final handoff (kind "final"). You must call it with kind "final" before you finish. When the task asks for text (an answer, a review, a poem), put that text itself in summary; for code changes, say what changed.', {
          kind: z.enum(['status', 'final']),
          summary: z.string(),
          outcome: z.enum(['done', 'partial', 'blocked']).optional().describe('kind "final": done (the default), partial (some of it is left: say what in summary), or blocked (you could not do it: say why)'),
          files: z.array(z.string()).optional(),
          commands: z.array(z.string()).optional(),
        }, async (a) => {
          if (a.kind === 'final') {
            t.final = { summary: a.summary, files: a.files, commands: a.commands, outcome: a.outcome };
            return text('Recorded. You can finish now.');
          }
          const { refused } = this.post({ kind: 'STATUS', taskId, from: worker, to: this.ownerOf(taskId), text: a.summary });
          return refused ? text(refused, true) : text('Sent.');
        }),
      ],
    });
  }

  workerHooks(taskId: string): Partial<Record<HookEvent, HookCallbackMatcher[]>> {
    const t = this.thread(taskId);
    return {
      PostToolUse: [{
        hooks: [async (input) => {
          if (input.hook_event_name !== 'PostToolUse' || !t.steers.length) return {};
          const steers = t.steers.splice(0);
          return { hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: steers.map((s) => `[duet] STEER from ${s.from}: ${s.text}`).join('\n') } };
        }],
      }],
      Stop: [{
        hooks: [async () => {
          if (t.final || t.stopBlocked) return {};
          t.stopBlocked = true;
          return { decision: 'block', reason: '[duet] Before you finish, call mcp__duet__report with kind "final": a short summary of what you did, the files you changed and the commands you ran.' };
        }],
      }],
    };
  }
}

const isApple = (worker: string) => worker.startsWith('apple-');

// The task and its check, then how this kind of task is done and what the report must say (from its profile).
export function wrapTask(task: string, profile: ProfileId = 'general', doneWhen?: string): string {
  const p = PROFILES[profile];
  return [
    task,
    ...(doneWhen ? ['', `Done when: ${doneWhen}`] : []),
    '',
    '---',
    `You are a Doublet worker. Task profile: ${p.id}${p.readOnly ? ' (read-only)' : ''}.${p.how ? ` ${p.how}` : ''}`,
    `Your tools: ${p.tools.join(', ')}.${p.tools.includes('Bash') ? '' : ' You have no shell, so you cannot run commands.'} The hub turns away commits, pushes, the network, sudo, and file tools outside your folder (except reading files the task lists as outside it).`,
    'If you are blocked on a decision only the requester can make, or the task can be read two ways, call mcp__duet__ask_lead before you start on it, and wait. Guidance from the requester may arrive after a tool call as "[duet] STEER": follow it.',
    'Work from what you read and run, not from memory: when you could not check something, say so in your report rather than guessing.',
    'When a tool is refused or a command can\'t run, don\'t work around it with guesses: report outcome "blocked" and name the tool and the command or path it refused. Never write output a tool didn\'t return: quote only what you actually read or ran, and say plainly what you could not get.',
    `When you are done, call mcp__duet__report with kind "final", then stop. Its summary must give ${p.report}${doneWhen ? ' Say whether "done when" holds, and how you checked.' : ''}`,
  ].join('\n');
}

type AwaitResult = { content: { type: 'text'; text: string }[] };
const awaitText = (text: string): AwaitResult => ({ content: [{ type: 'text', text }] });

/** The RESULT's hub-measured line of the tools a worker called, e.g. "Read ×3 (2 refused), Grep ×2; no shell (…)".
 *  `commands`: the commands its report says it ran, called out when no shell command ran at all. */
export function toolsLine(t: ToolsUsed, commands?: string[]): string {
  const calls = t.used.map((c) => {
    const notes = [c.refused ? `${c.refused} refused` : '', c.failed ? `${c.failed} failed` : ''].filter(Boolean).join(', ');
    return `${c.name} ×${c.calls}${notes ? ` (${notes})` : ''}`;
  });
  const bash = t.used.find((c) => c.name === 'Bash');
  const ran = bash ? bash.calls - bash.refused : 0;
  const shell = !PROFILES[t.profile].tools.includes('Bash') ? `no shell (the ${t.profile} profile has none)` : ran ? '' : 'no shell command ran';
  const claimed = commands?.length && !ran ? `, though its report lists ${commands.length} command${commands.length === 1 ? '' : 's'}` : '';
  return `Tools used (hub-measured): ${calls.join(', ') || 'none'}${shell ? `; ${shell}` : ''}${claimed}`;
}

function formatForLead(msgs: Msg[]): string {
  return msgs.map((m) => {
    const head = `[${m.kind} ${m.kind === 'QUESTION' ? `question_id=${m.id} ` : ''}task=${m.taskId} from=${m.from}]`;
    const opts = m.options?.length ? `\nOptions: ${m.options.join(' | ')}` : '';
    return `${head}\n${m.text}${opts}`;
  }).join('\n\n');
}

/** The plan as Claude reads it: [x] completed, [>] in progress, [ ] pending, with each step's owner and task. */
export function formatPlan(steps: PlanStep[], taskState: (taskId: string) => string | undefined): string {
  return steps.map((s) => {
    const box = s.status === 'completed' ? 'x' : s.status === 'in_progress' ? '>' : ' ';
    const task = s.taskId ? `, ${s.taskId} ${taskState(s.taskId) ?? 'ended'}` : '';
    return `- [${box}] ${s.id} (${s.owner}${task}): ${s.text}${s.note ? ` — ${s.note}` : ''}`;
  }).join('\n');
}

// A step id after the numbered ones: "4" after "1", "2", "3".
function nextStepId(steps: PlanStep[]): string {
  const ids = new Set(steps.map((s) => s.id));
  let n = Math.max(0, ...steps.map((s) => Number(s.id)).filter(Number.isInteger)) + 1;
  while (ids.has(String(n))) n++;
  return String(n);
}

function firstLine(text: string): string {
  const line = text.split('\n').map((l) => l.trim()).find(Boolean) ?? 'Task';
  return line.length > 80 ? `${line.slice(0, 79)}…` : line;
}
