#if os(iOS)
import DuetKit
import UIKit

/// What a code page shows beside its code: the lines changed since the last commit and where lines were removed, the
/// kept notes on its lines (a bubble in the gutter, a card for each one not yet resolved), and the diagrams that
/// explain it (a stripe, a ◆ on each element's line, a card).
struct CodePageDecor: Equatable {
    var changed: Set<Int> = []
    var removedAfter: Set<Int> = []
    var marks: [Int: LineMark] = [:]
    var peeks: [DiagramPeek] = []

    var hasCards: Bool { !peeks.isEmpty || marks.values.contains { !$0.cards.isEmpty } }
}

/// Something on the page a finger can tap, in page coordinates.
enum CodePageHit: Equatable {
    case notes([String])
    case diagram(String, element: String?)
    /// A line's notes, folded: open (or close) its history.
    case history(Int)
    /// A question asked a moment ago: take it back.
    case cancel(String)
}

/// The decorations, drawn into the code view (so they zoom and scroll with it): tints and stripes under the text, bubbles,
/// marks and cards over it, all under the ink. Static while the Pencil is down; laid out again only when the page
/// changes or a pinch ends.
@MainActor
final class CodeDecorations {
    static let cardWidth: CGFloat = 280
    static let cardGap: CGFloat = 16

    private let under = CALayer()
    /// What each note's mark was snapped to: drawn behind the ink, so the mark is confirmed without asking.
    private let snaps = CAShapeLayer()
    private let shownSnaps = CAShapeLayer()
    /// Bubbles and pills of notes being answered, pulsing.
    private var pulsing: [CALayer] = []
    private let selection = CAShapeLayer()
    private var views: [UIView] = []
    private(set) var hits: [(rect: CGRect, hit: CodePageHit)] = []

    init(in code: UIView) {
        under.anchorPoint = .zero
        code.layer.insertSublayer(under, at: 0)
        // Over the code's tints, under its text and the ink.
        for l in [snaps, shownSnaps] { l.fillColor = UIColor.clear.cgColor; code.layer.insertSublayer(l, above: under) }
        selection.fillColor = UIColor.clear.cgColor
        selection.strokeColor = UIColor.systemBlue.withAlphaComponent(0.95).cgColor
        selection.lineWidth = 2
        code.layer.addSublayer(selection)
    }

    /// Where the cards' column starts: after the code, or at the page's right edge when there's room.
    static func cardsX(_ g: CodePageGeometry, pageWidth: CGFloat) -> CGFloat {
        let codeEnd = g.codeX + CGFloat(min(g.columns, g.paper)) * g.advance + cardGap
        return max(codeEnd, pageWidth - cardWidth - cardGap)
    }

