import Foundation
import Testing
import UIKit
@testable import Duet

/// A file's code colored natively (CodeSyntax): each kind of token lands on the right text, coloring never changes the
/// text, and a long file is quick.
@MainActor
struct CodeSyntaxTests {
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

    /// Each token's text and kind.
    private func spans(_ text: String, _ language: String) -> [(text: String, kind: CodeSyntax.Kind)] {
        let ns = text as NSString
        return CodeSyntax.tokens(text, language: language).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func kind(of piece: String, in text: String, _ language: String) -> CodeSyntax.Kind? {
        spans(text, language).first { $0.text == piece }?.kind
    }

    /// The 1-based lines a kind of token touches.
    private func lines(_ kind: CodeSyntax.Kind, in text: String, _ language: String) -> [Int] {
        let ns = text as NSString
        var found = Set<Int>()
        for token in CodeSyntax.tokens(text, language: language) where token.kind == kind {
            let first = ns.substring(to: token.range.location).count(where: { $0 == "\n" }) + 1
            let inside = ns.substring(with: token.range).count(where: { $0 == "\n" })
            found.formUnion(first...(first + inside))
        }
        return found.sorted()
    }

    @Test func colorsSwift() {
        let text = Self.swift
        for word in ["import", "struct", "let", "var", "func"] { #expect(kind(of: word, in: text, "swift") == .keyword, "\(word)") }
        #expect(kind(of: "Lexer", in: text, "swift") == .type)
        #expect(kind(of: "String", in: text, "swift") == .type)
        #expect(kind(of: "name", in: text, "swift") == .title)
        #expect(kind(of: "42", in: text, "swift") == .number)
        #expect(kind(of: "// how many", in: text, "swift") == .comment)
        #expect(kind(of: "/// Splits source text into tokens.", in: text, "swift") == .doc)
        #expect(kind(of: "/// - Parameter source: the text.", in: text, "swift") == .doc)
        #expect(kind(of: "/* A block comment\n       over two lines. */", in: text, "swift") == .comment)
        // The interpolation stays in the base color, as highlight.js leaves it.
        #expect(kind(of: "\"lexer ", in: text, "swift") == .string)
        #expect(!spans(text, "swift").contains { $0.text.contains("count)") })
        #expect(kind(of: "source", in: text, "swift") == nil)
    }

    @Test func setsPythonDocstringsApart() {
        // The docstring's four lines are docs; the string assigned to s is a string.
        #expect(lines(.doc, in: Self.python, "python") == [2, 3, 4, 5])
        #expect(lines(.string, in: Self.python, "python") == [7, 8])
        #expect(lines(.comment, in: Self.python, "python") == [6])
        #expect(kind(of: "def", in: Self.python, "python") == .keyword)
        #expect(kind(of: "scan", in: Self.python, "python") == .title)
    }

    @Test func colorsOtherLanguages() {
        #expect(kind(of: "/a[/]b/g", in: "const re = /a[/]b/g; x = a / 2", "typescript") == .regexp)
        #expect(kind(of: "println!", in: "fn main() { println!(\"hi\"); }", "rust") == .builtIn)
        #expect(kind(of: "#[derive(Debug)]", in: "#[derive(Debug)]\nstruct A<'a> { c: char }", "rust") == .meta)
        #expect(kind(of: "#include", in: "#include <stdio.h>\nint x = 0x1F;", "c") == .meta)
        #expect(kind(of: "0x1F", in: "int x = 0x1F;", "c") == .number)
        #expect(kind(of: "\"a\"", in: "{\"a\": \"b\"}", "json") == .title)
        #expect(kind(of: "\"b\"", in: "{\"a\": \"b\"}", "json") == .string)
        #expect(kind(of: "port", in: "port: 8080 # c", "yaml") == .title)
        #expect(kind(of: "8080", in: "port: 8080 # c", "yaml") == .number)
        #expect(kind(of: "SELECT", in: "SELECT a FROM t -- c", "sql") == .keyword)
        #expect(kind(of: "# Title", in: "# Title\ntext", "markdown") == .type)
        #expect(kind(of: "@Test", in: "@Test func a() {}", "swift") == .meta)
        #expect(kind(of: "#if", in: "#if os(iOS)\n#endif", "swift") == .meta)
        #expect(kind(of: "echo", in: "echo $# # c", "bash") == .builtIn)
        #expect(kind(of: "# c", in: "echo $# # c", "bash") == .comment)
        #expect(lines(.addition, in: "@@ -1 +1 @@\n-old\n+new\n same", "diff") == [3])
        #expect(lines(.deletion, in: "@@ -1 +1 @@\n-old\n+new\n same", "diff") == [2])
        // A language it has no words for still gets its strings and comments.
        #expect(kind(of: "\"s\"", in: "x = \"s\" // c", "haskell") == .string)
    }

    @Test func coloringNeverChangesTheText() {
        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        for (text, language) in [(Self.swift, "swift"), (Self.python, "python"), ("é 👋🏽 \"ü\" // ✓\n", "swift"), ("", "swift")] {
            for dark in [false, true] {
                #expect(CodeSyntax.attributed(text, language: language, dark: dark, font: font).string == text)
            }
        }
        // Comments are italic, code isn't.
        let colored = CodeSyntax.attributed(Self.swift, language: "swift", dark: false, font: font)
        let ns = Self.swift as NSString
        let comment = colored.attribute(.font, at: ns.range(of: "// how many").location, effectiveRange: nil) as? UIFont
        let code = colored.attribute(.font, at: ns.range(of: "struct").location, effectiveRange: nil) as? UIFont
        #expect(comment?.fontDescriptor.symbolicTraits.contains(.traitItalic) == true)
        #expect(code == font)
        #expect(colored.attribute(.foregroundColor, at: ns.range(of: "struct").location, effectiveRange: nil) as? UIColor
            != colored.attribute(.foregroundColor, at: ns.range(of: "source").location, effectiveRange: nil) as? UIColor)
    }

    @Test func noLanguageIsPlain() {
        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let plain = CodeSyntax.attributed(Self.swift, language: nil, dark: true, font: font)
        var runs = 0
        plain.enumerateAttributes(in: NSRange(location: 0, length: plain.length)) { attributes, _, _ in
            runs += 1
            #expect(Set(attributes.keys) == [.font, .foregroundColor])
        }
        #expect(runs == 1)
    }

    @Test func anUnclosedStringOrCommentEndsAtTheEnd() {
        for (text, language) in [("let s = \"unterminated", "swift"), ("x /* open", "swift"), ("s = \"\"\"\nopen", "python"),
                                 ("let r = #\"raw", "swift"), ("x = `open ${a", "javascript"), ("/** doc", "java"),
                                 ("'\\", "rust"), ("\"\\", "swift"), ("```\ncode", "markdown"), ("<a href=\"", "xml")] {
            let tokens = CodeSyntax.tokens(text, language: language)
            let length = (text as NSString).length
            #expect(!tokens.isEmpty, "\(language): \(text)")
            for token in tokens { #expect(token.range.location >= 0 && NSMaxRange(token.range) <= length, "\(language): \(text)") }
        }
    }

    @Test func tokensAreInOrderAndApart() {
        for (text, language) in [(Self.swift, "swift"), (Self.python, "python")] {
            var end = 0
            for token in CodeSyntax.tokens(text, language: language) {
                #expect(token.range.location >= end && token.range.length > 0)
                end = NSMaxRange(token.range)
            }
        }
    }

    /// A long file (2,200 lines) colored well inside a frame budget's worth of the page's 50 ms.
    @Test func aLongFileIsQuick() {
        let text = Array(repeating: Self.swift, count: 200).joined(separator: "\n")
        _ = CodeSyntax.tokens(text, language: "swift")
        let clock = ContinuousClock()
        var count = 0
        let took = clock.measure { count = CodeSyntax.tokens(text, language: "swift").count }
        print("code syntax: \(count) tokens in \(took)")
        #expect(count > 3000)
        // Debug builds are several times slower than Release; this still catches a pass that's gone quadratic.
        #expect(took < .milliseconds(250))
    }
}
