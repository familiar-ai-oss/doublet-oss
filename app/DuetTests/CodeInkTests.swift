import CoreGraphics
import DuetKit
import Foundation
import Testing
@testable import Duet

/// Pen notes on a native code page: grouping, what a note is about (the mark first, the nearest line last), and
/// which notes ask themselves.
@MainActor
struct CodeInkTests {
    // 30 lines: "    let value1 = compute1(1)" and so on. At 16 pt with 10 pt characters: rows 24 high from y 12, code from x 64.
    private static let text = (1...30).map { "    let value\($0) = compute\($0)(\($0))" }.joined(separator: "\n")
    private let g = CodePageGeometry(text: text, advance: 10, fontSize: 16)
    private var lines: [Substring] { Self.text.split(separator: "\n", omittingEmptySubsequences: false) }

    private func top(_ n: Int) -> CGFloat { g.rect(line: n, width: 1).minY }

    // MARK: grouping

    @Test func aStrokeSoonAfterTheLastJoinsTheNote() {
        let note = CGRect(x: 100, y: 228, width: 120, height: 40), t = Date()
        let near = CGRect(x: 300, y: 230, width: 12, height: 20)
        #expect(CodeGrouping.joins(note: note, letterHeight: 20, lastEnd: t, stroke: near, start: t.addingTimeInterval(0.4)))
        // The same stroke a second later is its own note: it's not right beside this one.
        #expect(!CodeGrouping.joins(note: note, letterHeight: 20, lastEnd: t, stroke: near, start: t.addingTimeInterval(1.0)))
        // Right beside it, it joins however long the pause.
        let beside = CGRect(x: 225, y: 240, width: 10, height: 18)
        #expect(CodeGrouping.joins(note: note, letterHeight: 20, lastEnd: t, stroke: beside, start: t.addingTimeInterval(5)))
        // Quick, but across the page: not the same note.
        let far = CGRect(x: 900, y: 1200, width: 12, height: 20)
        #expect(!CodeGrouping.joins(note: note, letterHeight: 20, lastEnd: t, stroke: far, start: t.addingTimeInterval(0.2)))
    }

    // MARK: is it a question?

    @Test func aQuestionEndsInAQuestionMarkOrStartsWithAQuestionWord() {
        #expect(CodeQuestion.asks("why is this here"))
        #expect(CodeQuestion.asks("this is called twice?"))
        #expect(CodeQuestion.asks(" ? "))
        #expect(!CodeQuestion.asks("rename to count"))
        #expect(!CodeQuestion.asks(nil))
        #expect(CodeQuestion.isLone("?") && CodeQuestion.isLone("??") && !CodeQuestion.isLone("why?"))
    }

