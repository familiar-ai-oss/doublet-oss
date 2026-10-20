import Foundation
import Testing
@testable import DuetKit

private func ev(_ seq: Int, _ body: HubEvent.Body, in conversation: String? = nil) -> HubEvent {
    HubEvent(seq: seq, ts: 1_700_000_000_000 + Double(seq), body: body, conversationId: conversation)
}
private func task(_ id: String, _ worker: String, _ state: String, prompt: String? = nil, result: String? = nil) -> TaskEvent {
    TaskEvent(taskId: id, worker: worker, state: state, prompt: prompt, by: "lead", effort: nil, queuePosition: nil, result: result, evidence: nil, error: nil, stats: nil)
}

@MainActor
@Test func approvalEntersAndLeavesAttentionAndDrivesStatus() {
    let s = DuetStore()
    s.apply(ev(1, .user(UserEvent(turn: 1, text: "run it", by: "mac"))))
    s.apply(ev(2, .turnStart(TurnStartEvent(turn: 1))))
    #expect(s.leadStatus.phase == .thinking && s.leadStatus.turn == 1)
    let a = ApprovalRequestEvent(id: "ab12", turn: 1, tool: "Bash", input: ["command": .string("touch x")], title: nil, description: nil)
    s.apply(ev(3, .approvalRequest(a)))
    #expect(s.attention.map(\.id) == ["a-ab12"])
    #expect(s.leadStatus.phase == .approval)
    #expect(s.leadRows.contains(.approval(id: "t1-aab12", approvalId: "ab12")))
    s.apply(ev(4, .approvalResolved(ApprovalResolvedEvent(id: "ab12", decision: "allow", edited: true, by: "iphone", message: nil))))
    #expect(s.attention.isEmpty)
    #expect(s.leadStatus.phase == .tool("Bash"))
    s.apply(ev(5, .turnEnd(TurnEndEvent(turn: 1, subtype: "success", isError: false, interrupted: false, durationMs: 900, numTurns: 2))))
    #expect(!s.leadStatus.busy)
}

@MainActor
@Test func questionsToYouNeedYouButTheLeadsDoNot() {
    let s = DuetStore()
    s.apply(ev(1, .task(TaskEvent(taskId: "t-1", worker: "qwen-27b", state: "running", prompt: "x", by: "mac", effort: nil, queuePosition: nil, result: nil, evidence: nil, error: nil, stats: nil))))
    s.apply(ev(2, .dialogue(DialogueEvent(id: "q-1", kind: "QUESTION", taskId: "t-1", from: "qwen-27b", to: "mac", text: "English or French?", replyTo: nil, options: nil, refused: nil))))
    s.apply(ev(3, .dialogue(DialogueEvent(id: "q-2", kind: "QUESTION", taskId: "t-9", from: "qwen-9b", to: "lead", text: "Which word?", replyTo: nil, options: nil, refused: nil))))
    #expect(s.attention.map(\.id) == ["q-q-1"])
    #expect(s.workerActivity["qwen-27b"] == "Starting…")
    s.apply(ev(4, .task(TaskEvent(taskId: "t-1", worker: "qwen-27b", state: "cancelled", prompt: nil, by: nil, effort: nil, queuePosition: nil, result: nil, evidence: nil, error: nil, stats: nil))))
    #expect(s.attention.isEmpty, "a finished task's question no longer needs you")
}

