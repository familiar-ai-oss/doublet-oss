#if os(iOS)
import Foundation
import PencilKit

/// One named layer of ink on a code file ("Note 1", "Review pass", …): its strokes and the notes made of them.
struct CodeNotePage: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var drawing: Data = PKDrawing().dataRepresentation()
    var drafts: [DraftNote] = []
}

/// A code file's note pages, one shown and written on at a time, kept per file in Application Support.
struct CodeNoteBook: Codable, Equatable {
    var pages: [CodeNotePage]
    var current: UUID

    static let earlierName = "Earlier notes"

    init(pages: [CodeNotePage] = [CodeNotePage(name: "Note 1")], current: UUID? = nil) {
        self.pages = pages
        self.current = current ?? pages[0].id
    }

    var page: CodeNotePage {
        get { pages.first { $0.id == current } ?? pages[0] }
        set { if let i = pages.firstIndex(where: { $0.id == newValue.id }) { pages[i] = newValue } }
    }

    /// The next free "Note N".
    var nextName: String {
        let taken = Set(pages.map(\.name))
        return (1...).lazy.map { "Note \($0)" }.first { !taken.contains($0) }!
    }

    /// A fresh page, shown at once.
    @discardableResult
    mutating func add(named name: String? = nil) -> UUID {
        let p = CodeNotePage(name: Self.clean(name) ?? nextName)
        pages.append(p)
        current = p.id
        return p.id
    }

    mutating func rename(_ id: UUID, to name: String) {
        guard let name = Self.clean(name), let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[i].name = name
    }

    /// A page goes, with its ink. There's always one left to write on.
    mutating func remove(_ id: UUID) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages.remove(at: i)
        if pages.isEmpty { pages = [CodeNotePage(name: "Note 1")] }
        if current == id { current = pages[min(i, pages.count - 1)].id }
    }

    private static func clean(_ name: String?) -> String? {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? nil : String(n.prefix(60))
    }

    // MARK: keeping it

    /// What the web page kept for a file (`InkSurfaceView`'s saved ink), read to bring it over.
    struct WebSaved: Codable { var drawing: Data; var drafts: [DraftNote] }

    static var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appending(path: "Ink")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(_ key: String, in folder: URL) -> URL {
        folder.appending(path: "\(key.replacingOccurrences(of: "/", with: "_")).json")
    }

    /// The file's book, or a new one: with the web page's ink brought over as "Earlier notes" the first time, each
    /// note's strokes moved to the line it was tagged to (the web page's lines sat at other heights). The web page's
    /// own copy is left as it was.
    static func load(key: String, geometry: CodePageGeometry, folder: URL? = folder) -> CodeNoteBook {
        guard let folder else { return CodeNoteBook() }
        if let data = try? Data(contentsOf: url("code-\(key)", in: folder)), let book = try? JSONDecoder().decode(CodeNoteBook.self, from: data) {
            return book
        }
        var book = CodeNoteBook()
        if let data = try? Data(contentsOf: url(key, in: folder)), let old = try? JSONDecoder().decode(WebSaved.self, from: data),
           let drawing = try? PKDrawing(data: old.drawing), let earlier = earlierNotes(drawing, old.drafts, geometry: geometry) {
            book.pages.insert(earlier, at: 0)
            book.current = earlier.id
        }
        return book
    }

    func save(key: String, folder: URL? = folder) {
        guard let folder, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url("code-\(key)", in: folder), options: .atomic)
    }

    /// The web page's notes on this page's lines: each moved so its top sits on its first tagged line. Notes that
    /// weren't tagged to a line, and ink that wasn't in a note, have nowhere to go and are left behind.
    static func earlierNotes(_ drawing: PKDrawing, _ drafts: [DraftNote], geometry: CodePageGeometry) -> CodeNotePage? {
        var strokes: [PKStroke] = []
        var kept: [DraftNote] = []
        for var d in drafts {
            guard let line = d.note.lines?.first?.start, line <= geometry.lineCount else { continue }
            let dy = geometry.rect(line: line, width: 0).minY - d.bounds.minY
            let t = CGAffineTransform(translationX: 0, y: dy)
            var ids: Set<UUID> = []
            for s in drawing.strokes where d.strokeIDs.contains(s.id) {
                let moved = PKStroke(ink: s.ink, path: s.path, transform: s.transform.concatenating(t), mask: s.mask, randomSeed: s.randomSeed)
                strokes.append(moved)
                ids.insert(moved.id)
            }
            guard !ids.isEmpty else { continue }
            d.strokeIDs = ids
            d.bounds = d.bounds.applying(t)
            d.tagged = nil
            d.anchorCenter = nil
            kept.append(d)
        }
        guard !kept.isEmpty else { return nil }
        return CodeNotePage(name: earlierName, drawing: PKDrawing(strokes: strokes).dataRepresentation(), drafts: kept)
    }
}
#endif
