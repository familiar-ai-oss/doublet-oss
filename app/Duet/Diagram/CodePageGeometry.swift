import CoreGraphics
import DuetKit
import Foundation

/// Where everything is on a native code page, in page coordinates (zoom 1), which are the ink's coordinates too.
///
/// The page is a sheet of paper of a fixed width (`paper`, in characters), chosen once per file and kept with its
/// notes. A line longer than the paper wraps inside it onto more rows, so nothing runs off the side, and a window of
/// another size fits the paper by zooming rather than wrapping again: a line's place never changes under its ink.
/// Every row is the same height, so a line's place follows from its number and the rows before it.
struct CodePageGeometry: Equatable {
    /// The code's size at the default text size: larger than an editor's, so it reads (and takes writing) without
    /// zooming, as a page in Notes does. The page follows the user's text size from there.
    static let baseFontSize: CGFloat = 16
    /// The narrowest paper: narrower, and wrapped code gets hard to read.
    static let minimumPaper = 40

    /// One row of a wrapped line: its characters `start..<end`, and whether it ends mid-word (no space or
    /// punctuation to break at), which the page marks.
    struct Row: Equatable {
        let start: Int
        let end: Int
        let hard: Bool
    }

    let lineCount: Int
    /// The longest line, in characters.
    let columns: Int
    /// Characters of code per row.
    let paper: Int
    /// One character's width in the page's monospaced font.
    let advance: CGFloat
    let fontSize: CGFloat
    /// Each wrapped line's rows (by line number); a line that fits has none here.
    private(set) var wrapped: [Int: [Row]] = [:]
    /// Where each wrapped line's continuation rows start across: under its own indent, and further in.
    private(set) var hanging: [Int: Int] = [:]
    /// The first row of each line (index 0 is line 1), and the total after the last.
    private var firstRow: [Int] = []
    /// Each line's indent and length in characters (index 0 is line 1): where its code is, for what a mark covers.
    private var extents: [Extent] = []
    private struct Extent: Equatable { let lead: Int; let count: Int }

    /// Every row's height, and the margins, follow from the font's size.
    var lineHeight: CGFloat { (fontSize * 1.5).rounded() }
    var top: CGFloat { (fontSize * 0.75).rounded() }
    /// Room in the gutter for a note's bubble or a diagram's mark before the line number.
    var left: CGFloat { (fontSize * 1.5).rounded() }
    var bottom: CGFloat { fontSize * 3 }
    var right: CGFloat { fontSize * 1.5 }

    init(lineCount: Int, columns: Int, advance: CGFloat, fontSize: CGFloat = baseFontSize) {
        self.lineCount = max(lineCount, 1)
        self.columns = max(columns, 1)
        self.paper = max(columns, 1)
        self.advance = advance
        self.fontSize = fontSize
        firstRow = Array(0...self.lineCount)
        extents = Array(repeating: Extent(lead: 0, count: columns), count: self.lineCount)
    }

