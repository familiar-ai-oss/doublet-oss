import Foundation
import Observation

/// One lead turn as the UI shows it.
public struct Turn: Identifiable, Sendable, Equatable {
    public let id: Int
    public var prompt: String = ""
    public var by: String = ""
    /// Text streamed since the last complete assistant message, published at most 15 times a second.
    public var streaming: String = ""
    public var items: [TurnItem] = []
    public var end: TurnEndEvent?
    /// For the seamless-reconnect check: everything streamed vs. everything in complete messages.
    public var streamedTotal: String = ""
    public var finalTotal: String = ""
}

public enum TurnItem: Sendable, Equatable, Identifiable {
    case text(id: Int, String)
    case tool(id: Int, name: String, input: String)
    case toolResult(id: Int, preview: String, isError: Bool)
    case approval(id: Int, ApprovalRequestEvent)
    case note(id: Int, String)

    public var id: Int {
        switch self {
        case .text(let i, _), .tool(let i, _, _), .toolResult(let i, _, _), .approval(let i, _), .note(let i, _): i
        }
    }
}

/// A line in a worker's task thread.
public enum TaskLine: Sendable, Equatable, Identifiable {
    case text(id: Int, String)
    case tools(id: Int, [String])
    case toolResult(id: Int, String)
    case card(id: Int, DialogueEvent)
    case state(id: Int, TaskEvent)

    public var id: Int {
        switch self {
        case .text(let i, _), .tools(let i, _), .toolResult(let i, _), .card(let i, _), .state(let i, _): i
        }
    }
}

/// One conversation: a Claude session. Its rows are the lead's thread for it; the tasks and diagrams are those it
/// started (a worker task that finishes after a Clear still belongs here).
public struct Conversation: Identifiable, Sendable, Equatable {
    /// The session id. A segment of an older hub's log is "~N" until its first `session ready` names it.
    public internal(set) var id: String
    /// When its first event arrived, and its latest (hub clock).
    public var startedAt: Date
    public var lastActivity: Date
    /// The first thing you asked, and Claude's first reply: the raw material for its name.
    public var firstPrompt: String?
    public var firstReply: String?
    /// The folder Claude worked in, last known.
    public var cwd: String?
    public var turnIds: [Int] = []
    public var rows: [LeadRow] = []
    public var taskIds: [String] = []
    public var diagramIds: [String] = []
    /// Started outside Duet and continued here: where it came from, and its last messages there.
    public var imported: ConversationImportEvent?
    /// Claude's plan for it (its latest list): who does each step, and the task doing it.
    public var plan: [PlanStep] = []
    /// Side chats asked beside it, oldest first.
    public var sideChatIds: [String] = []
    /// Prompts the hub holds while Claude works, oldest first: shown as waiting until Claude takes them.
    public var waiting: [QueuedEvent] = []

    public init(id: String, startedAt: Date, lastActivity: Date) {
        self.id = id; self.startedAt = startedAt; self.lastActivity = lastActivity
    }

    /// Something was said in it, not only notes such as "New conversation".
    public var hasContent: Bool { rows.contains { if case .note = $0 { false } else { true } } }
    public var isProvisional: Bool { id.hasPrefix("~") }
}

/// A side chat: a quick question beside a conversation, answered by Claude in a copy of it (read-only).
public struct SideChat: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var model: String
    public var by: String
    public var about: SideAbout?
    /// answering, idle or failed; what it's doing while it answers, and why it failed.
    public var state: String
    public var activity: String?
    public var error: String?
    /// How much of the conversation its copy has: whole, before_turn (up to Claude's last reply) or none.
    public var forked: String?
    public var messages: [SideMessageEvent] = []
    /// The answer streaming now, published at most 15 times a second.
    public var streaming: String = ""
    public var startedAt: Date
    public var conversationId: String?
    /// The note it continues: it shows in that note's thread rather than as a side chat of its own.
    public var annotationId: String? = nil
    public var isAnswering: Bool { state == "answering" }
}

/// The last change Claude or a worker made to a file: who (`lead`, or a worker id), with which tool, when (hub clock).
public struct FileTouch: Sendable, Equatable {
    public let by: String
    public let tool: String
    public let at: Date
}

