#if os(iOS)
import DuetKit
import Foundation
import PencilKit

/// A code file's ink and notes, kept per file in Application Support. Every note is on this file only: the same idea
/// written on two files is two notes. Notes carry tags (up to `NoteTags.limit`), names shared across the codebase,
/// and the page shows the file through one tag at a time (or all of it).
struct CodeNoteBook: Codable, Equatable {
    /// Every stroke on the file, whichever tag it's under.
    var drawing: Data = PKDrawing().dataRepresentation()
    var drafts: [DraftNote] = []
    /// Strokes in no note yet: the tags they were drawn under (none: drawn with every note showing).
    var strokeTags: [UUID: [String]] = [:]
    /// The line height the ink was written for (nil: 20, the first native pages').
    var lineHeight: CGFloat?
    /// The paper's width in characters: long lines wrap inside it (nil: not chosen yet).
    var paper: Int?
    /// The module (file path) these notes are on, kept with them so every module's notes can be listed together.
    var module: String?

    static let earlierName = "Earlier notes"

    init() {}

    // MARK: through a tag

    /// What the page shows through a tag (nil: everything): those notes and their strokes, and loose strokes drawn
    /// under it.
    func visible(_ tag: String?) -> (drawing: PKDrawing, drafts: [DraftNote]) {
        let all = (try? PKDrawing(data: drawing)) ?? PKDrawing()
        guard let tag else { return (all, drafts) }
        let shown = drafts.filter { $0.tags?.contains(tag) == true }
        let inNotes = drafts.reduce(into: Set<UUID>()) { $0.formUnion($1.strokeIDs) }
        let ids = shown.reduce(into: Set<UUID>()) { $0.formUnion($1.strokeIDs) }
        let strokes = all.strokes.filter { ids.contains($0.id) || !inNotes.contains($0.id) && strokeTags[$0.id]?.contains(tag) == true }
        return (PKDrawing(strokes: strokes), shown)
    }

    /// What the page holds now, back into the book. `shown` is what it was given by `visible`: anything it showed and
    /// no longer has was erased (with its note); anything it didn't show is kept as it was. New notes and strokes
    /// take the tag they were written under.
    mutating func merge(_ canvas: PKDrawing, drafts now: [DraftNote], shown: (strokes: Set<UUID>, drafts: Set<String>), tag: String?) {
        let all = (try? PKDrawing(data: drawing)) ?? PKDrawing()
        let kept = all.strokes.filter { !shown.strokes.contains($0.id) }
        var notes = drafts.filter { !shown.drafts.contains($0.id) }
        for var d in now {
            if let tag, d.tags?.isEmpty ?? true { d.tags = [tag] }
            // The scratchpad isn't filed: nothing to review there.
            if tag == NoteTags.scratchpad { d.tagsReviewed = true }
            notes.append(d)
        }
        drafts = notes
        drawing = PKDrawing(strokes: kept + canvas.strokes).dataRepresentation()
        let inNotes = notes.reduce(into: Set<UUID>()) { $0.formUnion($1.strokeIDs) }
        let present = Set(kept.map(\.id)).union(canvas.strokes.map(\.id))
        strokeTags = strokeTags.filter { present.contains($0.key) && !inNotes.contains($0.key) }
        for s in canvas.strokes where !inNotes.contains(s.id) && strokeTags[s.id] == nil {
            strokeTags[s.id] = tag.map { [$0] } ?? []
        }
    }

