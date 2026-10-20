// Questions written on code (handwritten notes): a local model answers first, and its answer counts only when every
// citation checks out against the files. Otherwise Claude answers, with what the local model found, in the note's
// thread: a side chat that continues the note, forked from the conversation so Claude has its context. "Ask Claude"
// sends a locally answered note there too, and so do questions a local model isn't for. Only notes asking for work go to
// the conversation itself (main.ts). Claude hears about the notes answered without it, so the conversation stays whole.
import type { Annotations } from './annotations.ts';
import type { Answered, DelegateOpts, TaskSize } from './fleet.ts';
import { notesPrompt } from './notes.ts';
import type { Annotation, InkNote, Notes, NoteSurface, SideAbout } from './protocol.ts';
import type { RouteLog } from './routelog.ts';
import { route } from './routing.ts';
import { evidence, present, scout, type ScoutOutcome, type ScoutRun } from './scout.ts';
import type { NoteAsk, NoteThread } from './sidechat.ts';

export type QuestionDeps = {
  annotations: Annotations;
  /** A question for a local worker (Fleet.ask). */
  ask: (sel: string, prompt: string, by: string, opts: Omit<DelegateOpts, 'internal'>) => Promise<Answered>;
  /** Notes' threads, where Claude answers question notes (SideChats, wired in main.ts). */
  threads: NoteThreads;
  /** Tell Claude with the next prompt (Lead.notice). */
  notice: (text: string) => void;
  cwd: () => string;
  routes: RouteLog;
  log: (m: string) => void;
};

/** A note's thread (a side chat that continues the note), and Claude answering the note there. */
export type NoteThreads = {
  /** The note's thread, opened if it has none yet: it starts with the note's question, and its answer if it has one. */
  open(a: Annotation): string;
  /** Whether the thread is answering now (a reply in progress). */
  busy(chatId: string): boolean;
  /** Claude answers the note's own question in its thread (SideChats.answerNote). */
  claude(chatId: string, text: string, o: NoteAsk): void;
};

/** A note's question, as the routing reads it. */
const asked = (n: InkNote) => n.text?.trim() ?? '';

/** The note as written, without what the hub keeps with it. */
const noteOf = (a: Annotation): InkNote => ({
  id: a.id, intent: a.intent, ...(a.text ? { text: a.text } : {}), ...(a.lines ? { lines: a.lines } : {}), ...(a.elements ? { elements: a.elements } : {}), ...(a.typed ? { typed: true } : {}),
});

export class NoteQuestions {
  private d: QuestionDeps;

  constructor(d: QuestionDeps) {
    this.d = d;
  }

  /** The notes a local model answers first: questions about a file whose words it can read. Notes are asynchronous,
   *  so a busy GPU doesn't send them to Claude: they wait their turn. */
  local(surface: NoteSurface, items: InkNote[]): InkNote[] {
    if (surface.kind !== 'file') return [];
    return items.filter((n) => n.intent === 'question' && route(asked(n), 'note', { localFree: () => true }).to === 'local');
  }

  /** Answer one note locally; on to Claude with the evidence when the answer doesn't check out. */
  async answer(by: string, surface: NoteSurface, note: InkNote): Promise<void> {
    const r = route(asked(note), 'note', { localFree: () => true });
    const t0 = Date.now();
    this.d.annotations.routing(note.id, { route: 'local', answering: 'a local model' });
    let o: ScoutOutcome;
    try {
      o = await scout((prompt) => this.run(prompt, by, r.size), { question: asked(note), about: about(surface, note) }, this.d.cwd());
    } catch (e) {
      this.d.log(`note ${note.id}: local answer failed: ${e}`);
      o = { scouted: null, checked: null, verdict: { pass: false, why: 'the local model failed', repairable: false }, tries: 1, ms: Date.now() - t0 };
    }
    const citations = o.checked ? { checked: o.checked.claims.length + o.checked.failed.length, failed: o.checked.failed.length, fixed: o.checked.fixed } : undefined;
    if (o.verdict.pass && o.scouted && o.checked) {
      const ms = Date.now() - t0;
      const shown = present(o.scouted, o.checked);
      // Logged before it's announced, so the log never lags what devices see.
      this.d.routes.write({ surface: 'note', id: note.id, by, cls: r.cls, to: 'local', why: r.why, outcome: 'local', worker: o.worker, ms, citations, tries: o.tries, words: shown.words, ...(shown.trimmed ? { trimmed: true } : {}) });
      this.d.annotations.answerLocally(note.id, shown.text, { worker: o.worker ?? 'local', checked: { claims: o.checked.claims.length, failed: 0 }, ms, ...(shown.more ? { more: shown.more } : {}) });
      this.d.notice(`[duet] Meanwhile ${o.worker ?? 'a local model'} answered the user's note on ${place(surface, note)} ("${asked(note).slice(0, 120)}"), its citations checked: ${o.scouted.answer.replace(/\s+/g, ' ').slice(0, 300)}`);
      return;
    }
    const why = o.verdict.pass ? 'it was sent to Claude' : o.verdict.why;
    this.d.routes.write({ surface: 'note', id: note.id, by, cls: r.cls, to: 'local', why: r.why, outcome: 'escalated', worker: o.worker, ms: Date.now() - t0, citations, tries: o.tries, escalated: why });
    this.inThread(by, note.id, why, evidence(o));
  }

