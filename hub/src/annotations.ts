// Annotations: every handwritten note kept with what it was written on (a file's lines and their code, a diagram's
// elements, a diff), a picture of the handwriting, and, once Claude has taken it, Claude's answer and any diagram it
// drew in that turn. They live in the event log (`annotation` events, latest wins), so every device has them and
// they outlive restarts; the pictures are files beside the log.
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Annotation, EventBody, HubEvent, InkNote, NoteSurface } from './protocol.ts';

const ANSWER_MAX = 8000;
const INK_MAX = 512 << 10;

export class Annotations {
  private all = new Map<string, Annotation>();
  /** Turns that took notes: Claude's text in each, and the diagrams it drew. */
  // Each message's text, and whether it ran tools ("Let me read the action" is how Claude works, not its answer).
  private watching = new Map<number, { text: { text: string; tools: boolean }[]; diagrams: string[] }>();
  private turn = 0;
  /** When Claude was asked to check a local answer: its answer's time counts from then. */
  private asked = new Map<string, number>();
  /** The conversation each note was written in: the tag on its first event. */
  private conversations = new Map<string, string>();
  private dir: string;
  private emit: (e: EventBody) => void;

  constructor(stateDir: string, emit: (e: EventBody) => void) {
    this.dir = join(stateDir, 'ink');
    this.emit = emit;
  }

  /** Rebuild from the log after a restart. */
  seed(events: HubEvent[]): void {
    for (const e of events) {
      if (e.type !== 'annotation') continue;
      this.wroteIn(e);
      if (e.annotation.deleted) this.all.delete(e.annotation.id);
      else this.all.set(e.annotation.id, e.annotation);
    }
  }

  get(id: string): Annotation | undefined {
    return this.all.get(id);
  }

  /** The conversation the note was written in. */
  conversationOf(id: string): string | undefined {
    return this.conversations.get(id);
  }

  /** The note's thread: the side chat its replies continue in. */
  thread(id: string, chatId: string): void {
    const a = this.all.get(id);
    if (a) this.put({ ...a, chatId });
  }

  private wroteIn(e: HubEvent): void {
    if (e.type === 'annotation' && e.conversationId && !this.conversations.has(e.annotation.id)) this.conversations.set(e.annotation.id, e.conversationId);
  }

  /** New notes: each becomes an annotation, its handwriting (a PNG, base64) kept beside the log. */
  add(by: string, surface: NoteSurface, items: (InkNote & { ink?: string })[]): void {
    for (const { ink, ...note } of items) {
      const a: Annotation = { ...note, surface, by, ts: Date.now(), status: 'open' };
      if (ink && this.saveInk(note.id, ink)) a.ink = true;
      this.put(a);
    }
  }

  /** Claude took these notes in this turn: its answer, and its diagrams, come from the turn. */
  taken(ids: string[], turn: number): void {
    for (const id of ids) {
      const a = this.all.get(id);
      if (!a) continue;
      this.watching.set(turn, this.watching.get(turn) ?? { text: [], diagrams: [] });
      this.put({ ...a, turn });
    }
  }

  onEvent(e: HubEvent): void {
    switch (e.type) {
      case 'annotation':
        this.wroteIn(e);
        break;
      case 'turn_start':
        this.turn = e.turn;
        break;
      case 'assistant':
        if (e.text.trim()) this.watching.get(e.turn)?.text.push({ text: e.text.trim(), tools: e.toolUses.length > 0 });
        break;
      case 'diagram':
        if (e.by === 'lead') this.watching.get(this.turn)?.diagrams.push(e.id);
        break;
      case 'turn_end': {
        const w = this.watching.get(e.turn);
        if (!w) break;
        this.watching.delete(e.turn);
        // After every listener has had the turn_end: appending from inside one would reach the rest out of order.
        queueMicrotask(() => this.answered(e.turn, w, e.interrupted));
        break;
      }
    }
  }

