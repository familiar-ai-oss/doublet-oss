// Side chats: a quick question beside the conversation. The lead's agent (Claude Code, Codex or Cursor: agents/aside.ts)
// answers in a copy of the conversation, so it knows what's been said and done, while the conversation itself never sees
// the question. Read-only: it can read and search files in its folder, but not change anything, run commands or hand
// out work. A follow-up continues the same copy. Its messages are sequenced events tagged with the conversation it was
// asked in, so every device has it. ("Claude" in names here means the lead's agent, whichever it is.)
import { ClaudeAside, type Aside, type ClaudeAsideDeps, type ForkSource, type Forked } from './agents/aside.ts';
import type { McpSdkServerConfigWithInstance } from '@anthropic-ai/claude-agent-sdk';
import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import type { TaskSize } from './fleet.ts';
import { ANSWER_FIRST } from './notes.ts';
import type { Checked, EventBody, SideAbout } from './protocol.ts';
import type { RouteLog } from './routelog.ts';
import { classify, route, type QuestionClass, type Route } from './routing.ts';
import { evidence, present, scout, type ScoutOutcome, type ScoutRun } from './scout.ts';
import { fetchRules } from './web.ts';

export { lastReply, type ForkSource } from './agents/aside.ts';

export const SIDE_TOOLS = ['Read', 'Glob', 'Grep', 'WebSearch', 'WebFetch'];
// Everything but fetching runs without asking; pages open on documentation and code-hosting sites only (a side chat
// can't ask, so any other site is refused).
export const SIDE_ALLOWED = ['Read', 'Glob', 'Grep', 'WebSearch', ...fetchRules()];
// The agent answers with its quick model (Claude: Haiku) unless the question needs judgment (design, debugging,
// outside knowledge) or a local answer couldn't settle it: then its judgment model (Sonnet). "auto": the side chat routes
// each question (routing.ts).
const JUDGMENT: readonly QuestionClass[] = ['design', 'debug', 'external'];
const AUTO = 'auto';
const MAX_ANSWERING = 3;
const MAX_TURNS = 16;
const ABOUT_MAX = 8000;

type Chat = {
  id: string; title: string; model: string; by: string; about?: SideAbout; conversationId?: string;
  sessionId?: string; forked?: Forked; abort?: AbortController;
  /** Claude once it has answered here (it has the copy, and the thread): follow-ups stay with it. */
  route?: 'local' | 'claude';
  /** A model picked by hand: Claude answers, with that model. */
  chosen?: boolean;
  /** What was answered here before Claude had the thread (local models, or the note it continues), for a follow-up's
   *  context and for Claude when it takes over. */
  history: { q: string; a: string; worker?: string }[];
  /** The last local answer, kept for "Ask Claude". */
  lastLocal?: ScoutOutcome & { question: string };
  /** The local worker's task while it answers, to stop it. */
  localTask?: string;
  /** What was last said about it (a re-post after a new title keeps it). */
  lastState?: { state: 'answering' | 'idle' | 'failed'; extra: { activity?: string; error?: string } };
  /** The note it continues (a note's thread). */
  annotationId?: string;
  /** Deleted with its note: nothing more is said about it. */
  removed?: boolean;
};

/** What a note's thread starts with: the note's question (and whether it was handwritten) and its answer. */
export type NoteThread = {
  annotationId: string;
  title: string;
  about?: SideAbout;
  conversationId?: string;
  by: string;
  question: string;
  ink?: boolean;
  answer?: { text: string; model?: string; local?: boolean; checked?: Checked; ms?: number; more?: string; escalated?: string };
};

// The SDK calls Claude's asides make, replaceable in tests.
export type SideDeps = ClaudeAsideDeps;

