import Foundation

// Swift side of hub/src/protocol.ts. Keep the two in step; the fixture tests decode real hub output and
// fail if a field is dropped or a type is unknown.

public let protocolVersion = 1

public enum EffortLevel: String, Codable, Sendable, CaseIterable {
    case low, medium, high, xhigh, max
}

public struct ToolUse: Codable, Sendable, Equatable { public let id: String; public let name: String; public let input: JSONValue }

public struct AccountSummary: Codable, Sendable, Equatable { public let subscription: String?; public let apiKeySource: String? }

public struct SessionEvent: Codable, Sendable, Equatable { public let state: String; public let sessionId: String?; public let model: String?; public let account: AccountSummary?; public let reason: String? }
public struct UserEvent: Codable, Sendable, Equatable {
    public let turn: Int; public let text: String; public let by: String
    /// Set when the prompt is handwritten notes (iPad Pencil), tagged to what they were drawn on.
    public var notes: Notes? = nil
    /// Spoken in Talk mode (Claude's reply is read aloud).
    public var voice: Bool? = nil
}

// MARK: diagrams and handwritten notes

public enum DiagramKind: String, Codable, Sendable { case mermaid, html }

/// A diagram Claude showed. A revision reuses the id with a higher version.
public struct DiagramEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String; public let version: Int; public let title: String; public let kind: DiagramKind; public let source: String
    public let caption: String?; public let by: String
    /// The code it explains, and what each element stands for in it (element id → "path:line" or "path:start-end").
    public var explains: [CodeRef]? = nil
    public var links: [String: String]? = nil
    public init(id: String, version: Int, title: String, kind: DiagramKind, source: String, caption: String? = nil, by: String = "lead",
                explains: [CodeRef]? = nil, links: [String: String]? = nil) {
        self.id = id; self.version = version; self.title = title; self.kind = kind; self.source = source; self.caption = caption; self.by = by
        self.explains = explains; self.links = links
    }
}

/// Lines of a file on the hub machine.
public struct CodeRef: Codable, Sendable, Equatable, Hashable {
    public let path: String; public let start: Int?; public let end: Int?
    public init(path: String, start: Int? = nil, end: Int? = nil) { self.path = path; self.start = start; self.end = end }
    /// "path:12" or "path:12-20".
    public init?(link: String) {
        guard let colon = link.lastIndex(of: ":"), colon > link.startIndex else { return nil }
        let range = link[link.index(after: colon)...].split(separator: "-").compactMap { Int($0) }
        guard let first = range.first else { return nil }
        self.init(path: String(link[..<colon]), start: first, end: range.count > 1 ? range[1] : first)
    }
}

/// A kept note: what it says and was written on, the turn Claude took it in, and Claude's answer and diagrams.
public struct Annotation: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String; public let intent: InkIntent; public let text: String?
    public let elements: [InkElement]?; public let lines: [InkLines]?; public let color: String?
    public let surface: NoteSurface; public let by: String; public let ts: Double
    public let turn: Int?; public let status: String; public let answer: String?; public let diagrams: [String]?
    public let ink: Bool?; public let deleted: Bool?
    /// Who answered and how: a local model whose citations checked out, or Claude. `escalated`: why it went on to
    /// Claude; `answering`: who's answering it now; `localAnswer`: a local answer Claude was then asked about;
    /// `more`: a local answer's further points (Markdown), shown under "More".
    public var answeredBy: String? = nil
    public var route: String? = nil
    public var checked: Citations? = nil
    public var ms: Double? = nil
    public var escalated: String? = nil
    public var answering: String? = nil
    public var localAnswer: String? = nil
    public var more: String? = nil
    /// The note's thread: the side chat its replies continue in, once there's a reply.
    public var chatId: String? = nil
    public var date: Date { Date(timeIntervalSince1970: ts / 1000) }
    /// Answered by a local model, its citations checked against the code.
    public var answeredLocally: Bool { answered && route == "local" }
    public var answered: Bool { status == "answered" }
    public var resolved: Bool { status == "resolved" }
    /// The note as written, for showing with the same words and icons as a draft.
    public var note: InkNote { InkNote(id: id, intent: intent, text: text, elements: elements, lines: lines, color: color) }
}
public struct AnnotationEvent: Codable, Sendable, Equatable { public let annotation: Annotation }
/// A local answer's citations: how many checked out against the files, and how many didn't.
public struct Citations: Codable, Sendable, Equatable, Hashable { public let claims: Int; public let failed: Int }

/// What notes were written on: a diagram, or a task's diff.
public enum NoteSurface: Codable, Sendable, Equatable, Hashable {
    case diagram(diagramId: String, version: Int?, title: String?)
    case diff(taskId: String, worker: String?)
    /// A file on the hub machine, by its path.
    case file(path: String)
    /// A conversation's plan. A note's elements are the steps it's on: `InkElement(id: step.id, label: step.text)`.
    /// A question is answered in its thread; anything else redirects Claude on those steps (the live conversation's
    /// plan only: the hub refuses work notes on an earlier one).
    case plan(conversationId: String)

    private enum K: String, CodingKey { case kind, diagramId, version, title, taskId, worker, path, conversationId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "diff": self = .diff(taskId: try c.decode(String.self, forKey: .taskId), worker: try c.decodeIfPresent(String.self, forKey: .worker))
        case "file": self = .file(path: try c.decode(String.self, forKey: .path))
        case "plan": self = .plan(conversationId: try c.decode(String.self, forKey: .conversationId))
        default: self = .diagram(diagramId: try c.decode(String.self, forKey: .diagramId), version: try c.decodeIfPresent(Int.self, forKey: .version), title: try c.decodeIfPresent(String.self, forKey: .title))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .diagram(let id, let version, let title):
            try c.encode("diagram", forKey: .kind); try c.encode(id, forKey: .diagramId)
            try c.encodeIfPresent(version, forKey: .version); try c.encodeIfPresent(title, forKey: .title)
        case .diff(let taskId, let worker):
            try c.encode("diff", forKey: .kind); try c.encode(taskId, forKey: .taskId); try c.encodeIfPresent(worker, forKey: .worker)
        case .file(let path):
            try c.encode("file", forKey: .kind); try c.encode(path, forKey: .path)
        case .plan(let conversationId):
            try c.encode("plan", forKey: .kind); try c.encode(conversationId, forKey: .conversationId)
        }
    }
}

/// What a note means, from the shape of its ink and its color.
public enum InkIntent: String, Codable, Sendable, CaseIterable { case comment, change, question, remove, approve, connect, group, emphasize }
public struct InkElement: Codable, Sendable, Equatable, Hashable { public let id: String; public let label: String?
    public init(id: String, label: String?) { self.id = id; self.label = label } }
public struct InkLines: Codable, Sendable, Equatable, Hashable { public let file: String; public let start: Int; public let end: Int; public let code: String?
    public init(file: String, start: Int, end: Int, code: String?) { self.file = file; self.start = start; self.end = end; self.code = code } }