  private answered(turn: number, w: { text: { text: string; tools: boolean }[]; diagrams: string[] }, interrupted: boolean): void {
    // The answer is what Claude said without reaching for a tool; narration on the way there is left out.
    const replies = w.text.filter((t) => !t.tools);
    const answer = (replies.length ? replies : w.text).map((t) => t.text).join('\n\n');
    // Stopped, or nothing said: still open.
    if (interrupted || (!answer && !w.diagrams.length)) return;
    const diagrams = [...new Set(w.diagrams)];
    for (const a of [...this.all.values()]) {
      if (a.turn !== turn || a.status !== 'open') continue;
      const { answering: _a, more: _m, ...rest } = a;
      const since = this.asked.get(a.id) ?? a.ts;
      this.asked.delete(a.id);
      this.put({ ...rest, status: 'answered', answer: answer.length > ANSWER_MAX ? `${answer.slice(0, ANSWER_MAX - 1)}…` : answer, ...(diagrams.length ? { diagrams } : {}), answeredBy: 'Claude', route: 'claude', ms: Date.now() - since });
    }
  }

  /** Who's answering it now, where it went and why: shown on the note while it waits. */
  routing(id: string, change: Partial<Pick<Annotation, 'status' | 'route' | 'answering' | 'escalated' | 'answer' | 'answeredBy' | 'localAnswer'>>): void {
    const a = this.all.get(id);
    if (a) this.put({ ...a, ...change });
  }

  /** Claude is asked to check a local model's answer: the note is open again, with that answer set aside (so it isn't
   *  shown as Claude's while Claude works). */
  reask(id: string, why: string): void {
    const a = this.all.get(id);
    if (!a?.answer) return;
    const { answer, more, answeredBy: _b, checked: _c, ms: _m, ...rest } = a;
    this.asked.set(id, Date.now());
    this.put({ ...rest, status: 'open', route: 'claude', answering: 'Claude', escalated: why, localAnswer: more ? `${answer}\n\n${more}` : answer });
  }

  /** Claude's answer to the note, given in the note's thread: kept like an answer from the conversation, with any
   *  diagram it drew. */
  answeredInThread(id: string, r: { text: string; diagrams: string[] }): void {
    const a = this.all.get(id);
    if (!a) return;
    const since = this.asked.get(id) ?? a.ts;
    this.asked.delete(id);
    const { answering: _a, more: _m, ...rest } = a;
    const answer = r.text.length > ANSWER_MAX ? `${r.text.slice(0, ANSWER_MAX - 1)}…` : r.text;
    this.put({ ...rest, status: 'answered', answer, ...(r.diagrams.length ? { diagrams: r.diagrams } : {}), answeredBy: 'Claude', route: 'claude', ms: Date.now() - since });
  }

  /** A local model's answer, its citations checked: the note is answered without Claude. */
  answerLocally(id: string, answer: string, meta: { worker: string; checked: { claims: number; failed: number }; ms: number; more?: string }): void {
    const a = this.all.get(id);
    if (!a) return;
    const { answering: _a, escalated: _e, more: _m, ...rest } = a;
    this.put({ ...rest, status: 'answered', answer, answeredBy: meta.worker, route: 'local', checked: meta.checked, ms: meta.ms, ...(meta.more ? { more: meta.more } : {}) });
  }

  /** Resolve or reopen one, or delete it (and its picture). */
  update(id: string, change: { status?: 'open' | 'resolved'; delete?: boolean }): void {
    const a = this.all.get(id);
    if (!a) throw new Error(`no annotation ${id}`);
    if (change.delete) {
      this.all.delete(id);
      try { unlinkSync(this.inkFile(id)); } catch { /* none kept */ }
      this.emit({ type: 'annotation', annotation: { ...a, deleted: true } });
      return;
    }
    if (change.status) this.put({ ...a, status: change.status === 'open' ? (a.answer ? 'answered' : 'open') : 'resolved' });
  }

  /** The handwriting, as base64 PNG. */
  ink(id: string): string {
    const f = this.inkFile(id);
    if (!existsSync(f)) throw new Error(`no handwriting kept for ${id}`);
    return readFileSync(f).toString('base64');
  }

  private put(a: Annotation): void {
    this.all.set(a.id, a);
    this.emit({ type: 'annotation', annotation: a });
  }

  private inkFile(id: string): string {
    return join(this.dir, `${id.replace(/[^A-Za-z0-9-]/g, '')}.png`);
  }

  private saveInk(id: string, b64: string): boolean {
    const buf = Buffer.from(b64, 'base64');
    // A PNG, and small: a note's handwriting, not a page.
    if (buf.length > INK_MAX || buf.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a') return false;
    mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    writeFileSync(this.inkFile(id), buf, { mode: 0o600 });
    return true;
  }
}
