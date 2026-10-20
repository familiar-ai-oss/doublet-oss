import CoreGraphics
import Testing
@testable import DuetKit

// Synthetic Pencil strokes: the shapes people draw on a diagram or a diff, and what they should mean.

private func line(_ a: CGPoint, _ b: CGPoint, n: Int = 24) -> [CGPoint] {
    (0...n).map { i in CGPoint(x: a.x + (b.x - a.x) * CGFloat(i) / CGFloat(n), y: a.y + (b.y - a.y) * CGFloat(i) / CGFloat(n)) }
}
private func loop(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> [CGPoint] {
    (0...48).map { i in let t = Double(i) / 48 * 2 * .pi * 0.96; return CGPoint(x: c.x + rx * cos(t), y: c.y + ry * sin(t)) }
}
/// A handwritten word: a small zigzag.
private func word(at o: CGPoint, width: CGFloat = 40) -> [CGPoint] {
    (0...16).map { i in CGPoint(x: o.x + width * CGFloat(i) / 16, y: o.y + (i.isMultiple(of: 2) ? 0 : 9)) }
}
private let A = InkAnchor(id: "A", label: "Hub", rect: CGRect(x: 60, y: 60, width: 100, height: 40))
private let B = InkAnchor(id: "B", label: "llmd", rect: CGRect(x: 300, y: 60, width: 100, height: 40))
private let C = InkAnchor(id: "C", label: "Worker", rect: CGRect(x: 60, y: 260, width: 100, height: 40))
private let diagram = [A, B, C]

private func tag(_ strokes: [[CGPoint]], text: String? = nil, color: InkColorName = .other, anchors: [InkAnchor] = diagram, diff: Bool = false) -> (InkShapeResult, InkNote) {
    let shape = InkGeometry.classify(strokes)
    let h = InkGeometry.letterHeight(strokes.map(InkGeometry.bounds))
    return (shape, InkTagger.note(id: "n", shape: shape, text: text, color: color, anchors: anchors, diff: diff, letterHeight: h))
}

@Test func aLoopAroundOneNodePointsAtItAndAroundTwoGroupsThem() {
    let (s1, n1) = tag([loop(CGPoint(x: 110, y: 80), 80, 45)])
    #expect(s1.shape == .lasso)
    #expect(n1.intent == .emphasize && n1.elements?.map(\.id) == ["A"])
    let (_, n2) = tag([loop(CGPoint(x: 230, y: 80), 210, 60)])
    #expect(n2.intent == .group && Set(n2.elements?.map(\.id) ?? []) == ["A", "B"])
}

@Test func aLoopInsideASubgraphGroupsTheNodesNotTheSubgraph() {
    // A subgraph box around A, B and a third node further right; the loop goes around A and B only.
    let apps = InkAnchor(id: "Apps", label: "Duet apps", rect: CGRect(x: 40, y: 30, width: 600, height: 90))
    let (_, n) = tag([loop(CGPoint(x: 230, y: 80), 210, 60)], anchors: diagram + [apps])
    #expect(n.intent == .group && Set(n.elements?.map(\.id) ?? []) == ["A", "B"])
}

@Test func aLoopWithWordsBesideItReadsOnlyTheWords() {
    let (s, n) = tag([loop(CGPoint(x: 110, y: 80), 80, 45), word(at: CGPoint(x: 200, y: 150)), word(at: CGPoint(x: 250, y: 150))], text: "make this async")
    #expect(s.shape == .lasso && s.gestureStrokes == [0] && s.textStrokes == [1, 2], "only the words go to the recognizer")
    #expect(n.intent == .comment && n.elements?.map(\.id) == ["A"] && n.text == "make this async")
}

@Test func anArrowConnectsWhereItStartsToWhereItPoints() {
    // Drawn in one stroke: the shaft, then the barb.
    let shaft = line(CGPoint(x: 150, y: 80), CGPoint(x: 320, y: 80))
    let (s1, n1) = tag([shaft + line(CGPoint(x: 320, y: 80), CGPoint(x: 302, y: 66), n: 6).dropFirst()])
    #expect(s1.shape == .arrow)
    #expect(n1.intent == .connect && n1.elements?.map(\.id) == ["A", "B"])
    // Shaft, then a two-stroke head at the C end.
    let down = line(CGPoint(x: 110, y: 95), CGPoint(x: 110, y: 270))
    let (s2, n2) = tag([down, line(CGPoint(x: 100, y: 255), CGPoint(x: 110, y: 270), n: 6), line(CGPoint(x: 120, y: 255), CGPoint(x: 110, y: 270), n: 6)])
    #expect(s2.shape == .arrow && s2.gestureStrokes.count == 3)
    #expect(n2.intent == .connect && n2.elements?.map(\.id) == ["A", "C"])
}

@Test func anXRemovesWhatItCrosses() {
    let (s, n) = tag([line(CGPoint(x: 320, y: 62), CGPoint(x: 380, y: 98)), line(CGPoint(x: 380, y: 62), CGPoint(x: 320, y: 98))])
    #expect(s.shape == .cross)
    #expect(n.intent == .remove && n.elements?.map(\.id) == ["B"])
}

@Test func aLineThroughStrikesAndALineUnderUnderlines() {
    let (s1, n1) = tag([line(CGPoint(x: 55, y: 80), CGPoint(x: 165, y: 81))])
    #expect(s1.shape == .line && n1.intent == .remove && n1.elements?.map(\.id) == ["A"])
    let (_, n2) = tag([line(CGPoint(x: 60, y: 110), CGPoint(x: 160, y: 111))])
    #expect(n2.intent == .emphasize && n2.elements?.map(\.id) == ["A"])
}

@Test func aCheckApproves() {
    let v = CGPoint(x: 330, y: 92)
    let (s, n) = tag([line(CGPoint(x: 318, y: 78), v, n: 8) + line(v, CGPoint(x: 352, y: 58), n: 12).dropFirst()])
    #expect(s.shape == .check)
    #expect(n.intent == .approve && n.elements?.map(\.id) == ["B"])
}

@Test func writingIsAboutWhatItsOnAndItsWordsAndInkGiveItsIntent() {
    let words = [word(at: CGPoint(x: 70, y: 66), width: 30), word(at: CGPoint(x: 110, y: 66), width: 30)]
    let (s, q) = tag(words, text: "why so slow?")
    #expect(s.shape == .writing && s.textStrokes == [0, 1])
    #expect(q.intent == .question && q.elements?.map(\.id) == ["A"])
    #expect(tag(words, text: "rename to Router", color: .red).1.intent == .change)
    #expect(tag(words, text: "nice", color: .green).1.intent == .approve)
    #expect(tag(words, text: "keep", color: .other).1.intent == .comment)
}

// A diff: ten 20-point lines of a.py.
private let lines = (1...10).map { InkAnchor(id: "a.py:\($0)", label: "line \($0)", rect: CGRect(x: 0, y: CGFloat($0 - 1) * 20, width: 600, height: 20), file: "a.py", line: $0) }

@Test func onADiffABracketTakesTheLinesBesideItAndMarginWritingTakesItsLine() {
    let (_, bracket) = tag([line(CGPoint(x: 610, y: 45), CGPoint(x: 612, y: 115))], text: nil, anchors: lines, diff: true)
    #expect(bracket.intent == .emphasize && bracket.lines == [InkLines(file: "a.py", start: 3, end: 6, code: "line 3\nline 4\nline 5\nline 6")])
    let (_, note) = tag([word(at: CGPoint(x: 620, y: 62)), word(at: CGPoint(x: 670, y: 62))], text: "off by one", anchors: lines, diff: true)
    #expect(note.intent == .comment && note.lines?.first?.start == 4)
}

@Test func writingOverSeveralLinesIsAboutTheCodeLinesBesideIt() {
    // Two lines of handwriting, y 44 to 87, beside lines 3 to 5 (y 40 to 100): the lines whose middles it spans.
    let (_, two) = tag([word(at: CGPoint(x: 620, y: 44), width: 60), word(at: CGPoint(x: 690, y: 44), width: 60), word(at: CGPoint(x: 620, y: 78), width: 60)],
                       text: "how do I get this working", anchors: lines, diff: true)
    #expect(two.intent == .question && two.lines == [InkLines(file: "a.py", start: 3, end: 4, code: "line 3\nline 4")])
    // One line of handwriting: the one code line it's level with.
    let (_, one) = tag([word(at: CGPoint(x: 620, y: 62)), word(at: CGPoint(x: 670, y: 62))], text: "off by one", anchors: lines, diff: true)
    #expect(one.lines?.map(\.start) == [4] && one.lines?.first?.end == 4)
}

@Test func handwritingCarriesOnAlongItsLineAndOntoTheNextButNotFarOff() {
    // "how do I get this", letters about 20 high, with an underline that mustn't make the letters look small.
    let h = InkGeometry.letterHeight([CGRect(x: 620, y: 100, width: 40, height: 20), CGRect(x: 670, y: 102, width: 30, height: 18),
                                      CGRect(x: 710, y: 100, width: 60, height: 22), CGRect(x: 600, y: 124, width: 300, height: 2)])
    #expect(h == 20)
    let note = CGRect(x: 620, y: 100, width: 300, height: 22)
    #expect(InkGeometry.continues(note, letterHeight: h, with: CGRect(x: 935, y: 101, width: 50, height: 20)), "the next word along")
    #expect(InkGeometry.continues(note, letterHeight: h, with: CGRect(x: 625, y: 130, width: 90, height: 24)), "the next line down")
    #expect(InkGeometry.continues(note, letterHeight: h, with: CGRect(x: 990, y: 140, width: 3, height: 12)), "a question mark's stem, a little further off")
    #expect(!InkGeometry.continues(note, letterHeight: h, with: CGRect(x: 625, y: 190, width: 90, height: 24)), "a new thought three lines down")
    #expect(!InkGeometry.continues(note, letterHeight: h, with: CGRect(x: 100, y: 100, width: 60, height: 20)), "the other margin")
}

@Test func onADiffAStrikeRemovesTheLineAndAnArrowMovesLines() {
    let (_, strike) = tag([line(CGPoint(x: 20, y: 90), CGPoint(x: 400, y: 91))], anchors: lines, diff: true)
    #expect(strike.intent == .remove && strike.lines?.first?.start == 5)
    let shaft = line(CGPoint(x: 300, y: 30), CGPoint(x: 300, y: 150))
    let (_, move) = tag([shaft + line(CGPoint(x: 300, y: 150), CGPoint(x: 290, y: 136), n: 6).dropFirst()], anchors: lines, diff: true)
    #expect(move.intent == .connect && move.lines?.map(\.start) == [2, 8])
}

@Test func aNotesLinesAreFoundAgainAfterTheFileChanges() {
    let note = InkLines(file: "calc.py", start: 6, end: 7, code: "def sub(a, b):\n\"\"\"Return b - a.\"\"\"")
    let before: [Substring] = ["def add(a, b):", "    return a + b", "", "", "", "def sub(a, b):", "    \"\"\"Return b - a.\"\"\"", "    return b - a"]
    #expect(Reanchor.place(note, in: before) == 6...7)
    // Three lines added above: it moves down with its code.
    let after: [Substring] = ["import os", "", ""] + before
    #expect(Reanchor.place(note, in: after) == 9...10)
    // Its first line is still there, the second changed: it stays with the first.
    let edited: [Substring] = before.map { $0.contains("Return b") ? "    \"\"\"Subtract.\"\"\"" : $0 }
    #expect(Reanchor.place(note, in: edited) == 6...7)
    // Gone: nowhere.
    #expect(Reanchor.place(note, in: ["x = 1"]) == nil)
    // Two copies: the one nearer where it was.
    let twice: [Substring] = before + ["", "def sub(a, b):", "    \"\"\"Return b - a.\"\"\""]
    #expect(Reanchor.place(note, in: twice) == 6...7)
    let lines = InkTagger.lineRanges([InkAnchor(id: "L6", label: "def sub(a, b):", rect: .zero, file: "calc.py", line: 6),
                                      InkAnchor(id: "L7", label: "return b - a", rect: CGRect(x: 0, y: 20, width: 1, height: 1), file: "calc.py", line: 7)], connect: false)
    #expect(lines == [InkLines(file: "calc.py", start: 6, end: 7, code: "def sub(a, b):\nreturn b - a")], "every line's code is kept")
}

// MARK: reading the handwriting

@Test func misreadCodeWordsSnapToTheIdentifiersBesideThem() {
    let names = InkSnap.identifiers(in: "    return pickAuto(workers.filter(isIdle), size) // fleet.ts")
    #expect(names.contains("pickAuto") && names.contains("workers") && names.contains("isIdle") && names.contains("fleet.ts"))
    #expect(!names.contains("return"), "keywords aren't names")
    #expect(InkSnap.snap("why does pickAvto skip it?", to: names) == "why does pickAuto skip it?")
    #expect(InkSnap.snap("rename workars", to: names) == "rename workers")
    #expect(InkSnap.snap("is fleet.fs right", to: names) == "is fleet.ts right")
    #expect(InkSnap.snap("wow do I get this working", to: names) == "wow do I get this working", "plain words stay")
    #expect(InkSnap.snap("size it", to: ["sizes", "size"]) == "size it")
    #expect(InkSnap.snap("cat", to: ["car"]) == "cat", "a short word must match exactly")
    #expect(InkSnap.distance("kitten", "sitting") == 3)
}

@Test func theReadingGivesTheNoteItsWordsAndKindUnlessInkOrMenuSaidOtherwise() {
    let note = InkNote(id: "n", intent: .comment, text: "wow do I get this working")
    let reading = HandwritingReading(raw: "wow do I get this working", text: "How do I get this working?", kind: .question, byModel: true)
    let read = HandwritingReader.apply(reading, to: note, color: .other, chosen: false)
    #expect(read.text == "How do I get this working?" && read.intent == .question)
    #expect(HandwritingReader.apply(reading, to: note, color: .red, chosen: false).intent == .comment, "red ink wins")
    #expect(HandwritingReader.apply(reading, to: note, color: .other, chosen: true).intent == .comment, "a choice from the menu wins")
    let cross = InkNote(id: "x", intent: .remove, text: "old")
    #expect(HandwritingReader.apply(HandwritingReading(raw: "old", text: "Old.", kind: .comment), to: cross, color: .other, chosen: false).intent == .remove,
            "a gesture keeps its meaning")
    #expect(reading.summary == "Reads: How do I get this working? · Question")
}

