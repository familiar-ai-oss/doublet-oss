// A local model answers a question about the code by reading it, and has to show its work: every fact it states comes
// with a quote from a file, and the hub checks each quote against the file before the answer counts. An answer that
// can't prove itself goes to Claude, together with what the local model did find (so Claude doesn't read it all again).
import { existsSync, readFileSync, statSync } from 'node:fs';
import { isAbsolute, join, relative, resolve } from 'node:path';

export type Claim = { text: string; file: string; start: number; end: number; quote: string };
/** `answer` is the direct answer; `more` the few further points worth knowing, shown under "More". */
export type Scouted = { answer: string; more: string[]; claims: Claim[]; unknowns: string[]; confidence: 'high' | 'medium' | 'low' };
/** The claims that checked out (their lines corrected when the quote was found a few lines off), and those that didn't. */
export type Checked = { claims: Claim[]; failed: { claim: Claim; why: string }[]; fixed: number };
export type Verdict = { pass: true } | { pass: false; why: string; repairable: boolean };
export type ScoutAsk = { question: string; about?: string; context?: string };

/** What the hub hears back from a local worker's run. */
export type ScoutRun = { ok: boolean; result: string; worker: string; taskId?: string; error?: string };
export type ScoutOutcome = { worker?: string; scouted: Scouted | null; checked: Checked | null; verdict: Verdict; tries: number; ms: number };

const FILE_MAX = 2_000_000;
const QUOTE_MIN = 6;
// An answer is read at a glance, often on a phone. The prompt asks for these limits…
const ANSWER_WORDS = 50;
const POINTS = 3;
const POINT_WORDS = 25;
// …and past these (some slack), the answer gets one more try to shorten it, and anything still over goes under "More".
const ANSWER_MAX = 65;
const POINTS_MAX = 5;
const POINT_MAX = 45;
const SOURCES_SHOWN = 4;

const ITEM = /^\s*(?:[-*•]|\d+[.)])\s+/;
const words = (t: string) => t.split(/\s+/).filter(Boolean).length;
const draftText = (s: Scouted) => [s.answer, ...s.more.map((m) => `- ${m}`)].join('\n');

export function scoutPrompt(q: ScoutAsk, repair?: { draft: Scouted; failed: Checked['failed']; long?: boolean }): string {
  const parts = [
    "Answer a developer's question about the code in this folder. Read the code to answer: Grep and Glob to find things, Read to read them. Don't answer from memory, and don't change anything.",
    `Question: ${q.question.trim()}`,
    ...(q.about ? [`It's about: ${q.about}`] : []),
    ...(q.context ? [`What was said just before, for context:\n${q.context}`] : []),
  ];
  if (repair) {
    if (repair.failed.length) {
      const bad = repair.failed.map((f) => `- "${f.claim.quote.slice(0, 160)}" in ${f.claim.file}:${f.claim.start}-${f.claim.end}: ${f.why}`).join('\n');
      parts.push(`Your last answer cited lines that didn't match the files:\n${bad}\nRead those files again and fix the quotes and line numbers, or drop those claims.`);
    }
    if (repair.long) {
      const points = repair.draft.more.length ? ` and ${repair.draft.more.length} points` : '';
      parts.push(`Your last answer was too long to read at a glance (${words(repair.draft.answer)} words${points}). Rewrite it within the limits below, keeping its facts and claims.`);
    }
    parts.push(`Your last answer was:\n${draftText(repair.draft).slice(0, 1500)}`);
  }
  parts.push(
    'When you are done, reply with only this JSON object and nothing else:',
    '{"answer": "the direct answer, in one or two short sentences", "more": ["a short point worth knowing"], "claims": [{"text": "one fact the answer relies on", "file": "path/relative/to/this/folder", "start": 12, "end": 14, "quote": "the exact text of those lines, copied from the file"}], "unknowns": ["anything the answer needs that you could not find or check"], "confidence": "high"}',
    `It's read at a glance, often on a phone, so keep it short and plain. "answer" answers the question in at most ${ANSWER_WORDS} words: no heading, no preamble, no restating the question. "more" has at most ${POINTS} points of one short sentence each (under ${POINT_WORDS} words), only when they help; otherwise leave it empty. Use everyday words. When asked for layman's terms, use no jargon and at most one comparison.`,
    `Every fact about the code in your answer needs a claim whose quote is copied exactly from the file at those lines: each quote is checked against the file. Cite what the answer rests on, at most ${POINTS} claims, each on different lines. If you could not find something the answer needs, put it in unknowns instead of guessing; leave unknowns empty when the code settles the question (a side remark is not an unknown). confidence is "high", "medium" or "low".`,
  );
  return parts.join('\n\n');
}