/// App state built from the hub's event stream. Everything the UI shows is derived from applied events,
/// so replay after a reconnect (or on another device) produces the same screen.
@MainActor
@Observable
public final class DuetStore {
    public private(set) var connection: ConnectionState = .idle
    public private(set) var turns: [Turn] = []
    public private(set) var openApprovals: [String: ApprovalRequestEvent] = [:]
    /// Every approval request seen, open or resolved (cards keep showing what was asked).
    public private(set) var approvals: [String: ApprovalRequestEvent] = [:]
    public private(set) var resolvedApprovals: [String: ApprovalResolvedEvent] = [:]
    public private(set) var workers: [WorkerView] = []
    public private(set) var catalog: [CatalogModel] = []
    public private(set) var tasks: [String: TaskEvent] = [:]
    public private(set) var taskOrder: [String] = []
    public private(set) var taskLines: [String: [TaskLine]] = [:]
    public private(set) var cards: [DialogueEvent] = []
    public private(set) var answeredQuestions: Set<String> = []
    public private(set) var swaps: [SwapRequestEvent] = []
    public private(set) var resolvedSwaps: Set<String> = []
    public private(set) var dialogueState: DialogueStateEvent?
    public private(set) var session: SessionEvent?
    public private(set) var leadInfo: LeadInfoEvent?
    public private(set) var effort: EffortLevel?
    public private(set) var notices: [String] = []
    public private(set) var errors: [String] = []
    public private(set) var terminals: [PtyInfo] = []
    // Presentation state (see Presentation.swift), maintained as events arrive.
    /// Every conversation in the log, oldest first, each with its own thread, tasks and diagrams.
    public private(set) var conversations: [Conversation] = []
    /// The live one: the session Claude is in now. Prompts go to it.
    public private(set) var currentConversationId: String?
    /// The reply streaming right now (published at most 15 times a second), and its turn.
    public private(set) var liveText: String = ""
    public private(set) var liveTurn: Int?
    public private(set) var leadStatus = LeadStatus()
    public private(set) var attention: [AttentionItem] = []
    /// When the oldest item in `attention` arrived (hub clock): how long you've kept something waiting.
    public private(set) var waitingSince: Date?
    /// Latest progress line per worker ("Edit greet.txt", "Writing…").
    public private(set) var workerActivity: [String: String] = [:]
    /// Diagrams by id (their latest version), every version by id, and ids in the order they first appeared.
    public private(set) var diagrams: [String: DiagramEvent] = [:]
    public private(set) var diagramVersions: [String: [DiagramEvent]] = [:]
    public private(set) var diagramOrder: [String] = []
    /// Kept notes (annotations) by id: what they say, what they're on, and Claude's answers.
    public private(set) var annotations: [String: Annotation] = [:]
    /// Side chats by id; each conversation lists its own (`Conversation.sideChatIds`).
    public private(set) var sideChats: [String: SideChat] = [:]
    /// Claude Code sessions running outside Duet on the hub machine (the hub's list), and the messages of those followed here.
    public private(set) var outsideSessions: [OutsideSession] = []
    public private(set) var outsideMessages: [String: [OutsideMessage]] = [:]
    /// The user's devices (the hub's list, this one included): which are online now, when each was last seen.
    public private(set) var devices: [DeviceInfo] = []
    /// The hub's OpenAI-compatible endpoints (Settings → Agents), as it last sent them: kept current by its `endpoints`
    /// frames once `listEndpoints()` has run.
    public private(set) var endpoints: [EndpointView] = []
    /// The last place another device sent here (Send to iPad); `onPlaceSent` hears each one as it comes.
    public private(set) var lastPlaceSent: PlaceSent?
    /// The files Claude and its workers changed, by path: the latest change to each.
    public private(set) var fileTouches: [String: FileTouch] = [:]
    /// When each task finished (hub clock).
    public private(set) var taskEndedAt: [String: Date] = [:]
    /// Finished tasks, newest first (at most 12).
    public private(set) var recentResults: [TaskEvent] = []
    /// Claude's subagents by the few words it gave each ("Find subagent handling"), by task id.
    public private(set) var agentLabels: [String: String] = [:]
    /// The subagents Claude started in the same message, by each one's task id: they end as one launch.
    private var agentLaunches: [String: [String]] = [:]
    public private(set) var lastSeq = 0
    public private(set) var eventCount = 0
    public private(set) var gaps = 0
    public private(set) var duplicates = 0
    public private(set) var replayedOnce = false
    /// A long replay being applied (how many events of how many): the conversation says it's catching up until it's in.
    public private(set) var catchingUp: CatchUp?
    public struct CatchUp: Equatable, Sendable { public var done: Int; public var total: Int }
    /// The latest moment worth feeling (the iPhone's haptics). Only events that arrive live set it, never a replay.
    public private(set) var beat: Beat?
    private var beats = 0

    // Not observed: streaming deltas wait here until the next 15 Hz publish.
    @ObservationIgnored private var pendingDeltas: [Int: String] = [:]
    @ObservationIgnored private var pendingSideDeltas: [String: String] = [:]
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var conn: HubConnection?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var nextItem = 0
    @ObservationIgnored private var attentionArrived: [String: Date] = [:]
    /// Approval id by tool-use id, so a card replaces its tool-call row and a rejected call's result isn't repeated.
    @ObservationIgnored private var approvalByToolUse: [String: String] = [:]
    /// Claude's duet tool calls by tool-use id: their messages show instead (agent rows).
    @ObservationIgnored private var dialogueToolUses: [String: String] = [:]
    /// Tasks whose next tool result (older hubs) answers a duet call that isn't shown.
    @ObservationIgnored private var skipToolResult: Set<String> = []
    @ObservationIgnored private var eventTime = Date.distantPast
    /// The conversation each task started in (events of a task carry it, but older hubs' don't).
    @ObservationIgnored private var taskConversation: [String: String] = [:]
    @ObservationIgnored private var diagramConversation: [String: String] = [:]
    @ObservationIgnored private var provisionalCount = 0
    // Terminal output goes straight to the attached view (or waits here until one attaches).
    @ObservationIgnored private var ptySinks: [String: (String) -> Void] = [:]
    @ObservationIgnored private var ptyPending: [String: String] = [:]
    @ObservationIgnored public var onPtyExit: ((String, Int) -> Void)?
    /// Apple workers: a task the hub sent this device, and a cancellation.
    @ObservationIgnored public var onAppleTask: (@MainActor (AppleTask) -> Void)?
    @ObservationIgnored public var onAppleCancel: (@MainActor (String) -> Void)?
    /// A folder this device watches (its explorer) changed on the hub machine.
    @ObservationIgnored public var onFsChanged: (@MainActor (String) -> Void)?
    /// A place another device sent here. One sent while this device was away comes once it has caught up: its `date`
    /// says how old it is.
    @ObservationIgnored public var onPlaceSent: (@MainActor (PlaceSent) -> Void)?
    /// Called after each batch of applied events (debug status file, notifications later).
    @ObservationIgnored public var onChange: (@MainActor (DuetStore) -> Void)?

    public static let streamingInterval: Duration = .milliseconds(66) // ~15 Hz

    public init() {}

    public var isBusy: Bool { turns.last.map { $0.end == nil } ?? false }

    // MARK: conversations

    /// The live conversation.
    public var current: Conversation? { currentConversationId.flatMap { conversation($0) } }
    /// The live conversation's thread.
    public var leadRows: [LeadRow] { current?.rows ?? [] }
    /// How many other conversations have something in them.
    public var earlierConversations: Int { conversations.filter { $0.id != currentConversationId && $0.hasContent }.count }
    /// Every other conversation's rows, oldest first.
    public var earlierRows: [LeadRow] { conversations.filter { $0.id != currentConversationId }.flatMap(\.rows) }

    public func conversation(_ id: String) -> Conversation? { conversations.first { $0.id == id } }
    public func rows(for id: String) -> [LeadRow] { conversation(id)?.rows ?? [] }
    /// The conversation a worker task was started in.
    public func conversationOf(taskId: String) -> String? { taskConversation[taskId] }
    public func conversationOf(diagramId: String) -> String? { diagramConversation[diagramId] }

    /// Every kept note, newest first.
    public var annotationList: [Annotation] { annotations.values.sorted { $0.ts > $1.ts } }

    /// Kept notes written on a file, newest first.
    public func annotations(onFile path: String) -> [Annotation] {
        annotationList.filter { if case .file(let p) = $0.surface { p == path } else { false } }
    }

