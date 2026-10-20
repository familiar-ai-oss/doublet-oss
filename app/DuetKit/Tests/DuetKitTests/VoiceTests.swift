import Testing
@testable import DuetKit

// MARK: what to say

@Test func proseReadsAsWrittenWithoutMarkdownMarks() {
    let reply = """
    ## What auto does

    It picks the **idle** worker with the *shortest* queue, and prefers [the small model](https://example.com/x) for small tasks.
    """
    #expect(Speakable.text(reply) == "What auto does. It picks the idle worker with the shortest queue, and prefers the small model for small tasks.")
}

@Test func codeBlocksAndTablesStayOnScreenAndAreMentionedOnce() {
    let reply = """
    Here's the fix:

    ```ts
    return idle[0] ?? shortest(fit);
    ```

    And the test:

    ```ts
    assert.equal(pickAuto(ws, 'small'), small);
    ```

    | worker | takes |
    |---|---|
    | qwen-9b | small |

    That's all.
    """
    #expect(Speakable.text(reply) == "Here's the fix: The code is on screen. And the test: The table is on screen. That's all.")
}

@Test func pathsShrinkToTheFileAndLine() {
    #expect(Speakable.text("The bug is in /home/you/duet-hub/src/fleet.ts:42.") == "The bug is in fleet.ts line 42.")
    #expect(Speakable.text("See `src/dialogue.ts:120-140` for the hooks") == "See dialogue.ts lines 120 to 140 for the hooks.")
    #expect(Speakable.text("Run `make test` and check ~/duet-sim/hub.log") == "Run make test and check hub.log.")
    // Not paths: words with slashes and no file name, and version numbers.
    #expect(Speakable.text("Use and/or in v1.2") == "Use and/or in v1.2.")
}

@Test func longInlineCodeAndBareLinksAreNotReadOut() {
    #expect(Speakable.text("Run `node --experimental-strip-types --test --test-concurrency=1 test/*.test.ts` first.") == "Run the code on screen first.")
    #expect(Speakable.text("Docs: https://developer.apple.com/documentation/speech/speechanalyzer") == "Docs: developer.apple.com.")
}

@Test func listItemsAndHeadingsAreSentencesOfTheirOwn() {
    let reply = """
    Three things changed
    - the queue is FIFO
    - small tasks prefer qwen-9b
    1. tests pass
    """
    #expect(Speakable.text(reply) == "Three things changed. the queue is FIFO. small tasks prefer qwen-9b. tests pass.")
}

@Test func identifiersKeepTheirUnderscoresAndStars() {
    #expect(Speakable.text("Set max_turns to 2*3 in snake_case_name") == "Set max_turns to 2*3 in snake_case_name.")
    #expect(Speakable.text("Arrows: A → B and C -> D") == "Arrows: A to B and C to D.")
}

@Test func speechSplitsIntoSentencesAtTheirEnds() {
    // A sentence starts with a capital or a digit: "e.g. the" and "fleet.ts" don't end one.
    let s = Speakable.sentences("It's done. The tests pass! Want me to commit? e.g. the fix in fleet.ts is small. 2 files changed.")
    #expect(s == ["It's done.", "The tests pass!", "Want me to commit? e.g. the fix in fleet.ts is small.", "2 files changed."])
}

@Test func aLongSentenceBreaksNearItsMiddleComma() {
    let long = "The scheduler gives each worker one slot and a first in first out queue, so a task waits behind the one before it, and auto picks the idle worker first, then the shortest queue for the task's size"
    let parts = Speakable.sentences(long, longest: 120)
    #expect(parts.count >= 2)
    #expect(parts.allSatisfy { $0.count <= 120 })
    #expect(parts.joined(separator: " ") == long)
}

// MARK: what's been said

@Test func aSettledResultReplacesTheGuess() {
    var t = LiveTranscript()
    t.apply("what does", isFinal: false)
    #expect(t.text == "what does")
    t.apply("what does auto", isFinal: false)
    t.apply("What does auto do", isFinal: true)
    #expect(t.settled == "What does auto do" && t.guess.isEmpty)
    t.apply(" for small", isFinal: false)
    #expect(t.text == "What does auto do for small")
    t.apply("?", isFinal: true)
    #expect(t.text == "What does auto do?")
    #expect(t.words == 4)
    t.reset()
    #expect(t.isEmpty)
}