/** The JSON object in a worker's reply (fenced or not, with prose around it or not); null when there isn't one. */
export function parseScout(text: string): Scouted | null {
  const from = text.indexOf('{'), to = text.lastIndexOf('}');
  if (from < 0 || to <= from) return null;
  let raw: unknown;
  try { raw = JSON.parse(text.slice(from, to + 1)); } catch { return null; }
  if (!raw || typeof raw !== 'object') return null;
  const o = raw as Record<string, unknown>;
  if (typeof o.answer !== 'string' || !o.answer.trim()) return null;
  const claims = (Array.isArray(o.claims) ? o.claims : []).flatMap((c): Claim[] => {
    if (!c || typeof c !== 'object') return [];
    const r = c as Record<string, unknown>;
    if (typeof r.file !== 'string' || typeof r.quote !== 'string') return [];
    return [{ text: typeof r.text === 'string' ? r.text : '', file: r.file, start: Number(r.start) || 0, end: Number(r.end) || Number(r.start) || 0, quote: r.quote }];
  });
  const unknowns = (Array.isArray(o.unknowns) ? o.unknowns : []).filter((u): u is string => typeof u === 'string' && !!u.trim());
  const confidence = o.confidence === 'high' || o.confidence === 'low' ? o.confidence : 'medium';
  // Points as a list, or as one string with a point per line.
  const more = (Array.isArray(o.more) ? o.more : typeof o.more === 'string' ? o.more.split('\n') : [])
    .flatMap((m) => (typeof m === 'string' && m.replace(ITEM, '').trim() ? [m.replace(ITEM, '').trim()] : []));
  return { answer: o.answer.trim(), more, claims, unknowns, confidence };
}

/** Whether an answer is past the limits, with some slack over what the prompt asks: too long to read at a glance. */
export function wordy(s: Scouted): boolean {
  return words(s.answer) > ANSWER_MAX || s.more.length > POINTS_MAX || s.more.some((m) => words(m) > POINT_MAX);
}