/// One handwritten note: a group of Pencil strokes (its id), what PKStrokeRecognizer read, its intent, and the
/// diagram elements or diff lines it's tagged to (for connect: from, then to).
public struct InkNote: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String; public var intent: InkIntent; public var text: String?
    public var elements: [InkElement]?; public var lines: [InkLines]?; public var color: String?
    /// Sent only: the handwriting as a small PNG (base64), kept by the hub with the annotation.
    public var ink: String? = nil
    /// Typed rather than handwritten: there's no ink.
    public var typed: Bool? = nil
    public init(id: String, intent: InkIntent, text: String? = nil, elements: [InkElement]? = nil, lines: [InkLines]? = nil, color: String? = nil) {
        self.id = id; self.intent = intent; self.text = text; self.elements = elements; self.lines = lines; self.color = color
    }
}
public struct Notes: Codable, Sendable, Equatable, Hashable {
    public let surface: NoteSurface; public let items: [InkNote]; public let hasImage: Bool?
    public init(surface: NoteSurface, items: [InkNote], hasImage: Bool? = nil) { self.surface = surface; self.items = items; self.hasImage = hasImage }
}
/// Notes that arrived while Claude was working (they reach it after its next tool call).
public struct NotesEvent: Codable, Sendable, Equatable { public let turn: Int; public let by: String; public let notes: Notes }
public struct TurnStartEvent: Codable, Sendable, Equatable { public let turn: Int }
public struct TextDeltaEvent: Codable, Sendable, Equatable { public let turn: Int; public let text: String }
public struct AssistantEvent: Codable, Sendable, Equatable { public let turn: Int; public let text: String; public let toolUses: [ToolUse] }
public struct ToolResultEvent: Codable, Sendable, Equatable {
    public let turn: Int; public let toolUseId: String; public let isError: Bool; public let preview: String
    /// The end of a long result (past the preview), where a run's verdict usually is.
    public var tail: String? = nil
}
public struct ApprovalRequestEvent: Codable, Sendable, Equatable {
    public let id: String; public let turn: Int; public let tool: String; public let input: [String: JSONValue]; public let title: String?; public let description: String?
    // Added after Phase 5's first build; older events don't have them (vars, so the memberwise init defaults them).
    public var toolUseId: String? = nil; public var displayName: String? = nil; public var defaultToNo: Bool? = nil
    /// Claude asks to leave plan mode (ExitPlanMode) with this plan, in Markdown. Approving starts the work, in the
    /// mode from before plan mode; rejecting with a note keeps Claude planning. An edited plan goes back as
    /// `approve(id:updatedInput:)` with the input's `plan` replaced.
    public var plan: String? = nil
    /// Claude Code marked this ask as one a stray tap mustn't approve: no swipe, shortcut or "approve next".
    public var needsCare: Bool { defaultToNo == true }
}
public struct ApprovalResolvedEvent: Codable, Sendable, Equatable {
    public let id: String; public let decision: String; public let edited: Bool; public let by: String; public let message: String?
    /// What actually ran, when someone edited the call.
    public var updatedInput: [String: JSONValue]? = nil
}
public struct TurnEndEvent: Codable, Sendable, Equatable { public let turn: Int; public let subtype: String; public let isError: Bool; public let interrupted: Bool; public let durationMs: Double?; public let numTurns: Int? }
public struct EffortEvent: Codable, Sendable, Equatable { public let level: EffortLevel?; public let by: String; public let appliesFrom: String }
public struct InterruptEvent: Codable, Sendable, Equatable { public let turn: Int; public let by: String }
public struct ErrorEvent: Codable, Sendable, Equatable { public let message: String }

public struct WorkerView: Codable, Sendable, Equatable, Identifiable {
    public let id: String; public let label: String; public let backend: String; public let model: String
    public let enabled: Bool; public let available: Bool; public let loaded: Bool
    public let effort: String; public let effortLevels: [String]; public let temperature: Double?
    // Added in Phase 5; older events in a hub's log don't have them.
    public let tokPerS: Double?; public let verifiedEffort: Bool?
    public let running: String?; public let queue: [String]
    /// Apple workers (Phase 6): the device that runs it, its model (variant, context size, capabilities), why it's unavailable.
    public var device: String? = nil
    public var variant: String? = nil
    public var contextSize: Int? = nil
    public var capabilities: [String]? = nil
    public var unavailableReason: String? = nil
    /// Claude's subagents: every one of this kind running now (several can run at once).
    public var active: [String]? = nil
    /// An endpoint added in Settings (its id is the endpoint's): edited there, not in the hub's fleet file.
    public var fromSettings: Bool? = nil
    public var isApple: Bool { backend == "apple" }
    /// An OpenAI-compatible endpoint (vLLM, Ollama's /v1, LM Studio, llama.cpp, a hosted API).
    public var isOpenAI: Bool { backend == "openai" }
    /// One kind of Claude's own subagents (its Agent tool): Claude starts them, inside its turns.
    public var isClaude: Bool { backend == "claude" }
}

/// A task for this device's on-device model (an Apple worker), sent by the hub.
public struct AppleTask: Codable, Sendable, Equatable {
    public let taskId: String; public let prompt: String; public let input: String?; public let temperature: Double?
    enum CancelKeys: String, CodingKey {
        case taskId
        static func decode(_ d: Decoder) throws -> String { try d.container(keyedBy: CancelKeys.self).decode(String.self, forKey: .taskId) }
    }
    public init(taskId: String, prompt: String, input: String? = nil, temperature: Double? = nil) {
        self.taskId = taskId; self.prompt = prompt; self.input = input; self.temperature = temperature
    }
}
/// This device's on-device model, as reported to the hub.
/// Something that went wrong on this device, for the hub to keep (hub/src/diagnostics.ts): a crash, a freeze, the
/// system's own report of one (MetricKit). `id` is the app's, so one sent twice is kept once.
public struct DiagnosticReport: Codable, Sendable, Equatable {
    /// "crash", "hang", "freeze", "exit", "cpu", "disk" or "launch".
    public var kind: String
    public var id: String
    /// One line: "Freeze 2.9 s on the conversation".
    public var summary: String
    /// When it happened (ISO 8601).
    public var at: String?
    public var durationMs: Double?
    public var build: String?
    public var os: String?
    public var model: String?
    /// What the app was doing: what was on screen, the last few things done.
    public var context: [String: JSONValue]?
    /// The system's report as it came (MetricKit's JSON), for its call stacks.
    public var payload: String?
    public init(kind: String, id: String, summary: String, at: String? = nil, durationMs: Double? = nil, build: String? = nil, os: String? = nil,
                model: String? = nil, context: [String: JSONValue]? = nil, payload: String? = nil) {
        self.kind = kind; self.id = id; self.summary = summary; self.at = at; self.durationMs = durationMs; self.build = build; self.os = os
        self.model = model; self.context = context; self.payload = payload
    }
}