    /// The file's lines on paper `paper` characters wide (nil: as wide as its longest line, so nothing wraps). Tabs
    /// should already be spaces (`expanded`), so a character is a column. A final newline doesn't start a line.
    init(text: String, advance: CGFloat, fontSize: CGFloat = baseFontSize, paper: Int? = nil) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        lineCount = max(lines.count, 1)
        columns = max(lines.map(\.count).max() ?? 1, 1)
        self.paper = max(paper.map { max($0, Self.minimumPaper) } ?? columns, 1)
        self.advance = advance
        self.fontSize = fontSize
        var first = [0]
        first.reserveCapacity(lineCount + 1)
        extents = lines.map { l in Extent(lead: l.prefix { $0 == " " }.count, count: l.count) }
        if extents.isEmpty { extents = [Extent(lead: 0, count: 0)] }
        for (i, line) in lines.enumerated() {
            var rows = 1
            if line.count > self.paper {
                let (r, h) = Self.wrap(Array(line), width: self.paper)
                if r.count > 1 { wrapped[i + 1] = r; hanging[i + 1] = h; rows = r.count }
            }
            first.append(first[i] + rows)
        }
        if lines.isEmpty { first.append(1) }
        firstRow = first
    }

    /// Text as the page lays it out: a tab is four spaces, as on the web page.
    static func expanded(_ text: String) -> String { text.replacingOccurrences(of: "\t", with: "    ") }

    /// Characters before the code: the line number and two spaces.
    var gutter: Int { String(lineCount).count + 2 }
    /// Where the code starts across the page.
    var codeX: CGFloat { left + CGFloat(gutter) * advance }
    /// The paper's width.
    var width: CGFloat { codeX + CGFloat(paper) * advance + right }
    var rowCount: Int { firstRow.last ?? lineCount }

    /// The page's size, at least `minimum` (the screen at its zoom), so you can write past the end of a short file.
    func size(atLeast minimum: CGSize = .zero) -> CGSize {
        CGSize(width: max(width, minimum.width), height: max(top + CGFloat(rowCount) * lineHeight + bottom, minimum.height))
    }

    /// How many rows line `n` takes.
    func rows(line n: Int) -> Int { firstRow[n] - firstRow[n - 1] }

    /// Line `n` (from 1) across the whole page, all its rows.
    func rect(line n: Int, width: CGFloat) -> CGRect {
        let n = min(max(n, 1), lineCount)
        return CGRect(x: 0, y: top + CGFloat(firstRow[n - 1]) * lineHeight, width: width, height: CGFloat(rows(line: n)) * lineHeight)
    }

    /// Row `r` (from 0, counting every row of every line) across the page.
    func rect(row r: Int, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: top + CGFloat(r) * lineHeight, width: width, height: lineHeight)
    }

    /// The line at a height on the page, if there's one there: a continuation row belongs to its line.
    func line(at y: CGFloat) -> Int? {
        let r = Int(floor((y - top) / lineHeight))
        guard r >= 0, r < rowCount else { return nil }
        // The last line whose first row is at or before r.
        var lo = 0, hi = lineCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if firstRow[mid] <= r { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    /// The lines that run through a span of the page.
    func lines(in r: CGRect) -> ClosedRange<Int>? {
        let end = top + CGFloat(rowCount) * lineHeight
        guard r.maxY > top, r.minY < end else { return nil }
        guard let first = line(at: max(r.minY, top)), let last = line(at: min(r.maxY, end) - 0.01) else { return nil }
        return first...last
    }

    // MARK: where the code is

    /// Row `k` of line `n`: its first character, and where that character sits across the page.
    private func row(_ n: Int, _ k: Int) -> (start: Int, end: Int, x: CGFloat) {
        guard let rows = wrapped[n] else { return (0, extents[n - 1].count, codeX) }
        let r = rows[k]
        return (r.start, r.end, codeX + CGFloat(k == 0 ? 0 : hanging[n] ?? 0) * advance)
    }

    /// Line `n`'s length and indent, in characters.
    func length(line n: Int) -> Int { n >= 1 && n <= lineCount ? extents[n - 1].count : 0 }
    func lead(line n: Int) -> Int { n >= 1 && n <= lineCount ? extents[n - 1].lead : 0 }

    /// Where line `n`'s code is: one rectangle per row, from its first character to its last (a blank line has none).
    func codeRects(line n: Int) -> [CGRect] {
        guard n >= 1, n <= lineCount else { return [] }
        let e = extents[n - 1], top = rect(line: n, width: 0).minY
        return (0..<rows(line: n)).compactMap { k in
            let r = row(n, k)
            let from = k == 0 ? max(r.start, e.lead) : r.start
            guard r.end > from else { return nil }
            return CGRect(x: r.x + CGFloat(from - r.start) * advance, y: top + CGFloat(k) * lineHeight, width: CGFloat(r.end - from) * advance, height: lineHeight)
        }
    }

    /// Characters `cols` of line `n`, one rectangle per row they're on.
    func charRects(line n: Int, cols: ClosedRange<Int>) -> [CGRect] {
        guard n >= 1, n <= lineCount else { return [] }
        let top = rect(line: n, width: 0).minY
        return (0..<rows(line: n)).compactMap { k in
            let r = row(n, k)
            let a = max(cols.lowerBound, r.start), b = min(cols.upperBound + 1, r.end)
            guard b > a else { return nil }
            return CGRect(x: r.x + CGFloat(a - r.start) * advance, y: top + CGFloat(k) * lineHeight, width: CGFloat(b - a) * advance, height: lineHeight)
        }
    }

    /// The character of line `n` under a point (across its row), if the point is on its code.
    func column(line n: Int, at p: CGPoint) -> Int? {
        guard n >= 1, n <= lineCount else { return nil }
        let k = Int(floor((p.y - rect(line: n, width: 0).minY) / lineHeight))
        guard k >= 0, k < rows(line: n) else { return nil }
        let r = row(n, k)
        let c = r.start + Int(floor((p.x - r.x) / advance))
        return c >= max(r.start, k == 0 ? extents[n - 1].lead : 0) && c < r.end ? c : nil
    }

    /// What a note can be tagged to: each line, all its rows, as the web page reported them (id `L<n>`, the line's code
    /// as its label).
    func anchors(path: String, text: String, width: CGFloat) -> [InkAnchor] {
        var out: [InkAnchor] = []
        out.reserveCapacity(lineCount)
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(lineCount).enumerated() {
            out.append(InkAnchor(id: "L\(i + 1)", label: String(line.prefix(160)), rect: rect(line: i + 1, width: width), file: path, line: i + 1))
        }
        return out
    }

    /// A long line's rows on paper `width` characters wide. Continuation rows hang under the line's own indent and
    /// four further in (so one can't pass for the next statement), unless that leaves too little room. A row breaks
    /// after a space or punctuation near its end, never inside a name or a number; only a run with nowhere to break
    /// (a long string or URL) is cut mid-word, and that row is marked `hard`.
    static func wrap(_ chars: [Character], width: Int) -> (rows: [Row], hanging: Int) {
        let lead = chars.prefix { $0 == " " }.count
        var hang = lead + 4
        if width - hang < max(20, width / 3) { hang = min(4, width / 4) }
        var rows: [Row] = []
        var at = 0, room = width
        while chars.count - at > room {
            let end = at + room
            var cut = end, hard = true
            // The last place to break in the row's final 40%: after a space, or after , ; ( [ { or an operator.
            var i = end
            let floor = at + room * 6 / 10
            while i > floor {
                let c = chars[i - 1]
                if c == " " || ",;([{".contains(c) || ("+-*/=&|<>.".contains(c) && i < chars.count && chars[i] == " ") {
                    cut = i
                    hard = false
                    break
                }
                i -= 1
            }
            rows.append(Row(start: at, end: cut, hard: hard))
            at = cut
            // A continuation row starts at its code, not at the spaces it broke on.
            while at < chars.count, chars[at] == " " { at += 1 }
            room = width - hang
        }
        rows.append(Row(start: at, end: chars.count, hard: false))
        return (rows, hang)
    }
}
