#if os(iOS)
import Foundation
import Observation

/// The tags notes are filed under, shared by every code file, and the one the code pages are seen through now. A tag
/// is just a name; each file keeps which of its notes carry it (`CodeNoteBook`).
@MainActor @Observable
final class NoteTags {
    static let shared = NoteTags()
    /// At most this many tags on one note.
    nonisolated static let limit = 5

    /// Every tag, most recently used first.
    private(set) var all: [String]
    /// The tag the code pages are seen through (nil: every note). It stays as files change.
    private(set) var current: String?

    private let defaults: UserDefaults
    private static let allKey = "noteTags.all", currentKey = "noteTags.current"
    /// A tag was renamed, merged or deleted: open pages change their own notes (old name, new name or nil).
    nonisolated static let changed = Notification.Name("NoteTags.changed")
    /// One note's tags were set in a review: its page, if open, takes them ("key", "id", "tags").
    nonisolated static let noteTagged = Notification.Name("NoteTags.noteTagged")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        all = defaults.stringArray(forKey: Self.allKey) ?? []
        current = defaults.string(forKey: Self.currentKey)
    }

    /// See the pages through this tag (nil: everything).
    func pick(_ tag: String?) {
        let tag = tag.flatMap(Self.clean)
        if let tag { use([tag]) }
        current = tag
        defaults.set(tag, forKey: Self.currentKey)
    }

    /// These tags were just given to a note: they move to the front (new ones are added).
    func use(_ tags: [String]) {
        let tags = tags.compactMap(Self.clean)
        guard !tags.isEmpty else { return }
        all = tags + all.filter { !tags.contains($0) }
        defaults.set(all, forKey: Self.allKey)
    }

    /// Rename a tag everywhere; to an existing name, the two merge.
    func rename(_ old: String, to new: String) {
        guard let new = Self.clean(new), new != old else { return }
        all = all.map { $0 == old ? new : $0 }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        defaults.set(all, forKey: Self.allKey)
        if current == old { pick(new) }
        NotificationCenter.default.post(name: Self.changed, object: nil, userInfo: ["old": old, "new": new])
        Task.detached(priority: .utility) { CodeNoteBook.updateAll { $0.renameTag(old, to: new) } }
    }

    /// Delete a tag everywhere. Its notes stay, with their other tags.
    func delete(_ tag: String) {
        all.removeAll { $0 == tag }
        defaults.set(all, forKey: Self.allKey)
        if current == tag { pick(nil) }
        NotificationCenter.default.post(name: Self.changed, object: nil, userInfo: ["old": tag])
        Task.detached(priority: .utility) { CodeNoteBook.updateAll { $0.removeTag(tag) } }
    }

    /// A tag as typed: trimmed, at most 40 characters, nil when empty.
    nonisolated static func clean(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : String(n.prefix(40))
    }

    /// The dropdown's order: the tags used on this file first (most used first), then the rest, most recent first.
    func ranked(onFile: [String]) -> (here: [String], other: [String]) {
        let here = onFile.filter { all.contains($0) } + onFile.filter { !all.contains($0) }
        return (here, all.filter { !onFile.contains($0) })
    }
}
#endif