public struct AppleStatus: Codable, Sendable, Equatable {
    public var available: Bool; public var reason: String?; public var contextSize: Int?; public var capabilities: [String]?
    public var platform: String; public var simulator: Bool?
    /// Which model the system gives this device ("AFM 3 Core", "AFM 3 Core Advanced"); apps can't choose.
    public var variant: String?
    public init(available: Bool, reason: String? = nil, contextSize: Int? = nil, capabilities: [String]? = nil, platform: String, simulator: Bool? = nil,
                variant: String? = nil) {
        self.available = available; self.reason = reason; self.contextSize = contextSize; self.capabilities = capabilities; self.platform = platform; self.simulator = simulator
        self.variant = variant
    }
}
public struct AppleStats: Codable, Sendable, Equatable {
    public var inputTokens: Int; public var outputTokens: Int; public var wallMs: Double; public var firstTokenMs: Double?; public var parts: Int?
    /// Time spent writing (from each pass's first token), for a speed comparable with the GPU workers'.
    public var genMs: Double?
    public init(inputTokens: Int, outputTokens: Int, wallMs: Double, firstTokenMs: Double? = nil, parts: Int? = nil, genMs: Double? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.wallMs = wallMs; self.firstTokenMs = firstTokenMs; self.parts = parts
        self.genMs = genMs
    }
}
public struct FleetEvent: Codable, Sendable, Equatable { public let workers: [WorkerView] }
public struct TaskStats: Codable, Sendable, Equatable { public let requests: Int; public let inputTokens: Int; public let outputTokens: Int; public let genTokPerS: Double?; public let wallMs: Double; public let firstTokenMs: Double? }
public struct TaskEvent: Codable, Sendable, Equatable {
    public let taskId: String; public let worker: String; public let state: String
    public let prompt: String?; public let by: String?; public let effort: String?; public let queuePosition: Int?
    /// The folder it works in (on its first event).
    public var cwd: String? = nil
    public let result: String?; public let evidence: String?; public let error: String?; public let stats: TaskStats?
    /// The files an Apple worker reads (on its first event).
    public var files: [String]? = nil
    /// A local worker's task profile (explore, implement, test, review, docs, general), on its first event.
    public var profile: String? = nil
    /// It ran out of turns ("turn_limit") or of room in its model's context ("context"), and is done with what it had
    /// (its result says how far it got).
    public var stopped: String? = nil
    /// Claude's subagents: the few words Claude gave it (its Agent call's description), on its first event.
    public var label: String? = nil
    /// Claude's subagents: it runs in the background (its call returned at once, and it ends later with its own report).
    public var background: Bool? = nil
    /// Claude's subagents: for one another subagent started, that one's task, and how deep it is (2 for a subagent's own
    /// subagent).
    public var parentId: String? = nil
    public var depth: Int? = nil
    /// The state as it's shown: "stopped" (out of turns) or "out_of_room" for a task that stopped early, "background"
    /// for a subagent an older hub stopped following when it went to the background, else its state.
    public var displayState: String {
        if backgroundUntracked { return "background" }
        guard state == "done", let stopped else { return state }
        return stopped == "context" ? "out_of_room" : "stopped"
    }
    /// What an older hub reported for a subagent Claude Code runs in the background: its call returns at once, so that
    /// hub ended the task as done with this in place of a report.
    public static let backgroundReport = "Running in the background; Claude gets its report when it finishes."
    /// An older hub's stand-in (in older logs): the task says done with `backgroundReport`, but it wasn't finished, and
    /// that hub never followed it.
    public var backgroundUntracked: Bool { isClaude && state == "done" && result == Self.backgroundReport }
    /// A subagent running in the background: its call returned, and it's still working. Newer hubs follow it until it
    /// really ends, done or failed with its report; an older hub's stand-in counts too (it never ended).
    public var inBackground: Bool { isClaude && ((background == true && state == "running") || backgroundUntracked) }
    /// On a device's Apple Intelligence: it reads the text it's sent and changes nothing.
    public var isApple: Bool { worker.hasPrefix("apple-") }
    /// One of Claude's own subagents: it works in Claude's folder and ends with the tool call that started it, or, in
    /// the background, later.
    public var isClaude: Bool { worker.hasPrefix("claude-") }
}
public struct TaskProgressEvent: Codable, Sendable, Equatable {
    public let taskId: String; public let worker: String; public let text: String?; public let tools: [String]?; public let toolResult: String?
    /// Each call with long strings clipped (newer hubs); `tools` is the older one-line form.
    public var toolUses: [ToolCall]? = nil
}
/// A worker's tool call, as sent in its progress.
public struct ToolCall: Codable, Sendable, Equatable { public let name: String; public let input: JSONValue }
public struct WorkerRequestEvent: Codable, Sendable, Equatable {
    public let taskId: String?; public let worker: String; public let status: Int; public let ttfbMs: Double; public let totalMs: Double
    public let inputTokens: Int; public let outputTokens: Int; public let tokPerS: Double?; public let sent: JSONValue
}
public struct SwapRequestEvent: Codable, Sendable, Equatable { public let id: String; public let taskId: String; public let worker: String; public let model: String; public let device: String; public let evicts: [String] }
public struct SwapResolvedEvent: Codable, Sendable, Equatable { public let id: String; public let decision: String; public let by: String }
public struct DialogueEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String; public let kind: String; public let taskId: String; public let from: String; public let to: String; public let text: String
    public let replyTo: String?; public let options: [String]?; public let refused: String?
}
public struct DialogueStateEvent: Codable, Sendable, Equatable { public let used: Int; public let limit: Int; public let paused: Bool; public let openQuestions: Int; public let leadInbox: Int }
/// One step of Claude's plan. `owner`: "lead" (Claude itself) or a worker id; `taskId`: the task doing it, once handed
/// out. Claude sets `status` (pending, in_progress, completed); a step's task has its own state.
public struct PlanStep: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String; public let text: String; public let owner: String; public let status: String
    public var taskId: String? = nil
    public var note: String? = nil
    public init(id: String, text: String, owner: String, status: String, taskId: String? = nil, note: String? = nil) {
        self.id = id; self.text = text; self.owner = owner; self.status = status; self.taskId = taskId; self.note = note
    }
    /// One of Claude's own steps.
    public var isClaudes: Bool { owner == "lead" }
}
/// Claude's plan for the conversation, the whole list each time.
public struct PlanEvent: Codable, Sendable, Equatable { public let steps: [PlanStep]; public let by: String }

// MARK: side chats

/// What a side chat is about: a file (at some lines), or anything else by a label and its text (a reply, a task, a step).
public enum SideAbout: Codable, Sendable, Equatable, Hashable {
    case file(path: String, start: Int? = nil, end: Int? = nil)
    case text(label: String, text: String? = nil)

    private enum K: String, CodingKey { case kind, path, start, end, label, text }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "file": self = .file(path: try c.decode(String.self, forKey: .path), start: try c.decodeIfPresent(Int.self, forKey: .start), end: try c.decodeIfPresent(Int.self, forKey: .end))
        default: self = .text(label: try c.decode(String.self, forKey: .label), text: try c.decodeIfPresent(String.self, forKey: .text))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .file(let path, let start, let end):
            try c.encode("file", forKey: .kind); try c.encode(path, forKey: .path)
            try c.encodeIfPresent(start, forKey: .start); try c.encodeIfPresent(end, forKey: .end)
        case .text(let label, let text):
            try c.encode("text", forKey: .kind); try c.encode(label, forKey: .label); try c.encodeIfPresent(text, forKey: .text)
        }
    }

    /// "fleet.ts:12-20", or the label.
    public var title: String {
        switch self {
        case .file(let path, let start, let end):
            let name = Paths.name(path)
            guard let start else { return name }
            return end.map { $0 != start ? "\(name):\(start)-\($0)" : "\(name):\(start)" } ?? "\(name):\(start)"
        case .text(let label, _): return label
        }
    }
}

