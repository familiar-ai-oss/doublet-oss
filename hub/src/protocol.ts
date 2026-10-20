// Wire protocol between duet-hub and its clients (cli.ts now, the Swift app later).
// Every hub event is sequenced; a client reconnects with hello{lastSeq} and gets exactly the events after it.

export const PROTOCOL_VERSION = 1;

export type EffortLevel = 'low' | 'medium' | 'high' | 'xhigh' | 'max';
export const EFFORT_LEVELS: readonly EffortLevel[] = ['low', 'medium', 'high', 'xhigh', 'max'];

// How Claude asks before it acts (the Agent SDK's permission modes, less dontAsk): ask about each call ("default"),
// accept edits, auto (a classifier decides, and asks when it can't), plan (Claude plans; nothing runs) or bypass
// permissions (nothing asks).
export type PermissionMode = 'default' | 'acceptEdits' | 'auto' | 'plan' | 'bypassPermissions';
export const PERMISSION_MODES: readonly PermissionMode[] = ['default', 'acceptEdits', 'auto', 'plan', 'bypassPermissions'];

export type ToolCall = { name: string; input: unknown };
export type ToolUse = { id: string; name: string; input: unknown };

// The conversation (a Claude session) an event belongs to. The event log stamps it on every event but the hub-wide
// ones (UNTAGGED_EVENTS); an emitter that knows better than "the lead's current session" (a worker task finishing
// after a Clear) sets it itself.
type Tagged = { conversationId?: string };

export const UNTAGGED_EVENTS: ReadonlySet<string> = new Set(['fleet', 'model_catalog', 'dialogue_state', 'lead_info', 'effort']);