@MainActor
@Test func liveTextIsSeparateFromFinishedRows() {
    let s = DuetStore()
    s.apply(ev(1, .user(UserEvent(turn: 1, text: "count", by: "t"))))
    s.apply(ev(2, .turnStart(TurnStartEvent(turn: 1))))
    let before = s.leadRows
    for i in 3...2002 { s.apply(ev(i, .textDelta(TextDeltaEvent(turn: 1, text: "\(i - 2)\n")))) }
    s.flushStreaming()
    #expect(s.leadRows == before, "streaming never touches the finished rows")
    #expect(s.liveTurn == 1 && s.liveText.split(separator: "\n").count == 2000)
    #expect(s.leadStatus.phase == .writing)
    s.apply(ev(2003, .assistant(AssistantEvent(turn: 1, text: s.liveText, toolUses: []))))
    #expect(s.liveText.isEmpty && s.liveTurn == nil)
    let chunks = s.leadRows.compactMap { if case .chunk(_, _, let i, let n, let lines, _) = $0 { (i, n, lines) } else { nil } }
    #expect(chunks.count == 34 && chunks.allSatisfy { $0.1 == 34 }, "2,000 lines become 34 lazy 60-line chunks")
    #expect(Set(s.leadRows.map(\.id)).count == s.leadRows.count, "row ids are unique")
}

@MainActor
@Test func replaysEndIdleWithNothingWaiting() throws {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("../protocol/fixtures").standardized
    for file in ["p1.jsonl", "p2.jsonl", "p3.jsonl", "p5.jsonl", "p7.jsonl"] {
        let s = DuetStore()
        let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
        for line in text.split(separator: "\n") {
            if case .event(let e) = try JSONDecoder().decode(ServerFrame.self, from: Data(line.utf8)) { s.apply(e) }
        }
        s.flushStreaming()
        #expect(!s.leadStatus.busy, "\(file) ends idle")
        #expect(s.attention.isEmpty, "\(file): nothing left waiting: \(s.attention.map(\.id))")
        #expect(Set(s.leadRows.map(\.id)).count == s.leadRows.count, "\(file): unique row ids")
    }
}

@Test func olderAndMalformedEventsNeverBreakTheStream() throws {
    // A Phase 2 hub's fleet event (no tokPerS / verifiedEffort) still decodes.
    let old = #"{"seq":12,"ts":1,"type":"fleet","workers":[{"id":"qwen-9b","label":"9B","backend":"llmd","model":"m","enabled":true,"available":true,"loaded":true,"effort":"off","effortLevels":["off","on"],"running":null,"queue":[]}]}"#
    guard case .event(let e) = try JSONDecoder().decode(ServerFrame.self, from: Data(old.utf8)), case .fleet(let f) = e.body else { Issue.record("not a fleet event"); return }
    #expect(f.workers.first?.verifiedEffort == nil)
    // A malformed event keeps its seq and decodes as unknown instead of throwing.
    let bad = #"{"seq":13,"ts":1,"type":"session","state":42}"#
    guard case .event(let b) = try JSONDecoder().decode(ServerFrame.self, from: Data(bad.utf8)) else { Issue.record("not an event"); return }
    #expect(b.seq == 13)
    #expect(b.body == .unknown(type: "session (undecodable)"))
}

@MainActor
@Test func anApprovalCardTakesItsToolCallsPlaceAndARejectionIsNotRepeated() {
    let s = DuetStore()
    s.apply(ev(1, .user(UserEvent(turn: 1, text: "go", by: "mac"))))
    s.apply(ev(2, .turnStart(TurnStartEvent(turn: 1))))
    s.apply(ev(3, .assistant(AssistantEvent(turn: 1, text: "", toolUses: [ToolUse(id: "tu1", name: "Bash", input: .object(["command": .string("touch c")]))]))))
    #expect(s.leadRows.last == .tool(id: "t1-utu1", name: "Bash", summary: "touch c"))
    var a = ApprovalRequestEvent(id: "ap1", turn: 1, tool: "Bash", input: ["command": .string("touch c")], title: nil, description: nil)
    a.toolUseId = "tu1"
    s.apply(ev(4, .approvalRequest(a)))
    #expect(s.leadRows.filter { if case .tool = $0 { true } else { false } }.isEmpty, "one row per call: the card")
    #expect(s.leadRows.last == .approval(id: "t1-aap1", approvalId: "ap1"))
    s.apply(ev(5, .approvalResolved(ApprovalResolvedEvent(id: "ap1", decision: "deny", edited: false, by: "iphone", message: "skip c"))))
    s.apply(ev(6, .toolResult(ToolResultEvent(turn: 1, toolUseId: "tu1", isError: true, preview: "skip c"))))
    #expect(s.leadRows.last == .approval(id: "t1-aap1", approvalId: "ap1"), "the note is on the card, not repeated as a result")
}

