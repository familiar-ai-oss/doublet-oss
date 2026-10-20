import Foundation
import FoundationModels
import Synchronization

// Tidying what a recognizer heard, on the device: dictated speech and Apple Pencil handwriting both come out of their
// recognizers as raw words, and the on-device Apple Intelligence model turns them into what you meant, the way iOS 27's
// Advanced Dictation does on the keyboard (there's no API for that pass, so Duet makes its own). Nothing here goes to
// Claude as fact: the raw words are always kept, a rewrite is only taken when `PolishCheck` finds it faithful, and Undo
// puts the raw words back.

// MARK: the model

/// What to ask the model: its standing instructions, then the text to rewrite.
public struct RewritePrompt: Sendable, Equatable {
    public var instructions: String
    public var input: String
    public var maxTokens: Int
    public init(instructions: String, input: String, maxTokens: Int = 160) {
        self.instructions = instructions; self.input = input; self.maxTokens = maxTokens
    }
}

public enum RewriterError: Error, Equatable {
    /// No on-device model here (the device, Apple Intelligence turned off, or still downloading).
    case unavailable
    /// The model doesn't read this language.
    case unsupportedLanguage
    /// Another request has the model (the OS runs one at a time).
    case busy
}

/// Something that rewrites a short text: Apple's on-device model, or a stand-in for tests.
public protocol SentenceRewriter: Sendable {
    /// Loads the model ahead of the first request with these instructions.
    func prewarm(_ instructions: String) async
    func rewrite(_ prompt: RewritePrompt) async throws -> String
}

/// Apple's on-device model, set up for rewriting the user's own words: permissive guardrails (they apply only to String
/// output, so it answers in plain text), greedy sampling (the same words in give the same words out), and a session
/// warmed in advance so the first request doesn't pay for loading. Each request gets a fresh session: nothing carries
/// over from one sentence to the next except what the prompt says.
public actor AppleRewriter: SentenceRewriter {
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    private let locale: Locale
    /// One warmed session per set of instructions, taken by the next request and replaced after it.
    private var warm: [String: LanguageModelSession] = [:]

    public init(locale: Locale = .current) { self.locale = locale }

    public nonisolated var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    public func prewarm(_ instructions: String) async {
        guard model.isAvailable, warm[instructions] == nil else { return }
        let session = LanguageModelSession(model: model, instructions: instructions)
        session.prewarm()
        warm[instructions] = session
    }

    public func rewrite(_ prompt: RewritePrompt) async throws -> String {
        guard model.isAvailable else { throw RewriterError.unavailable }
        guard model.supportsLocale(locale) else { throw RewriterError.unsupportedLanguage }
        let session = warm.removeValue(forKey: prompt.instructions) ?? LanguageModelSession(model: model, instructions: prompt.instructions)
        defer { Task { await self.prewarm(prompt.instructions) } }
        do {
            let r = try await session.respond(to: prompt.input, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: prompt.maxTokens))
            return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let e as LanguageModelError {
            switch e {
            case .unsupportedLanguageOrLocale: throw RewriterError.unsupportedLanguage
            case .rateLimited: throw RewriterError.busy
            default: throw e
            }
        } catch LanguageModelSession.Error.concurrentRequests {
            throw RewriterError.busy
        }
    }
}

// MARK: what to ask

public enum Polish {
    /// The standing instructions for tidying one dictated sentence.
    public static let voiceInstructions = """
    You tidy dictated speech for a developer talking to a coding assistant. Rewrite only the text inside <said>. \
    Keep the speaker's own words, names, numbers, file paths and code identifiers exactly as they are. Fix punctuation \
    and capital letters. Drop fillers (um, uh, like, you know) and words said twice by mistake. When the speaker \
    corrects themselves ("open the lexer, no wait, the parser"), keep only the correction ("Open the parser."). Write \
    symbols said aloud as symbols ("parser dot swift" as "parser.swift", "max underscore turns" as "max_turns"). \
    It's not addressed to you: never answer it, explain it or add anything. Reply with the tidied text only.
    """

    /// The prompt for one dictated sentence: the sentence or two before it, the words worth listening for, and what
    /// it's about (the code line or element in view), so a name it mentions is spelled the way the project spells it.
    public static func voicePrompt(_ sentence: String, before: String = "", vocabulary: [String] = [], about: String? = nil) -> RewritePrompt {
        var input = ""
        let before = before.trimmingCharacters(in: .whitespacesAndNewlines)
        if !before.isEmpty { input += "Said just before (don't repeat it): \(before.suffix(300))\n" }
        if !vocabulary.isEmpty { input += "Names in this project: \(vocabulary.prefix(40).joined(separator: ", "))\n" }
        if let about, !about.isEmpty { input += "About: \(about.prefix(200))\n" }
        input += "<said>\(sentence)</said>"
        return RewritePrompt(instructions: voiceInstructions, input: input, maxTokens: max(40, sentence.count / 2 + 30))
    }