    func lay(_ d: CodePageDecor, cards showsCards: Bool, open: Int?, snapped: [(rects: [CGRect], shown: Bool)] = [], cancellable: Set<String> = [],
             geometry g: CodePageGeometry, pageWidth width: CGFloat, zoom z: CGFloat, in code: UIView) {
        under.sublayers = nil
        pulsing = []
        // A quiet outline around what each mark picked out; a fallback (the nearest line) is shown plainly, tinted,
        // since it's a guess.
        let quiet = UIBezierPath(), plain = UIBezierPath()
        for s in snapped {
            for r in s.rects {
                let box = CGRect(x: r.minX * z - 2, y: r.minY * z + 1, width: r.width * z + 4, height: r.height * z - 2)
                (s.shown ? plain : quiet).append(UIBezierPath(roundedRect: box, cornerRadius: 4 * z))
            }
        }
        snaps.path = quiet.cgPath
        snaps.strokeColor = UIColor.systemBlue.withAlphaComponent(0.35).cgColor
        snaps.lineWidth = 1.5 * z
        shownSnaps.path = plain.cgPath
        shownSnaps.strokeColor = UIColor.systemOrange.withAlphaComponent(0.8).cgColor
        shownSnaps.fillColor = UIColor.systemOrange.withAlphaComponent(0.1).cgColor
        shownSnaps.lineWidth = 2 * z
        for v in views { v.removeFromSuperview() }
        views = []
        hits = []
        let dark = code.traitCollection.userInterfaceStyle == .dark
        func band(_ r: CGRect, _ color: UIColor) {
            let l = CALayer()
            l.frame = CGRect(x: r.minX * z, y: r.minY * z, width: r.width * z, height: r.height * z)
            l.backgroundColor = color.cgColor
            under.addSublayer(l)
        }
        // A wrapped line's rows read as one line: a faint band across them, and a bar joining them beside the code.
        for n in g.wrapped.keys {
            let r = g.rect(line: n, width: width)
            band(r, UIColor.label.withAlphaComponent(dark ? 0.06 : 0.035))
            band(CGRect(x: g.codeX - 3, y: r.minY + 3, width: 2, height: r.height - 6), UIColor.tertiaryLabel)
        }
        let green = UIColor(red: 0x2d / 255, green: 0xa4 / 255, blue: 0x4e / 255, alpha: 1)
        for n in d.changed where n <= g.lineCount {
            let r = g.rect(line: n, width: width)
            band(r, dark ? UIColor(red: 0x12 / 255, green: 0x39 / 255, blue: 0x1e / 255, alpha: 1) : UIColor(red: 0xe6 / 255, green: 1, blue: 0xec / 255, alpha: 1))
            band(CGRect(x: 0, y: r.minY, width: 3, height: r.height), green)
        }
        for n in d.removedAfter where n <= g.lineCount {
            let r = g.rect(line: n, width: width)
            band(CGRect(x: 0, y: r.maxY - 2, width: width, height: 2), .systemRed)
        }
        let purple = UIColor(red: 0x8b / 255, green: 0x5c / 255, blue: 0xf6 / 255, alpha: 1)
        for n in d.peeks.reduce(into: Set<Int>(), { $0.formUnion($1.lines) }) where n <= g.lineCount {
            band(CGRect(x: g.codeX - 6, y: g.rect(line: n, width: width).minY, width: 2, height: g.lineHeight), purple.withAlphaComponent(0.75))
        }

        // In the gutter, before the number: a note's bubble, else a diagram element's ◆.
        let elementAt = Dictionary(d.peeks.flatMap { p in p.elements.map { ($0.line, (p, $0)) } }, uniquingKeysWith: { a, _ in a })
        for n in Set(d.marks.keys).union(elementAt.keys) where n <= g.lineCount {
            let r = g.rect(line: n, width: width)
            let box = CGRect(x: 3, y: r.minY + 2, width: 18, height: 16)
            if let m = d.marks[n] {
                let badge = Badge(state: m.state, count: m.ids.count)
                add(badge, box, z, in: code)
                if m.answering { pulse(badge.layer) }
                hits.append((box.insetBy(dx: -6, dy: -2), .history(n)))
            } else if let (p, e) = elementAt[n] {
                let mark = UILabel()
                mark.text = "◆"
                mark.font = .systemFont(ofSize: 10 * z)
                mark.textColor = purple
                add(mark, box, z, in: code)
                hits.append((box.insetBy(dx: -6, dy: -2), .diagram(p.id, element: e.id)))
            }
        }

        // Beside the code, on a wide page: each line's notes and diagrams folded to one pill, level with the line, so
        // they never take more than its row. A tap on a pill (or a bubble) opens the line's history under it.
        let x = Self.cardsX(g, pageWidth: width)
        if showsCards {
            for p in d.peeks where p.line <= g.lineCount {
                let r = g.rect(line: p.line, width: width)
                let pill = Pill(text: "◆ " + p.title, accent: purple)
                let f = CGRect(x: x, y: r.minY + 2, width: min(Self.cardWidth, pill.width), height: g.lineHeight - 4)
                add(pill, f, z, in: code)
                hits.append((f, .diagram(p.id, element: nil)))
            }
            for (n, m) in d.marks where n <= g.lineCount && !m.history.isEmpty && !d.peeks.contains(where: { $0.line == n }) {
                let r = g.rect(line: n, width: width)
                let pill = Pill(history: m.history, state: m.state)
                let f = CGRect(x: x, y: r.minY + 2, width: min(Self.cardWidth, pill.width), height: g.lineHeight - 4)
                add(pill, f, z, in: code)
                if m.answering { pulse(pill.layer) }
                hits.append((f, .history(n)))
            }
        }
        // The open line's history: every question asked on it, newest first, under the line, over what's below it.
        if let n = open, n <= g.lineCount, let m = d.marks[n], !m.history.isEmpty {
            let line = g.rect(line: n, width: width)
            let w = showsCards ? Self.cardWidth : min(420, width - g.codeX - g.right)
            let takeBack = m.history.last { cancellable.contains($0.id) }?.id
            let card = HistoryCard(m.history.reversed(), takeBack: takeBack != nil, dark: dark)
            let f = CGRect(x: showsCards ? x : g.codeX, y: line.maxY + 2, width: w, height: card.height(width: w))
            add(card, f, z, in: code)
            for (id, r) in card.rows(width: w) { hits.append((r.offsetBy(dx: f.minX, dy: f.minY), .notes([id]))) }
            hits.append((CGRect(x: f.minX, y: f.maxY - HistoryCard.footer, width: w / 2, height: HistoryCard.footer), .notes(m.ids)))
            if let takeBack { hits.append((CGRect(x: f.minX + w / 2, y: f.maxY - HistoryCard.footer, width: w / 2, height: HistoryCard.footer), .cancel(takeBack))) }
        }
    }

