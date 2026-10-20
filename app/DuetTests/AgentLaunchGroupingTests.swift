import DuetKit
import Foundation
import Testing
@testable import Duet

/// Claude's subagents in the thread (ThreadItem.group): the TASK cards of one launch are one line, their reports fold
/// into it, and a report that comes after you've said something shows where it landed too.
struct AgentLaunchGroupingTests {
    private static func card(_ kind: String, _ taskId: String) -> LeadRow {
        let json = #"{"id":"\#(taskId)-\#(kind)","kind":"\#(kind)","taskId":"\#(taskId)","from":"lead","to":"claude-explore","text":"x"}"#
        let d = try! JSONDecoder().decode(DialogueEvent.self, from: Data(json.utf8))
        return .agent(id: "d-\(taskId)-\(kind)", message: d)
    }
    private static func text(_ id: String) -> LeadRow { .chunk(id: id, message: id, index: 0, count: 1, lines: 1, text: "Some text") }

    @Test func aLaunchIsOneLineAndItsReportsFoldIntoIt() {
        let rows = [Self.card("TASK", "sa-a"), Self.card("TASK", "sa-b"), Self.card("TASK", "sa-c"),
                    Self.text("m1"), Self.card("RESULT", "sa-b"), Self.card("RESULT", "sa-a"), Self.card("RESULT", "sa-c")]
        let items = ThreadItem.group(rows, showResults: false)
        #expect(items.map(\.id) == ["agents-sa-a", "m1"], "one launch line, then the text; no cards")
        #expect(items.first == .agents(["sa-a", "sa-b", "sa-c"]))
    }

    @Test func aReportAfterYouSaidSomethingShowsWhereItLanded() {
        let rows = [Self.card("TASK", "sa-a"), Self.card("TASK", "sa-b"), Self.card("RESULT", "sa-a"),
                    .prompt(id: "p1", text: "Anything new?", by: "mac"), Self.card("RESULT", "sa-b")]
        let items = ThreadItem.group(rows, showResults: false)
        #expect(items.map(\.id) == ["agents-sa-a", "p1", "d-sa-b-RESULT"])
        #expect(items.last == .agentResult(id: "d-sa-b-RESULT", taskId: "sa-b"))
    }

    @Test func launchesInTurnAreSeparateLines() {
        // A finished launch, then another: two lines, not one launch of two.
        let rows = [Self.card("TASK", "sa-a"), Self.card("RESULT", "sa-a"), Self.card("TASK", "sa-b")]
        #expect(ThreadItem.group(rows, showResults: false) == [.agents(["sa-a"]), .agents(["sa-b"])])
    }

    @Test func otherCardsStayCards() {
        // A report whose launch isn't in these rows (an older log), and a local worker's task: their cards, as before.
        let local = Self.card("TASK", "t-1")
        let orphan = Self.card("RESULT", "sa-z")
        #expect(ThreadItem.group([orphan, local], showResults: false) == [.row(orphan), .row(local)])
    }
}
