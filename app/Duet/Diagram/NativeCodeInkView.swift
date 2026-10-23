#if os(iOS)
import PencilKit
import SwiftUI
import UIKit

/// SwiftUI's handle on a native code page: the Pencil palette, from the file's toolbar.
@MainActor @Observable
final class NativeInkController {
    @ObservationIgnored weak var view: NativeCodeInkView?
    func toggleTools() { view?.toggleTools() }
}

/// A code file as a native page to write on (the `nativeCodePage` setting, a prototype): the canvas is the page, as
/// in Notes. No saving, tagging or notes yet; it answers whether writing here feels like Notes.
struct NativeCodeInkRepresentable: UIViewRepresentable {
    let path: String
    let text: String
    let controller: NativeInkController

    func makeUIView(context: Context) -> NativeCodeInkView {
        let v = NativeCodeInkView()
        controller.view = v
        v.show(path: path, text: text)
        return v
    }

    func updateUIView(_ v: NativeCodeInkView, context: Context) {
        v.show(path: path, text: text)
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

/// The canvas is the page: an opaque, untransformed `PKCanvasView` that scrolls and zooms itself (its frame stays
/// screen-sized and the page lives in its content size), with the code drawn natively behind the ink. The Pencil
/// talks only to the canvas; fingers scroll and pinch.
final class NativeCodeInkView: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIScribbleInteractionDelegate {
    private let canvas = PKCanvasView()
    private let code = UITextView(usingTextLayoutManager: true)
    private var picker: PKToolPicker?
    private var shown: (path: String, text: String)?
    private var lineCount = 1
    private var columns = 1
    /// The zoom the code was last drawn at. While a pinch goes on the code is scaled to follow, then drawn again
    /// at the new size once it ends, so it's sharp at rest (the ink is PencilKit's, sharp at every zoom).
    private var drawnZoom: CGFloat = 1
    /// The tool before a squeeze picked the eraser: the next squeeze goes back to it.
    private var beforeEraser: String?

    private static let fontSize: CGFloat = 13
    private static let lineHeight: CGFloat = 20
    private static let inset = UIEdgeInsets(top: 12, left: 12, bottom: 40, right: 24)

    init() {
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
        addInteraction(UIPencilInteraction(delegate: self))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.drawCode() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(path: String, text: String) {
        if let shown, shown.path == path, shown.text == text { return }
        shown = (path, text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lineCount = max(lines.count - (lines.last == "" && lines.count > 1 ? 1 : 0), 1)
        columns = max(lines.map { $0.count }.max() ?? 1, 1)
        drawCode()
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

    // MARK: - The page

    private var font: UIFont { .monospacedSystemFont(ofSize: Self.fontSize, weight: .regular) }
    private var gutter: Int { String(lineCount).count + 2 }

    /// The page at zoom 1: every line is the same height and never wraps, so its size follows from the text.
    private var pageSize: CGSize {
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        let width = Self.inset.left + CGFloat(columns + gutter) * advance + Self.inset.right
        let height = Self.inset.top + CGFloat(lineCount) * Self.lineHeight + Self.inset.bottom
        return CGSize(width: max(width, bounds.width), height: max(height, bounds.height))
    }

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
        let attributed = Self.page(shown.text, path: shown.path, lineCount: lineCount, gutter: gutter, zoom: z,
                                   dark: traitCollection.userInterfaceStyle == .dark)
        let page = pageSize
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
        let font = UIFont.monospacedSystemFont(ofSize: fontSize * zoom, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lineHeight * zoom
        para.maximumLineHeight = lineHeight * zoom
        para.lineBreakMode = .byClipping
        para.firstLineHeadIndent = inset.left * zoom
        para.headIndent = inset.left * zoom
        let number: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.tertiaryLabel, .paragraphStyle: para]
        // Coloured as the web page colours it, then cut into lines, each led by its number.
        let styled = CodeSyntax.attributed(text, language: CodeHTML.language(path: path, text: text), dark: dark, font: font)
        let out = NSMutableAttributedString()
        // A top margin: the first line sits below the page's edge.
        let top = NSMutableParagraphStyle()
        top.minimumLineHeight = inset.top * zoom
        top.maximumLineHeight = inset.top * zoom
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
        // The palette stays out of the way until the Pencil writes, or Pencil Tools asks for it.
        if let picker, !picker.isVisible { picker.setVisible(true, forFirstResponder: canvas) }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { sizePage() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if abs(scale - drawnZoom) > 0.01 { drawCode() }
    }

    // MARK: - Pencil

    /// A squeeze picks the eraser, and the next one goes back to the tool before it, through the palette so it shows
    /// what's picked (the canvas follows the palette).
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended, let picker,
              let eraser = picker.toolItems.first(where: { $0 is PKToolPickerEraserItem }) else { return }
        if picker.selectedToolItemIdentifier == eraser.identifier {
            let back = beforeEraser ?? picker.toolItems.first { $0 is PKToolPickerInkingItem }?.identifier
            if let back { picker.selectedToolItemIdentifier = back }
        } else {
            beforeEraser = picker.selectedToolItemIdentifier
            picker.selectedToolItemIdentifier = eraser.identifier
        }
    }

    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool { false }
}
#endif