// Sequenced events (hub -> clients). Persisted to the event log and replayed.
export type EventBody = Tagged & (
  | { type: 'session'; state: 'starting' | 'ready' | 'stopped'; sessionId?: string; model?: string; account?: { subscription?: string; apiKeySource?: string }; reason?: string }
  // notes: the prompt is handwritten notes (iPad Pencil), tagged to what they were written on.
  // voice: spoken (Talk mode), and Claude's reply is read aloud.
  | { type: 'user'; turn: number; text: string; by: string; notes?: Notes; voice?: boolean }
  // A prompt the hub holds while Claude works: shown as waiting until Claude takes it (its `user` event follows at once),
  // or dropped (the hub restarted before Claude took it), with why.
  | { type: 'queued'; id: string; state: 'waiting' | 'taken' | 'dropped'; text?: string; by?: string; voice?: boolean; reason?: string }
  // A turn Claude Code starts by itself (to read a background subagent's report) has no `user` event before it.
  | { type: 'turn_start'; turn: number }
  | { type: 'text_delta'; turn: number; text: string }
  | { type: 'assistant'; turn: number; text: string; toolUses: ToolUse[] }
  // tail: the end of a long result (past the preview's 2,000 characters), where a run's verdict usually is.
  | { type: 'tool_result'; turn: number; toolUseId: string; isError: boolean; preview: string; tail?: string }
  // toolUseId pairs the card with its tool call; defaultToNo means no one-tap approve (swipe, shortcut, menu bar).
  // plan: Claude asks to leave plan mode (ExitPlanMode) with this plan, in Markdown. Approving starts the work, in the
  // mode from before plan mode; rejecting, with a note, keeps Claude planning.
  | { type: 'approval_request'; id: string; turn: number; tool: string; input: Record<string, unknown>; title?: string; description?: string; toolUseId?: string; displayName?: string; defaultToNo?: boolean; plan?: string }
  // updatedInput is what actually ran, when someone edited the call.
  | { type: 'approval_resolved'; id: string; decision: 'allow' | 'deny'; edited: boolean; by: string; message?: string; updatedInput?: Record<string, unknown> }
  | { type: 'turn_end'; turn: number; subtype: string; isError: boolean; interrupted: boolean; durationMs?: number; numTurns?: number }
  | { type: 'effort'; level: EffortLevel | null; by: string; appliesFrom: 'next_turn' }
  | { type: 'interrupt'; turn: number; by: string }
  | { type: 'error'; message: string }
  // Fleet (Phase 2)
  | { type: 'fleet'; workers: WorkerView[] }
  // files: what an Apple worker reads (its text goes to the device). profile: a local worker's task profile.
  // Claude's subagents: `label`, the few words Claude gave it (its Agent call's description); `background`, it runs in
  // the background (its call returned at once, and it ends with its own report later); `parentId` and `depth`, for one
  // that another subagent started: that one's task, and how deep it is (2 for a subagent's own subagent).
  | { type: 'task'; taskId: string; worker: string; state: TaskState; prompt?: string; by?: string; effort?: string; cwd?: string; files?: string[]; profile?: string; queuePosition?: number; result?: string; evidence?: string; error?: string; stats?: TaskStats; stopped?: 'turn_limit' | 'context'; label?: string; background?: boolean; parentId?: string; depth?: number }
  // toolUses carries each call with long strings clipped, so clients can summarize it; tools is the older one-line form.
  | { type: 'task_progress'; taskId: string; worker: string; text?: string; tools?: string[]; toolUses?: ToolCall[]; toolResult?: string }
  | { type: 'worker_request'; taskId?: string; worker: string; status: number; ttfbMs: number; totalMs: number; inputTokens: number; outputTokens: number; tokPerS: number | null; sent: Record<string, unknown> }
  | { type: 'swap_request'; id: string; taskId: string; worker: string; model: string; device: string; evicts: string[] }
  | { type: 'swap_resolved'; id: string; decision: 'allow' | 'deny'; by: string }
  // Dialogue (Phase 3): every message between the lead (or you) and a worker is a typed card in a task thread.
  | { type: 'dialogue'; id: string; kind: DialogueKind; taskId: string; from: string; to: string; text: string; replyTo?: string; options?: string[]; refused?: string }
  | { type: 'dialogue_state'; used: number; limit: number; paused: boolean; openQuestions: number; leadInbox: number }
  // Claude's plan for the conversation, the whole list each time: who does each step, and the task that does it.
  | { type: 'plan'; steps: PlanStep[]; by: string }
  | { type: 'notice'; text: string }
  // Phase 5: lead model/effort choices, context resets, and the worker model catalog (with swap warnings).
  // `cwd`: the folder Claude works in (and new shells and worker tasks start in); `recentCwds`, the last few.
  // `conversationId`: the live conversation (the lead's session). `permissionMode`: how Claude asks before it acts; sent
  // again whenever it changes, from a device or by Claude (leaving plan mode).
  | { type: 'lead_info'; model: string; effort: EffortLevel | null; models: LeadModel[]; cwd?: string; recentCwds?: string[]; conversationId?: string; permissionMode?: PermissionMode }
  // `resumed`: an earlier conversation (`sessionId`) continues as the live one.
  | { type: 'context'; action: 'cleared' | 'compacted' | 'folder' | 'resumed'; by: string; preTokens?: number; postTokens?: number; path?: string; sessionId?: string }
  // A session started outside Duet, continued here: the conversation it came from (`forked` while that still runs), and
  // its last messages, shown at the start of this conversation.
  | { type: 'conversation_import'; from: OutsideSession; forked: boolean; messages: OutsideMessage[] }
  | { type: 'model_catalog'; models: CatalogModel[] }
  // Diagrams: Claude shows a Mermaid chart or a self-contained HTML page. An update reuses the id with a higher version.
  | { type: 'diagram'; id: string; version: number; title: string; kind: DiagramKind; source: string; caption?: string; by: string; explains?: CodeRef[]; links?: Record<string, string> }
  // Notes that arrived while Claude was working: they reach Claude after its next tool call, or as the next prompt.
  | { type: 'notes'; turn: number; by: string; notes: Notes }
  // A kept note: new, taken by Claude (its turn), answered (Claude's answer and diagrams), resolved, or deleted.
  | { type: 'annotation'; annotation: Annotation }
  // Side chats: a quick question beside the conversation, answered by Claude in a copy of it (so it knows what's been
  // said and done) that never touches the conversation itself. Read-only. `forked`: how much of the conversation the
  // copy has (all of it; up to Claude's last reply, when it was mid-turn; or none). `activity`: what it's doing now.
  // `annotationId`: the note it continues (a note's thread); `deleted`: gone, with that note.
  | { type: 'side_chat'; chatId: string; state: SideState; title: string; model: string; by: string; about?: SideAbout; forked?: 'whole' | 'before_turn' | 'none'; activity?: string; error?: string; sessionId?: string; annotationId?: string; deleted?: boolean }
  // An answer's model, and for a local one its citations; escalated: why it went on to Claude.
  // `fromNote`: the note's own question and answer, which start its thread.
  | { type: 'side_message'; chatId: string; id: string; role: 'user' | 'assistant'; text: string; by?: string; image?: boolean; model?: string; local?: boolean; checked?: Checked; ms?: number; escalated?: string; more?: string; fromNote?: boolean }
  | { type: 'side_delta'; chatId: string; text: string }
);

