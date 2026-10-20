import Foundation

// Presentation state the views read directly. The store keeps these up to date incrementally as events
// arrive, so views never sort, filter or re-split the history in `body` (and a streaming reply only
// touches `liveText`, not the finished rows).

/// One row of the lead's thread. Long messages are split into 60-line Markdown chunks so they render lazily.
public enum LeadRow: Identifiable, Equatable, Sendable {
    /// `voice`: spoken in Talk mode.
    case prompt(id: String, text: String, by: String, voice: Bool = false)
    /// Chunk `index` of `count` of one complete assistant message (`message` groups the chunks; `lines` is the total).
    case chunk(id: String, message: String, index: Int, count: Int, lines: Int, text: String)
    /// A tool call: its command, file or pattern (see `ToolSummary`), and for a file tool the change it makes. An
    /// approval card takes its place if it needs one.
    case tool(id: String, name: String, summary: String, edit: FileEdit? = nil)
    case toolResult(id: String, preview: String, isError: Bool)
    case approval(id: String, approvalId: String)
    /// A message between Claude and one of its workers: the task it gave, a question, its answer, a result.
    case agent(id: String, message: DialogueEvent)
    /// A diagram Claude showed (one row per version).
    case diagram(id: String, diagram: DiagramEvent)
    /// Handwritten notes you sent: as a prompt, or mid-turn.
    case notes(id: String, by: String, notes: Notes)
    case note(id: String, text: String)
    case footer(id: String, end: TurnEndEvent)

    public var id: String {
        switch self {
        case .prompt(let i, _, _, _), .chunk(let i, _, _, _, _, _), .tool(let i, _, _, _), .toolResult(let i, _, _),
             .approval(let i, _), .agent(let i, _), .diagram(let i, _), .notes(let i, _, _), .note(let i, _), .footer(let i, _): i
        }
    }

    /// Splits text into blocks of at most `size` lines, never inside a ``` fence.
    public static func split(_ text: String, size: Int = 60) -> [String] {
        var out: [String] = []
        var cur: [Substring] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            cur.append(line)
            if cur.count >= size && !inFence {
                out.append(cur.joined(separator: "\n"))
                cur = []
            }
        }
        if !cur.isEmpty { out.append(cur.joined(separator: "\n")) }
        return out
    }
}

/// What the lead is doing, in a form a status line or a menu-bar icon can show.
public struct LeadStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, thinking, writing, tool(String), approval, workers(Int), compacting
    }
    public var phase: Phase = .idle
    /// When the current turn started (hub clock, so every device shows the same timer).
    public var since: Date?
    public var turn: Int?

    public var busy: Bool { phase != .idle }

    public var label: String {
        switch phase {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .writing: "Writing"
        case .tool(let t): LeadStatus.doing(t)
        case .approval: "Needs your approval"
        case .workers(let n): n == 1 ? "Waiting on a worker" : "Waiting on \(n) workers"
        case .compacting: "Compacting"
        }
    }

    public var symbol: String {
        switch phase {
        case .idle: "checkmark.circle"
        case .thinking: "brain"
        case .writing: "text.cursor"
        case .tool: "wrench.and.screwdriver"
        case .approval: "hand.raised.fill"
        case .workers: "person.2.wave.2"
        case .compacting: "rectangle.compress.vertical"
        }
    }

    /// What a tool call is doing, in words: "Reading a web page", not "Running WebFetch".
    static func doing(_ tool: String) -> String {
        switch tool {
        case "WebSearch": "Searching the web"
        case "WebFetch": "Reading a web page"
        case "Read": "Reading a file"
        case "Grep", "Glob": "Searching the code"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": "Editing files"
        case "Bash": "Running a command"
        case "Agent", "Task": "Starting a subagent"
        default: "Running \(friendly(tool))"
        }
    }

    static func friendly(_ tool: String) -> String {
        if tool.hasPrefix("mcp__duet__") { return String(tool.dropFirst("mcp__duet__".count)).replacingOccurrences(of: "_", with: " ") }
        return tool
    }
}

/// Something only you can unblock.
public enum AttentionItem: Identifiable, Equatable, Sendable {
    case approval(ApprovalRequestEvent)
    case question(DialogueEvent)
    case swap(SwapRequestEvent)

    public var id: String {
        switch self {
        case .approval(let a): "a-\(a.id)"
        case .question(let q): "q-\(q.id)"
        case .swap(let s): "s-\(s.id)"
        }
    }

    public var title: String {
        switch self {
        case .approval(let a): a.title ?? "Claude wants to run \(a.tool)"
        case .question(let q): "\(q.from) asks"
        case .swap(let s): "\(s.worker) needs \(s.model) loaded"
        }
    }
}

/// A RESULT message in parts: "Finished: <report>", then "Worker's output:" and "Hub-measured changes:" when present.
public struct ResultParts: Equatable, Sendable {
    public var ok: Bool
    public var summary: String
    public var output: String?
    public var changes: String?

    public init(_ text: String) {
        ok = !text.hasPrefix("Failed")
        var rest = text
        for p in ["Finished: ", "Failed: "] where rest.hasPrefix(p) { rest.removeFirst(p.count) }
        if let r = rest.range(of: "\nHub-measured changes:\n") {
            changes = String(rest[r.upperBound...])
            rest = String(rest[..<r.lowerBound])
        }
        if let r = rest.range(of: "\nWorker's output:\n") {
            output = String(rest[r.upperBound...])
            rest = String(rest[..<r.lowerBound])
        }
        summary = rest
    }
}
