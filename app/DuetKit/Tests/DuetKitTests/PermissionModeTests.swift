import Foundation
import Testing
@testable import DuetKit

private func info(_ seq: Int, mode: String?) throws -> HubEvent {
    let m = mode.map { #","permissionMode":"\#($0)""# } ?? ""
    let line = #"{"seq":\#(seq),"ts":\#(seq),"type":"lead_info","model":"claude-opus-5-5","effort":"high","models":[],"conversationId":"c-1"\#(m)}"#
    return try JSONDecoder().decode(HubEvent.self, from: Data(line.utf8))
}

@MainActor
@Test func theStoreHasTheModeTheHubLastSent() throws {
    let s = DuetStore()
    #expect(s.permissionMode == "default", "before the hub says, Claude asks about each call")
    s.apply(try info(1, mode: nil))
    #expect(s.permissionMode == "default", "a hub from before modes")
    s.apply(try info(2, mode: "plan"))
    #expect(s.permissionMode == "plan")
    // Claude's plan approved: the hub sends the mode from before plan mode.
    s.apply(try info(3, mode: "acceptEdits"))
    #expect(s.permissionMode == "acceptEdits")
}

@Test func aPlanApprovalCarriesThePlanAndRoundTrips() throws {
    let line = ##"{"seq":7,"ts":7,"type":"approval_request","conversationId":"c-1","id":"ab12cd34","turn":3,"tool":"ExitPlanMode","input":{"plan":"# Plan\n1. Add the mode","planFilePath":"/home/b/.claude/plans/x.md"},"toolUseId":"toolu_1","displayName":"ExitPlanMode","plan":"# Plan\n1. Add the mode"}"##
    let e = try JSONDecoder().decode(HubEvent.self, from: Data(line.utf8))
    guard case .approvalRequest(let a) = e.body else { Issue.record("not an approval: \(e.body)"); return }
    #expect(a.plan == "# Plan\n1. Add the mode")
    #expect(a.input["planFilePath"] == .string("/home/b/.claude/plans/x.md"))
    #expect(try JSONDecoder().decode(HubEvent.self, from: try JSONEncoder().encode(e)) == e)

    let other = #"{"seq":8,"ts":8,"type":"approval_request","id":"cd34ef56","turn":3,"tool":"Bash","input":{"command":"ls"}}"#
    guard case .approvalRequest(let b) = try JSONDecoder().decode(HubEvent.self, from: Data(other.utf8)).body else { Issue.record("not an approval"); return }
    #expect(b.plan == nil)
}

@Test func setPermissionModeSendsTheMode() {
    #expect(ClientMessage.setPermissionMode("auto").json(ref: "9") == .object(["type": .string("set_permission_mode"), "mode": .string("auto"), "ref": .string("9")]))
}