/// A side chat's state: answering (with what it's doing), idle, or failed (with why). `forked`: how much of the
/// conversation its copy has: "whole", "before_turn" (up to Claude's last reply), or "none".
public struct SideChatEvent: Codable, Sendable, Equatable {
    public let chatId: String; public let state: String; public let title: String; public let model: String; public let by: String
    public var about: SideAbout? = nil; public var forked: String? = nil; public var activity: String? = nil
    public var error: String? = nil; public var sessionId: String? = nil
    /// The note it continues (a note's thread); `deleted`: gone, with that note.
    public var annotationId: String? = nil; public var deleted: Bool? = nil
}
public struct SideMessageEvent: Codable, Sendable, Equatable, Identifiable {
    public let chatId: String; public let id: String; public let role: String; public let text: String
    public var by: String? = nil; public var image: Bool? = nil
    /// An answer's model; for a local one (`local`), its citations and further points (`more`, shown under "More");
    /// `escalated`: why it went on to Claude.
    public var model: String? = nil; public var local: Bool? = nil; public var checked: Citations? = nil
    public var ms: Double? = nil; public var escalated: String? = nil; public var more: String? = nil
    /// The note's own question and answer, which start its thread.
    public var fromNote: Bool? = nil
    public var isUser: Bool { role == "user" }
}
public struct SideDeltaEvent: Codable, Sendable, Equatable { public let chatId: String; public let text: String }
/// A Claude Code session started outside Duet on the hub machine: in the desktop app, a terminal, or the background (`place`),
/// and whether it still runs (`status`: busy or idle while it does; ended once it has gone).
public struct OutsideSession: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let sessionId: String; public let name: String; public let cwd: String
    public let place: String; public let status: String; public let live: Bool
    public var startedAt: Double? = nil; public var updatedAt: Double? = nil; public var endedAt: Double? = nil
    public var id: String { sessionId }
    enum CodingKeys: String, CodingKey { case sessionId, name, cwd, place = "where", status, live, startedAt, updatedAt, endedAt }
}
/// One of its messages: what was said, and the tools Claude reached for ("Read src/a.ts").
public struct OutsideMessage: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let uuid: String; public let role: String; public let text: String
    public var tools: [String]? = nil; public var ts: Double? = nil
    public var id: String { uuid }
}
/// A session started outside Duet, continued here: where it came from, whether as a fork (it still ran there), and its
/// last messages, shown at the start of this conversation.
public struct ConversationImportEvent: Codable, Sendable, Equatable {
    public let from: OutsideSession; public let forked: Bool; public let messages: [OutsideMessage]
}
public struct NoticeEvent: Codable, Sendable, Equatable { public let text: String }
/// A prompt the hub holds while Claude works: `waiting` (with its text), then `taken` (its `user` event follows at once)
/// or `dropped` (with `reason`: the hub restarted before Claude took it).
public struct QueuedEvent: Codable, Sendable, Equatable {
    public let id: String; public let state: String; public var text: String? = nil; public var by: String? = nil
    public var voice: Bool? = nil; public var reason: String? = nil
}
public struct LeadModel: Codable, Sendable, Equatable, Identifiable {
    public let value: String; public let displayName: String; public let effortLevels: [EffortLevel]; public let resolved: String?
    public var id: String { value }
}
/// `cwd`: the folder Claude works in (and new shells and worker tasks start in); `recentCwds`: the last few;
/// `conversationId`: the live conversation (Claude's session); `permissionMode`: how Claude asks before it acts (see
/// `DuetStore.permissionMode`), sent again whenever it changes.
public struct LeadInfoEvent: Codable, Sendable, Equatable {
    public let model: String; public let effort: EffortLevel?; public let models: [LeadModel]; public var cwd: String? = nil; public var recentCwds: [String]? = nil
    public var conversationId: String? = nil
    public var permissionMode: String? = nil
}
/// Cleared, compacted, moved to another folder (`path`), or an earlier conversation resumed (`sessionId`).
public struct ContextEvent: Codable, Sendable, Equatable {
    public let action: String; public let by: String; public let preTokens: Int?; public let postTokens: Int?; public var path: String? = nil
    public var sessionId: String? = nil
}
public struct CatalogModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String; public let device: String; public let loaded: Bool; public let evicts: [String]; public let effortLevels: [String]; public let verified: Bool
}
public struct ModelCatalogEvent: Codable, Sendable, Equatable { public let models: [CatalogModel] }
public enum PtyKind: String, Codable, Sendable, CaseIterable { case shell, hub_logs, llmd }
public struct PtyInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String; public let kind: PtyKind; public let title: String
    public init(id: String, kind: PtyKind, title: String) { self.id = id; self.kind = kind; self.title = title }
}

/// A sequenced hub event. Unknown types (a newer hub) decode as `.unknown` instead of failing.
public struct HubEvent: Codable, Sendable, Equatable {
    public let seq: Int
    public let ts: Double
    /// The conversation (Claude session) it belongs to. Absent on hub-wide events, and on everything from older hubs.
    public let conversationId: String?
    public let body: Body

    public enum Body: Sendable, Equatable {
        case session(SessionEvent), user(UserEvent), turnStart(TurnStartEvent), textDelta(TextDeltaEvent)
        case assistant(AssistantEvent), toolResult(ToolResultEvent), approvalRequest(ApprovalRequestEvent)
        case approvalResolved(ApprovalResolvedEvent), turnEnd(TurnEndEvent), effort(EffortEvent), interrupt(InterruptEvent), error(ErrorEvent)
        case fleet(FleetEvent), task(TaskEvent), taskProgress(TaskProgressEvent), workerRequest(WorkerRequestEvent)
        case swapRequest(SwapRequestEvent), swapResolved(SwapResolvedEvent)
        case dialogue(DialogueEvent), dialogueState(DialogueStateEvent), plan(PlanEvent), notice(NoticeEvent)
        case leadInfo(LeadInfoEvent), context(ContextEvent), modelCatalog(ModelCatalogEvent)
        case diagram(DiagramEvent), notes(NotesEvent), annotation(AnnotationEvent)
        case sideChat(SideChatEvent), sideMessage(SideMessageEvent), sideDelta(SideDeltaEvent)
        case conversationImport(ConversationImportEvent), queued(QueuedEvent)
        case unknown(type: String)
    }

    private enum K: String, CodingKey { case seq, ts, type, conversationId }

