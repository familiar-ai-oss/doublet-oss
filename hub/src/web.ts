// Web access for Claude, side chats and research workers. Searching is always fine: it runs at Anthropic, and only
// the query leaves this machine. Fetching a page sends a request to its site, so a page that tried to steer Claude
// could use a fetch to carry project text out in a URL. So pages on documentation and code-hosting sites open without
// asking; any other site waits for the user's approval (Claude) or is refused (side chats and workers can't ask).

/** Sites whose pages open without asking: documentation, references, code hosting and package registries. */
export const DOCS_SITES = [
  // Apple, Swift and the web platform
  'developer.apple.com', 'swift.org', 'docs.swift.org', 'forums.swift.org', 'developer.mozilla.org', 'web.dev', 'w3.org', 'whatwg.org',
  // Anthropic
  'anthropic.com', 'docs.anthropic.com', 'docs.claude.com', 'platform.claude.com', 'code.claude.com', 'support.claude.com',
  // Code hosting and Q&A
  'github.com', 'raw.githubusercontent.com', 'gist.github.com', 'docs.github.com', 'gitlab.com', 'stackoverflow.com', 'superuser.com', 'serverfault.com', 'unix.stackexchange.com',
  // Languages, runtimes and registries
  'nodejs.org', 'npmjs.com', 'typescriptlang.org', 'deno.com', 'bun.sh', 'python.org', 'pypi.org', 'rust-lang.org', 'docs.rs', 'crates.io',
  'go.dev', 'pkg.go.dev', 'kotlinlang.org', 'oracle.com', 'cppreference.com', 'learn.microsoft.com',
  // Frameworks, tools and systems
  'react.dev', 'vuejs.org', 'svelte.dev', 'nextjs.org', 'vitejs.dev', 'tailwindcss.com', 'docker.com', 'kubernetes.io', 'man7.org', 'kernel.org',
  'git-scm.com', 'sqlite.org', 'postgresql.org', 'redis.io', 'nginx.org', 'readthedocs.io', 'readthedocs.org', 'huggingface.co', 'pytorch.org',
  'wikipedia.org',
] as const;

/** Claude's and side chats' permission rules for fetching those sites (Claude Code matches a rule's site exactly). */
export function fetchRules(): string[] {
  return DOCS_SITES.flatMap((d) => [`WebFetch(domain:${d})`, `WebFetch(domain:www.${d})`]);
}

/** The sites a task names, whose pages its worker may fetch too. */
export function sitesIn(text: string): string[] {
  const out = new Set<string>();
  for (const m of text.matchAll(/https?:\/\/([a-z0-9.-]+\.[a-z]{2,})/gi)) out.add(m[1].toLowerCase());
  return [...out];
}

/** Why a worker may not fetch a URL, or null when it may: on a documentation site or one its task names, over HTTP(S), without a long query. */
export function fetchRefusal(url: string, named: string[] = []): string | null {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return `Not a URL: ${url.slice(0, 120)}`;
  }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return `Only web pages can be fetched, not ${u.protocol} URLs.`;
  // A long query string is how a page that steers a model gets text carried out.
  if (u.search.length > 200 || url.length > 1000) return 'That URL carries a long query; fetch the page without it.';
  const host = u.hostname.toLowerCase();
  const ok = [...DOCS_SITES, ...named].some((d) => host === d || host.endsWith(`.${d}`));
  return ok ? null : `${host} isn't a documentation or code-hosting site, or one your task names. Report the URL instead, and the lead can open it.`;
}
