import Foundation
import Synchronization
import Testing
@testable import DuetKit

// MARK: is it faithful?

@Test func aTidyMayDropFillersAndApplyASelfCorrection() {
    #expect(PolishCheck.judge(original: "um so open the lexer, no wait, the parser", rewrite: "So open the parser.").text == "So open the parser.")
    #expect(PolishCheck.judge(original: "can you uh look at the the scheduler", rewrite: "Can you look at the scheduler?").text == "Can you look at the scheduler?")
    #expect(PolishCheck.judge(original: "rename it, you know, to something shorter", rewrite: "Rename it to something shorter.").text != nil)
    #expect(PolishCheck.judge(original: "open parser dot swift", rewrite: "Open parser.swift.").text == "Open parser.swift.", "symbols said aloud")
    #expect(PolishCheck.judge(original: "set max underscore turns to 3", rewrite: "Set max_turns to 3.").text != nil)
}

@Test func whatIsLeftOnceFillersAndCorrectionsGo() {
    #expect(PolishCheck.expected("um open the lexer, no wait, the parser") == "open the parser")
    #expect(PolishCheck.expected("I I think uh it's fine") == "I think it's fine")
    #expect(PolishCheck.expected("look at line 40, sorry, I mean line 42") == "look at line 42")
}

@Test func aTidyKeepsNamesPathsAndNumbersExactly() {
    #expect(PolishCheck.judge(original: "look at fleet.ts line 42", rewrite: "Look at fleet.ts line 24.") == .reject("lost “42”"))
    #expect(PolishCheck.judge(original: "ask qwen-9b about src/fleet.ts", rewrite: "Ask Qwen about the fleet file.").text == nil)
    #expect(PolishCheck.judge(original: "call pickAuto with the small size", rewrite: "Call pick auto with the small size.").text == nil, "an identifier")
    #expect(PolishCheck.judge(original: "tell Brendan the tests pass", rewrite: "Tell them the tests pass.").text == nil, "a name")
    #expect(PolishCheck.judge(original: "send it to duet", rewrite: "Send it to Duet.", vocabulary: ["Duet"]).text == "Send it to Duet.", "the project's spelling may be fixed")
}

@Test func aTidyNeverTalksBackOrRunsOn() {
    #expect(PolishCheck.judge(original: "what does auto do", rewrite: "Sure! Auto picks the idle worker.").text == nil)
    #expect(PolishCheck.judge(original: "what does auto do", rewrite: "Here's the tidied text: What does auto do?").text == nil)
    #expect(PolishCheck.judge(original: "fix the bug", rewrite: "Fix the bug in the scheduler so that every worker gets one slot and the queue is fair.").text == nil, "too long")
    #expect(PolishCheck.judge(original: "fix the bug in the scheduler please and then run the tests", rewrite: "Fix it.").text == nil, "too short")
    #expect(PolishCheck.judge(original: "is it done?", rewrite: "It is done.").text == nil, "a question stays a question")
    #expect(PolishCheck.judge(original: "what does auto do", rewrite: "What does auto do?\nIt picks.").text == nil)
    #expect(PolishCheck.judge(original: "what does auto do", rewrite: "“What does auto do?”").text == "What does auto do?", "quotes unwrapped")
    #expect(PolishCheck.judge(original: "what does auto do", rewrite: "<said>What does auto do?</said>").text == "What does auto do?")
}

// MARK: one at a time

/// A stand-in for the model: answers after `delay`, in the order asked, and counts what it's asked.
private actor FakeRewriter: SentenceRewriter {
    var delay: Duration
    var answer: (String) -> String
    var fail: RewriterError?
    private(set) var asked: [String] = []
    private(set) var concurrent = 0
    private(set) var mostConcurrent = 0

    init(delay: Duration = .milliseconds(10), fail: RewriterError? = nil, answer: @escaping (String) -> String = { _ in "What does auto do?" }) {
        self.delay = delay; self.fail = fail; self.answer = answer
    }

    func prewarm(_ instructions: String) async {}

    func rewrite(_ prompt: RewritePrompt) async throws -> String {
        asked.append(prompt.input)
        concurrent += 1
        mostConcurrent = max(mostConcurrent, concurrent)
        defer { concurrent -= 1 }
        try? await Task.sleep(for: delay)
        if let fail { throw fail }
        return answer(prompt.input)
    }
}

@Test func thePolisherTidiesASentenceAndChecksIt() async {
    let polisher = DictationPolisher(rewriter: FakeRewriter())
    #expect(await polisher.polishSpeech("what does auto do") == .tidied("What does auto do?"))
    let liar = DictationPolisher(rewriter: FakeRewriter { _ in "Sure! It picks the idle worker." })
    #expect(await liar.polishSpeech("what does auto do") == .kept("talks back"))
    let same = DictationPolisher(rewriter: FakeRewriter { _ in "What does auto do?" })
    #expect(await same.polishSpeech("What does auto do?") == .kept("unchanged"))
}

