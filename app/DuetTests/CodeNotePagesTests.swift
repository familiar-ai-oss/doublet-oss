#if os(iOS)
import DuetKit
import Foundation
import PencilKit
import Testing
@testable import Duet

/// The native code page's lines, its notes filed under tags, and the web page's ink brought over to it.
@MainActor
struct CodeNotePagesTests {
    private static let text = (1...30).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n"
    private let geometry = CodePageGeometry(text: text, advance: 8)

    @Test func linesSitAtFixedHeights() {
        #expect(geometry.lineCount == 30) // the final newline doesn't start a line
        #expect(geometry.gutter == 4)
        #expect(geometry.rect(line: 1, width: 500).minY == geometry.top)
        #expect(geometry.rect(line: 10, width: 500).minY == geometry.top + 9 * geometry.lineHeight)
        #expect(geometry.line(at: geometry.rect(line: 7, width: 1).midY) == 7)
        #expect(geometry.line(at: 0) == nil)
        #expect(geometry.line(at: 10_000) == nil)
        #expect(geometry.lines(in: CGRect(x: 0, y: geometry.rect(line: 3, width: 1).midY, width: 1, height: 45)) == 3...5)
    }

    @Test func aStrokeOverLineNIsTaggedToLineN() {
        let anchors = geometry.anchors(path: "/p/a.swift", text: Self.text, width: 600)
        #expect(anchors.count == 30)
        #expect(anchors[11].id == "L12" && anchors[11].line == 12 && anchors[11].label == "let v12 = 12")
        let r = geometry.rect(line: 12, width: 600)
        // A cross drawn over line 12's code: remove that line.
        let a = (0...10).map { CGPoint(x: 120 + CGFloat($0) * 3, y: r.minY + 2 + CGFloat($0) * 1.6) }
        let b = (0...10).map { CGPoint(x: 150 - CGFloat($0) * 3, y: r.minY + 2 + CGFloat($0) * 1.6) }
        let shape = InkGeometry.classify([a, b])
        #expect(shape.shape == .cross)
        let note = InkTagger.note(id: "n", shape: shape, text: nil, color: .other, anchors: anchors, diff: true)
        #expect(note.lines?.map(\.start) == [12])
    }

    @Test func theCodeIsLargerThanAnEditorsAndLinesFollowItsSize() {
        #expect(geometry.fontSize == 16 && geometry.lineHeight == 24)
        let larger = CodePageGeometry(text: Self.text, advance: 10, fontSize: 20)
        #expect(larger.lineHeight == 30)
        #expect(larger.rect(line: 5, width: 1).minY > geometry.rect(line: 5, width: 1).minY)
    }

    @Test func inkScalesWithTheTextSize() throws {
        let stroke = Self.stroke(at: CGPoint(x: 100, y: 200))
        let loose = Self.stroke(at: CGPoint(x: 100, y: 400))
        var book = CodeNoteBook()
        book.drawing = PKDrawing(strokes: [stroke, loose]).dataRepresentation()
        book.drafts = [DraftNote(note: InkNote(id: "n", intent: .comment), strokeIDs: [stroke.id], bounds: stroke.renderBounds)]
        book.strokeTags = [loose.id: ["cyber"]]
        book.lineHeight = 20
        book.fit(lineHeight: 30)
        let moved = try PKDrawing(data: book.drawing).strokes
        #expect(abs(moved[0].renderBounds.midY - stroke.renderBounds.midY * 1.5) < 1)
        #expect(book.drafts[0].strokeIDs == [moved[0].id])
        #expect(book.strokeTags == [moved[1].id: ["cyber"]]) // a loose stroke keeps its tag
        #expect(book.lineHeight == 30)
        // Already that size: nothing moves.
        book.fit(lineHeight: 30)
        #expect(try PKDrawing(data: book.drawing).strokes.map(\.id) == moved.map(\.id))
    }

    /// A book with a cyber note, a storage note, a note with both, and a loose stroke under cyber.
    private func tagged() -> (book: CodeNoteBook, strokes: [PKStroke]) {
        let s = (0..<4).map { Self.stroke(at: CGPoint(x: 100, y: 100 + CGFloat($0) * 100)) }
        var book = CodeNoteBook()
        book.drawing = PKDrawing(strokes: s).dataRepresentation()
        book.drafts = [
            Self.draft("c", s[0], tags: ["cyber"]),
            Self.draft("s", s[1], tags: ["storage"]),
            Self.draft("b", s[2], tags: ["cyber", "storage"]),
        ]
        book.strokeTags = [s[3].id: ["cyber"]]
        return (book, s)
    }

