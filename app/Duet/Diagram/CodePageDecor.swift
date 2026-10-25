#if os(iOS)
import DuetKit
import UIKit

/// What a code page shows beside its code: the lines changed since the last commit and where lines were removed, the
/// kept notes on its lines (one pill per line, only while there's something for you), and the diagrams that explain
/// it (a stripe, a ◆ on each element's line, a pill).
struct CodePageDecor: Equatable {
    var changed: Set<Int> = []
    var removedAfter: Set<Int> = []
    var marks: [Int: LineMark] = [:]
    var peeks: [DiagramPeek] = []

    var hasCards: Bool { !peeks.isEmpty || marks.values.contains(where: \.wantsYou) }
}

extension LineMark {
    /// Something on the line for you: a question being answered, or an answer not yet resolved. Otherwise the line
    /// is plain code again (its history still opens from its number).
    var wantsYou: Bool { answering || state != "resolved" }
}

/// Something on the page a finger can tap, in page coordinates.
enum CodePageHit: Equatable {
    case notes([String])
    case diagram(String, element: String?)
    /// A line's notes, folded: open (or close) its history.
    case history(Int)
    /// A question asked a moment ago: take it back.
    case cancel(String)
    /// The line's answers dealt with: resolve these notes.
    case resolve([String])
}

/// The decorations, drawn into the code view (so they zoom and scroll with it): tints and stripes under the text, bubbles,
/// marks and cards over it, all under the ink. Static while the Pencil is down; laid out again only when the page
/// changes or a pinch ends.
@MainActor
final class CodeDecorations {
    static let cardWidth: CGFloat = 280
    static let cardGap: CGFloat = 16
    /// A pill's widest on a page with no room beside the code.
    static let narrowPill: CGFloat = 150

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

        // A line's number opens its notes' history, resolved ones too: nothing is drawn for it.
        for n in d.marks.keys where n <= g.lineCount {
            let r = g.rect(line: n, width: width)
            hits.append((CGRect(x: 0, y: r.minY, width: g.codeX - 2, height: g.lineHeight), .history(n)))
        }
        // In the gutter, before the number: a diagram element's ◆.
        let elementAt = Dictionary(d.peeks.flatMap { p in p.elements.map { ($0.line, (p, $0)) } }, uniquingKeysWith: { a, _ in a })
        for n in elementAt.keys where n <= g.lineCount && d.marks[n] == nil {
            let r = g.rect(line: n, width: width)
            let box = CGRect(x: 3, y: r.minY + 2, width: 18, height: 16)
            if let (p, e) = elementAt[n] {
                let mark = UILabel()
                mark.text = "◆"
                mark.font = .systemFont(ofSize: 10 * z)
                mark.textColor = purple
                add(mark, box, z, in: code)
                hits.append((box.insetBy(dx: -6, dy: -2), .diagram(p.id, element: e.id)))
            }
        }

