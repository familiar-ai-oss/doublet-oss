// The lead as any coding agent: what the hub needs from one (start or resume a session, send, interrupt, approvals,
// model, effort and mode), and the events it reports back, in order. lead.ts is written against this; each agent has an
// adapter that speaks its own protocol (Claude Code: the Agent SDK, agents/claude.ts). The plan, the comparison of the
// agents and what each can't do: docs/agents/plan.md (private).
import type { EffortLevel, LeadModel, PermissionMode, ToolUse } from '../protocol.ts';
import type { AgentId } from '../protocol.ts';
import type { SubagentPort } from '../lead.ts';

export type Image = { data: string; type: 'image/png' | 'image/jpeg' };

/** What an agent can do, so the hub and the app leave out what it can't. */
export type AgentCaps = {
  /** What you write while it works reaches it in this turn (at its next tool call), rather than waiting for the next. */
  steerMidTurn: boolean;
  /** Its own subagents, shown as workers. */
  subagents: boolean;
  resume: boolean;
  fork: boolean;
  /** A model change applies to the running session. */
  liveModelSwitch: boolean;
  /** Effort changes apply from the next turn. */
  effort: boolean;
  /** Its approval requests reach the hub as they happen. */
  approvals: 'callback' | 'hook-bridge' | 'none';
  /** It takes extra context with a prompt, unseen in the transcript (Claude Code's UserPromptSubmit hook). Without it,
   *  the hub puts notices in the prompt itself. */
  promptContext: boolean;
  /** It reports the estimated cost of a turn. */
  cost: boolean;
};

/** How a request for approval is answered: allowed (with the input as it should run, maybe edited), or denied with a
 *  reason for the agent. `interrupt`: the user stopped the turn too. */
export type ApprovalAnswer =
  | { allow: true; input: Record<string, unknown> }
  | { allow: false; message: string; interrupt?: boolean };

/** What a session reports, in the order it happens. The hub's own events are built from these. */
export type AgentEvent =
  /** Something happened in a turn: if none is open, the agent started one by itself (to read a background report). */
  | { type: 'activity' }
  /** Its session is up, under this id (the hub names new ones; an agent may choose another). */
  | { type: 'ready'; sessionId: string }
  | { type: 'text'; delta: string }
  /** A whole message of its own: its words and the tools it calls. */
  | { type: 'message'; text: string; toolUses: ToolUse[] }
  /** A tool call's result, as text. */
  | { type: 'tool_end'; toolUseId: string; isError: boolean; output: string }
  | {
      type: 'approval'; tool: string; input: Record<string, unknown>; toolUseId?: string;
      title?: string; description?: string; displayName?: string; defaultToNo?: boolean;
      respond: (a: ApprovalAnswer) => void;
      /** Called if the agent withdraws the request (its call was aborted). */
      onWithdrawn: (f: () => void) => void;
    }
  /** Its permission mode changed (set from a device, or by the agent, as when Claude leaves plan mode). */
  | { type: 'mode'; mode: string }
  | { type: 'compacted'; preTokens: number; postTokens?: number }
  /** Nothing runs in the agent any more, background work included. */
  | { type: 'idle' }
  /** A turn ended. `numTurns`: the model calls in it (0: a command that ran without the model). */
  | { type: 'turn_end'; subtype: string; isError: boolean; durationMs?: number; numTurns?: number }
  /** It refuses to go on (a sign-in the hub was told not to use): the hub stops it. */
  | { type: 'fatal'; message: string }
  /** Its process ended; `error`, if it failed. */
  | { type: 'closed'; error?: string };

/** What the hub tells a session as it runs: its events, and what to add when it takes a prompt or finishes a tool. */
export type SessionHost = {
  event: (e: AgentEvent) => void;
  /** The agent takes a prompt (one sent mid-turn, too): extra context to give it with it, unseen in the transcript. */
  beforePrompt: (prompt: unknown) => string | undefined;
  /** A tool call finished: anything to tell the agent about it (that the user edited the call before it ran). */
  afterTool: (toolUseId: string) => string | undefined;
  /** The agent's own subagents, shown as workers. */
  subagents?: SubagentPort;
  log: (msg: string) => void;
};

export type SessionOptions = {
  /** The hub's id for the conversation; `resume`: the agent has it already, else it starts it under this id. */
  sessionId: string;
  resume: boolean;
  cwd: string;
  model: string;
  effort: EffortLevel;
  mode: PermissionMode;
  /** Tools that run without asking. */
  autoAllow: string[];
  disallowedTools?: string[];
};

/** One running session of the agent. */
export interface AgentSession {
  /** Why it can't start at all (not installed), or null. */
  preflight(): string | null;
  /** Starts the agent's process. Resolves once it's signed in and ready to take prompts, with what plan it's on;
   *  throws (`Refused`) if it won't run. Its events start after `run()`. */
  start(): Promise<{ subscription?: string }>;
  /** Reads its events until its process ends (then `closed`). */
  run(): Promise<void>;
  send(text: string, images?: Image[]): void;
  interrupt(): Promise<void>;
  models(): Promise<LeadModel[]>;
  setModel(model: string): Promise<void>;
  setMode(mode: PermissionMode): Promise<void>;
  setEffort(level: EffortLevel | null): Promise<void>;
  /** A turn ended: drop what the agent cut off with it (subagents it waited on). */
  endTurn(): void;
  /** Its process is gone: drop whatever ran in it. */
  release(): void;
  close(): void;
}

/** A session that won't start, and why (shown to the user as is). */
export class Refused extends Error {}

/** One coding agent: discovery and sign-in come from agents.ts for now; this opens sessions. */
export interface AgentAdapter {
  id: AgentId;
  name: string;
  caps: AgentCaps;
  open(opts: SessionOptions, host: SessionHost): AgentSession;
  /** An earlier session of the agent's: where it ran, or null if there's none. */
  lookup(sessionId: string): Promise<{ cwd?: string } | null>;
}
