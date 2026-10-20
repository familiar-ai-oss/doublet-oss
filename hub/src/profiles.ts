// Task profiles for local workers: what each kind of task the lead hands out gets — its tools, how it goes about the
// work, how long it may run, and what its final report must say. The lead picks one with delegate(profile); the
// worker's model stays the worker's (a profile is the harness around it, like a Claude subagent type).
export const PROFILE_IDS = ['explore', 'research', 'implement', 'test', 'review', 'docs', 'general'] as const;
export type ProfileId = (typeof PROFILE_IDS)[number];

export type Profile = {
  id: ProfileId;
  /** When the lead should pick it (the delegate tool lists these). */
  use: string;
  tools: readonly string[];
  /** Changes no files: no Edit or Write, and Bash (when it has it) only for commands that read. */
  readOnly: boolean;
  maxTurns: number;
  /** How the worker goes about it ('' for none). */
  how: string;
  /** What its final report must contain. */
  report: string;
};

const EDITS = ['Read', 'Edit', 'Write', 'Bash', 'Glob', 'Grep'] as const;

export const PROFILES: Record<ProfileId, Profile> = {
  explore: {
    id: 'explore',
    use: 'find and read code to answer a question: where something is defined or used, how a flow works, which files a change would touch. Changes nothing.',
    tools: ['Read', 'Glob', 'Grep'],
    readOnly: true,
    maxTurns: 30,
    how: 'Search with Grep and Glob, then read what you find. Do not change any file. Stop as soon as you can answer: do not explore beyond the question.',
    report: 'the answer first, then the evidence: each place that matters as path:line, with what is there.',
  },
  research: {
    id: 'research',
    use: "read web pages for an answer: documentation, an API reference, release notes, an issue thread. Give it the URLs, or the site to look in; it can't search the web, but it reads pages on documentation and code-hosting sites and on the sites your task names. Changes nothing.",
    tools: ['WebFetch', 'Read', 'Glob', 'Grep'],
    readOnly: true,
    maxTurns: 25,
    how: "Fetch the pages in your task, and links on them that bear on the question. Apple's documentation pages render with JavaScript, so a fetch returns only their title: for developer.apple.com/documentation/<path>, fetch developer.apple.com/tutorials/data/documentation/<path>.json instead. Answer only from what the pages and files say: where they leave a gap, say so rather than filling it from memory.",
    report: 'the answer first, then each source as its URL with the passage that supports it, quoted briefly; and what the pages left unanswered.',
  },
  implement: {
    id: 'implement',
    use: 'make a specified code change: a fix, a small feature, a refactor, a mechanical edit across files.',
    tools: EDITS,
    readOnly: false,
    maxTurns: 60,
    how: "Read the code you will change first and match its style. Make only the change asked, in the files it names when it names them. Run the project's build or the relevant tests when it has them, and never change a test just to make it pass. Do not commit.",
    report: 'what you changed and why, file by file; the checks you ran and their outcome (or which check you skipped, and why); anything you were unsure of or left undone.',
  },
  test: {
    id: 'test',
    use: 'write or update tests for specified code, and run them.',
    tools: EDITS,
    readOnly: false,
    maxTurns: 50,
    how: "Follow the project's test style and runner. Test behaviour, not implementation details. Run the tests you wrote. Do not change the code under test unless the task says to: if a test fails because of a bug, report the bug rather than hiding it.",
    report: 'the tests you added or changed, the command you ran, and how many passed and failed, with the failure messages.',
  },
  review: {
    id: 'review',
    use: 'review code or a change for bugs, risks and missed cases. Changes nothing.',
    tools: ['Read', 'Glob', 'Grep', 'Bash'],
    readOnly: true,
    maxTurns: 40,
    how: 'See the change with git diff and git log when it is in a git repository, and read the code around it before judging. Do not change any file. Report only problems you can point to, and say so plainly when you find none.',
    report: 'each problem as path:line, what goes wrong and when, most serious first; or that you found none.',
  },
  docs: {
    id: 'docs',
    use: 'write or update documentation: READMEs, docs pages, comments and docstrings.',
    tools: ['Read', 'Edit', 'Write', 'Glob', 'Grep'],
    readOnly: false,
    maxTurns: 40,
    how: "Read the code you are documenting and describe what it actually does. Match the existing docs' tone and format. Change only documentation and comments.",
    report: 'the files you changed and what each now covers.',
  },
  general: {
    id: 'general',
    use: 'anything else a worker can do with files and a shell in one folder.',
    tools: EDITS,
    readOnly: false,
    maxTurns: 40,
    how: '',
    report: 'what you did; when the task asks for text (an answer, a review, a poem), the text itself.',
  },
};

/** The profiles for the lead, each with its tools and when to use it. */
export function describeProfiles(): string {
  return PROFILE_IDS.map((id) => `"${id}" (${toolsOf(PROFILES[id])}): ${PROFILES[id].use}`).join(' ');
}

/** A profile's tools in a few words: "Read, Glob, Grep; no shell; read-only". */
export function toolsOf(p: Profile): string {
  return [p.tools.join(', '), ...(p.tools.includes('Bash') ? [] : ['no shell']), ...(p.readOnly ? ['read-only'] : [])].join('; ');
}

// Shell commands a read-only task may not run: anything that writes, moves or deletes files, changes git state or
// installs packages. A guard against slips, not a sandbox (the hub still measures what changed).
const WRITES = new RegExp([
  String.raw`(^|[^<>&\d])>{1,2}(?!\s*/dev/null)`,
  String.raw`\b(rm|rmdir|mv|cp|mkdir|touch|chmod|chown|ln|tee|truncate|dd|patch)\b`,
  String.raw`\b(sed|perl)\s+(-\w+\s+)*-i`,
  String.raw`\bgit\s+(add|am|apply|checkout|cherry-pick|clean|commit|merge|mv|pull|push|rebase|reset|restore|revert|rm|stash|switch|tag|worktree)\b`,
  String.raw`\b(npm|pnpm|yarn|pip3?|uv|cargo|go)\s+(install|i|ci|add|remove|uninstall|update|upgrade|get)\b`,
].join('|'));

/** Why a read-only task may not run this shell command, or null when it only reads. */
export function readOnlyRefusal(command: string): string | null {
  return WRITES.test(command)
    ? 'This task is read-only: it may not write, move or delete files, change git state or install anything. If you only meant to read, run the command without that part.'
    : null;
}
