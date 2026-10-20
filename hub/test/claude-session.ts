// A Claude Code session attached to a lead without starting Claude Code: tests feed it Claude Code's messages by hand
// (`handle`), call its hooks and canUseTool, and see what the lead sends it in `push`.
import { ClaudeSession } from '../src/agents/claude.ts';
import type { Image } from '../src/agents/adapter.ts';
import type { Lead } from '../src/lead.ts';

export function attachClaude(lead: Lead, push: (text: string, images?: Image[]) => void = () => {}): ClaudeSession {
  const session = new ClaudeSession(lead['sessionOptions'](), lead['host']);
  session['input'] = { push, close: () => {} } as never;
  lead['session'] = session;
  return session;
}
