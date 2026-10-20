import Foundation
import Testing
@testable import DuetKit

// A prompt you send while Claude works shows as waiting on every device, then as a message once Claude takes it (one
// row, never two), or says it was dropped.

private func ev(_ seq: Int, _ body: HubEvent.Body) -> HubEvent {
    HubEvent(seq: seq, ts: 1_700_000_000_000 + Double(seq), body: body, conversationId: "c1")
}

@MainActor
@Test func aHeldPromptWaitsThenBecomesItsMessage() throws {
    let s = DuetStore()
    s.apply(ev(1, .user(UserEvent(turn: 1, text: "start", by: "mac"))))
    s.apply(ev(2, .turnStart(TurnStartEvent(turn: 1))))
    s.apply(ev(3, .queued(QueuedEvent(id: "q-1", state: "waiting", text: "how long do we keep the EC2 up?", by: "iphone"))))
    #expect(s.current?.waiting.map(\.text) == ["how long do we keep the EC2 up?"])
    #expect(!s.leadRows.contains { if case .prompt(_, let t, _, _) = $0 { t.contains("EC2") } else { false } })

    // Claude takes it mid-turn: the hub's next turn.
    s.apply(ev(4, .queued(QueuedEvent(id: "q-1", state: "taken"))))
    s.apply(ev(5, .user(UserEvent(turn: 2, text: "how long do we keep the EC2 up?", by: "iphone"))))
    s.apply(ev(6, .turnStart(TurnStartEvent(turn: 2))))
    #expect(s.current?.waiting.isEmpty == true)
    let prompts = s.leadRows.filter { if case .prompt(_, let t, _, _) = $0 { t.contains("EC2") } else { false } }
    #expect(prompts.count == 1)
}

@MainActor
@Test func aDroppedPromptSaysSoInsteadOfVanishing() throws {
    let s = DuetStore()
    s.apply(ev(1, .user(UserEvent(turn: 1, text: "start", by: "mac"))))
    s.apply(ev(2, .queued(QueuedEvent(id: "q-2", state: "waiting", text: "also the README", by: "mac"))))
    s.apply(ev(3, .queued(QueuedEvent(id: "q-2", state: "dropped", reason: "the hub restarted before Claude took it"))))
    #expect(s.current?.waiting.isEmpty == true)
    #expect(s.leadRows.contains { if case .note(_, let t) = $0 { t.contains("Not sent to Claude") && t.contains("also the README") } else { false } })
}
