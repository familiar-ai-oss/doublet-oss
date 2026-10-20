import Foundation
import NaturalLanguage

// Talk mode and dictation: the parts that are plain logic. Recognition and speech themselves (Apple's on-device
// SpeechAnalyzer and AVSpeechSynthesizer) live in the app.

// MARK: what to say

/// What to say aloud for a reply written for the screen. Prose reads as written; code blocks and tables stay on screen
/// (said once, briefly); links read as their words; paths shrink to the file's name and line; Markdown's marks go.
public enum Speakable {
    public static func text(_ markdown: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var fence: String?
        var saidCode = false, saidTable = false
        func flush() {
            let p = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            paragraph = []
            if !p.isEmpty { out.append(sentence(p)) }
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // A code block: skipped, and mentioned once.
            if let f = fence {
                if line.hasPrefix(f) { fence = nil }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                fence = String(line.prefix(3))
                if !saidCode { out.append("The code is on screen."); saidCode = true }
                continue
            }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("|") {
                flush()
                if !saidTable { out.append("The table is on screen."); saidTable = true }
                continue
            }
            // A rule (---, ***, ___).
            if line.count >= 3, line.allSatisfy({ "-*_ ".contains($0) }) { flush(); continue }
            // Headings and list items are sentences of their own; a quote reads as its words.
            if let r = line.range(of: #"^(#{1,6}\s+|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)"#, options: .regularExpression) {
                flush()
                paragraph.append(inline(String(line[r.upperBound...])))
                flush()
                continue
            }
            if let r = line.range(of: #"^>\s?"#, options: .regularExpression) {
                paragraph.append(inline(String(line[r.upperBound...])))
                continue
            }
            paragraph.append(inline(line))
        }
        flush()
        return out.joined(separator: " ")
    }

    /// The start of a long reply, for Talk mode: whole sentences up to about `words` words, then a note that the rest
    /// is on screen. A short reply is said in full.
    public static func brief(_ sentences: [String], words: Int = 70) -> [String] {
        let count = { (s: String) in s.split(whereSeparator: \.isWhitespace).count }
        guard sentences.map(count).reduce(0, +) > words * 3 / 2 else { return sentences }
        var out: [String] = []
        var said = 0
        for s in sentences {
            if !out.isEmpty, said + count(s) > words { break }
            out.append(s)
            said += count(s)
        }
        return out.count < sentences.count ? out + ["There's more on screen."] : out
    }

