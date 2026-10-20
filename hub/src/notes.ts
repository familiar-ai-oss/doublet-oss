// Handwritten notes become one message that says, for each note, what it means and what it was drawn on, so Claude
// (or a worker) knows exactly where to look.
import type { InkElement, InkLines, InkNote, Notes } from './protocol.ts';

/** How an answer begins, so a device can show the answer on its own (a sticky note), with the rest under More. */
export const ANSWER_FIRST = 'Start with the answer itself, in one paragraph of at most 65 words; then, after a blank line, any detail, code or citations.';

// A plan's steps go by their number; anything else by its label, with its id.
const element = (e: InkElement, plan: boolean) =>
  plan ? `step ${e.id}${e.label && e.label !== e.id ? ` "${e.label}"` : ''}` : e.label && e.label !== e.id ? `"${e.label}" (${e.id})` : `"${e.id}"`;
// The first line of the code they cover is enough to recognise it; Claude can read the rest.
const lines = (l: InkLines) => {
  const first = l.code?.split('\n')[0]?.trim().slice(0, 120);
  return `${l.file}:${l.start === l.end ? l.start : `${l.start}-${l.end}`}${first ? ` \`${first}\`` : ''}`;
};

function targets(n: InkNote, whole: string, plan: boolean): string[] {
  const t = [...(n.elements ?? []).map((e) => element(e, plan)), ...(n.lines ?? []).map(lines)];
  return t.length ? t : [whole];
}

function describe(n: InkNote, whole: string, plan: boolean): string {
  const t = targets(n, whole, plan);
  const said = n.text?.trim() ? `: "${n.text.trim()}"` : '';
  switch (n.intent) {
    case 'remove': return `Remove ${t.join(', ')}${said}`;
    case 'change': return `Change ${t.join(', ')}${said}`;
    case 'question': return `Question about ${t.join(', ')}${said}`;
    case 'approve': return `Looks right: ${t.join(', ')}${said}`;
    case 'group': return `These belong together: ${t.join(', ')}${said}`;
    case 'emphasize': return `Look at ${t.join(', ')}${said}`;
    case 'connect': return t.length >= 2 ? `${n.lines?.length ? 'Move' : 'Connect'} ${t[0]} → ${t.slice(1).join(', ')}${said}` : `Arrow at ${t[0]}${said}`;
    default: return `On ${t.join(', ')}${said}`;
  }
}

export function notesPrompt(by: string, notes: Notes): string {
  const s = notes.surface;
  const plan = s.kind === 'plan';
  const where = s.kind === 'diagram'
    ? `on the diagram "${s.title ?? s.diagramId}" (${s.diagramId}${s.version ? `, version ${s.version}` : ''})`
    : s.kind === 'diff' ? `on ${s.worker ?? 'a worker'}'s diff for task ${s.taskId}` : s.kind === 'plan' ? 'on your plan' : `on the file ${s.path}`;
  const whole = s.kind === 'diagram' ? 'the whole diagram' : s.kind === 'diff' ? 'the whole diff' : plan ? 'the whole plan' : 'the whole file';
  const picture = notes.hasImage ? ' The attached image shows the ink.' : '';
  const list = notes.items.map((n, i) => `${i + 1}. ${describe(n, whole, plan)}`).join('\n');
  // Questions about code: an answer, and a picture when it helps; both are kept with the note.
  const asks = s.kind === 'file' && notes.items.some((n) => n.intent === 'question' || n.text?.trim());
  const answer = notes.items.length === 1
    ? `Answer it about how this code works. ${ANSWER_FIRST} Don't repeat the question: the note already shows it. Keep the rest short too, at most three brief points, since it's read on the note.`
    : "Answer each one about how this code works, numbered like the notes. Start each with its answer, in one paragraph of at most 65 words, without repeating its question (the notes show them); then at most three brief points.";
  const how = asks
    ? `\n${answer} Where a picture makes it clearer (a flow, a call chain, how data moves, states), also draw one with diagram(), passing \`explains\` with these lines and \`links\` from its nodes to the code they stand for.`
    : '';
  // Notes on the plan redirect the work: the plan changes first, and what Claude does next follows it.
  const redirect = plan && notes.items.some((n) => n.intent !== 'question')
    ? '\nThey redirect the work on those steps: change your plan to follow them (the plan tool), carry on from there, and say briefly what you changed.'
    : '';
  // Typed notes are no less the user's, but they aren't handwriting.
  const kind = notes.items.every((n) => n.typed) ? 'Typed notes' : notes.items.some((n) => n.typed) ? 'Notes' : 'Handwritten notes';
  return `[${kind} from ${by} ${where}.${picture}]\n${list}${how}${redirect}`;
}
