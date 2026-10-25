import Foundation
import Testing
@testable import DuetKit

private let day: TimeInterval = 86_400
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private let notes: [NoteEntry] = [
    NoteEntry(id: "a", module: "Lexer.swift", tags: ["security", "parsing"], createdAt: t0, text: "escape?", question: true),
    NoteEntry(id: "b", module: "Parser.swift", tags: ["security"], createdAt: t0 + day, text: "trust input?", resolved: true),
    NoteEntry(id: "c", module: "Parser.swift", tags: ["Parsing"], createdAt: t0 + 2 * day, text: "precedence"),
    NoteEntry(id: "d", module: "Lexer.swift", tags: [], createdAt: nil, text: "old note"),
    NoteEntry(id: "e", module: "Lexer.swift", tags: ["security"], createdAt: t0 + 3 * day, text: "scratch", scratch: true),
]

@Test func oneTagAcrossModulesNewestFirst() {
    #expect(NoteLedger.query(notes, NoteFilter(tags: ["security"])).map(\.id) == ["b", "a"])
}

@Test func everyTagOrAnyTag() {
    #expect(NoteLedger.query(notes, NoteFilter(tags: ["security", "parsing"], match: .all)).map(\.id) == ["a"])
    #expect(NoteLedger.query(notes, NoteFilter(tags: ["security", "parsing"], match: .any)).map(\.id) == ["c", "b", "a"])
}

@Test func tagsMatchWithoutCase() {
    #expect(NoteLedger.query(notes, NoteFilter(tags: ["PARSING"])).map(\.id) == ["c", "a"])
}

@Test func modulesTimeAndResolved() {
    #expect(NoteLedger.query(notes, NoteFilter(modules: ["Lexer.swift"])).map(\.id) == ["a", "d"])
    #expect(NoteLedger.query(notes, NoteFilter(from: t0 + day / 2, to: t0 + 2 * day)).map(\.id) == ["c", "b"])
    #expect(NoteLedger.query(notes, NoteFilter(tags: ["security"], includeResolved: false)).map(\.id) == ["a"])
}

@Test func scratchpadStaysApart() {
    #expect(!NoteLedger.query(notes, NoteFilter()).contains { $0.scratch })
    #expect(NoteLedger.query(notes, NoteFilter(scratchpad: true)).map(\.id) == ["e"])
    // The scratchpad note doesn't count: security is on 2 notes, as is parsing (ties sort by name).
    #expect(NoteLedger.tagCounts(notes).map(\.tag) == ["parsing", "security"])
    #expect(NoteLedger.tagCounts(notes).map(\.count) == [2, 2])
}

@Test func overTimeByDay() {
    let cal = Calendar(identifier: .gregorian)
    let groups = NoteLedger.byDay(NoteLedger.query(notes, NoteFilter()), calendar: cal)
    #expect(groups.map(\.notes.count) == [1, 1, 1, 1])
    #expect(groups.last?.day == nil)
}

/// However the note was written (on the page, on a visual, on a plan), it's filed by module and tag the same way.
@Test func everySurfaceIsFiledByModuleAndTag() {
    let mixed = notes + [
        NoteEntry(id: "f", modules: ["Lexer.swift", "Token.swift"], surface: .diagram(diagramId: "g-1", version: 2, title: "Lexer states"),
                  node: "Lexer", tags: ["security"], createdAt: t0 + 4 * day, text: "why trust this?", question: true),
        NoteEntry(id: "g", modules: ["Parser.swift"], surface: .plan(conversationId: "c-1"), node: "step-3", tags: ["parsing"],
                  createdAt: t0 + 5 * day, text: "precedence again?", question: true),
    ]
    // A note on a diagram node counts for every module the node explains.
    #expect(NoteLedger.query(mixed, NoteFilter(modules: ["Token.swift"])).map(\.id) == ["f"])
    #expect(NoteLedger.query(mixed, NoteFilter(tags: ["security"], modules: ["Lexer.swift"])).map(\.id) == ["f", "a"])
    // One tag, every surface; or only what was asked on visuals.
    #expect(NoteLedger.query(mixed, NoteFilter(tags: ["parsing"])).map(\.id) == ["g", "c", "a"])
    #expect(NoteLedger.query(mixed, NoteFilter(surfaces: [.visual])).map(\.id) == ["f"])
    #expect(mixed.last?.module == "Parser.swift")
}
