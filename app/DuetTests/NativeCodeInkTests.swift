#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import Duet

/// The native code page (a prototype): every line of the file is on the page, numbered, in order and unchanged, so
/// ink written over a line stays over that line.
@MainActor
struct NativeCodeInkTests {
    private static let swift = #"""
    import Foundation

    struct Lexer {
        let source: String // the text
        var count = 42
    }
    """#

    @Test func numbersEveryLineAndKeepsItsText() {
        let page = NativeCodeInkView.page(Self.swift, path: "/p/Lexer.swift", geometry: CodePageGeometry(lineCount: 6, columns: 40, advance: 8), zoom: 1, dark: false)
        // A margin line first, then each line led by its number.
        let lines = page.string.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        let source = Self.swift.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 7) // six lines and the end
        for (n, (shown, line)) in zip(lines, source).enumerated() {
            #expect(shown == "\(n + 1)  \(line)")
        }
    }

    @Test func linesKeepOneHeightAtEveryZoom() {
        for zoom in [1.0, 2.5] as [CGFloat] {
            let page = NativeCodeInkView.page(Self.swift, path: "/p/Lexer.swift", geometry: CodePageGeometry(lineCount: 6, columns: 40, advance: 8), zoom: zoom, dark: true)
            let ns = page.string as NSString
            var at = ns.lineRange(for: NSRange(location: 0, length: 0)).length
            while at < ns.length {
                let style = page.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
                #expect(style?.minimumLineHeight == 24 * zoom)
                #expect(style?.maximumLineHeight == 24 * zoom)
                at = NSMaxRange(ns.lineRange(for: NSRange(location: at, length: 0)))
            }
        }
    }

    @Test func colorsCodeButNotItsNumbers() {
        let page = NativeCodeInkView.page(Self.swift, path: "/p/Lexer.swift", geometry: CodePageGeometry(lineCount: 6, columns: 40, advance: 8), zoom: 1, dark: false)
        let ns = page.string as NSString
        let keyword = ns.range(of: "struct")
        let number = ns.range(of: "\n3  ")
        let kc = page.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? UIColor
        let nc = page.attribute(.foregroundColor, at: number.location + 1, effectiveRange: nil) as? UIColor
        #expect(nc == .tertiaryLabel)
        #expect(kc != nil && kc != .tertiaryLabel && kc != .label)
    }

    @Test func aFileWithoutAFinalNewlineEndsCleanly() {
        let page = NativeCodeInkView.page("a\nb", path: "/p/notes.txt", geometry: CodePageGeometry(lineCount: 2, columns: 40, advance: 8), zoom: 1, dark: false)
        #expect(page.string == "\n1  a\n2  b\n")
    }
}
#endif