    /// The tags used on this file, most used first.
    var tags: [String] {
        let counts = drafts.flatMap { $0.tags ?? [] }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// A tag renamed (or merged into another) everywhere on this file. Whether anything changed.
    @discardableResult
    mutating func renameTag(_ old: String, to new: String) -> Bool {
        var changed = false
        for i in drafts.indices where drafts[i].tags?.contains(old) == true {
            drafts[i].tags = Self.unique(drafts[i].tags!.map { $0 == old ? new : $0 })
            changed = true
        }
        for (k, v) in strokeTags where v.contains(old) {
            strokeTags[k] = Self.unique(v.map { $0 == old ? new : $0 })
            changed = true
        }
        return changed
    }

    /// A tag gone from this file: its notes keep their other tags (with none, they show only with everything).
    @discardableResult
    mutating func removeTag(_ tag: String) -> Bool {
        var changed = false
        for i in drafts.indices where drafts[i].tags?.contains(tag) == true {
            drafts[i].tags?.removeAll { $0 == tag }
            changed = true
        }
        for (k, v) in strokeTags where v.contains(tag) {
            strokeTags[k] = v.filter { $0 != tag }
            changed = true
        }
        return changed
    }

    /// This module's notes as the cross-module views see them (by tag, over time).
    func entries(module: String) -> [NoteEntry] {
        drafts.map { d in
            let tags = d.tags ?? []
            return NoteEntry(id: d.id, module: module, tags: tags.filter { $0 != NoteTags.scratchpad }, createdAt: d.createdAt,
                             text: d.reading?.text ?? d.raw ?? d.note.text ?? "", question: d.note.intent == .question,
                             scratch: tags.contains(NoteTags.scratchpad))
        }
    }

    /// Every module's kept notes, for seeing them by tag or combination of tags, and over time. Reads the files: call
    /// it off the main thread.
    static func allEntries(folder: URL? = folder) -> [NoteEntry] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.lastPathComponent.hasPrefix("code-") }.flatMap { url -> [NoteEntry] in
            guard let data = try? Data(contentsOf: url), let book = try? JSONDecoder().decode(CodeNoteBook.self, from: data),
                  let module = book.module else { return [] }
            return book.entries(module: module)
        }
    }

    private static func unique(_ tags: [String]) -> [String] { tags.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    // MARK: keeping it

    /// What the web page kept for a file (`InkSurfaceView`'s saved ink), read to bring it over.
    struct WebSaved: Codable { var drawing: Data; var drafts: [DraftNote] }

    /// The first native pages kept notes in named pages, one shown at a time. Read to bring them over as tags.
    struct OldPage: Codable { var name: String; var drawing: Data; var drafts: [DraftNote] }
    struct OldBook: Codable { var pages: [OldPage]; var lineHeight: CGFloat?; var paper: Int? }

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
        if let data = try? Data(contentsOf: url("code-\(key)", in: folder)) {
            if let old = try? JSONDecoder().decode(OldBook.self, from: data) { return fromPages(old) }
            if let book = try? JSONDecoder().decode(CodeNoteBook.self, from: data) { return book }
        }
        var book = CodeNoteBook()
        book.lineHeight = geometry.lineHeight
        if let data = try? Data(contentsOf: url(key, in: folder)), let old = try? JSONDecoder().decode(WebSaved.self, from: data),
           let drawing = try? PKDrawing(data: old.drawing), let earlier = earlierNotes(drawing, old.drafts, geometry: geometry) {
            book.drawing = earlier.drawing.dataRepresentation()
            book.drafts = earlier.drafts
        }
        return book
    }

    /// Note pages become tags of the same name; pages that kept their given name ("Note 1") weren't named for
    /// anything, so their notes have no tag.
    static func fromPages(_ old: OldBook) -> CodeNoteBook {
        var book = CodeNoteBook()
        book.lineHeight = old.lineHeight
        book.paper = old.paper
        var strokes: [PKStroke] = []
        for page in old.pages {
            let tag = page.name.range(of: #"^Note \d+$"#, options: .regularExpression) == nil ? [page.name] : []
            let drawing = (try? PKDrawing(data: page.drawing)) ?? PKDrawing()
            let inNotes = page.drafts.reduce(into: Set<UUID>()) { $0.formUnion($1.strokeIDs) }
            strokes += drawing.strokes
            for s in drawing.strokes where !inNotes.contains(s.id) { book.strokeTags[s.id] = tag }
            // Filed already: they aren't offered for tagging.
            book.drafts += page.drafts.map { var d = $0; d.tags = tag; d.tagsReviewed = true; return d }
        }
        book.drawing = PKDrawing(strokes: strokes).dataRepresentation()
        return book
    }

    /// The page is drawn at another size (the user's text size changed): the ink scales with it, so each note stays on
    /// its lines.
    mutating func fit(lineHeight new: CGFloat) {
        let old = lineHeight ?? 20
        lineHeight = new
        guard abs(new - old) > 0.01, let drawing = try? PKDrawing(data: drawing) else { return }
        let t = CGAffineTransform(scaleX: new / old, y: new / old)
        var renamed: [UUID: UUID] = [:]
        let strokes = drawing.strokes.map { s in
            let moved = PKStroke(ink: s.ink, path: s.path, transform: s.transform.concatenating(t), mask: s.mask, randomSeed: s.randomSeed)
            renamed[s.id] = moved.id
            return moved
        }
        self.drawing = PKDrawing(strokes: strokes).dataRepresentation()
        strokeTags = Dictionary(strokeTags.map { (renamed[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        for j in drafts.indices {
            drafts[j].strokeIDs = Set(drafts[j].strokeIDs.map { renamed[$0] ?? $0 })
            drafts[j].bounds = drafts[j].bounds.applying(t)
            drafts[j].tagged = drafts[j].tagged?.mapValues { $0.applying(t) }
        }
    }

    func save(key: String, folder: URL? = folder) {
        var book = self
        if key.hasPrefix("file-") { book.module = String(key.dropFirst(5)) }
        guard let folder, let data = try? JSONEncoder().encode(book) else { return }
        try? data.write(to: Self.url("code-\(key)", in: folder), options: .atomic)
    }

    /// One file's kept book, changed and saved (a note's tags set in a review, after its page closed).
    static func update(key: String, folder: URL? = folder, _ change: (inout CodeNoteBook) -> Void) {
        guard let folder, let data = try? Data(contentsOf: url("code-\(key)", in: folder)),
              var book = try? JSONDecoder().decode(CodeNoteBook.self, from: data) else { return }
        change(&book)
        book.save(key: key, folder: folder)
    }

    /// Every file's kept book, changed and saved where `change` says so (a tag renamed or removed everywhere).
    static func updateAll(folder: URL? = folder, _ change: (inout CodeNoteBook) -> Bool) {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for url in files where url.lastPathComponent.hasPrefix("code-") {
            guard let data = try? Data(contentsOf: url), (try? JSONDecoder().decode(OldBook.self, from: data)) == nil,
                  var book = try? JSONDecoder().decode(CodeNoteBook.self, from: data), change(&book),
                  let out = try? JSONEncoder().encode(book) else { continue }
            try? out.write(to: url, options: .atomic)
        }
    }

    /// The web page's notes on this page's lines: each moved so its top sits on its first tagged line, under the
    /// "Earlier notes" tag. Notes that weren't tagged to a line, and ink that wasn't in a note, have nowhere to go and
    /// are left behind.
    static func earlierNotes(_ drawing: PKDrawing, _ drafts: [DraftNote], geometry: CodePageGeometry) -> (drawing: PKDrawing, drafts: [DraftNote])? {
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
            d.tagged = [InkNoteTaker.lineKey: CGPoint(x: 0, y: geometry.rect(line: line, width: 0).minY)]
            d.anchorCenter = nil
            d.tags = [earlierName]
            d.tagsReviewed = true
            kept.append(d)
        }
        guard !kept.isEmpty else { return nil }
        return (PKDrawing(strokes: strokes), kept)
    }
}
#endif
