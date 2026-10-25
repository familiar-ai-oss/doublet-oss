import CryptoKit
import DuetKit
import ImageIO
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WebKit
#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// What a diagram page shows: Claude's Mermaid source, Claude's HTML page, a task's diff, or a file on the hub machine.
enum DiagramDocument: Equatable {
    case mermaid(String)
    case html(String)
    case diff(String)
    /// A file's text, with the lines changed since the last commit, where lines were removed, the kept notes on it, and
    /// the diagrams that explain it.
    case code(path: String, text: String, changed: [Int], removedAfter: [Int], marks: [Int: LineMark] = [:], peeks: [DiagramPeek] = [])

    init(_ d: DiagramEvent) { self = d.kind == .html ? .html(d.source) : .mermaid(d.source) }
}

/// One web page that renders a diagram (with the bundled Mermaid) and reports where each element is, so a tap, a
/// Pencil hover or a handwritten note can be tagged to it. Shared by iPhone, iPad and Mac.
@MainActor
final class DiagramPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// Made on first use: a view's state may build (and drop) a page each time the view is recreated, and a web view
    /// is costly.
    private(set) lazy var web: WKWebView = makeWeb()
    var onLayout: ((CGSize, [InkAnchor]) -> Void)?
    /// An element tapped (nil: a tap on nothing in particular).
    var onTap: ((InkAnchor?) -> Void)?
    /// A note's marker tapped: the notes on that line.
    var onMark: (([String]) -> Void)?
    /// A diagram's card or mark on a code page tapped: the diagram, and the element picked (nil: the diagram as a whole).
    var onDiagram: ((String, String?) -> Void)?
    /// An element to pick once the diagram is drawn (opened from the code it stands for).
    private var pendingFocus: String?
    /// A line to show (and pick) once the page is laid out.
    private var pendingReveal: Int?

    /// The kept notes on a code page, by line.
    var marks: [Int: LineMark] {
        if case .code(_, _, _, _, let m, _) = document { m } else { [:] }
    }
    /// Where each diagram's card, element chip and margin mark is on a code page (page coordinates), for taps through
    /// the ink. Chips and marks come before the cards they sit in.
    private(set) var diagramCards: [(diagram: String, element: String?, rect: CGRect)] = []
    var onError: ((String) -> Void)?
    private(set) var anchors: [InkAnchor] = []
    /// Where each note's card is on a code page (page coordinates, like the anchors), for taps through the ink.
    private(set) var noteCards: [(ids: [String], rect: CGRect)] = []
    private(set) var contentSize: CGSize = .zero
    /// Scale a Mermaid diagram to fit the view's height as well as its width (thread previews).
    var fitsHeight = false
    private var document: DiagramDocument?
    private var dark = false
    private var ready = false
    #if os(iOS)
    /// Where you were on the page when it loaded again, to go back to once it's laid out.
    private var place: (offset: CGPoint, zoom: CGFloat)?
    #endif

    /// One store for every page (and the stills' page): in memory only, so nothing is kept past this run and nothing of
    /// the app's is reachable, but shared, so WebKit can give a new page a web process it already has running. With a
    /// store of its own per page, every file opened started new web processes first: most of the half second to a
    /// second a file stayed blank.
    static let store = WKWebsiteDataStore.nonPersistent()
    private static let folder = Bundle.main.url(forResource: "diagram", withExtension: "html")?.deletingLastPathComponent()
    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "diagram")
    private static let bridge: String = Bundle.main.url(forResource: "duet-bridge", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    /// A code page's colors: the bundled highlight.js and Duet's script that colors the rows with it.
    private static let colors: String = ["highlight.min", "code-colors"]
        .compactMap { Bundle.main.url(forResource: $0, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
        .joined(separator: "\n;\n")

    private func makeWeb() -> WKWebView {
        // The one made ahead, once its blank page is up (taking it mid-load would report that load as failed).
        let web: WKWebView
        if let spare = Self.spare, Self.spareLoaded {
            web = spare
            Self.spare = nil
        } else {
            web = Self.bareWeb()
        }
        web.configuration.userContentController.add(WeakHandler(self), name: "duet")
        web.navigationDelegate = self
        Self.prepareSpare()
        return web
    }

    private static func bareWeb() -> WKWebView {
        let config = WKWebViewConfiguration()
        // Nothing Claude's page runs can persist or read anything of the app's.
        config.websiteDataStore = store
        let web = WKWebView(frame: .zero, configuration: config)
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        #else
        web.setValue(false, forKey: "drawsBackground")
        // Pinch on the trackpad zooms, as in Safari.
        web.allowsMagnification = true
        #endif
        return web
    }

    // MARK: a web view made ahead

    /// A web view made and started ahead, its web process running and a blank page up: the next page takes it. A new
    /// web view's first page waited about 0.4 s for WebKit to set up (measured in the simulator, for any file, with or
    /// without its colors), and every file, diff and diagram opened paid it.
    private static var spare: WKWebView?
    private static var spareLoaded = false
    private static var preparing = false
    private static let warmer = SpareWarmer()

    /// Make the next page's web view ahead, after a moment: not in the frame that just opened a page.
    static func prepareSpare(after delay: Duration = .milliseconds(800)) {
        guard spare == nil, !preparing else { return }
        preparing = true
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            preparing = false
            guard spare == nil else { return }
            let web = bareWeb()
            spareLoaded = false
            web.navigationDelegate = warmer
            // In the pages' fonts (code, its italic comments, and the labels), so they're loaded ahead too.
            web.loadHTMLString(#"<!doctype html><meta charset="utf-8"><body style="font: 13px ui-monospace, Menlo, monospace">x <i>x</i> <b style="font: 600 13px -apple-system, sans-serif">x</b> <span style="font: 15px -apple-system, sans-serif">x</span></body>"#, baseURL: nil)
            spare = web
        }
    }

    /// Marks the spare ready once its blank page has loaded.
    private final class SpareWarmer: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { if webView === DiagramPage.spare { DiagramPage.spareLoaded = true } }
        }
    }

    func load(_ doc: DiagramDocument, dark: Bool) {
        guard doc != document || dark != self.dark else { return }
        let wasMermaid = if case .mermaid = document { true } else { false }
        let again = document != nil
        document = doc
        self.dark = dark
        anchors = []
        // Another version of a Mermaid diagram: the page (and its 5 MB of Mermaid) is already loaded; draw again.
        if case .mermaid = doc, wasMermaid {
            if ready { render() }
            return
        }
        #if os(iOS)
        // The same page loading again (its notes' cards changed, or the file did, or dark mode): a new page starts at the
        // top, so this is where to go back to.
        if again, ready, place == nil { place = (web.scrollView.contentOffset, web.scrollView.zoomScale) }
        #endif
        ready = false
        let controller = web.configuration.userContentController
        controller.removeAllUserScripts()
        #if os(iOS)
        // The page itself scrolls there as it loads, in its own pixels: WebKit shows a new page where the page says, so
        // scrolling the view from here would be undone as it first draws.
        if let place, place.offset != .zero {
            let z = max(place.zoom, 0.01)
            controller.addUserScript(WKUserScript(source: "window.scrollTo(\(place.offset.x / z), \(place.offset.y / z))", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        #endif
        switch doc {
        case .mermaid:
            guard let folder = Self.folder else { return }
            web.loadFileURL(folder.appending(path: "diagram.html"), allowingReadAccessTo: folder)
        case .html(let page):
            controller.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            web.loadHTMLString(page, baseURL: nil)
        case .diff(let text):
            controller.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            web.loadHTMLString(DiffHTML.page(text, dark: dark, margin: Self.writesInMargin), baseURL: nil)
        case .code(let path, let text, let changed, let removedAfter, let marks, let peeks):
            // Colored before the bridge says it's ready, so a short file's first paint is already colored.
            if CodeHTML.language(path: path, text: text) != nil {
                controller.addUserScript(WKUserScript(source: Self.colors, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
            controller.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            web.loadHTMLString(CodeHTML.page(path: path, text: text, changed: Set(changed), removedAfter: Set(removedAfter), marks: marks, peeks: peeks,
                                             dark: dark, margin: Self.writesInMargin), baseURL: nil)
        }
    }

    private func render() {
        switch document {
        case .mermaid(let source):
            web.callAsyncJavaScript("await duet.render(source, dark, fit)", arguments: ["source": source, "dark": dark, "fit": fitsHeight], in: nil, in: .page) { result in
                if case .failure(let e) = result { Self.log.error("render call failed: \(e.localizedDescription, privacy: .public)") }
            }
        case .html: web.callAsyncJavaScript("duet.index('html')", arguments: [:], in: nil, in: .page)
        // A file's lines are tagged the way a diff's are.
        case .diff, .code: web.callAsyncJavaScript("duet.index('diff')", arguments: [:], in: nil, in: .page)
        case nil: break
        }
    }

    /// Scroll to a line and pick it (opened from a diagram or a note); waits for the page if it isn't laid out yet.
    func reveal(line: Int) {
        guard ready, !anchors.isEmpty else { pendingReveal = line; return }
        scrollTo(line: line)
        highlight("L\(line)", "duet-sel")
        if let a = anchors.first(where: { $0.id == "L\(line)" }) { onTap?(a) }
    }

    /// Pick an element of the diagram (opened from the code it stands for): it's highlighted and picked, as a tap on it
    /// would. Waits for the diagram to be drawn.
    func focus(element id: String) {
        guard ready, let a = anchors.first(where: { $0.id == id }) else { pendingFocus = id; return }
        highlight(id, "duet-sel")
        onTap?(a)
    }

    /// Scroll a code or diff page to a line (the first change, the next one).
    func scrollTo(line: Int) {
        guard ready else { return }
        web.callAsyncJavaScript("document.getElementById('L' + n)?.scrollIntoView({ block: 'center', behavior: 'smooth' })", arguments: ["n": line], in: nil, in: .page)
    }

    /// iPad: room to the right of the code to write in.
    static var writesInMargin: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    func highlight(_ id: String?, _ cls: String) {
        guard ready else { return }
        web.callAsyncJavaScript("duet.highlight(id, cls)", arguments: ["id": id ?? NSNull(), "cls": cls], in: nil, in: .page)
    }

    /// The rendered page as an image (for a note's picture).
    func snapshot(_ rect: CGRect? = nil) async -> PlatformImage? {
        let config = WKSnapshotConfiguration()
        if let rect { config.rect = rect }
        return try? await web.takeSnapshot(configuration: config)
    }

    // MARK: messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "ready":
            Self.log.debug("page ready in \(Int(self.web.frame.width))×\(Int(self.web.frame.height)), in a window: \(self.web.window != nil)")
            ready = true
            render()
        case "layout":
            let raw = m["anchors"] as? [[String: Any]] ?? []
            anchors = raw.compactMap { a in
                guard let id = a["id"] as? String, let x = a["x"] as? Double, let y = a["y"] as? Double, let w = a["w"] as? Double, let h = a["h"] as? Double else { return nil }
                return InkAnchor(id: id, label: a["label"] as? String ?? id, rect: CGRect(x: x, y: y, width: w, height: h), file: a["file"] as? String, line: a["line"] as? Int)
            }
            noteCards = (m["notes"] as? [[String: Any]] ?? []).compactMap { n in
                guard let ids = n["ids"] as? String, let x = n["x"] as? Double, let y = n["y"] as? Double, let w = n["w"] as? Double, let h = n["h"] as? Double else { return nil }
                return (ids.split(separator: ",").map(String.init), CGRect(x: x, y: y, width: w, height: h))
            }
            diagramCards = (m["diagrams"] as? [[String: Any]] ?? []).compactMap { n in
                guard let id = n["id"] as? String, let x = n["x"] as? Double, let y = n["y"] as? Double, let w = n["w"] as? Double, let h = n["h"] as? Double else { return nil }
                let element = (n["el"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return (id, element, CGRect(x: x, y: y, width: w, height: h))
            }
            contentSize = CGSize(width: m["width"] as? Double ?? 0, height: m["height"] as? Double ?? 0)
            if let line = pendingReveal, !anchors.isEmpty {
                pendingReveal = nil
                reveal(line: line)
            }
            if let id = pendingFocus, anchors.contains(where: { $0.id == id }) {
                pendingFocus = nil
                focus(element: id)
            }
            Self.log.debug("laid out \(self.anchors.count) elements in \(Int(self.contentSize.width))×\(Int(self.contentSize.height))")
            onLayout?(contentSize, anchors)
        case "tap":
            let id = m["id"] as? String
            highlight(id, "duet-sel")
            onTap?(id.map { id in anchors.first { $0.id == id } ?? InkAnchor(id: id, label: m["label"] as? String ?? id, rect: .zero) })
        case "mark":
            if let ids = m["ids"] as? [String], !ids.isEmpty { onMark?(ids) }
        case "diagram":
            if let id = m["id"] as? String { onDiagram?(id, (m["el"] as? String).flatMap { $0.isEmpty ? nil : $0 }) }
        case "error":
            Self.log.error("render failed: \(m["message"] as? String ?? "", privacy: .public)")
            onError?(m["message"] as? String ?? "The diagram didn't render.")
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        // A load that gave way to the next one (the page loading again before the last had finished) isn't a failure.
        if (error as NSError).code == NSURLErrorCancelled { return }
        Self.log.error("page didn't load: \(error.localizedDescription, privacy: .public)")
        onError?("The diagram page didn't load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Self.log.error("page failed: \(error.localizedDescription, privacy: .public)")
    }

    #if os(iOS)
    /// The page loaded again: back to the zoom you were reading at (a new page starts at its own), and where you were in it.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let place else { return }
        self.place = nil
        let sv = webView.scrollView
        guard abs(sv.zoomScale - place.zoom) > 0.001 else { return }
        sv.setZoomScale(place.zoom, animated: false)
        sv.setContentOffset(CGPoint(x: min(place.offset.x, max(0, sv.contentSize.width - sv.bounds.width)),
                                    y: min(place.offset.y, max(0, sv.contentSize.height - sv.bounds.height))), animated: false)
    }
    #endif

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // WebKit's page process went away (memory pressure): load it again.
        Self.log.error("web content process ended; reloading")
        let doc = document
        document = nil
        if let doc { load(doc, dark: dark) }
    }

    // A diagram page never navigates anywhere: links in Claude's HTML are inert.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        switch action.request.url?.scheme {
        case "file", "about", "data", nil: return .allow
        default: return action.navigationType == .other && action.targetFrame?.isMainFrame == false ? .allow : .cancel
        }
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle with the page.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}

/// A unified diff as an annotatable page: one row per line (with its file and line number for tagging), and a wide
/// right margin to write in.
enum DiffHTML {
    struct Line { let kind: String; let old: Int?; let new: Int?; let text: String }
    struct File { let path: String; var lines: [Line] }

    static func parse(_ diff: String) -> [File] {
        var files: [File] = []
        var oldNo = 0, newNo = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                let path = line.components(separatedBy: " b/").last ?? line
                files.append(File(path: path, lines: []))
            } else if line.hasPrefix("+++ ") {
                let p = String(line.dropFirst(4))
                if p != "/dev/null", !files.isEmpty { files[files.count - 1] = File(path: p.hasPrefix("b/") ? String(p.dropFirst(2)) : p, lines: files[files.count - 1].lines) }
            } else if line.hasPrefix("--- ") || line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("similarity") || line.hasPrefix("rename ") {
                continue
            } else if line.hasPrefix("@@"), !files.isEmpty {
                // @@ -a,b +c,d @@
                let nums = line.split(separator: " ")
                oldNo = Int(nums.dropFirst().first?.dropFirst().split(separator: ",").first ?? "0") ?? 0
                newNo = Int(nums.dropFirst(2).first?.dropFirst().split(separator: ",").first ?? "0") ?? 0
                files[files.count - 1].lines.append(Line(kind: "hunk", old: nil, new: nil, text: line))
            } else if !files.isEmpty, let first = line.first {
                switch first {
                case "+": files[files.count - 1].lines.append(Line(kind: "add", old: nil, new: newNo, text: String(line.dropFirst()))); newNo += 1
                case "-": files[files.count - 1].lines.append(Line(kind: "del", old: oldNo, new: nil, text: String(line.dropFirst()))); oldNo += 1
                case " ": files[files.count - 1].lines.append(Line(kind: "ctx", old: oldNo, new: newNo, text: String(line.dropFirst()))); oldNo += 1; newNo += 1
                default: break
                }
            }
        }
        return files
    }

    static func page(_ diff: String, dark: Bool, margin: Bool) -> String {
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        var body = ""
        for (i, f) in parse(diff).enumerated() {
            body += "<div class=\"fh\">\(esc(f.path))</div>"
            for l in f.lines {
                if l.kind == "hunk" { body += "<div class=\"hunk\">\(esc(l.text))</div>"; continue }
                let no = l.new ?? l.old ?? 0
                let id = l.new != nil ? "f\(i)-n\(no)" : "f\(i)-o\(no)"
                let sign = l.kind == "add" ? "+" : l.kind == "del" ? "−" : " "
                body += "<div class=\"ln \(l.kind)\" id=\"\(id)\" data-file=\"\(esc(f.path))\" data-line=\"\(no)\" data-kind=\"\(l.kind)\" data-code=\"\(esc(String(l.text.prefix(160))))\"><span class=\"no\">\(no)</span><span class=\"sg\">\(sign)</span><span class=\"cd\">\(esc(l.text))</span></div>"
            }
        }
        if body.isEmpty { body = "<div class=\"empty\">No changes.</div>" }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=4">
        <style>
        :root { color-scheme: \(dark ? "dark" : "light"); }
        body { margin: 0; font: 13px ui-monospace, Menlo, monospace; background: transparent; -webkit-user-select: none; }
        .fh { position: sticky; top: 0; z-index: 1; padding: 8px 12px; font: 600 13px -apple-system, sans-serif; background: \(dark ? "#2c2c2e" : "#f2f2f7"); border-bottom: 1px solid #8884; }
        .hunk { height: 20px; line-height: 20px; padding: 0 12px; color: #8e8e93; background: \(dark ? "#1c1c1e" : "#fafafa"); }
        .ln { display: flex; min-height: 20px; line-height: 20px; \(margin ? "padding-right: 34%;" : "padding-right: 12px;") }
        .ln.add { background: \(dark ? "#12391e" : "#e6ffec"); }
        .ln.del { background: \(dark ? "#3d1418" : "#ffebe9"); }
        .no { width: 44px; flex: none; text-align: right; padding-right: 8px; color: #8e8e93; }
        .sg { width: 14px; flex: none; color: #8e8e93; }
        /* Long lines wrap (indent kept) rather than being cut off. */
        .cd { flex: 1; min-width: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
        .duet-hot { outline: 2px solid rgba(255,149,0,.9); outline-offset: -2px; }
        .duet-sel { outline: 2px solid rgba(10,132,255,.95); outline-offset: -2px; }
        .empty { padding: 24px; color: #8e8e93; font: 15px -apple-system, sans-serif; }
        \(margin ? "@media (max-width: 700px) { .ln { padding-right: 18%; } .nc, .dc { margin-right: 18%; } }" : "")
        </style></head><body>\(body)</body></html>
        """
    }
}

/// A file as a page: line numbers, the lines changed since the last commit marked in the gutter, long lines wrapped,
/// and one row per line (with its file and number) so a tap or a note can be tagged to it. Its code is colored as in an
/// editor (code-colors.js, with the bundled highlight.js), comments and docs set apart from code.
enum CodeHTML {
    /// Past this a file is shown plain: coloring 400 KB takes highlight.js ~100 ms on a Mac, more on an iPhone.
    static let colorLimit = 400_000

    /// The highlight.js language a file is colored as, by its extension, its name or its #! line; nil to show it plain
    /// (not code it knows, or too long).
    static func language(path: String, text: String) -> String? {
        guard text.utf8.count <= colorLimit else { return nil }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let ext = name.contains(".") ? name.split(separator: ".").last.map { $0.lowercased() } ?? "" : ""
        if let lang = byExtension[ext] { return lang }
        switch name.lowercased() {
        case "makefile", "gnumakefile": return "makefile"
        case ".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", ".envrc": return "bash"
        default: break
        }
        // A script with no extension: by its #! line.
        guard text.hasPrefix("#!"), let first = text.prefix(200).split(separator: "\n").first else { return nil }
        for (word, lang) in [("python", "python"), ("node", "javascript"), ("deno", "typescript"), ("bun", "typescript"), ("ruby", "ruby"),
                             ("perl", "perl"), ("bash", "bash"), ("zsh", "bash"), ("sh", "bash")] where first.contains(word) {
            return lang
        }
        return nil
    }

    private static let byExtension: [String: String] = [
        "swift": "swift",
        "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "py": "python", "pyi": "python",
        "rs": "rust", "go": "go",
        "sh": "bash", "bash": "bash", "zsh": "bash", "ksh": "bash", "fish": "bash",
        "json": "json", "jsonc": "json", "json5": "json", "jsonl": "json",
        "yml": "yaml", "yaml": "yaml",
        "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini", "properties": "ini",
        "md": "markdown", "markdown": "markdown", "mdx": "markdown",
        "c": "c", "h": "c",
        "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp", "ino": "cpp",
        "m": "objectivec", "mm": "objectivec",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "cs": "csharp",
        "rb": "ruby", "pl": "perl", "pm": "perl", "php": "php", "lua": "lua", "r": "r",
        "css": "css", "scss": "scss", "less": "less",
        "html": "xml", "htm": "xml", "xml": "xml", "plist": "xml", "svg": "xml", "xib": "xml", "storyboard": "xml",
        "sql": "sql", "graphql": "graphql", "gql": "graphql",
        "diff": "diff", "patch": "diff", "mk": "makefile",
    ]

    static func page(path: String, text: String, changed: Set<Int>, removedAfter: Set<Int>, marks: [Int: LineMark] = [:], peeks: [DiagramPeek] = [],
                     dark: Bool, margin: Bool) -> String {
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        let file = esc(path)
        let lang = language(path: path, text: text)
        // The diagrams that explain lines here: those lines get a stripe, each element's first line a mark, and the
        // first line of each diagram its card.
        let explained = peeks.reduce(into: Set<Int>()) { $0.formUnion($1.lines) }
        let elementAt = Dictionary(peeks.flatMap { p in p.elements.map { ($0.line, (p, $0)) } }, uniquingKeysWith: { a, _ in a })
        let cardsAt = Dictionary(grouping: peeks, by: \.line)
        var body = ""
        body.reserveCapacity(text.utf8.count * 2 + lines.count * 120)
        for (i, raw) in lines.enumerated() {
            let n = i + 1
            let line = String(raw).replacingOccurrences(of: "\t", with: "    ")
            let kind = changed.contains(n) ? "chg" : "ctx"
            let mark = (removedAfter.contains(n) ? " del-after" : "") + (explained.contains(n) ? " xp" : "")
            // A diagram element that stands for this line: its mark in the gutter, before the number.
            let element = elementAt[n].map { p, e in "<span class=\"dm\" data-diagram=\"\(esc(p.id))\" data-el=\"\(esc(e.id))\" title=\"\(esc(e.label)) in \(esc(p.title))\">◆</span>" } ?? ""
            // A kept note on this line: a bubble in the gutter (filled once Claude has answered).
            let note = marks[n].map { m in "<span class=\"mk \(m.state)\" data-ids=\"\(esc(m.ids.joined(separator: ",")))\">\(m.ids.count > 1 ? "\(m.ids.count)" : "")</span>" } ?? ""
            body += "<div class=\"ln \(kind)\(mark)\" id=\"L\(n)\" data-file=\"\(file)\" data-line=\"\(n)\" data-kind=\"\(kind)\" data-code=\"\(esc(String(line.prefix(160))))\"><span class=\"no\">\(note)\(element)\(n)</span><span class=\"cd\">\(esc(line))</span></div>"
            // The diagrams that start explaining here: a card naming each, with its elements that stand for this file.
            for p in cardsAt[n] ?? [] {
                let chips = p.elements.prefix(8).map { e in "<span class=\"dx\" data-diagram=\"\(esc(p.id))\" data-el=\"\(esc(e.id))\">\(esc(e.label)) <i>\(e.line)</i></span>" }.joined()
                body += "<div class=\"dc\" data-diagram=\"\(esc(p.id))\"><div class=\"dt\">Explained in <b>\(esc(p.title))</b><span class=\"go\">Open ›</span></div>\(chips.isEmpty ? "" : "<div class=\"dxs\">\(chips)</div>")</div>"
            }
            // Its notes' cards, right under it: the answer where the question was asked.
            for c in marks[n]?.cards ?? [] {
                let reply = c.answer.map { "<div class=\"na\">\(esc($0))</div><div class=\"nm\">\(c.chip.map { "<span class=\"who\">\(esc($0))</span> · " } ?? "")Open the thread ›</div>" }
                    ?? "<div class=\"na wait\">\(esc(c.waiting))</div>"
                body += "<div class=\"nc\(c.answer == nil ? " open" : "")\" data-ids=\"\(esc(c.id))\"><div class=\"nq\">\(esc(c.question))</div>\(reply)</div>"
            }
        }
        if lines.isEmpty { body = "<div class=\"empty\">Empty file.</div>" }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=4">
        <style>
        :root { color-scheme: \(dark ? "dark" : "light"); }
        body { margin: 0; padding: 6px 0 40px; font: 13px ui-monospace, Menlo, monospace; background: transparent; -webkit-user-select: none; }
        .ln { display: flex; min-height: 20px; line-height: 20px; border-left: 3px solid transparent; \(margin ? "padding-right: 34%;" : "padding-right: 12px;") }
        .ln.chg { background: \(dark ? "#12391e" : "#e6ffec"); border-left-color: #2da44e; }
        .ln.del-after { box-shadow: inset 0 -2px 0 #cf222e; }
        .no { width: 58px; flex: none; text-align: right; padding-right: 10px; color: #8e8e93; position: relative; }
        .cd { flex: 1; min-width: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
        .mk { position: absolute; left: 3px; top: 2px; min-width: 16px; height: 16px; border-radius: 8px 8px 8px 2px; font: 600 10px -apple-system, sans-serif; line-height: 16px; text-align: center; color: #fff; padding: 0 2px; box-sizing: border-box; }
        .mk.open { background: transparent; border: 1.5px solid #0a84ff; color: #0a84ff; line-height: 13px; }
        .mk.answered { background: #0a84ff; }
        .mk.resolved { background: #8e8e93; }
        .nc { margin: 4px 12px 8px 61px; padding: 8px 10px; border-radius: 10px; border-left: 3px solid #0a84ff; background: \(dark ? "rgba(10,132,255,.14)" : "rgba(10,132,255,.07)"); font: 13px/1.4 -apple-system, sans-serif; white-space: normal; cursor: pointer; \(margin ? "margin-right: 34%;" : "") }
        .nc.open { border-left-color: #8e8e93; background: \(dark ? "rgba(142,142,147,.14)" : "rgba(142,142,147,.08)"); }
        .nq { color: #8e8e93; font-size: 12px; margin-bottom: 3px; }
        .nq::before { content: "✎ "; }
        .na { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
        .na.wait { color: #8e8e93; font-style: italic; }
        .nm { margin-top: 4px; color: #0a84ff; font-size: 12px; font-weight: 600; }
        .nm .who { color: #8e8e93; font-weight: 500; }
        .ln.xp .no { box-shadow: inset -2px 0 0 rgba(139,92,246,.75); }
        .dm { display: inline-block; margin-right: 4px; color: #8b5cf6; font: 10px -apple-system, sans-serif; cursor: pointer; }
        .dc { margin: 4px 12px 8px 61px; padding: 7px 10px; border-radius: 10px; border-left: 3px solid #8b5cf6; background: \(dark ? "rgba(139,92,246,.16)" : "rgba(139,92,246,.07)"); font: 13px/1.4 -apple-system, sans-serif; white-space: normal; cursor: pointer; \(margin ? "margin-right: 34%;" : "") }
        .dt { display: flex; gap: 6px; align-items: baseline; color: \(dark ? "#c4b5fd" : "#6d28d9"); }
        .dt::before { content: "◆"; font-size: 10px; }
        .dt b { font-weight: 600; }
        .dt .go { margin-left: auto; font-size: 12px; font-weight: 600; }
        .dxs { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 6px; }
        .dx { padding: 1px 8px; border-radius: 9px; border: 1px solid rgba(139,92,246,.5); color: \(dark ? "#ddd6fe" : "#5b21b6"); font-size: 12px; }
        .dx i { font-style: normal; color: #8e8e93; font-size: 11px; }
        .duet-hot { outline: 2px solid rgba(255,149,0,.9); outline-offset: -2px; }
        .duet-sel { outline: 2px solid rgba(10,132,255,.95); outline-offset: -2px; }
        .empty { padding: 24px; color: #8e8e93; font: 15px -apple-system, sans-serif; }
        \(margin ? "@media (max-width: 700px) { .ln { padding-right: 18%; } .nc, .dc { margin-right: 18%; } }" : "")
        .cd .hljs-keyword, .cd .hljs-literal, .cd .hljs-selector-tag, .cd .hljs-tag, .cd .hljs-name, .cd .hljs-bullet { color: \(dark ? "#ff7ab2" : "#9b2393"); }
        .cd .hljs-string, .cd .hljs-char, .cd .hljs-code, .cd .hljs-template-tag { color: \(dark ? "#fc6a5d" : "#c41a16"); }
        .cd .hljs-regexp, .cd .hljs-link { color: \(dark ? "#ff8170" : "#a3351b"); }
        .cd .hljs-subst { color: \(dark ? "#e5e5e7" : "#1d1d1f"); }
        .cd .hljs-number, .cd .hljs-symbol { color: \(dark ? "#d9c97c" : "#1c00cf"); }
        .cd .hljs-title.class_, .cd .hljs-type, .cd .hljs-section, .cd .hljs-selector-class, .cd .hljs-selector-id { color: \(dark ? "#5dd8ff" : "#0b4f79"); }
        .cd .hljs-title, .cd .hljs-attr, .cd .hljs-property { color: \(dark ? "#67b7a4" : "#0f68a0"); }
        .cd .hljs-built_in, .cd .hljs-title.class_.inherited__ { color: \(dark ? "#d0a8ff" : "#6c36a9"); }
        .cd .hljs-meta, .cd .hljs-attribute, .cd .hljs-selector-attr, .cd .hljs-selector-pseudo { color: \(dark ? "#fd8f3f" : "#815f03"); }
        .cd .hljs-meta .hljs-string { color: \(dark ? "#fc6a5d" : "#c41a16"); }
        .cd .hljs-comment, .cd .hljs-quote { color: \(dark ? "#8e959e" : "#6e7781"); font-style: italic; }
        .cd .hljs-doc { color: \(dark ? "#7cc893" : "#2e7a46"); font-style: italic; }
        .cd .hljs-doctag { color: \(dark ? "#a6e3b8" : "#1a5c32"); }
        .cd .hljs-emphasis { font-style: italic; }
        .cd .hljs-addition { color: \(dark ? "#7ee787" : "#116329"); }
        .cd .hljs-deletion { color: \(dark ? "#ff7b72" : "#a40e26"); }
        </style></head><body\(lang.map { " data-lang=\"\($0)\" data-size=\"\(text.utf8.count)\"" } ?? "")>\(body)</body></html>
        """
    }
}

/// The kept notes on one line of a file: their ids, and whether they're waiting, answered or resolved; and the cards
/// shown under the line for the ones not yet resolved.
struct LineMark: Equatable {
    let ids: [String]
    let state: String
    var cards: [NoteCard] = []
    /// Every note on the line, resolved ones too, oldest first: the native page's history of what was asked here.
    var history: [NoteCard] = []
    /// One of them is being answered now: its bubble or pill pulses gently.
    var answering = false
}

/// A note under the line it was written on, as in a code review: what you asked, and the start of Claude's answer
/// (or that Claude is on it). A tap opens the whole note.
struct NoteCard: Equatable {
    let id: String
    let question: String
    /// The start of the answer; nil while it's being answered.
    let answer: String?
    /// Who answered, and how ("qwen-27b · 2 citations checked · 14 s").
    var chip: String? = nil
    /// While it's being answered: by whom.
    var waiting: String = "Claude is answering…"
    var resolved = false
    /// What it's about in at most three words, for its pill on the native page.
    var gist: String? = nil
}

/// A diagram that explains lines of a file, as the file shows it: a stripe beside the lines it explains, a mark on the
/// first line of each element that stands for code here, and a card under the first line naming the diagram and those
/// elements. A tap opens the diagram (with the element picked).
struct DiagramPeek: Equatable {
    struct Element: Equatable {
        let id: String
        let label: String
        let line: Int
    }

    let id: String
    let title: String
    /// The lines it explains here (by `explains`, or as what an element stands for).
    let lines: Set<Int>
    /// Its elements that stand for code here, by first line.
    let elements: [Element]
    /// Where its card goes: the first line it explains.
    var line: Int { lines.min() ?? 1 }

    /// The diagrams that explain a file, from their latest versions: by `explains` (a whole file when it gives no lines)
    /// and `links` (each element to "path:line" or "path:start-end"). A path may be given relative to the project.
    static func all(for path: String, lineCount: Int, in diagrams: some Sequence<DiagramEvent>) -> [DiagramPeek] {
        func here(_ p: String) -> Bool { p == path || (!p.hasPrefix("/") && path.hasSuffix("/" + p)) }
        func clamp(_ a: Int, _ b: Int) -> ClosedRange<Int>? {
            let lo = max(1, a), hi = min(max(a, b), max(lineCount, 1))
            return lo <= hi ? lo...hi : nil
        }
        var out: [DiagramPeek] = []
        for d in diagrams {
            var lines = Set<Int>()
            for r in d.explains ?? [] where here(r.path) {
                if let range = clamp(r.start ?? 1, r.end ?? (r.start == nil ? lineCount : r.start!)) { lines.formUnion(range) }
            }
            var elements: [Element] = []
            for (id, link) in d.links ?? [:] {
                guard let r = CodeRef(link: link), here(r.path), let start = r.start, let range = clamp(start, r.end ?? start) else { continue }
                lines.formUnion(range)
                elements.append(Element(id: id, label: label(of: id, in: d.source), line: range.lowerBound))
            }
            guard !lines.isEmpty else { continue }
            out.append(DiagramPeek(id: d.id, title: d.title, lines: lines, elements: elements.sorted { ($0.line, $0.id) < ($1.line, $1.id) }))
        }
        return out.sorted { ($0.line, $0.id) < ($1.line, $1.id) }
    }

    /// An element's label in Mermaid source (`A[Read the file]`, `A("…")`, `state "…" as A`), else its id.
    static func label(of id: String, in source: String) -> String {
        let name = NSRegularExpression.escapedPattern(for: id)
        let patterns = [#"(?m)(?:^|[\s;&>-])"# + name + #"\s*(?:\[\[|\[\(|\(\(|\[|\(|\{\{|\{|>)\s*"?([^\]\)\}"\n]+)"#,
                        #"state\s+"([^"]+)"\s+as\s+"# + name + #"\b"#]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), let r = Range(m.range(at: 1), in: source) {
                let label = source[r].trimmingCharacters(in: .whitespaces)
                if !label.isEmpty { return label }
            }
        }
        return id
    }
}

// MARK: stills for the thread's cards

/// What a diagram card in the thread shows: a still of the diagram, not a live page. A live page is a web view that takes
/// the main thread close to 100 ms to make and load, and a web process of its own, for every card on screen; a
/// conversation that opened on diagrams made them all in the frame it appeared (DUET_SPEED_OFF=stills goes back to that,
/// docs/diagnostics.md). The full diagram screen keeps its live page.
///
/// Each still is drawn once, off screen, by one page that draws them in turn once the app has settled, newest asked
/// first (the cards on screen now), and kept in Caches by what it shows: the source, light or dark, and the card's
/// height. A later launch, or the same diagram from another hub, reads it from there with no web view at all.
@MainActor
final class DiagramStills {
    static let shared = DiagramStills()

    enum Still {
        case image(PlatformImage)
        /// It couldn't be drawn: Mermaid's message, as the live card showed it.
        case failed(String)
    }

    /// What a still shows. Its file is named by a digest of that.
    struct Key: Hashable, Sendable {
        let name: String

        init(_ d: DiagramEvent, dark: Bool, height: CGFloat) {
            let what = "1|\(d.kind.rawValue)|\(dark ? "dark" : "light")|\(Int(height))|\(d.source)"
            name = SHA256.hash(data: Data(what.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private struct Job {
        let kind: DiagramKind
        let source: String
        let dark: Bool
        let height: CGFloat
        var waiters: [(id: UUID, done: CheckedContinuation<Still?, Never>)] = []
    }

    private let memory = NSCache<NSString, PlatformImage>()
    /// Mermaid's errors, so a broken diagram isn't drawn again each time its card shows.
    private var failures: [Key: String] = [:]
    private var jobs: [Key: Job] = [:]
    /// Asked for, oldest first. The newest is drawn next.
    private var order: [Key] = []
    private var drawing = false
    private var page: StillPage?
    private var closing: Task<Void, Never>?
    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "stills")
    nonisolated private static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appending(path: "DiagramStills", directoryHint: .isDirectory)

    private init() {
        memory.totalCostLimit = 48 << 20
        Task.detached(priority: .background) { Self.prune() }
    }

    /// A still already in memory: a card shows it in its first frame, with no spinner first.
    func cached(_ key: Key) -> PlatformImage? { memory.object(forKey: key.name as NSString) }

    /// A diagram's still: from memory, from disk, or drawn once its turn comes. Nil if the card went away first.
    func still(of d: DiagramEvent, key: Key, dark: Bool, height: CGFloat) async -> Still? {
        if let image = cached(key) { return .image(image) }
        if let why = failures[key] { return .failed(why) }
        if let image = await Self.read(key) {
            keep(image, key)
            return .image(image)
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Still?, Never>) in
                guard !Task.isCancelled else { return done.resume(returning: nil) }
                jobs[key, default: Job(kind: d.kind, source: d.source, dark: dark, height: height)].waiters.append((id, done))
                order.removeAll { $0 == key }
                order.append(key)
                pump()
            }
        } onCancel: {
            Task { @MainActor in self.drop(id) }
        }
    }

    /// A card went away before its still was drawn: it stops waiting, and one nobody waits for isn't drawn.
    private func drop(_ id: UUID) {
        guard let key = jobs.first(where: { $0.value.waiters.contains { $0.id == id } })?.key, var job = jobs[key],
              let i = job.waiters.firstIndex(where: { $0.id == id }) else { return }
        job.waiters.remove(at: i).done.resume(returning: nil)
        jobs[key] = job.waiters.isEmpty ? nil : job
    }

    private func pump() {
        guard !drawing else { return }
        order.removeAll { jobs[$0] == nil }
        guard !order.isEmpty else { return closeSoon() }
        drawing = true
        closing?.cancel()
        Task {
            // Making the page takes the main thread a moment: not while the app is opening, or a screenful of cards is
            // still arriving.
            if page == nil { try? await Task.sleep(for: .seconds(1.5)) }
            await drawNext()
            drawing = false
            pump()
        }
    }

    private func drawNext() async {
        order.removeAll { jobs[$0] == nil }
        guard let key = order.last, let job = jobs[key] else { return }
        let page = self.page ?? StillPage()
        self.page = page
        let started = Date()
        let still: Still
        switch await answer(job, key: key, from: page) {
        case .some(.success(.image(let image))):
            still = .image(image)
            keep(image, key)
            Self.write(image, key)
        case .some(.success(.failed(let why))):
            still = .failed(why)
            failures[key] = why
        case .some(.failure(let error)):
            Self.log.error("still failed: \(error.localizedDescription, privacy: .public)")
            still = .failed("The diagram didn't draw.")
        case nil:
            // The page stopped answering: a new one for the next.
            Self.log.error("still timed out")
            self.page = nil
            still = .failed("The diagram didn't draw.")
        }
        Self.log.debug("still drawn in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        order.removeAll { $0 == key }
        for w in jobs.removeValue(forKey: key)?.waiters ?? [] { w.done.resume(returning: still) }
        // A breath between drawings, for whatever else the main thread has to do.
        try? await Task.sleep(for: .milliseconds(30))
    }

    /// The page's drawing, or nil if it didn't come within 20 s.
    private func answer(_ job: Job, key: Key, from page: StillPage) async -> Result<Still, any Error>? {
        await withCheckedContinuation { (done: CheckedContinuation<Result<Still, any Error>?, Never>) in
            let once = Once(done)
            let timer = Task {
                try? await Task.sleep(for: .seconds(20))
                once.resume(nil)
            }
            Task {
                let r: Result<Still, any Error>
                do { r = .success(try await page.draw(job.kind, job.source, dark: job.dark, height: job.height)) } catch { r = .failure(error) }
                timer.cancel()
                once.resume(r)
            }
        }
    }

    /// Nothing left to draw: the page, and its web process, go once nothing more has come for a while.
    private func closeSoon() {
        guard page != nil else { return }
        closing?.cancel()
        closing = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, !drawing else { return }
            page = nil
        }
    }

    private func keep(_ image: PlatformImage, _ key: Key) {
        let bytes = Self.pixels(image).map { $0.bytesPerRow * $0.height } ?? 0
        memory.setObject(image, forKey: key.name as NSString, cost: bytes)
    }

    private static func pixels(_ image: PlatformImage) -> CGImage? {
        #if os(iOS)
        image.cgImage
        #else
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    /// A drawing at its size in points: the page draws at the screen's scale, whichever that is.
    static func image(_ pixels: CGImage, scale: CGFloat) -> PlatformImage {
        #if os(iOS)
        UIImage(cgImage: pixels, scale: scale, orientation: .up)
        #else
        NSImage(cgImage: pixels, size: CGSize(width: CGFloat(pixels.width) / scale, height: CGFloat(pixels.height) / scale))
        #endif
    }

    // MARK: on disk

    nonisolated private static func file(_ key: Key) -> URL? { folder?.appending(path: key.name + ".png") }

    /// Read and decoded off the main thread, ready to draw. Its scale is kept in the file (as its DPI).
    private static func read(_ key: Key) async -> PlatformImage? {
        guard let url = file(key) else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) { () -> (CGImage, CGFloat)? in
            // Read first: ImageIO logs an error for a file that isn't there, and most asks are for one not drawn yet.
            guard let data = try? Data(contentsOf: url), let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            let dpi = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyDPIWidth] as? Double ?? 144
            // Shown again: kept a while longer (prune).
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return (image, max(1, (dpi / 72 * 4).rounded() / 4))
        }.value
        guard let (pixels, scale) = decoded else { return nil }
        return image(pixels, scale: scale)
    }

    private static func write(_ image: PlatformImage, _ key: Key) {
        guard let cg = pixels(image), let folder, let url = file(key) else { return }
        let dpi = 72 * CGFloat(cg.width) / max(image.size.width, 1)
        Task.detached(priority: .utility) {
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, cg, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? (data as Data).write(to: url, options: .atomic)
        }
    }

    /// Stills not shown for a month go.
    nonisolated private static func prune() {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let old = Date().addingTimeInterval(-30 * 86_400)
        for f in files where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) < old {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// A continuation resumed by whichever comes first.
    private final class Once {
        private var done: CheckedContinuation<Result<Still, any Error>?, Never>?
        init(_ done: CheckedContinuation<Result<Still, any Error>?, Never>) { self.done = done }
        func resume(_ value: Result<Still, any Error>?) {
            done?.resume(returning: value)
            done = nil
        }
    }
}

/// The page that draws stills, off screen: Duet's Mermaid page (its 5 MB loaded once, then each diagram drawn into it),
/// or one of Claude's HTML pages.
@MainActor
private final class StillPage: NSObject, WKNavigationDelegate {
    /// Wide enough for any card: a Mermaid diagram is fitted to this and the card's height, as the live card fitted it to
    /// its own width, and the card shows it scaled to fit. Claude's pages are drawn at a card's usual width.
    private static let width: CGFloat = 1200
    private static let htmlWidth: CGFloat = 720
    private let web: WKWebView
    private var holds: DiagramKind?
    private var loading: CheckedContinuation<Void, any Error>?

    override init() {
        let config = WKWebViewConfiguration()
        // As on the live page: nothing Claude's page runs can persist or read anything of the app's.
        config.websiteDataStore = DiagramPage.store
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 320), configuration: config)
        super.init()
        web.navigationDelegate = self
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        web.setValue(false, forKey: "drawsBackground")
        #endif
    }

    func draw(_ kind: DiagramKind, _ source: String, dark: Bool, height: CGFloat) async throws -> DiagramStills.Still {
        let rect: CGRect
        switch kind {
        case .mermaid:
            web.frame = CGRect(x: 0, y: 0, width: Self.width, height: height)
            if holds != .mermaid {
                guard let page = Bundle.main.url(forResource: "diagram", withExtension: "html") else { return .failed("The diagram page is missing.") }
                try await load { web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
                holds = .mermaid
            }
            let r = try await web.callAsyncJavaScript(Self.drawMermaid, arguments: ["source": source, "dark": dark], contentWorld: .page) as? [String: Any]
            if let message = r?["error"] as? String { return .failed(message) }
            guard let x = r?["x"] as? Double, let y = r?["y"] as? Double, let w = r?["w"] as? Double, let h = r?["h"] as? Double, w >= 1, h >= 1 else {
                return .failed("The diagram didn't draw.")
            }
            rect = CGRect(x: x, y: y, width: w, height: h).integral
        case .html:
            web.frame = CGRect(x: 0, y: 0, width: Self.htmlWidth, height: height)
            holds = .html
            try await load { web.loadHTMLString(source, baseURL: nil) }
            // Its own scripts and fonts, after the load.
            try await Task.sleep(for: .milliseconds(300))
            rect = web.bounds
        }
        let config = WKSnapshotConfiguration()
        config.rect = rect
        config.afterScreenUpdates = true
        let snapshot = try await web.takeSnapshot(configuration: config)
        #if os(iOS)
        let pixels = snapshot.cgImage
        #else
        let pixels = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
        guard let pixels else { return .failed("The diagram didn't draw.") }
        // In points, the drawing's own size.
        let scale = max(1, (CGFloat(pixels.width) / rect.width * 4).rounded() / 4)
        Self.log.debug("still \(Int(rect.width))×\(Int(rect.height)) pt at \(scale)x")
        return .image(DiagramStills.image(pixels, scale: scale))
    }

    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "stills")

    /// Draw, then say where the drawing is: fitted to the height, an SVG keeps its shape inside a box that may be wider,
    /// and the still is the drawing alone.
    private static let drawMermaid = """
        await duet.render(source, dark, true);
        const err = document.getElementById('err').textContent;
        if (err) return { error: err };
        const svg = document.querySelector('#d svg');
        if (!svg) return { error: "The diagram didn't draw." };
        const r = svg.getBoundingClientRect();
        const vb = svg.viewBox && svg.viewBox.baseVal;
        let w = r.width, h = r.height;
        if (vb && vb.width > 0 && vb.height > 0) {
            const s = Math.min(r.width / vb.width, r.height / vb.height);
            w = vb.width * s;
            h = vb.height * s;
        }
        return { x: r.left + (r.width - w) / 2, y: r.top + (r.height - h) / 2, w, h };
        """

    private func load(_ start: () -> Void) async throws {
        loading?.resume(throwing: CancellationError())
        loading = nil
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            loading = c
            start()
        }
    }

    private func loaded(_ error: (any Error)?) {
        guard let c = loading else { return }
        loading = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { loaded(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { loaded(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        holds = nil
        loaded(URLError(.cancelled))
    }

    // As on the live page: a diagram page never navigates anywhere.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        switch action.request.url?.scheme {
        case "file", "about", "data", nil: .allow
        default: action.navigationType == .other && action.targetFrame?.isMainFrame == false ? .allow : .cancel
        }
    }
}
