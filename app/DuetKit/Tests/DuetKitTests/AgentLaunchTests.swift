import Foundation
import Testing
@testable import DuetKit

/// Claude's subagents: each keeps the few words Claude gave it, one that went to the background isn't called done, and
/// a launch taps once in the hand, when the last agent started with it ends.
@MainActor
@Test func subagentLaunchesAreNamedHonestAndTapOnce() throws {
    let store = DuetStore()
    func apply(_ json: String) throws {
        if case .event(let e) = try JSONDecoder().decode(ServerFrame.self, from: Data(json.utf8)) { store.apply(e) }
    }
    store.handle(.replayDone(headSeq: 0))
    try apply(#"{"seq":1,"ts":1,"type":"assistant","turn":1,"text":"","toolUses":[{"id":"toolu_aaaaaaa1","name":"Agent","input":{"description":"Map the states","prompt":"Map the lexer's states.","subagent_type":"Explore"}},{"id":"toolu_bbbbbbb2","name":"Agent","input":{"prompt":"Find every use of Token.text\nand list them.","subagent_type":"Explore"}}],"conversationId":"c1"}"#)
    #expect(store.agentLabels["sa-aaaaaaa1"] == "Map the states")
    #expect(store.agentLabels["sa-bbbbbbb2"] == "Find every use of Token.text", "no description: its prompt's first line")
    for id in ["aaaaaaa1", "bbbbbbb2"] {
        try apply(#"{"seq":2,"ts":2,"type":"task","taskId":"sa-\#(id)","worker":"claude-explore","state":"running","prompt":"p","by":"lead","conversationId":"c1"}"#)
    }
    let start = store.beat?.n ?? 0
    try apply(#"{"seq":3,"ts":3,"type":"task","taskId":"sa-aaaaaaa1","worker":"claude-explore","state":"done","result":"Two states.","conversationId":"c1"}"#)
    #expect((store.beat?.n ?? 0) == start, "no tap while the other agent of the launch still runs")
    try apply(#"{"seq":4,"ts":4,"type":"task","taskId":"sa-bbbbbbb2","worker":"claude-explore","state":"failed","result":"It couldn't build.","conversationId":"c1"}"#)
    #expect((store.beat?.n ?? 0) == start + 1, "one tap when the launch ends")
    #expect(store.beat?.moment == .taskFailed, "a launch with a failure taps as failed")

    // Sent to the background: the hub ends it at once with a stand-in report.
    try apply(#"{"seq":5,"ts":5,"type":"assistant","turn":1,"text":"","toolUses":[{"id":"toolu_ccccccc3","name":"Agent","input":{"description":"Benchmark the lexer","prompt":"Time it.","run_in_background":true}}],"conversationId":"c1"}"#)
    try apply(#"{"seq":6,"ts":6,"type":"task","taskId":"sa-ccccccc3","worker":"claude-general-purpose","state":"running","prompt":"Time it.","by":"lead","conversationId":"c1"}"#)
    try apply(#"{"seq":7,"ts":7,"type":"task","taskId":"sa-ccccccc3","worker":"claude-general-purpose","state":"done","result":"Running in the background; Claude gets its report when it finishes.","conversationId":"c1"}"#)
    let bg = try #require(store.tasks["sa-ccccccc3"])
    #expect(bg.inBackground)
    #expect(bg.displayState == "background", "not shown as done")
    #expect(!store.recentResults.contains { $0.taskId == "sa-ccccccc3" }, "not a result yet")
    #expect((store.beat?.n ?? 0) == start + 1, "no tap for going to the background")

    // A local worker's task still taps on its own, and a finished subagent's report is a result.
    try apply(#"{"seq":8,"ts":8,"type":"task","taskId":"t-1","worker":"qwen-27b","state":"done","result":"Renamed it.","conversationId":"c1"}"#)
    #expect((store.beat?.n ?? 0) == start + 2)
    #expect(store.recentResults.contains { $0.taskId == "sa-aaaaaaa1" })
    #expect(store.tasks["sa-aaaaaaa1"]?.displayState == "done")
}

/// A workflow's row reads its name: from its script's meta, a saved workflow's name, or the script file.
@Test func workflowRowsReadTheirName() {
    let script = "export const meta = {\n  name: 'lexer-audit',\n  description: 'Audit the lexer',\n  phases: [{ title: 'Read' }],\n}\nphase('Read')\n"
    #expect(ToolSummary.text("Workflow", .object(["script": .string(script)])) == "lexer-audit")
    #expect(ToolSummary.text("Workflow", .object(["name": .string("review-changes")])) == "review-changes")
    #expect(ToolSummary.text("Workflow", .object(["scriptPath": .string("/tmp/s/review.js")])) == "review")
    #expect(ToolSummary.text("Workflow", .object(["script": .string("agent('x')")])) == "workflow", "no meta name: still not the script")
    #expect(ToolSummary.agentLabel(.object(["description": .string("  Find it  ")])) == "Find it")
    #expect(ToolSummary.agentLabel(.object([:])) == "Subagent")
}
