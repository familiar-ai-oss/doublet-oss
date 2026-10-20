import Foundation

/// Go to File: the files whose paths hold the letters you typed, in order, best first. A match in a file's name beats
/// one in its folders, letters together beat letters apart, a match at the start of a word (after `/`, `.`, `_`, `-`)
/// counts extra, and shorter paths win ties: "fleet" finds `src/fleet.ts` before `test/fleet-old/x.ts`.
public struct FileSearch: Sendable {
    private let files: [(path: String, lower: [UInt8], nameStart: Int)]

    /// `paths`: relative to the folder searched.
    public init(_ paths: [String]) {
        files = paths.map { p in
            let lower = Array(p.lowercased().utf8)
            let slash = lower.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 } ?? 0
            return (p, lower, slash)
        }
    }

    public var count: Int { files.count }

    /// The best matches for `query` (spaces ignored), at most `limit`.
    public func rank(_ query: String, limit: Int = 60) -> [String] {
        let q = Array(query.lowercased().filter { !$0.isWhitespace }.utf8)
        guard !q.isEmpty else { return Array(files.prefix(limit).map(\.path)) }
        var scored: [(path: String, score: Int)] = []
        for f in files {
            if let s = Self.score(f.lower, f.nameStart, q) { scored.append((f.path, s)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.path.utf8.count < $1.path.utf8.count }
        return scored.prefix(limit).map(\.path)
    }

    private static let breaks: Set<UInt8> = [UInt8(ascii: "/"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: " ")]

    static func score(_ s: [UInt8], _ nameStart: Int, _ q: [UInt8]) -> Int? {
        var score = 0, qi = 0, last = -2
        // Prefer the match that ends in the file's name: try matching the name alone first.
        if let inName = match(s, from: nameStart, q) { return inName + 20 }
        var i = 0
        while i < s.count, qi < q.count {
            if s[i] == q[qi] {
                score += 1
                if last == i - 1 { score += 5 }
                if i >= nameStart { score += 3 }
                if i == 0 || breaks.contains(s[i - 1]) { score += 4 }
                last = i
                qi += 1
            }
            i += 1
        }
        return qi == q.count ? score : nil
    }

    private static func match(_ s: [UInt8], from start: Int, _ q: [UInt8]) -> Int? {
        var score = 0, qi = 0, last = -2, i = start
        while i < s.count, qi < q.count {
            if s[i] == q[qi] {
                score += 4
                if last == i - 1 { score += 5 }
                if i == start || breaks.contains(s[i - 1]) { score += 4 }
                last = i
                qi += 1
            }
            i += 1
        }
        return qi == q.count ? score : nil
    }
}