    public init(seq: Int, ts: Double, body: Body, conversationId: String? = nil) {
        self.seq = seq; self.ts = ts; self.body = body; self.conversationId = conversationId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        seq = try c.decode(Int.self, forKey: .seq)
        ts = try c.decode(Double.self, forKey: .ts)
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId)
        let type = try c.decode(String.self, forKey: .type)
        do {
            body = try Self.decodeBody(type, from: decoder)
        } catch {
            // One malformed or newer-shaped event must never break the stream: keep its seq, skip its content.
            body = .unknown(type: "\(type) (undecodable)")
        }
    }

    private static func decodeBody(_ type: String, from decoder: Decoder) throws -> Body {
        func d<T: Decodable>(_: T.Type) throws -> T { try T(from: decoder) }
        let body: Body
        switch type {
        case "session": body = .session(try d(SessionEvent.self))
        case "user": body = .user(try d(UserEvent.self))
        case "turn_start": body = .turnStart(try d(TurnStartEvent.self))
        case "text_delta": body = .textDelta(try d(TextDeltaEvent.self))
        case "assistant": body = .assistant(try d(AssistantEvent.self))
        case "tool_result": body = .toolResult(try d(ToolResultEvent.self))
        case "approval_request": body = .approvalRequest(try d(ApprovalRequestEvent.self))
        case "approval_resolved": body = .approvalResolved(try d(ApprovalResolvedEvent.self))
        case "turn_end": body = .turnEnd(try d(TurnEndEvent.self))
        case "effort": body = .effort(try d(EffortEvent.self))
        case "interrupt": body = .interrupt(try d(InterruptEvent.self))
        case "error": body = .error(try d(ErrorEvent.self))
        case "fleet": body = .fleet(try d(FleetEvent.self))
        case "task": body = .task(try d(TaskEvent.self))
        case "task_progress": body = .taskProgress(try d(TaskProgressEvent.self))
        case "worker_request": body = .workerRequest(try d(WorkerRequestEvent.self))
        case "swap_request": body = .swapRequest(try d(SwapRequestEvent.self))
        case "swap_resolved": body = .swapResolved(try d(SwapResolvedEvent.self))
        case "dialogue": body = .dialogue(try d(DialogueEvent.self))
        case "dialogue_state": body = .dialogueState(try d(DialogueStateEvent.self))
        case "plan": body = .plan(try d(PlanEvent.self))
        case "notice": body = .notice(try d(NoticeEvent.self))
        case "lead_info": body = .leadInfo(try d(LeadInfoEvent.self))
        case "context": body = .context(try d(ContextEvent.self))
        case "model_catalog": body = .modelCatalog(try d(ModelCatalogEvent.self))
        case "diagram": body = .diagram(try d(DiagramEvent.self))
        case "notes": body = .notes(try d(NotesEvent.self))
        case "annotation": body = .annotation(try d(AnnotationEvent.self))
        case "side_chat": body = .sideChat(try d(SideChatEvent.self))
        case "side_message": body = .sideMessage(try d(SideMessageEvent.self))
        case "side_delta": body = .sideDelta(try d(SideDeltaEvent.self))
        case "conversation_import": body = .conversationImport(try d(ConversationImportEvent.self))
        case "queued": body = .queued(try d(QueuedEvent.self))
        default: body = .unknown(type: type)
        }
        return body
    }

    public var type: String {
        switch body {
        case .session: "session"; case .user: "user"; case .turnStart: "turn_start"; case .textDelta: "text_delta"
        case .assistant: "assistant"; case .toolResult: "tool_result"; case .approvalRequest: "approval_request"
        case .approvalResolved: "approval_resolved"; case .turnEnd: "turn_end"; case .effort: "effort"; case .interrupt: "interrupt"
        case .error: "error"; case .fleet: "fleet"; case .task: "task"; case .taskProgress: "task_progress"
        case .workerRequest: "worker_request"; case .swapRequest: "swap_request"; case .swapResolved: "swap_resolved"
        case .dialogue: "dialogue"; case .dialogueState: "dialogue_state"; case .plan: "plan"; case .notice: "notice"
        case .leadInfo: "lead_info"; case .context: "context"; case .modelCatalog: "model_catalog"
        case .diagram: "diagram"; case .notes: "notes"; case .annotation: "annotation"
        case .sideChat: "side_chat"; case .sideMessage: "side_message"; case .sideDelta: "side_delta"
        case .conversationImport: "conversation_import"; case .queued: "queued"
        case .unknown(let t): t
        }
    }

    // Encoding exists so tests can prove a decode keeps every field (decode → encode → compare).
    public func encode(to encoder: Encoder) throws {
        switch body {
        case .session(let v): try v.encode(to: encoder); case .user(let v): try v.encode(to: encoder)
        case .turnStart(let v): try v.encode(to: encoder); case .textDelta(let v): try v.encode(to: encoder)
        case .assistant(let v): try v.encode(to: encoder); case .toolResult(let v): try v.encode(to: encoder)
        case .approvalRequest(let v): try v.encode(to: encoder); case .approvalResolved(let v): try v.encode(to: encoder)
        case .turnEnd(let v): try v.encode(to: encoder); case .effort(let v): try v.encode(to: encoder)
        case .interrupt(let v): try v.encode(to: encoder); case .error(let v): try v.encode(to: encoder)
        case .fleet(let v): try v.encode(to: encoder); case .task(let v): try v.encode(to: encoder)
        case .taskProgress(let v): try v.encode(to: encoder); case .workerRequest(let v): try v.encode(to: encoder)
        case .swapRequest(let v): try v.encode(to: encoder); case .swapResolved(let v): try v.encode(to: encoder)
        case .dialogue(let v): try v.encode(to: encoder); case .dialogueState(let v): try v.encode(to: encoder)
        case .plan(let v): try v.encode(to: encoder)
        case .notice(let v): try v.encode(to: encoder); case .leadInfo(let v): try v.encode(to: encoder)
        case .context(let v): try v.encode(to: encoder); case .modelCatalog(let v): try v.encode(to: encoder)
        case .diagram(let v): try v.encode(to: encoder); case .notes(let v): try v.encode(to: encoder)
        case .annotation(let v): try v.encode(to: encoder)
        case .sideChat(let v): try v.encode(to: encoder); case .sideMessage(let v): try v.encode(to: encoder)
        case .sideDelta(let v): try v.encode(to: encoder); case .conversationImport(let v): try v.encode(to: encoder)
        case .queued(let v): try v.encode(to: encoder)
        case .unknown: break
        }
        var c = encoder.container(keyedBy: K.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(ts, forKey: .ts)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(conversationId, forKey: .conversationId)
    }
}

// MARK: Settings → Agents

/// A coding agent on the hub's machine, from its scan: Claude Code, Codex CLI, Cursor CLI or Gemini CLI.
public struct AgentInfo: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// `blocked`: signed in only in a way its terms don't let Doublet use (a personal Google plan for Antigravity or
    /// Gemini CLI); `signIn` says what would work. A state this version doesn't know reads as `needsSignIn`.
    public enum State: String, Codable, Sendable {
        case ready, needsSignIn = "needs_sign_in", notInstalled = "not_installed", blocked
        public init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .needsSignIn
        }
    }
    /// "claude", "codex", "cursor", "agy" or "gemini".
    public let id: String
    public let name: String
    /// What it's run as, as found ("agent" or "cursor-agent" for Cursor).
    public let command: String
    public let state: State
    public let path: String?
    public let version: String?
    /// When it needs signing in: how, and what the hub looked for (its check is a best guess from files and the
    /// environment).
    public let signIn: String?
    /// It's there, but `--version` failed (a broken install, or one that hangs), so it may not run.
    public let problem: String?
    public init(id: String, name: String, command: String, state: State, path: String? = nil, version: String? = nil, signIn: String? = nil, problem: String? = nil) {
        self.id = id; self.name = name; self.command = command; self.state = state; self.path = path; self.version = version; self.signIn = signIn; self.problem = problem
    }
}

/// A scan of the hub's machine for coding agents. `host`: its name; `platform`: "darwin", "linux"…
public struct AgentScan: Codable, Sendable, Equatable, Hashable {
    public let host: String
    public let platform: String
    /// Milliseconds since the epoch.
    public let scannedAt: Double
    public let agents: [AgentInfo]
    public var scannedDate: Date { Date(timeIntervalSince1970: scannedAt / 1000) }
}

/// An OpenAI-compatible endpoint the hub keeps, which is a worker with the same id. Its API key never leaves the hub:
/// `hasApiKey` says whether one is set.
public struct EndpointView: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// Ends in /v1.
    public let baseUrl: String
    public let model: String
    public let hasApiKey: Bool
    public let enabled: Bool
    public init(id: String, name: String, baseUrl: String, model: String, hasApiKey: Bool, enabled: Bool) {
        self.id = id; self.name = name; self.baseUrl = baseUrl; self.model = model; self.hasApiKey = hasApiKey; self.enabled = enabled
    }
}

/// Test Connection (GET {baseUrl}/models): the model ids it lists, or why it failed (for people), and how long it took.
/// `status`: the HTTP status when it answered with an error.
public struct EndpointTest: Codable, Sendable, Equatable, Hashable {
    public let ok: Bool
    public let models: [String]
    public let error: String?
    public let ms: Double
    public let status: Int?
    /// "Connected · 3 models found", or the error.
    public var summary: String {
        ok ? "Connected · \(models.count) model\(models.count == 1 ? "" : "s") found" : error ?? "Couldn't connect"
    }
}