export type SideConfig = {
  source: () => ForkSource;
  env: () => Record<string, string>;
  log: (m: string) => void;
  deps?: Partial<SideDeps>;
  /** Who answers: the lead's agent. Default: Claude Code (with `env` and `deps`). */
  aside?: Aside;
  /** Local models, to answer questions about the code first (routing.ts); without them Claude answers everything. */
  local?: {
    ask(prompt: string, size: TaskSize, by: string, onTask: (taskId: string) => void): Promise<ScoutRun>;
    free(size: TaskSize): boolean;
    cancel(taskId: string): void;
  };
  routes?: RouteLog;
  /** The diagram tool, for Claude answering a note in its thread; `drawn` hears each diagram's id. */
  diagrams?: (drawn: (id: string) => void) => McpSdkServerConfigWithInstance;
};

/**
 * Claude answering a note's own question in its thread: why it came to Claude, what to tell it besides the note (a
 * local model's evidence, or the local answer to check), the picture of the ink, and where the answer goes.
 */
export type NoteAsk = {
  escalated: string;
  extra?: string;
  image?: SideAsk['image'];
  done: (r: { text: string; diagrams: string[] }) => void;
  failed?: (error: string) => void;
};

// voice: asked out loud in Talk mode; the answer is read aloud.
// route: where it must go (the hub's own "Ask Claude"); unset, the side chat routes it.
export type SideAsk = { chatId?: string; text: string; about?: SideAbout; model?: string; image?: { data: string; type: 'image/png' | 'image/jpeg' }; voice?: boolean; route?: 'local' | 'claude' };

/** Before a question asked out loud: the answer is read aloud, so its start should sound right spoken. */
export const SIDE_VOICE =
  "[Asked out loud in Talk mode: your answer is read aloud (code blocks and tables are skipped; they stay on screen). Open with the answer in one to three short, plain sentences, with no file paths, symbols or code in them. If you're unsure, say so.]";

export class SideChats {
  private chats = new Map<string, Chat>();
  private cfg: SideConfig;
  private aside: Aside;
  private emit: (e: EventBody) => void;

  constructor(cfg: SideConfig, emit: (e: EventBody) => void) {
    this.cfg = cfg;
    this.emit = emit;
    this.aside = cfg.aside ?? new ClaudeAside({ env: cfg.env, allowed: SIDE_ALLOWED, log: cfg.log, deps: cfg.deps });
  }

  private get quickModel(): string { return this.aside.quick; }
  private get judgmentModel(): string { return this.aside.judgment; }

  /** After a restart, side chats continue from the log. One that was answering when the hub stopped says so. */
  seed(events: EventBody[]): void {
    const answering = new Set<string>();
    const asked = new Map<string, string>();
    for (const e of events) {
      // Local answers, with the questions they answered: a follow-up's context, and Claude's when it takes over.
      if (e.type === 'side_message') {
        const c = this.chats.get(e.chatId);
        const q = asked.get(e.chatId) ?? '';
        if (e.role === 'user') asked.set(e.chatId, e.text);
        else if (c && (e.local || e.fromNote)) {
          c.history.push({ q, a: e.text, worker: e.model });
          // "Ask Claude" still works on the last local answer.
          if (e.local) c.lastLocal = shownLocal(q, e.text, e.model, e.ms);
        }
        continue;
      }
      if (e.type !== 'side_chat') continue;
      if (e.deleted) {
        this.chats.delete(e.chatId);
        answering.delete(e.chatId);
        continue;
      }
      const c: Chat = this.chats.get(e.chatId) ?? { id: e.chatId, title: e.title, model: e.model, by: e.by, history: [] };
      Object.assign(c, { title: e.title, model: e.model, by: e.by, about: e.about ?? c.about, conversationId: e.conversationId ?? c.conversationId, annotationId: e.annotationId ?? c.annotationId });
      // A copy of the conversation means Claude has answered here: follow-ups stay with it.
      if (e.sessionId) {
        c.sessionId = e.sessionId;
        c.route = 'claude';
      }
      if (e.forked) c.forked = e.forked;
      this.chats.set(c.id, c);
      if (e.state === 'answering') answering.add(c.id); else answering.delete(c.id);
    }
    for (const id of answering) this.state(this.chats.get(id)!, 'failed', { error: 'The hub restarted while this was being answered. Ask again.' });
  }

  answering(): number {
    return [...this.chats.values()].filter((c) => c.abort).length;
  }

