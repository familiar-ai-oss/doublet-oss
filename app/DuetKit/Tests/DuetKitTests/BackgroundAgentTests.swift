import Foundation
import Testing
@testable import DuetKit

/// Claude's subagents as newer hubs follow them: one in the background is running until it really ends, then done or
/// failed with its own report; a subagent's own subagent sits under its parent and stays quiet; a turn Claude Code
/// starts by itself is a turn of its own; and an older hub's stand-in (older logs) still isn't called done.
@MainActor
@Test func backgroundSubagentsRunUntilTheyReallyEnd() throws {
    let store = DuetStore()
    func apply(_ json: String) throws {
        if case .event(let e) = try JSONDecoder().decode(ServerFrame.self, from: Data(json.utf8)) { store.apply(e) }
    }
    store.handle(.replayDone(headSeq: 0))
    try apply(#"{"seq":1,"ts":1,"type":"user","turn":1,"text":"Benchmark the lexer in the background","by":"mac","conversationId":"c1"}"#)
    try apply(#"{"seq":2,"ts":2,"type":"turn_start","turn":1,"conversationId":"c1"}"#)
    try apply(#"{"seq":3,"ts":3,"type":"assistant","turn":1,"text":"","toolUses":[{"id":"toolu_aaaaaaa1","name":"Agent","input":{"description":"Benchmark the lexer","prompt":"Time it.","run_in_background":true}}],"conversationId":"c1"}"#)
    try apply(#"{"seq":4,"ts":4,"type":"task","taskId":"sa-aaaaaaa1","worker":"claude-general-purpose","state":"running","prompt":"Time it.","by":"lead","label":"Benchmark the lexer","conversationId":"c1"}"#)
    var bg = try #require(store.tasks["sa-aaaaaaa1"])
    #expect(bg.label == "Benchmark the lexer")
    #expect(!bg.inBackground, "not until the hub says it went there")
    let lines = store.taskLines["sa-aaaaaaa1"]?.count ?? 0

    // Claude Code sent it to the background: still running, and nothing new in its thread.
    try apply(#"{"seq":5,"ts":5,"type":"task","taskId":"sa-aaaaaaa1","worker":"claude-general-purpose","state":"running","background":true,"conversationId":"c1"}"#)
    bg = try #require(store.tasks["sa-aaaaaaa1"])
    #expect(bg.inBackground)
    #expect(!bg.backgroundUntracked)
    #expect(bg.displayState == "running", "it is running, not 'not tracked yet'")
    #expect(bg.label == "Benchmark the lexer" && bg.prompt == "Time it.", "kept from its first event")
    #expect((store.taskLines["sa-aaaaaaa1"]?.count ?? 0) == lines, "going to the background adds no line")
    try apply(#"{"seq":6,"ts":6,"type":"turn_end","turn":1,"subtype":"success","isError":false,"interrupted":false,"conversationId":"c1"}"#)
    #expect(store.tasks["sa-aaaaaaa1"]?.inBackground == true, "Claude's turn ending doesn't end it")
    #expect(!store.recentResults.contains { $0.taskId == "sa-aaaaaaa1" })
    let start = store.beat?.n ?? 0

    // A helper it started: under it, two deep, by its own few words.
    try apply(#"{"seq":7,"ts":7,"type":"task","taskId":"sa-bbbbbbb2","worker":"claude-explore","state":"running","prompt":"Read Parser.swift.","by":"lead","label":"Read the parser","parentId":"sa-aaaaaaa1","depth":2,"conversationId":"c1"}"#)
    try apply(#"{"seq":8,"ts":8,"type":"dialogue","id":"sa-bbbbbbb2-task","kind":"TASK","taskId":"sa-bbbbbbb2","from":"claude-general-purpose","to":"claude-explore","text":"Read Parser.swift.","conversationId":"c1"}"#)
    let helper = try #require(store.tasks["sa-bbbbbbb2"])
    #expect(helper.parentId == "sa-aaaaaaa1" && helper.depth == 2 && helper.label == "Read the parser")
    let rows = try #require(store.conversation("c1")).rows
    #expect(!rows.contains { $0.id == "d-sa-bbbbbbb2-task" }, "its TASK card stays out of Claude's thread")
    try apply(#"{"seq":9,"ts":9,"type":"task","taskId":"sa-bbbbbbb2","worker":"claude-explore","state":"done","result":"It reads one token at a time.","conversationId":"c1"}"#)
    #expect((store.beat?.n ?? 0) == start, "a helper's end doesn't tap: its parent's does")
    #expect(!store.recentResults.contains { $0.taskId == "sa-bbbbbbb2" })

    // It really ends, with its report: done, a result, and one tap.
    try apply(#"{"seq":10,"ts":10,"type":"task","taskId":"sa-aaaaaaa1","worker":"claude-general-purpose","state":"done","result":"41 ms on big.swift.","stats":{"requests":2,"inputTokens":2000,"outputTokens":60,"genTokPerS":null,"wallMs":52000,"firstTokenMs":null},"conversationId":"c1"}"#)
    bg = try #require(store.tasks["sa-aaaaaaa1"])
    #expect(!bg.inBackground)
    #expect(bg.background == true, "it ran in the background")
    #expect(bg.displayState == "done")
    #expect(bg.result == "41 ms on big.swift.")
    #expect(store.recentResults.first?.taskId == "sa-aaaaaaa1")
    #expect((store.beat?.n ?? 0) == start + 1)
    #expect(store.beat?.moment == .taskDone)

    // Claude Code starts a turn by itself to read it: a turn of its own, with no prompt row.
    try apply(#"{"seq":11,"ts":11,"type":"turn_start","turn":2,"conversationId":"c1"}"#)
    try apply(#"{"seq":12,"ts":12,"type":"assistant","turn":2,"text":"The benchmark is back: 41 ms.","toolUses":[],"conversationId":"c1"}"#)
    try apply(#"{"seq":13,"ts":13,"type":"turn_end","turn":2,"subtype":"success","isError":false,"interrupted":false,"conversationId":"c1"}"#)
    #expect(store.turns.map(\.id) == [1, 2])
    #expect(store.turns.last?.prompt == "")
    let conversation = try #require(store.conversation("c1"))
    #expect(conversation.turnIds == [1, 2])
    #expect(!conversation.rows.contains { $0.id == "t2-p" })

    // An older hub's stand-in, from an older log: not done, and not "running" either.
    try apply(#"{"seq":14,"ts":14,"type":"task","taskId":"sa-ccccccc3","worker":"claude-general-purpose","state":"running","prompt":"Time it.","by":"lead","conversationId":"c1"}"#)
    try apply(#"{"seq":15,"ts":15,"type":"task","taskId":"sa-ccccccc3","worker":"claude-general-purpose","state":"done","result":"Running in the background; Claude gets its report when it finishes.","conversationId":"c1"}"#)
    let old = try #require(store.tasks["sa-ccccccc3"])
    #expect(old.inBackground && old.backgroundUntracked)
    #expect(old.displayState == "background")
}
