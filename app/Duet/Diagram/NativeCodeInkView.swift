#if os(iOS)
import DuetKit
import PencilKit
import SwiftUI
import UIKit

/// SwiftUI's handle on a native code page: the palette, the file's note pages, and its notes for sending.
@MainActor @Observable
final class NativeInkController {
    struct PageName: Identifiable, Equatable { let id: UUID; let name: String }

    @ObservationIgnored weak var view: NativeCodeInkView? {
        didSet { view?.controller = self; view?.publishPages() }
    }
    /// The file's note pages, for the toolbar's menu, and the one shown.
    private(set) var pages: [PageName] = []
    private(set) var current: UUID?

    var currentName: String { pages.first { $0.id == current }?.name ?? "Note 1" }

    func toggleTools() { view?.toggleTools() }
    func show(page id: UUID) { view?.show(page: id) }
    func addPage() { view?.addPage() }
    func rename(_ id: UUID, to name: String) { view?.rename(id, to: name) }
    func remove(_ id: UUID) { view?.remove(id) }
    /// Wrap the file again for the width it's shown at now.
    func reflow() { view?.reflow() }

    /// Show this line (from a note or a diagram), picked.
    func reveal(line: Int) { view?.reveal(line: line) }
    /// Scroll to this line, as Next Change does.
    func scrollTo(line: Int) { view?.scrollTo(line: line) }

    func finishNote() async { await view?.notes.finishGroup() }
    func snapshot() async -> UIImage? { view?.snapshot() }

    /// The notes to send, each with a picture of its handwriting. Readings on their way get a moment (at most 0.8 s).
    func items(_ drafts: [DraftNote]) async -> [InkNote] {
        await view?.notes.settleReadings(Set(drafts.map(\.id)), within: .milliseconds(800))
        return drafts.map { d in
            let latest = view?.notes.drafts.first { $0.id == d.id } ?? d
            var n = latest.note
            n.ink = view?.notes.inkPNG(latest)
            return n
        }
    }

    func update(_ book: CodeNoteBook) {
        let names = book.pages.map { PageName(id: $0.id, name: $0.name) }
        if names != pages { pages = names }
        if current != book.current { current = book.current }
    }
}

/// A code file as a native page to write on (the `nativeCodePage` setting): the canvas is the page, as in Notes.
struct NativeCodeInkRepresentable: UIViewRepresentable {
    let path: String
    let text: String
    let controller: NativeInkController
    @Binding var drafts: [DraftNote]
    var decor = CodePageDecor()
    /// A line picked with a finger (nil: none).
    var onSelect: (InkAnchor?) -> Void = { _ in }
    /// A note's bubble or card: open those notes.
    var onMark: ([String]) -> Void = { _ in }
    /// A diagram's mark or card: open it, with that element picked.
    var onDiagram: (String, String?) -> Void = { _, _ in }

    /// Whether SwiftUI has heard of the notes the view restored. Until then its (empty) list mustn't replace them.
    final class Coordinator { var synced = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> NativeCodeInkView {
        let v = NativeCodeInkView(key: "file-\(path)")
        v.onDrafts = { drafts = $0 }
        callbacks(v)
        v.show(path: path, text: text, decor: decor)
        controller.view = v
        let restored = v.notes.drafts, coordinator = context.coordinator
        DispatchQueue.main.async {
            drafts = restored
            coordinator.synced = true
        }
        return v
    }

    func updateUIView(_ v: NativeCodeInkView, context: Context) {
        v.onDrafts = { drafts = $0 }
        callbacks(v)
        v.show(path: path, text: text, decor: decor)
        if context.coordinator.synced, drafts != v.notes.drafts { v.setDrafts(drafts) }
    }

    private func callbacks(_ v: NativeCodeInkView) {
        v.onSelect = onSelect
        v.onMark = onMark
        v.onDiagram = onDiagram
    }
}

/// One Pencil palette per window, shared by its code pages and remembered across pages and launches, as in Notes.
@MainActor
enum CodePalette {
    private static var pickers: [ObjectIdentifier: PKToolPicker] = [:]

