import DuetKit
import Foundation
import Testing
@testable import Duet

/// A note's pill says what it's about in at most three words: as written when short, a gist made on the device when
/// not, and its first three words until then.
@MainActor
struct NoteGistTests {
    @Test func threeWordsOrFewerShowAsWritten() {
        #expect(NoteGist.isShort("why emit here?"))
        #expect(NoteGist.fallback("why emit here?") == "why emit here?")
        #expect(NoteGist.fallback("  rename   this ") == "rename this")
        #expect(!NoteGist.isShort("why save start before step?"))
    }

    @Test func longerNotesFallBackToTheirFirstThreeWords() {
        #expect(NoteGist.fallback("why save start before step?") == "why save start…")
        #expect(NoteGist.fallback("one two three four") == "one two three…")
    }

    @Test func theModelsGistIsHeldToThreeWords() {
        #expect(NoteGist.clean("\"Start before step.\"") == "Start before step")
        #expect(NoteGist.clean("Saving start index early") == "Saving start index")
        #expect(NoteGist.clean("  ") == nil)
        #expect(NoteGist.clean("emit(.string) order") == "emit(.string) order") // code names kept as written
    }

    @Test func aGistIsMadeOnceAndAgainWhenTheAnswerArrives() {
        let code = "    while index < source.endIndex {\n        start = index\n        step(source[index])"
        let asked = NoteGist.key(question: "why save start before step?", code: code, answer: nil)
        #expect(asked == NoteGist.key(question: "why save start before step?", code: code, answer: nil))
        let answered = NoteGist.key(question: "why save start before step?", code: code, answer: "So each token knows where it began.")
        #expect(answered != asked)
        // Another line's code is another gist.
        #expect(NoteGist.key(question: "why save start before step?", code: "start = index", answer: nil) != asked)
    }

    @Test func itsInputsAreTheLineAroundAndTheAnswersFirstSentence() {
        let lines = "a\nb\nc\nd".split(separator: "\n", omittingEmptySubsequences: false)
        #expect(NoteGist.code(around: 2, in: lines) == "a\nb\nc")
        #expect(NoteGist.code(around: 1, in: lines) == "a\nb")
        #expect(NoteGist.code(around: 4, in: lines) == "c\nd")
        #expect(NoteGist.code(around: 9, in: lines) == "")
        #expect(NoteGist.firstSentence("Let me check.\n\nIt marks where the token began. Then step moves on.") == "It marks where the token began.")
    }

    @Test func aShortNoteNeedsNoModel() {
        let gists = NoteGists()
        #expect(gists.gist(question: "rename this", code: "", answer: nil) == "rename this")
        // A long one shows its first words at once, while its gist is made (or for good, without the model).
        #expect(gists.gist(question: "why save start before step?", code: "x", answer: nil) == "why save start…")
    }
}