    /// Kept notes written on a diagram (any version), newest first.
    public func annotations(onDiagram id: String) -> [Annotation] {
        annotationList.filter { if case .diagram(let d, _, _) = $0.surface { d == id } else { false } }
    }

    /// Kept notes written on a conversation's plan, newest first. Each one's elements are the steps it's on.
    public func annotations(onPlan conversationId: String) -> [Annotation] {
        annotationList.filter { if case .plan(let c) = $0.surface { c == conversationId } else { false } }
    }

    /// The notes Claude answered with this diagram.
    public func annotations(answeredBy diagramId: String) -> [Annotation] {
        annotationList.filter { $0.diagrams?.contains(diagramId) ?? false }
    }

    /// The folder Claude works in on the hub machine, and the ones it worked in before.
    public var leadCwd: String? { leadInfo?.cwd }
    public var recentCwds: [String] { leadInfo?.recentCwds ?? [] }
    public var lastTokPerS: [String: Double] { Dictionary(uniqueKeysWithValues: workers.compactMap { w in w.tokPerS.map { (w.id, $0) } }) }

    public func connect(_ config: HubConfig) {
        disconnect()
        reset()
        let c = HubConnection(config: config)
        conn = c
        // A connection's replay comes as one batch: a short one is applied at once (SwiftUI renders once, not once
        // per event); a long one a slice at a time, so Duet keeps answering touches while it catches up.
        pump = Task { [weak self] in
            for await ev in c.events {
                guard let self else { return }
                if case .events(let list) = ev, list.count > Self.sliceOver {
                    await self.applyInSlices(list)
                } else {
                    self.handle(ev)
                }
                self.onChange?(self)
            }
        }
        Task { await c.start() }
    }

    /// Replays longer than this are applied in slices.
    static let sliceOver = 400
    /// How long one slice of a replay may take before Duet goes back to the run loop (touches, drawing).
    static let slice: Duration = .milliseconds(12)

    /// A long replay (a hub's whole history at launch: thousands of events), a slice at a time. In one go it blocks
    /// the main thread for a second or more; this way touches and drawing go on between slices.
    func applyInSlices(_ list: [HubEvent]) async {
        catchingUp = CatchUp(done: 0, total: list.count)
        defer { catchingUp = nil }
        var i = 0
        while i < list.count {
            if Task.isCancelled { return }
            let start = ContinuousClock.now
            repeat {
                apply(list[i])
                i += 1
            } while i < list.count && ContinuousClock.now - start < Self.slice
            catchingUp?.done = i
            // A timer, not a yield: it goes back through the run loop, where touches and the next frame are handled.
            if i < list.count { try? await Task.sleep(for: .milliseconds(1)) }
        }
    }

    public func disconnect() {
        pump?.cancel()
        if let c = conn { Task { await c.stop() } }
        conn = nil
        connection = .idle
    }

    /// Debug: drop the socket as a network failure would.
    public func dropConnection() {
        if let c = conn { Task { await c.dropConnection() } }
    }

    @discardableResult
    public func send(_ m: ClientMessage) async throws -> Ack {
        guard let c = conn else { throw HubError(message: "not connected") }
        return try await c.send(m)
    }

    // MARK: other devices

    /// The user's other devices, as the hub knows them.
    public var otherDevices: [DeviceInfo] {
        guard case .connected(let me) = connection else { return devices }
        return devices.filter { $0.device != me }
    }

    /// Open a place on another device (Open on iPad; `write`: Write on iPad). Returns whether it's waiting there
    /// because the device is away.
    @discardableResult
    public func sendPlace(to device: String, place: JSONValue, title: String, write: Bool = false) async throws -> Bool {
        try await send(.sendPlace(to: device, place: place, title: title, write: write)).queued ?? false
    }

    /// Tell the other devices what this one has open (its tabs and windows; `current` the one in front), for their
    /// switchers.
    public func reportOpenPlaces(_ places: [OpenPlace], current: Int?) async throws {
        try await send(.openPlaces(places: places, current: current))
    }

    // MARK: Settings → Agents

    /// The coding agents on the hub's machine: its last scan, or (`rescan`) a fresh one.
    public func agentScan(rescan: Bool = false) async throws -> AgentScan {
        guard let scan = try await send(rescan ? .agentsScan : .agentsList).scan else { throw HubError(message: "the hub sent no scan") }
        return scan
    }

    @discardableResult
    public func listEndpoints() async throws -> [EndpointView] {
        let l = try await send(.endpointsList).endpoints ?? []
        endpoints = l
        return l
    }

    /// Add an endpoint (`.endpointAdd`) or change one (`.endpointUpdate`): the hub's copy of it.
    @discardableResult
    public func saveEndpoint(_ m: ClientMessage) async throws -> EndpointView {
        guard let e = try await send(m).endpoint else { throw HubError(message: "the hub sent no endpoint") }
        return e
    }

    public func removeEndpoint(_ id: String) async throws {
        try await send(.endpointRemove(id: id))
    }

    /// Test Connection: a saved endpoint by id, or an unsaved one by URL and key.
    public func testEndpoint(id: String? = nil, baseUrl: String? = nil, apiKey: String? = nil) async throws -> EndpointTest {
        guard let t = try await send(.endpointTest(id: id, baseUrl: baseUrl, apiKey: apiKey)).test else { throw HubError(message: "the hub sent no result") }
        return t
    }

    // MARK: sessions running outside Duet

    /// Follow one live: its recent messages now (`outsideMessages[sessionId]`), then each new one as it comes.
    public func followOutside(_ sessionId: String) async throws {
        let ack = try await send(.outsideFollow(sessionId: sessionId))
        outsideMessages[sessionId] = ack.messages ?? []
    }

    public func unfollowOutside(_ sessionId: String) async {
        outsideMessages[sessionId] = nil
        _ = try? await send(.outsideUnfollow(sessionId: sessionId))
    }

    /// Continue it here: a fork while it still runs there, else the session itself. Returns the conversation's id, or
    /// nil when a turn is running here: the hub continues it as soon as that turn ends.
    @discardableResult
    public func continueOutside(_ sessionId: String) async throws -> String? {
        let ack = try await send(.outsideContinue(sessionId: sessionId))
        return ack.queued == true ? nil : ack.sessionId ?? sessionId
    }

    // MARK: terminals

    /// Route a terminal's output to a view. Output that arrived before the view attached is delivered first.
    public func attachTerminal(_ id: String, sink: @escaping (String) -> Void) {
        ptySinks[id] = sink
        if let p = ptyPending.removeValue(forKey: id) { sink(p) }
    }

