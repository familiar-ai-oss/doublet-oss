import Foundation
import Testing
@testable import DuetKit

private func ev(_ seq: Int, _ body: HubEvent.Body, in conversation: String? = "conv-1") -> HubEvent {
    HubEvent(seq: seq, ts: 1_700_000_000_000 + Double(seq), body: body, conversationId: conversation)
}
private func task(_ id: String, _ worker: String, _ state: String, queuePosition: Int? = nil, result: String? = nil, profile: String? = nil) -> TaskEvent {
    TaskEvent(taskId: id, worker: worker, state: state, prompt: "do \(id)", by: "lead", effort: nil, queuePosition: queuePosition, result: result,
              evidence: nil, error: nil, stats: nil, profile: profile)
}
private func card(_ id: String, _ kind: String, _ taskId: String, from: String, to: String, _ text: String, replyTo: String? = nil) -> DialogueEvent {
    DialogueEvent(id: id, kind: kind, taskId: taskId, from: from, to: to, text: text, replyTo: replyTo, options: nil, refused: nil)
}

@Test func planAndEscalationEventsDecodeAndKeepEveryField() throws {
    let lines = [
        #"{"seq":1,"ts":1,"type":"plan","conversationId":"c","by":"lead","steps":[{"id":"1","text":"Find it","owner":"qwen-27b","status":"in_progress","taskId":"t-1"},{"id":"2","text":"Review","owner":"lead","status":"pending","note":"after 1"}]}"#,
        #"{"seq":2,"ts":2,"type":"dialogue","id":"e-1","kind":"ESCALATE","taskId":"t-1","from":"lead","to":"you","text":"Your call.","replyTo":"q-1"}"#,
        #"{"seq":3,"ts":3,"type":"task","taskId":"t-1","worker":"qwen-27b","state":"queued","profile":"explore","queuePosition":1}"#,
    ]
    for line in lines {
        let e = try JSONDecoder().decode(HubEvent.self, from: Data(line.utf8))
        if case .unknown(let t) = e.body { Issue.record("undecoded: \(t)") }
        let back = try JSONDecoder().decode(HubEvent.self, from: try JSONEncoder().encode(e))
        #expect(back == e)
    }
    let plan = try JSONDecoder().decode(HubEvent.self, from: Data(lines[0].utf8))
    guard case .plan(let p) = plan.body else { Issue.record("not a plan"); return }
    #expect(p.steps.map(\.id) == ["1", "2"] && p.steps[0].taskId == "t-1" && p.steps[1].note == "after 1" && p.steps[1].isClaudes)
}