    /// Splits speech into sentences, so the first is heard sooner and a long one doesn't run on without a breath.
    public static func sentences(_ text: String, longest: Int = 220) -> [String] {
        let marked = text.replacingOccurrences(of: #"(?<=[.!?…])["”')\]]?\s+(?=["“'(\[]?[A-Z0-9])"#, with: "$0\u{1E}", options: .regularExpression)
        return marked.split(separator: "\u{1E}").flatMap { split(String($0).trimmingCharacters(in: .whitespaces), longest) }.filter { !$0.isEmpty }
    }

    /// A long sentence breaks at the comma, semicolon or dash nearest its middle.
    private static func split(_ s: String, _ longest: Int) -> [String] {
        guard s.count > longest else { return [s] }
        let breaks = s.indices.filter { i in
            let c = s[i]
            return (c == "," || c == ";" || c == "—") && s.index(after: i) < s.endIndex && s[s.index(after: i)] == " "
        }
        let middle = s.count / 2
        guard let at = breaks.min(by: { abs(s.distance(from: s.startIndex, to: $0) - middle) < abs(s.distance(from: s.startIndex, to: $1) - middle) }) else { return [s] }
        let head = String(s[...at]), tail = String(s[s.index(after: at)...]).trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty, head.count < s.count else { return [s] }
        return split(head, longest) + split(tail, longest)
    }

    /// One line's words: Markdown's marks gone, links as their text, code read only when it's short.
    static func inline(_ line: String) -> String {
        var s = line
        func sub(_ pattern: String, _ template: String) { s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression) }
        sub(#"!\[[^\]]*\]\([^)]*\)"#, "")
        sub(#"\[([^\]]+)\]\([^)]*\)"#, "$1")
        // Inline code: a path reads as its file, a short name as itself, anything long as "the code on screen".
        while let r = s.range(of: #"`([^`]+)`"#, options: .regularExpression) {
            let code = String(s[r].dropFirst().dropLast())
            s.replaceSubrange(r, with: spokenCode(code))
        }
        // Bare links read as their site.
        sub(#"<?https?://(www\.)?([^/\s>]+)[^\s>]*>?"#, "$2")
        s = spokenPaths(s)
        sub(#"\*\*(.+?)\*\*"#, "$1")
        sub(#"__(.+?)__"#, "$1")
        sub(#"~~(.+?)~~"#, "$1")
        sub(#"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])"#, "$1")
        sub(#"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])"#, "$1")
        sub(#"</?[A-Za-z][^>]*>"#, "")
        sub(#"\s*(→|->|=>)\s*"#, " to ")
        sub(#"\s+"#, " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func spokenCode(_ code: String) -> String {
        let c = code.trimmingCharacters(in: .whitespaces)
        if !c.contains(" "), c.contains("/") { return spokenPath(c) }
        return c.count > 40 ? "the code on screen" : c
    }

    /// "/home/b/proj/src/fleet.ts:42" as "fleet.ts line 42".
    static func spokenPaths(_ text: String) -> String {
        let pattern = #"(?<![\w@])(~|\.{1,2})?/?([\w.-]+/)+[\w-]+(\.[\w-]+)+(:\d+(-\d+)?)?"#
        var s = text
        var searchFrom = s.startIndex
        while let r = s.range(of: pattern, options: .regularExpression, range: searchFrom..<s.endIndex) {
            let spoken = spokenPath(String(s[r]))
            s.replaceSubrange(r, with: spoken)
            searchFrom = s.index(r.lowerBound, offsetBy: spoken.count, limitedBy: s.endIndex) ?? s.endIndex
        }
        return s
    }

    static func spokenPath(_ path: String) -> String {
        var p = path
        var line = ""
        if let r = p.range(of: #":\d+(-\d+)?$"#, options: .regularExpression) {
            let nums = p[r].dropFirst().split(separator: "-")
            line = nums.count == 2 ? " lines \(nums[0]) to \(nums[1])" : " line \(nums[0])"
            p.removeSubrange(r)
        }
        let name = p.split(separator: "/").last.map(String.init) ?? p
        return name + line
    }

    /// A line that becomes its own sentence ends like one, so the voice pauses there.
    private static func sentence(_ s: String) -> String {
        guard let last = s.last else { return s }
        return ".!?:;…".contains(last) ? s : s + "."
    }
}

// MARK: what's been said

/// One result from the recognizer: its words, the audio they cover (seconds from when listening started), and how far
/// the recognizer has settled. A guess (`isFinal` false) can still change; a final result won't.
public struct Heard: Sendable, Equatable {
    /// A word or two and the audio it was heard in.
    public struct Run: Sendable, Equatable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(_ text: String, _ start: Double, _ end: Double) { self.text = text; self.start = start; self.end = end }
    }

    public let text: String
    public let isFinal: Bool
    /// The words with their times, when the recognizer gives them (empty: untimed).
    public var runs: [Run]
    /// Everything up to here is final, even if no final result came for it (the recognizer skips a final when the
    /// guess didn't change).
    public var finalThrough: Double?

    public init(text: String, isFinal: Bool, runs: [Run] = [], finalThrough: Double? = nil) {
        self.text = text; self.isFinal = isFinal; self.runs = runs; self.finalThrough = finalThrough
    }
}

/// What's been said so far, in three parts: sentences Apple Intelligence has tidied, the words the recognizer has
/// settled on, and its guess at the rest, which can still change. Results are merged by time: a guess replaces only
/// the guess from where it starts, and a final result only the words it covers, so the words on screen don't blink.
public struct LiveTranscript: Equatable, Sendable {
    public enum Style: Sendable, Equatable { case tidied, settled, guess }

    private var done: [Heard.Run] = []
    private var pending: [Heard.Run] = []
    /// Raw sentence → its tidied form. Keyed by the words, so a sentence that grows is tidied again.
    private var tidies: [String: String] = [:]
    /// Sentences already sent to be tidied (whatever came back).
    private var asked: Set<String> = []
    /// Show and use the tidied sentences (off: Undo).
    public var showsTidy = true
    /// Untimed results get times of their own, one after another.
    private var untimed = 0.0
    /// Words from before here were sent or typed over: results for them that arrive late are ignored.
    private var floor = -Double.infinity
    /// How far the recognizer has said everything is final.
    private var finalThrough = -Double.infinity

    public init() {}

    // MARK: in

    /// An untimed result: a final adds to what's settled and clears the guess; a guess replaces the guess.
    public mutating func apply(_ text: String, isFinal: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let at = max(untimed, done.last?.end ?? 0, pending.last?.end ?? 0)
        untimed = at + 1
        if isFinal {
            if !t.isEmpty { done.append(Heard.Run(t, at, at + 1)) }
            pending = []
        } else {
            pending = t.isEmpty ? [] : [Heard.Run(t, at, at + 1)]
        }
    }

    public mutating func apply(_ h: Heard) {
        guard !h.runs.isEmpty else {
            apply(h.text, isFinal: h.isFinal)
            if let f = h.finalThrough { promote(through: f) }
            return
        }
        let runs = h.runs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.end > floor + 0.01 }
        let start = h.runs.map(\.start).min() ?? 0, end = h.runs.map(\.end).max() ?? start
        let ε = 0.01
        if h.isFinal {
            // These words are settled: the guess and anything settled over the same audio give way to them. A guess comes
            // as one run over all its words, so where it runs on past the final, the words the final didn't cover stay.
            var rest: [Heard.Run] = []
            for p in pending where p.end > start + ε && p.start < end - ε && p.end > end + ε {
                let covered = runs.filter { $0.start >= p.start - ε }.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }.count
                let words = p.text.split(whereSeparator: \.isWhitespace)
                if words.count > covered { rest.append(Heard.Run(words.dropFirst(covered).joined(separator: " "), end, p.end)) }
            }
            pending.removeAll { $0.end > start + ε && $0.start < end - ε }
            pending += rest
            done.removeAll { $0.end > start + ε && $0.start < end - ε }
            done = (done + runs).sorted { $0.start < $1.start }
            finalThrough = max(finalThrough, end)
        } else {
            // A guess covers from its start to now: the old guess from there on goes.
            pending.removeAll { $0.end > start + ε }
            pending = (pending + runs).sorted { $0.start < $1.start }
        }
        if let f = h.finalThrough { promote(through: f) }
    }

    /// The recognizer has finished: everything heard is settled, including a guess it never sent a final for (it
    /// skips the final when the guess didn't change).
    public mutating func end() {
        done = (done + pending).sorted { $0.start < $1.start }
        pending = []
    }

    /// The guess up to `time` becomes settled.
    public mutating func promote(through time: Double) {
        finalThrough = max(finalThrough, time)
        let ready = pending.filter { $0.end <= time + 0.01 }
        guard !ready.isEmpty else { return }
        pending.removeAll { $0.end <= time + 0.01 }
        done = (done + ready).sorted { $0.start < $1.start }
    }

    /// The end of the last word heard, settled or not.
    public var lastHeard: Double { max(done.last?.end ?? 0, pending.last?.end ?? 0) }

    // MARK: tidying

    /// The settled words as sentences.
    public var sentences: [String] { Self.sentences(settled) }

    /// Settled sentences ready to tidy and not yet asked: complete ones, or (`all`) the last one too, once you've
    /// finished.
    public func untidied(all: Bool = false) -> [String] {
        let s = sentences
        return s.enumerated().compactMap { i, sentence in
            let complete = i < s.count - 1 || all || sentence.last.map { ".?!".contains($0) } == true
            return complete && !asked.contains(sentence) && sentence.split(separator: " ").count >= 2 ? sentence : nil
        }
    }

    /// The sentences just before this one, as context for tidying it.
    public func before(_ sentence: String) -> String {
        let s = sentences
        guard let i = s.firstIndex(of: sentence) else { return "" }
        return s[max(0, i - 2)..<i].joined(separator: " ")
    }

    public mutating func asking(_ sentence: String) { asked.insert(sentence) }

    public mutating func tidy(_ sentence: String, as tidied: String) { tidies[sentence] = tidied }

    /// Whether any sentence on show is tidied.
    public var isTidied: Bool { showsTidy && sentences.contains { tidies[$0] != nil } }

    // MARK: out

    public var settled: String { Self.joined(done) }
    public var guess: String { Self.joined(pending) }
    /// What was heard, untouched.
    public var raw: String { Self.join(settled, guess) }

    /// What goes in the field: the settled sentences (tidied, unless undone), then the guess.
    public var text: String { parts.map(\.text).reduce("") { Self.join($0, $1) } }

    /// The text in its three styles, in order, for showing.
    public var parts: [(text: String, style: Style)] {
        var out: [(String, Style)] = []
        func add(_ t: String, _ style: Style) {
            if let last = out.last, last.1 == style { out[out.count - 1].0 = Self.join(last.0, t) } else { out.append((t, style)) }
        }
        for s in sentences {
            if showsTidy, let t = tidies[s] { add(t, .tidied) } else { add(s, .settled) }
        }
        if !guess.isEmpty { add(guess, .guess) }
        return out.map { (text: $0.0, style: $0.1) }
    }

    public var isEmpty: Bool { done.isEmpty && pending.isEmpty }
    public var words: Int { raw.split(whereSeparator: \.isWhitespace).count }

    public mutating func reset() {
        done = []; pending = []; tidies = [:]; asked = []; showsTidy = true; floor = -.infinity; finalThrough = -.infinity
    }

    /// Starts afresh from `time`: what was heard before it is dropped (sent, or typed over), what came after stays.
    public mutating func reset(after time: Double) {
        done.removeAll { $0.end <= time + 0.01 }
        pending.removeAll { $0.end <= time + 0.01 }
        untimed = max(untimed, time)
        floor = max(floor, time)
        let left = Set(sentences)
        tidies = tidies.filter { left.contains($0.key) }
        asked = asked.intersection(left)
    }

    // MARK: helpers

    static func joined(_ runs: [Heard.Run]) -> String { runs.map(\.text).reduce("") { join($0, $1) } }

    /// Sentences, by Apple's tokenizer (so "e.g." and "fleet.ts" don't end one).
    public static func sentences(_ text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = t
        let out = tokenizer.tokens(for: t.startIndex..<t.endIndex).map { t[$0].trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return out.isEmpty ? [t] : out
    }

    /// Two pieces of speech as one: "What does" and "auto do?" read "What does auto do?".
    public static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines), b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        // Punctuation the recognizer puts at a segment's start belongs to the words before it.
        if let first = b.first, ",.!?;:".contains(first) { return a + b }
        return a + " " + b
    }

    public static func == (a: LiveTranscript, b: LiveTranscript) -> Bool {
        a.done == b.done && a.pending == b.pending && a.tidies == b.tidies && a.showsTidy == b.showsTidy
    }
}

// MARK: when you've finished

/// When you've finished speaking: a pause after you've said something. After "and", "so", "um" or a comma it waits
/// longer, because you're usually still thinking.
public struct TurnTimer: Equatable, Sendable {
    /// Seconds of quiet that end a turn.
    public var pause: Double

    public init(pause: Double = 1.4) { self.pause = pause }

    static let unfinished: Set<String> = ["and", "but", "so", "or", "because", "um", "uh", "er", "erm", "like", "then", "if", "the", "a", "an",
                                          "to", "with", "of", "for", "that", "which", "is", "my", "your", "our", "i", "we"]

    public func pause(after text: String) -> Double {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix(",") || t.hasSuffix("…") || t.hasSuffix("-") { return pause * 1.8 }
        let last = t.split(whereSeparator: { $0.isWhitespace }).last.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
        return Self.unfinished.contains(last) && !t.hasSuffix(".") && !t.hasSuffix("?") ? pause * 1.8 : pause
    }

    /// Whether a turn with these words is over after this many seconds of quiet.
    public func isOver(_ text: String, quietFor seconds: Double) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seconds >= pause(after: text)
    }
}


// MARK: talking over

/// Whether what the microphone heard while Duet was speaking is you talking over it, rather than Duet's own voice
/// coming back (the echo canceller misses some of it, and the recognizer may garble what it hears): two or more words
/// that aren't in what Duet has been saying. Duet's echo in the transcript doesn't count against you, so you can
/// interrupt mid-echo.
public enum BargeIn {
    public static func isYou(_ heard: String, saying: String) -> Bool {
        let said = words(saying)
        let known = Set(said)
        let stems = Set(said.filter { $0.count >= 4 }.map { String($0.prefix(4)) })
        let yours = words(heard).filter { w in
            guard w.count >= 2, !known.contains(w) else { return false }
            // "schedule" for "scheduler": a garbled echo shares its first letters.
            return w.count < 4 || !stems.contains(String(w.prefix(4)))
        }
        return yours.count >= 2
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }
}