    public func detachTerminal(_ id: String) {
        ptySinks[id] = nil
    }

    private func ptyData(_ id: String, _ data: String) {
        if let s = ptySinks[id] { s(data) } else { ptyPending[id, default: ""] = String((ptyPending[id, default: ""] + data).suffix(262_144)) }
    }

    // MARK: events

    func handle(_ ev: ConnectionEvent) {
        switch ev {
        case .state(let s):
            connection = s
            // The hub forgets what a device followed when it disconnects: follow those again.
            if case .connected = s { for id in outsideMessages.keys { Task { try? await self.followOutside(id) } } }
        case .outsideSessions(let l): outsideSessions = l
        case .outsideMessages(let id, let m):
            guard let had = outsideMessages[id] else { break }
            let seen = Set(had.map(\.uuid))
            outsideMessages[id] = had + m.filter { !seen.contains($0.uuid) }
        case .devices(let l): devices = l
        case .endpoints(let l): endpoints = l
        case .placeSent(let p):
            // The hub sends it again on each connection until it hears it arrived. If this doesn't get there, the next
            // connection brings it again, and the app opens each one once.
            Task { try? await self.send(.placeSeen(id: p.id)) }
            lastPlaceSent = p
            onPlaceSent?(p)
        case .reset: reset()
        case .event(let e): apply(e)
        case .events(let list): for e in list { apply(e) }
        case .replayDone: replayedOnce = true
        case .ptyList(let l):
            terminals = l
            // Re-attach terminals this device was showing; the hub replays their scrollback.
            for t in l where ptySinks[t.id] != nil { Task { try? await self.send(.ptyAttach(id: t.id)) } }
        case .ptyData(let id, let data): ptyData(id, data)
        case .stats(let g, let d): gaps = g; duplicates = d
        case .appleTask(let t): onAppleTask?(t)
        case .appleCancel(let id): onAppleCancel?(id)
        case .fsChanged(let path): onFsChanged?(path)
        case .ptyExit(let id, let code):
            terminals.removeAll { $0.id == id }
            ptySinks[id]?("\r\n[process exited with code \(code)]\r\n")
            onPtyExit?(id, code)
        }
    }

    /// Track a terminal this device opened (the hub's list only arrives on connect).
    public func addTerminal(_ info: PtyInfo) {
        if !terminals.contains(where: { $0.id == info.id }) { terminals.append(info) }
    }

    /// The task the hub shows a subagent call as (the hub's subagentTaskId).
    static func subagentTaskId(_ toolUseId: String) -> String { "sa-\(toolUseId.suffix(8))" }

    private func reset() {
        turns = []; openApprovals = [:]; approvals = [:]; resolvedApprovals = [:]; workers = []; catalog = []; tasks = [:]; taskOrder = []; taskLines = [:]
        cards = []; answeredQuestions = []; swaps = []; resolvedSwaps = []; dialogueState = nil; session = nil; leadInfo = nil
        effort = nil; notices = []; errors = []; lastSeq = 0; eventCount = 0; nextItem = 0; pendingDeltas = [:]
        conversations = []; currentConversationId = nil; taskConversation = [:]; diagramConversation = [:]; provisionalCount = 0
        liveText = ""; liveTurn = nil; leadStatus = LeadStatus(); attention = []; workerActivity = [:]; recentResults = []
        waitingSince = nil; attentionArrived = [:]; approvalByToolUse = [:]; dialogueToolUses = [:]; skipToolResult = []; taskEndedAt = [:]
        diagrams = [:]; diagramVersions = [:]; diagramOrder = []; annotations = [:]; sideChats = [:]; fileTouches = [:]; pendingSideDeltas = [:]
        agentLabels = [:]; agentLaunches = [:]
    }

    // MARK: conversation bookkeeping

    private func index(of id: String) -> Int? { conversations.firstIndex { $0.id == id } }

    /// The conversation with this id, added if it's new.
    @discardableResult private func ensure(_ id: String) -> Int {
        if let i = index(of: id) { return i }
        conversations.append(Conversation(id: id, startedAt: eventTime, lastActivity: eventTime))
        return conversations.count - 1
    }

    /// Make `id` the live conversation. A provisional one (an older hub's segment not yet named) takes the id
    /// instead of giving way, so its early events stay with it.
    private func switchCurrent(to id: String) {
        if let cur = currentConversationId, cur != id, cur.hasPrefix("~"), !id.hasPrefix("~"), index(of: id) == nil {
            rekey(from: cur, to: id)
            return
        }
        ensure(id)
        currentConversationId = id
    }

    private func rekey(from: String, to: String) {
        guard let i = index(of: from) else { return }
        conversations[i].id = to
        for (k, v) in taskConversation where v == from { taskConversation[k] = to }
        for (k, v) in diagramConversation where v == from { diagramConversation[k] = to }
        if currentConversationId == from { currentConversationId = to }
    }

    private func newProvisional() -> String { provisionalCount += 1; return "~\(provisionalCount)" }

    /// Where a lead-turn event goes: its tagged conversation, made live (older hubs: whatever is live now).
    private func leadConversation(_ e: HubEvent) -> Int {
        if let id = e.conversationId { switchCurrent(to: id) } else if currentConversationId == nil { switchCurrent(to: newProvisional()) }
        return index(of: currentConversationId!)!
    }

    /// Where a worker's or task's event goes, without changing the live conversation: its tag, else its task's.
    private func asyncConversation(_ e: HubEvent, taskId: String? = nil) -> Int {
        if let id = e.conversationId { return ensure(id) }
        if let t = taskId, let id = taskConversation[t], let i = index(of: id) { return i }
        if currentConversationId == nil { switchCurrent(to: newProvisional()) }
        return index(of: currentConversationId!)!
    }

    private func addRow(_ row: LeadRow, to i: Int) {
        conversations[i].rows.append(row)
        conversations[i].lastActivity = eventTime
    }

    /// Replace the row matching `where` in a conversation's thread, else append.
    private func putRow(_ row: LeadRow, in i: Int, replacing match: (LeadRow) -> Bool) {
        if let r = conversations[i].rows.lastIndex(where: match) { conversations[i].rows[r] = row } else { addRow(row, to: i) }
    }

    private func feel(_ m: Beat.Moment) {
        guard replayedOnce else { return }
        beats += 1
        beat = Beat(moment: m, n: beats)
    }