@MainActor
@Test func oldApprovalEventsWithoutToolIdsStillAppendTheirCard() throws {
    let line = #"{"seq":7,"ts":1700000000000,"type":"approval_request","id":"x1","turn":1,"tool":"Bash","input":{"command":"ls"}}"#
    let e = try JSONDecoder().decode(HubEvent.self, from: Data(line.utf8))
    guard case .approvalRequest(let a) = e.body else { Issue.record("decoded as \(e.body)"); return }
    #expect(a.toolUseId == nil && !a.needsCare)
    let s = DuetStore()
    s.apply(ev(1, .user(UserEvent(turn: 1, text: "go", by: "mac"))))
    s.apply(ev(2, .assistant(AssistantEvent(turn: 1, text: "", toolUses: [ToolUse(id: "tu9", name: "Bash", input: .object(["command": .string("ls")]))]))))
    s.apply(e)
    #expect(s.leadRows.suffix(2).map(\.id) == ["t1-utu9", "t1-ax1"])
}

@MainActor
@Test func waitingSinceIsTheOldestOpenItem() {
    let s = DuetStore()
    let t0 = 1_700_000_000_000.0
    func at(_ ms: Double, _ seq: Int, _ b: HubEvent.Body) { s.apply(HubEvent(seq: seq, ts: t0 + ms, body: b)) }
    at(0, 1, .user(UserEvent(turn: 1, text: "go", by: "mac")))
    at(10_000, 2, .approvalRequest(ApprovalRequestEvent(id: "a", turn: 1, tool: "Bash", input: [:], title: nil, description: nil)))
    at(25_000, 3, .swapRequest(SwapRequestEvent(id: "s", taskId: "t", worker: "qwen-9b", model: "m", device: "3060", evicts: [])))
    #expect(s.waitingSince == Date(timeIntervalSince1970: (t0 + 10_000) / 1000))
    at(30_000, 4, .approvalResolved(ApprovalResolvedEvent(id: "a", decision: "allow", edited: false, by: "mac", message: nil)))
    #expect(s.waitingSince == Date(timeIntervalSince1970: (t0 + 25_000) / 1000), "the swap is now the oldest")
    at(31_000, 5, .swapResolved(SwapResolvedEvent(id: "s", decision: "approve", by: "mac")))
    #expect(s.waitingSince == nil)
}

@Test func toolSummariesReadLikeTheCallNotItsJSON() {
    func j(_ o: [String: String]) -> JSONValue { .object(o.mapValues { .string($0) }) }
    #expect(ToolSummary.text("Bash", j(["command": "touch /tmp/a", "description": "Make a file"])) == "touch /tmp/a")
    #expect(ToolSummary.text("Bash", j(["command": "cd x\nmake test"])) == "cd x …")
    #expect(ToolSummary.text("Read", j(["file_path": "/srv/app/main.ts"])) == "/srv/app/main.ts")
    #expect(ToolSummary.text("Grep", j(["pattern": "TODO", "path": "src"])) == "TODO  in src")
    #expect(ToolSummary.text("mcp__duet__delegate", j(["worker": "qwen-9b", "task": "Write tests"])) == "Write tests")
    #expect(ToolSummary.text("Mystery", .object(["n": .number(3)])) == #"{"n":3}"#)
}