    /// A gentle pulse (Core Animation, at most 30 frames a second) while a note is being answered.
    private func pulse(_ layer: CALayer) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0.35
        a.duration = 0.9
        a.autoreverses = true
        a.repeatCount = .infinity
        a.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: 30)
        layer.add(a, forKey: "answering")
        pulsing.append(layer)
    }

    /// Held still while the Pencil is down (nothing moves near the writing), and going again after.
    func pausePulses(_ paused: Bool) {
        for l in pulsing {
            if paused, l.speed != 0 {
                l.timeOffset = l.convertTime(CACurrentMediaTime(), from: nil)
                l.speed = 0
            } else if !paused, l.speed == 0 {
                let t = l.timeOffset
                l.speed = 1
                l.timeOffset = 0
                l.beginTime = 0
                l.beginTime = l.convertTime(CACurrentMediaTime(), from: nil) - t
            }
        }
    }

    /// The page's height with its cards: they may run past the last line.
    func bottom() -> CGFloat { hits.map(\.rect.maxY).max() ?? 0 }

    func hit(at p: CGPoint) -> CodePageHit? { hits.last { $0.rect.contains(p) }?.hit }

    /// The picked line's outline (nil: none).
    func select(_ r: CGRect?, zoom z: CGFloat) {
        selection.path = r.map { UIBezierPath(rect: CGRect(x: $0.minX * z + 1, y: $0.minY * z + 1, width: $0.width * z - 2, height: $0.height * z - 2)).cgPath }
        selection.lineWidth = 2
    }

    private func add(_ v: UIView, _ r: CGRect, _ z: CGFloat, in code: UIView) {
        v.frame = CGRect(x: r.minX * z, y: r.minY * z, width: r.width * z, height: r.height * z)
        if let c = v as? ZoomDrawn { c.zoom = z }
        code.addSubview(v)
        views.append(v)
    }
}

/// A view that draws itself for the zoom it's shown at, so it stays sharp.
@MainActor
private protocol ZoomDrawn: AnyObject { var zoom: CGFloat { get set } }

/// A kept note's bubble in the gutter: an outline while it waits, filled once answered, grey once resolved.
private final class Badge: UIView, ZoomDrawn {
    let state: String
    let count: Int
    var zoom: CGFloat = 1 { didSet { setNeedsDisplay() } }

    init(state: String, count: Int) {
        self.state = state
        self.count = count
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = UIBezierPath(roundedRect: r, byRoundingCorners: [.topLeft, .topRight, .bottomRight], cornerRadii: CGSize(width: r.height / 2, height: r.height / 2))
        let blue = UIColor.systemBlue, color = state == "resolved" ? UIColor.systemGray : blue
        if state == "open" {
            color.setStroke()
            path.lineWidth = 1.5 * zoom
            path.stroke()
        } else {
            color.setFill()
            path.fill()
        }
        guard count > 1 else { return }
        let text = NSAttributedString(string: "\(count)", attributes: [.font: UIFont.systemFont(ofSize: 10 * zoom, weight: .semibold),
                                                                         .foregroundColor: state == "open" ? blue : .white])
        let s = text.size()
        text.draw(at: CGPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2))
    }
}

/// A line's notes or a diagram, folded to one row beside the line: what was last asked there, and how many.
private final class Pill: UIView, ZoomDrawn {
    private let text: NSAttributedString
    private let accent: UIColor
    var zoom: CGFloat = 1 { didSet { setNeedsDisplay() } }

