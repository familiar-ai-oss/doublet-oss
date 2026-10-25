import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A file's code colored natively, as the code page's highlight.js does (CodeHTML): one hand-written pass over the
/// text's UTF-16, so a 2,000-line file takes a few milliseconds and the ranges line up with NSString's. Languages are
/// named as CodeHTML.language(path:text:) names them.
enum CodeSyntax {
    enum Kind: Equatable, Sendable { case keyword, string, regexp, number, type, title, builtIn, meta, comment, doc, addition, deletion }

    #if canImport(UIKit)
    typealias PlatformFont = UIFont
    typealias PlatformColor = UIColor
    #else
    typealias PlatformFont = NSFont
    typealias PlatformColor = NSColor
    #endif

    /// The colored ranges of `text`, in order and never overlapping; what isn't in one is plain.
    static func tokens(_ text: String, language: String) -> [(range: NSRange, kind: Kind)] {
        let units = Array(text.utf16)
        let grammar = Grammar.named(language)
        var scanner = Scanner(units, grammar)
        switch grammar.mode {
        case .code, .json: scanner.code()
        case .yaml: scanner.yaml()
        case .ini: scanner.ini()
        case .css: scanner.css()
        case .xml: scanner.xml()
        case .markdown: scanner.markdown()
        case .diff: scanner.diff()
        }
        return scanner.out
    }

    /// The whole text in `font` and the label color, its tokens colored, comments and docs in italic. The text itself is
    /// never changed. No language: plain.
    static func attributed(_ text: String, language: String?, dark: Bool, font: PlatformFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color(base, dark: dark)])
        guard let language else { return result }
        let italic = italicFont(font)
        let colors = palette.mapValues { color($0, dark: dark) }
        result.beginEditing()
        for token in tokens(text, language: language) {
            if let color = colors[token.kind] { result.addAttribute(.foregroundColor, value: color, range: token.range) }
            if token.kind == .comment || token.kind == .doc { result.addAttribute(.font, value: italic, range: token.range) }
        }
        result.endEditing()
        return result
    }

    // MARK: Colors

    /// (dark, light). This mirrors DiagramPage's `.cd .hljs-*` CSS until DesignSystem has code tokens.
    private static let base: (UInt32, UInt32) = (0xe5e5e7, 0x1d1d1f)
    private static let palette: [Kind: (UInt32, UInt32)] = [
        .keyword: (0xff7ab2, 0x9b2393), .string: (0xfc6a5d, 0xc41a16), .regexp: (0xff8170, 0xa3351b),
        .number: (0xd9c97c, 0x1c00cf), .type: (0x5dd8ff, 0x0b4f79), .title: (0x67b7a4, 0x0f68a0),
        .builtIn: (0xd0a8ff, 0x6c36a9), .meta: (0xfd8f3f, 0x815f03), .comment: (0x8e959e, 0x6e7781),
        .doc: (0x7cc893, 0x2e7a46), .addition: (0x7ee787, 0x116329), .deletion: (0xff7b72, 0xa40e26),
    ]

    private static func color(_ pair: (UInt32, UInt32), dark: Bool) -> PlatformColor {
        let hex = dark ? pair.0 : pair.1
        return PlatformColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                             blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    /// The font slanted, or the font itself when it has no italic (some monospaced faces don't).
    private static func italicFont(_ font: PlatformFont) -> PlatformFont {
        #if canImport(UIKit)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #else
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        #endif
    }
}

// MARK: - Grammars

extension CodeSyntax {
    /// What one language's scanner looks for. Most languages are the `code` mode with different words and comments; the
    /// rest are shaped too differently (by line, or by braces) and have their own pass.
    struct Grammar: Sendable {
        enum Mode: Sendable { case code, json, yaml, ini, css, xml, markdown, diff }
        var mode: Mode = .code
        var lineComments: [[UInt16]] = []
        var blockComment: (open: [UInt16], close: [UInt16])?
        /// `///` and `//!`: doc lines.
        var docLines: [[UInt16]] = []
        /// `/** … */` is a doc.
        var docBlocks = false
        var quotes: Set<UInt16> = [q2, q1]
        /// Quotes whose strings run on past a line's end (JS template literals, shell strings).
        var multilineQuotes: Set<UInt16> = []
        /// `"""` (and `'''` where `'` quotes): a string over many lines.
        var tripleQuotes = false
        /// A `"""` string opening a line after a `:` (a def or class) or at the top of a file is a docstring.
        var docstrings = false
        /// An interpolation inside a string, left in the base color as highlight.js does: `\(…)`, `${…}`, `#{…}`.
        var interpolation: (open: [UInt16], close: UInt16, quotes: Set<UInt16>)?
        var keywords: Set<String> = []
        var builtIns: Set<String> = []
        /// The word after one of these is a declaration's name.
        var titleAfter: Set<String> = []
        /// A capitalized word is a type.
        var capitalTypes = false
        /// `@word` is an attribute or decorator.
        var atMeta = false
        /// `#word` is a directive: anywhere (Swift's `#if`, `#available`) or only opening a line (C's preprocessor).
        var hashMeta: HashMeta = .none
        enum HashMeta: Sendable { case none, anywhere, lineStart }
        /// Rust: `#[…]` attributes, `'a` lifetimes, `name!` macros, `r#"…"#` raw strings.
        var rust = false
        /// Swift's `#"…"#` raw strings.
        var rawHashStrings = false
        /// A `/…/` regex literal where a value can start.
        var regex = false
        /// Keywords in any case (SQL).
        var caseInsensitive = false
        /// A `#` comment needs a space (or the line's start) before it, so `$#` and `${#x}` aren't comments.
        var hashNeedsSpace = false
        /// `$` can start a name (JavaScript, PHP).
        var dollarNames = false
        /// Ruby's `:symbol`.
        var symbols = false
        /// Letters that can prefix a string (`f"…"`, `b'…'`, `L"…"`, `@"…"`).
        var stringPrefixes: Set<String> = []
        /// A string key followed by `:` is a name (JSON).
        var keyStrings = false
        /// C#'s @"…" has no escapes.
        var verbatimAt = false