  /** Questions a local model isn't for (or can't read): Claude answers each in the note's thread, with the picture. */
  direct(by: string, items: InkNote[], image?: NoteAsk['image']): void {
    for (const n of items) {
      const r = route(asked(n), 'note', { localFree: () => true, picture: !!image });
      this.d.routes.write({ surface: 'note', id: n.id, by, cls: r.cls, to: 'claude', why: r.why, outcome: 'claude' });
      this.inThread(by, n.id, r.why, undefined, image);
    }
  }

  /**
   * "Ask Claude" about a note a local model answered: Claude checks it in the note's thread, and its answer is kept
   * beside the local one.
   */
  reroute(id: string, by: string): void {
    const a = this.d.annotations.get(id);
    if (!a) throw new Error(`no annotation ${id}`);
    // The thread first, so it starts with the local answer being checked.
    const chatId = this.d.threads.open(a);
    if (this.d.threads.busy(chatId)) throw new Error("the note's thread is still answering; wait for it, or stop it");
    const local = a.route === 'local' && a.answer ? a.answer : undefined;
    if (local) this.d.annotations.reask(id, 'you asked Claude');
    else this.d.annotations.routing(id, { status: 'open', route: 'claude', answering: 'Claude', escalated: 'you asked Claude' });
    const r = route(asked(a), 'note', { localFree: () => true });
    this.d.routes.write({ surface: 'note', id, by, cls: r.cls, to: 'claude', why: 'you asked Claude', outcome: 'override', worker: a.answeredBy });
    const check = local ? `[duet] ${a.answeredBy ?? 'A local model'} answered this note first, and the user asked you to check it. Its answer:\n${local.slice(0, 2000)}` : undefined;
    this.answerIn(by, a, chatId, 'you asked Claude', check);
  }

  /** Claude answers a question note in the note's thread: a side chat forked from the conversation, so Claude has its context. */
  private inThread(by: string, id: string, why: string, extra?: string, image?: NoteAsk['image']): void {
    const a = this.d.annotations.get(id);
    if (!a) return;
    const chatId = this.d.threads.open(a);
    this.d.annotations.routing(id, { route: 'claude', answering: 'Claude', escalated: why });
    this.answerIn(by, a, chatId, why, extra, image);
  }

  /** Claude's answer in the thread is kept on the note, and the conversation hears about it. */
  private answerIn(by: string, a: Annotation, chatId: string, why: string, extra?: string, image?: NoteAsk['image']): void {
    const notes: Notes = { surface: a.surface, items: [noteOf(a)], hasImage: !!image };
    const failed = (error: string) => this.d.annotations.routing(a.id, { answering: undefined, escalated: `${why}; Claude couldn't answer (${error.slice(0, 160)})` });
    try {
      this.d.threads.claude(chatId, notesPrompt(by, notes), {
        escalated: why, ...(extra ? { extra } : {}), ...(image ? { image } : {}), failed,
        done: (r) => {
          this.d.annotations.answeredInThread(a.id, r);
          this.d.notice(`[duet] Meanwhile Claude answered the user's note on ${place(a.surface, a)} in the note's thread ("${asked(a).slice(0, 120)}"): ${r.text.replace(/\s+/g, ' ').slice(0, 300)}`);
        },
      });
    } catch (e) {
      // Its thread was answering a reply already.
      failed(e instanceof Error ? e.message : String(e));
    }
  }

  private async run(prompt: string, by: string, size: TaskSize): Promise<ScoutRun> {
    try {
      const a = await this.d.ask('auto', prompt, by, { cwd: this.d.cwd(), profile: 'explore', size });
      return { ok: a.state === 'done', result: a.result, worker: a.worker, taskId: a.taskId, error: a.error };
    } catch (e) {
      // No local worker can take it (all off, or none loaded): nothing to wait for.
      return { ok: false, result: '', worker: '', error: e instanceof Error ? e.message : String(e) };
    }
  }
}