/// Everything the hub sends: sequenced events and unsequenced control frames.
/// The hub's answer to one message: ok or an error, and what the request asked for.
public struct AckFrame: Decodable, Sendable, Equatable {
    public let ref: String; public let ok: Bool; public let error: String?
    public let taskId: String?; public let ptyId: String?
    public let diff: String?; public let truncated: Bool?
    public let listing: FsListing?; public let file: FsFile?
    public let image: String?
    /// side_ask: the side chat it went to. fs_files: every file under the folder, relative to it.
    public let chatId: String?; public let files: [String]?
    /// outside_follow: the session and its recent messages. outside_continue: the conversation it continues as, and
    /// whether as a fork.
    public let session: OutsideSession?; public let messages: [OutsideMessage]?
    public let sessionId: String?; public let forked: Bool?
    /// send_place: the device is away, so the place waits for it (it gets it when it next connects).
    public let queued: Bool?
    /// Settings: agents_list/agents_scan's scan, endpoints_list's endpoints, endpoint_add/update's endpoint, and
    /// endpoint_test's result.
    public let scan: AgentScan?; public let endpoints: [EndpointView]?; public let endpoint: EndpointView?; public let test: EndpointTest?
}

/// One of the user's devices (one per device token): whether the app is connected there now, when it was last seen,
/// what it is ("mac", "ipad" or "iphone"; nil for anything else, such as a test client), and what it last said it has
/// open (nil if it never said).
public struct DeviceInfo: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let device: String
    public let online: Bool
    /// Milliseconds since the epoch; nil if never seen.
    public let lastSeen: Double?
    public let kind: String?
    public let open: OpenPlaces?
    public var id: String { device }
    public var lastSeenDate: Date? { lastSeen.map { Date(timeIntervalSince1970: $0 / 1000) } }
    public init(device: String, online: Bool, lastSeen: Double? = nil, kind: String? = nil, open: OpenPlaces? = nil) {
        self.device = device; self.online = online; self.lastSeen = lastSeen; self.kind = kind; self.open = open
    }
}

/// A place a device has open (its tabs and windows), as the app there describes it, with its name for people.
public struct OpenPlace: Codable, Sendable, Equatable, Hashable {
    public let place: JSONValue
    public let title: String
    public init(place: JSONValue, title: String) { self.place = place; self.title = title }
}

/// What a device has open, as it last said (`openPlaces`): `current` is the one in front there, an index into `places`.
public struct OpenPlaces: Codable, Sendable, Equatable, Hashable {
    public let places: [OpenPlace]
    public let current: Int?
    /// Milliseconds since the epoch.
    public let ts: Double
    public init(places: [OpenPlace], current: Int? = nil, ts: Double) { self.places = places; self.current = current; self.ts = ts }
}

/// A place another device sent here (Open on iPad): the sender's own description of it, untouched by the hub. One sent
/// while this device was away arrives after it catches up, so `ts` (ms since the epoch) says how old it is. It comes
/// again on each connection until the store says it has it. `write`: to write on with Apple Pencil (Write on iPad).
public struct PlaceSent: Decodable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let from: String
    public let to: String
    public let place: JSONValue
    public let title: String
    public let ts: Double
    public let write: Bool?
    public var date: Date { Date(timeIntervalSince1970: ts / 1000) }
}

/// A folder on the hub machine, for the file viewer. `git` on an entry: M changed, A added, ? new, D deleted, R renamed,
/// U conflicted; on a folder, • means changes inside.
public struct FsEntry: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let name: String; public let kind: String; public let size: Int; public let mtime: Double; public let link: Bool?; public let git: String?
    public var id: String { name }
    public var isFolder: Bool { kind == "dir" }
    public var modified: Date { Date(timeIntervalSince1970: mtime / 1000) }
}
public struct FsRepo: Codable, Sendable, Equatable, Hashable { public let root: String; public let branch: String }
public struct FsListing: Codable, Sendable, Equatable, Hashable {
    public let path: String; public let parent: String?; public let entries: [FsEntry]; public let truncated: Bool; public let repo: FsRepo?
}
/// A file's text (up to 1 MB), and the lines changed since the last commit.
public struct FsFile: Codable, Sendable, Equatable, Hashable {
    public let path: String; public let size: Int; public let mtime: Double; public let binary: Bool; public let truncated: Bool
    public let text: String?; public let git: String?; public let changed: [Int]?; public let removedAfter: [Int]?
}

public enum ServerFrame: Decodable, Sendable, Equatable {
    case event(HubEvent)
    /// `devices`: the user's devices as this one connects (nil from a hub before the device list).
    case welcome(protocol: Int, device: String, headSeq: Int, replayFrom: Int, reset: Bool, devices: [DeviceInfo]?)
    case replayDone(headSeq: Int)
    case ack(AckFrame)
    case fatal(error: String)
    case ptyList([PtyInfo])
    case appleTask(AppleTask)
    case appleCancel(taskId: String)
    case ptyData(id: String, data: String)
    case ptyExit(id: String, code: Int)
    /// A folder this device watches (its explorer) changed.
    case fsChanged(path: String)
    /// Sessions running outside Duet: the list (on connecting, and when it changes), and the new messages of one this
    /// device follows.
    case outsideSessions([OutsideSession])
    case outsideMessages(sessionId: String, messages: [OutsideMessage])
    /// The user's devices again, whenever one connects or disconnects.
    case devices([DeviceInfo])
    /// A place another device sent here.
    case placeSent(PlaceSent)
    /// The hub's OpenAI-compatible endpoints again, whenever one is added, changed or removed (from any device).
    case endpoints([EndpointView])
    case unknown(type: String)

    private enum K: String, CodingKey { case seq, type, `protocol`, device, headSeq, replayFrom, reset, ref, ok, error, terminals, id, data, code, path, sessions, sessionId, messages, devices, endpoints }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        if c.contains(.seq) { self = .event(try HubEvent(from: decoder)); return }
        switch try c.decode(String.self, forKey: .type) {
        case "welcome":
            self = .welcome(protocol: try c.decode(Int.self, forKey: .protocol), device: try c.decode(String.self, forKey: .device), headSeq: try c.decode(Int.self, forKey: .headSeq), replayFrom: try c.decode(Int.self, forKey: .replayFrom), reset: try c.decode(Bool.self, forKey: .reset),
                            devices: try c.decodeIfPresent([DeviceInfo].self, forKey: .devices))
        case "devices": self = .devices(try c.decode([DeviceInfo].self, forKey: .devices))
        case "place_sent": self = .placeSent(try PlaceSent(from: decoder))
        case "replay_done": self = .replayDone(headSeq: try c.decode(Int.self, forKey: .headSeq))
        case "ack": self = .ack(try AckFrame(from: decoder))
        case "fatal": self = .fatal(error: try c.decode(String.self, forKey: .error))
        case "pty_list": self = .ptyList(try c.decode([PtyInfo].self, forKey: .terminals))
        case "apple_task": self = .appleTask(try AppleTask(from: decoder))
        case "apple_cancel": self = .appleCancel(taskId: try AppleTask.CancelKeys.decode(decoder))
        case "pty_data": self = .ptyData(id: try c.decode(String.self, forKey: .id), data: try c.decode(String.self, forKey: .data))
        case "pty_exit": self = .ptyExit(id: try c.decode(String.self, forKey: .id), code: try c.decode(Int.self, forKey: .code))
        case "outside_sessions": self = .outsideSessions(try c.decode([OutsideSession].self, forKey: .sessions))
        case "outside_messages": self = .outsideMessages(sessionId: try c.decode(String.self, forKey: .sessionId), messages: try c.decode([OutsideMessage].self, forKey: .messages))
        case "fs_changed": self = .fsChanged(path: try c.decode(String.self, forKey: .path))
        case "endpoints": self = .endpoints(try c.decode([EndpointView].self, forKey: .endpoints))
        case let t: self = .unknown(type: t)
        }
    }
}