    @Test func aTagShowsOnlyItsNotesAndInk() {
        let (book, s) = tagged()
        let cyber = book.visible("cyber")
        #expect(cyber.drafts.map(\.id) == ["c", "b"])
        #expect(Set(cyber.drawing.strokes.map(\.id)) == [s[0].id, s[2].id, s[3].id])
        #expect(book.visible("storage").drafts.map(\.id) == ["s", "b"])
        #expect(book.visible("nothing").drafts.isEmpty)
        // Every note, with no tag picked.
        #expect(book.visible(nil).drafts.count == 3 && book.visible(nil).drawing.strokes.count == 4)
        #expect(book.tags == ["cyber", "storage"])
    }

    @Test func writingUnderATagFilesTheNoteThere() {
        var (book, _) = tagged()
        let v = book.visible("storage")
        let shown = (strokes: Set(v.drawing.strokes.map(\.id)), drafts: Set(v.drafts.map(\.id)))
        let new = Self.stroke(at: CGPoint(x: 300, y: 600)), loose = Self.stroke(at: CGPoint(x: 300, y: 700))
        var drafts = v.drafts
        drafts.append(Self.draft("n", new, tags: nil))
        book.merge(PKDrawing(strokes: v.drawing.strokes + [new, loose]), drafts: drafts, shown: shown, tag: "storage")
        #expect(book.drafts.first { $0.id == "n" }?.tags == ["storage"])
        #expect(book.strokeTags[loose.id] == ["storage"])
        // What the page didn't show is kept as it was.
        #expect(Set(book.drafts.map(\.id)) == ["c", "s", "b", "n"])
        #expect(try! PKDrawing(data: book.drawing).strokes.count == 6)
        // Written with every note showing: no tag.
        var all = book
        let a = all.visible(nil)
        let free = Self.stroke(at: CGPoint(x: 10, y: 10))
        all.merge(PKDrawing(strokes: a.drawing.strokes + [free]), drafts: a.drafts + [Self.draft("f", free, tags: nil)],
                  shown: (Set(a.drawing.strokes.map(\.id)), Set(a.drafts.map(\.id))), tag: nil)
        #expect(all.drafts.first { $0.id == "f" }?.tags == nil)
    }

    @Test func erasingANoteUnderATagRemovesItFromEveryTag() {
        var (book, s) = tagged()
        let v = book.visible("storage")
        let shown = (strokes: Set(v.drawing.strokes.map(\.id)), drafts: Set(v.drafts.map(\.id)))
        // The note with both tags rubbed out while seen through storage.
        book.merge(PKDrawing(strokes: v.drawing.strokes.filter { $0.id != s[2].id }), drafts: v.drafts.filter { $0.id != "b" }, shown: shown, tag: "storage")
        #expect(book.visible("cyber").drafts.map(\.id) == ["c"])
        #expect(!(try! PKDrawing(data: book.drawing).strokes.contains { $0.id == s[2].id }))
    }