/**
 * What a note's thread starts from: the note's question and answer, in the conversation it was written in, about
 * where it was written (the file's lines; a diagram's elements, with the diagram's source; a diff's lines, with their
 * code). `diagram` looks up a diagram's title and source.
 */
export function noteThread(a: Annotation, conversationId: string | undefined, diagram: (id: string) => { title?: string; source?: string } | undefined): NoteThread {
  const answer = a.answer?.trim()
    ? { text: a.answer, ...(a.answeredBy ? { model: a.answeredBy } : {}), ...(a.route === 'local' ? { local: true } : {}), ...(a.checked ? { checked: a.checked } : {}), ...(a.ms !== undefined ? { ms: a.ms } : {}), ...(a.more ? { more: a.more } : {}), ...(a.escalated ? { escalated: a.escalated } : {}) }
    : undefined;
  return {
    annotationId: a.id, title: `Note on ${anchorLabel(a)}`, about: anchor(a, diagram), ...(conversationId ? { conversationId } : {}),
    by: a.by, question: a.text?.trim() ?? '', ...(a.ink ? { ink: true } : {}), ...(answer ? { answer } : {}),
  };
}

function anchor(a: Annotation, diagram: (id: string) => { title?: string; source?: string } | undefined): SideAbout | undefined {
  const s = a.surface;
  const l = a.lines?.[0];
  if (s.kind === 'file') return l ? { kind: 'file', path: l.file || s.path, start: l.start, end: l.end } : { kind: 'file', path: s.path };
  if (s.kind === 'diagram') {
    const d = diagram(s.diagramId);
    return { kind: 'text', label: anchorLabel(a, d?.title), ...(d?.source ? { text: d.source } : {}) };
  }
  // The thread is a copy of the conversation, so it knows the whole plan; the steps written on are enough here.
  if (s.kind === 'plan') {
    const steps = (a.elements ?? []).map((e) => `${e.id}. ${e.label ?? ''}`.trim()).join('\n');
    return { kind: 'text', label: anchorLabel(a), ...(steps ? { text: steps } : {}) };
  }
  const code = (a.lines ?? []).flatMap((x) => (x.code ? [`${x.file}:${x.start}-${x.end}\n${x.code}`] : [])).join('\n\n');
  return { kind: 'text', label: anchorLabel(a), ...(code ? { text: code } : {}) };
}

/**
 * "“InString” in the diagram “Lexer states”", "src/a.ts:3-5", "a.py:3-5 in qwen-27b's change for task t-1",
 * "step 3 “Refactor the lexer” of the plan".
 */
function anchorLabel(a: Annotation, diagramTitle?: string): string {
  const s = a.surface;
  const lines = (a.lines ?? []).map((l) => `${l.file}:${l.start === l.end ? l.start : `${l.start}-${l.end}`}`).join(', ');
  if (s.kind === 'diagram') {
    const title = `the diagram “${diagramTitle ?? s.title ?? s.diagramId}”`;
    const named = (a.elements ?? []).map((e) => `“${e.label || e.id}”`).join(', ');
    return named ? `${named} in ${title}` : title;
  }
  if (s.kind === 'plan') {
    const steps = a.elements ?? [];
    if (steps.length === 1) return `step ${steps[0].id}${steps[0].label ? ` “${steps[0].label}”` : ''} of the plan`;
    return steps.length ? `steps ${steps.map((e) => e.id).join(', ')} of the plan` : 'the plan';
  }
  if (s.kind === 'diff') return `${lines ? `${lines} in ` : ''}${s.worker ?? 'a worker'}'s change for task ${s.taskId}`;
  return lines || s.path;
}

/** Where a note is, for a prompt: the file and lines, with the first line of the code. */
function about(surface: NoteSurface, n: InkNote): string {
  const l = n.lines?.[0];
  const file = surface.kind === 'file' ? surface.path : '';
  if (!l) return `the file ${file}`;
  const first = l.code?.split('\n')[0]?.trim().slice(0, 160);
  return `${l.file}:${l.start === l.end ? l.start : `${l.start}-${l.end}`}${first ? ` \`${first}\`` : ''}`;
}

function place(surface: NoteSurface, n: InkNote): string {
  const l = n.lines?.[0];
  if (surface.kind === 'plan') return n.elements?.length ? `step ${n.elements.map((e) => e.id).join(', ')} of the plan` : 'the plan';
  return l ? `${l.file}:${l.start}` : surface.kind === 'file' ? surface.path : 'a file';
}