private func run(_ text: String, _ start: Double, _ end: Double) -> Heard.Run { Heard.Run(text, start, end) }

@Test func aGuessReplacesOnlyTheGuessFromWhereItStarts() {
    var t = LiveTranscript()
    t.apply(Heard(text: "what does", isFinal: false, runs: [run("what", 0, 0.3), run("does", 0.3, 0.6)]))
    t.apply(Heard(text: "What does auto", isFinal: true, runs: [run("What", 0, 0.3), run("does", 0.3, 0.6), run("auto", 0.6, 0.9)]))
    #expect(t.settled == "What does auto" && t.guess.isEmpty)
    // A guess for later audio leaves the settled words alone.
    t.apply(Heard(text: "do for", isFinal: false, runs: [run("do", 0.9, 1.1), run("for", 1.1, 1.3)]))
    #expect(t.text == "What does auto do for")
    // A new guess from 1.1 s replaces "for" onward, and keeps "do": nothing blinks.
    t.apply(Heard(text: "for small", isFinal: false, runs: [run("for", 1.1, 1.3), run("small", 1.3, 1.6)]))
    #expect(t.guess == "do for small")
    // A final for part of the guess settles just those words; the rest stays a guess.
    t.apply(Heard(text: "do", isFinal: true, runs: [run("do", 0.9, 1.1)]))
    #expect(t.settled == "What does auto do" && t.guess == "for small")
}

@Test func aSkippedFinalIsPromotedByTime() {
    var t = LiveTranscript()
    t.apply(Heard(text: "open the parser", isFinal: false, runs: [run("open", 0, 0.3), run("the", 0.3, 0.5), run("parser", 0.5, 0.9)]))
    t.apply(Heard(text: "and", isFinal: false, runs: [run("and", 1.4, 1.6)], finalThrough: 1.0))
    #expect(t.settled == "open the parser", "the recognizer never sent a final for it, but it's final through 1 s")
    #expect(t.guess == "and")
    #expect(t.lastHeard == 1.6)
}

@Test func aFinalForPartOfAGuessKeepsTheRestAndFinishingSettlesAll() {
    // As Apple's recognizer does it: a guess is one run over its span, a final comes word by word.
    var t = LiveTranscript()
    t.apply(Heard(text: "Please ask the small", isFinal: false, runs: [run("Please ask the small", 0, 1.0)]))
    t.apply(Heard(text: "Please ask.", isFinal: true, runs: [run("Please", 0, 0.3), run("ask.", 0.3, 0.6)], finalThrough: 0.6))
    #expect(t.settled == "Please ask." && t.guess == "the small", "the words the final didn't reach stay on screen")
    t.apply(Heard(text: "the small worker", isFinal: false, runs: [run("the small worker", 0.6, 1.4)]))
    #expect(t.text == "Please ask. the small worker")
    // No final for the last guess (it didn't change): finishing settles it anyway.
    t.end()
    #expect(t.settled == "Please ask. the small worker" && t.guess.isEmpty)
}

@Test func settledWordsSplitIntoSentencesAndTidyOneByOne() {
    var t = LiveTranscript()
    t.apply("um open the lexer, no wait, the parser. Then run the tests in fleet.ts.", isFinal: true)
    t.apply("and", isFinal: false)
    #expect(t.sentences == ["um open the lexer, no wait, the parser.", "Then run the tests in fleet.ts."])
    #expect(t.untidied() == t.sentences)
    let first = t.sentences[0]
    t.asking(first)
    #expect(t.untidied() == [t.sentences[1]], "asked once")
    #expect(t.before(t.sentences[1]) == first)
    t.tidy(first, as: "Open the parser.")
    #expect(t.text == "Open the parser. Then run the tests in fleet.ts. and")
    #expect(t.parts.map(\.style) == [.tidied, .settled, .guess])
    #expect(t.raw.hasPrefix("um open the lexer"), "the raw words are kept")
    // Undo.
    t.showsTidy = false
    #expect(t.text.hasPrefix("um open the lexer"))
    #expect(!t.isTidied)
}