  /**
   * A better name for a side chat than its question's first line, from a device's on-device model. Note threads keep
   * theirs (they're named after the note). The chat is posted again as it was, with the new title, so every device
   * shows it. False when it's refused or the same.
   */
  retitle(chatId: string, title: unknown): boolean {
    const chat = this.chats.get(chatId);
    if (!chat || chat.removed) throw new Error(`no side chat ${chatId}`);
    if (chat.annotationId) return false;
    const t = typeof title === 'string' ? title.trim().replace(/[.!:;,]+$/, '').replace(/\s+/g, ' ') : '';
    const words = t.split(' ').filter(Boolean).length;
    if (!t || t.length > 60 || words < 1 || words > 8) throw new Error('a title is one to eight words, at most 60 characters');
    if (t === chat.title) return false;
    chat.title = t;
    this.state(chat, chat.lastState?.state ?? 'idle', chat.lastState?.extra ?? {});
    return true;
  }

  has(chatId: string): boolean {
    return this.chats.has(chatId);
  }

  busy(chatId: string): boolean {
    return !!this.chats.get(chatId)?.abort;
  }

  /**
   * A note's thread: a side chat that continues the note, opened by the first reply to it. It starts with the note's
   * question and answer as its first exchange, so a follow-up has them as context, and "Ask Claude" can check a local
   * answer to the note from here. Returns the chat id; the reply itself is asked with `ask`.
   */
  thread(t: NoteThread): string {
    const chat: Chat = {
      id: `sc-${randomUUID().slice(0, 8)}`, title: firstLine(t.question || t.title), model: AUTO, by: t.by, about: clipAbout(t.about),
      conversationId: t.conversationId ?? this.cfg.source().sessionId, annotationId: t.annotationId, history: [],
    };
    this.chats.set(chat.id, chat);
    this.state(chat, 'idle');
    const question = t.question || 'The handwritten note';
    this.post(chat, { type: 'side_message', chatId: chat.id, id: `m-${randomUUID().slice(0, 8)}`, role: 'user', text: question, by: t.by, fromNote: true, ...(t.ink ? { image: true } : {}) });
    const a = t.answer;
    if (a) {
      this.post(chat, {
        type: 'side_message', chatId: chat.id, id: `m-${randomUUID().slice(0, 8)}`, role: 'assistant', text: a.text, fromNote: true,
        ...(a.model ? { model: a.model } : {}), ...(a.local ? { local: true } : {}), ...(a.checked ? { checked: a.checked } : {}),
        ...(a.ms !== undefined ? { ms: a.ms } : {}), ...(a.more ? { more: a.more } : {}), ...(a.escalated ? { escalated: a.escalated } : {}),
      });
      chat.history.push({ q: question, a: a.text, worker: a.model });
      if (a.local) chat.lastLocal = shownLocal(question, a.text, a.model, a.ms);
    }
    return chat.id;
  }

  /**
   * Claude answers a note's own question in its thread: the note went to Claude (sent on by a local model, asked
   * directly, or "Ask Claude" about a local answer). As a side chat's Claude answer, in a copy of the conversation, but
   * marked as the note's, able to draw a diagram, and handed to `done` to keep on the note. `text` is the note as the
   * conversation would have had it (notesPrompt).
   */
  answerNote(chatId: string, text: string, o: NoteAsk): void {
    const chat = this.chats.get(chatId);
    if (!chat) throw new Error(`no side chat ${chatId}`);
    if (chat.abort) throw new Error('this note is still being answered');
    chat.abort = new AbortController();
    chat.route = 'claude';
    if (!chat.chosen) chat.model = this.judgmentModel;
    this.state(chat, 'answering', { activity: `Asking ${this.aside.name}` });
    void this.run(chat, text, o.image, !chat.sessionId, false, { escalated: o.escalated, extra: [this.earlier(chat), o.extra].filter(Boolean).join('\n\n'), t0: Date.now(), note: o });
  }