export type SideState = 'answering' | 'idle' | 'failed';
// What a side chat is about: a file (at some lines), or anything else by a label and its text (a reply, a task, a step).
export type SideAbout = { kind: 'file'; path: string; start?: number; end?: number } | { kind: 'text'; label: string; text?: string };

export type DiagramKind = 'mermaid' | 'html';

// Handwritten notes. Each one is a group of Pencil strokes (its id), read by PKStrokeRecognizer, whose shape and ink
// color give an intent, tagged to the diagram elements or diff lines it was drawn on.
export type NoteSurface =
  | { kind: 'diagram'; diagramId: string; version?: number; title?: string }
  | { kind: 'diff'; taskId: string; worker?: string }
  | { kind: 'file'; path: string }
  // A conversation's plan: a note's elements are the steps it's on (a step's id, with its text as the label).
  | { kind: 'plan'; conversationId: string };
export type InkIntent = 'comment' | 'change' | 'question' | 'remove' | 'approve' | 'connect' | 'group' | 'emphasize';
export type InkElement = { id: string; label?: string };
export type InkLines = { file: string; start: number; end: number; code?: string };
export type InkNote = {
  id: string;
  intent: InkIntent;
  text?: string;
  // Diagram elements, or diff line ranges. For connect, the first is where the arrow starts and the second where it ends.
  elements?: InkElement[];
  lines?: InkLines[];
  color?: string;
  /** Typed rather than written: there's no ink. */
  typed?: boolean;
};
export type Notes = { surface: NoteSurface; items: InkNote[]; hasImage?: boolean };
export type Annotation = InkNote & {
  surface: NoteSurface;
  by: string;
  ts: number;
  // The turn Claude took it in; its text and diagrams from that turn are the answer.
  turn?: number;
  status: 'open' | 'answered' | 'resolved';
  answer?: string;
  diagrams?: string[];
  // A picture of the handwriting is kept (ask with annotation_ink).
  ink?: boolean;
  deleted?: boolean;
  // Who answered and how: a local model whose citations checked out, or Claude (routing.ts).
  answeredBy?: string;
  route?: 'local' | 'claude';
  /** A local answer's citations: how many checked out, and how many didn't. */
  checked?: Checked;
  /** From the note to its answer. */
  ms?: number;
  /** Why the question went on to Claude. */
  escalated?: string;
  /** Who is answering it now. */
  answering?: string;
  /** A local model's answer that Claude was then asked about: kept beside Claude's. */
  localAnswer?: string;
  /** A local answer's further points (Markdown), shown under "More". */
  more?: string;
  /** The side chat that replies to the note continue in: the note's thread. */
  chatId?: string;
};
export type Checked = { claims: number; failed: number };
// Code a diagram explains, or that one of its elements stands for.
export type CodeRef = { path: string; start?: number; end?: number };

export type LeadModel = { value: string; displayName: string; effortLevels: EffortLevel[]; resolved?: string };

// The file viewer. `git`: M changed, A added, ? new (untracked), D deleted, R renamed, U conflicted; on a folder, • means
// changes inside.
export type FsEntry = { name: string; kind: 'dir' | 'file'; size: number; mtime: number; link?: boolean; git?: string };
export type FsListing = { path: string; parent: string | null; entries: FsEntry[]; truncated: boolean; repo?: { root: string; branch: string } };
// `changed`: lines added or changed since the last commit; `removedAfter`: lines after which lines were removed.
export type FsFile = { path: string; size: number; mtime: number; binary: boolean; truncated: boolean; text?: string; git?: string; changed?: number[]; removedAfter?: number[] };
// A local model a worker can switch to. `evicts` lists loaded models that loading it would push out.
export type CatalogModel = { id: string; device: string; loaded: boolean; evicts: string[]; effortLevels: string[]; verified: boolean };