@Test func thePolisherRunsOneAtATimeAndDropsTheOldestWaiting() async {
    let fake = FakeRewriter(delay: .milliseconds(80))
    let polisher = DictationPolisher(rewriter: fake, maxWaiting: 3)
    let outcomes = await withTaskGroup(of: (Int, DictationPolisher.Outcome).self) { group in
        for i in 0..<6 {
            group.addTask {
                // In order: each asks a moment after the one before.
                try? await Task.sleep(for: .milliseconds(5 * i))
                return (i, await polisher.polishSpeech("what does auto do"))
            }
        }
        var out: [Int: DictationPolisher.Outcome] = [:]
        for await (i, o) in group { out[i] = o }
        return out
    }
    #expect(await fake.mostConcurrent == 1, "one request at a time")
    let dropped = outcomes.values.filter { $0 == .skipped("too many waiting") }.count
    #expect(dropped == 2, "one runs, three wait, the two oldest waiting are dropped: \(outcomes)")
    #expect(outcomes[0] == .tidied("What does auto do?"), "the first runs")
    #expect(outcomes[5] != .skipped("too many waiting"), "the newest is kept")
}

@Test func thePolisherKeepsToItsBudgetAndTurnsOffAfterThreeTimeouts() async {
    let slow = FakeRewriter(delay: .milliseconds(300))
    let polisher = DictationPolisher(rewriter: slow)
    let prompt = Polish.voicePrompt("what does auto do")
    let started = ContinuousClock.now
    let first = await polisher.polish("what does auto do", prompt, budget: .milliseconds(50)) { .accept($0) }
    #expect(first == .timedOut)
    // It waits for the model to finish the request that ran out, so the next doesn't collide with it.
    #expect(ContinuousClock.now - started < .seconds(2))
    _ = await polisher.polish("what does auto do", prompt, budget: .milliseconds(50)) { .accept($0) }
    _ = await polisher.polish("what does auto do", prompt, budget: .milliseconds(50)) { .accept($0) }
    #expect(await polisher.off != nil, "three timeouts turn it off")
    #expect(await polisher.polish("what does auto do", prompt, budget: .seconds(1)) { .accept($0) } == .skipped("too slow on this device"))
    await polisher.reset()
    #expect(await polisher.off == nil)
}

@Test func thePolisherSkipsWhileTheModelIsBusyAndStopsForAnUnsupportedLanguage() async {
    let busy = Mutex(true)
    let fake = FakeRewriter()
    let polisher = DictationPolisher(rewriter: fake, isBusy: { busy.withLock { $0 } })
    #expect(await polisher.polishSpeech("what does auto do") == .skipped("Apple Intelligence is busy"))
    #expect(await fake.asked.isEmpty, "not asked while busy")
    busy.withLock { $0 = false }
    #expect(await polisher.polishSpeech("what does auto do") == .tidied("What does auto do?"))

    let foreign = DictationPolisher(rewriter: FakeRewriter(fail: .unsupportedLanguage))
    #expect(await foreign.polishSpeech("was macht auto") == .skipped("Apple Intelligence doesn't read this language"))
    #expect(await foreign.off != nil)
}

@Test func theVoicePromptCarriesItsContext() {
    let p = Polish.voicePrompt("open the parser", before: "Look at the lexer.", vocabulary: ["Duet", "qwen-9b"], about: "fleet.ts:42 return idle[0]")
    #expect(p.instructions == Polish.voiceInstructions)
    #expect(p.input.contains("Look at the lexer.") && p.input.contains("qwen-9b") && p.input.contains("fleet.ts:42"))
    #expect(p.input.hasSuffix("<said>open the parser</said>"))
}

/// The real on-device model, where this Mac has it: how long a sentence takes, and whether its tidy passes the check.
@Test(.timeLimit(.minutes(1))) func appleTidiesASentenceOnTheDevice() async {
    let rewriter = AppleRewriter(locale: Locale(identifier: "en-US"))
    guard rewriter.isAvailable else { print("Apple Intelligence unavailable here: nothing to time"); return }
    let polisher = DictationPolisher(rewriter: rewriter)
    await polisher.prewarm(Polish.voiceInstructions)
    for said in ["um so open the lexer, no wait, the parser", "can you uh check why the the tests in fleet.ts fail"] {
        let t0 = ContinuousClock.now
        let r = await polisher.polish(said, Polish.voicePrompt(said), budget: .seconds(10)) { PolishCheck.judge(original: said, rewrite: $0) }
        print("  tidied in \(ContinuousClock.now - t0): \(said) → \(r)")
        #expect(r != .timedOut)
    }
}
