#if os(iOS)
import DuetKit
import PencilKit
import UIKit

/// Strokes into notes on a canvas that is the page: one thought, one note (grouped by a pause and by place), its words
/// read on the device, tagged to the lines under it, and kept in step with erasing, the lasso and undo. The same rules
/// as `InkSurfaceView`'s, which still serves diagrams and diffs. Nothing here runs while a stroke is being drawn: the
/// canvas tells it of a stroke once the Pencil lifts.
@MainActor
final class InkNoteTaker {
    private unowned let canvas: PKCanvasView
    private let recognizer = PKStrokeRecognizer()
    /// What a note can be tagged to, now.
    var anchors: () -> [InkAnchor] = { [] }
    /// The notes changed (one closed, read, erased or edited).
    var onChange: (() -> Void)?
    /// A note was tagged: a tap in the hand on Apple Pencil Pro, at this place on the page.
    var onTagged: ((CGPoint) -> Void)?
    private(set) var drafts: [DraftNote] = []
    private var known: Set<UUID> = []
    private var group: [UUID] = []
    /// The note the strokes being written carry on: one closed but not sent, opened again to be read whole.
    private var reopened: String?
    private var groupTimer: Timer?
    private var readings: [String: Task<Void, Never>] = [:]
    private var finishing = 0

    init(canvas: PKCanvasView) { self.canvas = canvas }

    /// A note is being written or worked out: the page shouldn't change under it.
    var busy: Bool { !group.isEmpty || finishing > 0 }

    /// Show a page's ink and notes. Its strokes are known first, so the canvas's news of them isn't taken for new ink.
    func load(_ drawing: PKDrawing, drafts: [DraftNote]) {
        groupTimer?.invalidate()
        groupTimer = nil
        group = []
        reopened = nil
        for r in readings.values { r.cancel() }
        readings = [:]
        known = Set(drawing.strokes.map(\.id))
        self.drafts = drafts
        canvas.drawing = drawing
    }

