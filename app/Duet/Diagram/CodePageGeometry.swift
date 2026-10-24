import CoreGraphics
import DuetKit
import Foundation

/// Where everything is on a native code page, in page coordinates (zoom 1), which are the ink's coordinates too.
/// Every line is the same height and never wraps, so a line's place follows from its number alone: ink written over
/// line N stays over line N at any width or zoom, and notes are tagged to lines the same way the web page tagged them.
struct CodePageGeometry: Equatable {
    static let lineHeight: CGFloat = 20
    static let fontSize: CGFloat = 13
    static let top: CGFloat = 12, left: CGFloat = 12, bottom: CGFloat = 40, right: CGFloat = 24

    let lineCount: Int
    /// The longest line, in characters.
    let columns: Int
    /// One character's width in the page's monospaced font.
    let advance: CGFloat

    init(lineCount: Int, columns: Int, advance: CGFloat) {
        self.lineCount = max(lineCount, 1)
        self.columns = max(columns, 1)
        self.advance = advance
    }

    /// The page's lines as the file splits them: a final newline doesn't start another line.
    init(text: String, advance: CGFloat) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        self.init(lineCount: lines.count - (lines.count > 1 && lines.last == "" ? 1 : 0), columns: lines.map(\.count).max() ?? 1, advance: advance)
    }

    /// Characters before the code: the line number and two spaces.
    var gutter: Int { String(lineCount).count + 2 }
    /// Where the code starts across the page.
    var codeX: CGFloat { Self.left + CGFloat(gutter) * advance }

    /// The page's size, at least `minimum` (the screen), so you can write past the end of a short file.
    func size(atLeast minimum: CGSize = .zero) -> CGSize {
        CGSize(width: max(codeX + CGFloat(columns) * advance + Self.right, minimum.width),
               height: max(Self.top + CGFloat(lineCount) * Self.lineHeight + Self.bottom, minimum.height))
    }

    /// Line `n` (from 1) across the whole page.
    func rect(line n: Int, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: Self.top + CGFloat(n - 1) * Self.lineHeight, width: width, height: Self.lineHeight)
    }

    /// The line at a height on the page, if there's one there.
    func line(at y: CGFloat) -> Int? {
        let n = Int(floor((y - Self.top) / Self.lineHeight)) + 1
        return (1...lineCount).contains(n) ? n : nil
    }

    /// The lines that run through a span of the page.
    func lines(in r: CGRect) -> ClosedRange<Int>? {
        let first = max(1, Int(floor((r.minY - Self.top) / Self.lineHeight)) + 1)
        let last = min(lineCount, Int(ceil((r.maxY - Self.top) / Self.lineHeight)))
        return first <= last ? first...last : nil
    }

    /// What a note can be tagged to: each line, as the web page reported them (id `L<n>`, the line's code as its label).
    func anchors(path: String, text: String, width: CGFloat) -> [InkAnchor] {
        var out: [InkAnchor] = []
        out.reserveCapacity(lineCount)
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(lineCount).enumerated() {
            out.append(InkAnchor(id: "L\(i + 1)", label: String(line.prefix(160)), rect: rect(line: i + 1, width: width), file: path, line: i + 1))
        }
        return out
    }
}