/// Client → hub. `ref` is echoed in the hub's ack.
public enum ClientMessage: Sendable, Equatable {
    /// `kind`: what this device is ("mac", "ipad" or "iphone"), for a token whose name doesn't say.
    case hello(token: String, device: String, lastSeq: Int, kind: String? = nil)
    /// `voice`: spoken in Talk mode, so Claude keeps the start of its reply short and plain (it's read aloud).
    case prompt(text: String, boost: Bool = false, voice: Bool = false)
    case approve(id: String, updatedInput: [String: JSONValue]? = nil)
    case reject(id: String, message: String? = nil)
    case interrupt
    case setEffort(EffortLevel?)
    /// `profile`: the task's kind (explore, research, implement…), which sets the worker's tools; nil for general.
    case delegate(worker: String, prompt: String, cwd: String? = nil, effort: String? = nil, files: [String]? = nil, profile: String? = nil)
    /// Apple workers: this device's on-device model, and a task's progress and outcome.
    case appleStatus(AppleStatus)
    case appleProgress(taskId: String, text: String)
    case appleDone(taskId: String, ok: Bool, result: String?, error: String?, stats: AppleStats?)
    case cancelTask(taskId: String)
    case setWorker(worker: String, effort: String? = nil, temperature: Double?? = nil, enabled: Bool? = nil, model: String? = nil)
    case approveSwap(id: String)
    case rejectSwap(id: String)
    case answer(questionId: String, text: String)
    case steer(taskId: String, text: String)
    case setPause(Bool)
    /// A new conversation (the current one stays in the list, resumable).
    case clear
    /// Continue an earlier conversation, by its session id. Refused while Claude is busy.
    case resumeSession(sessionId: String)
    case compact
    case setModel(String)
    /// How Claude asks before it acts: "default" (Ask), "acceptEdits", "auto", "plan" or "bypassPermissions". Takes
    /// effect at once, mid-turn too, and the next session starts in it. The hub refuses any other mode.
    case setPermissionMode(String)
    case broadcast(text: String)
    case ptyOpen(kind: PtyKind, cols: Int, rows: Int, cwd: String? = nil)
    /// The file viewer: a folder's entries (nil: Claude's folder), or a file.
    case fsList(path: String?)
    case fsRead(path: String)
    /// Move Claude (and new shells and worker tasks) to a folder, keeping the conversation.
    case setCwd(path: String)
    case ptyAttach(id: String)
    case ptyInput(id: String, data: String)
    case ptyResize(id: String, cols: Int, rows: Int)
    case ptyClose(id: String)
    /// Handwritten notes, with a picture (base64 PNG or JPEG) of what was annotated.
    case notes(surface: NoteSurface, items: [InkNote], image: String? = nil, imageType: String? = nil)
    /// Resolve or reopen a kept note, or delete it; fetch its handwriting.
    /// `reroute`: "claude" asks Claude about a note a local model answered.
    case annotationUpdate(id: String, status: String? = nil, delete: Bool = false, reroute: String? = nil)
    case annotationInk(id: String)
    case taskDiff(taskId: String)
    /// A Live Activity's push token (to update it) and the app's push-to-start token (to start one remotely).
    case liveActivity(token: String?, startToken: String?, environment: String)
    case liveActivityEnd
    /// A question in a new side chat (no chatId) or a follow-up, about something, with a picture (base64) if any.
    case sideAsk(chatId: String? = nil, text: String, about: SideAbout? = nil, model: String? = nil, image: String? = nil, imageType: String? = nil, voice: Bool = false)
    case sideStop(chatId: String)
    /// A better name for a side chat, made on this device; the hub gives it to every device.
    case sideTitle(chatId: String, title: String)
    /// A crash or freeze report, kept by the hub (sent until acked).
    case diagnostic(DiagnosticReport)
    /// "Ask Claude" about a side chat's last local answer.
    case sideReroute(chatId: String)
    /// A reply to a note: its thread (a side chat that continues the note) starts with the first one. The ack
    /// carries the chat id. `image`: a picture (ink) with it.
    case noteReply(id: String, text: String, image: String? = nil, imageType: String? = nil)
    /// Sessions running outside Duet: follow one live (the ack has its recent messages; then `outsideMessages`), stop
    /// following, or continue it here (a fork while it still runs there; the ack has the conversation it continues as).
    case outsideFollow(sessionId: String)
    case outsideUnfollow(sessionId: String)
    case outsideContinue(sessionId: String)
    /// The folders this device's explorer shows (replacing the last set): changes in them come as `fsChanged`.
    case fsWatch(paths: [String])
    /// Every file under a folder (nil: Claude's), for Quick Open.
    case fsFiles(path: String? = nil)
    /// Open a place on another of the user's devices (Open on iPad). It reaches only that device, as `placeSent`, or
    /// waits for it while it's away (the ack's `queued`). `place` is this app's own description, passed on untouched.
    /// `write`: it opens there with the Pencil tools out (Write on iPad).
    case sendPlace(to: String, place: JSONValue, title: String, write: Bool = false)
    /// This device has the place another sent (`placeSent`'s id): the hub stops keeping it for the next connection.
    case placeSeen(id: String)
    /// What this device has open now (its tabs and windows; `current` the one in front), replacing what it said before:
    /// the other devices see it in their device lists.
    case openPlaces(places: [OpenPlace], current: Int?)
    /// Settings → Agents. The last scan of coding agents on the hub's machine (scanning the first time), or a fresh
    /// one: the ack's `scan`.
    case agentsList
    case agentsScan
    /// OpenAI-compatible endpoints: list (ack `endpoints`), add or change (ack `endpoint`), remove (refused while it
    /// has a task). Each change also reaches every device as `.endpoints`. Base URLs end in /v1.
    case endpointsList
    case endpointAdd(name: String, baseUrl: String, model: String, apiKey: String? = nil, enabled: Bool? = nil)
    /// `apiKey`: nil keeps it, `.some(nil)` removes it, `.some(key)` replaces it.
    case endpointUpdate(id: String, name: String? = nil, baseUrl: String? = nil, model: String? = nil, apiKey: String?? = nil, enabled: Bool? = nil)
    case endpointRemove(id: String)
    /// Test Connection (ack `test`): a saved endpoint by id (its stored key unless `apiKey` is given, its URL unless
    /// `baseUrl` is), or an unsaved one by `baseUrl` and `apiKey`.
    case endpointTest(id: String? = nil, baseUrl: String? = nil, apiKey: String? = nil)

