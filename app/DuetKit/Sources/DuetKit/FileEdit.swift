import Foundation

/// What one of Claude's file tools changes (Edit, MultiEdit, Write): the file, and each stretch of text it replaces. A
/// Write replaces nothing that's known here, so all of its text counts as new.
public struct FileEdit: Equatable, Sendable {
    public let path: String
    public let changes: [Change]
    /// Lines added and removed, over every change.
    public let added: Int
    public let removed: Int

    /// One replaced stretch: the text that was there, and the text that's there now.
    public struct Change: Equatable, Sendable {
        public let old: String
        public let new: String

        public init(old: String, new: String) {
            self.old = old
            self.new = new
        }

        /// Its lines, as a diff.
        public var lines: [DiffLine] { DiffLine.lines(from: old, to: new) }
    }

    public init(path: String, changes: [Change]) {
        self.path = path
        self.changes = changes
        let lines = changes.flatMap(\.lines)
        added = lines.count { $0.kind == .added }
        removed = lines.count { $0.kind == .removed }
    }

    /// The change a file tool's call makes, from its input; nil for any other tool.
    public init?(tool: String, input: JSONValue) {
        guard case .object(let o) = input, let path = o["file_path"]?.stringValue else { return nil }
        func change(_ e: [String: JSONValue]) -> Change? {
            guard let old = e["old_string"]?.stringValue, let new = e["new_string"]?.stringValue else { return nil }
            return Change(old: old, new: new)
        }
        switch tool {
        case "Edit":
            guard let c = change(o) else { return nil }
            self.init(path: path, changes: [c])
        case "MultiEdit":
            guard case .array(let edits)? = o["edits"] else { return nil }
            let cs = edits.compactMap { e -> Change? in if case .object(let e) = e { change(e) } else { nil } }
            guard !cs.isEmpty else { return nil }
            self.init(path: path, changes: cs)
        case "Write":
            guard let content = o["content"]?.stringValue else { return nil }
            self.init(path: path, changes: [Change(old: "", new: content)])
        default:
            return nil
        }
    }

    /// The line (from 1) where `change`'s new text starts in the file's text now, if it's still there.
    public func line(of change: Int, in text: String) -> Int? {
        let new = changes[change].new
        guard !new.isEmpty, let r = text.range(of: new) else { return nil }
        return text[..<r.lowerBound].count { $0 == "\n" } + 1
    }
}

/// A line of a diff: kept, taken out, or put in.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case kept, removed, added }
    public let kind: Kind
    public let text: String
    /// Where it is among the new text's lines (from 0); nil for a removed line, which isn't in the file any more.
    public let newIndex: Int?

    /// The lines from `old` to `new`, matched by their longest common run of lines. Very long texts (a whole file
    /// rewritten) skip the matching: all of the old goes, then all of the new.
    public static func lines(from old: String, to new: String) -> [DiffLine] {
        let a = old.isEmpty ? [] : old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = new.isEmpty ? [] : new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 250_000 else {
            return a.map { DiffLine(kind: .removed, text: $0, newIndex: nil) }
                + b.enumerated().map { DiffLine(kind: .added, text: $1, newIndex: $0) }
        }
        // longest[i][j]: the longest common run of a[i...] and b[j...].
        var longest = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                longest[i][j] = a[i] == b[j] ? longest[i + 1][j + 1] + 1 : max(longest[i + 1][j], longest[i][j + 1])
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                out.append(DiffLine(kind: .kept, text: a[i], newIndex: j)); i += 1; j += 1
            } else if i < a.count, j == b.count || longest[i + 1][j] >= longest[i][j + 1] {
                out.append(DiffLine(kind: .removed, text: a[i], newIndex: nil)); i += 1
            } else {
                out.append(DiffLine(kind: .added, text: b[j], newIndex: j)); j += 1
            }
        }
        return out
    }
}
