import CoreGraphics
import DuetKit
import Foundation

// Pen notes on a native code page: which strokes make one note, what the note is about (the mark first; the nearest
// line only as a fallback), and whether it's a question to ask at once. Pure, so it's tested without a canvas.
//
// From studies of pen notes on code and documents: most marks without words are reading aids, not requests; a
// question nearly always comes with a mark on what it's about (underline, circle, box); "?" is how people end one;
// and showing what a mark was snapped to confirms it better than asking (Penquiry, UIST 2026; Sutherland et al.,
// INTERACT 2015). Mis-anchored notes mostly come from strokes grouped wrongly (vsInk, 2012), so grouping is tight.

/// What a note on code is about: lines, and the characters it picked out within them, and how it was found.
struct CodeSpan: Codable, Equatable {
    var start: Int
    var end: Int
    /// The first character on `start` and the last on `end`, when the mark picked out words.
    var from: Int? = nil
    var to: Int? = nil
    /// How it was found: 1 an arrow's end, 2 what a loop goes around, 3 the words a line crosses, 4 the lines a bar
    /// runs beside, 5 the line nearest the writing (a fallback, always shown).
    var step: Int

    var isFallback: Bool { step >= 5 }

    func shifted(by d: Int) -> CodeSpan {
        var s = self
        s.start += d
        s.end += d
        return s
    }

    /// Where it is on the page, row by row.
    func rects(in g: CodePageGeometry) -> [CGRect] {
        guard start <= end else { return [] }
        return (start...end).flatMap { n -> [CGRect] in
            let a = n == start ? from : nil, b = n == end ? to : nil
            if a == nil, b == nil { return g.codeRects(line: n) }
            return g.charRects(line: n, cols: (a ?? 0)...(b ?? max(g.length(line: n) - 1, 0)))
        }
    }
}

enum CodeGrouping {
    /// A stroke started this soon after the last one belongs to the same note (a circle and the "?" beside it).
    static let window: TimeInterval = 0.5

    /// Whether a stroke joins the note being written: it started within half a second of the last stroke ending (and
    /// not across the page), or it's inside a tight margin around the note.
    static func joins(note: CGRect, letterHeight h: CGFloat, lastEnd: Date, stroke: CGRect, start: Date) -> Bool {
        guard !note.isNull, !stroke.isNull else { return false }
        if start.timeIntervalSince(lastEnd) <= window, note.insetBy(dx: -12 * h, dy: -6 * h).intersects(stroke) { return true }
        return note.insetBy(dx: -1.2 * h, dy: -0.6 * h).intersects(stroke)
    }
}

enum CodeQuestion {
    static let interrogatives: Set<String> = ["why", "what", "how", "should", "can", "does", "do", "is", "are", "could", "where",
                                              "when", "which", "who", "will", "would", "isn't", "doesn't", "shouldn't", "wouldn't"]

    /// Whether words ask something: they end in "?" (or are one), or start with a question word.
    static func asks(_ text: String?) -> Bool {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.hasSuffix("?") { return true }
        let first = t.split(whereSeparator: { $0.isWhitespace || $0 == "," }).first.map { $0.lowercased() } ?? ""
        return interrogatives.contains(first)
    }

    /// Just a question mark (or a few).
    static func isLone(_ text: String?) -> Bool {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.allSatisfy { $0 == "?" }
    }
}

/// What to do with a note once it's read.
enum CodeDecision: Equatable {
    /// Ask this at once, no confirming. `shown`: its target is highlighted for all to see (a fallback anchor, or a
    /// question only the model heard), rather than outlined quietly.
    case ask(String, shown: Bool)
    /// Keep it as a note (sent with Send).
    case note
    /// A mark with no words: a reading aid. Nothing to send or ask.
    case none

    static let whatDoesThisMean = "What does this mean?"

    /// From the mark, what PencilKit read (`raw`), the tidied reading and the model's kind, and what it's about.
    static func of(shape: InkShape, strike: Bool, raw: String?, tidied: String?, kind: InkIntent?, span: CodeSpan?) -> CodeDecision {
        let hasText = !(raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // A ✓ or an X accepts or rejects; striking code out asks for a change. Neither is a question.
        if shape == .check || shape == .cross || strike { return hasText ? .note : .none }
        guard hasText else { return .none }
        guard let span else { return .note }
        if CodeQuestion.asks(raw) || CodeQuestion.asks(tidied) {
            let words = CodeQuestion.isLone(raw) || CodeQuestion.isLone(tidied) ? whatDoesThisMean : (tidied?.isEmpty == false ? tidied! : raw!)
            return .ask(words.trimmingCharacters(in: .whitespacesAndNewlines), shown: span.isFallback)
        }
        // Only the model heard a question: ask it, but show what it's about.
        if kind == .question { return .ask((tidied ?? raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines), shown: true) }
        return .note
    }
}

enum CodeAnchors {
    /// What a note's mark is about, by the most telling mark first: an arrow's end, what a loop goes around, the
    /// words a line crosses, the lines a bar runs beside; else the line nearest the writing. Also whether a straight
    /// line strikes code out (through its middle) rather than underlining it.
    static func resolve(_ shape: InkShapeResult, geometry g: CodePageGeometry, lines text: [Substring]) -> (span: CodeSpan, strike: Bool) {
        switch shape.shape {
        case .arrow:
            if let head = shape.head, let s = word(at: head, g, text) { return (with(s, step: 1), false) }
        case .lasso:
            if let s = enclosed(shape.polygon, g) { return (with(s, step: 2), false) }
        case .line:
            let a = abs(shape.angle ?? 0).truncatingRemainder(dividingBy: 180)
            if a < 25 || a > 155, let (s, strike) = crossed(shape.bounds, g) { return (with(s, step: 3), strike) }
            if abs(a - 90) < 25, let r = g.lines(in: shape.bounds) { return (CodeSpan(start: r.lowerBound, end: r.upperBound, step: 4), false) }
        case .cross, .check, .dot:
            if let c = shape.center, let s = word(at: c, g, text) { return (with(s, step: 3), false) }
        case .writing:
            break
        }
        // The line level with where the writing starts (or the mark, without writing).
        let r = shape.textBounds ?? shape.bounds
        let y = r.minY + min(r.height, g.lineHeight) / 2
        let n = g.line(at: y) ?? (y < g.top ? 1 : g.lineCount)
        return (CodeSpan(start: n, end: n, step: 5), false)
    }

