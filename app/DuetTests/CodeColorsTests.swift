import DuetKit
import Foundation
import Testing
import WebKit
@testable import Duet

/// A file's page colored as in an editor (CodeHTML, code-colors.js): which files are colored as what, and that coloring
/// leaves every line, note and mark where it was.
@MainActor
struct CodeColorsTests {
    private static let swift = #"""
    import Foundation

    /// Splits source text into tokens.
    /// - Parameter source: the text.
    struct Lexer {
        /* A block comment
           over two lines. */
        let source: String
        var count = 42 // how many
        func name() -> String { "lexer \(count)" }
    }
    """#

    private static let python = #"""
    def scan(text):
        """Split text into tokens.

        Returns a list.
        """
        # a comment
        s = """not a docstring
    still a string"""
        return [t for t in text.split()]
    """#

    @Test func picksTheLanguageByNameOrFirstLine() {
        #expect(CodeHTML.language(path: "/p/Sources/Lexer.swift", text: "") == "swift")
        #expect(CodeHTML.language(path: "/p/src/main.TS", text: "") == "typescript")
        #expect(CodeHTML.language(path: "/p/a.py", text: "") == "python")
        #expect(CodeHTML.language(path: "/p/Cargo.toml", text: "") == "ini")
        #expect(CodeHTML.language(path: "/p/README.md", text: "") == "markdown")
        #expect(CodeHTML.language(path: "/p/x.hpp", text: "") == "cpp")
        #expect(CodeHTML.language(path: "/p/Makefile", text: "") == "makefile")
        #expect(CodeHTML.language(path: "/p/bin/deploy", text: "#!/usr/bin/env bash\necho hi") == "bash")
        #expect(CodeHTML.language(path: "/p/bin/tool", text: "#!/usr/bin/env python3\n") == "python")
        // Not code it knows, or too long to color quickly: plain.
        #expect(CodeHTML.language(path: "/p/notes.txt", text: "hello") == nil)
        #expect(CodeHTML.language(path: "/p/LICENSE", text: "MIT") == nil)
        #expect(CodeHTML.language(path: "/p/big.swift", text: String(repeating: "let x = 1\n", count: 50_000)) == nil)
    }

    @Test func colorsSwiftWithoutMovingALine() async throws {
        try await compare(Self.swift, as: "Lexer.swift", dark: false)
        try await compare(Self.swift, as: "Lexer.swift", dark: true)
    }

    @Test func setsPythonDocstringsApart() async throws {
        let page = try await compare(Self.python, as: "scan.py", dark: false)
        // The docstring's four lines are docs; the string assigned to s is a string.
        let docs = try await page.web.evaluateJavaScript("[...document.querySelectorAll('.ln')].filter(r => r.querySelector('.hljs-doc')).map(r => +r.dataset.line).join(',')") as? String
        #expect(docs == "2,3,4,5")
        let strings = try await page.web.evaluateJavaScript("[...document.querySelectorAll('.ln')].filter(r => r.querySelector('.hljs-string:not(.hljs-doc)')).map(r => +r.dataset.line).join(',')") as? String
        #expect(strings == "7,8")
    }

    /// The sample conversation's file, at an iPhone's width and an iPad's.
    @Test func colorsTheDemoFile() async throws {
        let path = "/home/you/projects/parser/Sources/Parser/Lexer.swift"
        let text = try #require(PreviewData.files[path])
        for (width, dark) in [(390.0, false), (390.0, true), (1000.0, false), (1000.0, true)] {
            try await compare(text, as: "Lexer.swift", dark: dark, width: width, changed: [33, 34], marks: [:], peeks: [])
        }
    }

    /// A long file shows plain first and is colored just after, still without moving a line.
    @Test func colorsALongFileJustAfter() async throws {
        let text = Array(repeating: Self.swift, count: 200).joined(separator: "\n")
        #expect(text.utf8.count > 40_000)
        try await compare(text, as: "Long.swift", dark: false, picture: false)
    }

    /// Loads the file plain (as a .txt) and colored, and checks that the colored page has every row, note card and diagram
    /// mark at the same place and size, and each row the same text. Saves a picture of the colored page.
    @discardableResult
    private func compare(_ text: String, as name: String, dark: Bool, width: CGFloat = 640, changed: [Int] = [4],
                         marks: [Int: LineMark] = [3: LineMark(ids: ["n-1"], state: "answered", cards: [NoteCard(id: "n-1", question: "why?", answer: "Because.")])],
                         peeks: [DiagramPeek] = [DiagramPeek(id: "g1", title: "Lexer states", lines: [5, 6, 7], elements: [.init(id: "Start", label: "Start", line: 6)])],
                         picture: Bool = true) async throws -> DiagramPage {
        func doc(_ path: String) -> DiagramDocument { .code(path: path, text: text, changed: changed, removedAfter: [], marks: marks, peeks: peeks) }
        let plain = try await laidOut(doc("/p/\(name).txt"), dark: dark, width: width)
        let colored = try await laidOut(doc("/p/\(name)"), dark: dark, width: width)
        // A long file is colored just after it's shown.
        let spans = "document.querySelectorAll('.cd [class^=hljs]').length"
        for _ in 0..<50 {
            if try await colored.web.evaluateJavaScript(spans) as? Int ?? 0 > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try await colored.web.evaluateJavaScript(spans) as? Int ?? 0 > 5)
        #expect(try await plain.web.evaluateJavaScript("document.querySelectorAll('.cd span').length") as? Int == 0)

        // Measured again now that it's colored.
        let rects = "[...document.querySelectorAll('.ln, .nc, .dc, .dm, .dx')].map(e => { const r = e.getBoundingClientRect(); return [r.left + scrollX, r.top + scrollY, r.width, r.height].join(' ') }).join(',')"
        let before = try await plain.web.evaluateJavaScript(rects) as? String
        #expect(before?.isEmpty == false)
        #expect(try await colored.web.evaluateJavaScript(rects) as? String == before)
        // The page drops a last empty line.
        let shown = text.hasSuffix("\n") ? String(text.dropLast()) : text
        #expect(colored.anchors.count == shown.split(separator: "\n", omittingEmptySubsequences: false).count)
        #expect(colored.anchors.map(\.rect) == plain.anchors.map(\.rect))
        #expect(colored.contentSize == plain.contentSize)
        let rows = "[...document.querySelectorAll('.ln > .cd')].map(r => r.textContent).join('\\n')"
        #expect(try await colored.web.evaluateJavaScript(rows) as? String == shown.replacingOccurrences(of: "\t", with: "    "))

        // Comments and docs read differently from code and from each other.
        let color = { (sel: String) in try await colored.web.evaluateJavaScript("(e => e && getComputedStyle(e).color)(document.querySelector('\(sel)'))") as? String }
        let keyword = try await color(".hljs-keyword"), doc = try await color(".hljs-doc"), comment = try await color(".hljs-comment:not(.hljs-doc)")
        #expect(keyword != nil && doc != nil && keyword != doc)
        if comment != nil { #expect(comment != doc && comment != keyword) }

        #if os(iOS)
        // A picture to look at, on the background the app puts behind the page.
        if picture {
            colored.web.frame.size.height = min(max(colored.contentSize.height, 200), 1400)
            _ = try await colored.web.evaluateJavaScript("document.body.style.background = '\(dark ? "#1c1c1e" : "#ffffff")'; 0")
            if let image = await colored.snapshot(), let png = image.pngData() {
                let url = URL.temporaryDirectory.appending(path: "code-colors-\(name)-\(Int(width))-\(dark ? "dark" : "light").png")
                try png.write(to: url)
                print("code colors picture: \(url.path)")
            }
        }
        #endif
        return colored
    }

    private func laidOut(_ doc: DiagramDocument, dark: Bool, width: CGFloat) async throws -> DiagramPage {
        let page = DiagramPage()
        page.web.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        let laidOut: Void? = await withCheckedContinuation { (done: CheckedContinuation<Void?, Never>) in
            var once = false
            page.onLayout = { _, _ in if !once { once = true; done.resume(returning: ()) } }
            page.load(doc, dark: dark)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                if !once { once = true; done.resume(returning: nil) }
            }
        }
        try #require(laidOut != nil, "the page never laid out")
        return page
    }
}