    static func picker(for window: UIWindow) -> PKToolPicker {
        let id = ObjectIdentifier(window.windowScene ?? window)
        if let p = pickers[id] { return p }
        let p = PKToolPicker()
        p.stateAutosaveName = "codePage"
        // Only the Pencil draws here, so the palette shouldn't offer drawing with a finger.
        p.showsDrawingPolicyControls = false
        pickers[id] = p
        return p
    }
}

/// The canvas is the page: an untransformed `PKCanvasView` that scrolls and zooms itself (its frame stays
/// screen-sized and the page lives in its content size), with the code drawn natively behind the ink. The Pencil
/// talks only to the canvas; fingers scroll and pinch.
final class NativeCodeInkView: UIView, PKCanvasViewDelegate, UIScribbleInteractionDelegate {
    private let canvas = PKCanvasView()
    private let code = UITextView(usingTextLayoutManager: true)
    private(set) lazy var notes = InkNoteTaker(canvas: canvas)
    private lazy var feedback = UICanvasFeedbackGenerator(view: self)
    private let key: String
    private var picker: PKToolPicker?
    private var shown: (path: String, text: String)?
    /// A new version of the file that came while a note was being written: shown once it's done, so the lines don't
    /// move under the Pencil.
    private var waiting: (path: String, text: String, decor: CodePageDecor)?
    private var decor = CodePageDecor()
    private lazy var decorations = CodeDecorations(in: code)
    /// The page's size at zoom 1, with its cards.
    private var pageSize = CGSize(width: 1, height: 1)
    /// The picked line.
    private var selectedLine: Int?
    /// A line to show once the file is up.
    private var pendingReveal: Int?
    /// The last tap, to tell a double tap's second tap from a new one.
    private var lastTap: (time: CFTimeInterval, at: CGPoint)?
    private var geometry = CodePageGeometry(lineCount: 1, columns: 1, advance: 8)
    /// The file's text as laid out (tabs as spaces).
    private var layoutText = ""
    /// The book's current page is on the canvas (it waits for the page's width to be known).
    private var pageLoaded = false
    private var anchors: [InkAnchor] = []
    private var book: CodeNoteBook?
    private var penDown = false
    private var saveTask: Task<Void, Never>?
    /// The zoom the code was last drawn at. While a pinch goes on the code is scaled to follow, then drawn again
    /// at the new size once it ends, so it's sharp at rest (the ink is PencilKit's, sharp at every zoom).
    private var drawnZoom: CGFloat = 1
    var onDrafts: (([DraftNote]) -> Void)?
    var onSelect: ((InkAnchor?) -> Void)?
    var onMark: (([String]) -> Void)?
    var onDiagram: ((String, String?) -> Void)?
    /// SwiftUI's handle, for the toolbar's page menu.
    weak var controller: NativeInkController?