        static func named(_ name: String) -> Grammar { all[name] ?? all[aliases[name] ?? ""] ?? generic }

        private static let aliases: [String: String] = [
            "js": "javascript", "jsx": "javascript", "ts": "typescript", "tsx": "typescript", "py": "python",
            "sh": "bash", "zsh": "bash", "shell": "bash", "yml": "yaml", "c++": "cpp", "objc": "objectivec", "cs": "csharp",
            "kt": "kotlin", "rb": "ruby", "md": "markdown", "html": "xml", "toml": "ini", "patch": "diff",
            "scss": "css", "less": "css", "golang": "go", "rs": "rust",
        ]

        /// Strings, numbers and C-style comments: something sensible for a language it has no words for.
        private static let generic = Grammar(lineComments: [u("//")], blockComment: (u("/*"), u("*/")))

        private static let all: [String: Grammar] = {
            var g: [String: Grammar] = [:]
            let slashes = [u("//")], cBlock = (open: u("/*"), close: u("*/"))

            g["swift"] = Grammar(
                lineComments: slashes, blockComment: cBlock, docLines: [u("///")], docBlocks: true, tripleQuotes: true,
                interpolation: (u("\\("), paren, [q2]),
                keywords: words("""
                    associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private
                    precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default
                    defer do else fallthrough for guard if in repeat return throw switch where while as Any false is nil super self
                    Self throws true try async await actor nonisolated isolated some any mutating nonmutating override final required
                    convenience lazy weak unowned dynamic indirect willSet didSet consuming borrowing sending package macro
                    """),
                builtIns: words("""
                    abs assert assertionFailure debugPrint dump fatalError max min numericCast precondition preconditionFailure print
                    readLine repeatElement sequence stride swap type unsafeBitCast unsafeDowncast withExtendedLifetime
                    withUnsafeMutablePointer withUnsafePointer withoutActuallyEscaping zip
                    """),
                titleAfter: ["func"], capitalTypes: true, atMeta: true, hashMeta: .anywhere, rawHashStrings: true)

            let jsKeywords = """
                as async await break case catch class const continue debugger default delete do else export extends finally for
                from function get if import in instanceof let new of return set static super switch this throw try typeof var void
                while with yield true false null undefined NaN Infinity
                """
            let jsBuiltIns = """
                Array Boolean Date Error JSON Map Math Number Object Promise Proxy Reflect RegExp Set String Symbol WeakMap WeakSet
                console document window globalThis process require module exports parseInt parseFloat isNaN isFinite setTimeout
                setInterval clearTimeout clearInterval fetch structuredClone
                """
            var js = Grammar(
                lineComments: slashes, blockComment: cBlock, docBlocks: true, quotes: [q2, q1, tick], multilineQuotes: [tick],
                interpolation: (u("${"), brace, [tick]), keywords: words(jsKeywords), builtIns: words(jsBuiltIns),
                titleAfter: ["function"], capitalTypes: true, atMeta: true, regex: true, dollarNames: true)
            g["javascript"] = js
            js.keywords.formUnion(words("""
                abstract any boolean declare enum implements interface keyof namespace never number object private protected public
                readonly string symbol type unknown is infer satisfies override asserts
                """))
            g["typescript"] = js

            g["python"] = Grammar(
                lineComments: [u("#")], tripleQuotes: true, docstrings: true,
                keywords: words("""
                    and as assert async await break class continue def del elif else except finally for from global if import in is
                    lambda nonlocal not or pass raise return try while with yield match case False None True
                    """),
                builtIns: words("""
                    abs all any bin bool bytearray bytes callable chr classmethod compile complex delattr dict dir divmod enumerate eval
                    exec filter float format frozenset getattr globals hasattr hash help hex id input int isinstance issubclass iter len
                    list locals map max memoryview min next object oct open ord pow print property range repr reversed round set setattr
                    slice sorted staticmethod str sum super tuple type vars zip self cls __name__ __init__
                    """),
                titleAfter: ["def"], capitalTypes: true, atMeta: true,
                stringPrefixes: ["r", "b", "f", "u", "rb", "br", "fr", "rf", "R", "B", "F", "U", "Rb", "bR", "Br", "RB", "BR", "fR", "Fr", "FR", "rF", "Rf", "RF"])

            g["rust"] = Grammar(
                lineComments: slashes, blockComment: cBlock, docLines: [u("///"), u("//!")], docBlocks: true, multilineQuotes: [q2],
                keywords: words("""
                    as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut
                    pub ref return self Self static struct super trait true type unsafe use where while union macro_rules
                    """),
                builtIns: words("""
                    i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str Some None Ok Err Box Vec String Option
                    Result drop
                    """),
                titleAfter: ["fn"], capitalTypes: true, rust: true, stringPrefixes: ["b"])

            g["go"] = Grammar(
                lineComments: slashes, blockComment: cBlock, quotes: [q2, q1, tick], multilineQuotes: [tick],
                keywords: words("""
                    break case chan const continue default defer else fallthrough for func go goto if import interface map package range
                    return select struct switch type var true false nil iota
                    """),
                builtIns: words("""
                    append cap close complex copy delete imag len make new panic print println real recover bool byte complex64
                    complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any
                    """),
                titleAfter: ["func"])

            g["bash"] = Grammar(
                lineComments: [u("#")], multilineQuotes: [q2, q1],
                keywords: words("""
                    if then else elif fi for while until do done case esac in function select return local export declare readonly
                    unset break continue time true false
                    """),
                builtIns: words("""
                    echo cd printf read set shift source test exit eval exec trap alias unalias pwd pushd popd type command getopts
                    wait kill let shopt umask ulimit mkdir rm cp mv ls cat grep sed awk find xargs sudo chmod chown curl git
                    """),
                titleAfter: ["function"], hashNeedsSpace: true)

            g["json"] = Grammar(mode: .json, lineComments: slashes, blockComment: cBlock, quotes: [q2],
                                keywords: ["true", "false", "null"], keyStrings: true)
            g["yaml"] = Grammar(mode: .yaml)
            g["ini"] = Grammar(mode: .ini)
            g["css"] = Grammar(mode: .css, blockComment: cBlock)
            g["xml"] = Grammar(mode: .xml)
            g["markdown"] = Grammar(mode: .markdown)
            g["diff"] = Grammar(mode: .diff)

            let cKeywords = """
                auto break case char const continue default do double else enum extern float for goto if inline int long register
                restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false
                NULL _Bool _Atomic _Thread_local
                """
            let cBuiltIns = "printf fprintf sprintf snprintf malloc calloc realloc free memcpy memset strlen strcmp exit assert size_t FILE"
            var c = Grammar(lineComments: slashes, blockComment: cBlock, docLines: [u("///")], docBlocks: true,
                            keywords: words(cKeywords), builtIns: words(cBuiltIns), capitalTypes: true, hashMeta: .lineStart,
                            stringPrefixes: ["L", "u", "U", "u8"])
            g["c"] = c
            c.keywords.formUnion(words("""
                alignas alignof and asm catch class constexpr consteval constinit const_cast co_await co_return co_yield concept
                decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not nullptr operator or private
                protected public reinterpret_cast requires static_assert static_cast template this thread_local throw try typeid
                typename using virtual override final
                """))
            c.builtIns.formUnion(words("std cout cerr endl string vector map unordered_map set unique_ptr shared_ptr make_unique make_shared move"))
            g["cpp"] = c
            var objc = g["c"]!
            objc.keywords.formUnion(words("""
                self super nil Nil YES NO id instancetype SEL BOOL IBOutlet IBAction nonatomic atomic strong weak copy assign
                readonly readwrite nullable nonnull
                """))
            objc.builtIns.formUnion(words("NSLog NSString NSArray NSDictionary NSObject NSInteger NSUInteger CGFloat"))
            objc.atMeta = true
            objc.stringPrefixes.insert("@")
            g["objectivec"] = objc

            let javaKeywords = """
                abstract assert boolean break byte case catch char class const continue default do double else enum extends final
                finally float for goto if implements import instanceof int interface long native new package private protected
                public return short static strictfp super switch synchronized this throw throws transient try void volatile while
                var record sealed permits yield true false null
                """
            g["java"] = Grammar(lineComments: slashes, blockComment: cBlock, docBlocks: true, keywords: words(javaKeywords),
                                builtIns: words("String Object System Integer Long Double Boolean List Map Set ArrayList HashMap Math"),
                                capitalTypes: true, atMeta: true)
            g["kotlin"] = Grammar(
                lineComments: slashes, blockComment: cBlock, docBlocks: true, tripleQuotes: true,
                interpolation: (u("${"), brace, [q2]),
                keywords: words("""
                    abstract actual annotation as break by catch class companion const constructor continue crossinline data do else
                    enum expect external false final finally for fun get if import in infix init inline inner interface internal is
                    lateinit noinline null object open operator out override package private protected public reified return sealed
                    set super suspend tailrec this throw true try typealias val var vararg when where while
                    """),
                builtIns: words("println print listOf mapOf setOf mutableListOf mutableMapOf arrayOf lazy require check error repeat let apply also run with"),
                titleAfter: ["fun"], capitalTypes: true, atMeta: true)
            g["csharp"] = Grammar(
                lineComments: slashes, blockComment: cBlock, docLines: [u("///")], docBlocks: true,
                interpolation: (u("{"), brace, []),
                keywords: words("""
                    abstract as base bool break byte case catch char checked class const continue decimal default delegate do double
                    else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is
                    lock long namespace new null object operator out override params private protected public readonly ref return
                    sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked
                    unsafe ushort using virtual void volatile while async await var dynamic get set init record when where yield
                    nameof partial global
                    """),
                builtIns: words("Console Math String Task List Dictionary Exception"),
                capitalTypes: true, hashMeta: .lineStart, stringPrefixes: ["@", "$", "$@", "@$"], verbatimAt: true)

            g["ruby"] = Grammar(
                lineComments: [u("#")], multilineQuotes: [q2, q1], interpolation: (u("#{"), brace, [q2, tick]),
                keywords: words("""
                    alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo
                    rescue retry return self super then true undef unless until when while yield __FILE__ __LINE__
                    """),
                builtIns: words("puts print p require require_relative attr_accessor attr_reader attr_writer include extend raise lambda proc loop private protected public"),
                titleAfter: ["def"], capitalTypes: true, symbols: true)

            g["sql"] = Grammar(
                lineComments: [u("--")], blockComment: cBlock, quotes: [q1, q2], multilineQuotes: [q1],
                keywords: words("""
                    select from where and or not insert into values update set delete create table drop alter add column index view
                    primary key foreign references join inner left right outer full cross on as group by order having limit offset
                    union all distinct case when then else end is null like in between exists default unique check constraint begin
                    commit rollback transaction with recursive returning true false asc desc if replace trigger database schema cascade
                    integer int text varchar char boolean real float double date timestamp blob numeric serial bigint
                    """),
                builtIns: words("count sum avg min max coalesce nullif cast lower upper length substr substring trim now round abs"),
                caseInsensitive: true)

            // Not colored by word, but by their comments and strings.
            g["perl"] = Grammar(lineComments: [u("#")], quotes: [q2, q1, tick],
                                keywords: words("my our local sub if elsif else unless while until for foreach return use package last next and or not"),
                                titleAfter: ["sub"], hashNeedsSpace: true, dollarNames: true)
            g["makefile"] = Grammar(lineComments: [u("#")], hashNeedsSpace: true)
            g["r"] = Grammar(lineComments: [u("#")], keywords: words("if else repeat while function for in next break TRUE FALSE NULL Inf NaN NA"))
            g["graphql"] = Grammar(lineComments: [u("#")], tripleQuotes: true,
                                   keywords: words("query mutation subscription fragment on type input enum interface union scalar schema extend implements directive true false null"),
                                   capitalTypes: true, atMeta: true)
            g["lua"] = Grammar(lineComments: [u("--")], blockComment: (u("--[["), u("]]")),
                               keywords: words("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"),
                               builtIns: words("print pairs ipairs require type tostring tonumber table string math"),
                               titleAfter: ["function"])
            g["php"] = Grammar(lineComments: [u("//"), u("#")], blockComment: cBlock, docBlocks: true,
                               keywords: words("""
                                   abstract and array as break case catch class clone const continue declare default do echo else elseif empty
                                   enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global
                                   if implements include include_once instanceof interface isset list match namespace new or print private
                                   protected public readonly require require_once return static switch throw trait try unset use var while
                                   yield true false null
                                   """),
                               titleAfter: ["function"], capitalTypes: true, hashNeedsSpace: true, dollarNames: true)
            return g
        }()