  /** Deleted with the note it continued: stopped if it was answering, and gone from every device. */
  remove(chatId: string): void {
    const chat = this.chats.get(chatId);
    if (!chat) return;
    chat.abort?.abort();
    if (chat.localTask) this.cfg.local?.cancel(chat.localTask);
    this.chats.delete(chatId);
    this.post(chat, { type: 'side_chat', chatId, state: 'idle', title: chat.title, model: chat.model, by: chat.by, deleted: true, ...(chat.annotationId ? { annotationId: chat.annotationId } : {}) });
    chat.removed = true;
  }

  /**
   * A question in a new side chat (no chatId) or a follow-up. Returns the chat id; the answer comes in the background:
   * from a local model when it's a question about the code and its citations check out, else from Claude.
   */
  ask(by: string, a: SideAsk): string {
    const text = a.text?.trim() ?? '';
    if (!text && !a.image) throw new Error('empty question');
    const picked = a.model?.trim() && a.model.trim() !== AUTO ? a.model.trim() : undefined;
    if (picked && !/^[a-z0-9][a-z0-9.\-[\]]{0,63}$/i.test(picked)) throw new Error(`not a model: ${picked}`);
    let chat = a.chatId ? this.chats.get(a.chatId) : undefined;
    if (a.chatId && !chat) throw new Error(`no side chat ${a.chatId}`);
    if (chat?.abort) throw new Error('this side chat is still answering; wait for it, or stop it');
    if (this.answering() >= MAX_ANSWERING) throw new Error(`${MAX_ANSWERING} side chats are answering already; wait for one to finish`);
    if (!chat) {
      chat = { id: `sc-${randomUUID().slice(0, 8)}`, title: firstLine(text || 'About the picture'), model: picked ?? AUTO, by, about: clipAbout(a.about), conversationId: this.cfg.source().sessionId, history: [] };
      this.chats.set(chat.id, chat);
    }
    if (picked) {
      chat.model = picked;
      chat.chosen = true;
    }
    const r = this.decide(chat, text, a);
    chat.abort = new AbortController();
    this.state(chat, 'answering', { activity: r.to === 'local' ? 'A local model is reading the code' : chat.sessionId ? 'Thinking' : 'Reading the conversation' });
    this.post(chat, { type: 'side_message', chatId: chat.id, id: `m-${randomUUID().slice(0, 8)}`, role: 'user', text, by, ...(a.image ? { image: true } : {}) });
    if (r.to === 'local') {
      void this.runLocal(chat, text, r, a.voice === true);
    } else {
      // Claude: the model picked by hand, or the one this kind of question needs.
      if (!chat.chosen && chat.route !== 'claude') chat.model = JUDGMENT.includes(r.cls) ? this.judgmentModel : this.quickModel;
      chat.route = 'claude';
      this.cfg.routes?.write({ surface: 'side', id: chat.id, by, cls: r.cls, to: 'claude', why: r.why, outcome: 'claude' });
      void this.run(chat, text, a.image, !chat.sessionId, a.voice === true, { extra: this.earlier(chat), t0: Date.now() });
    }
    return chat.id;
  }

  /** "Ask Claude" about the last answer a local model gave here: Claude checks it, with what the local model found. */
  reroute(by: string, chatId: string): void {
    const chat = this.chats.get(chatId);
    if (!chat) throw new Error(`no side chat ${chatId}`);
    if (chat.abort) throw new Error('this side chat is still answering; wait for it, or stop it');
    const last = chat.lastLocal;
    if (!last) throw new Error('no answer here came from a local model');
    if (this.answering() >= MAX_ANSWERING) throw new Error(`${MAX_ANSWERING} side chats are answering already; wait for one to finish`);
    chat.abort = new AbortController();
    chat.route = 'claude';
    if (!chat.chosen) chat.model = this.judgmentModel;
    this.state(chat, 'answering', { activity: `Asking ${this.aside.name}` });
    this.cfg.routes?.write({ surface: 'side', id: chat.id, by, cls: classify(last.question), to: 'claude', why: 'you asked Claude', outcome: 'override', worker: last.worker });
    const check = `[duet] ${last.worker ?? 'A local model'} answered the question below in this side chat, and the user asked you to check it. Its answer:\n${last.scouted?.answer.slice(0, 2000) ?? ''}`;
    void this.run(chat, last.question, undefined, !chat.sessionId, false, { escalated: 'you asked Claude', extra: [this.earlier(chat), check].filter(Boolean).join('\n\n'), t0: Date.now() });
  }