@Test func theModelsAnswerSplitsIntoKindAndText() {
    #expect(HandwritingReader.parse("question | How do I get this working?") == (.question, "How do I get this working?"))
    #expect(HandwritingReader.parse("Change | Do this first.") == (.change, "Do this first."))
    #expect(HandwritingReader.parse("Do this first.") == (nil, "Do this first."))
}

private actor Answers: SentenceRewriter {
    let answer: String
    let delay: Duration
    init(_ answer: String, delay: Duration = .milliseconds(5)) { self.answer = answer; self.delay = delay }
    func prewarm(_ instructions: String) async {}
    func rewrite(_ prompt: RewritePrompt) async throws -> String {
        try? await Task.sleep(for: delay)
        return answer
    }
}

@Test func aNoteInPiecesReadsAsOneQuestion() async {
    let polisher = DictationPolisher(rewriter: Answers("question | How do I get this working?"))
    let r = await HandwritingReader.read("wow do I get this working", about: "line 9: let x = 1", names: [], polisher: polisher)
    #expect(r.text == "How do I get this working?" && r.kind == .question && r.byModel)
    #expect(r.raw == "wow do I get this working")
}

@Test func anUnfaithfulOrSlowReadingFallsBackToTheSnappedWords() async {
    let talker = DictationPolisher(rewriter: Answers("comment | Sure! You can get it working by restarting the hub and then running the tests again."))
    let r = await HandwritingReader.read("why does pickAvto skip it", about: nil, names: ["pickAuto"], polisher: talker)
    #expect(r.text == "why does pickAuto skip it" && r.kind == nil && !r.byModel)
    let slow = DictationPolisher(rewriter: Answers("question | Why?", delay: .seconds(5)))
    let started = ContinuousClock.now
    let late = await HandwritingReader.read("why", about: nil, names: [], polisher: slow)
    #expect(late.text == "why")
    #expect(ContinuousClock.now - started < .seconds(7))
}
