import Foundation
import Testing
@testable import DuetKit

private func note(_ id: String, on surface: NoteSurface, elements: [String]? = nil, lines: [InkLines]? = nil,
                  intent: InkIntent = .question, status: String = "open", deleted: Bool? = nil) -> Annotation {
    let json: [String: Any?] = [
        "id": id, "intent": intent.rawValue, "text": "why \(id)?", "by": "ipad", "ts": 1_800_000_000_000.0, "status": status,
        "elements": elements.map { $0.map { ["id": $0, "label": $0] } },
        "lines": lines.map { $0.map { ["file": $0.file, "start": $0.start, "end": $0.end] } },
        "deleted": deleted,
    ]
    var s = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
    // The surface, as the hub sends it.
    var obj = try! JSONSerialization.jsonObject(with: s) as! [String: Any]
    obj["surface"] = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(surface))
    s = try! JSONSerialization.data(withJSONObject: obj)
    return try! JSONDecoder().decode(Annotation.self, from: s)
}

private let lexerStates = DiagramEvent(id: "g-1", version: 2, title: "Lexer states", kind: .mermaid, source: "flowchart LR",
                                       explains: [CodeRef(path: "/p/Sources/Lexer.swift"), CodeRef(path: "/p/Sources/Token.swift")],
                                       links: ["Scan": "/p/Sources/Lexer.swift:40-58", "Emit": "Sources/Token.swift", "Done": "nowhere:"])

@Test func aLinkNamesItsFileWithOrWithoutLines() {
    #expect(NoteSources.path(ofLink: "/p/A.swift:12") == "/p/A.swift")
    #expect(NoteSources.path(ofLink: "/p/A.swift:12-20") == "/p/A.swift")
    #expect(NoteSources.path(ofLink: "/p/A.swift") == "/p/A.swift")
    #expect(NoteSources.path(ofLink: " ") == nil)
}

@Test func aNoteOnAVisualIsFiledUnderWhatItsNodesStandFor() {
    let a = note("n1", on: .diagram(diagramId: "g-1", version: 2, title: nil), elements: ["Scan", "Emit"])
    // Relative links join the conversation's folder.
    #expect(NoteSources.modules(of: a, diagram: lexerStates, taskCwd: nil, base: "/p") == ["/p/Sources/Lexer.swift", "/p/Sources/Token.swift"])
    // Written off every node (or on a node with no link): what the whole diagram explains.
    let loose = note("n2", on: .diagram(diagramId: "g-1", version: 2, title: nil))
    #expect(NoteSources.modules(of: loose, diagram: lexerStates, taskCwd: nil, base: "/p") == ["/p/Sources/Lexer.swift", "/p/Sources/Token.swift"])
    // A diagram that says nothing about code: no module (it still shows under its tags).
    #expect(NoteSources.modules(of: a, diagram: nil, taskCwd: nil, base: "/p").isEmpty)
}

@Test func notesOnCodeAndDiffsAndPlans() {
    let page = note("n3", on: .file(path: "/p/Sources/Parser.swift"), lines: [InkLines(file: "/p/Sources/Parser.swift", start: 3, end: 4, code: nil)])
    #expect(NoteSources.modules(of: page, diagram: nil, taskCwd: nil, base: "/p") == ["/p/Sources/Parser.swift"])
    let diff = note("n4", on: .diff(taskId: "t-1", worker: nil), lines: [InkLines(file: "Sources/Lexer.swift", start: 1, end: 1, code: nil)])
    #expect(NoteSources.modules(of: diff, diagram: nil, taskCwd: "/work/t1", base: "/p") == ["/work/t1/Sources/Lexer.swift"])
    #expect(NoteSources.modules(of: note("n5", on: .plan(conversationId: "c-1"), elements: ["s1"]), diagram: nil, taskCwd: nil, base: "/p").isEmpty)
}

@Test func everyKeptNoteBecomesAnEntryFiledTheSameWay() {
    let kept = [
        note("n1", on: .diagram(diagramId: "g-1", version: 2, title: nil), elements: ["Scan"]),
        note("n3", on: .file(path: "/p/Sources/Lexer.swift"), status: "resolved"),
        note("gone", on: .file(path: "/p/Sources/Lexer.swift"), deleted: true),
    ]
    let hub = NoteSources.entries(kept, diagram: { id, _ in id == "g-1" ? lexerStates : nil }, taskCwd: { _ in nil }, base: "/p",
                                  tags: ["n1": ["security"], "n3": ["security", "parsing"]])
    #expect(hub.map(\.id) == ["n1", "n3"])
    #expect(hub[0].node == "Scan" && hub[0].surface.kind == .visual && hub[0].question)
    #expect(hub[1].resolved)
    // The visual's note and the page's note come up together under the module and the tag.
    #expect(Set(NoteLedger.query(hub, NoteFilter(tags: ["security"], modules: ["/p/Sources/Lexer.swift"])).map(\.id)) == ["n1", "n3"])
    // Notes only on this device (unsent, scratch) join them; one in both keeps the hub's status.
    let local = [NoteEntry(id: "n3", module: "/p/Sources/Lexer.swift", tags: ["parsing"], createdAt: nil, text: ""),
                 NoteEntry(id: "draft", module: "/p/Sources/Lexer.swift", tags: [], createdAt: nil, text: "", scratch: true)]
    let all = NoteSources.merged(hub: hub, local: local)
    #expect(all.map(\.id) == ["n1", "n3", "draft"])
    #expect(all[1].resolved && all[1].tags == ["security", "parsing"])
}
