#if os(iOS)
import DuetKit
import Foundation
import Testing
import UIKit
@testable import Duet

/// Long lines on the native page's paper: they wrap inside it, read as one line (one number, a ↪ on each continuation
/// row, a hanging indent), and keep their place, so ink on any of their rows belongs to them.
@MainActor
struct CodePaperTests {
    private static let long = "    let result = parser.parse(source, options: .init(strict: true, recover: false, maxDepth: 64), onError: { report($0) })"
    private static let text = "import Foundation\n" + long + "\nreturn result\n"

    @Test func aLongLineWrapsInsideThePaper() {
        let g = CodePageGeometry(text: Self.text, advance: 8, paper: 72)
        #expect(g.lineCount == 3)
        let rows = try! #require(g.wrapped[2])
        #expect(rows.count == 2)
        #expect(g.rows(line: 1) == 1 && g.rows(line: 2) == 2 && g.rows(line: 3) == 1)
        #expect(g.rowCount == 4)
        // Every row fits: the first in the paper, the rest beside their hanging indent.
        let hang = try! #require(g.hanging[2])
        #expect(hang == 8) // its own indent, and four further in
        for (i, r) in rows.enumerated() { #expect(r.end - r.start <= (i == 0 ? 72 : 72 - hang)) }
        // The rows cover the line, and never break inside a name: each break is after a space or punctuation.
        let chars = Array(Self.long)
        #expect(rows.first?.start == 0 && rows.last?.end == chars.count)
        for r in rows.dropLast() { #expect(!r.hard); #expect(" ,;([{".contains(chars[r.end - 1])) }
    }

    @Test func aContinuationRowBelongsToItsLine() {
        let g = CodePageGeometry(text: Self.text, advance: 8, paper: 72)
        let line2 = g.rect(line: 2, width: 500)
        #expect(line2.height == 2 * g.lineHeight)
        // Ink on the second row of line 2 is on line 2; the next row is line 3.
        #expect(g.line(at: line2.minY + g.lineHeight * 1.5) == 2)
        #expect(g.line(at: line2.maxY + 1) == 3)
        #expect(g.rect(line: 3, width: 1).minY == g.top + 3 * g.lineHeight)
        #expect(g.lines(in: CGRect(x: 0, y: line2.maxY - 4, width: 1, height: 8)) == 2...3)
        let anchors = g.anchors(path: "/p/a.swift", text: Self.text, width: 500)
        #expect(anchors[1].rect == line2)
    }

    @Test func anUnbrokenRunIsCutAndMarked() {
        let url = "let u = \"" + String(repeating: "x", count: 120) + "\""
        let g = CodePageGeometry(text: url, advance: 8, paper: 50)
        let rows = try! #require(g.wrapped[1])
        #expect(rows.contains { $0.hard })
        #expect(rows.last?.end == url.count)
    }

    @Test func nothingWrapsWithoutPaper() {
        let g = CodePageGeometry(text: Self.text, advance: 8)
        #expect(g.wrapped.isEmpty && g.rowCount == 3 && g.paper == Self.long.count)
        // Too narrow a paper is widened to the least that still reads.
        #expect(CodePageGeometry(text: Self.text, advance: 8, paper: 10).paper == CodePageGeometry.minimumPaper)
    }

    @Test func theCuesShowOneLineContinuing() {
        let g = CodePageGeometry(text: Self.text, advance: 8, paper: 72)
        let page = NativeCodeInkView.page(Self.text, path: "/p/a.swift", geometry: g, zoom: 1, dark: false)
        let rows = page.string.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        #expect(rows.count == 5) // four rows and the end
        let shown = Array(rows)
        #expect(shown[0] == "1  import Foundation")
        #expect(shown[1].hasPrefix("2      let result"))
        // The continuation: no number, a ↪ where it would be, and the hanging indent.
        #expect(shown[2].hasPrefix("↪  " + String(repeating: " ", count: 8)))
        #expect(!shown[2].contains("2  "))
        #expect(shown[3] == "3  return result")
        // The text is all there, in order: joined back, the rows are the line.
        let back = shown[1].dropFirst(3) + shown[2].dropFirst(3 + 8)
        #expect(back.replacingOccurrences(of: " ", with: "") == Self.long.replacingOccurrences(of: " ", with: ""))
        // The ↪ is dim; the code keeps its colours across the break.
        let ns = page.string as NSString
        let arrow = ns.range(of: "↪")
        #expect(page.attribute(.foregroundColor, at: arrow.location, effectiveRange: nil) as? UIColor == .tertiaryLabel)
        let truth = ns.range(of: "true")
        #expect(page.attribute(.foregroundColor, at: truth.location, effectiveRange: nil) as? UIColor != .tertiaryLabel)
    }
}
#endif
