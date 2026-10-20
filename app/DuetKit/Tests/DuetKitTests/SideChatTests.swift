import Foundation
import Testing
@testable import DuetKit

private func ev(_ seq: Int, _ body: HubEvent.Body, in conversation: String? = "conv-1") -> HubEvent {
    HubEvent(seq: seq, ts: 1_700_000_000_000 + Double(seq), body: body, conversationId: conversation)
}
private func chat(_ id: String, _ state: String, activity: String? = nil, error: String? = nil, forked: String? = nil) -> HubEvent.Body {
    .sideChat(SideChatEvent(chatId: id, state: state, title: "How does auto pick?", model: "haiku", by: "mac",
                            about: .file(path: "/home/b/duet-hub/src/fleet.ts", start: 51, end: 56), forked: forked, activity: activity, error: error))
}

@Test func sideChatEventsAndFramesDecodeAndKeepEveryField() throws {
    let lines = [
        #"{"seq":1,"ts":1,"type":"side_chat","conversationId":"c","chatId":"sc-1","state":"answering","title":"Why?","model":"haiku","by":"mac","about":{"kind":"file","path":"/p/a.ts","start":3},"forked":"whole","activity":"Read /p/a.ts"}"#,
        #"{"seq":2,"ts":2,"type":"side_message","chatId":"sc-1","id":"m-1","role":"user","text":"Why?","by":"mac","image":true}"#,
        #"{"seq":3,"ts":3,"type":"side_delta","chatId":"sc-1","text":"Because"}"#,
        #"{"seq":4,"ts":4,"type":"side_chat","chatId":"sc-2","state":"failed","title":"x","model":"sonnet","by":"ipad","about":{"kind":"text","label":"A step","text":"Write tests"},"error":"Stopped."}"#,
    ]
    for line in lines {
        let e = try JSONDecoder().decode(HubEvent.self, from: Data(line.utf8))
        if case .unknown(let t) = e.body { Issue.record("undecoded: \(t)") }
        #expect(try JSONDecoder().decode(HubEvent.self, from: try JSONEncoder().encode(e)) == e)
    }
    let changed = try JSONDecoder().decode(ServerFrame.self, from: Data(#"{"type":"fs_changed","path":"/p/src"}"#.utf8))
    #expect(changed == .fsChanged(path: "/p/src"))
    #expect(SideAbout.file(path: "/p/src/fleet.ts", start: 51, end: 56).title == "fleet.ts:51-56")
    #expect(SideAbout.file(path: "/p/src/fleet.ts").title == "fleet.ts")
    #expect(SideAbout.text(label: "qwen-27b's result").title == "qwen-27b's result")
}

@MainActor
@Test func aSideChatStreamsItsAnswerThenKeepsIt() {
    let s = DuetStore()
    s.apply(ev(1, chat("sc-1", "answering", activity: "Reading the conversation")))
    s.apply(ev(2, .sideMessage(SideMessageEvent(chatId: "sc-1", id: "m-1", role: "user", text: "How does auto pick?", by: "mac"))))
    s.apply(ev(3, chat("sc-1", "answering", activity: "Read /home/b/duet-hub/src/fleet.ts", forked: "whole")))
    s.apply(ev(4, .sideDelta(SideDeltaEvent(chatId: "sc-1", text: "It picks "))))
    s.apply(ev(5, .sideDelta(SideDeltaEvent(chatId: "sc-1", text: "the idle worker."))))
    #expect(s.sideChats["sc-1"]?.streaming == "", "streaming text waits for the 15 Hz publish")
    s.flushStreaming()
    var c = s.sideChats["sc-1"]!
    #expect(c.streaming == "It picks the idle worker." && c.isAnswering && c.activity == "Read /home/b/duet-hub/src/fleet.ts" && c.forked == "whole")
    s.apply(ev(6, .sideMessage(SideMessageEvent(chatId: "sc-1", id: "msg_2", role: "assistant", text: "It picks the idle worker."))))
    s.apply(ev(7, chat("sc-1", "idle")))
    c = s.sideChats["sc-1"]!
    #expect(c.streaming.isEmpty && !c.isAnswering && c.activity == nil)
    #expect(c.messages.map(\.role) == ["user", "assistant"] && c.messages.last?.text == "It picks the idle worker.")
    #expect(c.about == .file(path: "/home/b/duet-hub/src/fleet.ts", start: 51, end: 56) && c.conversationId == "conv-1")
    // A second chat in the same conversation, and one in another: each conversation lists its own, newest first.
    s.apply(ev(8, chat("sc-2", "answering")))
    s.apply(ev(9, chat("sc-3", "failed", error: "Stopped."), in: "conv-2"))
    #expect(s.sideChats(in: "conv-1").map(\.id) == ["sc-2", "sc-1"])
    #expect(s.sideChats(in: "conv-2").map(\.id) == ["sc-3"] && s.sideChats["sc-3"]?.error == "Stopped.")
    // A late delta for a chat that ended streams nothing.
    s.apply(ev(10, .sideDelta(SideDeltaEvent(chatId: "sc-3", text: "late"))))
    s.apply(ev(11, chat("sc-3", "failed", error: "Stopped."), in: "conv-2"))
    s.flushStreaming()
    #expect(s.sideChats["sc-3"]?.streaming == "")
}

@MainActor
@Test func filesClaudeAndWorkersChangeAreNotedWithWhoAndWhen() {
    let s = DuetStore()
    s.apply(ev(1, .assistant(AssistantEvent(turn: 1, text: "", toolUses: [
        ToolUse(id: "u1", name: "Edit", input: .object(["file_path": .string("/p/src/a.ts"), "old_string": .string("x")])),
        ToolUse(id: "u2", name: "Read", input: .object(["file_path": .string("/p/src/b.ts")])),
    ]))))
    s.apply(ev(2, .taskProgress(TaskProgressEvent(taskId: "t-1", worker: "qwen-27b", text: nil, tools: nil, toolResult: nil, toolUses: [
        ToolCall(name: "Write", input: .object(["file_path": .string("/p/test/a.test.ts")])),
        ToolCall(name: "NotebookEdit", input: .object(["notebook_path": .string("/p/n.ipynb")])),
        ToolCall(name: "Bash", input: .object(["command": .string("touch /p/c")])),
    ]))))
    s.apply(ev(3, .taskProgress(TaskProgressEvent(taskId: "t-2", worker: "qwen-9b", text: nil, tools: nil, toolResult: nil, toolUses: [
        ToolCall(name: "Edit", input: .object(["file_path": .string("/p/src/a.ts")])),
    ]))))
    #expect(s.fileTouches["/p/src/a.ts"]?.by == "qwen-9b", "the latest change wins")
    #expect(s.fileTouches["/p/test/a.test.ts"]?.by == "qwen-27b" && s.fileTouches["/p/n.ipynb"]?.tool == "NotebookEdit")
    #expect(s.fileTouches["/p/src/b.ts"] == nil, "reading changes nothing")
    #expect(s.touches(under: "/p/src").map(\.path) == ["/p/src/a.ts"])
    #expect(Set(s.touches(under: "/p").map(\.path)) == ["/p/src/a.ts", "/p/test/a.test.ts", "/p/n.ipynb"])
}
