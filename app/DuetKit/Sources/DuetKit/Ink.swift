import CoreGraphics
import Foundation

// Stroke tagging: what a group of Pencil strokes looks like (its gesture), which of its strokes are words, and what
// it's drawn on. Pure geometry, so it's tested without a canvas; the iPad feeds it PKStroke points and UUIDs.

/// The gesture a group of strokes makes.
public enum InkShape: String, Sendable, Equatable {
    /// Handwriting (or a scribble): its words are the note.
    case writing
    /// A closed loop around something.
    case lasso
    /// From its tail to its head.
    case arrow
    /// An X over something.
    case cross
    /// A straight stroke: across or under something, or a bracket down the margin.
    case line
    /// ✓
    case check
    /// A tap-sized mark.
    case dot
}

public struct InkShapeResult: Equatable, Sendable {
    public var shape: InkShape
    /// Which strokes make the gesture, and which are words to read (indexes into the group).
    public var gestureStrokes: [Int]
    public var textStrokes: [Int]
    public var tail: CGPoint?
    public var head: CGPoint?
    public var center: CGPoint?
    public var polygon: [CGPoint]
    /// A line's direction in degrees, 0 = left to right, 90 = down.
    public var angle: Double?
    /// The gesture's bounds (or the writing's, for .writing).
    public var bounds: CGRect
    /// The writing's bounds, when there is writing.
    public var textBounds: CGRect?
}

public enum InkGeometry {
    public static func length(_ p: [CGPoint]) -> CGFloat { zip(p, p.dropFirst()).reduce(0) { $0 + dist($1.0, $1.1) } }
    public static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    public static func bounds(_ p: [CGPoint]) -> CGRect {
        guard let f = p.first else { return .null }
        var r = CGRect(origin: f, size: .zero)
        for q in p.dropFirst() { r = r.union(CGRect(origin: q, size: .zero)) }
        return r
    }
    /// How tall handwriting's letters are, from its strokes' bounds: the middle height, so an underline or a dot
    /// doesn't skew it.
    public static func letterHeight(_ strokes: [CGRect]) -> CGFloat {
        let heights = strokes.filter { !$0.isNull }.map(\.height).sorted()
        guard !heights.isEmpty else { return 24 }
        return min(48, max(12, heights[heights.count / 2]))
    }

    /// Whether a stroke carries on handwriting whose bounds are `note` and whose letters are about `h` high: further
    /// along the same line, on the next line down, or a dot or stem among it. `across` and `down` are how many letter
    /// heights off still count.
    public static func continues(_ note: CGRect, letterHeight h: CGFloat, with stroke: CGRect, across: CGFloat = 3, down: CGFloat = 1.5) -> Bool {
        guard !note.isNull, !stroke.isNull else { return false }
        // A dot, a comma or the stem of a question mark joins from a little further off.
        let k: CGFloat = max(stroke.width, stroke.height) < h * 0.8 ? 1.4 : 1
        return note.insetBy(dx: -across * h * k, dy: -down * h * k).intersects(stroke)
    }

    static func straightness(_ p: [CGPoint]) -> CGFloat {
        let l = length(p)
        return l > 0 ? dist(p.first!, p.last!) / l : 1
    }
    static func angle(_ a: CGPoint, _ b: CGPoint) -> Double { atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180 / .pi }
    static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    /// Where two segments cross, if they do within `margin` of either end (an X crosses near its middles; an
    /// arrowhead's barbs only meet at the tip).
    static func intersection(_ a1: CGPoint, _ a2: CGPoint, _ b1: CGPoint, _ b2: CGPoint, margin: CGFloat = 0) -> CGPoint? {
        let d = (a2.x - a1.x) * (b2.y - b1.y) - (a2.y - a1.y) * (b2.x - b1.x)
        guard abs(d) > 1e-6 else { return nil }
        let t = ((b1.x - a1.x) * (b2.y - b1.y) - (b1.y - a1.y) * (b2.x - b1.x)) / d
        let u = ((b1.x - a1.x) * (a2.y - a1.y) - (b1.y - a1.y) * (a2.x - a1.x)) / d
        let span = margin...(1 - margin)
        guard span.contains(t), span.contains(u) else { return nil }
        return CGPoint(x: a1.x + t * (a2.x - a1.x), y: a1.y + t * (a2.y - a1.y))
    }

