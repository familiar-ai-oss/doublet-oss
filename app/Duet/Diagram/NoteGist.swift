import DuetKit
import Foundation

/// A note's pill on a code page says what the note is about in at most three words, so it can be tapped with
/// confidence: as written when it's that short, else a gist made on this device, and until then (or without Apple
/// Intelligence) its first three words.
enum NoteGist {
    static let maxWords = 3

    private static func words(_ s: String) -> [Substring] { s.split(whereSeparator: \.isWhitespace) }

    /// Short enough to show as written.
    static func isShort(_ text: String) -> Bool { words(text).count <= maxWords }

    /// The note's first three words, and "…" when there were more.
    static func fallback(_ text: String) -> String {
        let w = words(text)
        return w.count <= maxWords ? w.joined(separator: " ") : w.prefix(maxWords).joined(separator: " ") + "…"
    }

    /// The model's answer as a gist: at most three words, without quotes or a full stop. Nil when it's empty.
    static func clean(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’.")))
        let w = words(trimmed)
        guard !w.isEmpty else { return nil }
        return w.prefix(maxWords).joined(separator: " ")
    }

    /// What a gist is made from, as a key: the same note, code and answer make the same gist, so it's made once, and
    /// again only when something changes (the answer arriving).
    static func key(question: String, code: String, answer: String?) -> String {
        OnDeviceText.digest("gist\u{1}\(question)\u{1}\(code)\u{1}\(answer ?? "")")
    }

    /// An answer's first sentence (its first paragraph of prose, up to the first full stop).
    static func firstSentence(_ answer: String) -> String {
        let prose = FileViewer.gist(answer)
        if let end = prose.range(of: #"[.!?](\s|$)"#, options: .regularExpression) { return String(prose[..<end.upperBound]).trimmingCharacters(in: .whitespaces) }
        return String(prose.prefix(200))
    }

    /// The tagged line with one line either side, for the gist.
    static func code(around line: Int, in lines: [Substring]) -> String {
        guard line >= 1, line <= lines.count else { return "" }
        return lines[max(0, line - 2)...min(lines.count - 1, line)].joined(separator: "\n")
    }
}

/// Gists made on this device, kept across launches by their key, and made one at a time in the background.
@MainActor @Observable
final class NoteGists {
    static let shared = NoteGists()

    private static let savedKey = "noteGists"
    private(set) var made: [String: String] = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String] ?? [:]
    @ObservationIgnored private var queue: [(key: String, question: String, code: String, answer: String?)] = []
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var working = false
    /// The device's model (set by the page that shows pills).
    @ObservationIgnored weak var apple: AppleIntelligence?

    /// A note's pill text, now: as written, its gist, or its first words while the gist is made.
    func gist(question: String, code: String, answer: String?) -> String {
        if NoteGist.isShort(question) { return NoteGist.fallback(question) }
        let key = NoteGist.key(question: question, code: code, answer: answer)
        if let g = made[key] { return g }
        if !asked.contains(key) {
            asked.insert(key)
            queue.append((key, question, code, answer))
            // Made after this view update, not during it.
            Task { await self.work() }
        }
        return NoteGist.fallback(question)
    }

    private func work() async {
        guard !working else { return }
        working = true
        defer { working = false }
        while !queue.isEmpty {
            let job = queue.removeFirst()
            guard let apple, let g = await apple.noteGist(note: job.question, code: job.code, answer: job.answer) else { continue }
            made[job.key] = g
            if made.count > 500 { for k in made.keys.shuffled().prefix(200) { made[k] = nil } }
            UserDefaults.standard.set(made, forKey: Self.savedKey)
        }
    }
}

extension NoteCard {
    /// A kept note as a card: what was asked, the start of the answer (or who's answering), and its pill's gist.
    static func of(_ a: Annotation, gist: String? = nil) -> NoteCard {
        let asked = a.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return NoteCard(id: a.id, question: asked.isEmpty ? "Your handwritten note" : asked,
                        answer: a.status != "open" && a.answer != nil ? FileViewer.gist(a.answer ?? "") : nil,
                        chip: a.answered ? AnswerChip.text(for: a) : nil,
                        waiting: a.answering == "Claude" ? "Claude is answering…" : a.answering != nil ? "A local model is reading the code…" : "Claude is answering…",
                        resolved: a.resolved, gist: gist)
    }
}