  /** Where a question goes: Claude once it has this thread, or when a model was picked; else by the question. */
  private decide(chat: Chat, text: string, a: SideAsk): Route {
    const forced = a.route ?? (chat.chosen || chat.route === 'claude' ? 'claude' : undefined);
    if (!this.cfg.local) return { to: 'claude', cls: classify(text), size: 'large', why: 'no local models here' };
    return route(text, 'side', { forced, localFree: (size) => this.cfg.local!.free(size), picture: !!a.image });
  }

  /** A local model answers; Claude takes over, with its evidence, when the answer doesn't check out. */
  private async runLocal(chat: Chat, text: string, r: Route, voice: boolean): Promise<void> {
    chat.route = 'local';
    const t0 = Date.now();
    const context = chat.history.slice(-2).map((h) => `Q: ${h.q}\nA: ${h.a.slice(0, 600)}`).join('\n\n') || undefined;
    let o: ScoutOutcome;
    try {
      o = await scout((prompt) => this.cfg.local!.ask(prompt, r.size, chat.by, (id) => { chat.localTask = id; }), { question: text, about: chat.about ? describeAbout(chat.about) : undefined, context }, this.cfg.source().cwd);
    } catch (e) {
      this.cfg.log(`side chat ${chat.id}: local answer failed: ${e}`);
      o = { scouted: null, checked: null, verdict: { pass: false, why: 'the local model failed', repairable: false }, tries: 1, ms: Date.now() - t0 };
    }
    chat.localTask = undefined;
    if (chat.abort?.signal.aborted) {
      chat.abort = undefined;
      this.state(chat, 'failed', { error: 'Stopped.' });
      return;
    }
    const citations = o.checked ? { checked: o.checked.claims.length + o.checked.failed.length, failed: o.checked.failed.length, fixed: o.checked.fixed } : undefined;
    if (o.verdict.pass && o.scouted && o.checked) {
      const ms = Date.now() - t0;
      const shown = present(o.scouted, o.checked);
      this.post(chat, {
        type: 'side_message', chatId: chat.id, id: `m-${randomUUID().slice(0, 8)}`, role: 'assistant', text: shown.text,
        ...(o.worker ? { model: o.worker } : {}), local: true, checked: { claims: o.checked.claims.length, failed: 0 }, ms, ...(shown.more ? { more: shown.more } : {}),
      });
      chat.history.push({ q: text, a: o.scouted.answer, worker: o.worker });
      chat.lastLocal = { ...o, question: text };
      chat.abort = undefined;
      // Logged before it's announced as done, so the log never lags what devices see.
      this.cfg.routes?.write({ surface: 'side', id: chat.id, by: chat.by, cls: r.cls, to: 'local', why: r.why, outcome: 'local', worker: o.worker, ms, citations, tries: o.tries, words: shown.words, ...(shown.trimmed ? { trimmed: true } : {}) });
      this.state(chat, 'idle');
      return;
    }
    // On to Claude, with what the local model found.
    const why = o.verdict.pass ? '' : o.verdict.why;
    chat.route = 'claude';
    if (!chat.chosen) chat.model = this.judgmentModel;
    this.cfg.routes?.write({ surface: 'side', id: chat.id, by: chat.by, cls: r.cls, to: 'local', why: r.why, outcome: 'escalated', worker: o.worker, ms: Date.now() - t0, citations, tries: o.tries, escalated: why });
    await this.run(chat, text, undefined, !chat.sessionId, voice, { escalated: why, extra: [this.earlier(chat), evidence(o)].filter(Boolean).join('\n\n'), t0 });
  }

  /** For Claude's first answer in a side chat local models have answered in: what they said. */
  private earlier(chat: Chat): string {
    if (chat.sessionId || !chat.history.length) return '';
    return `[duet] Earlier in this side chat:\n${chat.history.map((h) => `Q: ${h.q}\nA (${h.worker ?? 'a local model'}): ${h.a.slice(0, 800)}`).join('\n\n')}`;
  }