    private func setPhase(_ p: LeadStatus.Phase) {
        guard leadStatus.busy || p == .idle else { return }
        if leadStatus.phase != p { leadStatus.phase = p }
    }

    private func addAttention(_ a: AttentionItem) {
        attention.append(a)
        attentionArrived[a.id] = eventTime
        if waitingSince == nil { waitingSince = eventTime }
    }

    private func removeAttention(_ id: String) {
        guard attention.contains(where: { $0.id == id }) else { return }
        attention.removeAll { $0.id == id }
        attentionArrived[id] = nil
        let oldest = attention.compactMap { attentionArrived[$0.id] }.min()
        if waitingSince != oldest { waitingSince = oldest }
    }

    private func leadActiveTasks() -> Int {
        tasks.values.filter { $0.by == "lead" && ["queued", "running", "awaiting_swap"].contains($0.state) }.count
    }

    private func item() -> Int { nextItem += 1; return nextItem }

    private func withTurn(_ n: Int, _ f: (inout Turn) -> Void) {
        if let i = turns.lastIndex(where: { $0.id == n }) { f(&turns[i]); return }
        var t = Turn(id: n)
        f(&t)
        turns.append(t)
    }

    private func line(_ taskId: String, _ l: TaskLine) {
        var ls = taskLines[taskId, default: []]
        ls.append(l)
        if ls.count > 400 { ls.removeFirst(ls.count - 400) }
        taskLines[taskId] = ls
    }

