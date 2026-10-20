#if os(iOS)
import DuetKit
import PencilKit
import SwiftUI
import UIKit

/// SwiftUI's handle on the ink surface: a snapshot for the note's picture, the tool picker, search.
@MainActor @Observable
final class InkController {
    @ObservationIgnored weak var view: InkSurfaceView? {
        didSet { if toolsWanted, let view { toolsWanted = false; view.showTools() } }
    }
    /// The tools were asked for before the page was up (a file still loading).
    @ObservationIgnored private var toolsWanted = false
    func snapshot() async -> UIImage? { await view?.snapshot() }
    func toggleTools() { view?.toggleTools() }
    /// The tools out, ready to write: a file or a diagram sent here to write on (Write on iPad).
    func showTools() { if let view { view.showTools() } else { toolsWanted = true } }
    func finishNote() async { await view?.finishGroup() }

    /// The notes to send, each with a picture of its handwriting for the hub to keep. Readings still on their way get
    /// a moment (at most 0.8 s) to arrive, since a note's kind decides where it goes.
    func items(_ drafts: [DraftNote]) async -> [InkNote] {
        await view?.settleReadings(Set(drafts.map(\.id)), within: .milliseconds(800))
        return drafts.map { d in
            let latest = view?.drafts.first { $0.id == d.id } ?? d
            var n = latest.note
            n.ink = view?.inkPNG(latest)
            return n
        }
    }
}

/// The iPad's annotatable page: the rendered diagram or diff with an Apple Pencil canvas over it.
struct InkSurfaceRepresentable: UIViewRepresentable {
    let page: DiagramPage
    let document: DiagramDocument
    /// Where the ink is kept: a diagram's id (so it follows the diagram across versions) or a task's.
    let key: String
    let isDiff: Bool
    let controller: InkController
    @Binding var drafts: [DraftNote]
    var search: String
    var onSelect: (InkAnchor?) -> Void
    var onSqueeze: () -> Void

    /// Whether SwiftUI has heard of the notes the view restored. Until then its (empty) list mustn't replace them.
    final class Coordinator { var synced = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InkSurfaceView {
        let v = InkSurfaceView(page: page, isDiff: isDiff, key: key)
        v.onDrafts = { drafts = $0 }
        v.onSelect = onSelect
        v.onSqueeze = onSqueeze
        controller.view = v
        v.show(document, dark: context.environment.colorScheme == .dark)
        let restored = v.drafts, coordinator = context.coordinator
        DispatchQueue.main.async {
            drafts = restored
            coordinator.synced = true
        }
        return v
    }

    func updateUIView(_ v: InkSurfaceView, context: Context) {
        v.show(document, dark: context.environment.colorScheme == .dark)
        v.onSelect = onSelect
        v.onSqueeze = onSqueeze
        if context.coordinator.synced, drafts != v.drafts { v.setDrafts(drafts) }
        v.search(search)
    }
}

/// The page zooms and scrolls itself (WebKit's own scroll view, so it's sharp at any zoom), and the ink rides on top
/// inside that scroll view: an overlay in page coordinates (the same as the elements' rectangles), scaled to its zoom.
final class InkSurfaceView: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    let page: DiagramPage
    let isDiff: Bool
    private let key: String
    /// Ink, tethers, chips and the hover readout, in page coordinates.
    private let overlay = UIView()
    private let canvas = PKCanvasView()
    private let tethers = CAShapeLayer()
    private let found = CAShapeLayer()
    private let hoverLabel = PaddedLabel()
    private var chips: [String: PaddedLabel] = [:]
    private let toolPicker = PKToolPicker()
    private lazy var feedback = UICanvasFeedbackGenerator(view: self)
    private let recognizer = PKStrokeRecognizer()
    private(set) var drafts: [DraftNote] = []
    private var known: Set<UUID> = []
    private var group: [UUID] = []
    /// The note the strokes being written carry on: one already closed but not sent, opened again to be read whole.
    private var reopened: String?
    private var groupTimer: Timer?
    /// The Pencil is on the glass: a stroke is being drawn.
    private var penDown = false
    /// The Pencil palette has been put out on this page.
    private var pickerShown = false
    /// The last tap, to tell a double tap's second tap from a new one.
    private var lastTap: (time: CFTimeInterval, at: CGPoint)?
    /// The page moved under a stroke: the tagged ink follows it once the pen lifts.
    private var followAfterStroke = false
    /// Notes being worked out (their words read, their elements found), which need the page they were written on.
    private var finishing = 0
    /// A new version of the page that came while a note was being written. It's shown once the note is done, so the
    /// lines don't move under the Pencil and the note is tagged to the page it was written on.
    private var waiting: (document: DiagramDocument, dark: Bool)?
    private var hovered: String?
    /// The note under the Pencil's tip, whose reading the hover readout shows.
    private var hoveredNote: String?
    /// Readings on their way, by note.
    private var readings: [String: Task<Void, Never>] = [:]
    /// The hover readout's size on screen, measured when its text changes rather than on every move of the tip.
    private var hoverSize: CGSize = .zero
    /// When the Pencil last wrote. Between strokes its tip hovers just above the glass, and hover feedback there would
    /// light a line, pop up its label and tick in the hand with every letter.
    private var lastInk: CFTimeInterval = 0
    /// When the tip came close while not writing: feedback once it lingers, not as it comes down to write.
    private var hoverSince: CFTimeInterval?
    private var sharpZoom: CGFloat = 1
    /// The zoom the labels and tethers were last laid out for.
    private var shownZoom: CGFloat = 1
    private var zoomWatch: NSKeyValueObservation?
    private var scrollWatch: NSKeyValueObservation?
    private var lastSearch = ""
    private var searchTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    var onDrafts: (([DraftNote]) -> Void)?
    var onSelect: ((InkAnchor?) -> Void)?
    var onSqueeze: (() -> Void)?