@MainActor
@Test func claudesExchangesWithItsWorkersReadAsMessagesNotToolCalls() {
    let s = DuetStore()
    func card(_ seq: Int, _ id: String, _ kind: String, _ from: String, _ to: String, _ text: String, options: [String]? = nil, replyTo: String? = nil) {
        s.apply(ev(seq, .dialogue(DialogueEvent(id: id, kind: kind, taskId: "t-1", from: from, to: to, text: text, replyTo: replyTo, options: options, refused: nil))))
    }
    s.apply(ev(1, .user(UserEvent(turn: 1, text: "have the 9B write a poem", by: "iphone"))))
    s.apply(ev(2, .assistant(AssistantEvent(turn: 1, text: "", toolUses: [ToolUse(id: "u1", name: "mcp__duet__delegate", input: .object(["worker": .string("qwen-9b"), "task": .string("Write a poem")]))]))))
    card(3, "t-a", "TASK", "lead", "qwen-9b", "Write a poem")
    s.apply(ev(4, .toolResult(ToolResultEvent(turn: 1, toolUseId: "u1", isError: false, preview: #"[{"type":"text","text":"Delegated as t-1."}]"#))))
    card(5, "q-a", "QUESTION", "qwen-9b", "lead", "Which GPU?", options: ["R9700", "RTX 3060"])
    card(6, "a-a", "ANSWER", "lead", "qwen-9b", "RTX 3060", replyTo: "q-a")
    card(7, "r-a", "RESULT", "qwen-9b", "lead", "Finished: wrote it")
    card(8, "s-x", "STEER", "iphone", "qwen-27b", "your own task, not Claude's")
    #expect(s.leadRows.map(\.id) == ["t1-p", "d-t-a", "d-q-a", "d-a-a", "d-r-a"], "no duet tool rows, no raw results, no human↔worker messages")
    #expect(s.attention.isEmpty, "Claude answers its own workers' questions")
    s.apply(ev(9, .assistant(AssistantEvent(turn: 1, text: "", toolUses: [ToolUse(id: "u2", name: "mcp__duet__delegate", input: .object([:]))]))))
    s.apply(ev(10, .toolResult(ToolResultEvent(turn: 1, toolUseId: "u2", isError: true, preview: #"[{"type":"text","text":"no worker is free, loaded and enabled"}]"#))))
    #expect(s.leadRows.last == .note(id: "t1-ru2", text: "duet.delegate failed: no worker is free, loaded and enabled"), "a failed call still shows")
}

@MainActor
@Test func workerProgressReadsLikeTheCallsNotTheirJSON() {
    let s = DuetStore()
    let calls: [ToolCall] = [ToolCall(name: "Edit", input: .object(["file_path": .string("/srv/greet.txt")])), ToolCall(name: "Bash", input: .object(["command": .string("git diff --stat")]))]
    var p = TaskProgressEvent(taskId: "t-1", worker: "qwen-27b", text: nil, tools: ["Edit {…}", "Bash {…}"], toolResult: nil)
    p.toolUses = calls
    s.apply(ev(1, .taskProgress(p)))
    #expect(s.taskLines["t-1"]?.last == .tools(id: 1, ["Edit  /srv/greet.txt", "Bash  git diff --stat"]))
    #expect(s.workerActivity["qwen-27b"] == "Bash  git diff --stat")
    // An older hub: duet calls and their results come as raw lines; they're dropped (the cards say it) or unwrapped.
    s.apply(ev(2, .taskProgress(TaskProgressEvent(taskId: "t-2", worker: "qwen-9b", text: nil, tools: [#"mcp__duet__ask_lead {"question":"Which GPU?""#], toolResult: nil))))
    s.apply(ev(3, .taskProgress(TaskProgressEvent(taskId: "t-2", worker: "qwen-9b", text: nil, tools: nil, toolResult: #"[{"type":"text","text":"Answer: RTX 3060"}]"#))))
    s.apply(ev(4, .taskProgress(TaskProgressEvent(taskId: "t-2", worker: "qwen-9b", text: nil, tools: [#"Read {"file_path":"/srv/a.txt"}"#], toolResult: nil))))
    s.apply(ev(5, .taskProgress(TaskProgressEvent(taskId: "t-2", worker: "qwen-9b", text: nil, tools: nil, toolResult: #"[{"type":"text","text":"line one\nline two"}]"#))))
    #expect(s.taskLines["t-2"] == [.tools(id: 2, ["Read  /srv/a.txt"]), .toolResult(id: 3, "line one\nline two")])
}

@Test func toolNamesAndResultsReadPlainly() {
    #expect(ToolSummary.displayName("mcp__duet__ask_lead") == "duet.ask_lead")
    #expect(ToolSummary.displayName("Bash") == "Bash")
    #expect(ToolSummary.legacyLine(#"Write {"file_path":"/srv/x.swift","content":"import Foundation\nstruct"#) == #"Write  {"file_path":"/srv/x.swift","content":"import Foundation\nstruct"#, "cut-off JSON is shown as sent")
    #expect(ToolSummary.legacyLine(#"Bash {"command":"ls -la"}"#) == "Bash  ls -la")
    #expect(ToolSummary.resultText(#"[{"type":"text","text":"Recorded. You can finish now."}]"#) == "Recorded. You can finish now.")
    #expect(ToolSummary.resultText(#"[{"type":"text","text":"cut short at 500 chara"#) == "cut short at 500 chara", "an older hub's cut-off result")
    #expect(ToolSummary.resultText("plain output") == "plain output")
}

@Test func aResultSplitsIntoReportOutputAndChanges() {
    let r = ResultParts("Finished: Wrote the poem.\nWorker's output:\n**RTX 3060**\nSilicon hums\nHub-measured changes:\nno changes")
    #expect(r.ok && r.summary == "Wrote the poem." && r.output == "**RTX 3060**\nSilicon hums" && r.changes == "no changes")
    let old = ResultParts("Failed: crashed\nHub-measured changes:\ndiff --stat:\n a.txt | 2 +-")
    #expect(!old.ok && old.summary == "crashed" && old.output == nil && old.changes == "diff --stat:\n a.txt | 2 +-")
}

@MainActor
@Test func clearStartsAnEmptyThreadAndKeepsTheEarlierOneAside() {
    let s = DuetStore()
    s.apply(ev(1, .user(UserEvent(turn: 1, text: "first question", by: "mac"))))
    s.apply(ev(2, .context(ContextEvent(action: "cleared", by: "mac", preTokens: nil, postTokens: nil))))
    #expect(s.leadRows.count == 1)
    if case .note(_, let text) = s.leadRows.first { #expect(text == "New conversation, started by mac") } else { Issue.record("no note") }
    #expect(s.earlierConversations == 1)
    #expect(s.earlierRows.contains(.prompt(id: "t1-p", text: "first question", by: "mac")))
    // Clearing an empty conversation doesn't count as another one.
    s.apply(ev(3, .context(ContextEvent(action: "cleared", by: "iphone", preTokens: nil, postTokens: nil))))
    #expect(s.earlierConversations == 1)
    s.apply(ev(4, .user(UserEvent(turn: 2, text: "second", by: "iphone"))))
    #expect(s.leadRows.contains(.prompt(id: "t2-p", text: "second", by: "iphone")))
    // Compacting keeps the conversation.
    s.apply(ev(5, .context(ContextEvent(action: "compacted", by: "mac", preTokens: 9000, postTokens: 2000))))
    #expect(s.leadRows.contains(.prompt(id: "t2-p", text: "second", by: "iphone")))
}

@MainActor
@Test func taggedEventsGroupByConversationAndATasksEventsKeepTheirs() {
    let s = DuetStore()
    s.apply(ev(1, .session(SessionEvent(state: "starting", sessionId: "A", model: nil, account: nil, reason: nil)), in: "A"))
    s.apply(ev(2, .user(UserEvent(turn: 1, text: "write a poem", by: "mac")), in: "A"))
    s.apply(ev(3, .task(task("t-1", "qwen-9b", "running", prompt: "Write a poem")), in: "A"))
    s.apply(ev(4, .diagram(DiagramEvent(id: "g1", version: 1, title: "Flow", kind: .mermaid, source: "graph TD")), in: "A"))
    s.apply(ev(5, .context(ContextEvent(action: "cleared", by: "mac", preTokens: nil, postTokens: nil)), in: "B"))
    s.apply(ev(6, .user(UserEvent(turn: 2, text: "something else", by: "mac")), in: "B"))
    // The worker finishes after the Clear: its events still belong to A.
    s.apply(ev(7, .task(task("t-1", "qwen-9b", "done", result: "Done")), in: "A"))
    s.apply(ev(8, .dialogue(DialogueEvent(id: "r-1", kind: "RESULT", taskId: "t-1", from: "qwen-9b", to: "lead", text: "Finished: done", replyTo: nil, options: nil, refused: nil)), in: "A"))
    #expect(s.conversations.map(\.id) == ["A", "B"])
    #expect(s.currentConversationId == "B")
    #expect(s.conversationOf(taskId: "t-1") == "A" && s.conversationOf(diagramId: "g1") == "A")
    #expect(s.conversation("A")?.taskIds == ["t-1"] && s.conversation("A")?.diagramIds == ["g1"])
    #expect(s.rows(for: "A").contains { $0.id == "d-r-1" }, "the result card is in the conversation that delegated")
    #expect(!s.leadRows.contains { $0.id == "d-r-1" })
    #expect(s.leadRows.map(\.id).contains("t2-p"))
    #expect(s.conversation("A")?.firstPrompt == "write a poem" && s.conversation("B")?.firstPrompt == "something else")
    #expect(s.earlierConversations == 1)
}

@MainActor
@Test func anOlderHubsLogFallsBackToTheSegmentAndIsNamedWhenTheIdArrives() {
    let s = DuetStore()
    s.apply(ev(1, .session(SessionEvent(state: "starting", sessionId: nil, model: nil, account: nil, reason: nil))))
    s.apply(ev(2, .user(UserEvent(turn: 1, text: "hello", by: "mac"))))
    s.apply(ev(3, .task(task("t-1", "qwen-9b", "running"))))
    #expect(s.conversations.count == 1 && s.conversations[0].isProvisional)
    s.apply(ev(4, .session(SessionEvent(state: "ready", sessionId: "X", model: nil, account: nil, reason: nil))))
    #expect(s.conversations.map(\.id) == ["X"] && s.currentConversationId == "X")
    #expect(s.conversationOf(taskId: "t-1") == "X", "what arrived before the name moves with it")
    #expect(s.rows(for: "X").contains(.prompt(id: "t1-p", text: "hello", by: "mac")))
    s.apply(ev(5, .context(ContextEvent(action: "cleared", by: "mac", preTokens: nil, postTokens: nil))))
    s.apply(ev(6, .user(UserEvent(turn: 2, text: "again", by: "mac"))))
    s.apply(ev(7, .session(SessionEvent(state: "ready", sessionId: "Y", model: nil, account: nil, reason: nil))))
    #expect(s.conversations.map(\.id) == ["X", "Y"] && s.currentConversationId == "Y")
    #expect(s.leadRows.contains(.prompt(id: "t2-p", text: "again", by: "mac")))
}

@MainActor
@Test func resumingMakesAnEarlierConversationLiveAgain() {
    let s = DuetStore()
    s.apply(ev(1, .user(UserEvent(turn: 1, text: "first", by: "mac")), in: "A"))
    s.apply(ev(2, .context(ContextEvent(action: "cleared", by: "mac", preTokens: nil, postTokens: nil)), in: "B"))
    s.apply(ev(3, .user(UserEvent(turn: 2, text: "second", by: "mac")), in: "B"))
    var resumed = ContextEvent(action: "resumed", by: "ipad", preTokens: nil, postTokens: nil)
    resumed.sessionId = "A"
    s.apply(ev(4, .context(resumed), in: "A"))
    #expect(s.currentConversationId == "A")
    if case .note(_, let text) = s.leadRows.last { #expect(text == "Resumed by ipad") } else { Issue.record("no note") }
    #expect(s.earlierConversations == 1)
    s.apply(ev(5, .user(UserEvent(turn: 3, text: "third", by: "ipad")), in: "A"))
    #expect(s.rows(for: "A").contains(.prompt(id: "t3-p", text: "third", by: "ipad")))
    #expect(s.conversation("A")?.turnIds == [1, 3])
    // Clearing a conversation nothing was said in adds none.
    s.apply(ev(6, .context(ContextEvent(action: "cleared", by: "mac", preTokens: nil, postTokens: nil)), in: "C"))
    s.apply(ev(7, .context(ContextEvent(action: "cleared", by: "mac", preTokens: nil, postTokens: nil)), in: "D"))
    #expect(s.conversations.map(\.id) == ["A", "B", "D"])
}

@Test func conversationIdRoundTripsAtTheEventLevel() throws {
    let line = #"{"seq":9,"ts":1700000000000,"type":"context","action":"resumed","by":"mac","sessionId":"f35790a0-07ad-4715-9450-8b37023a3197","conversationId":"f35790a0-07ad-4715-9450-8b37023a3197"}"#
    let e = try JSONDecoder().decode(HubEvent.self, from: Data(line.utf8))
    #expect(e.conversationId == "f35790a0-07ad-4715-9450-8b37023a3197")
    guard case .context(let c) = e.body else { Issue.record("decoded as \(e.body)"); return }
    #expect(c.action == "resumed" && c.sessionId == e.conversationId)
    let again = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(e)) as! NSDictionary
    #expect(again["conversationId"] as? String == e.conversationId)
    // Untagged events stay untagged.
    let bare = try JSONDecoder().decode(HubEvent.self, from: Data(#"{"seq":1,"ts":1,"type":"turn_start","turn":1}"#.utf8))
    #expect(bare.conversationId == nil)
    #expect((try JSONSerialization.jsonObject(with: try JSONEncoder().encode(bare)) as! NSDictionary)["conversationId"] == nil)
}

@MainActor
@Test func aSubagentsTaskCardTakesItsAgentCallsPlaceAndItsReportIsntRepeated() {
    let s = DuetStore()
    s.apply(ev(1, .user(UserEvent(turn: 1, text: "look around", by: "mac"))))
    s.apply(ev(2, .assistant(AssistantEvent(turn: 1, text: "", toolUses: [ToolUse(id: "toolu_0123456789abcdef", name: "Agent", input: .object(["prompt": .string("Find X"), "subagent_type": .string("Explore")]))]))))
    #expect(s.leadRows.last?.id == "t1-utoolu_0123456789abcdef")
    s.apply(ev(3, .task(TaskEvent(taskId: "sa-89abcdef", worker: "claude-explore", state: "running", prompt: "Find X", by: "lead", effort: nil, queuePosition: nil, result: nil, evidence: nil, error: nil, stats: nil))))
    s.apply(ev(4, .dialogue(DialogueEvent(id: "sa-89abcdef-task", kind: "TASK", taskId: "sa-89abcdef", from: "lead", to: "claude-explore", text: "Find X", replyTo: nil, options: nil, refused: nil))))
    #expect(s.leadRows.last?.id == "d-sa-89abcdef-task")
    #expect(!s.leadRows.contains { $0.id == "t1-utoolu_0123456789abcdef" })
    s.apply(ev(5, .task(TaskEvent(taskId: "sa-89abcdef", worker: "claude-explore", state: "done", prompt: nil, by: nil, effort: nil, queuePosition: nil, result: "X is in y.swift", evidence: nil, error: nil, stats: nil))))
    s.apply(ev(6, .toolResult(ToolResultEvent(turn: 1, toolUseId: "toolu_0123456789abcdef", isError: false, preview: "X is in y.swift"))))
    #expect(!s.leadRows.contains { $0.id == "t1-rtoolu_0123456789abcdef" })
    #expect(s.tasks["sa-89abcdef"]?.isClaude == true)
}
