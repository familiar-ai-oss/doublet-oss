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

    /// Whether SwiftUI has heard of the notes the view restored. Until then its (empty) list mustn't replace them.
    final class Coordinator { var synced = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> NativeCodeInkView {
        let v = NativeCodeInkView(key: "file-\(path)")
        v.onDrafts = { drafts = $0 }
        v.show(path: path, text: text)
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
        v.show(path: path, text: text)
        if context.coordinator.synced, drafts != v.notes.drafts { v.setDrafts(drafts) }
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
    private var waiting: (path: String, text: String)?
    private var geometry = CodePageGeometry(lineCount: 1, columns: 1, advance: 8)
    private var anchors: [InkAnchor] = []
    private var book: CodeNoteBook?
    private var penDown = false
    private var saveTask: Task<Void, Never>?
    /// The zoom the code was last drawn at. While a pinch goes on the code is scaled to follow, then drawn again
    /// at the new size once it ends, so it's sharp at rest (the ink is PencilKit's, sharp at every zoom).
    private var drawnZoom: CGFloat = 1
    var onDrafts: (([DraftNote]) -> Void)?
    /// SwiftUI's handle, for the toolbar's page menu.
    weak var controller: NativeInkController?

    private static var font: UIFont { .monospacedSystemFont(ofSize: CodePageGeometry.fontSize, weight: .regular) }
    private static var advance: CGFloat { ("0" as NSString).size(withAttributes: [.font: font]).width }

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
        // Lines never wrap: a line's place on the page is fixed, so ink stays on its line at any width or zoom.
        code.textContainer.widthTracksTextView = false
        code.textContainer.lineBreakMode = .byClipping
        code.layer.anchorPoint = .zero
        // Behind the ink, in the canvas's content.
        canvas.insertSubview(code, at: 0)
        addSubview(canvas)
        // Strokes are ink, never text input.
        for v in [canvas, code] as [UIView] { v.addInteraction(UIScribbleInteraction(delegate: self)) }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.drawCode() }
        notes.anchors = { [weak self] in self?.anchors ?? [] }
        notes.onChange = { [weak self] in self?.notesChanged() }
        notes.onTagged = { [weak self] p in
            guard let self else { return }
            self.feedback.pathCompleted(at: self.convert(p, from: self.code))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show this version of the file, or (while a note is being written) once the note is done.
    func show(path: String, text: String) {
        if let shown, shown.path == path, shown.text == text { return }
        guard !penDown, !notes.busy else { waiting = (path, text); return }
        waiting = nil
        let first = shown?.path != path
        shown = (path, text)
        geometry = CodePageGeometry(text: text, advance: Self.advance)
        if first {
            let book = CodeNoteBook.load(key: key, geometry: geometry)
            self.book = book
            notes.load((try? PKDrawing(data: book.page.drawing)) ?? PKDrawing(), drafts: book.page.drafts)
            publishPages()
        }
        drawCode()
    }

    private func showWaiting() {
        guard let w = waiting, !penDown, !notes.busy else { return }
        show(path: w.path, text: w.text)
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
            canvas.frame = bounds
            sizePage()
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
            notes.load((try? PKDrawing(data: book.page.drawing)) ?? PKDrawing(), drafts: book.page.drafts)
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
            notes.load((try? PKDrawing(data: book.page.drawing)) ?? PKDrawing(), drafts: book.page.drafts)
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
        let page = geometry.size(atLeast: CGSize(width: bounds.width, height: 0))
        var rect = CGRect(origin: .zero, size: page)
        if rect.height > 2200, !ink.isNull { rect = ink.insetBy(dx: 0, dy: -260).intersection(rect); rect.origin.x = 0; rect.size.width = page.width }
        guard let lines = geometry.lines(in: rect) else { return nil }
        let text = Self.page(shown.text, path: shown.path, lineCount: geometry.lineCount, gutter: geometry.gutter, zoom: 1,
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
                // The page's text is a margin line, then a line per line of the file.
                var at = NSMaxRange(ns.lineRange(for: NSRange(location: 0, length: 0)))
                for n in 1...lines.upperBound {
                    let r = ns.lineRange(for: NSRange(location: min(at, ns.length), length: 0))
                    if n >= lines.lowerBound {
                        text.attributedSubstring(from: r).draw(with: geometry.rect(line: n, width: rect.width), options: .usesLineFragmentOrigin, context: nil)
                    }
                    at = NSMaxRange(r)
                }
                drawing.draw(in: rect)
            }
        }
    }

    // MARK: - The page

    /// The canvas's content size is the page at its zoom (PencilKit scales the ink to match).
    private func sizePage() {
        let z = canvas.zoomScale, page = geometry.size(atLeast: bounds.size)
        canvas.contentSize = CGSize(width: page.width * z, height: page.height * z)
        code.transform = CGAffineTransform(scaleX: z / drawnZoom, y: z / drawnZoom)
        code.layer.position = .zero
    }

    /// Draw the code at the zoom it's seen at, with line numbers in a gutter.
    private func drawCode() {
        guard let shown else { return }
        let z = canvas.zoomScale
        drawnZoom = z
        let attributed = Self.page(shown.text, path: shown.path, lineCount: geometry.lineCount, gutter: geometry.gutter, zoom: z,
                                   dark: traitCollection.userInterfaceStyle == .dark)
        let page = geometry.size(atLeast: bounds.size)
        anchors = geometry.anchors(path: shown.path, text: shown.text, width: page.width)
        code.transform = .identity
        code.layer.position = .zero
        code.textContainer.size = CGSize(width: page.width * z, height: page.height * z)
        code.attributedText = attributed
        code.bounds = CGRect(x: 0, y: 0, width: page.width * z, height: page.height * z)
        code.frame.origin = .zero
        sizePage()
    }

    /// The file's text as the page shows it, at a zoom: each line led by its number.
    static func page(_ text: String, path: String, lineCount: Int, gutter: Int, zoom: CGFloat, dark: Bool) -> NSAttributedString {
        let font = UIFont.monospacedSystemFont(ofSize: CodePageGeometry.fontSize * zoom, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = CodePageGeometry.lineHeight * zoom
        para.maximumLineHeight = CodePageGeometry.lineHeight * zoom
        para.lineBreakMode = .byClipping
        para.firstLineHeadIndent = CodePageGeometry.left * zoom
        para.headIndent = CodePageGeometry.left * zoom
        let number: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.tertiaryLabel, .paragraphStyle: para]
        // Coloured as the web page colours it, then cut into lines, each led by its number.
        let styled = CodeSyntax.attributed(text, language: CodeHTML.language(path: path, text: text), dark: dark, font: font)
        let out = NSMutableAttributedString()
        // A top margin: the first line sits below the page's edge.
        let top = NSMutableParagraphStyle()
        top.minimumLineHeight = CodePageGeometry.top * zoom
        top.maximumLineHeight = CodePageGeometry.top * zoom
        out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: top]))
        let ns = text as NSString
        var start = 0
        for n in 1...lineCount {
            let label = String(n)
            out.append(NSAttributedString(string: String(repeating: " ", count: gutter - 2 - label.count) + label + "  ", attributes: number))
            let range = ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0))
            let line = NSMutableAttributedString(attributedString: styled.attributedSubstring(from: range))
            if !line.string.hasSuffix("\n") { line.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            line.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: line.length))
            out.append(line)
            start = NSMaxRange(range)
        }
        return out
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