    /// Publish buffered streaming text. Called on the 15 Hz tick, and before anything that ends a stream.
    public func flushStreaming() {
        flushScheduled = false
        for (id, text) in pendingSideDeltas where sideChats[id] != nil { sideChats[id]!.streaming += text }
        pendingSideDeltas = [:]
        guard !pendingDeltas.isEmpty else { return }
        let pending = pendingDeltas
        pendingDeltas = [:]
        for (turn, text) in pending {
            withTurn(turn) { $0.streaming += text }
            if liveTurn != turn { liveTurn = turn; liveText = "" }
            liveText += text
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.streamingInterval)
            self?.flushStreaming()
        }
    }

    /// Apply one event. Public so tests can replay fixtures without a socket.
    public func apply(_ e: HubEvent) {
        lastSeq = e.seq
        eventCount += 1
        eventTime = Date(timeIntervalSince1970: e.ts / 1000)
        switch e.body {
        case .session(let s):
            session = s
            if e.conversationId != nil {
                _ = leadConversation(e)
            } else if let sid = s.sessionId, sid != currentConversationId {
                // An older hub names a session on its first turn: the segment so far is that session.
                switchCurrent(to: sid)
            }
        case .user(let u):
            withTurn(u.turn) { $0.prompt = u.text; $0.by = u.by }
            let i = leadConversation(e)
            if !conversations[i].turnIds.contains(u.turn) { conversations[i].turnIds.append(u.turn) }
            if conversations[i].firstPrompt == nil, u.notes == nil { conversations[i].firstPrompt = u.text }
            if let notes = u.notes {
                addRow(.notes(id: "t\(u.turn)-p", by: u.by, notes: notes), to: i)
            } else {
                addRow(.prompt(id: "t\(u.turn)-p", text: u.text, by: u.by, voice: u.voice == true), to: i)
            }
        case .turnStart(let t):
            withTurn(t.turn) { _ in }
            let i = leadConversation(e)
            if !conversations[i].turnIds.contains(t.turn) { conversations[i].turnIds.append(t.turn) }
            let compacting = turns.last(where: { $0.id == t.turn })?.prompt == "/compact"
            leadStatus = LeadStatus(phase: compacting ? .compacting : .thinking, since: Date(timeIntervalSince1970: e.ts / 1000), turn: t.turn)
        case .textDelta(let d):
            withTurn(d.turn) { $0.streamedTotal += d.text }
            pendingDeltas[d.turn, default: ""] += d.text
            scheduleFlush()
            if leadStatus.phase != .compacting { setPhase(.writing) }
        case .assistant(let a):
            flushStreaming()
            withTurn(a.turn) { t in
                if !a.text.isEmpty { t.items.append(.text(id: item(), a.text)); t.finalTotal += a.text }
                t.streaming = ""
                for u in a.toolUses { t.items.append(.tool(id: item(), name: u.name, input: u.input.compact)) }
            }
            if liveTurn == a.turn { liveText = ""; liveTurn = nil }
            let i = leadConversation(e)
            if !a.text.isEmpty {
                if conversations[i].firstReply == nil { conversations[i].firstReply = a.text }
                let msg = "t\(a.turn)-m\(item())"
                let chunks = LeadRow.split(a.text)
                let lines = a.text.split(separator: "\n", omittingEmptySubsequences: false).count
                for (k, c) in chunks.enumerated() { addRow(.chunk(id: "\(msg)-c\(k)", message: msg, index: k, count: chunks.count, lines: lines, text: c), to: i) }
            }
            for u in a.toolUses { touch(u.name, u.input, by: "lead") }
            // Subagents: what each is called, and which started together.
            let launched = a.toolUses.filter { ToolSummary.isSubagent($0.name) }
            for u in launched { agentLabels[Self.subagentTaskId(u.id)] = ToolSummary.agentLabel(u.input) }
            let ids = launched.map { Self.subagentTaskId($0.id) }
            for id in ids { agentLaunches[id] = ids }
            for u in a.toolUses {
                // Claude's duet calls (delegate, await, answer…) show as the messages they carry.
                if ToolSummary.isDialogue(u.name) { dialogueToolUses[u.id] = u.name; continue }
                // A subagent call's row gives way to its TASK card when the hub sends one (see .dialogue).
                addRow(.tool(id: "t\(a.turn)-u\(u.id)", name: u.name, summary: ToolSummary.text(u.name, u.input), edit: FileEdit(tool: u.name, input: u.input)), to: i)
            }
            if let last = a.toolUses.last {
                setPhase(last.name == "mcp__duet__await_workers" || ToolSummary.isSubagent(last.name) ? .workers(max(1, leadActiveTasks())) : .tool(last.name))
            }
        case .toolResult(let r):
            withTurn(r.turn) { $0.items.append(.toolResult(id: item(), preview: r.preview, isError: r.isError)) }
            let i = leadConversation(e)
            if tasks[Self.subagentTaskId(r.toolUseId)]?.isClaude == true {
                // A subagent's report: its RESULT card already shows it.
            } else if let name = dialogueToolUses[r.toolUseId] {
                // Its outcome arrives as messages; only a failure needs its own line.
                if r.isError { addRow(.note(id: "t\(r.turn)-r\(r.toolUseId)", text: "\(ToolSummary.displayName(name)) failed: \(ToolSummary.resultText(r.preview))"), to: i) }
            } else {
                // A rejected call's result is the rejection note, which its card already shows.
                let rejected = approvalByToolUse[r.toolUseId].flatMap { resolvedApprovals[$0] }?.decision == "deny"
                if !rejected { addRow(.toolResult(id: "t\(r.turn)-r\(r.toolUseId)", preview: ToolSummary.resultText(r.preview) + (r.tail.map { "\n…\n" + ToolSummary.resultText($0) } ?? ""), isError: r.isError), to: i) }
            }
            if case .approval = leadStatus.phase {} else { setPhase(.thinking) }
        case .approvalRequest(let a):
            openApprovals[a.id] = a
            approvals[a.id] = a
            withTurn(a.turn) { $0.items.append(.approval(id: item(), a)) }
            // The card stands in for its tool-call row (same place in the thread).
            let i = leadConversation(e)
            let row = LeadRow.approval(id: "t\(a.turn)-a\(a.id)", approvalId: a.id)
            if let tid = a.toolUseId {
                approvalByToolUse[tid] = a.id
                putRow(row, in: i) { $0.id == "t\(a.turn)-u\(tid)" }
            } else {
                addRow(row, to: i)
            }
            addAttention(.approval(a))
            setPhase(.approval)
        case .approvalResolved(let r):
            let req = openApprovals[r.id]
            openApprovals[r.id] = nil
            resolvedApprovals[r.id] = r
            removeAttention("a-\(r.id)")
            if leadStatus.phase == .approval, !attention.contains(where: { if case .approval = $0 { true } else { false } }) {
                setPhase(r.decision == "allow" ? .tool(req?.tool ?? "tool") : .thinking)
            }
        case .turnEnd(let t):
            flushStreaming()
            withTurn(t.turn) { $0.end = t; $0.streaming = "" }
            if liveTurn == t.turn { liveText = ""; liveTurn = nil }
            addRow(.footer(id: "t\(t.turn)-end", end: t), to: leadConversation(e))
            leadStatus = LeadStatus()
            // Stopping was your own tap, already felt.
            if !t.interrupted { feel(t.isError ? .failed : .replied) }
        case .effort(let ef): effort = ef.level
        case .interrupt(let i):
            withTurn(i.turn) { $0.items.append(.note(id: item(), "Interrupted by \(i.by)")) }
            addRow(.note(id: "t\(i.turn)-x\(item())", text: "Interrupted by \(i.by)"), to: leadConversation(e))
        case .error(let er): errors.append(er.message)
        case .fleet(let f): workers = f.workers
        case .modelCatalog(let c): catalog = c.models
        case .leadInfo(let i):
            leadInfo = i; effort = i.effort
            if let id = i.conversationId { switchCurrent(to: id) }
            if let cur = currentConversationId.flatMap(index(of:)), let cwd = i.cwd { conversations[cur].cwd = cwd }
        case .context(let c):
            let n = turns.last?.id ?? 0
            let text = switch c.action {
            case "cleared": "Context cleared by \(c.by)"
            case "resumed": "Resumed by \(c.by)"
            case "folder": "Moved to \(Paths.short(c.path ?? "?")) by \(c.by); the conversation carries on there"
            default: "Compacted by \(c.by)\(c.preTokens.map { ": \($0.formatted()) → \((c.postTokens ?? 0).formatted()) tokens" } ?? "")"
            }
            withTurn(n) { $0.items.append(.note(id: item(), text)) }
            switch c.action {
            case "cleared":
                // A new conversation starts an empty thread; the one before stays in the list. Clearing a conversation
                // nothing was said in adds none: that one just takes the new id.
                let note = LeadRow.note(id: "t\(n)-c\(item())", text: "New conversation, started by \(c.by)")
                let cur = currentConversationId.flatMap(index(of:))
                let empty = cur.map { !conversations[$0].hasContent } ?? true
                if let id = e.conversationId {
                    if empty, let from = currentConversationId, index(of: id) == nil { rekey(from: from, to: id) } else { switchCurrent(to: id) }
                } else if !empty || cur == nil {
                    switchCurrent(to: newProvisional())
                }
                let i = index(of: currentConversationId!)!
                conversations[i].rows = [note]
                conversations[i].lastActivity = eventTime
            case "resumed":
                if let id = e.conversationId ?? c.sessionId { switchCurrent(to: id) }
                addRow(.note(id: "t\(n)-c\(item())", text: text), to: leadConversation(e))
            default:
                let i = leadConversation(e)
                if c.action == "folder", let path = c.path { conversations[i].cwd = path }
                addRow(.note(id: "t\(n)-c\(item())", text: text), to: i)
            }
        case .task(let t):
            let i = asyncConversation(e, taskId: t.taskId)
            if tasks[t.taskId] == nil {
                taskOrder.append(t.taskId)
                conversations[i].taskIds.append(t.taskId)
                conversations[i].lastActivity = eventTime
                taskConversation[t.taskId] = conversations[i].id
            }
            // An event that leaves its state as it was (a subagent going to the background) adds no line to its thread.
            let changed = tasks[t.taskId]?.state != t.state
            let merged = merge(tasks[t.taskId], t)
            tasks[t.taskId] = merged
            if changed, ["done", "failed", "cancelled", "running", "awaiting_swap"].contains(t.state) { line(t.taskId, .state(id: item(), merged)) }
            if ["done", "failed", "cancelled"].contains(t.state) {
                taskEndedAt[t.taskId] = eventTime
                // A finished task closes its open question.
                for q in attention { if case .question(let d) = q, d.taskId == t.taskId { removeAttention(q.id) } }
                workerActivity[t.worker] = nil
                // An older hub's stand-in for a subagent gone to the background isn't an end: no result yet, and no tap in
                // the hand. Nor is a subagent's own subagent's end news of its own: its parent's end is.
                let news = t.state != "cancelled" && !merged.inBackground && merged.parentId == nil
                if news { recentResults.insert(merged, at: 0); if recentResults.count > 12 { recentResults.removeLast() } }
                if news {
                    if merged.isClaude {
                        // Claude's subagents tap once, when the last one started with it ends: not once per agent.
                        let launch = agentLaunches[t.taskId] ?? [t.taskId]
                        if launch.allSatisfy(isEnded) {
                            feel(launch.contains { tasks[$0]?.state == "failed" } ? .taskFailed : .taskDone)
                        }
                    } else {
                        feel(t.state == "done" ? .taskDone : .taskFailed)
                    }
                }
            } else if t.state == "running", changed {
                workerActivity[t.worker] = "Starting…"
            }
        case .taskProgress(let p):
            if let text = p.text { line(p.taskId, .text(id: item(), text)) }
            for u in p.toolUses ?? [] { touch(u.name, u.input, by: p.worker) }
            let calls: [String]
            if let uses = p.toolUses {
                calls = uses.filter { !ToolSummary.isDialogue($0.name) }.map { ToolSummary.line($0.name, $0.input) }
            } else if let tools = p.tools {
                // Older hubs: "name {json}" lines, the duet tools included (their messages show as cards).
                let shown = tools.filter { !ToolSummary.isDialogue($0) }
                if shown.isEmpty { skipToolResult.insert(p.taskId) }
                calls = shown.map(ToolSummary.legacyLine)
            } else {
                calls = []
            }
            if !calls.isEmpty { line(p.taskId, .tools(id: item(), calls)) }
            if let r = p.toolResult, skipToolResult.remove(p.taskId) == nil { line(p.taskId, .toolResult(id: item(), ToolSummary.resultText(r))) }
            if let last = calls.last { workerActivity[p.worker] = String(last.prefix(80)) }
            else if let text = p.text { workerActivity[p.worker] = String(text.split(separator: "\n").first?.prefix(80) ?? "") }
        case .workerRequest: break // tok/s arrives on the fleet card
        case .swapRequest(let s):
            swaps.append(s)
            addAttention(.swap(s))
        case .swapResolved(let s):
            resolvedSwaps.insert(s.id)
            removeAttention("s-\(s.id)")
        case .dialogue(let d):
            cards.append(d)
            if d.kind == "ANSWER", let q = d.replyTo, d.refused == nil { answeredQuestions.insert(q); removeAttention("q-\(q)") }
            // Questions to you (tasks you delegated) need you; the lead answers its own, unless it passes one on to you.
            if d.kind == "QUESTION", d.refused == nil, d.to != "lead" { addAttention(.question(d)) }
            if d.kind == "ESCALATE", let q = d.replyTo, !answeredQuestions.contains(q), !isEnded(d.taskId),
               !attention.contains(where: { $0.id == "q-\(q)" }), let question = cards.last(where: { $0.id == q && $0.kind == "QUESTION" }) {
                addAttention(.question(question))
            }
            line(d.taskId, .card(id: item(), d))
            // Claude's own exchanges with its workers show in its thread too. A subagent's TASK card takes the
            // place of the Agent call's row.
            if d.from == "lead" || d.to == "lead" {
                let i = asyncConversation(e, taskId: d.taskId)
                let row = LeadRow.agent(id: "d-\(d.id)", message: d)
                if d.taskId.hasPrefix("sa-"), d.kind == "TASK" {
                    let suffix = String(d.taskId.dropFirst(3))
                    putRow(row, in: i) { if case .tool = $0 { $0.id.hasSuffix(suffix) } else { false } }
                } else {
                    addRow(row, to: i)
                }
            }
        case .diagram(let g):
            let i = leadConversation(e)
            if diagrams[g.id] == nil {
                diagramOrder.append(g.id)
                conversations[i].diagramIds.append(g.id)
                diagramConversation[g.id] = conversations[i].id
            }
            if (diagrams[g.id]?.version ?? 0) <= g.version { diagrams[g.id] = g }
            diagramVersions[g.id, default: []].append(g)
            addRow(.diagram(id: "g-\(g.id)-v\(g.version)", diagram: g), to: i)
            feel(.diagram)
        case .notes(let n):
            addRow(.notes(id: "n-\(e.seq)", by: n.by, notes: n.notes), to: leadConversation(e))
        case .annotation(let a):
            annotations[a.annotation.id] = a.annotation.deleted == true ? nil : a.annotation
        case .sideChat(let c):
            // Deleted with its note: gone from the side chats and from its conversation.
            if c.deleted == true {
                sideChats[c.chatId] = nil
                pendingSideDeltas[c.chatId] = nil
                for j in conversations.indices { conversations[j].sideChatIds.removeAll { $0 == c.chatId } }
                break
            }
            let i = asyncConversation(e)
            if sideChats[c.chatId] == nil {
                sideChats[c.chatId] = SideChat(id: c.chatId, title: c.title, model: c.model, by: c.by, about: c.about, state: c.state, startedAt: eventTime, conversationId: conversations[i].id)
                conversations[i].sideChatIds.append(c.chatId)
            }
            sideChats[c.chatId]!.title = c.title
            sideChats[c.chatId]!.model = c.model
            sideChats[c.chatId]!.state = c.state
            sideChats[c.chatId]!.activity = c.activity
            sideChats[c.chatId]!.error = c.error
            if let a = c.about { sideChats[c.chatId]!.about = a }
            if let f = c.forked { sideChats[c.chatId]!.forked = f }
            if let n = c.annotationId { sideChats[c.chatId]!.annotationId = n }
            // Done (or stopped): what streamed is in its messages now.
            if c.state != "answering" { sideChats[c.chatId]!.streaming = ""; pendingSideDeltas[c.chatId] = nil }
        case .sideMessage(let m):
            guard sideChats[m.chatId] != nil else { break }
            sideChats[m.chatId]!.messages.append(m)
            // A finished reply takes the place of what streamed of it.
            if !m.isUser { sideChats[m.chatId]!.streaming = ""; pendingSideDeltas[m.chatId] = nil }
        case .conversationImport(let c):
            conversations[asyncConversation(e)].imported = c
        case .sideDelta(let d):
            guard sideChats[d.chatId] != nil else { break }
            pendingSideDeltas[d.chatId, default: ""] += d.text
            scheduleFlush()
        case .dialogueState(let s): dialogueState = s
        case .plan(let p):
            let i = asyncConversation(e)
            conversations[i].plan = p.steps
            conversations[i].lastActivity = eventTime
        case .notice(let n): notices.append(n.text)
        case .queued(let q):
            // Taken: its `user` event, right after, is the message's row. Dropped: a row says so, with its words.
            let i = asyncConversation(e)
            let held = conversations[i].waiting.first { $0.id == q.id }
            conversations[i].waiting.removeAll { $0.id == q.id }
            if q.state == "waiting" { conversations[i].waiting.append(q) }
            if q.state == "dropped" {
                addRow(.note(id: "q-\(q.id)", text: "Not sent to Claude (\(q.reason ?? "dropped")): “\(held?.text ?? "")”"), to: i)
            }
        case .unknown: break
        }
    }

    /// Tools that change a file, and where they say which.
    private static let fileWriters: [String: String] = ["Edit": "file_path", "MultiEdit": "file_path", "Write": "file_path", "NotebookEdit": "notebook_path"]

    /// Note a change to a file by Claude (`lead`) or a worker, from one of its tool calls.
    private func touch(_ tool: String, _ input: JSONValue, by: String) {
        guard let key = Self.fileWriters[tool], case .object(let o) = input, let path = o[key]?.stringValue, path.hasPrefix("/") else { return }
        fileTouches[path] = FileTouch(by: by, tool: tool, at: eventTime)
    }

    /// A whole reply's text, from its chunks (a long reply is shown in several).
    public func messageText(_ message: String) -> String {
        for c in conversations {
            let parts = c.rows.compactMap { row -> String? in
                if case .chunk(_, let m, _, _, _, let text) = row, m == message { return text }
                return nil
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        return ""
    }

    /// A conversation's side chats, newest first.
    public func sideChats(in conversationId: String) -> [SideChat] {
        (conversation(conversationId)?.sideChatIds ?? []).reversed().compactMap { sideChats[$0] }
    }

    /// The latest change to each file at or under a folder, newest first.
    public func touches(under folder: String) -> [(path: String, touch: FileTouch)] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return fileTouches.filter { $0.key == folder || $0.key.hasPrefix(prefix) }.map { ($0.key, $0.value) }.sorted { $0.1.at > $1.1.at }
    }

    /// Questions still waiting for an answer.
    public var openQuestions: [DialogueEvent] {
        cards.filter { $0.kind == "QUESTION" && $0.refused == nil && !answeredQuestions.contains($0.id) && !isEnded($0.taskId) }
    }

    public var openSwaps: [SwapRequestEvent] { swaps.filter { !resolvedSwaps.contains($0.id) } }

    private func isEnded(_ taskId: String) -> Bool {
        guard let s = tasks[taskId]?.state else { return false }
        return ["done", "failed", "cancelled"].contains(s)
    }

    // Task events carry only what changed; keep the earlier fields.
    private func merge(_ old: TaskEvent?, _ new: TaskEvent) -> TaskEvent {
        guard let old else { return new }
        return TaskEvent(taskId: new.taskId, worker: new.worker, state: new.state, prompt: new.prompt ?? old.prompt, by: new.by ?? old.by,
                         effort: new.effort ?? old.effort, queuePosition: new.queuePosition ?? old.queuePosition, cwd: new.cwd ?? old.cwd,
                         result: new.result ?? old.result, evidence: new.evidence ?? old.evidence, error: new.error ?? old.error, stats: new.stats ?? old.stats,
                         files: new.files ?? old.files, profile: new.profile ?? old.profile, stopped: new.stopped ?? old.stopped,
                         label: new.label ?? old.label, background: new.background ?? old.background, parentId: new.parentId ?? old.parentId,
                         depth: new.depth ?? old.depth)
    }
}

