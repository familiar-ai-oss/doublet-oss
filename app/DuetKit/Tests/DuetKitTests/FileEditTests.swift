import Foundation
import Testing
@testable import DuetKit

private func ev(_ seq: Int, _ body: HubEvent.Body) -> HubEvent { HubEvent(seq: seq, ts: 1_700_000_000_000 + Double(seq), body: body) }

@Test func anEditDiffsByLineKeepingWhatsTheSame() {
    let lines = DiffLine.lines(from: "a\nb\nc", to: "a\nB\nc\nd")
    #expect(lines.map(\.kind) == [.kept, .removed, .added, .kept, .added])
    #expect(lines.map(\.text) == ["a", "b", "B", "c", "d"])
    // Where each line is in the new text; a removed line isn't in it.
    #expect(lines.map(\.newIndex) == [0, nil, 1, 2, 3])
}

@Test func eachFileToolSaysWhatItChanges() {
    let edit = FileEdit(tool: "Edit", input: .object(["file_path": .string("/p/a.swift"), "old_string": .string("let x = 1"), "new_string": .string("let x = 2\nlet y = 3")]))
    #expect(edit?.path == "/p/a.swift")
    #expect(edit?.added == 2 && edit?.removed == 1)

    let multi = FileEdit(tool: "MultiEdit", input: .object(["file_path": .string("/p/b.swift"), "edits": .array([
        .object(["old_string": .string("one"), "new_string": .string("1")]),
        .object(["old_string": .string("two"), "new_string": .string("2")]),
    ])]))
    #expect(multi?.changes.count == 2 && multi?.added == 2 && multi?.removed == 2)

    // A Write is all new text.
    let write = FileEdit(tool: "Write", input: .object(["file_path": .string("/p/c.txt"), "content": .string("x\ny\n")]))
    #expect(write?.added == 3 && write?.removed == 0)

    #expect(FileEdit(tool: "Read", input: .object(["file_path": .string("/p/a.swift")])) == nil)
    #expect(FileEdit(tool: "Edit", input: .object(["file_path": .string("/p/a.swift")])) == nil)
}

@Test func anEditsLineIsFoundInTheFileAsItIsNow() {
    let edit = FileEdit(path: "/p/a.swift", changes: [.init(old: "b", new: "B\nB2")])
    #expect(edit.line(of: 0, in: "a\nB\nB2\nc") == 2)
    #expect(edit.line(of: 0, in: "a\nb\nc") == nil)
}

@MainActor
@Test func aFileToolsRowCarriesItsChange() {
    let s = DuetStore()
    s.apply(ev(1, .user(UserEvent(turn: 1, text: "fix it", by: "mac"))))
    s.apply(ev(2, .assistant(AssistantEvent(turn: 1, text: "", toolUses: [
        ToolUse(id: "e1", name: "Edit", input: .object(["file_path": .string("/p/a.swift"), "old_string": .string("x"), "new_string": .string("y")])),
        ToolUse(id: "b1", name: "Bash", input: .object(["command": .string("swift test")])),
    ]))))
    guard case .tool(_, _, let summary, let edit)? = s.leadRows.first(where: { $0.id == "t1-ue1" }) else { Issue.record("no edit row"); return }
    #expect(summary == "/p/a.swift")
    #expect(edit == FileEdit(path: "/p/a.swift", changes: [.init(old: "x", new: "y")]))
    #expect(s.leadRows.last == .tool(id: "t1-ub1", name: "Bash", summary: "swift test"))
}