@Test func anUnfinishedSentenceWaitsUntilYouveFinished() {
    var t = LiveTranscript()
    t.apply("look at the scheduler", isFinal: true)
    #expect(t.untidied().isEmpty)
    #expect(t.untidied(all: true) == ["look at the scheduler"])
}

@Test func startingAfreshKeepsWhatCameAfter() {
    var t = LiveTranscript()
    t.apply(Heard(text: "send this", isFinal: true, runs: [run("send", 0, 0.4), run("this", 0.4, 0.8)]))
    t.apply(Heard(text: "and then", isFinal: false, runs: [run("and", 1.2, 1.4), run("then", 1.4, 1.6)]))
    t.reset(after: 0.8)
    #expect(t.text == "and then")
    // The recognizer's late final for the words already sent doesn't bring them back.
    t.apply(Heard(text: "Send this.", isFinal: true, runs: [run("Send", 0, 0.4), run("this.", 0.4, 0.8)]))
    #expect(t.text == "and then")
    t.reset()
    #expect(t.isEmpty)
}

// MARK: when you've finished

@Test func aPauseEndsTheTurnButLongerAfterAnUnfinishedThought() {
    let timer = TurnTimer(pause: 1.0)
    #expect(!timer.isOver("", quietFor: 10), "nothing said, nothing to send")
    #expect(!timer.isOver("Find the bug", quietFor: 0.5))
    #expect(timer.isOver("Find the bug", quietFor: 1.0))
    #expect(!timer.isOver("Find the bug and", quietFor: 1.2), "still thinking")
    #expect(timer.isOver("Find the bug and", quietFor: 1.8))
    #expect(!timer.isOver("Look at fleet.ts, um", quietFor: 1.5))
    #expect(!timer.isOver("First,", quietFor: 1.5))
    #expect(timer.isOver("What is a?", quietFor: 1.0), "a question mark ends it even after 'a'")
}

// MARK: talking over

@Test func talkingOverDuetIsYouButItsOwnEchoIsNot() {
    let saying = "The scheduler gives each worker one slot and a first in, first out queue."
    #expect(!BargeIn.isYou("the scheduler gives", saying: saying), "its own words")
    #expect(!BargeIn.isYou("worker queue scheduler", saying: saying), "its own words, out of order")
    #expect(!BargeIn.isYou("the schedule are", saying: saying), "garbled echo: one stray word isn't you")
    #expect(!BargeIn.isYou("stop", saying: saying), "one word could be noise")
    #expect(BargeIn.isYou("wait, stop", saying: saying))
    #expect(BargeIn.isYou("the scheduler gives wait stop", saying: saying), "you, after some of its echo")
    #expect(BargeIn.isYou("no, use the other file", saying: "I'll use the fleet file"))
    #expect(BargeIn.isYou("hang on a second", saying: ""))
}

// MARK: status in words

@Test func claudesStatusSaysWhatItIsDoingInWords() {
    #expect(LeadStatus(phase: .tool("WebFetch")).label == "Reading a web page")
    #expect(LeadStatus(phase: .tool("WebSearch")).label == "Searching the web")
    #expect(LeadStatus(phase: .tool("Edit")).label == "Editing files")
    #expect(LeadStatus(phase: .tool("mcp__duet__await_workers")).label == "Running await workers")
}

@Test func talkModeSaysTheStartOfALongReplyAndPointsToTheRest() {
    let short = ["It picks the idle worker.", "Small tasks prefer the small model."]
    #expect(Speakable.brief(short) == short, "a short reply is said in full")
    let long = (1...20).map { "Sentence number \($0) has exactly seven words." }
    let said = Speakable.brief(long, words: 30)
    #expect(said.last == "There's more on screen.")
    #expect(said.dropLast().count == 4, "whole sentences up to about 30 words")
    #expect(Speakable.brief(["One very long opening sentence " + String(repeating: "word ", count: 200)], words: 30).count == 1, "never less than the first sentence")
}