        // One pill per line, level with it, so it never takes more than its row: beside the code on a wide page, at
        // the page's right edge on a narrow one. A note's pill shows only while there's something for you; a tap
        // opens the line's answer under it.
        let x = Self.cardsX(g, pageWidth: width)
        func place(_ pill: Pill, line n: Int) -> CGRect {
            let r = g.rect(line: n, width: width)
            if showsCards { return CGRect(x: x, y: r.minY + 2, width: min(Self.cardWidth, pill.width), height: g.lineHeight - 4) }
            let w = min(Self.narrowPill, pill.width)
            return CGRect(x: width - g.right - w, y: r.minY + 2, width: w, height: g.lineHeight - 4)
        }
        for p in d.peeks where p.line <= g.lineCount && showsCards {
            let pill = Pill(text: "◆ " + p.title, accent: purple)
            let f = place(pill, line: p.line)
            add(pill, f, z, in: code)
            hits.append((f, .diagram(p.id, element: nil)))
        }
        for (n, m) in d.marks where n <= g.lineCount && m.wantsYou && !m.history.isEmpty && !(showsCards && d.peeks.contains { $0.line == n }) {
            let pill = Pill(history: m.history, state: m.state, answering: m.answering)
            let f = place(pill, line: n)
            add(pill, f, z, in: code)
            if m.answering { pulse(pill.layer) }
            hits.append((f, .history(n)))
        }
        // The open line's answers: every question asked on it, newest first, short, under the line, over what's below
        // it. A row opens its thread; the footer opens the newest one's, and resolves the line (or takes back a
        // question just asked).
        if let n = open, n <= g.lineCount, let m = d.marks[n], !m.history.isEmpty {
            let line = g.rect(line: n, width: width)
            let w = showsCards ? Self.cardWidth : min(420, width - g.codeX - g.right)
            let takeBack = m.history.last { cancellable.contains($0.id) }?.id
            let unresolved = m.history.filter { !$0.resolved }.map(\.id)
            let second: HistoryCard.Second? = takeBack != nil ? .takeBack : unresolved.isEmpty ? nil : .resolve
            let card = HistoryCard(m.history.reversed(), second: second, dark: dark)
            let f = CGRect(x: showsCards ? x : g.codeX, y: line.maxY + 2, width: w, height: card.height(width: w))
            add(card, f, z, in: code)
            for (id, r) in card.rows(width: w) { hits.append((r.offsetBy(dx: f.minX, dy: f.minY), .notes([id]))) }
            let foot = CGRect(x: f.minX, y: f.maxY - HistoryCard.footer, width: w / 2, height: HistoryCard.footer)
            hits.append((foot, .notes([m.history.last!.id])))
            switch second {
            case .takeBack: hits.append((foot.offsetBy(dx: w / 2, dy: 0), .cancel(takeBack!)))
            case .resolve: hits.append((foot.offsetBy(dx: w / 2, dy: 0), .resolve(unresolved)))
            case nil: break
            }
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

    convenience init(history: [NoteCard], state: String, answering: Bool) {
        let last = history.last!
        let mark = answering ? "…" : state == "open" ? "✎" : "✓"
        let more = history.count > 1 ? "  ·  \(history.count)" : ""
        self.init(text: "\(mark) \(last.gist ?? NoteGist.fallback(last.question))\(more)", accent: .systemBlue)
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

/// A line's answers, opened from its pill or its number (or by itself when an answer comes): each question asked on
/// the line and the start of its answer (or that it's being answered, or resolved), newest first. Opaque, with no
/// shadow: it may sit where the Pencil writes.
private final class HistoryCard: UIView, ZoomDrawn {
    /// The footer's second button.
    enum Second { case resolve, takeBack }
    static let footer: CGFloat = 28
    private static let pad: CGFloat = 10
    private let items: [NoteCard]
    private let dark: Bool
    private let second: Second?
    var zoom: CGFloat = 1 { didSet { setNeedsDisplay() } }

    init(_ items: some Sequence<NoteCard>, second: Second?, dark: Bool) {
        self.items = Array(items.prefix(6))
        self.dark = dark
        self.second = second
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
        let bold = UIFont.systemFont(ofSize: 12, weight: .semibold)
        let foot = NSAttributedString(string: "Open thread ›", attributes: [.font: bold, .foregroundColor: UIColor.systemBlue])
        foot.draw(at: CGPoint(x: Self.pad, y: bounds.height / zoom - Self.footer + 6))
        let label: NSAttributedString? = switch second {
        case .takeBack: NSAttributedString(string: "Take back question", attributes: [.font: bold, .foregroundColor: UIColor.systemRed])
        case .resolve: NSAttributedString(string: "Resolve ✓", attributes: [.font: bold, .foregroundColor: UIColor.systemGreen])
        case nil: nil
        }
        label?.draw(at: CGPoint(x: width / 2 + Self.pad, y: bounds.height / zoom - Self.footer + 6))
    }
}

#endif