    /// The wire object. Optional fields are omitted when nil, except explicit nulls the hub gives meaning to.
    public func json(ref: String?) -> JSONValue {
        var o: [String: JSONValue] = [:]
        func put(_ k: String, _ v: String?) { if let v { o[k] = .string(v) } }
        switch self {
        case .hello(let token, let device, let lastSeq, let kind):
            o = ["type": .string("hello"), "protocol": .number(Double(protocolVersion)), "token": .string(token), "device": .string(device), "lastSeq": .number(Double(lastSeq))]
            put("kind", kind)
            return .object(o)
        case .prompt(let text, let boost, let voice):
            o = ["type": .string("prompt"), "text": .string(text)]
            if boost { o["boost"] = .bool(true) }
            if voice { o["voice"] = .bool(true) }
        case .approve(let id, let input):
            o = ["type": .string("approve"), "id": .string(id)]
            if let input { o["updatedInput"] = .object(input) }
        case .reject(let id, let message): o = ["type": .string("reject"), "id": .string(id)]; put("message", message)
        case .interrupt: o = ["type": .string("interrupt")]
        case .setEffort(let level): o = ["type": .string("set_effort"), "level": level.map { .string($0.rawValue) } ?? .null]
        case .delegate(let worker, let prompt, let cwd, let effort, let files, let profile):
            o = ["type": .string("delegate"), "worker": .string(worker), "prompt": .string(prompt)]; put("cwd", cwd); put("effort", effort); put("profile", profile)
            if let files, !files.isEmpty { o["files"] = .array(files.map { .string($0) }) }
        case .appleStatus(let s):
            o = ["type": .string("apple_status"), "available": .bool(s.available), "platform": .string(s.platform)]
            put("reason", s.reason); put("variant", s.variant)
            if let n = s.contextSize { o["contextSize"] = .number(Double(n)) }
            if let c = s.capabilities { o["capabilities"] = .array(c.map { .string($0) }) }
            if let sim = s.simulator { o["simulator"] = .bool(sim) }
        case .appleProgress(let id, let text): o = ["type": .string("apple_progress"), "taskId": .string(id), "text": .string(text)]
        case .appleDone(let id, let ok, let result, let error, let stats):
            o = ["type": .string("apple_done"), "taskId": .string(id), "ok": .bool(ok)]; put("result", result); put("error", error)
            if let stats { o["stats"] = JSONValue(encoding: stats) }
        case .cancelTask(let id): o = ["type": .string("cancel_task"), "taskId": .string(id)]
        case .setWorker(let worker, let effort, let temperature, let enabled, let model):
            o = ["type": .string("set_worker"), "worker": .string(worker)]; put("effort", effort); put("model", model)
            if let temperature { o["temperature"] = temperature.map { .number($0) } ?? .null }
            if let enabled { o["enabled"] = .bool(enabled) }
        case .approveSwap(let id): o = ["type": .string("approve_swap"), "id": .string(id)]
        case .rejectSwap(let id): o = ["type": .string("reject_swap"), "id": .string(id)]
        case .answer(let q, let text): o = ["type": .string("answer"), "questionId": .string(q), "text": .string(text)]
        case .steer(let t, let text): o = ["type": .string("steer"), "taskId": .string(t), "text": .string(text)]
        case .setPause(let p): o = ["type": .string("set_pause"), "paused": .bool(p)]
        case .clear: o = ["type": .string("clear")]
        case .resumeSession(let id): o = ["type": .string("resume_session"), "sessionId": .string(id)]
        case .compact: o = ["type": .string("compact")]
        case .setModel(let m): o = ["type": .string("set_model"), "model": .string(m)]
        case .setPermissionMode(let m): o = ["type": .string("set_permission_mode"), "mode": .string(m)]
        case .broadcast(let t): o = ["type": .string("broadcast"), "text": .string(t)]
        case .ptyOpen(let kind, let cols, let rows, let cwd): o = ["type": .string("pty_open"), "kind": .string(kind.rawValue), "cols": .number(Double(cols)), "rows": .number(Double(rows))]; put("cwd", cwd)
        case .fsList(let path): o = ["type": .string("fs_list")]; put("path", path)
        case .fsRead(let path): o = ["type": .string("fs_read"), "path": .string(path)]
        case .setCwd(let path): o = ["type": .string("set_cwd"), "path": .string(path)]
        case .ptyAttach(let id): o = ["type": .string("pty_attach"), "id": .string(id)]
        case .ptyInput(let id, let data): o = ["type": .string("pty_input"), "id": .string(id), "data": .string(data)]
        case .ptyResize(let id, let cols, let rows): o = ["type": .string("pty_resize"), "id": .string(id), "cols": .number(Double(cols)), "rows": .number(Double(rows))]
        case .ptyClose(let id): o = ["type": .string("pty_close"), "id": .string(id)]
        case .notes(let surface, let items, let image, let imageType):
            o = ["type": .string("notes"), "surface": JSONValue(encoding: surface), "items": JSONValue(encoding: items)]
            put("image", image); put("imageType", imageType)
        case .taskDiff(let id): o = ["type": .string("task_diff"), "taskId": .string(id)]
        case .annotationUpdate(let id, let status, let delete, let reroute):
            o = ["type": .string("annotation_update"), "id": .string(id)]; put("status", status); put("reroute", reroute)
            if delete { o["delete"] = .bool(true) }
        case .annotationInk(let id): o = ["type": .string("annotation_ink"), "id": .string(id)]
        case .liveActivity(let token, let start, let env):
            o = ["type": .string("live_activity"), "environment": .string(env)]; put("token", token); put("startToken", start)
        case .liveActivityEnd: o = ["type": .string("live_activity_end")]
        case .sideAsk(let chatId, let text, let about, let model, let image, let imageType, let voice):
            o = ["type": .string("side_ask"), "text": .string(text)]; put("chatId", chatId); put("model", model)
            if let about { o["about"] = JSONValue(encoding: about) }
            put("image", image); put("imageType", imageType)
            if voice { o["voice"] = .bool(true) }
        case .sideStop(let id): o = ["type": .string("side_stop"), "chatId": .string(id)]
        case .sideTitle(let id, let title): o = ["type": .string("side_title"), "chatId": .string(id), "title": .string(title)]
        case .diagnostic(let r):
            o = ["type": .string("diagnostic"), "id": .string(r.id), "kind": .string(r.kind), "summary": .string(r.summary)]
            put("at", r.at); put("build", r.build); put("os", r.os); put("model", r.model); put("payload", r.payload)
            if let ms = r.durationMs { o["durationMs"] = .number(ms) }
            if let c = r.context { o["context"] = .object(c) }
        case .sideReroute(let id): o = ["type": .string("side_reroute"), "chatId": .string(id)]
        case .noteReply(let id, let text, let image, let imageType):
            o = ["type": .string("note_reply"), "id": .string(id), "text": .string(text)]; put("image", image); put("imageType", imageType)
        case .outsideFollow(let id): o = ["type": .string("outside_follow"), "sessionId": .string(id)]
        case .outsideUnfollow(let id): o = ["type": .string("outside_unfollow"), "sessionId": .string(id)]
        case .outsideContinue(let id): o = ["type": .string("outside_continue"), "sessionId": .string(id)]
        case .fsWatch(let paths): o = ["type": .string("fs_watch"), "paths": .array(paths.map { .string($0) })]
        case .fsFiles(let path): o = ["type": .string("fs_files")]; put("path", path)
        case .sendPlace(let to, let place, let title, let write):
            o = ["type": .string("send_place"), "to": .string(to), "place": place, "title": .string(title)]
            if write { o["write"] = .bool(true) }
        case .placeSeen(let id): o = ["type": .string("place_seen"), "id": .string(id)]
        case .openPlaces(let places, let current):
            o = ["type": .string("open_places"), "places": JSONValue(encoding: places)]
            if let current { o["current"] = .number(Double(current)) }
        case .agentsList: o = ["type": .string("agents_list")]
        case .agentsScan: o = ["type": .string("agents_scan")]
        case .endpointsList: o = ["type": .string("endpoints_list")]
        case .endpointAdd(let name, let baseUrl, let model, let apiKey, let enabled):
            o = ["type": .string("endpoint_add"), "name": .string(name), "baseUrl": .string(baseUrl), "model": .string(model)]; put("apiKey", apiKey)
            if let enabled { o["enabled"] = .bool(enabled) }
        case .endpointUpdate(let id, let name, let baseUrl, let model, let apiKey, let enabled):
            o = ["type": .string("endpoint_update"), "id": .string(id)]; put("name", name); put("baseUrl", baseUrl); put("model", model)
            if let apiKey { o["apiKey"] = apiKey.map { .string($0) } ?? .null }
            if let enabled { o["enabled"] = .bool(enabled) }
        case .endpointRemove(let id): o = ["type": .string("endpoint_remove"), "id": .string(id)]
        case .endpointTest(let id, let baseUrl, let apiKey):
            o = ["type": .string("endpoint_test")]; put("id", id); put("baseUrl", baseUrl); put("apiKey", apiKey)
        }
        if let ref { o["ref"] = .string(ref) }
        return .object(o)
    }
}
