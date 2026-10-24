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
}

/// The decorations, drawn into the code view (so they zoom and scroll with it): tints and stripes under the text, bubbles,
/// marks and cards over it, all under the ink. Static while the Pencil is down; laid out again only when the page
/// changes or a pinch ends.
@MainActor
final class CodeDecorations {
    static let cardWidth: CGFloat = 280
    static let cardGap: CGFloat = 16

    private let under = CALayer()
    private let selection = CAShapeLayer()
    private var views: [UIView] = []
    private(set) var hits: [(rect: CGRect, hit: CodePageHit)] = []

    init(in code: UIView) {
        under.anchorPoint = .zero
        code.layer.insertSublayer(under, at: 0)
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

    func lay(_ d: CodePageDecor, cards showsCards: Bool, geometry g: CodePageGeometry, pageWidth width: CGFloat, zoom z: CGFloat, in code: UIView) {
        under.sublayers = nil
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
                add(Badge(state: m.state, count: m.ids.count), box, z, in: code)
                hits.append((box.insetBy(dx: -6, dy: -2), .notes(m.ids)))
            } else if let (p, e) = elementAt[n] {
                let mark = UILabel()
                mark.text = "◆"
                mark.font = .systemFont(ofSize: 10 * z)
                mark.textColor = purple
                add(mark, box, z, in: code)
                hits.append((box.insetBy(dx: -6, dy: -2), .diagram(p.id, element: e.id)))
            }
        }

        // Cards in a column beside the code, each level with its line, pushed down past the one above.
        let x = Self.cardsX(g, pageWidth: width)
        var below: CGFloat = 0
        var cards: [(line: Int, view: Card, hit: CodePageHit)] = []
        for p in d.peeks { cards.append((p.line, Card(diagram: p, dark: dark), .diagram(p.id, element: nil))) }
        for (n, m) in d.marks { for c in m.cards { cards.append((n, Card(note: c, dark: dark), .notes([c.id]))) } }
        for c in cards.sorted(by: { $0.line < $1.line }) where showsCards && c.line <= g.lineCount {
            let h = c.view.height(width: Self.cardWidth)
            let y = max(g.rect(line: c.line, width: width).minY, below)
            let r = CGRect(x: x, y: y, width: Self.cardWidth, height: h)
            below = r.maxY + 8
            add(c.view, r, z, in: code)
            hits.append((r, c.hit))
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

/// A card beside its line: a note's question and the start of its answer, or the diagram that explains these lines.
private final class Card: UIView, ZoomDrawn {
    private let title: NSAttributedString
    private let body: NSAttributedString?
    private let accent: UIColor
    private let fill: UIColor
    var zoom: CGFloat = 1 { didSet { setNeedsDisplay() } }

    private static let pad: CGFloat = 9

    init(note c: NoteCard, dark: Bool) {
        let open = c.answer == nil
        accent = open ? .systemGray : .systemBlue
        fill = (open ? UIColor.systemGray : .systemBlue).withAlphaComponent(dark ? 0.16 : 0.08)
        title = NSAttributedString(string: "✎ " + c.question, attributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.secondaryLabel])
        let reply = c.answer ?? c.waiting
        body = NSAttributedString(string: reply + (c.answer != nil ? "\n" + (c.chip.map { "\($0) · " } ?? "") + "Open the thread ›" : ""),
                                  attributes: [.font: c.answer == nil ? UIFont.italicSystemFont(ofSize: 13) : UIFont.systemFont(ofSize: 13),
                                               .foregroundColor: c.answer == nil ? UIColor.secondaryLabel : UIColor.label])
        super.init(frame: .zero)
        setUp()
    }

    init(diagram p: DiagramPeek, dark: Bool) {
        accent = UIColor(red: 0x8b / 255, green: 0x5c / 255, blue: 0xf6 / 255, alpha: 1)
        fill = accent.withAlphaComponent(dark ? 0.16 : 0.07)
        let t = NSMutableAttributedString(string: "◆ Explained in ", attributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: accent])
        t.append(NSAttributedString(string: p.title, attributes: [.font: UIFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: accent]))
        t.append(NSAttributedString(string: "  Open ›", attributes: [.font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: accent]))
        title = t
        let names = p.elements.prefix(8).map { "\($0.label) \($0.line)" }.joined(separator: " · ")
        body = names.isEmpty ? nil : NSAttributedString(string: names, attributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.secondaryLabel])
        super.init(frame: .zero)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    private func texts(width: CGFloat) -> [(NSAttributedString, CGRect)] {
        let w = width - Self.pad * 2 - 3
        var y = Self.pad, out: [(NSAttributedString, CGRect)] = []
        for t in [title, body].compactMap({ $0 }) {
            let h = ceil(t.boundingRect(with: CGSize(width: w, height: 80), options: [.usesLineFragmentOrigin], context: nil).height)
            out.append((t, CGRect(x: Self.pad + 3, y: y, width: w, height: min(h, 80))))
            y += min(h, 80) + 3
        }
        return out
    }

    func height(width: CGFloat) -> CGFloat { (texts(width: width).last?.1.maxY ?? 0) + Self.pad - 3 }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        fill.setFill()
        UIBezierPath(roundedRect: bounds, cornerRadius: 10 * zoom).fill()
        accent.setFill()
        UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 3 * zoom, height: bounds.height), byRoundingCorners: [.topLeft, .bottomLeft],
                     cornerRadii: CGSize(width: 10 * zoom, height: 10 * zoom)).fill()
        // Laid out at zoom 1 and drawn scaled, so it reads the same at any zoom.
        ctx.scaleBy(x: zoom, y: zoom)
        for (t, r) in texts(width: bounds.width / zoom) { t.draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil) }
    }
}
#endif