@MainActor
@Test func eachPlanStepFollowsItsTask() {
    let s = DuetStore()
    s.apply(ev(1, .task(task("t-1", "qwen-27b", "running", profile: "explore"))))
    s.apply(ev(2, .task(task("t-2", "qwen-27b", "queued", queuePosition: 1))))
    s.apply(ev(3, .task(task("t-3", "gemma", "awaiting_swap"))))
    s.apply(ev(4, .task(task("t-9", "qwen-9b", "running"))))
    s.apply(ev(5, .plan(PlanEvent(steps: [
        PlanStep(id: "1", text: "Find the effort tables", owner: "qwen-27b", status: "in_progress", taskId: "t-1"),
        PlanStep(id: "2", text: "Write tests", owner: "qwen-27b", status: "in_progress", taskId: "t-2"),
        PlanStep(id: "3", text: "Try gemma", owner: "gemma", status: "in_progress", taskId: "t-3"),
        PlanStep(id: "4", text: "Review", owner: "lead", status: "pending"),
        PlanStep(id: "5", text: "Sketch the change", owner: "lead", status: "in_progress", note: "reading fleet.ts"),
    ], by: "lead"))))
    s.apply(ev(6, .taskProgress(TaskProgressEvent(taskId: "t-1", worker: "qwen-27b", text: nil, tools: nil, toolResult: nil, toolUses: [ToolCall(name: "Grep", input: .object(["pattern": .string("EFFORT")]))]))))
    var items = s.planItems("conv-1")
    #expect(items.map(\.phase) == [.active, .queued, .needsYou, .pending, .active])
    #expect(items[0].detail == "Grep  EFFORT" && items[0].task?.profile == "explore")
    #expect(items[1].detail == "Waits for the task ahead of it: its worker runs one at a time")
    #expect(items[4].detail == "reading fleet.ts")
    #expect(s.unplannedTasks("conv-1").map(\.taskId) == ["t-9"], "a task no step names still shows")
    var summary = s.planSummary("conv-1")!
    #expect(summary.done == 0 && summary.total == 5 && summary.queued == 1 && summary.needsYou == 1)
    #expect(summary.next?.step.id == "4" && summary.now.map(\.step.id) == ["1", "3", "5"])

    // The worker finishes: the step waits for Claude's review, with what it found; Claude then marks it done.
    s.apply(ev(7, .dialogue(card("r-1", "RESULT", "t-1", from: "qwen-27b", to: "lead", "Finished: effort.ts:12 defines EFFORT_TABLES\nHub-measured changes:\nno changes"))))
    s.apply(ev(8, .task(task("t-1", "qwen-27b", "done", result: "done"))))
    items = s.planItems("conv-1")
    #expect(items[0].phase == .review && items[0].detail == "effort.ts:12 defines EFFORT_TABLES")
    s.apply(ev(9, .task(task("t-2", "qwen-27b", "failed"))))
    s.apply(ev(10, .plan(PlanEvent(steps: [
        PlanStep(id: "1", text: "Find the effort tables", owner: "qwen-27b", status: "completed", taskId: "t-1"),
        PlanStep(id: "2", text: "Write tests", owner: "qwen-27b", status: "in_progress", taskId: "t-2"),
    ], by: "lead"))))
    items = s.planItems("conv-1")
    #expect(items.map(\.phase) == [.done, .failed])
    #expect(items[0].detail == "effort.ts:12 defines EFFORT_TABLES")
    summary = s.planSummary("conv-1")!
    #expect(summary.done == 1 && summary.total == 2 && summary.next == nil)
    #expect(s.planItems("other").isEmpty && s.planSummary("other") == nil)
}

@MainActor
@Test func aQuestionClaudePassesOnNeedsYouUntilAnswered() {
    let s = DuetStore()
    s.apply(ev(1, .task(task("t-1", "qwen-27b", "running"))))
    s.apply(ev(2, .plan(PlanEvent(steps: [PlanStep(id: "1", text: "Format", owner: "qwen-27b", status: "in_progress", taskId: "t-1")], by: "lead"))))
    s.apply(ev(3, .dialogue(card("q-1", "QUESTION", "t-1", from: "qwen-27b", to: "lead", "Tabs or spaces?"))))
    #expect(s.attention.isEmpty, "Claude's own question")
    s.apply(ev(4, .dialogue(card("e-1", "ESCALATE", "t-1", from: "lead", to: "you", "A style choice.", replyTo: "q-1"))))
    #expect(s.attention.map(\.id) == ["q-q-1"], "passed on to you: you answer the question itself")
    s.apply(ev(5, .dialogue(card("e-2", "ESCALATE", "t-1", from: "lead", to: "you", "Again.", replyTo: "q-1"))))
    #expect(s.attention.count == 1)
    let item = s.planItems("conv-1")[0]
    #expect(item.phase == .needsYou && item.detail == "Asks: Tabs or spaces?")
    s.apply(ev(6, .dialogue(card("a-1", "ANSWER", "t-1", from: "iphone", to: "qwen-27b", "spaces", replyTo: "q-1"))))
    #expect(s.attention.isEmpty)
    #expect(s.planItems("conv-1")[0].phase == .active)
    // Passed on after it was answered (or its task ended): nothing waits on you.
    s.apply(ev(7, .dialogue(card("e-3", "ESCALATE", "t-1", from: "lead", to: "you", "Late.", replyTo: "q-1"))))
    #expect(s.attention.isEmpty)
}