/** Prose as sentences, not split inside `code` or after "e.g." and the like. */
export function sentences(t: string): string[] {
  const out: string[] = [];
  let cur = '';
  let code = false;
  for (let i = 0; i < t.length; i++) {
    const ch = t[i];
    cur += ch;
    if (ch === '`') code = !code;
    else if (!code && '.!?'.includes(ch) && /^\s+["'`*([A-Z0-9]/.test(t.slice(i + 1, i + 4)) && !/\b(?:e\.g|i\.e|etc|vs|cf)\.$/i.test(cur)) {
      out.push(cur.trim());
      cur = '';
    }
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

/**
 * An answer as shown, within the limits whatever the model wrote: the direct answer, cut at a sentence once it's past
 * ANSWER_MAX words, and everything else (further sentences, paragraphs, list items, its own points) as points under
 * "More", at most POINTS_MAX of them. Nothing is reworded, only moved; headings go.
 */
export function brief(s: Scouted): { answer: string; more: string[]; trimmed: boolean } {
  const blocks = s.answer.split(/\n\s*\n/)
    .map((b) => b.split('\n').filter((l) => l.trim() && !/^\s*#{1,6}\s/.test(l)))
    .filter((b) => b.length);
  let lead = '';
  const points: string[] = [];
  blocks.forEach((lines, i) => {
    const prose = lines.filter((l) => !ITEM.test(l)).map((l) => l.trim()).join(' ');
    const items = lines.filter((l) => ITEM.test(l)).map((l) => l.replace(ITEM, '').trim()).filter(Boolean);
    if (i === 0) lead = prose || items.shift() || '';
    else if (prose) points.push(prose);
    points.push(...items);
  });
  const said = sentences(lead);
  let answer = said.shift() ?? '';
  while (said.length && words(`${answer} ${said[0]}`) <= ANSWER_MAX) answer = `${answer} ${said.shift()}`;
  const all = [...said, ...points, ...s.more];
  return { answer, more: all.slice(0, POINTS_MAX), trimmed: said.length + points.length > 0 || all.length > POINTS_MAX };
}

const norm = (s: string) => s.replace(/\s+/g, ' ').trim();

/**
 * Where a quote is in a file, as 1-based lines: the occurrence nearest the lines it was cited at. Whitespace doesn't
 * count (models re-indent, join and split lines), but every other character of the code does.
 */
export function locate(quote: string, lines: string[], near: number): { start: number; end: number } | null {
  const q = quote.replace(/\s+/g, '');
  if (q.length < QUOTE_MIN) return null;
  const size = lines.reduce((n, l) => n + l.length, 0);
  const lineOf = new Int32Array(size);
  let joined = '';
  let n = 0;
  lines.forEach((l, i) => {
    const bare = l.replace(/\s+/g, '');
    joined += bare;
    lineOf.fill(i + 1, n, n + bare.length);
    n += bare.length;
  });
  let best: { start: number; end: number } | null = null;
  for (let at = joined.indexOf(q); at >= 0; at = joined.indexOf(q, at + 1)) {
    const hit = { start: lineOf[at], end: lineOf[at + q.length - 1] };
    if (!best || Math.abs(hit.start - near) < Math.abs(best.start - near)) best = hit;
  }
  return best;
}

/** Checks every claim against the file it cites, inside `cwd` only. */
export function checkClaims(s: Scouted, cwd: string): Checked {
  const root = resolve(cwd);
  const out: Checked = { claims: [], failed: [], fixed: 0 };
  const texts = new Map<string, string[] | string>();
  const read = (path: string): string[] | string => {
    if (!texts.has(path)) {
      try {
        if (!existsSync(path) || !statSync(path).isFile()) texts.set(path, "the file doesn't exist");
        else if (statSync(path).size > FILE_MAX) texts.set(path, 'the file is too big to check');
        else texts.set(path, readFileSync(path, 'utf8').split('\n'));
      } catch {
        texts.set(path, "the file couldn't be read");
      }
    }
    return texts.get(path)!;
  };
  for (const claim of s.claims) {
    const path = resolve(isAbsolute(claim.file) ? claim.file : join(root, claim.file));
    const rel = relative(root, path);
    if (rel.startsWith('..') || isAbsolute(rel)) { out.failed.push({ claim, why: 'it is outside the project folder' }); continue; }
    const lines = read(path);
    if (typeof lines === 'string') { out.failed.push({ claim, why: lines }); continue; }
    if (claim.quote.replace(/\s+/g, '').length < QUOTE_MIN) { out.failed.push({ claim, why: 'the quote is too short to check' }); continue; }
    const at = locate(claim.quote, lines, claim.start);
    if (!at) { out.failed.push({ claim, why: "that text isn't in the file" }); continue; }
    if (at.start !== claim.start || at.end !== claim.end) out.fixed++;
    out.claims.push({ ...claim, file: rel, start: at.start, end: at.end });
  }
  return out;
}

/** Whether a local answer counts, or why it goes to Claude (and whether one more try could fix it). */
export function judge(s: Scouted | null, c: Checked | null): Verdict {
  if (!s || !c) return { pass: false, why: "it didn't give an answer that could be checked", repairable: false };
  if (c.failed.length) return { pass: false, why: `${c.failed.length} of its ${c.failed.length + c.claims.length} citations didn't match the files`, repairable: true };
  if (!c.claims.length) return { pass: false, why: 'it cited nothing from the code', repairable: true };
  if (s.confidence === 'low') return { pass: false, why: "it wasn't confident", repairable: false };
  if (s.unknowns.length) return { pass: false, why: `it couldn't settle: ${s.unknowns[0].slice(0, 120)}`, repairable: false };
  return { pass: true };
}

/**
 * Asks a local worker and checks the answer. It gets one more try when only its citations were off, or when it passed
 * but ran too long; a shorter retry that fails its checks doesn't replace the answer that passed.
 */
export async function scout(run: (prompt: string) => Promise<ScoutRun>, q: ScoutAsk, cwd: string): Promise<ScoutOutcome> {
  const t0 = Date.now();
  let out = await run(scoutPrompt(q));
  let worker = out.worker;
  let s = parseScout(out.result);
  let c = s ? checkClaims(s, cwd) : null;
  let v = judge(s, c);
  let tries = 1;
  const long = !!s && wordy(s);
  if (s && c && ((!v.pass && v.repairable) || (v.pass && long))) {
    tries = 2;
    out = await run(scoutPrompt(q, { draft: s, failed: c.failed, long }));
    const again = parseScout(out.result);
    const checked = again ? checkClaims(again, cwd) : null;
    const verdict = judge(again, checked);
    if (again && (verdict.pass || !v.pass)) {
      [s, c, v, worker] = [again, checked, verdict, out.worker];
    }
  }
  return { worker, scouted: s, checked: c, verdict: v, tries, ms: Date.now() - t0 };
}

/**
 * A checked local answer as shown: the short answer, then in one line the lines it rests on (each place once); any
 * further points go under "More". `words` is the shown answer's length, `trimmed` whether the hub had to cut it.
 */
export function present(s: Scouted, c: Checked): { text: string; more?: string; trimmed: boolean; words: number } {
  const b = brief(s);
  const where = [...new Set(c.claims.map((k) => `${k.file}:${k.start === k.end ? k.start : `${k.start}–${k.end}`}`))];
  const listed = where.slice(0, SOURCES_SHOWN).map((w) => `\`${w}\``).join(', ');
  const rest = where.length > SOURCES_SHOWN ? ` and ${where.length - SOURCES_SHOWN} more` : '';
  const sources = where.length ? `\n\nChecked against ${listed}${rest}.` : '';
  return { text: `${b.answer}${sources}`, ...(b.more.length ? { more: b.more.map((m) => `- ${m}`).join('\n') } : {}), trimmed: b.trimmed, words: words(b.answer) };
}

/** For Claude, when a question goes on to it: what the local model verified, what didn't hold, and its draft. */
export function evidence(o: ScoutOutcome): string {
  const who = o.worker ?? 'a local model';
  const parts = [`[duet] A local model (${who}) looked into this first; its answer didn't count because ${o.verdict.pass ? 'you were asked directly' : o.verdict.why}. Use what it verified and check the rest yourself. The user hasn't seen its draft, so answer them directly, without mentioning it.`];
  if (o.checked?.claims.length) parts.push(`Verified in the files:\n${o.checked.claims.map((k) => `- ${k.text || 'quoted'} (${k.file}:${k.start}-${k.end}): "${norm(k.quote).slice(0, 160)}"`).join('\n')}`);
  if (o.checked?.failed.length) parts.push(`Didn't check out:\n${o.checked.failed.map((f) => `- ${f.claim.text || f.claim.quote.slice(0, 80)} (${f.claim.file}:${f.claim.start}): ${f.why}`).join('\n')}`);
  if (o.scouted?.unknowns.length) parts.push(`It couldn't settle:\n${o.scouted.unknowns.map((u) => `- ${u}`).join('\n')}`);
  if (o.scouted?.answer) parts.push(`Its draft (unverified):\n${draftText(o.scouted).slice(0, 1500)}`);
  return parts.join('\n\n');
}