/// Something that just happened, live: Claude replied or failed, a worker finished, a diagram arrived.
public struct Beat: Equatable, Sendable {
    public enum Moment: Sendable { case replied, failed, taskDone, taskFailed, diagram }
    public let moment: Moment
    /// Counts up, so the same moment twice in a row is still a change.
    public let n: Int
}

/// Paths on the hub machine, for showing.
public enum Paths {
    /// `/home/you/projects/duet` → `~/projects/duet` (any home folder: the hub machine's user isn't known to the app).
    public static func short(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        let homeDepth = parts.first == "home" && parts.count >= 2 ? 2 : parts.first == "root" ? 1 : 0
        guard homeDepth > 0 else { return path }
        let rest = parts.dropFirst(homeDepth).joined(separator: "/")
        return rest.isEmpty ? "~" : "~/" + rest
    }

    /// The last component: `duet` for `~/projects/duet`, `/` for the root.
    public static func name(_ path: String) -> String {
        path == "/" ? "/" : path.split(separator: "/").last.map(String.init) ?? path
    }

    /// `parent` and `name` joined.
    public static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    /// Each folder from the root down: `/`, `/home`, `/home/you`, ….
    public static func ancestors(_ path: String) -> [String] {
        var out = ["/"]
        var cur = ""
        for part in path.split(separator: "/") { cur += "/" + part; out.append(cur) }
        return out
    }
}

