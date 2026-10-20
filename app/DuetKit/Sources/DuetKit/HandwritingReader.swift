import Foundation

// Reading Apple Pencil handwriting the way you meant it. PencilKit's recognizer reads letters, not code, and a note
// written in pieces comes out in pieces ("wow do I get this" + "working"). So a note's words are first snapped to the
// identifiers it's written beside (plain code: this alone fixes most misread code words), then one on-device request
// tidies the note and says what kind it is. The raw words are kept, and the ink's colour or a choice from the menu
// always wins over the model's kind.

/// What a handwritten note says, as read.
public struct HandwritingReading: Codable, Sendable, Equatable {
    /// What PencilKit read, untouched.
    public var raw: String
    /// The words as meant: snapped to the code, then tidied if Apple Intelligence could.
    public var text: String
    /// What kind of note it is, if Apple Intelligence said.
    public var kind: InkIntent?
    /// Whether Apple Intelligence read it (else: only snapped).
    public var byModel: Bool

    public init(raw: String, text: String, kind: InkIntent? = nil, byModel: Bool = false) {
        self.raw = raw; self.text = text; self.kind = kind; self.byModel = byModel
    }

    /// For the hover readout: "Reads: How do I get this working? · Question".
    public var summary: String {
        let k = kind.map { " · " + HandwritingReader.name($0) } ?? ""
        return "Reads: \(text)\(k)"
    }
}

public enum InkSnap {
    /// The names in a line of code or an element's label: identifiers, and file names with their extension.
    public static func identifiers(in code: String) -> [String] {
        let pattern = #"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for m in re.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let r = Range(m.range, in: code) else { continue }
            let name = String(code[r])
            // Each dotted part on its own too: "items.count" offers "items" and "count".
            for n in [name] + (name.contains(".") ? name.split(separator: ".").map(String.init) : [])
            where n.count >= 3 && !keywords.contains(n) && seen.insert(n).inserted {
                out.append(n)
            }
        }
        return out
    }

    /// Words of the language, not names of the code: handwriting near them is left as written.
    static let keywords: Set<String> = ["let", "var", "func", "return", "if", "else", "for", "while", "the", "this", "self", "true", "false", "nil",
                                        "null", "import", "const", "function", "class", "struct", "enum", "case", "switch", "guard", "await",
                                        "async", "public", "private", "static", "new", "and", "not", "with", "from", "def", "in", "of", "to"]

    /// Each word within a small edit distance of exactly one of `names` becomes that name (case-insensitively; the
    /// name's own spelling). Short words need to be closer: two edits from six letters, one from four, none below.
    public static func snap(_ text: String, to names: [String]) -> String {
        guard !names.isEmpty else { return text }
        let lowered = names.map { ($0, $0.lowercased()) }
        var out: [String] = []
        for token in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            // The word without the punctuation around it.
            let lead = token.prefix { !$0.isLetter && !$0.isNumber && $0 != "_" }
            let rest = token.dropFirst(lead.count)
            let core = String(rest.reversed().drop { !$0.isLetter && !$0.isNumber && $0 != "_" }.reversed())
            let trail = rest.dropFirst(core.count)
            let w = core.lowercased()
            let allowed = w.count >= 6 ? 2 : w.count >= 4 ? 1 : 0
            guard allowed > 0 || lowered.contains(where: { $0.1 == w }) else { out.append(token); continue }
            let scored = lowered.map { ($0.0, distance(w, $0.1)) }.filter { $0.1 <= allowed }
            let best = scored.map(\.1).min()
            let winners = scored.filter { $0.1 == best }
            // An exact match keeps the name's spelling; a tie between names is left alone.
            if let best, Set(winners.map(\.0)).count == 1, best > 0 || winners[0].0 != core {
                out.append(lead + winners[0].0 + trail)
            } else {
                out.append(token)
            }
        }
        return out.joined(separator: " ")
    }

    /// Levenshtein distance.
    public static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