    /// The canvas's drawing changed: a stroke added, erased, moved by the lasso, or undone.
    func drawingChanged() {
        let ids = canvas.drawing.strokes.map(\.id)
        let now = Set(ids)
        // Erasing a note's strokes erases the note. One that loses only some (part rubbed out, Undo taking back a
        // stroke, the lasso moving some away: a moved stroke has a new id) is read again from what's left.
        let gone = known.subtracting(now)
        if !gone.isEmpty {
            known.subtract(gone)
            group.removeAll { gone.contains($0) }
            var shrunk: [(id: String, strokes: [UUID])] = []
            for i in drafts.indices where !drafts[i].strokeIDs.isDisjoint(with: gone) {
                drafts[i].strokeIDs.subtract(gone)
                if !drafts[i].sent, !drafts[i].strokeIDs.isEmpty { shrunk.append((drafts[i].id, Array(drafts[i].strokeIDs))) }
            }
            drafts.removeAll { $0.strokeIDs.isEmpty }
            onChange?()
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
            // A stroke beside a note not yet sent carries it on, however long the pause, and it's read again whole.
            if group.isEmpty, let d = drafts.last(where: { !$0.sent && continues($0.strokeIDs, with: new) }) {
                reopened = d.id
                group = ids.filter { d.strokeIDs.contains($0) && !added.contains($0) }
            }
        }
        group.append(contentsOf: added)
        groupTimer?.invalidate()
        // Long enough for a pause between words or lines; Send closes it at once.
        groupTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.finishGroup() }
        }
    }

    /// Close the note being written (after a pause, or before sending).
    func finishGroup() async {
        groupTimer?.invalidate()
        groupTimer = nil
        let ids = group, into = reopened
        group = []
        reopened = nil
        await finish(ids, into: into)
    }

    /// Where a note's tagged line was when it was last placed (its top, in `DraftNote.tagged`), so its ink can follow.
    nonisolated static let lineKey = "line"

    /// The page was laid out again (the file changed under its notes, the paper's width or the text size did): each
    /// note's lines are found again by their code, and its ink moves to where its first line is now. Notes whose code
    /// is gone stay where they were. Whether anything moved.
    @discardableResult
    func follow(_ text: String, geometry g: CodePageGeometry) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var drawing = canvas.drawing
        var renamed: [UUID: UUID] = [:]
        for i in drafts.indices {
            guard let tagged = drafts[i].note.lines, let first = tagged.first, let now = Reanchor.place(first, in: lines) else { continue }
            let shift = now.lowerBound - first.start
            // Placed before lines could wrap: its line was a plain row then.
            let was = drafts[i].tagged?[Self.lineKey]?.y ?? g.top + CGFloat(first.start - 1) * g.lineHeight
            let top = g.rect(line: now.lowerBound, width: 0).minY
            drafts[i].tagged = [Self.lineKey: CGPoint(x: 0, y: top)]
            if shift != 0 { drafts[i].note.lines = tagged.map { InkLines(file: $0.file, start: $0.start + shift, end: $0.end + shift, code: $0.code) } }
            guard abs(top - was) > 0.5 else { continue }
            let t = CGAffineTransform(translationX: 0, y: top - was)
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
        guard !renamed.isEmpty else { return false }
        // Known before the canvas hears of them, so they aren't taken for new ink.
        known.subtract(renamed.keys)
        known.formUnion(renamed.values)
        canvas.drawing = drawing
        return true
    }

    /// Notes edited or removed from SwiftUI (the tray). A deleted note's ink goes with it, unless another note uses it.
    func setDrafts(_ new: [DraftNote]) {
        let gone = Set(drafts.map(\.id)).subtracting(new.map(\.id))
        if !gone.isEmpty {
            let kept = new.reduce(into: Set<UUID>()) { $0.formUnion($1.strokeIDs) }
            let strokeIDs = drafts.filter { gone.contains($0.id) }.reduce(into: Set<UUID>()) { $0.formUnion($1.strokeIDs) }.subtracting(kept)
            var d = canvas.drawing
            d.strokes.removeAll { strokeIDs.contains($0.id) }
            known.subtract(strokeIDs)
            drafts = new
            canvas.drawing = d
        }
        drafts = new
    }

    /// Waits (at most `within`) for these notes' readings.
    func settleReadings(_ ids: Set<String>, within limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline, readings.keys.contains(where: ids.contains) {
            try? await Task.sleep(for: .milliseconds(30))
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

    // MARK: making a note

    private func finish(_ ids: [UUID], into reopened: String? = nil) async {
        finishing += 1
        defer { finishing -= 1 }
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
        let anchors = anchors()
        let note = InkTagger.note(id: reopened ?? UUID().uuidString, shape: shape, text: text, color: InkSurfaceView.colorName(strokes), anchors: anchors,
                                  diff: true, letterHeight: InkGeometry.letterHeight(strokes.map(\.renderBounds)))
        let box = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        var draft = DraftNote(note: note, strokeIDs: Set(ids), bounds: box)
        // Where its line is, so its ink can follow it when the page is laid out again.
        if let line = note.lines?.first?.start, let a = anchors.first(where: { $0.line == line }) { draft.tagged = [Self.lineKey: CGPoint(x: 0, y: a.rect.minY)] }
        let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty {
            // Snapped to the code at once; read by Apple Intelligence in a moment.
            let (about, names) = Self.context(of: note)
            draft.raw = raw
            draft.note.text = InkSnap.snap(raw, to: names)
            if let reopened, let old = drafts.first(where: { $0.id == reopened }), old.chosen == true {
                draft.chosen = true
                draft.note.intent = old.note.intent
            }
            read(draft.id, raw: raw, about: about, names: names)
        }
        if let reopened, let i = drafts.firstIndex(where: { $0.id == reopened && !$0.sent }) {
            drafts[i] = draft
        } else {
            drafts.append(draft)
            onTagged?(CGPoint(x: box.midX, y: box.midY))
        }
        onChange?()
    }

    /// What a note is about, for reading it: its code lines in words, and the names in them.
    private static func context(of note: InkNote) -> (about: String?, names: [String]) {
        var parts: [String] = []
        for l in note.lines ?? [] { parts.append("line \(l.start): \(l.code?.prefix(160) ?? "")") }
        let about = parts.isEmpty ? nil : parts.joined(separator: "; ")
        return (about, InkSnap.identifiers(in: (note.lines ?? []).compactMap(\.code).joined(separator: "\n")))
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
            self.onChange?()
        }
    }

    private func continues(_ ids: Set<UUID>, with new: CGRect, across: CGFloat = 3, down: CGFloat = 1.5) -> Bool {
        let rects = canvas.drawing.strokes.filter { ids.contains($0.id) }.map(\.renderBounds)
        guard let note = rects.reduce(nil, { $0?.union($1) ?? $1 }) else { return false }
        return InkGeometry.continues(note, letterHeight: InkGeometry.letterHeight(rects), with: new, across: across, down: down)
    }

    private func bounds(of ids: [UUID]) -> CGRect? {
        guard !ids.isEmpty else { return nil }
        let set = Set(ids)
        let r = canvas.drawing.strokes.filter { set.contains($0.id) }.reduce(CGRect.null) { $0.union($1.renderBounds) }
        return r.isNull ? nil : r
    }
}
#endif