    private var pageScroll: UIScrollView { page.web.scrollView }

    init(page: DiagramPage, isDiff: Bool, key: String) {
        self.page = page
        self.isDiff = isDiff
        self.key = key
        super.init(frame: .zero)
        let web = page.web
        web.isUserInteractionEnabled = true
        web.scrollView.isScrollEnabled = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.alwaysBounceVertical = true
        addSubview(web)
        overlay.layer.anchorPoint = .zero
        web.scrollView.addSubview(overlay)
        // Apple Pencil always writes; fingers scroll, zoom and pick elements.
        canvas.drawingPolicy = .pencilOnly
        #if DEBUG
        // Simulator test runs draw with a finger: there's no Pencil to test with.
        if ProcessInfo.processInfo.environment["DUET_FINGER_INK"] == "1" { canvas.drawingPolicy = .anyInput }
        #endif
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        // The canvas only covers what's on screen and scrolls its content to match (`fitCanvas`), so its offset must
        // be exactly where it sits on the page: no insets of its own.
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.delegate = self
        // Black (white in dark mode) for plain notes; red, blue or green from the picker mean change, ask, looks right.
        canvas.tool = PKInkingTool(.pen, color: .label, width: 3)
        overlay.addSubview(canvas)
        for layer in [tethers, found] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 2
            overlay.layer.addSublayer(layer)
        }
        tethers.lineDashPattern = [5, 4]
        found.strokeColor = UIColor.systemYellow.cgColor
        found.fillColor = UIColor.systemYellow.withAlphaComponent(0.18).cgColor
        hoverLabel.isHidden = true
        overlay.addSubview(hoverLabel)
        // The overlay covers the page, so it takes the taps: one picks an element, two zoom in or back out.
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = direct
        overlay.addGestureRecognizer(doubleTap)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.allowedTouchTypes = direct
        // A tap on a note's bubble is never ink, whatever the drawing policy.
        tap.delegate = self
        // A tap acts at once rather than waiting out a possible double tap (a third of a second on every tap); the
        // second tap of a double tap is ignored instead (`tapped`).
        if !SpeedSwitches.on("taps") { tap.require(toFail: doubleTap) }
        overlay.addGestureRecognizer(tap)
        overlay.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovering(_:))))
        addInteraction(UIPencilInteraction(delegate: self))
        page.onLayout = { [weak self] size, anchors in self?.laidOut(size, anchors) }
        // The page's content size changes as it loads and on every step of a pinch.
        zoomWatch = web.scrollView.observe(\.contentSize) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.followZoom() }
        }
        // The canvas goes along as the page scrolls.
        scrollWatch = web.scrollView.observe(\.contentOffset) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.fitCanvas() }
        }
        restore()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            // Leaving the screen: the picker goes with it, and the keyboard focus goes back to the app.
            toolPicker.setVisible(false, forFirstResponder: canvas)
            toolPicker.removeObserver(canvas)
            canvas.resignFirstResponder()
            return
        }
        // The palette stays out of the way until the Pencil writes, or Pencil Tools or a squeeze asks for it.
        toolPicker.addObserver(canvas)
        canvas.becomeFirstResponder()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        page.web.frame = bounds
        followZoom()
    }

    /// Keep the overlay over the page: page coordinates inside, scaled by the page's zoom, covering at least what's
    /// on screen (so you can write below a short diagram), and on top of WebKit's own views.
    private func followZoom() {
        let sv = pageScroll
        let z = max(sv.zoomScale, 0.01)
        let size = CGSize(width: max(sv.contentSize.width, bounds.width) / z, height: max(sv.contentSize.height, bounds.height) / z)
        if overlay.bounds.size != size { overlay.bounds = CGRect(origin: .zero, size: size) }
        overlay.layer.position = .zero
        overlay.transform = CGAffineTransform(scaleX: z, y: z)
        fitCanvas()
        if sv.subviews.last !== overlay { sv.bringSubviewToFront(overlay) }
        // Labels and tethers stay the same size on screen at any zoom; only the ink and the page grow.
        if abs(z - shownZoom) > 0.001 {
            shownZoom = z
            redraw()
        }
        // The ink and labels are drawn for the zoom they're seen at, once it has changed enough to show.
        if abs(z - sharpZoom) > 0.2 {
            sharpZoom = z
            let pixels = (window?.screen.scale ?? 2) * z
            canvas.contentScaleFactor = pixels
            for layer in [tethers, found] { layer.contentsScale = pixels }
            for chip in chips.values { chip.contentScaleFactor = pixels }
            hoverLabel.contentScaleFactor = pixels
        }
    }

    /// The canvas covers what's on screen and a margin around it, never the whole page. As a stroke starts, PencilKit
    /// copies the canvas's ink into one picture the size of the canvas; a page-sized one (past 16,384 pixels: a few
    /// hundred lines of code, fewer zoomed in) can't be made, so all the ink vanished while the Pencil was down and came
    /// back as it lifted (in the simulator, Metal stops the app instead). The canvas's content scrolls to match where
    /// it sits, so the ink stays in page coordinates: the drawing, the saved notes and their tags are unchanged.
    private func fitCanvas() {
        // Never under the Pencil: a canvas moved or resized mid-stroke drops the stroke. It catches up as the pen lifts.
        guard !penDown else { return }
        let sv = pageScroll
        let z = max(sv.zoomScale, 0.01)
        let page = overlay.bounds
        if canvas.contentSize != page.size { canvas.contentSize = page.size }
        let seen = CGRect(x: sv.contentOffset.x / z, y: sv.contentOffset.y / z, width: sv.bounds.width / z, height: sv.bounds.height / z).intersection(page)
        guard !seen.isNull, seen.width > 0, seen.height > 0 else { return }
        var frame = canvas.frame
        // Moved only once what's on screen nears its edge, or a zoom made it far bigger than what's on screen: not on
        // every step of a scroll.
        if !(frame.insetBy(dx: -0.5, dy: -0.5).contains(seen) && frame.width < seen.width * 2 && frame.height < seen.height * 2) {
            frame = seen.insetBy(dx: -seen.width / 4, dy: -seen.height / 4).intersection(page)
        }
        if canvas.frame != frame { canvas.frame = frame }
        if canvas.contentOffset != frame.origin { canvas.contentOffset = frame.origin }
    }

    /// The palette shows only while the canvas has the focus. Once a text field (the message, the handwriting search)
    /// or another page took it, asking for the palette again changed nothing and the canvas never took the focus back:
    /// the button did nothing, and a page left on the eraser stayed on it. Out, it goes away; away, it comes out and
    /// the canvas takes the focus.
    func toggleTools() {
        if toolPicker.isVisible {
            toolPicker.setVisible(false, forFirstResponder: canvas)
        } else {
            toolPicker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        }
    }

    /// The palette out without a stroke first (Write on iPad). Before the view is on screen, it comes out when it is
    /// (`didMoveToWindow` makes the canvas the first responder).
    func showTools() {
        toolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    /// Show this version of the page, or (while a note is being written) once the note is done.
    func show(_ document: DiagramDocument, dark: Bool) {
        guard !penDown, group.isEmpty, finishing == 0 else {
            waiting = (document, dark)
            return
        }
        waiting = nil
        page.load(document, dark: dark)
    }

    private func showWaiting() {
        guard !penDown, group.isEmpty, finishing == 0, let w = waiting else { return }
        waiting = nil
        page.load(w.document, dark: w.dark)
    }

    // MARK: layout from the page

    private func laidOut(_ size: CGSize, _ anchors: [InkAnchor]) {
        followZoom()
        followElements(anchors)
        redraw()
    }

    /// Sticky ink: when Claude revises the diagram, each note's strokes move with the element they're tagged to.
    private func followElements(_ anchors: [InkAnchor]) {
        // Not under the pen: setting the drawing mid-stroke would cut the stroke short. They move once it lifts.
        guard !penDown else {
            followAfterStroke = true
            return
        }
        var drawing = canvas.drawing
        var renamed: [UUID: UUID] = [:]
        for i in drafts.indices {
            // Ink saved before notes kept every element: its first one.
            if drafts[i].tagged == nil, let c = drafts[i].anchorCenter, let id = drafts[i].note.elements?.first?.id { drafts[i].tagged = [id: c] }
            // The average move of its elements that are still there (a removed one has nowhere to go).
            var moves: [CGVector] = []
            for (id, old) in drafts[i].tagged ?? [:] {
                guard let a = anchors.first(where: { $0.id == id }) else { continue }
                moves.append(CGVector(dx: a.rect.midX - old.x, dy: a.rect.midY - old.y))
                drafts[i].tagged?[id] = CGPoint(x: a.rect.midX, y: a.rect.midY)
            }
            guard !moves.isEmpty else { continue }
            let dx = moves.map(\.dx).reduce(0, +) / CGFloat(moves.count), dy = moves.map(\.dy).reduce(0, +) / CGFloat(moves.count)
            guard abs(dx) > 0.5 || abs(dy) > 0.5 else { continue }
            let t = CGAffineTransform(translationX: dx, y: dy)
            for j in drawing.strokes.indices where drafts[i].strokeIDs.contains(drawing.strokes[j].id) {
                // A moved stroke gets a new id: the canvas redraws strokes it hasn't seen, not ones it has that moved.
                let s = drawing.strokes[j]
                let moved = PKStroke(ink: s.ink, path: s.path, transform: s.transform.concatenating(t), mask: s.mask, randomSeed: s.randomSeed)
                renamed[s.id] = moved.id
                drawing.strokes[j] = moved
            }
            drafts[i].strokeIDs = Set(drafts[i].strokeIDs.map { renamed[$0] ?? $0 })
            drafts[i].bounds = drafts[i].bounds.applying(t)
        }
        guard !renamed.isEmpty else { return }
        // Known before the canvas hears of them, so they aren't taken for new ink.
        known.subtract(renamed.keys)
        known.formUnion(renamed.values)
        canvas.drawing = drawing
        publish()
    }

    // MARK: strokes into notes

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        if !penDown { ProblemReports.note("ink") }
        penDown = true
        lastInk = CACurrentMediaTime()
        clearHover()
        // Out once per page: if you put it away, it stays away, rather than coming back (and laying out) on every stroke.
        if !pickerShown || !SpeedSwitches.on("taps") {
            pickerShown = true
            if !toolPicker.isVisible { toolPicker.setVisible(true, forFirstResponder: canvas) }
        }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        penDown = false
        lastInk = CACurrentMediaTime()
        // The page may have moved or resized under the stroke (the keyboard going away does): the canvas catches up.
        fitCanvas()
        // Writing takes the focus back from a text field or another page, so this page's palette (with the Pencil's
        // switch between pen and eraser) works again, as you left it. Once the stroke is down: taking it as the stroke
        // starts puts the keyboard away under the pen, the page grows, and the stroke was lost.
        if !canvas.isFirstResponder { canvas.becomeFirstResponder() }
        // A stroke starts or adds to a note, and the page waits for that; an eraser's doesn't. The drawing hears of the
        // stroke just after this, so look once it has.
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            if followAfterStroke, !penDown {
                followAfterStroke = false
                followElements(page.anchors)
                redraw()
            }
            showWaiting()
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let ids = canvas.drawing.strokes.map(\.id)
        let now = Set(ids)
        // Erasing a note's strokes erases the note. One that loses only some (part of it rubbed out, or Undo taking
        // back a stroke that had carried it on) is read again from what's left, so its chip, tags and words match it.
        let erased = known.subtracting(now)
        if !erased.isEmpty {
            known.subtract(erased)
            group.removeAll { erased.contains($0) }
            var shrunk: [(id: String, strokes: [UUID])] = []
            for i in drafts.indices where !drafts[i].strokeIDs.isDisjoint(with: erased) {
                drafts[i].strokeIDs.subtract(erased)
                if !drafts[i].sent, !drafts[i].strokeIDs.isEmpty { shrunk.append((drafts[i].id, Array(drafts[i].strokeIDs))) }
            }
            drafts.removeAll { $0.strokeIDs.isEmpty }
            publish()
            for s in shrunk { Task { await self.finish(s.strokes, into: s.id) } }
        }
        let added = ids.filter { !known.contains($0) }
        guard !added.isEmpty else { return }
        known.formUnion(added)
        if let new = bounds(of: added) {
            // A stroke clearly away from the note being written closes it; this one starts or carries on another.
            if !group.isEmpty, !continues(Set(group), with: new, across: 5, down: 2.5) {
                let finished = group, into = reopened
                group = []
                reopened = nil
                Task { await self.finish(finished, into: into) }
            }
            // One thought, one note: a stroke beside a note not yet sent carries it on, however long the pause was, and
            // the note is read again whole.
            if group.isEmpty, let d = drafts.last(where: { !$0.sent && continues($0.strokeIDs, with: new) }) {
                reopened = d.id
                group = canvas.drawing.strokes.map(\.id).filter { d.strokeIDs.contains($0) && !added.contains($0) }
            }
        }
        group.append(contentsOf: added)
        groupTimer?.invalidate()
        // Long enough for a pause between words or lines; a squeeze or Send closes it at once.
        groupTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.finishGroup() }
        }
    }

    /// Whether a stroke at `new` carries on the handwriting made of these strokes, judged by the size of its letters.
    private func continues(_ ids: Set<UUID>, with new: CGRect, across: CGFloat = 3, down: CGFloat = 1.5) -> Bool {
        let rects = canvas.drawing.strokes.filter { ids.contains($0.id) }.map(\.renderBounds)
        guard let note = rects.reduce(nil, { $0?.union($1) ?? $1 }) else { return false }
        return InkGeometry.continues(note, letterHeight: InkGeometry.letterHeight(rects), with: new, across: across, down: down)
    }

    /// Close the note being drawn (after a pause, a squeeze, or before sending).
    func finishGroup() async {
        groupTimer?.invalidate()
        groupTimer = nil
        let ids = group, into = reopened
        group = []
        reopened = nil
        await finish(ids, into: into)
    }

    /// Make the strokes a note, or (`into`) the note they carry on, read again whole.
    private func finish(_ ids: [UUID], into reopened: String? = nil) async {
        finishing += 1
        defer {
            finishing -= 1
            showWaiting()
        }
        // A stroke belongs to one note; the one carried on keeps its own.
        let ids = ids.filter { id in !drafts.contains { $0.id != reopened && $0.strokeIDs.contains(id) } }
        let strokes = canvas.drawing.strokes.filter { ids.contains($0.id) }
        guard !strokes.isEmpty else { return }
        let points = strokes.map { s in s.path.interpolatedPoints(by: .distance(4)).map { $0.location.applying(s.transform) } }
        let shape = InkGeometry.classify(points)
        let textIDs = Set(shape.textStrokes.map { strokes[$0].id })
        var text: String?
        if !textIDs.isEmpty {
            // Only the strokes that are words, so a loop or an arrow beside them isn't read as letters.
            await recognizer.updateDrawing(canvas.drawing)
            text = await recognizer.recognizedText(strokeIDs: textIDs)
        }
        let anchors = page.anchors
        let note = InkTagger.note(id: reopened ?? UUID().uuidString, shape: shape, text: text, color: Self.colorName(strokes), anchors: anchors, diff: isDiff,
                                  letterHeight: InkGeometry.letterHeight(strokes.map(\.renderBounds)))
        let box = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        var tagged: [String: CGPoint] = [:]
        for e in note.elements ?? [] { if let a = anchors.first(where: { $0.id == e.id }) { tagged[e.id] = CGPoint(x: a.rect.midX, y: a.rect.midY) } }
        var draft = DraftNote(note: note, strokeIDs: Set(ids), bounds: box, tagged: tagged)
        let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty {
            // Snapped to the code at once; read by Apple Intelligence in a moment.
            let (about, names) = context(of: note, anchors: anchors)
            draft.raw = raw
            draft.note.text = InkSnap.snap(raw, to: names)
            if let reopened, let old = drafts.first(where: { $0.id == reopened }), old.chosen == true {
                draft.chosen = true
                draft.note.intent = old.note.intent
            }
            read(draft.id, raw: raw, about: about, names: names)
        }
        if let reopened, let i = drafts.firstIndex(where: { $0.id == reopened && !$0.sent }) {
            // The same note, grown: its chip catches up, with no second tap.
            drafts[i] = draft
        } else {
            drafts.append(draft)
            // On Apple Pencil Pro, a tap in the hand: the note is tagged.
            feedback.pathCompleted(at: convert(CGPoint(x: box.midX, y: box.midY), from: overlay))
        }
        publish()
    }

    // MARK: reading the handwriting

    /// What a note is about, for reading it: its code lines or elements in words, and the names in them.
    private func context(of note: InkNote, anchors: [InkAnchor]) -> (about: String?, names: [String]) {
        var parts: [String] = []
        for l in note.lines ?? [] { parts.append("line \(l.start): \(l.code?.prefix(160) ?? "")") }
        for e in note.elements ?? [] { parts.append(e.label ?? e.id) }
        let about = parts.isEmpty ? nil : parts.joined(separator: "; ")
        let names = InkSnap.identifiers(in: ((note.lines ?? []).compactMap(\.code) + (note.elements ?? []).map { $0.label ?? $0.id }).joined(separator: "\n"))
        return (about, names)
    }

    /// Reads a note's words on the device, then gives the note its reading, if it still says the same.
    private func read(_ id: String, raw: String, about: String?, names: [String]) {
        readings[id]?.cancel()
        readings[id] = Task { [weak self] in
            let reading = await HandwritingReader.read(raw, about: about, names: names)
            guard let self, !Task.isCancelled else { return }
            self.readings[id] = nil
            guard let i = self.drafts.firstIndex(where: { $0.id == id }), self.drafts[i].raw == raw, !self.drafts[i].sent else { return }
            let d = self.drafts[i]
            self.drafts[i].reading = reading
            self.drafts[i].note = HandwritingReader.apply(reading, to: d.note, color: InkColorName(rawValue: d.note.color ?? "") ?? .other, chosen: d.chosen == true)
            self.publish()
            // Under the Pencil now: the readout catches up, with a tap in the hand.
            if self.hoveredNote == id {
                self.showReading(self.drafts[i])
                self.feedback.alignmentOccurred(at: self.convert(CGPoint(x: d.bounds.midX, y: d.bounds.midY), from: self.overlay))
            }
        }
    }

    /// Waits (at most `within`) for these notes' readings.
    func settleReadings(_ ids: Set<String>, within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline, readings.keys.contains(where: ids.contains) {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    private func showReading(_ d: DraftNote) {
        let text = d.reading?.summary ?? (readings[d.id] != nil ? "Reading “\(d.note.text ?? "")”…" : "Reads: \(d.note.text ?? "") · \(NoteDisplay(d.note).verb)")
        hoverLabel.apply(text: text, symbol: d.reading?.byModel == true ? "apple.intelligence" : "pencil.and.scribble", tint: UIColor(NoteDisplay(d.note).tint))
        hoverSize = hoverLabel.sizeThatFits(CGSize(width: 300, height: 60))
    }

    /// The note (not yet sent) whose ink is at this point.
    private func note(at p: CGPoint) -> DraftNote? {
        drafts.last { !$0.sent && $0.bounds.insetBy(dx: -10, dy: -10).contains(p) }
    }

    /// Ink color picks the intent of plain notes: red to change, blue to ask, green for "looks right".
    static func colorName(_ strokes: [PKStroke]) -> InkColorName {
        var counts: [InkColorName: Int] = [:]
        for s in strokes {
            var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            s.ink.color.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
            let name: InkColorName = sat < 0.35 || b < 0.25 ? .other : (h < 0.06 || h > 0.92) ? .red : (0.22...0.45).contains(h) ? .green : (0.5...0.75).contains(h) ? .blue : .other
            counts[name, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? .other
    }

    private func bounds(of ids: [UUID]) -> CGRect? {
        guard !ids.isEmpty else { return nil }
        let r = canvas.drawing.strokes.filter { ids.contains($0.id) }.reduce(CGRect.null) { $0.union($1.renderBounds) }
        return r.isNull ? nil : r
    }

    // MARK: drafts in from SwiftUI (edits, deletions, sent)

    func setDrafts(_ new: [DraftNote]) {
        let gone = Set(drafts.map(\.id)).subtracting(new.map(\.id))
        if !gone.isEmpty {
            // A deleted note's ink goes with it, but never ink another note still uses.
            let kept = new.reduce(into: Set<UUID>()) { $0.formUnion($1.strokeIDs) }
            let strokeIDs = drafts.filter { gone.contains($0.id) }.reduce(into: Set<UUID>()) { $0.formUnion($1.strokeIDs) }.subtracting(kept)
            var d = canvas.drawing
            d.strokes.removeAll { strokeIDs.contains($0.id) }
            known.subtract(strokeIDs)
            drafts = new
            canvas.drawing = d
        }
        drafts = new
        redraw()
        save()
    }

    private func publish() {
        redraw()
        save()
        onDrafts?(drafts)
    }

    // MARK: drawing what's tagged

    private func redraw() {
        let path = UIBezierPath()
        let anchors = page.anchors
        for d in drafts where !d.sent {
            let from = CGPoint(x: d.bounds.midX, y: d.bounds.midY)
            for e in d.note.elements ?? [] {
                guard let a = anchors.first(where: { $0.id == e.id }) else { continue }
                let to = CGPoint(x: a.rect.midX, y: a.rect.midY)
                path.move(to: from)
                path.addLine(to: to)
                path.append(UIBezierPath(ovalIn: CGRect(x: to.x - 3, y: to.y - 3, width: 6, height: 6)))
            }
            for l in d.note.lines ?? [] {
                guard let a = anchors.first(where: { $0.file == l.file && $0.line == l.start }) else { continue }
                path.move(to: from)
                path.addLine(to: CGPoint(x: min(from.x, a.rect.maxX * 0.66), y: a.rect.midY))
            }
        }
        tethers.path = path.cgPath
        tethers.strokeColor = UIColor.tintColor.withAlphaComponent(0.55).cgColor
        let inv = 1 / max(pageScroll.zoomScale, 0.01)
        tethers.lineWidth = 2 * inv
        tethers.lineDashPattern = [NSNumber(value: Double(5 * inv)), NSNumber(value: Double(4 * inv))]
        found.lineWidth = 2 * inv
        // One chip per note, beside its ink, clear of the chips placed before it.
        let live = Set(drafts.map(\.id))
        for (id, chip) in chips where !live.contains(id) { chip.removeFromSuperview(); chips[id] = nil }
        var placed: [CGRect] = []
        // The page's own cards (a note's answer, a diagram's peek) stay readable: chips go around them. And no chip ever
        // covers writing, its own or another note's: on a narrow page (the side panel) keeping a chip on the page used
        // to slide it back onto the ink, and the writing seemed to vanish.
        let cards = page.noteCards.map(\.rect) + page.diagramCards.map(\.rect)
        let inks = drafts.map(\.bounds)
        for d in drafts {
            let chip = chips[d.id] ?? {
                let c = PaddedLabel()
                c.contentScaleFactor = (window?.screen.scale ?? 2) * sharpZoom
                overlay.addSubview(c)
                chips[d.id] = c
                return c
            }()
            chip.apply(NoteDisplay(d.note), sent: d.sent)
            // Laid out in screen points, then placed in page coordinates and scaled back down by the zoom.
            let screen = chip.sizeThatFits(CGSize(width: 260, height: 60))
            let size = CGSize(width: screen.width * inv, height: screen.height * inv)
            let ink = d.bounds
            // Above the ink to its right, as before; else beside it on the right, above it on the left, under it, and
            // only then on its left (where it would likely cover what the note is about): the first that's clear of
            // cards, other chips and all ink. Failing those, under the ink, moving down until clear (never back up over
            // the writing).
            let below = CGPoint(x: ink.minX, y: ink.maxY + 5 * inv)
            let spots = [CGPoint(x: ink.maxX + 6 * inv, y: ink.minY - size.height - 5 * inv), CGPoint(x: ink.maxX + 6 * inv, y: ink.midY - size.height / 2),
                         CGPoint(x: ink.minX, y: ink.minY - size.height - 5 * inv), below, CGPoint(x: ink.maxX - size.width, y: ink.maxY + 5 * inv),
                         CGPoint(x: ink.minX - size.width - 6 * inv, y: ink.midY - size.height / 2)]
                .map { CGRect(x: max(4 * inv, min($0.x, overlay.bounds.width - size.width - 4 * inv)), y: max(4 * inv, $0.y), width: size.width, height: size.height) }
            // Cards and chips get a little room; ink just mustn't be touched.
            let clear = { (r: CGRect) in
                !(cards + placed).contains { $0.intersects(r.insetBy(dx: -3 * inv, dy: -3 * inv)) } && !inks.contains { $0.intersects(r.insetBy(dx: -1 * inv, dy: -1 * inv)) }
            }
            var frame = spots.first(where: clear) ?? spots[3]
            for _ in 0..<12 where !clear(frame) { frame.origin.y += size.height + 4 * inv }
            placed.append(frame)
            chip.place(in: frame, screenSize: screen, scale: inv)
        }
    }

    // MARK: Apple Pencil Pro: hover, squeeze; fingers: tap to pick

    private func anchor(at p: CGPoint) -> InkAnchor? {
        page.anchors.filter { $0.rect.insetBy(dx: -4, dy: -4).contains(p) }.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }

    @objc private func hovering(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            let now = CACurrentMediaTime()
            // Only when the tip is close (a hand high above the glass shouldn't light things up), and never while writing:
            // the note being written, or a stroke just now.
            guard g.zOffset < 0.7, group.isEmpty, now - lastInk > 0.6 else {
                hoverSince = nil
                return clearHover()
            }
            // And once the tip lingers, not as it comes down to write.
            let since = hoverSince ?? now
            hoverSince = since
            guard now - since > 0.25 else { return }
            let p = g.location(in: overlay)
            let inv = 1 / max(pageScroll.zoomScale, 0.01)
            // Over a note's ink: what Duet read it as.
            if let d = note(at: p) {
                if hovered != nil { page.highlight(nil, "duet-hot"); hovered = nil }
                if hoveredNote != d.id {
                    hoveredNote = d.id
                    showReading(d)
                }
                let size = CGSize(width: hoverSize.width * inv, height: hoverSize.height * inv)
                let frame = CGRect(x: min(p.x + 14 * inv, overlay.bounds.width - size.width - 4 * inv), y: max(4 * inv, p.y - size.height - 14 * inv), width: size.width, height: size.height)
                hoverLabel.place(in: frame, screenSize: hoverSize, scale: inv)
                hoverLabel.isHidden = false
                return
            }
            if hoveredNote != nil { hoveredNote = nil; hovered = nil }
            let hit = anchor(at: p)
            if hit?.id != hovered {
                hovered = hit?.id
                page.highlight(hit?.id, "duet-hot")
                if let hit {
                    // A tick in the hand as the tip crosses onto an element.
                    feedback.alignmentOccurred(at: g.location(in: self))
                    let count = drafts.filter { d in
                        (d.note.elements ?? []).contains { $0.id == hit.id }
                            || (d.note.lines ?? []).contains { l in l.file == hit.file && (hit.line.map { l.start <= $0 && $0 <= l.end } ?? false) }
                    }.count
                    hoverLabel.apply(text: count > 0 ? "\(hit.label) · \(count) note\(count == 1 ? "" : "s")" : hit.label, symbol: isDiff ? "text.line.first.and.arrowtriangle.forward" : "scope", tint: .systemOrange)
                    hoverSize = hoverLabel.sizeThatFits(CGSize(width: 280, height: 40))
                }
            }
            guard hit != nil else {
                hoverLabel.isHidden = true
                return
            }
            let size = CGSize(width: hoverSize.width * inv, height: hoverSize.height * inv)
            let frame = CGRect(x: min(p.x + 14 * inv, overlay.bounds.width - size.width - 4 * inv), y: max(4 * inv, p.y - size.height - 14 * inv), width: size.width, height: size.height)
            hoverLabel.place(in: frame, screenSize: hoverSize, scale: inv)
            hoverLabel.isHidden = false
        default:
            hoverSince = nil
            clearHover()
        }
    }

    private func clearHover() {
        if hovered != nil { page.highlight(nil, "duet-hot") }
        hovered = nil
        hoveredNote = nil
        hoverLabel.isHidden = true
    }

    /// Double tap: zoom in around the spot, or back out if already zoomed.
    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        let sv = pageScroll
        if sv.zoomScale > sv.minimumZoomScale * 1.05 {
            sv.setZoomScale(sv.minimumZoomScale, animated: true)
        } else {
            let p = g.location(in: overlay), w = overlay.bounds.width / 2.5, h = bounds.height / sv.zoomScale / 2.5
            sv.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
        }
    }

    /// Whether a point is on a note's bubble (the gutter of a line with notes), or a diagram's card or mark.
    private func onMark(_ p: CGPoint) -> Bool {
        if page.noteCards.contains(where: { $0.rect.contains(p) }) { return true }
        if page.diagramCards.contains(where: { $0.rect.contains(p) }) { return true }
        guard p.x < 62, let line = anchor(at: p)?.line else { return false }
        return page.marks[line] != nil
    }

    // Taps on a bubble win over the canvas's drawing (it would take a finger as ink when fingers draw).
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other === canvas.drawingGestureRecognizer && onMark(g.location(in: overlay))
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: overlay)
        let now = CACurrentMediaTime()
        defer { lastTap = (now, p) }
        if SpeedSwitches.on("taps"), let last = lastTap, now - last.time < 0.35, hypot(p.x - last.at.x, p.y - last.at.y) < 30 { return }
        // A note's card under its line: open the note.
        if let card = page.noteCards.first(where: { $0.rect.contains(p) }) {
            page.onMark?(card.ids)
            return
        }
        // A diagram's mark, element chip or card: open the diagram, with that element picked.
        if let d = page.diagramCards.first(where: { $0.rect.contains(p) }) {
            page.onDiagram?(d.diagram, d.element)
            return
        }
        let hit = anchor(at: p)
        // A note's bubble in the gutter: open the note.
        if let line = hit?.line, p.x < 62, let mark = page.marks[line] {
            page.onMark?(mark.ids)
            return
        }
        page.highlight(hit?.id, "duet-sel")
        onSelect?(hit)
    }

    /// A squeeze while hovering a note opens its palette (what it means, or send); anywhere else it sends the notes.
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        let at = squeeze.hoverPose.map { $0.location } ?? CGPoint(x: bounds.midX, y: bounds.midY)
        feedback.alignmentOccurred(at: at)
        if squeeze.hoverPose != nil, group.isEmpty, let d = note(at: convert(at, to: overlay)) {
            palette(for: d.id, at: at)
            return
        }
        // Nothing to send: the Pencil palette comes out (or goes away), as a squeeze does elsewhere on iPad.
        if group.isEmpty, !drafts.contains(where: { !$0.sent }) {
            toggleTools()
            return
        }
        Task {
            await finishGroup()
            onSqueeze?()
        }
    }

    /// Ask / Change / Comment / Looks right for one note, or Send them all, beside the Pencil.
    private func palette(for id: String, at point: CGPoint) {
        guard let d = drafts.first(where: { $0.id == id }), var host = window?.rootViewController else { return }
        while let shown = host.presentedViewController { host = shown }
        clearHover()
        let sheet = UIAlertController(title: d.reading.map { $0.text } ?? d.note.text, message: nil, preferredStyle: .actionSheet)
        let choices: [(String, InkIntent)] = [("Ask", .question), ("Change", .change), ("Comment", .comment), ("Looks Right", .approve)]
        for (title, intent) in choices {
            sheet.addAction(UIAlertAction(title: d.note.intent == intent ? "✓ " + title : title, style: .default) { [weak self] _ in self?.choose(intent, for: id) })
        }
        sheet.addAction(UIAlertAction(title: "Send Notes", style: .default) { [weak self] _ in
            Task { await self?.finishGroup(); self?.onSqueeze?() }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = self
        sheet.popoverPresentationController?.sourceRect = CGRect(origin: point, size: .zero).insetBy(dx: -4, dy: -4)
        host.present(sheet, animated: true)
    }

    private func choose(_ intent: InkIntent, for id: String) {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[i].note.intent = intent
        drafts[i].chosen = true
        publish()
    }

    // MARK: search your handwriting

    func search(_ query: String) {
        guard query != lastSearch else { return }
        lastSearch = query
        searchTask?.cancel()
        guard query.count >= 2 else { found.path = nil; return }
        let drawing = canvas.drawing
        searchTask = Task { [weak self] in
            guard let self else { return }
            await recognizer.updateDrawing(drawing)
            let found = await inkSearch(recognizer, query)
            guard !Task.isCancelled else { return }
            let path = UIBezierPath()
            for r in found { path.append(UIBezierPath(roundedRect: r.insetBy(dx: -6, dy: -4), cornerRadius: 6)) }
            self.found.path = path.cgPath
            if let first = found.first { pageScroll.scrollRectToVisible(overlay.convert(first.insetBy(dx: -60, dy: -120), to: pageScroll), animated: true) }
        }
    }

    /// One note's handwriting as a small PNG (base64): dark ink on clear, readable on any device.
    func inkPNG(_ d: DraftNote) -> String? {
        let strokes = canvas.drawing.strokes.filter { d.strokeIDs.contains($0.id) }
        guard !strokes.isEmpty else { return nil }
        let rect = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }.insetBy(dx: -6, dy: -6)
        let scale = min(2, 640 / max(rect.width, rect.height, 1))
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = PKDrawing(strokes: strokes).image(from: rect, scale: scale)
        }
        return image?.pngData()?.base64EncodedString()
    }

    // MARK: the note's picture: the page with the ink on it (around the notes, for a long diff)

    func snapshot() async -> UIImage? {
        let ink = drafts.filter { !$0.sent }.reduce(CGRect.null) { $0.union($1.bounds) }
        var rect = overlay.bounds
        if rect.height > 2200, !ink.isNull { rect = ink.insetBy(dx: 0, dy: -260).intersection(overlay.bounds); rect.origin.x = 0; rect.size.width = overlay.bounds.width }
        // The snapshot is taken in the web view's own coordinates: zoomed and scrolled.
        guard let page = await page.snapshot(overlay.convert(rect, to: page.web)) else { return nil }
        let drawing = canvas.drawing.image(from: rect, scale: 1)
        let scale = min(1, 1600 / max(rect.width, 1))
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.systemBackground.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            page.draw(in: CGRect(origin: .zero, size: size))
            drawing.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: keeping the ink

    private struct Saved: Codable { var drawing: Data; var drafts: [DraftNote] }

    private var file: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appending(path: "Ink")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(key.replacingOccurrences(of: "/", with: "_")).json")
    }

    private func restore() {
        guard let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data), let drawing = try? PKDrawing(data: saved.drawing) else { return }
        // Known first: setting the drawing calls the delegate, which would take these strokes for new ink.
        known = Set(drawing.strokes.map(\.id))
        drafts = saved.drafts
        canvas.drawing = drawing
    }

    private func save() {
        saveTask?.cancel()
        let saved = Saved(drawing: canvas.drawing.dataRepresentation(), drafts: drafts)
        let file = file
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let file, let data = try? JSONEncoder().encode(saved) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}