  stop(chatId: string): void {
    const c = this.chats.get(chatId);
    if (!c) throw new Error(`no side chat ${chatId}`);
    c.abort?.abort();
    if (c.localTask) this.cfg.local?.cancel(c.localTask);
  }

  stopAll(): void {
    for (const c of this.chats.values()) c.abort?.abort();
  }

  private post(chat: Chat, e: EventBody): void {
    if (chat.removed) return;
    this.emit(chat.conversationId ? { ...e, conversationId: chat.conversationId } : e);
  }

  private state(chat: Chat, state: 'answering' | 'idle' | 'failed', extra: { activity?: string; error?: string } = {}): void {
    chat.lastState = { state, extra };
    this.post(chat, {
      type: 'side_chat', chatId: chat.id, state, title: chat.title, model: chat.model, by: chat.by,
      ...(chat.about ? { about: chat.about } : {}), ...(chat.forked ? { forked: chat.forked } : {}), ...(chat.sessionId ? { sessionId: chat.sessionId } : {}),
      ...(chat.annotationId ? { annotationId: chat.annotationId } : {}), ...extra,
    });
  }

  /** Claude answers in the copy. `more`: what to tell it besides the question (a local model's evidence, the side
   *  chat's earlier local answers), and why it was sent on, shown on its first message. */
  private async run(chat: Chat, text: string, image: SideAsk['image'], fresh: boolean, voice = false, more: { escalated?: string; extra?: string; t0?: number; note?: NoteAsk } = {}): Promise<void> {
    const abort = chat.abort!;
    let error: string | undefined;
    if (chat.model === AUTO) chat.model = this.judgmentModel;
    let first = true;
    // Answering a note: its answer is what Claude said without reaching for a tool, plus the diagrams it drew.
    const note = more.note;
    const said: { text: string; tools: boolean }[] = [];
    const drawn: string[] = [];
    const diagrams = note && this.cfg.diagrams ? this.cfg.diagrams((id) => drawn.push(id)) : undefined;
    try {
      let from: string | undefined;
      if (fresh) {
        const f = await this.aside.fork(this.cfg.source());
        chat.forked = f.forked;
        from = f.from;
      }
      // A follow-up is asked as typed, with the reminder of how an answer starts (spoken ones have their own).
      const asked = !fresh ? (voice ? text : `[${ANSWER_FIRST}]\n\n${text}`) : note ? notePrompt(text, chat.forked ?? 'none') : sidePrompt(chat.by, text, chat.about, chat.forked ?? 'none');
      const withEvidence = more.extra ? `${asked}\n\n${more.extra}` : asked;
      const prompt = voice ? `${SIDE_VOICE}\n\n${withEvidence}` : withEvidence;
      const src = this.cfg.source();
      await this.aside.run({
        prompt, image, model: chat.model, maxTurns: MAX_TURNS, signal: abort.signal, diagrams,
        // The lead's folder, unless it has gone since (then home, so the answer still comes).
        cwd: existsSync(src.cwd) ? src.cwd : homedir(),
        ...(fresh ? (from ? { from } : {}) : chat.sessionId ? { resume: chat.sessionId } : {}),
      }, (e) => {
        if (e.type === 'session') chat.sessionId = e.id;
        else if (e.type === 'text') this.post(chat, { type: 'side_delta', chatId: chat.id, text: e.delta });
        else if (e.type === 'error') error = e.message;
        else if (e.type === 'message') {
          if (e.text.trim()) {
            // The first answer says which model, how long it took, and why it came to the agent.
            const meta = first ? { model: chat.model, ...(more.t0 ? { ms: Date.now() - more.t0 } : {}), ...(more.escalated ? { escalated: more.escalated } : {}) } : { model: chat.model };
            first = false;
            this.post(chat, { type: 'side_message', chatId: chat.id, id: e.id ?? `m-${randomUUID().slice(0, 8)}`, role: 'assistant', text: e.text, ...meta, ...(note ? { fromNote: true } : {}) });
            said.push({ text: e.text.trim(), tools: !!e.tool });
          }
          if (e.tool) this.state(chat, 'answering', { activity: activity(e.tool.name, e.tool.input) });
        }
      });
    } catch (e) {
      error = abort.signal.aborted ? 'Stopped.' : String(e instanceof Error ? e.message : e).slice(0, 300);
      if (!abort.signal.aborted) this.cfg.log(`side chat ${chat.id} failed: ${error}`);
    } finally {
      chat.abort = undefined;
    }
    if (note && !chat.removed) {
      const replies = said.filter((s) => !s.tools);
      const answer = (replies.length ? replies : said).map((s) => s.text).join('\n\n');
      if (!error && answer) note.done({ text: answer, diagrams: [...new Set(drawn)] });
      else note.failed?.(error ?? `${this.aside.name} said nothing`);
    }
    this.state(chat, error ? 'failed' : 'idle', error ? { error } : {});
  }

}