    init(text: String, accent: UIColor) {
        self.accent = accent
        self.text = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: accent])
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    convenience init(history: [NoteCard], state: String) {
        let last = history.last!
        let mark = state == "open" ? "✎" : "✓"
        let more = history.count > 1 ? "  ·  \(history.count)" : ""
        self.init(text: "\(mark) \(last.gist ?? NoteGist.fallback(last.question))\(more)", accent: state == "resolved" ? .secondaryLabel : .systemBlue)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Its width at zoom 1, for its text and padding.
    var width: CGFloat { ceil(text.size().width) + 20 }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        accent.withAlphaComponent(0.1).setFill()
        UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).fill()
        ctx.scaleBy(x: zoom, y: zoom)
        let h = bounds.height / zoom, s = text.size()
        text.draw(with: CGRect(x: 10, y: (h - s.height) / 2, width: bounds.width / zoom - 20, height: s.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}

/// A line's history, opened from its pill or bubble: each question asked on the line and the start of its answer (or
/// that it's being answered, or resolved), newest first. Opaque, with no shadow: it may sit where the Pencil writes.
private final class HistoryCard: UIView, ZoomDrawn {
    static let footer: CGFloat = 28
    private static let pad: CGFloat = 10
    private let items: [NoteCard]
    private let dark: Bool
    /// Its newest question was asked a moment ago: it can be taken back.
    private let takeBack: Bool
    var zoom: CGFloat = 1 { didSet { setNeedsDisplay() } }

    init(_ items: some Sequence<NoteCard>, takeBack: Bool, dark: Bool) {
        self.items = Array(items.prefix(6))
        self.dark = dark
        self.takeBack = takeBack
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    private func texts(_ c: NoteCard) -> (NSAttributedString, NSAttributedString) {
        let q = NSAttributedString(string: "✎ " + c.question, attributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.secondaryLabel])
        let reply = c.answer ?? (c.resolved ? "Resolved" : c.waiting)
        let a = NSAttributedString(string: reply, attributes: [.font: c.answer == nil ? UIFont.italicSystemFont(ofSize: 13) : UIFont.systemFont(ofSize: 13),
                                                                .foregroundColor: c.answer == nil ? UIColor.secondaryLabel : UIColor.label])
        return (q, a)
    }

    private func height(of t: NSAttributedString, width: CGFloat, max: CGFloat) -> CGFloat {
        min(ceil(t.boundingRect(with: CGSize(width: width, height: max), options: [.usesLineFragmentOrigin], context: nil).height), max)
    }

    /// Each note's row, at zoom 1 in the card.
    func rows(width: CGFloat) -> [(String, CGRect)] {
        let w = width - Self.pad * 2
        var y = Self.pad, out: [(String, CGRect)] = []
        for c in items {
            let (q, a) = texts(c)
            let h = height(of: q, width: w, max: 34) + 2 + height(of: a, width: w, max: 54)
            out.append((c.id, CGRect(x: 0, y: y - 4, width: width, height: h + 8)))
            y += h + 10
        }
        return out
    }

    func height(width: CGFloat) -> CGFloat { (rows(width: width).last?.1.maxY ?? Self.pad) + 2 + Self.footer }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        UIColor.secondarySystemBackground.setFill()
        let shape = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 10 * zoom)
        shape.fill()
        UIColor.separator.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        ctx.scaleBy(x: zoom, y: zoom)
        let width = bounds.width / zoom, w = width - Self.pad * 2
        for ((_, r), c) in zip(rows(width: width), items) {
            let (q, a) = texts(c)
            let qh = height(of: q, width: w, max: 34)
            q.draw(with: CGRect(x: Self.pad, y: r.minY + 4, width: w, height: qh), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            a.draw(with: CGRect(x: Self.pad, y: r.minY + 6 + qh, width: w, height: r.height - qh - 8), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            UIColor.separator.setFill()
            ctx.fill(CGRect(x: Self.pad, y: r.maxY, width: w, height: 0.5))
        }
        let foot = NSAttributedString(string: "All notes on this line ›", attributes: [.font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: UIColor.systemBlue])
        foot.draw(at: CGPoint(x: Self.pad, y: bounds.height / zoom - Self.footer + 6))
        if takeBack {
            let back = NSAttributedString(string: "Take back question", attributes: [.font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: UIColor.systemRed])
            back.draw(at: CGPoint(x: width / 2 + Self.pad, y: bounds.height / zoom - Self.footer + 6))
        }
    }
}

#endif
