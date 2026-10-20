import Foundation
import Testing
@testable import DuetKit

/// A worker task that ran out of turns ends done, marked stopped: shown as "stopped", kept through later updates, and
/// read the same as before by a hub that doesn't send the mark.
@MainActor
@Test func taskStoppedAtItsTurnLimit() throws {
    let store = DuetStore()
    func apply(_ json: String) throws {
        if case .event(let e) = try JSONDecoder().decode(ServerFrame.self, from: Data(json.utf8)) { store.apply(e) }
    }
    try apply(#"{"seq":1,"ts":1,"type":"task","taskId":"t-1","worker":"qwen-27b","state":"running","prompt":"Fix the table","conversationId":"c1"}"#)
    #expect(store.tasks["t-1"]?.displayState == "running")
    try apply(#"{"seq":2,"ts":2,"type":"task","taskId":"t-1","worker":"qwen-27b","state":"done","result":"Stopped at its 60-turn limit before finishing.","stopped":"turn_limit","conversationId":"c1"}"#)
    #expect(store.tasks["t-1"]?.stopped == "turn_limit")
    #expect(store.tasks["t-1"]?.displayState == "stopped")
    #expect(store.tasks["t-1"]?.prompt == "Fix the table", "earlier fields kept")
    try apply(#"{"seq":3,"ts":3,"type":"task","taskId":"t-2","worker":"qwen-9b","state":"done","result":"All done.","conversationId":"c1"}"#)
    #expect(store.tasks["t-2"]?.displayState == "done", "an ordinary finish reads as before")
    try apply(#"{"seq":4,"ts":4,"type":"task","taskId":"t-3","worker":"qwen-9b","state":"done","result":"Stopped before finishing: the work kept outgrowing its model's context.","stopped":"context","conversationId":"c1"}"#)
    #expect(store.tasks["t-3"]?.displayState == "out_of_room")
}
