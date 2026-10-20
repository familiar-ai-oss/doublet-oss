// Which model answers a question asked on a note or in a side chat. A question about the code itself (find it,
// explain it, trace it) goes to a local model first; one that needs judgment (design, debugging), outside knowledge
// or the conversation goes to Claude. The local answer then has to prove itself (see scout.ts): when it can't, the
// question goes to Claude with what the local model found. Phase 1 decides by rules; the log (routelog.ts) is what a
// learned router will be calibrated on.
import type { TaskSize } from './fleet.ts';

export type QuestionClass = 'locate' | 'explain' | 'trace' | 'debug' | 'design' | 'plan' | 'external' | 'meta';
export type Surface = 'note' | 'side';

export type Route = {
  to: 'local' | 'claude';
  cls: QuestionClass;
  /** Why, in words: shown on the answer and logged. */
  why: string;
  /** For a local answer: the worker size it needs (finding something is a small model's job). */
  size: TaskSize;
};

/** The classes a local model answers first: questions about what's in the code, which its quotes can prove. */
export const LOCAL_CLASSES: readonly QuestionClass[] = ['locate', 'explain', 'trace'];

// In order: the first class whose words a question has is its class.
const RULES: [QuestionClass, RegExp][] = [
  ['meta', /\b(you said|you (just )?(did|wrote|meant)|your (answer|reply|last)|this conversation|earlier (you|we)|we (decided|agreed|discussed)|what did you|why did you)\b/i],
  ['plan', /\b(the plan|your plan|plan step|next steps?|what should (we|i) do next|change the plan|add a step)\b/i],
  ['external', /(https?:\/\/|\b(latest|newest|current) (version|release)\b|\brelease notes\b|\bchangelog\b|\b(docs?|documentation) (for|of|on)\b|\bbest practices?\b|\bon the (web|internet)\b|\b(github|stack ?overflow|npm|pypi) (says|issue)\b)/i],
  ['design', /\b(should (we|i)|is it (better|worth)|better (way|approach)|how would you|redesign|refactor(ing)?|architect(ure)?|trade-?offs?|pros and cons|recommend(ation)?|alternatives? to)\b/i],
  ['debug', /\b(why (does|do|is|did|would) [^?]*\b(fail|crash|break|throw|hang|wrong|error)|doesn'?t work|not working|is (this|it|that) a bug|bug in|fix (this|the|that) (bug|error|crash))/i],
  ['locate', /\b(where (is|are|does|do|did)|where'?s|which (file|function|class|module)|find (the|where|all)|defined|definition of|who calls|what calls|callers? of|used (in|by|anywhere)|usages? of|references? to)\b/i],
  ['trace', /\b(trace|walk me through|step by step|what happens (when|if|after)|call chain|end to end|flow of|how does .* (get|flow|reach|end up))\b/i],
];

export function classify(text: string): QuestionClass {
  for (const [cls, re] of RULES) if (re.test(text)) return cls;
  return 'explain';
}

const WHY: Record<QuestionClass, string> = {
  locate: 'finding something in the code',
  explain: 'explaining code',
  trace: 'tracing how the code runs',
  debug: 'a debugging question, which needs judgment',
  design: 'a design question, which needs judgment',
  plan: "a question about Claude's plan",
  external: 'it needs knowledge from outside the code',
  meta: 'it is about the conversation',
};

/**
 * Where a question goes. `forced`: the user's own choice ("Ask Claude", or a side chat's model picked by hand).
 * `localFree`: whether a local worker that takes a question this size could start now; a side chat is interactive, so
 * it doesn't wait behind a running task (a note does).
 * `picture`: the question comes with a picture (a local model can't see it).
 */
export function route(text: string, surface: Surface, opts: { forced?: 'local' | 'claude'; localFree: (size: TaskSize) => boolean; picture?: boolean }): Route {
  const cls = classify(text);
  const size: TaskSize = cls === 'locate' ? 'small' : 'large';
  if (opts.forced) return { to: opts.forced, cls, size, why: opts.forced === 'claude' ? 'you asked Claude' : 'you asked for a local model' };
  if (!text.trim()) return { to: 'claude', cls, size, why: 'the question is only handwriting, which Claude reads from the picture' };
  if (opts.picture) return { to: 'claude', cls, size, why: 'it comes with a picture' };
  if (!LOCAL_CLASSES.includes(cls)) return { to: 'claude', cls, size, why: WHY[cls] };
  if (surface === 'side' && !opts.localFree(size)) return { to: 'claude', cls, size, why: 'the local models are busy' };
  return { to: 'local', cls, size, why: WHY[cls] };
}