    /// How much of a rectangle a closed loop covers, from a 5×5 grid of points in it: a node the loop goes around is
    /// mostly inside; a subgraph's box that the loop only crosses is not.
    static func coverage(_ polygon: [CGPoint], _ r: CGRect) -> CGFloat {
        var inside = 0
        for i in 0..<5 {
            for j in 0..<5 where contains(polygon, CGPoint(x: r.minX + r.width * (CGFloat(i) + 0.5) / 5, y: r.minY + r.height * (CGFloat(j) + 0.5) / 5)) {
                inside += 1
            }
        }
        return CGFloat(inside) / 25
    }

    public static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Points spaced about `step` apart, so turn detection doesn't depend on how fast the pen moved.
    static func resample(_ p: [CGPoint], step: CGFloat = 6) -> [CGPoint] {
        guard p.count > 1 else { return p }
        var out = [p[0]]
        var carry: CGFloat = 0
        for (a, b) in zip(p, p.dropFirst()) {
            let d = dist(a, b)
            guard d > 0 else { continue }
            var t = step - carry
            while t <= d {
                out.append(CGPoint(x: a.x + (b.x - a.x) * t / d, y: a.y + (b.y - a.y) * t / d))
                t += step
            }
            carry = d - (t - step)
        }
        if let last = p.last, dist(out.last!, last) > 1 { out.append(last) }
        return out
    }

    /// Index (into the resampled points) of the first sharp turn after `fromFraction` of the stroke, if any.
    static func sharpTurn(_ p: [CGPoint], over degrees: Double, fromFraction: Double) -> Int? {
        let r = resample(p)
        guard r.count >= 7 else { return nil }
        let start = max(3, Int(Double(r.count) * fromFraction))
        guard start < r.count - 3 else { return nil }
        for i in start..<(r.count - 3) {
            let a = angle(r[i - 3], r[i]), b = angle(r[i], r[i + 3])
            var turn = abs(b - a)
            if turn > 180 { turn = 360 - turn }
            if turn >= degrees { return i }
        }
        return nil
    }

    static func isLasso(_ p: [CGPoint]) -> Bool {
        let l = length(p), b = bounds(p)
        return l > 90 && b.width > 28 && b.height > 22 && dist(p.first!, p.last!) < max(24, 0.18 * l)
    }

    /// ✓: down-right to a low vertex, then a longer stroke up-right.
    static func checkVertex(_ p: [CGPoint]) -> CGPoint? {
        guard p.count >= 4, let low = p.indices.max(by: { p[$0].y < p[$1].y }) else { return nil }
        let a = p.first!, v = p[low], b = p.last!
        let first = dist(a, v), second = dist(v, b)
        guard low > 0, low < p.count - 1, first > 6, second > first * 1.15, second < first * 6 else { return nil }
        guard v.y - a.y > 4, v.x >= a.x - 4, b.x > v.x + 6, v.y - b.y > second * 0.45 else { return nil }
        guard straightness(Array(p[...low])) > 0.8, straightness(Array(p[low...])) > 0.85 else { return nil }
        return v
    }