    /// The code's size: the page's base size, scaled by the user's text size (Settings › Display & Brightness).
    private var fontSize: CGFloat { UIFontMetrics(forTextStyle: .body).scaledValue(for: CodePageGeometry.baseFontSize, compatibleWith: traitCollection) }
    private func advance(_ size: CGFloat) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular)]).width
    }

    init(key: String) {
        self.key = key
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        isOpaque = true
        canvas.drawingPolicy = .pencilOnly
        #if DEBUG
        // Simulator test runs draw with a finger: there's no Pencil to test with.
        if ProcessInfo.processInfo.environment["DUET_FINGER_INK"] == "1" { canvas.drawingPolicy = .anyInput }
        #endif
        // The page is opaque through the code view, the first thing in the canvas's content. The canvas itself is
        // clear: PencilKit fills a page-sized view of its own with the canvas's colour, above anything added to it,
        // which hid the code.
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.alwaysBounceVertical = true
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 4
        canvas.delegate = self
        // No blur under the bars at the page's edges: nothing composited over the writing.
        canvas.topEdgeEffect.isHidden = true
        canvas.bottomEdgeEffect.isHidden = true
        code.isEditable = false
        code.isSelectable = false
        code.isScrollEnabled = false
        code.isUserInteractionEnabled = false
        code.backgroundColor = .systemBackground
        code.isOpaque = true
        code.textContainerInset = .zero
        code.textContainer.lineFragmentPadding = 0
        // The page wraps long lines itself (onto rows of the paper), so the text view never does.
        code.textContainer.widthTracksTextView = false
        code.textContainer.lineBreakMode = .byClipping
        code.layer.anchorPoint = .zero
        // Behind the ink, in the canvas's content.
        canvas.insertSubview(code, at: 0)
        addSubview(canvas)
        // Strokes are ink, never text input.
        for v in [canvas, code] as [UIView] { v.addInteraction(UIScribbleInteraction(delegate: self)) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.drawCode() }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in self.resize() }
        // Fingers pick: one tap picks a line or opens what's tapped, two zoom in or back out. (The Pencil only draws.)
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = direct
        canvas.addGestureRecognizer(doubleTap)
        // A tap acts at once rather than waiting out a possible double tap; the second tap of a double tap is ignored.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.allowedTouchTypes = direct
        canvas.addGestureRecognizer(tap)
        notes.anchors = { [weak self] in self?.anchors ?? [] }
        notes.onChange = { [weak self] in self?.notesChanged() }
        notes.onTagged = { [weak self] p in
            guard let self else { return }
            self.feedback.pathCompleted(at: self.convert(p, from: self.code))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show this version of the file, or (while a note is being written) once the note is done.
    func show(path: String, text: String, decor: CodePageDecor) {
        if let shown, shown.path == path, shown.text == text, decor == self.decor { return }
        guard !penDown, !notes.busy else { waiting = (path, text, decor); return }
        waiting = nil
        let first = shown?.path != path
        shown = (path, text)
        self.decor = decor
        layoutText = CodePageGeometry.expanded(text)
        if first {
            // Its notes, brought over from the web page if it's new, laid out as if nothing wrapped; laying out on the
            // paper then moves each note to its line.
            let size = fontSize
            var book = CodeNoteBook.load(key: key, geometry: CodePageGeometry(text: layoutText, advance: advance(size), fontSize: size))
            // Written at another text size: the ink grows or shrinks with the page, so it stays on its lines.
            book.fit(lineHeight: CodePageGeometry(lineCount: 1, columns: 1, advance: 1, fontSize: size).lineHeight)
            self.book = book
            pageLoaded = false
        }
        layOut()
        if let line = pendingReveal { pendingReveal = nil; reveal(line: line) }
    }

    /// Lay the file out on its paper (chosen now from the page's width, the first time), with its notes where its
    /// lines are, fitted to the width by zooming, and draw it.
    private func layOut(reflow: Bool = false) {
        guard shown != nil, var book, bounds.width > 0 else { return }
        let size = fontSize, adv = advance(size)
        if book.paper == nil || reflow {
            book.paper = columns(fitting: bounds.width, advance: adv, size: size)
            self.book = book
            save()
        }
        geometry = CodePageGeometry(text: layoutText, advance: adv, fontSize: size, paper: book.paper)
        if !pageLoaded {
            pageLoaded = true
            loadPage(book.page)
            onDrafts?(notes.drafts)
            publishPages()
        } else if notes.follow(layoutText, geometry: geometry) {
            // The file changed under its notes, or the paper did: each note's ink moves with its line.
            onDrafts?(notes.drafts)
            save()
        }
        fitZoom()
        drawCode()
    }

    /// How many characters of code fit across this width, beside the cards' column when there's room for it.
    private func columns(fitting width: CGFloat, advance: CGFloat, size: CGFloat) -> Int {
        let g = CodePageGeometry(text: layoutText, advance: advance, fontSize: size)
        let cards = decor.hasCards && width >= Self.cardsWidth ? CodeDecorations.cardWidth + CodeDecorations.cardGap * 2 : 0
        return max(CodePageGeometry.minimumPaper, Int((width - g.codeX - g.right - cards) / advance))
    }

    /// Narrower than this, the page has no room for cards beside the code without shrinking it: their notes open
    /// from the bubbles in the gutter instead.
    static let cardsWidth: CGFloat = 700
    private var showsCards: Bool { decor.hasCards && bounds.width >= Self.cardsWidth }

    /// The page's width at zoom 1: the paper, with the cards beside it, and at least the screen's width.
    private var pageWidth: CGFloat {
        var w = geometry.width
        if showsCards { w = max(w, CodeDecorations.cardsX(geometry, pageWidth: 0) + CodeDecorations.cardWidth + CodeDecorations.cardGap) }
        return max(w, bounds.width)
    }

    /// The whole paper fits the width: it's the least zoom, and the page shows at it unless zoomed in.
    private func fitZoom() {
        let fit = min(1, bounds.width / max(pageWidth, 1))
        let atFit = abs(canvas.zoomScale - canvas.minimumZoomScale) < 0.01
        canvas.minimumZoomScale = fit
        if atFit || canvas.zoomScale < fit { canvas.zoomScale = fit }
    }

    /// Wrap the file again for this page's width, from the page menu; each note's ink moves with its line.
    func reflow() {
        guard !penDown, !notes.busy else { return }
        layOut(reflow: true)
        canvas.zoomScale = canvas.minimumZoomScale
        drawCode()
    }

    /// The user's text size changed: the page is laid out again at the new size, and its ink scaled to match.
    private func resize() {
        guard shown != nil, var book, abs(fontSize - geometry.fontSize) > 0.01 else { return }
        guard !penDown, !notes.busy else { return }
        keepCurrent(in: &book)
        book.fit(lineHeight: CodePageGeometry(lineCount: 1, columns: 1, advance: 1, fontSize: fontSize).lineHeight)
        self.book = book
        pageLoaded = false
        layOut()
        save()
    }

    private func showWaiting() {
        guard let w = waiting, !penDown, !notes.busy else { return }
        show(path: w.path, text: w.text, decor: w.decor)
    }

    /// A page's ink and notes onto the canvas, each note where its line is in the file now.
    private func loadPage(_ page: CodeNotePage) {
        notes.load((try? PKDrawing(data: page.drawing)) ?? PKDrawing(), drafts: page.drafts)
        if notes.follow(layoutText, geometry: geometry) { onDrafts?(notes.drafts); save() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else {
            // Leaving the screen: the palette goes with it (it's shared with the window's other pages).
            picker?.setVisible(false, forFirstResponder: canvas)
            picker?.removeObserver(canvas)
            canvas.resignFirstResponder()
            return
        }
        let p = CodePalette.picker(for: window)
        picker = p
        p.addObserver(canvas)
        // Start from the palette's own (remembered) tool.
        if let tool = p.selectedToolItem.tool { canvas.tool = tool }
        // First responder: the palette shows for it, and undo (three-finger swipe, two- and three-finger taps, the
        // palette's buttons) reaches the canvas.
        canvas.becomeFirstResponder()
        // The palette is out from the start, as in Notes. PencilKit does the Pencil's double-tap and squeeze (what
        // the user picked in Settings) only while it shows; handling squeeze here as well fought it.
        p.setVisible(true, forFirstResponder: canvas)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if canvas.frame != bounds {
            let wider = canvas.frame.width != bounds.width
            canvas.frame = bounds
            // Another width: the same paper, fitted to it by zooming (the first time, the paper is cut to it).
            if wider { layOut() } else { sizePage() }
        }
    }

    func toggleTools() {
        guard let picker else { return }
        canvas.becomeFirstResponder()
        picker.setVisible(!picker.isVisible, forFirstResponder: canvas)
    }

    // MARK: - Note pages

    func publishPages() {
        if let book { controller?.update(book) }
    }

    func show(page id: UUID) {
        guard var book, book.current != id, book.pages.contains(where: { $0.id == id }) else { return }
        Task {
            // The note being written goes with the page it was written on.
            await notes.finishGroup()
            keepCurrent(in: &book)
            book.current = id
            self.book = book
            loadPage(book.page)
            canvas.undoManager?.removeAllActions()
            onDrafts?(notes.drafts)
            publishPages()
            save()
        }
    }

    func addPage() {
        guard var book else { return }
        Task {
            await notes.finishGroup()
            keepCurrent(in: &book)
            book.add()
            self.book = book
            notes.load(PKDrawing(), drafts: [])
            canvas.undoManager?.removeAllActions()
            onDrafts?([])
            publishPages()
            save()
        }
    }

    func rename(_ id: UUID, to name: String) {
        book?.rename(id, to: name)
        publishPages()
        save()
    }

    func remove(_ id: UUID) {
        guard var book else { return }
        let wasCurrent = book.current == id
        book.remove(id)
        self.book = book
        if wasCurrent {
            loadPage(book.page)
            canvas.undoManager?.removeAllActions()
            onDrafts?(notes.drafts)
        }
        publishPages()
        save()
    }

    /// What's on the canvas, into the book's current page.
    private func keepCurrent(in book: inout CodeNoteBook) {
        var page = book.page
        page.drawing = canvas.drawing.dataRepresentation()
        page.drafts = notes.drafts
        book.page = page
    }

    // MARK: - Notes

    func setDrafts(_ new: [DraftNote]) {
        notes.setDrafts(new)
        save()
    }

    private func notesChanged() {
        onDrafts?(notes.drafts)
        save()
        showWaiting()
    }

    /// Kept a moment after the last change, off the main thread but for taking the drawing's data (a few ms at most).
    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, var book = self.book else { return }
            self.keepCurrent(in: &book)
            self.book = book
            let key = self.key
            await Task.detached(priority: .utility) { book.save(key: key) }.value
        }
    }

    /// The note's picture: the code and ink around the notes being sent, as on the page at zoom 1.
    func snapshot() -> UIImage? {
        guard let shown else { return nil }
        let ink = notes.drafts.filter { !$0.sent }.reduce(CGRect.null) { $0.union($1.bounds) }
        let page = pageSize
        var rect = CGRect(origin: .zero, size: page)
        if rect.height > 2200, !ink.isNull { rect = ink.insetBy(dx: 0, dy: -260).intersection(rect); rect.origin.x = 0; rect.size.width = page.width }
        guard geometry.lines(in: rect) != nil else { return nil }
        let text = Self.page(layoutText, path: shown.path, geometry: geometry, zoom: 1,
                             dark: false) as NSAttributedString
        let ns = text.string as NSString
        let drawing = canvas.drawing.image(from: rect, scale: 1)
        let scale = min(1, 1600 / max(rect.width, 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: rect.width * scale, height: rect.height * scale), format: format).image { ctx in
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                UIColor.systemBackground.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: rect.width * scale, height: rect.height * scale))
                ctx.cgContext.scaleBy(x: scale, y: scale)
                ctx.cgContext.translateBy(x: 0, y: -rect.minY)
                // The page's text is a margin line, then a row per row of the page.
                var at = NSMaxRange(ns.lineRange(for: NSRange(location: 0, length: 0))), row = 0
                let first = Int(((rect.minY - geometry.top) / geometry.lineHeight).rounded(.down)), last = Int(((rect.maxY - geometry.top) / geometry.lineHeight).rounded(.up))
                while at < ns.length, row <= last {
                    let r = ns.lineRange(for: NSRange(location: at, length: 0))
                    if row >= first { text.attributedSubstring(from: r).draw(with: geometry.rect(row: row, width: rect.width), options: .usesLineFragmentOrigin, context: nil) }
                    at = NSMaxRange(r)
                    row += 1
                }
                drawing.draw(in: rect)
            }
        }
    }

    // MARK: - The page

    /// The canvas's content size is the page at its zoom (PencilKit scales the ink to match).
    private func sizePage() {
        let z = canvas.zoomScale, page = pageSize
        canvas.contentSize = CGSize(width: page.width * z, height: page.height * z)
        code.transform = CGAffineTransform(scaleX: z / drawnZoom, y: z / drawnZoom)
        code.layer.position = .zero
    }

    /// Draw the code at the zoom it's seen at, with line numbers in a gutter.
    private func drawCode() {
        guard let shown else { return }
        let z = canvas.zoomScale
        drawnZoom = z
        let attributed = Self.page(layoutText, path: shown.path, geometry: geometry, zoom: z,
                                   dark: traitCollection.userInterfaceStyle == .dark)
        var page = geometry.size(atLeast: CGSize(width: pageWidth, height: bounds.height / max(canvas.minimumZoomScale, 0.01)))
        anchors = geometry.anchors(path: shown.path, text: layoutText, width: page.width)
        code.transform = .identity
        code.layer.position = .zero
        code.attributedText = attributed
        decorations.lay(decor, cards: showsCards, geometry: geometry, pageWidth: page.width, zoom: z, in: code)
        decorations.select(selectedLine.map { geometry.rect(line: $0, width: page.width) }, zoom: z)
        // Cards may run past the last line.
        page.height = max(page.height, decorations.bottom() + geometry.bottom)
        pageSize = page
        code.textContainer.size = CGSize(width: page.width * z, height: page.height * z)
        code.bounds = CGRect(x: 0, y: 0, width: page.width * z, height: page.height * z)
        code.frame.origin = .zero
        sizePage()
    }

    /// The file's text as the page shows it, at a zoom: each line led by its number.
    static func page(_ text: String, path: String, geometry g: CodePageGeometry, zoom: CGFloat, dark: Bool) -> NSAttributedString {
        let lineCount = g.lineCount, gutter = g.gutter
        let font = UIFont.monospacedSystemFont(ofSize: g.fontSize * zoom, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = g.lineHeight * zoom
        para.maximumLineHeight = g.lineHeight * zoom
        para.lineBreakMode = .byClipping
        para.firstLineHeadIndent = g.left * zoom
        para.headIndent = g.left * zoom
        let number: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.tertiaryLabel, .paragraphStyle: para]
        // Coloured as the web page colours it, then cut into lines, each led by its number.
        let styled = CodeSyntax.attributed(text, language: CodeHTML.language(path: path, text: text), dark: dark, font: font)
        let out = NSMutableAttributedString()
        // A top margin: the first line sits below the page's edge.
        let top = NSMutableParagraphStyle()
        top.minimumLineHeight = g.top * zoom
        top.maximumLineHeight = g.top * zoom
        out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: top]))
        let wrap: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.tertiaryLabel, .paragraphStyle: para]
        let ns = text as NSString
        var start = 0
        for n in 1...lineCount {
            let label = String(n)
            out.append(NSAttributedString(string: String(repeating: " ", count: gutter - 2 - label.count) + label + "  ", attributes: number))
            let range = ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0))
            start = NSMaxRange(range)
            let line = NSMutableAttributedString(attributedString: styled.attributedSubstring(from: range))
            if line.string.hasSuffix("\n") { line.deleteCharacters(in: NSRange(location: line.length - 1, length: 1)) }
            guard let rows = g.wrapped[n] else {
                line.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                line.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: line.length))
                out.append(line)
                continue
            }
            // A long line on its rows: no number on a continuation row (a ↪ where it would be), hanging under the
            // line's own indent, and a dim ⏎ where a row had to break mid-word. Its colours run across the breaks.
            let utf16 = line.string.reduce(into: [0]) { $0.append($0.last! + $1.utf16.count) }
            let hang = String(repeating: " ", count: g.hanging[n] ?? 4)
            for (i, row) in rows.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: String(repeating: " ", count: gutter - 3) + "↪  " + hang, attributes: wrap)) }
                let piece = NSMutableAttributedString(attributedString: line.attributedSubstring(from: NSRange(location: utf16[row.start], length: utf16[row.end] - utf16[row.start])))
                if row.hard { piece.append(NSAttributedString(string: "⏎", attributes: wrap)) }
                piece.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                piece.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: piece.length))
                out.append(piece)
            }
        }
        return out
    }

    // MARK: - Fingers

    /// A point in the canvas, on the page (zoom 1).
    private func onPage(_ g: UIGestureRecognizer) -> CGPoint {
        let p = g.location(in: canvas), z = max(canvas.zoomScale, 0.01)
        return CGPoint(x: p.x / z, y: p.y / z)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = onPage(g), now = CACurrentMediaTime()
        defer { lastTap = (now, p) }
        if let last = lastTap, now - last.time < 0.35, hypot(p.x - last.at.x, p.y - last.at.y) < 30 { return }
        switch decorations.hit(at: p) {
        case .notes(let ids): onMark?(ids)
        case .diagram(let id, let element): onDiagram?(id, element)
        case nil:
            let line = geometry.line(at: p.y)
            select(line == selectedLine ? nil : line)
        }
    }

    /// Two taps zoom in on where they were, or back out to the whole width.
    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        if canvas.zoomScale > canvas.minimumZoomScale * 1.05 {
            canvas.setZoomScale(canvas.minimumZoomScale, animated: true)
        } else {
            let p = g.location(in: canvas), z: CGFloat = max(2 * canvas.minimumZoomScale, 1.5)
            let size = CGSize(width: canvas.bounds.width / z * canvas.zoomScale, height: canvas.bounds.height / z * canvas.zoomScale)
            canvas.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }

    private func select(_ line: Int?) {
        selectedLine = line
        let z = drawnZoom
        decorations.select(line.map { geometry.rect(line: $0, width: pageSize.width) }, zoom: z)
        onSelect?(line.flatMap { n in anchors.first { $0.line == n } })
    }

    func reveal(line: Int) {
        guard shown != nil else { pendingReveal = line; return }
        scrollTo(line: line)
        select(min(max(line, 1), geometry.lineCount))
    }

    /// The line a third of the way down the screen.
    func scrollTo(line: Int) {
        guard shown != nil else { pendingReveal = line; return }
        let z = canvas.zoomScale, r = geometry.rect(line: min(max(line, 1), geometry.lineCount), width: pageSize.width)
        let maxY = max(0, canvas.contentSize.height - canvas.bounds.height)
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: min(max(0, r.minY * z - canvas.bounds.height / 3), maxY)), animated: true)
    }

    // MARK: - Canvas

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        penDown = true
        // Back out if it was put away with Pencil Tools.
        if let picker, !picker.isVisible { picker.setVisible(true, forFirstResponder: canvas) }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        penDown = false
        // The drawing hears of the stroke just after this; a waiting version of the file shows once the note allows.
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            showWaiting()
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { notes.drawingChanged() }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { sizePage() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if abs(scale - drawnZoom) > 0.01 { drawCode() }
    }

    // MARK: - Scribble

    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool { false }
}
#endif
