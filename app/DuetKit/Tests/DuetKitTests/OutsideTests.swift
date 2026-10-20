import Foundation
import Testing
@testable import DuetKit

// Sessions started outside Duet: the hub's list and a followed session's messages arrive as frames; one continued here
// starts its conversation with where it came from and its last messages.

@Test func outsideFramesDecode() throws {
    let list = #"{"type":"outside_sessions","sessions":[{"sessionId":"s-1","name":"Chip findings","cwd":"/home/b/p","where":"desktop","status":"busy","live":true,"startedAt":1792332372092}]}"#
    guard case .outsideSessions(let sessions) = try JSONDecoder().decode(ServerFrame.self, from: Data(list.utf8)) else {
        Issue.record("not an outside_sessions frame"); return
    }
    #expect(sessions.map(\.place) == ["desktop"])
    #expect(sessions.first?.live == true && sessions.first?.status == "busy")
    let messages = #"{"type":"outside_messages","sessionId":"s-1","messages":[{"uuid":"a1","role":"assistant","text":"Done.","tools":["Read src/a.ts"]}]}"#
    guard case .outsideMessages(let id, let got) = try JSONDecoder().decode(ServerFrame.self, from: Data(messages.utf8)) else {
        Issue.record("not an outside_messages frame"); return
    }
    #expect(id == "s-1" && got.first?.tools == ["Read src/a.ts"])
}

@MainActor
@Test func aContinuedSessionStartsItsConversationWithWhereItCameFrom() throws {
    let store = DuetStore()
    let line = #"{"seq":1,"ts":1792332372092,"type":"conversation_import","conversationId":"fork-1","from":{"sessionId":"s-1","name":"Chip findings","cwd":"/home/b/p","where":"terminal","status":"busy","live":true},"forked":true,"messages":[{"uuid":"u1","role":"user","text":"Where is the lexer?"},{"uuid":"a1","role":"assistant","text":"In src/lexer.ts."}]}"#
    guard case .event(let e) = try JSONDecoder().decode(ServerFrame.self, from: Data(line.utf8)) else {
        Issue.record("not an event"); return
    }
    store.apply(e)
    let imported = store.conversation("fork-1")?.imported
    #expect(imported?.forked == true)
    #expect(imported?.from.place == "terminal")
    #expect(imported?.messages.map(\.text) == ["Where is the lexer?", "In src/lexer.ts."])
}