/** What a copy of the conversation has seen: all of it, up to the turn in progress, or nothing yet. */
function seenSoFar(forked: Forked): string {
  return forked === 'before_turn'
    ? " You see our conversation up to your last reply; you're still working on the turn after it, so this copy doesn't know what that turn has done yet."
    : forked === 'none' ? " There's no conversation to go on yet: answer from what you can read." : '';
}

/** Claude answering a note in its thread: what that is, then the note as the conversation would have had it. */
export function notePrompt(note: string, forked: Forked): string {
  const head = `[A note, answered in its own thread beside our conversation: nothing here goes into the conversation itself. ${ANSWER_FIRST} You can read and search files, search the web, open documentation pages and draw a diagram, but not change anything, run commands or hand out work. Name the file and line, or the page, an answer comes from; if you can't find it, say so.${seenSoFar(forked)}]`;
  return `${head}\n\n${note}`;
}

/** The first question of a side chat: what it is, what it's about, and the question. */
export function sidePrompt(by: string, text: string, about: SideAbout | undefined, forked: Forked): string {
  const seen = seenSoFar(forked);
  const head = `[Side chat from ${by}: a quick question beside our conversation. Nothing here goes into the conversation itself, so answer directly. ${ANSWER_FIRST} You can read and search files, search the web and open documentation pages, but not change anything, run commands or hand out work. Name the file and line, or the page, an answer comes from; if you can't find it, say so.${seen}]`;
  return [head, about ? describeAbout(about) : '', text].filter(Boolean).join('\n\n');
}

function describeAbout(a: SideAbout): string {
  if (a.kind === 'file') {
    const lines = a.start ? `, lines ${a.start}${a.end && a.end !== a.start ? `-${a.end}` : ''}` : '';
    return `About the file ${a.path}${lines}.`;
  }
  return a.text?.trim() ? `About ${a.label}:\n${a.text.trim()}` : `About ${a.label}.`;
}

function clipAbout(a: SideAbout | undefined): SideAbout | undefined {
  if (!a) return undefined;
  if (a.kind === 'text' && a.text && a.text.length > ABOUT_MAX) return { ...a, text: `${a.text.slice(0, ABOUT_MAX)}\n[…]` };
  return a;
}

/** "Read src/fleet.ts", for the side chat's status line. */
function activity(tool: string, input: unknown): string {
  const i = (input ?? {}) as Record<string, unknown>;
  const what = [i.file_path, i.pattern, i.path, i.url, i.query].find((v) => typeof v === 'string' && v) as string | undefined;
  return what ? `${tool} ${what}` : tool;
}

/** A local answer as it was shown, standing in for its draft when "Ask Claude" sends it on (from a note, or after a restart). */
function shownLocal(question: string, text: string, worker?: string, ms = 0): ScoutOutcome & { question: string } {
  return { worker, scouted: { answer: text, more: [], claims: [], unknowns: [], confidence: 'high' }, checked: null, verdict: { pass: true }, tries: 1, ms, question };
}

function firstLine(text: string): string {
  const line = text.split('\n').map((l) => l.trim()).find(Boolean) ?? 'Side chat';
  return line.length > 60 ? `${line.slice(0, 59)}…` : line;
}