    /// Sort a group's strokes into a gesture and words.
    public static func classify(_ strokes: [[CGPoint]]) -> InkShapeResult {
        let s = strokes.map { $0.count == 1 ? [$0[0], $0[0]] : $0 }.filter { !$0.isEmpty }
        let all = s.flatMap { $0 }
        let b = bounds(all)
        func result(_ shape: InkShape, gesture: [Int], tail: CGPoint? = nil, head: CGPoint? = nil, center: CGPoint? = nil, polygon: [CGPoint] = [], angle: Double? = nil) -> InkShapeResult {
            let text = s.indices.filter { !gesture.contains($0) }
            let gb = gesture.isEmpty ? b : bounds(gesture.flatMap { s[$0] })
            let tb = text.isEmpty ? nil : bounds(text.flatMap { s[$0] })
            return InkShapeResult(shape: shape, gestureStrokes: gesture, textStrokes: text, tail: tail, head: head, center: center, polygon: polygon, angle: angle, bounds: gb, textBounds: tb)
        }
        guard !s.isEmpty else { return InkShapeResult(shape: .dot, gestureStrokes: [], textStrokes: [], polygon: [], bounds: .zero) }
        if b.width < 9 && b.height < 9 { return result(.dot, gesture: Array(s.indices), center: center(b)) }

        // A loop around something; anything else in the group is what was written about it.
        if let i = s.indices.filter({ isLasso(s[$0]) }).max(by: { length(s[$0]) < length(s[$1]) }) {
            return result(.lasso, gesture: [i], center: center(bounds(s[i])), polygon: s[i])
        }
        // An X: two straight strokes of similar length crossing at a wide angle.
        for i in s.indices { for j in s.indices where j > i {
            let a = s[i], c = s[j]
            guard straightness(a) > 0.85, straightness(c) > 0.85, length(a) > 14, length(c) > 14 else { continue }
            let ratio = max(length(a), length(c)) / min(length(a), length(c))
            var between = abs(angle(a.first!, a.last!) - angle(c.first!, c.last!)).truncatingRemainder(dividingBy: 180)
            if between > 90 { between = 180 - between }
            if ratio < 2.6, between > 40, let x = intersection(a.first!, a.last!, c.first!, c.last!, margin: 0.15) {
                return result(.cross, gesture: [i, j], center: x)
            }
        } }
        // The longest stroke, if it's long: an arrow (with a head in the same stroke or drawn after) or a line.
        let main = s.indices.max(by: { length(s[$0]) < length(s[$1]) })!
        let m = s[main], ml = length(m)
        if ml >= 60 {
            if let turn = sharpTurn(m, over: 110, fromFraction: 0.55) {
                let r = resample(m)
                let before = length(Array(r[...turn])), after = length(Array(r[turn...]))
                if after < before * 0.45, straightness(Array(r[...turn])) > 0.7 {
                    return result(.arrow, gesture: [main], tail: r.first!, head: r[turn])
                }
            }
            // Short strokes near one end of a straight-ish main stroke are its arrowhead.
            if straightness(m) > 0.7 {
                let near = { (end: CGPoint) in s.indices.filter { $0 != main && length(s[$0]) < ml * 0.45 && dist(center(bounds(s[$0])), end) < ml * 0.3 + 18 } }
                let atEnd = near(m.last!), atStart = near(m.first!)
                if !atEnd.isEmpty, atEnd.count >= atStart.count { return result(.arrow, gesture: [main] + atEnd, tail: m.first!, head: m.last!) }
                if !atStart.isEmpty { return result(.arrow, gesture: [main] + atStart, tail: m.last!, head: m.first!) }
            }
            if straightness(m) > 0.9 {
                return result(.line, gesture: [main], tail: m.first!, head: m.last!, center: center(bounds(m)), angle: angle(m.first!, m.last!))
            }
        }
        // ✓ on its own.
        if s.count <= 2, let i = s.indices.first(where: { checkVertex(s[$0]) != nil }), let v = checkVertex(s[i]) {
            return result(.check, gesture: [i], center: v)
        }
        return result(.writing, gesture: [])
    }
}