// ESCALATE: Claude passed a worker's QUESTION (replyTo) on to you; you answer the question itself.
export type DialogueKind = 'TASK' | 'STEER' | 'QUESTION' | 'ANSWER' | 'STATUS' | 'RESULT' | 'CANCEL' | 'ESCALATE';

// One step of Claude's plan. owner: "lead" (Claude itself) or a worker id; taskId: the task doing it, once handed out.
// Claude sets status; a step's task shows its own state (queued, running, done…) beside it.
export type PlanStatus = 'pending' | 'in_progress' | 'completed';
export type PlanStep = { id: string; text: string; owner: string; status: PlanStatus; taskId?: string; note?: string };

export type TaskState = 'queued' | 'awaiting_swap' | 'running' | 'done' | 'failed' | 'cancelled';
export type TaskStats = { requests: number; inputTokens: number; outputTokens: number; genTokPerS: number | null; wallMs: number; firstTokenMs: number | null };

export type WorkerView = {
  id: string;
  label: string;
  // openai: an OpenAI-compatible endpoint (vLLM, Ollama's /v1, LM Studio, llama.cpp, a hosted API).
  backend: 'llmd' | 'ollama' | 'apple' | 'claude' | 'openai';
  model: string;
  enabled: boolean;
  available: boolean; // backend reachable
  loaded: boolean; // model resident, so no swap is needed
  effort: string;
  effortLevels: string[];
  temperature?: number;
  tokPerS: number | null; // last measured generation speed
  verifiedEffort: boolean; // the effort mapping was measured on this model
  running: string | null; // task id
  queue: string[]; // task ids, in order
  // Claude's subagents: every subagent of this kind running now (several can run at once); running is the first.
  active?: string[];
  // Apple workers: the device that runs them, its model (variant, context size, capabilities), and why it's unavailable.
  device?: string;
  variant?: string;
  contextSize?: number;
  capabilities?: string[];
  unavailableReason?: string;
  // An endpoint added in Settings (its id is the endpoint's): edited there, not in the fleet file.
  fromSettings?: boolean;
};

// Settings → Agents (agents.ts): the coding agents on the hub's machine. `signIn`, when it needs signing in: how, and
// what the hub looked for (the check is a best guess from files and the environment). `problem`: it's there but
// `--version` failed (a broken install, or one that hangs), so it may not run.
export type AgentId = 'claude' | 'codex' | 'cursor' | 'gemini';
export type AgentState = 'ready' | 'needs_sign_in' | 'not_installed';
export type AgentInfo = { id: AgentId; name: string; command: string; state: AgentState; path?: string; version?: string; signIn?: string; problem?: string };
// `host`: the hub machine's name; `platform`: Node's (darwin, linux); `scannedAt`: ms since the epoch.
export type AgentScan = { host: string; platform: string; scannedAt: number; agents: AgentInfo[] };

// Settings → Agents: an OpenAI-compatible endpoint (endpoints.ts), which is a worker with the same id. Its API key never
// leaves the hub: `hasApiKey` says whether one is set.
export type EndpointView = { id: string; name: string; baseUrl: string; model: string; hasApiKey: boolean; enabled: boolean };
// Test Connection: GET {baseUrl}/models. `models`: the ids it lists (to pick from); `error`, why not, for people;
// `status`: the HTTP status, when it answered with an error.
export type EndpointTest = { ok: boolean; models: string[]; error?: string; ms: number; status?: number };

// A device's on-device model (Apple Intelligence), as it reports it.
export type DiagnosticKind = 'crash' | 'hang' | 'freeze' | 'exit' | 'cpu' | 'disk' | 'launch';
export type DiagnosticBody = {
  id: string;
  kind: DiagnosticKind;
  summary: string;
  at?: string;
  durationMs?: number;
  build?: string;
  os?: string;
  model?: string;
  context?: Record<string, unknown>;
  payload?: string;
};

export type AppleStatus = {
  available: boolean;
  reason?: string; // when unavailable: 'deviceNotEligible' | 'appleIntelligenceNotEnabled' | 'modelNotReady' | ...
  variant?: string; // which model the system gives this device: 'AFM 3 Core', 'AFM 3 Core Advanced' (apps can't choose)
  contextSize?: number;
  capabilities?: string[];
  platform: 'mac' | 'ipad' | 'iphone';
  simulator?: boolean;
};
// genMs: time spent writing (from each pass's first token), so its speed compares with the GPU workers'.
export type AppleStats = { inputTokens: number; outputTokens: number; wallMs: number; firstTokenMs?: number; parts?: number; genMs?: number };

