#if os(iOS)
import DuetKit
import Foundation
import PencilKit
import Testing
@testable import Duet

/// The decluttered code page: one pill per line while it wants you, answers opening under their line, erasing a note
/// deleting it everywhere (after Undo's chance), and tag suggestions tidied onto existing tags.
@MainActor
struct TrackDTests {
    private static func mark(_ id: String, state: String, answer: String?, resolved: Bool = false, answering: Bool = false) -> LineMark {
        LineMark(ids: [id], state: state, history: [NoteCard(id: id, question: "why?", answer: answer, resolved: resolved)], answering: answering)
    }

    @Test func aLineWantsYouOnlyWhileThereIsSomethingForYou() {
        #expect(Self.mark("a", state: "open", answer: nil, answering: true).wantsYou)
        #expect(Self.mark("a", state: "answered", answer: "Because…").wantsYou)
        #expect(!Self.mark("a", state: "resolved", answer: "Because…", resolved: true).wantsYou)
        var decor = CodePageDecor()
        decor.marks = [21: Self.mark("a", state: "resolved", answer: "x", resolved: true)]
        #expect(!decor.hasCards) // a resolved line takes no room beside the code
    }

    @Test func aNewAnswerOpensUnderItsLine() {
        var before = CodePageDecor(), after = CodePageDecor()
        before.marks = [21: Self.mark("a", state: "open", answer: nil, answering: true), 30: Self.mark("b", state: "answered", answer: "old")]
        after.marks = [21: Self.mark("a", state: "answered", answer: "Because…"), 30: Self.mark("b", state: "answered", answer: "old")]
        #expect(NativeCodeInkView.newlyAnswered(from: before, to: after) == 21)
        #expect(NativeCodeInkView.newlyAnswered(from: after, to: after) == nil) // nothing new
        // Resolved straight away: nothing to open.
        var resolved = CodePageDecor()
        resolved.marks = [21: Self.mark("a", state: "resolved", answer: "Because…", resolved: true)]
        #expect(NativeCodeInkView.newlyAnswered(from: before, to: resolved) == nil)
    }

    @Test func suggestionsReuseExistingTagsAndStopAtFive() {
        let tidy = TagSuggestions.tidy(["Cyber", " storage ", "cyber", "", "Call Map", "a", "b", "c"], existing: ["cyber", "Call Map"])
        #expect(tidy == ["cyber", "storage", "Call Map", "a", "b"])
    }

    @Test func erasingASentNoteDeletesItAfterUndosChance() async throws {
        let canvas = PKCanvasView()
        let taker = InkNoteTaker(canvas: canvas)
        let s = Self.stroke()
        var d = DraftNote(note: InkNote(id: "n", intent: .question, text: "why?"), strokeIDs: [s.id], bounds: s.renderBounds)
        d.sent = true
        taker.load(PKDrawing(strokes: [s]), drafts: [d])
        var erased: [String] = []
        taker.onErased = { erased.append($0) }
        // Rubbed out, then brought back by Undo within the window: kept.
        canvas.drawing = PKDrawing()
        taker.drawingChanged()
        #expect(taker.drafts.isEmpty)
        canvas.drawing = PKDrawing(strokes: [s])
        taker.drawingChanged()
        #expect(taker.drafts.map(\.id) == ["n"])
        try await Task.sleep(for: InkNoteTaker.undoWindow + .milliseconds(300))
        #expect(erased.isEmpty)
        // Rubbed out for good: deleted once the window passes.
        canvas.drawing = PKDrawing()
        taker.drawingChanged()
        try await Task.sleep(for: InkNoteTaker.undoWindow + .milliseconds(300))
        #expect(erased == ["n"])
    }

    private static func stroke() -> PKStroke {
        let points = (0..<10).map { i in
            PKStrokePoint(location: CGPoint(x: 100 + CGFloat(i) * 4, y: 100), timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
}
#endif