/// Something a note can be tagged to: a diagram element, or one line of a diff.
public struct InkAnchor: Sendable, Equatable {
    public let id: String
    public let label: String
    public let rect: CGRect
    public let file: String?
    public let line: Int?
    public init(id: String, label: String, rect: CGRect, file: String? = nil, line: Int? = nil) {
        self.id = id; self.label = label; self.rect = rect; self.file = file; self.line = line
    }
}

public enum InkColorName: String, Sendable { case red, blue, green, other }

public enum InkTagger {
    /// The intent, and the elements or lines, for one classified group of strokes. `letterHeight` is how big the
    /// handwriting is, which says whether it runs over more than one line.
    public static func note(id: String, shape: InkShapeResult, text: String?, color: InkColorName, anchors: [InkAnchor], diff: Bool,
                            letterHeight: CGFloat? = nil) -> InkNote {
        let words = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var targets: [InkAnchor] = []
        var intent: InkIntent

        func at(_ p: CGPoint, within: CGFloat = 60) -> InkAnchor? {
            if diff { return anchors.first { $0.rect.minY <= p.y && p.y <= $0.rect.maxY } ?? nearest(p, within: 14) }
            return anchors.filter { $0.rect.insetBy(dx: -6, dy: -6).contains(p) }.min { $0.rect.area < $1.rect.area } ?? nearest(p, within: within)
        }
        func nearest(_ p: CGPoint, within: CGFloat) -> InkAnchor? {
            anchors.map { ($0, InkGeometry.dist(InkGeometry.center($0.rect), p)) }.filter { $0.1 <= within + max($0.0.rect.width, $0.0.rect.height) / 2 }.min { $0.1 < $1.1 }?.0
        }
        /// What a span of ink sits on: diff lines it covers vertically, or the diagram element it overlaps most.
        func under(_ r: CGRect) -> [InkAnchor] {
            if diff { return anchors.filter { $0.rect.maxY >= r.minY && $0.rect.minY <= r.maxY } }
            let best = anchors.map { ($0, $0.rect.intersection(r).area) }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
            return [best ?? nearest(InkGeometry.center(r), within: 120)].compactMap { $0 }
        }
        /// Writing in a diff's margin is about the line level with where it starts. Written over several lines of
        /// handwriting, it's about the code lines it runs beside.
        func besideWriting(_ r: CGRect) -> [InkAnchor] {
            guard diff else { return under(r) }
            if let h = letterHeight, r.height > h * 2 {
                let beside = anchors.filter { $0.rect.midY >= r.minY && $0.rect.midY <= r.maxY }
                if !beside.isEmpty { return beside }
            }
            return [at(CGPoint(x: 0, y: r.minY + min(r.height, 24) / 2)) ?? at(InkGeometry.center(r))].compactMap { $0 }
        }

        switch shape.shape {
        case .lasso:
            // What it goes around: elements mostly inside the loop, not the subgraph box the loop sits in.
            targets = anchors.filter { InkGeometry.contains(shape.polygon, InkGeometry.center($0.rect)) && InkGeometry.coverage(shape.polygon, $0.rect) >= 2.0 / 3 }
            if targets.isEmpty, let c = shape.center, let a = at(c, within: 80) { targets = [a] }
            intent = !diff && targets.count >= 2 ? .group : .emphasize
        case .arrow:
            let from = shape.tail.flatMap { at($0) }, to = shape.head.flatMap { at($0) }
            if let from, let to, from.id != to.id { targets = [from, to]; intent = .connect }
            else { targets = [to ?? from].compactMap { $0 }; intent = .emphasize }
        case .cross:
            targets = diff ? under(shape.bounds) : [shape.center.flatMap { at($0, within: 30) }].compactMap { $0 }
            intent = .remove
        case .check:
            targets = diff ? under(shape.bounds) : [shape.center.flatMap { at($0, within: 40) } ?? under(shape.bounds).first].compactMap { $0 }
            intent = .approve
        case .dot:
            targets = [shape.center.flatMap { at($0, within: 30) }].compactMap { $0 }
            intent = .emphasize
        case .line:
            let a = abs(shape.angle ?? 0).truncatingRemainder(dividingBy: 180), horizontal = a < 25 || a > 155, vertical = abs(a - 90) < 25
            let from = shape.tail.flatMap { at($0, within: 20) }, to = shape.head.flatMap { at($0, within: 20) }
            if !diff, let from, let to, from.id != to.id {
                targets = [from, to]; intent = .connect
            } else if horizontal, let mid = shape.center {
                // Through the middle of something strikes it out; just below it underlines it.
                if let hit = at(mid, within: 0), mid.y > hit.rect.minY + hit.rect.height * 0.2, mid.y < hit.rect.maxY - hit.rect.height * 0.2 || diff {
                    targets = [hit]; intent = .remove
                } else {
                    let above = anchors.filter { mid.y >= $0.rect.maxY - 8 && mid.y <= $0.rect.maxY + 26 && $0.rect.maxX > shape.bounds.minX && $0.rect.minX < shape.bounds.maxX }
                    targets = above.isEmpty ? under(shape.bounds) : [above.min { abs($0.rect.maxY - mid.y) < abs($1.rect.maxY - mid.y) }!]
                    intent = .emphasize
                }
            } else if vertical {
                // A bracket down the margin: the lines (or elements) beside it.
                let r = shape.bounds
                targets = diff ? under(r) : anchors.filter { $0.rect.maxY >= r.minY && $0.rect.minY <= r.maxY && abs($0.rect.midX - r.midX) < $0.rect.width / 2 + 90 }
                intent = .emphasize
            } else {
                targets = [to ?? from].compactMap { $0 }
                intent = .emphasize
            }
        case .writing:
            targets = besideWriting(shape.textBounds ?? shape.bounds)
            intent = .comment
        }

        // Words and ink color refine a note that isn't already a specific gesture.
        if [.comment, .emphasize].contains(intent) {
            if let w = words, w.hasSuffix("?") || ["why", "what", "how", "should", "can", "does", "is", "could", "where", "when"].contains(w.split(separator: " ").first?.lowercased() ?? "") {
                intent = .question
            } else {
                switch color {
                case .red: intent = .change
                case .blue: intent = .question
                case .green: intent = .approve
                case .other: if intent == .emphasize, words != nil { intent = .comment }
                }
            }
        }

        if diff {
            return InkNote(id: id, intent: intent, text: words, lines: lineRanges(targets, connect: intent == .connect), color: color == .other ? nil : color.rawValue)
        }
        let elements = targets.reduce(into: [InkAnchor]()) { acc, a in if !acc.contains(where: { $0.id == a.id }) { acc.append(a) } }
        return InkNote(id: id, intent: intent, text: words, elements: elements.map { InkElement(id: $0.id, label: $0.label == $0.id ? nil : $0.label) },
                       color: color == .other ? nil : color.rawValue)
    }

    /// Diff lines as ranges per file. For a move (connect), the source lines and the destination stay separate.
    static func lineRanges(_ anchors: [InkAnchor], connect: Bool) -> [InkLines] {
        if connect, anchors.count == 2 {
            return anchors.compactMap { a in a.file.map { InkLines(file: $0, start: a.line ?? 0, end: a.line ?? 0, code: a.label) } }
        }
        var out: [InkLines] = []
        for a in anchors.sorted(by: { ($0.file ?? "", $0.rect.minY) < ($1.file ?? "", $1.rect.minY) }) {
            guard let file = a.file, let line = a.line else { continue }
            if let last = out.last, last.file == file, line == last.end + 1 {
                // Every line's code, so the note can be found again after the file changes.
                let code = [last.code, a.label].compactMap { $0 }.joined(separator: "\n")
                out[out.count - 1] = InkLines(file: file, start: last.start, end: line, code: String(code.prefix(4000)))
            } else {
                out.append(InkLines(file: file, start: line, end: line, code: a.label))
            }
        }
        return out
    }
}

extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