    private static func with(_ s: CodeSpan, step: Int) -> CodeSpan {
        var s = s
        s.step = step
        return s
    }

    /// The name or word at a point on the code (a run of letters, digits and _), or the character there.
    static func word(at p: CGPoint, _ g: CodePageGeometry, _ text: [Substring]) -> CodeSpan? {
        guard let n = g.line(at: p.y), let c = g.column(line: n, at: p) else { return nil }
        guard n <= text.count else { return CodeSpan(start: n, end: n, from: c, to: c, step: 0) }
        let chars = Array(text[n - 1])
        let isWord = { (ch: Character) in ch.isLetter || ch.isNumber || ch == "_" }
        guard c < chars.count, isWord(chars[c]) else { return CodeSpan(start: n, end: n, from: c, to: c, step: 0) }
        var a = c, b = c
        while a > 0, isWord(chars[a - 1]) { a -= 1 }
        while b + 1 < chars.count, isWord(chars[b + 1]) { b += 1 }
        return CodeSpan(start: n, end: n, from: a, to: b, step: 0)
    }

    /// The code a loop goes around: the characters whose middles are inside it, from the first to the last.
    static func enclosed(_ polygon: [CGPoint], _ g: CodePageGeometry) -> CodeSpan? {
        guard polygon.count > 2, let lines = g.lines(in: InkGeometry.bounds(polygon)) else { return nil }
        var first: (line: Int, col: Int)?, last: (line: Int, col: Int)?
        for n in lines {
            for c in 0..<g.length(line: n) {
                guard let r = g.charRects(line: n, cols: c...c).first, InkGeometry.contains(polygon, CGPoint(x: r.midX, y: r.midY)) else { continue }
                if first == nil { first = (n, c) }
                last = (n, c)
            }
        }
        guard let first, let last else { return nil }
        // Around whole lines (most of each): the lines, not their characters.
        let whole = first.col <= g.lead(line: first.line) + 1 && last.col >= g.length(line: last.line) - 2
        return whole ? CodeSpan(start: first.line, end: last.line, step: 0)
            : CodeSpan(start: first.line, end: last.line, from: first.col, to: last.col, step: 0)
    }

    /// The words a straight line crosses: through a row's middle strikes them out; just under a row underlines them.
    static func crossed(_ b: CGRect, _ g: CodePageGeometry) -> (CodeSpan, Bool)? {
        let y = b.midY
        // The row it's in, or the one just above it (an underline sits on or under its row's bottom).
        for (probe, strike) in [(y, true), (y - g.lineHeight * 0.5, false)] {
            guard let n = g.line(at: probe) else { continue }
            let rows = g.codeRects(line: n).filter { $0.minY <= probe && probe <= $0.maxY }
            guard let row = rows.first, b.maxX > row.minX, b.minX < row.maxX else { continue }
            let inMiddle = y > row.minY + row.height * 0.3 && y < row.maxY - row.height * 0.25
            if strike && !inMiddle { continue }
            let from = g.column(line: n, at: CGPoint(x: max(b.minX, row.minX) + 1, y: row.midY)),
                to = g.column(line: n, at: CGPoint(x: min(b.maxX, row.maxX) - 1, y: row.midY))
            guard let from, let to, from <= to else { continue }
            return (CodeSpan(start: n, end: n, from: from, to: to, step: 0), strike)
        }
        return nil
    }
}

enum CodeTagger {
    /// A note on code: what it means and the lines it's about, from its mark first.
    static func note(id: String, shape: InkShapeResult, text: String?, color: InkColorName, path: String,
                     geometry g: CodePageGeometry, lines: [Substring]) -> (note: InkNote, span: CodeSpan, strike: Bool) {
        let (span, strike) = CodeAnchors.resolve(shape, geometry: g, lines: lines)
        let words = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmptyCode
        var intent: InkIntent
        switch shape.shape {
        case .cross: intent = .remove
        case .check: intent = .approve
        case .line: intent = strike ? .change : .emphasize
        case .writing: intent = .comment
        case .lasso, .arrow, .dot: intent = .emphasize
        }
        if [.comment, .emphasize].contains(intent) {
            if CodeQuestion.asks(words) { intent = .question }
            else {
                switch color {
                case .red: intent = .change
                case .blue: intent = .question
                case .green: intent = .approve
                case .other: if words != nil { intent = .comment }
                }
            }
        }
        let code = (span.start...span.end).compactMap { $0 <= lines.count ? String(lines[$0 - 1].prefix(160)) : nil }.joined(separator: "\n")
        let note = InkNote(id: id, intent: intent, text: words, lines: [InkLines(file: path, start: span.start, end: span.end, code: code)],
                           color: color == .other ? nil : color.rawValue)
        return (note, span, strike)
    }
}

private extension String {
    var nilIfEmptyCode: String? { isEmpty ? nil : self }
}