export type HubEvent = EventBody & { seq: number; ts: number };

// Claude Code sessions started outside Duet on the hub machine (outside.ts, docs/import.md).
export type OutsideSession = {
  sessionId: string;
  name: string;
  cwd: string;
  /** The desktop app (locally or over SSH), a terminal, or a background session (claude --bg). */
  where: 'desktop' | 'terminal' | 'background';
  /** While it runs: busy or idle (a background session reports its state). Once its process has gone: ended. */
  status: string;
  live: boolean;
  startedAt?: number;
  updatedAt?: number;
  endedAt?: number;
};
/** One of its messages: what was said, and the tools Claude reached for ("Read src/a.ts"). */
export type OutsideMessage = { uuid: string; role: 'user' | 'assistant'; text: string; tools?: string[]; ts?: number };

// The user's devices (devices.ts): one per device token, whether the app is connected there now, when it was last seen
// (ms since the epoch; absent if never), and what it is (from its hello, else its name). `open`: what it last said it
// has open (open_places), for the other devices' switchers ("On iPad").
export type DeviceKind = 'mac' | 'ipad' | 'iphone';
export type DeviceInfo = { device: string; online: boolean; lastSeen?: number; kind?: DeviceKind; open?: OpenPlaces };
// A place a device has open (the app's own description, untouched) and its name; `current` indexes the one in front.
export type OpenPlace = { place: unknown; title: string };
export type OpenPlaces = { places: OpenPlace[]; current?: number; ts: number };

// Unsequenced control frames (hub -> one client).
export type ControlFrame =
  | { type: 'welcome'; protocol: number; device: string; headSeq: number; replayFrom: number; reset: boolean; devices?: DeviceInfo[] }
  // The devices again, whenever one connects or disconnects, or says what it has open. Never stored or replayed.
  | { type: 'devices'; devices: DeviceInfo[] }
  // A place another device sent here (Open on iPad): `place` is the app's own, untouched. One sent while this device
  // was away comes after its replay, so `ts` says how old it is; it comes again on each connection until the app says
  // it has it (place_seen). `write`: to write on with Apple Pencil (Write on iPad).
  | { type: 'place_sent'; id: string; from: string; to: string; place: unknown; title: string; ts: number; write?: boolean }
  | { type: 'replay_done'; headSeq: number }
  // queued: a place sent to a device that's away, waiting for it.
  // Settings: `scan` answers agents_list/agents_scan, `endpoints` endpoints_list, `endpoint` endpoint_add/update, `test`
  // endpoint_test.
  | { type: 'ack'; ref: string; ok: boolean; error?: string; taskId?: string; ptyId?: string; diff?: string; truncated?: boolean; listing?: FsListing; file?: FsFile; image?: string; chatId?: string; files?: string[]; session?: OutsideSession; messages?: OutsideMessage[]; sessionId?: string; forked?: boolean; queued?: boolean; scan?: AgentScan; endpoints?: EndpointView[]; endpoint?: EndpointView; test?: EndpointTest }
  // The endpoints again, to every device, whenever one is added, changed or removed. Never stored or replayed.
  | { type: 'endpoints'; endpoints: EndpointView[] }
  // A folder this client watches (fs_watch) changed: list it again.
  | { type: 'fs_changed'; path: string }
  | { type: 'fatal'; error: string }
  // Apple workers (Phase 6): a task for this device's on-device model, and its cancellation. `input` is the text of
  // the files the requester named (the device can't read the hub machine's files).
  | { type: 'apple_task'; taskId: string; prompt: string; input?: string; temperature?: number }
  | { type: 'apple_cancel'; taskId: string }
  // Terminals (Phase 5): unsequenced, never in the event log. Output is replayed from a per-terminal buffer on attach.
  | { type: 'pty_list'; terminals: { id: string; kind: PtyKind; title: string }[] }
  | { type: 'pty_data'; id: string; data: string }
  | { type: 'pty_exit'; id: string; code: number }
  // Sessions running outside Duet: the list (on connecting, and when it changes), and the new messages of one this
  // device follows. Unsequenced, never in the event log.
  | { type: 'outside_sessions'; sessions: OutsideSession[] }
  | { type: 'outside_messages'; sessionId: string; messages: OutsideMessage[] };