/// Where a note's lines are now: the file may have changed since it was written. Its lines are found again by their
/// code (whitespace ignored), nearest where they were; nil when the code isn't there any more.
public enum Reanchor {
    static func norm(_ s: Substring) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    public static func place(_ l: InkLines, in text: [Substring]) -> ClosedRange<Int>? {
        let span = max(0, l.end - l.start)
        let want = (l.code ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(norm)
        // Nothing to check against: where it was, if the file still has those lines.
        guard want.contains(where: { !$0.isEmpty }) else {
            return l.start >= 1 && l.start <= text.count ? l.start...min(text.count, l.start + span) : nil
        }
        let lines = text.map(norm)
        func matches(at i: Int, count: Int) -> Bool {
            guard i + count <= lines.count else { return false }
            for k in 0..<count {
                // The page kept at most 140 characters of a line.
                let w = want[k], have = lines[i + k]
                if w.isEmpty ? !have.isEmpty : !have.hasPrefix(w) { return false }
            }
            return true
        }
        let nearest = { (hits: [Int]) in hits.min { abs($0 + 1 - l.start) < abs($1 + 1 - l.start) } }
        // All its lines, else just its first.
        let all = (0..<lines.count).filter { matches(at: $0, count: want.count) }
        let first = all.isEmpty ? (0..<lines.count).filter { matches(at: $0, count: 1) } : all
        guard let i = nearest(first) else { return nil }
        return (i + 1)...min(lines.count, i + 1 + span)
    }
}
