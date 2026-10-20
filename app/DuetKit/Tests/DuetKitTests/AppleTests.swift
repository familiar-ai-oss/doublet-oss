import Foundation
import Testing
@testable import DuetKit

private func ev(_ seq: Int, _ body: HubEvent.Body) -> HubEvent { HubEvent(seq: seq, ts: 1_700_000_000_000 + Double(seq), body: body) }

@Test func theHubsTasksForThisDeviceDecode() throws {
    let task = #"{"type":"apple_task","taskId":"t-1","prompt":"Summarize","input":"=== /x/build.log ===\nERROR disk full","temperature":0.2}"#
    guard case .appleTask(let t) = try JSONDecoder().decode(ServerFrame.self, from: Data(task.utf8)) else {
        Issue.record("not an Apple task")
        return
    }
    #expect(t == AppleTask(taskId: "t-1", prompt: "Summarize", input: "=== /x/build.log ===\nERROR disk full", temperature: 0.2))
    guard case .appleCancel(let id) = try JSONDecoder().decode(ServerFrame.self, from: Data(#"{"type":"apple_cancel","taskId":"t-1"}"#.utf8)) else {
        Issue.record("not a cancel")
        return
    }
    #expect(id == "t-1")
}

@MainActor
@Test func anAppleTaskKeepsTheFilesItReadsAsItRuns() {
    let s = DuetStore()
    s.apply(ev(1, .task(TaskEvent(taskId: "t-1", worker: "apple-ipad", state: "queued", prompt: "Summarize", by: "lead", effort: nil, queuePosition: 0,
                                  result: nil, evidence: nil, error: nil, stats: nil, files: ["/x/build.log"]))))
    s.apply(ev(2, .task(TaskEvent(taskId: "t-1", worker: "apple-ipad", state: "done", prompt: nil, by: nil, effort: nil, queuePosition: nil,
                                  result: "Three errors, all disk full.", evidence: "not applicable: an Apple worker reads and writes no files", error: nil, stats: nil))))
    let t = s.tasks["t-1"]
    #expect(t?.files == ["/x/build.log"])
    #expect(t?.prompt == "Summarize")
    #expect(t?.isApple == true)
}