    @Test func theSameIdeaOnTwoFilesIsTwoNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for file in ["module.rs", "anchor.rs"] {
            var book = CodeNoteBook.load(key: "file-/p/\(file)", geometry: geometry, folder: folder)
            let s = Self.stroke(at: CGPoint(x: 100, y: 100))
            book.drawing = PKDrawing(strokes: [s]).dataRepresentation()
            book.drafts = [Self.draft("\(file)-n", s, tags: ["cyber"])]
            book.save(key: "file-/p/\(file)", folder: folder)
        }
        var module = CodeNoteBook.load(key: "file-/p/module.rs", geometry: geometry, folder: folder)
        module.drafts = []
        module.save(key: "file-/p/module.rs", folder: folder)
        // Erased on one file, the other file's note stays.
        #expect(CodeNoteBook.load(key: "file-/p/anchor.rs", geometry: geometry, folder: folder).visible("cyber").drafts.count == 1)
    }

    @Test func aTagIsRenamedMergedAndDeletedEverywhere() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        tagged().book.save(key: "file-/p/a.rs", folder: folder)
        CodeNoteBook.updateAll(folder: folder) { $0.renameTag("storage", to: "cyber") }
        var book = CodeNoteBook.load(key: "file-/p/a.rs", geometry: geometry, folder: folder)
        #expect(book.drafts.map { $0.tags ?? [] } == [["cyber"], ["cyber"], ["cyber"]]) // merged, never twice
        book.removeTag("cyber")
        #expect(book.visible(nil).drafts.count == 3) // the notes stay
        #expect(book.tags.isEmpty && book.strokeTags.values.allSatisfy(\.isEmpty))
    }

    @Test func notePagesBecomeTags() throws {
        let a = Self.stroke(at: CGPoint(x: 100, y: 100)), b = Self.stroke(at: CGPoint(x: 100, y: 200)), loose = Self.stroke(at: CGPoint(x: 100, y: 300))
        let old = CodeNoteBook.OldBook(pages: [
            .init(name: "Note 1", drawing: PKDrawing(strokes: [a]).dataRepresentation(), drafts: [Self.draft("a", a, tags: nil)]),
            .init(name: "Review pass", drawing: PKDrawing(strokes: [b, loose]).dataRepresentation(), drafts: [Self.draft("b", b, tags: nil)]),
        ], lineHeight: 24, paper: 80)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONEncoder().encode(old).write(to: CodeNoteBook.url("code-file-/p/a.rs", in: folder))
        let book = CodeNoteBook.load(key: "file-/p/a.rs", geometry: geometry, folder: folder)
        #expect(book.paper == 80 && book.lineHeight == 24)
        #expect(book.drafts.map { $0.tags ?? [] } == [[], ["Review pass"]]) // "Note 1" wasn't named for anything
        #expect(book.strokeTags[loose.id] == ["Review pass"])
        #expect(book.visible(nil).drawing.strokes.count == 3)
    }

    @Test func aBookIsKeptPerFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var book = tagged().book
        book.paper = 72
        book.save(key: "file-/p/a.swift", folder: folder)
        // Kept with the module it's on, so every module's notes can be listed together.
        book.module = "/p/a.swift"
        #expect(CodeNoteBook.load(key: "file-/p/a.swift", geometry: geometry, folder: folder) == book)
        #expect(CodeNoteBook.load(key: "file-/p/b.swift", geometry: geometry, folder: folder).drafts.isEmpty)
    }

    @Test func webInkMovesToItsTaggedLines() throws {
        // A note written on the web page at y 300 about line 12, and ink in no note.
        let stroke = Self.stroke(at: CGPoint(x: 200, y: 300))
        let loose = Self.stroke(at: CGPoint(x: 50, y: 900))
        let note = InkNote(id: "n1", intent: .comment, text: "why", lines: [InkLines(file: "/p/a.swift", start: 12, end: 12, code: "let v12 = 12")])
        let draft = DraftNote(note: note, strokeIDs: [stroke.id], bounds: stroke.renderBounds)
        let untagged = DraftNote(note: InkNote(id: "n2", intent: .comment), strokeIDs: [loose.id], bounds: loose.renderBounds)
        let earlier = try #require(CodeNoteBook.earlierNotes(PKDrawing(strokes: [stroke, loose]), [draft, untagged], geometry: geometry))
        #expect(earlier.drafts.map(\.id) == ["n1"])
        #expect(earlier.drafts[0].tags == [CodeNoteBook.earlierName])
        let moved = earlier.drawing.strokes
        #expect(moved.count == 1)
        #expect(abs(moved[0].renderBounds.minY - geometry.rect(line: 12, width: 1).minY) < 0.5)
        #expect(abs(moved[0].renderBounds.minX - stroke.renderBounds.minX) < 0.5)
        #expect(earlier.drafts[0].strokeIDs == [moved[0].id])
        #expect(abs(earlier.drafts[0].bounds.minY - geometry.rect(line: 12, width: 1).minY) < 0.5)
    }

    @Test func webInkComesOverOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stroke = Self.stroke(at: CGPoint(x: 200, y: 300))
        let note = InkNote(id: "n1", intent: .comment, lines: [InkLines(file: "/p/a.swift", start: 3, end: 3, code: nil)])
        let old = CodeNoteBook.WebSaved(drawing: PKDrawing(strokes: [stroke]).dataRepresentation(), drafts: [DraftNote(note: note, strokeIDs: [stroke.id], bounds: stroke.renderBounds)])
        try JSONEncoder().encode(old).write(to: CodeNoteBook.url("file-/p/a.swift", in: folder))
        let book = CodeNoteBook.load(key: "file-/p/a.swift", geometry: geometry, folder: folder)
        #expect(book.visible(CodeNoteBook.earlierName).drafts.map(\.id) == ["n1"])
        // The web page's own copy is left as it was.
        #expect(FileManager.default.fileExists(atPath: CodeNoteBook.url("file-/p/a.swift", in: folder).path))
    }

    @Test func tagsAreSharedRankedAndCapped() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let tags = NoteTags(defaults: defaults)
        tags.use(["cyber", "storage"])
        tags.pick("call map")
        #expect(tags.current == "call map" && tags.all == ["call map", "cyber", "storage"])
        // The file's own tags first, then the rest.
        let r = tags.ranked(onFile: ["storage"])
        #expect(r.here == ["storage"] && r.other == ["call map", "cyber"])
        tags.pick("   ")
        #expect(tags.current == nil) // an empty name is every note
        #expect(NoteTags(defaults: defaults).all == tags.all) // kept
        #expect(NoteTags.limit == 5)
    }

    private static func draft(_ id: String, _ s: PKStroke, tags: [String]?) -> DraftNote {
        var d = DraftNote(note: InkNote(id: id, intent: .comment), strokeIDs: [s.id], bounds: s.renderBounds)
        d.tags = tags
        return d
    }

    private static func stroke(at p: CGPoint) -> PKStroke {
        let points = (0..<10).map { i in
            PKStrokePoint(location: CGPoint(x: p.x + CGFloat(i) * 4, y: p.y), timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
}
#endif