        private static func words(_ list: String) -> Set<String> {
            Set(list.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
        }
    }
}

private func u(_ s: String) -> [UInt16] { Array(s.utf16) }

// The characters the scanner looks for, as UTF-16.
private let nl: UInt16 = 0x0A, cr: UInt16 = 0x0D, tab: UInt16 = 0x09, space: UInt16 = 0x20
private let q2: UInt16 = 0x22, q1: UInt16 = 0x27, tick: UInt16 = 0x60, backslash: UInt16 = 0x5C
private let slash: UInt16 = 0x2F, star: UInt16 = 0x2A, hashSign: UInt16 = 0x23, atSign: UInt16 = 0x40, dollar: UInt16 = 0x24
private let dot: UInt16 = 0x2E, colon: UInt16 = 0x3A, semicolon: UInt16 = 0x3B, comma: UInt16 = 0x2C, equals: UInt16 = 0x3D
private let paren: UInt16 = 0x29, openParen: UInt16 = 0x28, brace: UInt16 = 0x7D, openBrace: UInt16 = 0x7B
private let bracket: UInt16 = 0x5D, openBracket: UInt16 = 0x5B, lt: UInt16 = 0x3C, gt: UInt16 = 0x3E
private let bang: UInt16 = 0x21, question: UInt16 = 0x3F, plus: UInt16 = 0x2B, minus: UInt16 = 0x2D, underscore: UInt16 = 0x5F
private let pipe: UInt16 = 0x7C, tilde: UInt16 = 0x7E, percent: UInt16 = 0x25, amp: UInt16 = 0x26

private let diffHeaders = ["+++", "---", "diff ", "index ", "Index:", "==="].map(u)
private let yamlDocStart = u("---"), yamlDocEnd = u("..."), xmlCommentOpen = u("<!--"), xmlCommentClose = u("-->")

@inline(__always) private func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
@inline(__always) private func isUpper(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A }
@inline(__always) private func isLetter(_ c: UInt16) -> Bool { (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A }
@inline(__always) private func isSpace(_ c: UInt16) -> Bool { c == space || c == tab || c == cr }
/// Letters past ASCII count as name characters, so a name with an accent isn't split.
@inline(__always) private func isNameStart(_ c: UInt16) -> Bool { isLetter(c) || c == underscore || c >= 0x80 }
@inline(__always) private func isName(_ c: UInt16) -> Bool { isNameStart(c) || isDigit(c) }

// MARK: - Scanner

extension CodeSyntax {
    fileprivate struct Scanner {
        let s: [UInt16]
        let n: Int
        let g: Grammar
        var out: [(range: NSRange, kind: Kind)] = []
        var i = 0

        init(_ s: [UInt16], _ g: Grammar) {
            self.s = s
            n = s.count
            self.g = g
            out.reserveCapacity(n / 12)
        }

        /// The unit at j, or 0 off either end.
        @inline(__always) func at(_ j: Int) -> UInt16 { j >= 0 && j < n ? s[j] : 0 }

        @inline(__always) func has(_ p: [UInt16], _ j: Int) -> Bool {
            guard j + p.count <= n else { return false }
            for k in 0..<p.count where s[j + k] != p[k] { return false }
            return true
        }

        mutating func emit(_ start: Int, _ end: Int, _ kind: Kind) {
            guard end > start else { return }
            // One run of a kind, not many touching ones.
            if let last = out.last, last.kind == kind, last.range.location + last.range.length == start {
                out[out.count - 1].range.length += end - start
            } else {
                out.append((NSRange(location: start, length: end - start), kind))
            }
        }

        func lineEnd(_ j: Int) -> Int {
            var k = j
            while k < n && s[k] != nl { k += 1 }
            return k
        }

        func word(_ a: Int, _ b: Int) -> String { String(decoding: s[a..<b], as: UTF16.self) }

        // MARK: Code

        mutating func code() {
            var lineStart = true
            // The last character of code (not space or comment), and the word just before, for regexes, docstrings and names.
            var prev: UInt16 = 0
            var prevWord: String?
            while i < n {
                let c = s[i]
                if c == nl { lineStart = true; i += 1; continue }
                if isSpace(c) { i += 1; continue }
                let start = i
                let wasLineStart = lineStart
                lineStart = false

                if comment() { continue }

                // Strings.
                if g.tripleQuotes, (c == q2 || (c == q1 && g.quotes.contains(q1))), at(i + 1) == c, at(i + 2) == c {
                    let doc = g.docstrings && wasLineStart && (prev == 0 || prev == colon)
                    string(quote: c, triple: true, kind: doc ? .doc : .string)
                    prev = c; prevWord = nil; continue
                }
                if g.quotes.contains(c) {
                    if g.rust && c == q1 && !rustChar() {
                        // A lifetime: 'a.
                        i += 1
                        while i < n && isName(s[i]) { i += 1 }
                        prev = c; prevWord = nil; continue
                    }
                    string(quote: c, triple: false, kind: .string)
                    if g.keyStrings && nextIsColon() { retag(from: start, as: .title) }
                    prev = c; prevWord = nil; continue
                }
                if g.rawHashStrings && c == hashSign && (at(i + 1) == q2 || at(i + 1) == hashSign) && rawString(from: i) {
                    prev = q2; prevWord = nil; continue
                }
                if (c == atSign || c == dollar) && !g.dollarNames {
                    // C#'s @"…" and $"…", Objective-C's @"…".
                    var q = i
                    while q < n && q - i < 2 && (s[q] == atSign || s[q] == dollar) { q += 1 }
                    if at(q) == q2 && g.stringPrefixes.contains(word(i, q)) {
                        i = q
                        string(quote: q2, triple: false, kind: .string, from: start)
                        prev = q2; prevWord = nil; continue
                    }
                }

                // Numbers.
                if isDigit(c) || (c == dot && isDigit(at(i + 1)) && !isName(prev)) {
                    number()
                    emit(start, i, .number)
                    prev = s[i - 1]; prevWord = nil; continue
                }

                // Names and words.
                if isNameStart(c) || (g.dollarNames && c == dollar) {
                    i += 1
                    while i < n && (isName(s[i]) || (g.dollarNames && s[i] == dollar)) { i += 1 }
                    // Ruby's `defined?`, and its `empty?` and `save!` methods.
                    if g.symbols && (at(i) == question || at(i) == bang) && at(i + 1) != equals { i += 1 }
                    let text = word(start, i)
                    // A string's prefix: f"…", r'…', b"…", u8"…".
                    if g.quotes.contains(at(i)) && g.stringPrefixes.contains(text) {
                        if g.tripleQuotes, at(i + 1) == at(i), at(i + 2) == at(i) {
                            string(quote: at(i), triple: true, kind: .string, from: start)
                        } else {
                            string(quote: at(i), triple: false, kind: .string, from: start)
                        }
                        prev = q2; prevWord = nil; continue
                    }
                    if g.rust && (text == "r" || text == "br") && (at(i) == hashSign || at(i) == q2) && rawString(from: i, start: start) {
                        prev = q2; prevWord = nil; continue
                    }
                    classify(text, start: start, prev: prev, prevWord: prevWord)
                    prev = s[i - 1]; prevWord = text; continue
                }

                // Attributes and directives.
                if c == atSign && g.atMeta && isNameStart(at(i + 1)) {
                    i += 1
                    while i < n && (isName(s[i]) || (s[i] == dot && isNameStart(at(i + 1)))) { i += 1 }
                    emit(start, i, .meta)
                    prev = s[i - 1]; prevWord = nil; continue
                }
                if c == hashSign {
                    if g.rust && (at(i + 1) == openBracket || (at(i + 1) == bang && at(i + 2) == openBracket)) {
                        attribute()
                        prev = bracket; prevWord = nil; continue
                    }
                    let directive = g.hashMeta == .anywhere || (g.hashMeta == .lineStart && wasLineStart)
                    if directive {
                        i += 1
                        while i < n && isSpace(s[i]) && g.hashMeta == .lineStart { i += 1 }
                        while i < n && isName(s[i]) { i += 1 }
                        emit(start, i, .meta)
                        prev = s[i - 1]; prevWord = nil; continue
                    }
                }
                // `:name`, not `a::B` or `a ? b :c`'s neighbor.
                if g.symbols && c == colon && isNameStart(at(i + 1)) && at(i - 1) != colon && !isName(at(i - 1)) {
                    i += 1
                    while i < n && isName(s[i]) { i += 1 }
                    emit(start, i, .number)
                    prev = s[i - 1]; prevWord = nil; continue
                }
                if g.regex && c == slash && regexCanStart(prev: prev, prevWord: prevWord) && regex() {
                    prev = slash; prevWord = nil; continue
                }
                if g.rust && c == bang, let last = out.last, last.kind == .builtIn, last.range.location + last.range.length == i {
                    // The `!` of a macro.
                    emit(i, i + 1, .builtIn)
                }
                i += 1
                prev = c; prevWord = nil
            }
        }

        /// A comment at i: scans past it and says so.
        mutating func comment() -> Bool {
            let start = i
            if let block = g.blockComment, has(block.open, i) {
                let doc = g.docBlocks && at(i + 2) == star && at(i + 3) != slash && at(i + 3) != star
                i += block.open.count
                while i < n && !has(block.close, i) { i += 1 }
                i = min(n, i + block.close.count)
                emit(start, i, doc ? .doc : .comment)
                return true
            }
            for p in g.docLines where has(p, i) && at(i + p.count) != slash {
                i = lineEnd(i)
                emit(start, i, .doc)
                return true
            }
            for p in g.lineComments where has(p, i) {
                if g.hashNeedsSpace && p.first == hashSign {
                    if i > 0 && !isSpace(s[i - 1]) && s[i - 1] != nl { return false }
                    // A script's #! line.
                    if i == 0 && at(1) == bang { i = lineEnd(i); emit(start, i, .meta); return true }
                }
                i = lineEnd(i)
                emit(start, i, .comment)
                return true
            }
            return false
        }

        /// A string from i (its opening quote), or from `from` when a prefix comes first. Stops at the end of the text if
        /// it's never closed, and at the line's end if its quote can't span lines.
        mutating func string(quote: UInt16, triple: Bool, kind: Kind, from: Int? = nil) {
            var pieceStart = from ?? i
            // C# interpolates only in a $"…" string.
            let dollarPrefix = from.map { s[$0..<i].contains(dollar) } ?? false
            let interp = g.interpolation.flatMap { $0.quotes.contains(quote) || ($0.quotes.isEmpty && dollarPrefix) ? $0 : nil }
            i += triple ? 3 : 1
            let multiline = triple || g.multilineQuotes.contains(quote)
            // SQL doubles a quote rather than escaping it, and so does C#'s @"…".
            let escapes = !g.caseInsensitive && !(g.verbatimAt && from.map { s[$0..<i].contains(atSign) } == true)
            while i < n {
                let c = s[i]
                if let interp, has(interp.open, i) {
                    emit(pieceStart, i, kind)
                    i += interp.open.count
                    let opener: UInt16 = interp.close == paren ? openParen : openBrace
                    var depth = 1
                    while i < n {
                        if s[i] == opener { depth += 1 } else if s[i] == interp.close { depth -= 1; if depth == 0 { break } }
                        if s[i] == nl && !multiline { break }
                        i += 1
                    }
                    if i < n && s[i] == interp.close { i += 1 }
                    pieceStart = i
                    continue
                }
                if c == backslash && escapes { i += 2; continue }
                if c == quote {
                    if !triple { i += 1; break }
                    if at(i + 1) == quote && at(i + 2) == quote {
                        i += 3
                        // A docstring's closing quotes may be followed by more of them: """a"""".
                        while i < n && s[i] == quote { i += 1 }
                        break
                    }
                }
                if c == nl && !multiline { break }
                i += 1
            }
            emit(pieceStart, min(i, n), kind)
            i = min(i, n)
        }

        /// A raw string (`#"…"#` in Swift, `r#"…"#` in Rust) from j, its first `#` or quote; false if it isn't one.
        mutating func rawString(from j: Int, start: Int? = nil) -> Bool {
            var k = j, hashes = 0
            while k < n && s[k] == hashSign { hashes += 1; k += 1 }
            guard k < n && s[k] == q2 else { return false }
            let triple = at(k + 1) == q2 && at(k + 2) == q2
            k += triple ? 3 : 1
            outer: while k < n {
                if s[k] == q2 && (!triple || (at(k + 1) == q2 && at(k + 2) == q2)) {
                    var e = k + (triple ? 3 : 1), count = 0
                    while e < n && s[e] == hashSign && count < hashes { count += 1; e += 1 }
                    if count == hashes { k = e; break outer }
                }
                if s[k] == nl && !triple && !g.rust { break }
                k += 1
            }
            emit(start ?? j, min(k, n), .string)
            i = min(k, n)
            return true
        }

        /// Whether a `'` at i is a Rust char ('a', '\n', '\u{1F600}') rather than a lifetime.
        func rustChar() -> Bool {
            if at(i + 1) == backslash { return true }
            if at(i + 2) == q1 { return true }
            // A char past the Basic Multilingual Plane is two UTF-16 units.
            return at(i + 1) >= 0xD800 && at(i + 1) <= 0xDBFF && at(i + 3) == q1
        }

        /// Whether the next code after i is a `:` (a JSON key).
        func nextIsColon() -> Bool {
            var k = i
            while k < n && (isSpace(s[k]) || s[k] == nl) { k += 1 }
            return at(k) == colon
        }

        mutating func retag(from start: Int, as kind: Kind) {
            guard let last = out.last, last.range.location == start else { return }
            out[out.count - 1].kind = kind
        }

        /// A number from i: decimal, hex, binary, with `_` separators, a fraction, an exponent and a suffix (`10u`, `1.5f`,
        /// `12px`). Stops before `..` so a range's ends stay separate.
        mutating func number() {
            let hex = s[i] == 0x30 && (at(i + 1) | 0x20) == 0x78
            i += 1
            while i < n {
                let c = s[i]
                if isName(c) || (g.mode == .css && c == percent) { i += 1; continue }
                if c == dot && isDigit(at(i + 1)) { i += 1; continue }
                if !hex, c == plus || c == minus, (s[i - 1] | 0x20) == 0x65, isDigit(at(i + 1)) { i += 1; continue }
                break
            }
        }

        mutating func classify(_ text: String, start: Int, prev: UInt16, prevWord: String?) {
            let key = g.caseInsensitive ? text.lowercased() : text
            // A member (`x.default`, `.init`) isn't a keyword.
            let member = prev == dot && at(start - 1) == dot
            if g.keywords.contains(key) && !member {
                emit(start, i, .keyword)
            } else if let prevWord, g.titleAfter.contains(prevWord) {
                emit(start, i, .title)
            } else if g.rust && at(i) == bang && at(i + 1) != equals {
                emit(start, i, .builtIn)
            } else if g.builtIns.contains(key) && !member {
                emit(start, i, .builtIn)
            } else if g.capitalTypes && isUpper(s[start]) {
                emit(start, i, .type)
            }
        }

        /// A `#[…]` attribute, its brackets nested.
        mutating func attribute() {
            let start = i
            while i < n && s[i] != openBracket { i += 1 }
            var depth = 0
            while i < n {
                if s[i] == openBracket { depth += 1 } else if s[i] == bracket { depth -= 1; if depth == 0 { i += 1; break } }
                i += 1
            }
            emit(start, i, .meta)
        }

        func regexCanStart(prev: UInt16, prevWord: String?) -> Bool {
            if let prevWord { return ["return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw", "yield", "await"].contains(prevWord) }
            switch prev {
            case 0, openParen, comma, equals, colon, openBracket, bang, amp, pipe, question, openBrace, brace, semicolon, plus, minus, star,
                 percent, lt, gt, tilde, 0x5E: return true
            default: return false
            }
        }

        /// A /regex/flags on one line from i; false (and nothing scanned) if it doesn't close.
        mutating func regex() -> Bool {
            var k = i + 1, inClass = false
            while k < n && s[k] != nl {
                let c = s[k]
                if c == backslash { k += 2; continue }
                if c == openBracket { inClass = true } else if c == bracket { inClass = false } else if c == slash && !inClass { break }
                k += 1
            }
            guard k < n && s[k] == slash, k > i + 1 else { return false }
            k += 1
            while k < n && isLetter(s[k]) { k += 1 }
            emit(i, k, .regexp)
            i = k
            return true
        }

        // MARK: Line-shaped languages

        /// A scalar on one line from i up to `end`: a quoted string, a number, a literal, or plain; and a ` #` comment.
        mutating func value(upTo end: Int, literals: Set<String>, commentChars: Set<UInt16>) {
            while i < end {
                let c = s[i]
                if isSpace(c) { i += 1; continue }
                let start = i
                if commentChars.contains(c) && (i == 0 || isSpace(s[i - 1]) || s[i - 1] == nl) {
                    emit(start, end, .comment); i = end; return
                }
                if c == q2 || c == q1 {
                    i += 1
                    while i < end && s[i] != c { if s[i] == backslash && c == q2 { i += 1 }; i += 1 }
                    i = min(end, i + 1)
                    emit(start, i, .string)
                    continue
                }
                if c == openBracket || c == bracket || c == openBrace || c == brace || c == comma || c == equals || c == colon { i += 1; continue }
                // A bare word or number runs to the next separator.
                while i < end && !isSpace(s[i]) && s[i] != comma && s[i] != bracket && s[i] != brace { i += 1 }
                let text = word(start, i)
                if literals.contains(text.lowercased()) {
                    emit(start, i, .keyword)
                } else if isDigit(s[start]) || ((s[start] == minus || s[start] == plus || s[start] == dot) && isDigit(at(start + 1))) {
                    if text.allSatisfy({ $0.isNumber || "._-+:eExXoObBabcdefABCDEF".contains($0) }) { emit(start, i, .number) }
                }
            }
        }

        mutating func yaml() {
            let literals: Set<String> = ["true", "false", "null", "yes", "no", "on", "off", "~"]
            while i < n {
                let end = lineEnd(i)
                while i < end && isSpace(s[i]) { i += 1 }
                if i < end {
                    if s[i] == hashSign { emit(i, end, .comment); i = end }
                    else if (has(yamlDocStart, i) || has(yamlDocEnd, i)) && (i + 3 == end || isSpace(at(i + 3))) { emit(i, end, .meta); i = end }
                    else {
                        // List items' dashes, then perhaps a key.
                        while i < end && s[i] == minus && (i + 1 == end || isSpace(at(i + 1))) {
                            i += 1
                            while i < end && isSpace(s[i]) { i += 1 }
                        }
                        let keyStart = i
                        var k = i, quoted = false
                        if at(k) == q2 || at(k) == q1 {
                            let q = s[k]; k += 1; quoted = true
                            while k < end && s[k] != q { k += 1 }
                            k += 1
                        } else {
                            while k < end && s[k] != colon && s[k] != hashSign && s[k] != openBrace && s[k] != openBracket { k += 1 }
                        }
                        if k < end && s[k] == colon && (k + 1 >= end || isSpace(at(k + 1))) && (quoted || k > keyStart) {
                            emit(keyStart, k, .title)
                            i = k + 1
                        }
                        while i < end && isSpace(s[i]) { i += 1 }
                        if i < end && (s[i] == amp || s[i] == star || s[i] == bang) {
                            let start = i
                            while i < end && !isSpace(s[i]) { i += 1 }
                            emit(start, i, .type)
                        }
                        value(upTo: end, literals: literals, commentChars: [hashSign])
                    }
                }
                i = end + 1
            }
            i = n
        }

        mutating func ini() {
            let literals: Set<String> = ["true", "false", "yes", "no", "on", "off"]
            while i < n {
                let end = lineEnd(i)
                while i < end && isSpace(s[i]) { i += 1 }
                if i < end {
                    let c = s[i]
                    if c == hashSign || c == semicolon { emit(i, end, .comment) }
                    else if c == openBracket {
                        var k = i
                        while k < end && s[k] != bracket { k += 1 }
                        while k < end && s[k] == bracket { k += 1 }
                        emit(i, k, .type)
                        i = k
                        value(upTo: end, literals: [], commentChars: [hashSign, semicolon])
                    } else {
                        var k = i
                        while k < end && s[k] != equals && s[k] != colon { k += 1 }
                        if k < end {
                            var keyEnd = k
                            while keyEnd > i && isSpace(s[keyEnd - 1]) { keyEnd -= 1 }
                            emit(i, keyEnd, .title)
                            i = k + 1
                        }
                        value(upTo: end, literals: literals, commentChars: [hashSign, semicolon])
                    }
                }
                i = end + 1
            }
            i = n
        }

        mutating func css() {
            // Each open brace: whether it holds declarations (a rule) or more rules (@media).
            var blocks: [Bool] = []
            var preludeIsAt = false
            var statementStart = true
            var atPrelude = false
            while i < n {
                let c = s[i]
                if c == nl || isSpace(c) { i += 1; continue }
                let start = i
                if comment() { continue }
                // An at-rule's own words (`@media (width > 600px)`) read as values, not selectors.
                let declarations = (blocks.last ?? false) || atPrelude
                if c == q2 || c == q1 { string(quote: c, triple: false, kind: .string); statementStart = false; continue }
                if c == openBrace { blocks.append(!preludeIsAt); preludeIsAt = false; atPrelude = false; statementStart = true; i += 1; continue }
                if c == brace { _ = blocks.popLast(); statementStart = true; i += 1; continue }
                if c == semicolon { statementStart = true; preludeIsAt = false; atPrelude = false; i += 1; continue }
                if c == atSign {
                    i += 1
                    while i < n && (isName(s[i]) || s[i] == minus) { i += 1 }
                    let rule = word(start + 1, i)
                    preludeIsAt = ["media", "supports", "layer", "container", "document"].contains(rule)
                    emit(start, i, .keyword)
                    statementStart = false
                    atPrelude = true
                    continue
                }
                if declarations {
                    if statementStart && (isNameStart(c) || c == minus) {
                        while i < n && (isName(s[i]) || s[i] == minus) { i += 1 }
                        var k = i
                        while k < n && isSpace(s[k]) { k += 1 }
                        if at(k) == colon { emit(start, i, .meta) }
                        statementStart = false
                        continue
                    }
                    statementStart = false
                    if isDigit(c) || (c == dot && isDigit(at(i + 1))) || (c == minus && isDigit(at(i + 1))) {
                        number()
                        emit(start, i, .number)
                        continue
                    }
                    if c == hashSign && isName(at(i + 1)) {
                        i += 1
                        while i < n && isName(s[i]) { i += 1 }
                        emit(start, i, .number)
                        continue
                    }
                    if c == bang && isLetter(at(i + 1)) {
                        i += 1
                        while i < n && isLetter(s[i]) { i += 1 }
                        emit(start, i, .keyword)
                        continue
                    }
                    if isNameStart(c) || c == minus {
                        while i < n && (isName(s[i]) || s[i] == minus) { i += 1 }
                        if at(i) == openParen { emit(start, i, .builtIn) }
                        continue
                    }
                    i += 1
                    continue
                }
                // A selector.
                statementStart = false
                if c == dot || c == hashSign {
                    i += 1
                    while i < n && (isName(s[i]) || s[i] == minus) { i += 1 }
                    emit(start, i, .type)
                } else if c == colon {
                    while i < n && s[i] == colon { i += 1 }
                    while i < n && (isName(s[i]) || s[i] == minus) { i += 1 }
                    emit(start, i, .meta)
                } else if c == openBracket {
                    while i < n && s[i] != bracket && s[i] != nl { i += 1 }
                    if i < n && s[i] == bracket { i += 1 }
                    emit(start, i, .meta)
                } else if isNameStart(c) {
                    while i < n && (isName(s[i]) || s[i] == minus) { i += 1 }
                    emit(start, i, .keyword)
                } else {
                    i += 1
                }
            }
        }

        mutating func xml() {
            let open = xmlCommentOpen, close = xmlCommentClose
            while i < n {
                let c = s[i]
                let start = i
                if has(open, i) {
                    i += open.count
                    while i < n && !has(close, i) { i += 1 }
                    i = min(n, i + close.count)
                    emit(start, i, .comment)
                    continue
                }
                guard c == lt, isNameStart(at(i + 1)) || at(i + 1) == slash || at(i + 1) == question || at(i + 1) == bang else { i += 1; continue }
                if at(i + 1) == question || at(i + 1) == bang {
                    while i < n && s[i] != gt { i += 1 }
                    i = min(n, i + 1)
                    emit(start, i, .meta)
                    continue
                }
                i += 1
                if at(i) == slash { i += 1 }
                let name = i
                while i < n && (isName(s[i]) || s[i] == colon || s[i] == minus || s[i] == dot) { i += 1 }
                emit(name, i, .keyword)
                // Attributes, to the tag's end.
                while i < n && s[i] != gt {
                    let a = i
                    if isNameStart(s[i]) {
                        while i < n && (isName(s[i]) || s[i] == colon || s[i] == minus || s[i] == dot) { i += 1 }
                        emit(a, i, .title)
                    } else if s[i] == q2 || s[i] == q1 {
                        let q = s[i]
                        i += 1
                        while i < n && s[i] != q { i += 1 }
                        i = min(n, i + 1)
                        emit(a, i, .string)
                    } else {
                        i += 1
                    }
                }
                i = min(n, i + 1)
            }
        }

        mutating func markdown() {
            var fence: UInt16 = 0
            var fenceStart = 0
            while i < n {
                let end = lineEnd(i)
                var k = i
                while k < end && isSpace(s[k]) { k += 1 }
                let c = at(k)
                if fence != 0 {
                    // Inside a fenced block: all code, to its closing fence.
                    if c == fence && at(k + 1) == fence && at(k + 2) == fence { emit(fenceStart, end, .string); fence = 0 }
                } else if (c == tick || c == tilde) && at(k + 1) == c && at(k + 2) == c && k < end {
                    fence = c
                    fenceStart = k
                } else if c == hashSign && k < end {
                    var h = k
                    while h < end && s[h] == hashSign { h += 1 }
                    if h - k <= 6 && (h == end || isSpace(s[h])) { emit(k, end, .type) } else { inline(k, end) }
                } else if c == gt && k < end {
                    emit(k, end, .comment)
                } else {
                    if k < end && (c == minus || c == star || c == plus) && (k + 1 == end || isSpace(at(k + 1))) {
                        emit(k, k + 1, .keyword)
                        k += 1
                    } else if k < end && isDigit(c) {
                        var d = k
                        while d < end && isDigit(s[d]) { d += 1 }
                        if (at(d) == dot || at(d) == paren) && (d + 1 == end || isSpace(at(d + 1))) { emit(k, d + 1, .keyword); k = d + 1 }
                    }
                    inline(k, end)
                }
                i = end + 1
            }
            if fence != 0 { emit(fenceStart, n, .string) }
            i = n
        }

        /// A Markdown line's `code` spans and [links](url).
        mutating func inline(_ from: Int, _ end: Int) {
            var k = from
            while k < end {
                let c = s[k]
                if c == backslash { k += 2; continue }
                if c == tick {
                    var e = k + 1
                    while e < end && s[e] != tick { e += 1 }
                    if e < end { emit(k, e + 1, .string); k = e + 1; continue }
                }
                if c == openBracket {
                    var e = k + 1
                    while e < end && s[e] != bracket { e += 1 }
                    if e + 1 < end && s[e + 1] == openParen {
                        var p = e + 2
                        while p < end && s[p] != paren { p += 1 }
                        if p < end {
                            emit(k + 1, e, .string)
                            emit(e + 2, p, .regexp)
                            k = p + 1
                            continue
                        }
                    }
                }
                k += 1
            }
        }

        mutating func diff() {
            while i < n {
                let end = lineEnd(i)
                let c = at(i)
                if diffHeaders.contains(where: { has($0, i) }) {
                    emit(i, end, .comment)
                } else if has(u("@@"), i) {
                    emit(i, end, .meta)
                } else if c == plus || c == bang {
                    emit(i, end, .addition)
                } else if c == minus {
                    emit(i, end, .deletion)
                }
                i = end + 1
            }
            i = n
        }
    }
}