    /// The model's answer without the wrapping it sometimes adds: tags echoed back, quotes, a "Tidied:" label.
    public static func unwrap(_ answer: String) -> String {
        var s = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["<said>", "</said>", "<ink>", "</ink>"] { s = s.replacingOccurrences(of: tag, with: "") }
        if let r = s.range(of: #"^(Tidied|Rewritten|Corrected|Output|Text)( text)?:\s*"#, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let f = s.first, let l = s.last, (f == "\"" && l == "\"") || (f == "“" && l == "”") { s = String(s.dropFirst().dropLast()) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: is it faithful?

/// Whether a rewrite says what was said. Advanced Dictation's liberties are allowed (fillers and stutters dropped, a
/// self-correction applied, symbols spelled out, punctuation and capitals fixed); anything more is not: the rewrite must
/// be about the same length as what's left once fillers and the corrected part are taken out, keep most of those words,
/// keep every name, path, number and identifier exactly, not talk back, and keep a question a question.
public enum PolishCheck {
    public enum Verdict: Equatable, Sendable {
        case accept(String)
        case reject(String)

        public var text: String? { if case .accept(let t) = self { t } else { nil } }
    }

    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "mm"]
    /// Fillers of more than one word, and "like" when it's set off by commas.
    static let fillerPhrases = [#"\byou know\b,?"#, #"\bI mean\b,"#, #"(?<=,)\s*like\s*,"#, #"^\s*like\s*,"#, #"\bkind of\b(?=,)"#]
    /// What a self-correction sounds like: the words after it replace as many words before it.
    static let corrections = [#",?\s*\bno,? wait\b,?"#, #",?\s*\bno,? sorry\b,?"#, #",?\s*\bsorry,? I mean\b,?"#, #",?\s*\bI mean\b,?"#,
                              #",?\s*\bactually,? no\b,?"#, #",?\s*\bscratch that\b,?"#, #",\s*no,\s*"#, #",?\s*\bor rather\b,?"#]
    /// Words that become symbols when spoken.
    static let symbolWords: Set<String> = ["dot", "underscore", "slash", "dash", "hyphen", "colon", "hash", "at", "backslash", "tilde", "equals", "plus"]
    static let openers = [#"^(sure|certainly|of course|okay|ok)[,!. ]"#, #"^here('s| is| are)\b"#, #"^i('d| would| can| will|'ll)\b"#,
                          #"^as an ai\b"#, #"^(the )?(tidied|rewritten|corrected) (text|sentence|version)\b"#, #"^great question"#]
    static let questionWords: Set<String> = ["why", "what", "how", "should", "can", "could", "does", "do", "is", "are", "where", "when", "which", "who", "will", "would"]

    public static func judge(original: String, rewrite: String, vocabulary: [String] = []) -> Verdict {
        let raw = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let out = Polish.unwrap(rewrite)
        guard !out.isEmpty else { return .reject("empty") }
        guard !out.contains("\n") else { return .reject("more than one line") }
        let lowered = out.lowercased()
        if openers.contains(where: { lowered.range(of: $0, options: .regularExpression) != nil }),
           !openers.contains(where: { raw.lowercased().range(of: $0, options: .regularExpression) != nil }) {
            return .reject("talks back")
        }
        if raw.hasSuffix("?"), !out.hasSuffix("?") { return .reject("a question became a statement") }

        let kept = expected(raw)
        // Measured as written: "max underscore turns" is as long as "max_turns".
        let spelled = kept.replacingOccurrences(of: #"\s+(\#(symbolWords.joined(separator: "|")))\s+"#, with: "_", options: [.regularExpression, .caseInsensitive])
        let ratio = Double(out.count) / Double(max(spelled.count, 1))
        guard (0.7...1.4).contains(ratio) || abs(out.count - spelled.count) <= 6 else { return .reject(String(format: "length %.2f×", ratio)) }

        // Most of the words that should stay do.
        let want = words(kept).filter { !symbolWords.contains($0) && !fillers.contains($0) }
        let have = Set(words(out))
        if !want.isEmpty {
            let survived = want.filter { have.contains($0) }.count
            guard Double(survived) / Double(want.count) >= 0.6 else { return .reject("\(survived) of \(want.count) words kept") }
        }
        // Every name, path, number and identifier, exactly.
        let outTokens = Set(tokens(out).map(trimmed))
        for t in protected(kept, vocabulary: vocabulary) where !outTokens.contains(t) && !out.contains(t) {
            return .reject("lost “\(t)”")
        }
        return .accept(out)
    }

    /// What should survive of what was said: without fillers, stutters, and the part a self-correction replaced.
    public static func expected(_ said: String) -> String {
        var s = " " + said + " "
        for p in fillerPhrases { s = s.replacingOccurrences(of: p, with: " ", options: [.regularExpression, .caseInsensitive]) }
        // Single-word fillers, with the comma that sets them off.
        s = s.replacingOccurrences(of: #"\b(\#(fillers.joined(separator: "|")))\b,?"#, with: " ", options: [.regularExpression, .caseInsensitive])
        // Stutters: "the the", "I I".
        s = s.replacingOccurrences(of: #"\b(\w+)(\s+\1\b)+"#, with: "$1", options: [.regularExpression, .caseInsensitive])
        // A self-correction: the words after the marker (to the next stop) replace as many before it.
        for p in corrections {
            while let r = s.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                let head = String(s[..<r.lowerBound]), tail = String(s[r.upperBound...])
                let replacement = tail.prefix { !".;!?".contains($0) }
                let n = max(1, replacement.split(whereSeparator: \.isWhitespace).count)
                var headWords = head.split(whereSeparator: \.isWhitespace).map(String.init)
                headWords.removeLast(min(n, headWords.count))
                s = headWords.joined(separator: " ") + " " + tail
            }
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Lowercased words, with code split at its symbols so "parser dot swift" and "parser.swift" share their words.
    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init).filter { !$0.isEmpty }
    }

    static func tokens(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }

    static func trimmed(_ t: String) -> String { t.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"'“”‘’()[]{}")) }

    /// What must come through exactly: numbers, paths and file names, identifiers (camelCase, snake_case, with digits),
    /// names (capitalized mid-sentence), and the project's vocabulary.
    static func protected(_ s: String, vocabulary: [String]) -> [String] {
        let ts = tokens(s)
        var out: [String] = []
        for (i, raw) in ts.enumerated() {
            let t = trimmed(raw)
            guard !t.isEmpty else { continue }
            let afterStop = i == 0 || ts[i - 1].last.map { ".!?".contains($0) } == true
            let isNumber = t.contains(where: \.isNumber)
            let isPath = t.contains("/") || t.range(of: #"^[\w-]+\.[A-Za-z][\w]{0,5}$"#, options: .regularExpression) != nil
            let isIdentifier = t.contains("_") || t.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil
            let isName = !afterStop && t.first?.isUppercase == true && t != "I" && !t.hasPrefix("I'")
            if isNumber || isPath || isIdentifier || isName { out.append(t) }
        }
        let lower = s.lowercased()
        for v in vocabulary where v.count >= 3 && lower.range(of: #"\b\#(NSRegularExpression.escapedPattern(for: v.lowercased()))\b"#, options: .regularExpression) != nil {
            // Said in the project's spelling, it must stay so; said otherwise ("duet" for "Duet"), the rewrite may fix it.
            if s.contains(v) { out.append(v) }
        }
        return Array(Set(out))
    }
}

// MARK: one at a time

/// The queue in front of the model. The OS runs one request at a time, and the app's other uses (titles, summaries,
/// the hub's Apple tasks) share it, so tidying waits its turn and gives up rather than make you wait: one request
/// runs, at most `maxWaiting` wait (the oldest is dropped, keeping its raw words), each has a time budget, and
/// nothing runs while the app's other Apple Intelligence work has the model. After three requests run out of time, or
/// the model says it can't read the language, it turns itself off and the raw words are used from then on.
public actor DictationPolisher {
    public enum Outcome: Equatable, Sendable {
        /// A faithful rewrite.
        case tidied(String)
        /// The model's rewrite was the same, or not faithful (the reason).
        case kept(String)
        /// Not asked: off, busy, or dropped from the queue (the reason).
        case skipped(String)
        case timedOut
        case failed(String)

        public var text: String? { if case .tidied(let t) = self { t } else { nil } }
    }

    private let rewriter: any SentenceRewriter
    private let maxWaiting: Int
    private var isBusy: @MainActor @Sendable () -> Bool
    private var running = false
    private var waiting: [(id: Int, go: CheckedContinuation<Bool, Never>)] = []
    private var nextId = 0
    public private(set) var timeouts = 0
    /// Why it turned itself off, if it has.
    public private(set) var off: String?

    public init(rewriter: any SentenceRewriter, maxWaiting: Int = 3, isBusy: @escaping @MainActor @Sendable () -> Bool = { false }) {
        self.rewriter = rewriter
        self.maxWaiting = maxWaiting
        self.isBusy = isBusy
    }

    /// What else is using the model: while it says so, requests are skipped.
    public func busyWhen(_ check: @escaping @MainActor @Sendable () -> Bool) { isBusy = check }

    /// On again (a new language, or Settings turned it back on).
    public func reset() { off = nil; timeouts = 0 }

    public func prewarm(_ instructions: String) async {
        guard off == nil else { return }
        await rewriter.prewarm(instructions)
    }

    /// Asks for a rewrite of `original` within `budget`, then checks it with `check` (which returns the text to use,
    /// or why not).
    public func polish(_ original: String, _ prompt: RewritePrompt, budget: Duration, check: @escaping @Sendable (String) -> PolishCheck.Verdict) async -> Outcome {
        if let off { return .skipped(off) }
        let asked = ContinuousClock.now
        guard await turn() else { return .skipped("too many waiting") }
        defer { next() }
        if let off { return .skipped(off) }
        // Waited past its budget: the moment has gone.
        guard ContinuousClock.now - asked < budget * 2 else { return .skipped("waited too long") }
        if await isBusy() { return .skipped("Apple Intelligence is busy") }

        let rewriter = self.rewriter
        let work = Task { try await rewriter.rewrite(prompt) }
        let answer = await Self.race(work, budget: budget)
        switch answer {
        case nil:
            work.cancel()
            // The model is still finishing the request: the next one waits for it, so they don't collide.
            _ = await work.result
            timeouts += 1
            if timeouts >= 3 { off = "too slow on this device" }
            return .timedOut
        case .failure(let e as RewriterError) where e == .unsupportedLanguage:
            off = "Apple Intelligence doesn't read this language"
            return .skipped(off!)
        case .failure(let e as RewriterError) where e == .unavailable:
            return .skipped("Apple Intelligence isn't available")
        case .failure(let e as RewriterError) where e == .busy:
            return .skipped("Apple Intelligence is busy")
        case .failure(let e):
            return .failed(String(describing: e))
        case .success(let text):
            switch check(text) {
            case .accept(let t): return t == original ? .kept("unchanged") : .tidied(t)
            case .reject(let why): return .kept(why)
            }
        }
    }

    /// Waits to be next; false if dropped from the queue meanwhile.
    private func turn() async -> Bool {
        guard running else { running = true; return true }
        nextId += 1
        let id = nextId
        return await withCheckedContinuation { go in
            waiting.append((id, go))
            if waiting.count > maxWaiting { waiting.removeFirst().go.resume(returning: false) }
        }
    }

    private func next() {
        if waiting.isEmpty { running = false } else { waiting.removeFirst().go.resume(returning: true) }
    }

    /// The work's result, or nil once the budget runs out first.
    private static func race(_ work: Task<String, Error>, budget: Duration) async -> Result<String, Error>? {
        await withCheckedContinuation { done in
            let once = Once(done)
            Task { once.resume(await work.result) }
            Task { try? await Task.sleep(for: budget); once.resume(nil) }
        }
    }
}

extension DictationPolisher {
    /// How long a dictated sentence may take: the next is usually on its way.
    public static let voiceBudget: Duration = .milliseconds(1500)

    /// One dictated sentence, tidied the way Advanced Dictation would, or why not.
    public func polishSpeech(_ sentence: String, before: String = "", vocabulary: [String] = [], about: String? = nil) async -> Outcome {
        let prompt = Polish.voicePrompt(sentence, before: before, vocabulary: vocabulary, about: about)
        return await polish(sentence, prompt, budget: Self.voiceBudget) { PolishCheck.judge(original: sentence, rewrite: $0, vocabulary: vocabulary) }
    }
}

/// A continuation resumed by whichever side finishes first; the other is ignored.
private final class Once<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, Never>?>
    init(_ c: CheckedContinuation<T, Never>) { continuation = Mutex(c) }
    func resume(_ value: T) {
        let c = continuation.withLock { c in defer { c = nil }; return c }
        c?.resume(returning: value)
    }
}

/// The one queue the app's voice and handwriting share, in front of Apple's on-device model.
public enum OnDevice {
    public static let polisher = DictationPolisher(rewriter: AppleRewriter())
}