public enum HandwritingReader {
    /// How long a note's reading may take.
    public static let budget: Duration = .seconds(2)

    public static let instructions = """
    You read a handwritten note a developer wrote on their code or a diagram, for a coding assistant. The handwriting \
    recognizer's guess is in <ink>. It can misread letters ("wow" for "how") and break one note into pieces. Write the \
    note as its writer meant it, with punctuation and capitals, keeping their words, names and code identifiers. Then \
    say what kind of note it is: question (they're asking something), change (they want something changed), approve \
    (it looks right to them), or comment (anything else). Never answer the note. Reply on one line: the kind, a bar, \
    then the note. For example: question | How do I get this working?
    """

    public static func prompt(_ text: String, about: String?) -> RewritePrompt {
        var input = ""
        if let about, !about.isEmpty { input += "Written beside: \(about.prefix(240))\n" }
        input += "<ink>\(text)</ink>"
        return RewritePrompt(instructions: instructions, input: input, maxTokens: max(40, text.count / 2 + 30))
    }

    /// "question | How do I get this working?" as its kind and its text.
    public static func parse(_ answer: String) -> (kind: InkIntent?, text: String) {
        let line = Polish.unwrap(answer)
        let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return (nil, line) }
        let kind: InkIntent? = switch parts[0].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "*:")) {
        case "question": .question
        case "change": .change
        case "approve", "approval": .approve
        case "comment": .comment
        default: nil
        }
        return (kind, Polish.unwrap(parts[1]))
    }

    /// Reads a note: snapped to `names` (the identifiers on its line or element), then, within the budget, tidied
    /// and given its kind by the on-device model. Falls back to the snapped words.
    public static func read(_ raw: String, about: String?, names: [String], vocabulary: [String] = [],
                            polisher: DictationPolisher = OnDevice.polisher) async -> HandwritingReading {
        let snapped = InkSnap.snap(raw, to: names + vocabulary)
        var reading = HandwritingReading(raw: raw, text: snapped)
        guard snapped.split(separator: " ").count >= 1, snapped.count >= 2 else { return reading }
        let keep = names + vocabulary
        let outcome = await polisher.polish(snapped, prompt(snapped, about: about), budget: budget) { answer in
            let (kind, text) = parse(answer)
            switch PolishCheck.judge(original: snapped, rewrite: text, vocabulary: keep) {
            case .accept(let t): return .accept((kind.map { $0.rawValue + "|" } ?? "") + t)
            case .reject(let why): return .reject(why)
            }
        }
        // The check passes the kind through ahead of a bar.
        let answer: String? = switch outcome {
        case .tidied(let t): t
        case .kept("unchanged"): snapped
        default: nil
        }
        guard let answer else { return reading }
        let parts = answer.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2, let k = InkIntent(rawValue: parts[0]) {
            reading.kind = k
            reading.text = parts[1]
        } else {
            reading.text = answer
        }
        reading.byModel = true
        return reading
    }

    /// A note with its reading: the reading's words, and its kind where nothing else has decided it. A gesture (a
    /// cross, an arrow, a loop) keeps its meaning, and so does ink in red, blue or green, and a kind picked from the
    /// note's menu.
    public static func apply(_ reading: HandwritingReading, to note: InkNote, color: InkColorName, chosen: Bool) -> InkNote {
        var n = note
        if !reading.text.isEmpty { n.text = reading.text }
        if let k = reading.kind, !chosen, color == .other, [.comment, .question].contains(note.intent) { n.intent = k }
        return n
    }

    static func name(_ intent: InkIntent) -> String {
        switch intent {
        case .question: "Question"
        case .change: "Change"
        case .approve: "Looks right"
        case .comment: "Comment"
        case .remove: "Remove"
        case .connect: "Connect"
        case .group: "Group"
        case .emphasize: "Look at"
        }
    }
}