export type PtyKind = 'shell' | 'hub_logs' | 'llmd';

export type ServerFrame = HubEvent | ControlFrame;

// Client -> hub. `ref` is echoed in the ack.
export type ClientMsg =
  // kind: what this device is, for a token whose name doesn't say.
  | { type: 'hello'; protocol: number; token: string; device: string; lastSeq: number; kind?: DeviceKind }
  | { type: 'prompt'; ref?: string; text: string; boost?: boolean; voice?: boolean }
  | { type: 'approve'; ref?: string; id: string; updatedInput?: Record<string, unknown> }
  | { type: 'reject'; ref?: string; id: string; message?: string }
  | { type: 'interrupt'; ref?: string }
  | { type: 'set_effort'; ref?: string; level: EffortLevel | null }
  // Fleet (Phase 2). In Phase 3 the lead's delegate tool calls the same path.
  | { type: 'delegate'; ref?: string; worker: string; prompt: string; cwd?: string; effort?: string; files?: string[]; profile?: string }
  // Apple workers: this device's on-device model, and a task's progress and outcome.
  | ({ type: 'apple_status'; ref?: string } & AppleStatus)
  | { type: 'apple_progress'; ref?: string; taskId: string; text: string }
  | { type: 'apple_done'; ref?: string; taskId: string; ok: boolean; result?: string; error?: string; stats?: AppleStats }
  | { type: 'cancel_task'; ref?: string; taskId: string }
  | { type: 'set_worker'; ref?: string; worker: string; effort?: string; temperature?: number | null; enabled?: boolean; model?: string }
  | { type: 'approve_swap'; ref?: string; id: string }
  | { type: 'reject_swap'; ref?: string; id: string }
  // Dialogue (Phase 3): you can answer and steer workers too, and pause all handoffs.
  | { type: 'answer'; ref?: string; questionId: string; text: string }
  | { type: 'steer'; ref?: string; taskId: string; text: string }
  | { type: 'set_pause'; ref?: string; paused: boolean }
  // Phase 5: lead context and model, @all, terminals.
  | { type: 'clear'; ref?: string }
  // Continue an earlier conversation (a Claude session id from a `session` or `context` event).
  | { type: 'resume_session'; ref?: string; sessionId: string }
  | { type: 'compact'; ref?: string }
  | { type: 'set_model'; ref?: string; model: string }
  // Takes effect at once, mid-turn too; the next session (a restart, Clear, a resume) starts in it.
  | { type: 'set_permission_mode'; ref?: string; mode: PermissionMode }
  | { type: 'broadcast'; ref?: string; text: string }
  | { type: 'pty_open'; ref?: string; kind: PtyKind; cols: number; rows: number; cwd?: string }
  | { type: 'pty_attach'; ref?: string; id: string }
  | { type: 'pty_input'; ref?: string; id: string; data: string }
  | { type: 'pty_resize'; ref?: string; id: string; cols: number; rows: number }
  // The file viewer: a folder's entries (default: Claude's folder) or a file. Answered in the ack.
  | { type: 'fs_list'; ref?: string; path?: string }
  | { type: 'fs_read'; ref?: string; path: string }
  // Move Claude (and new shells and worker tasks) to another folder, keeping the conversation.
  | { type: 'set_cwd'; ref?: string; path: string }
  | { type: 'pty_close'; ref?: string; id: string }
  // Notes, diffs and the Lock Screen. The image (PNG or JPEG, base64) is what was annotated, with the ink.
  // Each item can carry its handwriting (`ink`, a small PNG, base64); the hub keeps it with the annotation.
  | { type: 'notes'; ref?: string; surface: NoteSurface; items: (InkNote & { ink?: string })[]; image?: string; imageType?: 'image/png' | 'image/jpeg' }
  // reroute: "Ask Claude" about a note a local model answered.
  | { type: 'annotation_update'; ref?: string; id: string; status?: 'open' | 'resolved'; delete?: boolean; reroute?: 'claude' }
  | { type: 'annotation_ink'; ref?: string; id: string }
  // A reply to a note: its thread (a side chat that continues the note) starts with the first one. The ack carries the
  // chat id. `image`: a picture (ink) with it.
  | { type: 'note_reply'; ref?: string; id: string; text: string; image?: string; imageType?: 'image/png' | 'image/jpeg' }
  | { type: 'task_diff'; ref?: string; taskId: string }
  | { type: 'live_activity'; ref?: string; token?: string; startToken?: string; environment: 'development' | 'production' }
  | { type: 'live_activity_end'; ref?: string }
  // Side chats: a new one (no chatId) or a follow-up; the ack carries the chat id. `image`: a picture (ink) with it.
  | { type: 'side_ask'; ref?: string; chatId?: string; text: string; about?: SideAbout; model?: string; image?: string; imageType?: 'image/png' | 'image/jpeg'; voice?: boolean }
  // "Ask Claude" about a side chat's last local answer.
  | { type: 'side_reroute'; ref?: string; chatId: string }
  | { type: 'side_stop'; ref?: string; chatId: string }
  // A better name for a side chat, from a device's on-device model; every device gets it in the side_chat event.
  | { type: 'side_title'; ref?: string; chatId: string; title: string }
  // Something that went wrong on this device (a crash, a freeze, the system's report of one), kept in the state folder
  // (diagnostics.ts). Sent until acked; a report sent twice is kept once.
  | ({ type: 'diagnostic'; ref?: string } & DiagnosticBody)
  // Sessions running outside Duet: follow one live (the ack has its recent messages; then outside_messages), stop
  // following, or continue it here (a fork while it still runs there; the ack has the conversation it continues as).
  | { type: 'outside_follow'; ref?: string; sessionId: string }
  | { type: 'outside_unfollow'; ref?: string; sessionId: string }
  | { type: 'outside_continue'; ref?: string; sessionId: string }
  // Open a place on another of the user's devices (Open on iPad): it reaches only that device, as place_sent, or waits
  // for it if it's away (the ack says queued). `place` is the app's own description, passed on untouched. `write`: it
  // opens there with the Pencil tools out (Write on iPad).
  | { type: 'send_place'; ref?: string; to: string; place: unknown; title: string; write?: boolean }
  // The app has the place_sent `id`: the hub stops keeping it for this device's next connection.
  | { type: 'place_seen'; ref?: string; id: string }
  // What this device has open now (its tabs and windows; `current` indexes the one in front), replacing what it said
  // before. The other devices get it in the device list.
  | { type: 'open_places'; ref?: string; places: OpenPlace[]; current?: number }
  // The folders this client shows (its explorer's open folders), replacing the last set: changes come as fs_changed.
  | { type: 'fs_watch'; ref?: string; paths: string[] }
  // Every file under a folder (default: Claude's), as paths relative to it, for Quick Open. Answered in the ack.
  | { type: 'fs_files'; ref?: string; path?: string }
  // Settings → Agents. agents_list: the last scan of coding agents on the hub's machine (scanning the first time);
  // agents_scan: a fresh one. Both answer with the ack's `scan`.
  | { type: 'agents_list'; ref?: string }
  | { type: 'agents_scan'; ref?: string }
  // OpenAI-compatible endpoints: list them (ack `endpoints`), add or change one (ack `endpoint`), remove one (refused
  // while it has a task). update's apiKey: a new key, null to remove it, absent to keep it. Each change also reaches
  // every device as an `endpoints` frame, and the fleet as a worker.
  | { type: 'endpoints_list'; ref?: string }
  | { type: 'endpoint_add'; ref?: string; name: string; baseUrl: string; model: string; apiKey?: string; enabled?: boolean }
  | { type: 'endpoint_update'; ref?: string; id: string; name?: string; baseUrl?: string; model?: string; apiKey?: string | null; enabled?: boolean }
  | { type: 'endpoint_remove'; ref?: string; id: string }
  // Test Connection (ack `test`): a saved endpoint by `id` (with its stored key unless `apiKey` is given, and its URL
  // unless `baseUrl` is), or one not yet saved by `baseUrl` (and `apiKey`).
  | { type: 'endpoint_test'; ref?: string; id?: string; baseUrl?: string; apiKey?: string };

export function isSequenced(f: ServerFrame): f is HubEvent {
  return typeof (f as HubEvent).seq === 'number';
}
