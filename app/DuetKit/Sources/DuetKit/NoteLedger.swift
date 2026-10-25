import Foundation

/// One note as the cross-module views see it: the module(s) it's about, its tags, when it was written and where it
/// stands. Where it was written (`surface`: the module's page, a visual of it, a task's diff, a plan) doesn't change
/// what it is: people learn in different places, and every note is filed by module and tag the same way.
public struct NoteEntry: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    /// The modules (file paths) the note is about, the main one first: the page's file for a note on code; for a note
    /// on a visual, the files its nodes explain. Empty only when nothing it touches maps to code yet.
    public var modules: [String]
    /// Where it was written, as the hub knows surfaces.
    public var surface: NoteSurface
    /// On a visual or a plan: the node or step it was written on (nil: the whole surface, or a code page).
    public var node: String?
    public var tags: [String]
    /// When it was written (nil: written before notes kept the time).
    public var createdAt: Date?
    /// What it says, short: its gist or its reading.
    public var text: String
    public var question: Bool
    public var resolved: Bool
    /// Written on a scratchpad: never filed, never in a tag's view.
    public var scratch: Bool

    /// The main module, or "" when it touches none.
    public var module: String { modules.first ?? "" }

    public init(id: String, modules: [String], surface: NoteSurface, node: String? = nil, tags: [String], createdAt: Date?,
                text: String, question: Bool = false, resolved: Bool = false, scratch: Bool = false) {
        self.id = id; self.modules = modules; self.surface = surface; self.node = node; self.tags = tags; self.createdAt = createdAt
        self.text = text; self.question = question; self.resolved = resolved; self.scratch = scratch
    }

    /// A note on one module's own page.
    public init(id: String, module: String, tags: [String], createdAt: Date?, text: String, question: Bool = false,
                resolved: Bool = false, scratch: Bool = false) {
        self.init(id: id, modules: [module], surface: .file(path: module), tags: tags, createdAt: createdAt, text: text,
                  question: question, resolved: resolved, scratch: scratch)
    }
}

/// Which notes to see: through one tag or several (every one, or any one), on some modules or all, over a span of
/// time. Tag names match without regard to case.
public struct NoteFilter: Equatable, Sendable {
    public enum Match: Sendable { case all, any }

    public var tags: [String] = []
    public var match: Match = .all
    /// Nil: every module. A note matches when it's about any of them, wherever it was written.
    public var modules: Set<String>?
    /// Nil: every surface. E.g. only notes written on visuals.
    public var surfaces: Set<SurfaceKind>?
    public var from: Date?
    public var to: Date?
    public var includeResolved = true
    /// The scratchpad's notes, alone (and nothing else).
    public var scratchpad = false

    /// Where notes were written, broadly: on code (a module's page, a task's diff), on a visual, or in the
    /// conversation (its plan).
    public enum SurfaceKind: Hashable, Sendable { case code, visual, conversation }

    public init(tags: [String] = [], match: Match = .all, modules: Set<String>? = nil, surfaces: Set<SurfaceKind>? = nil,
                from: Date? = nil, to: Date? = nil, includeResolved: Bool = true, scratchpad: Bool = false) {
        self.tags = tags; self.match = match; self.modules = modules; self.surfaces = surfaces; self.from = from; self.to = to
        self.includeResolved = includeResolved; self.scratchpad = scratchpad
    }

    public func matches(_ e: NoteEntry) -> Bool {
        if e.scratch != scratchpad { return false }
        if let modules, !e.modules.contains(where: modules.contains) { return false }
        if let surfaces, !surfaces.contains(e.surface.kind) { return false }
        if !includeResolved, e.resolved { return false }
        if from != nil || to != nil {
            // A note with no time can't be placed in a span.
            guard let t = e.createdAt else { return false }
            if let from, t < from { return false }
            if let to, t > to { return false }
        }
        guard !tags.isEmpty else { return true }
        let have = Set(e.tags.map { $0.lowercased() })
        let want = tags.map { $0.lowercased() }
        return match == .all ? want.allSatisfy(have.contains) : want.contains(where: have.contains)
    }
}

public enum NoteLedger {
    /// The notes the filter lets through, newest first; notes with no time last, in a stable order.
    public static func query(_ entries: [NoteEntry], _ filter: NoteFilter) -> [NoteEntry] {
        entries.filter(filter.matches).sorted { a, b in
            switch (a.createdAt, b.createdAt) {
            case let (x?, y?): x != y ? x > y : a.id < b.id
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.module != b.module ? a.module < b.module : a.id < b.id
            }
        }
    }

    /// Notes over time: one group per calendar day, newest day first (undated notes in a last group with no day).
    public static func byDay(_ entries: [NoteEntry], calendar: Calendar = .current) -> [(day: Date?, notes: [NoteEntry])] {
        var groups: [(day: Date?, notes: [NoteEntry])] = []
        for e in entries {
            let day = e.createdAt.map { calendar.startOfDay(for: $0) }
            if let i = groups.firstIndex(where: { $0.day == day }) { groups[i].notes.append(e) } else { groups.append((day, [e])) }
        }
        return groups.sorted { a, b in
            switch (a.day, b.day) {
            case let (x?, y?): x > y
            case (.some, nil): true
            default: false
            }
        }
    }

    /// Every tag in use and how many notes carry it, most used first: what a tag picker draws from.
    public static func tagCounts(_ entries: [NoteEntry]) -> [(tag: String, count: Int)] {
        var counts: [String: (name: String, n: Int)] = [:]
        for e in entries where !e.scratch {
            for t in e.tags { counts[t.lowercased(), default: (t, 0)].n += 1 }
        }
        return counts.values.map { ($0.name, $0.n) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }
}

extension NoteSurface {
    public var kind: NoteFilter.SurfaceKind {
        switch self {
        case .file, .diff: .code
        case .diagram: .visual
        case .plan: .conversation
        }
    }
}