    @Test func theRuleRunsOnTheTidiedReadingToo() {
        let span = CodeSpan(start: 10, end: 10, step: 2)
        // PencilKit missed the "?", the tidied reading has it.
        #expect(CodeDecision.of(shape: .lasso, strike: false, raw: "is this ever nil", tidied: "Is this ever nil?", kind: nil, span: span)
                == .ask("Is this ever nil?", shown: false))
        // Neither has it, and the model doesn't call it a question: a note.
        #expect(CodeDecision.of(shape: .lasso, strike: false, raw: "rename", tidied: "Rename", kind: .change, span: span) == .note)
        // Only the model calls it a question: asked, but with its target shown.
        #expect(CodeDecision.of(shape: .lasso, strike: false, raw: "this nil", tidied: "This nil", kind: .question, span: span)
                == .ask("This nil", shown: true))
    }

    @Test func aMarkWithALoneQuestionMarkAsksWhatItMeans() {
        let span = CodeSpan(start: 10, end: 12, step: 2)
        #expect(CodeDecision.of(shape: .lasso, strike: false, raw: "?", tidied: nil, kind: nil, span: span) == .ask(CodeDecision.whatDoesThisMean, shown: false))
    }

    @Test func aMarkWithoutWordsNeverAsks() {
        let span = CodeSpan(start: 10, end: 12, step: 2)
        for shape in [InkShape.lasso, .line, .arrow, .dot] {
            #expect(CodeDecision.of(shape: shape, strike: false, raw: nil, tidied: nil, kind: nil, span: span) == .none)
            #expect(CodeDecision.of(shape: shape, strike: false, raw: "  ", tidied: nil, kind: .question, span: span) == .none)
        }
        // A check or a cross accepts or rejects; striking code out asks for a change.
        #expect(CodeDecision.of(shape: .check, strike: false, raw: "why?", tidied: nil, kind: nil, span: span) == .note)
        #expect(CodeDecision.of(shape: .line, strike: true, raw: "why?", tidied: nil, kind: nil, span: span) == .note)
    }

    @Test func aQuestionOnTheNearestLineIsAlwaysShown() {
        let fallback = CodeSpan(start: 13, end: 13, step: 5)
        #expect(CodeDecision.of(shape: .writing, strike: false, raw: "why twice?", tidied: nil, kind: nil, span: fallback) == .ask("why twice?", shown: true))
        #expect(!fallback.rects(in: g).isEmpty)
    }

    // MARK: what it's about: the mark first

    @Test func aCircleOverLinesTenToTwelveIsAboutThem() {
        let ellipse = (0...40).map { i -> CGPoint in
            let a = Double(i) / 40 * 2 * .pi
            return CGPoint(x: 240 + 170 * cos(a), y: (top(10) + g.rect(line: 12, width: 1).maxY) / 2 + 46 * sin(a))
        }
        let shape = InkGeometry.classify([ellipse])
        #expect(shape.shape == .lasso)
        let (span, strike) = CodeAnchors.resolve(shape, geometry: g, lines: lines)
        #expect(span.step == 2 && span.start == 10 && span.end == 12 && !strike)
    }

    @Test func anUnderlineIsAboutTheWordsItCrosses() {
        // Under "compute10" (characters 18-26) on line 10.
        let y = top(10) + g.lineHeight - 2
        let stroke = stride(from: 246.0, through: 332.0, by: 4).map { CGPoint(x: $0, y: y) }
        let shape = InkGeometry.classify([stroke])
        #expect(shape.shape == .line)
        let (span, strike) = CodeAnchors.resolve(shape, geometry: g, lines: lines)
        #expect(span.step == 3 && span.start == 10 && span.from == 18 && span.to == 26 && !strike)
    }

    @Test func aLineThroughCodeStrikesItOut() {
        let y = top(10) + g.lineHeight / 2
        let stroke = stride(from: 246.0, through: 332.0, by: 4).map { CGPoint(x: $0, y: y) }
        let (span, strike) = CodeAnchors.resolve(InkGeometry.classify([stroke]), geometry: g, lines: lines)
        #expect(span.step == 3 && span.start == 10 && strike)
    }

    @Test func anArrowIsAboutWhereItPoints() {
        // From the margin to "compute10" on line 10, with a head drawn back from the tip.
        let tip = CGPoint(x: 300, y: top(10) + 12)
        let shaft = (0...30).map { i in CGPoint(x: 560 - (560 - tip.x) * CGFloat(i) / 30, y: 420 - (420 - tip.y) * CGFloat(i) / 30) }
        let barb = (1...6).map { i in CGPoint(x: tip.x + CGFloat(i) * 4, y: tip.y + CGFloat(i) * 1) }
        let shape = InkGeometry.classify([shaft + barb])
        #expect(shape.shape == .arrow)
        let (span, _) = CodeAnchors.resolve(shape, geometry: g, lines: lines)
        #expect(span.step == 1 && span.start == 10 && span.from == 18 && span.to == 26)
    }

    @Test func writingAloneFallsBackToTheNearestLine() {
        // Short strokes, like letters, beside line 13.
        let y = top(13) + 4
        let letters = (0..<5).map { k in (0...6).map { i in CGPoint(x: 420 + CGFloat(k) * 14 + CGFloat(i), y: y + CGFloat(i % 3) * 5) } }
        let shape = InkGeometry.classify(letters)
        #expect(shape.shape == .writing)
        let (span, _) = CodeAnchors.resolve(shape, geometry: g, lines: lines)
        #expect(span.step == 5 && span.start == 13 && span.isFallback)
    }

    @Test func aNotesLinesAndCodeComeFromItsMark() {
        let y = top(10) + g.lineHeight - 2
        let stroke = stride(from: 246.0, through: 332.0, by: 4).map { CGPoint(x: $0, y: y) }
        let (note, span, _) = CodeTagger.note(id: "n", shape: InkGeometry.classify([stroke]), text: "why?", color: .other, path: "/p/a.swift", geometry: g, lines: lines)
        #expect(note.intent == .question)
        #expect(note.lines == [InkLines(file: "/p/a.swift", start: 10, end: 10, code: "    let value10 = compute10(10)")])
        #expect(span.rects(in: g).count == 1)
    }

    @Test func codeRectsCoverOnlyTheCode() {
        let r = g.codeRects(line: 10)
        #expect(r.count == 1)
        #expect(r[0].minX == g.codeX + 4 * 10) // after its indent
        #expect(r[0].maxX == g.codeX + CGFloat(g.length(line: 10)) * 10)
    }
}