/// Where the query appears in the handwriting. Runs on the recognizer's actor, so its results (not Sendable) become
/// plain rectangles before they cross back to the main actor.
private func inkSearch(_ recognizer: isolated PKStrokeRecognizer, _ query: String) async -> [CGRect] {
    await recognizer.search(query).map(\.bounds)
}

/// A small rounded label with an SF Symbol: note chips and the hover readout.
final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    func apply(_ d: NoteDisplay, sent: Bool) {
        apply(text: d.pageChip, symbol: sent ? "paperplane.fill" : d.symbol, tint: sent ? .secondaryLabel : UIColor(d.tint))
        alpha = sent ? 0.6 : 1
    }

    func apply(text: String, symbol: String, tint: UIColor) {
        let s = NSMutableAttributedString()
        if let image = UIImage(systemName: symbol)?.withTintColor(tint, renderingMode: .alwaysOriginal) {
            s.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            s.append(NSAttributedString(string: " "))
        }
        s.append(NSAttributedString(string: text, attributes: [.foregroundColor: UIColor.label]))
        attributedText = s
        font = .preferredFont(forTextStyle: .caption1)
        numberOfLines = 2
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.95)
        layer.cornerRadius = 9
        layer.masksToBounds = true
        layer.borderColor = tint.withAlphaComponent(0.6).cgColor
        layer.borderWidth = 1
    }

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }

    /// Shown at `screenSize` points whatever the zoom: laid out at that size, then scaled by `scale` into `frame`.
    func place(in frame: CGRect, screenSize: CGSize, scale: CGFloat) {
        transform = .identity
        bounds = CGRect(origin: .zero, size: screenSize)
        layer.anchorPoint = .zero
        layer.position = frame.origin
        transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let s = super.sizeThatFits(CGSize(width: size.width - insets.left - insets.right, height: size.height))
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }
}
#endif
