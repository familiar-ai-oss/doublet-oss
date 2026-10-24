#if os(iOS)
import DuetKit
import Foundation
import PencilKit
import Testing
@testable import Duet

/// The native code page's lines, its note pages, and the web page's ink brought over to it.
@MainActor
struct CodeNotePagesTests {
    private static let text = (1...30).map { "let v\($0) = \($0)" }.joined(separator: "\n") + "\n"
    private let geometry = CodePageGeometry(text: text, advance: 8)

    @Test func linesSitAtFixedHeights() {
        #expect(geometry.lineCount == 30) // the final newline doesn't start a line
        #expect(geometry.gutter == 4)
        #expect(geometry.rect(line: 1, width: 500).minY == CodePageGeometry.top)
        #expect(geometry.rect(line: 10, width: 500).minY == CodePageGeometry.top + 9 * CodePageGeometry.lineHeight)
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

    @Test func pagesAreNamedAddedRenamedAndRemoved() {
        var book = CodeNoteBook()
        #expect(book.pages.map(\.name) == ["Note 1"])
        let second = book.add()
        #expect(book.current == second && book.page.name == "Note 2")
        book.add(named: "  Review pass  ")
        #expect(book.page.name == "Review pass")
        book.rename(second, to: "")
        #expect(book.pages[1].name == "Note 2") // an empty name is ignored
        book.remove(book.current)
        #expect(book.pages.map(\.name) == ["Note 1", "Note 2"] && book.current == second)
        book.remove(book.pages[0].id)
        book.remove(book.pages[0].id)
        #expect(book.pages.count == 1 && book.page.name == "Note 1") // always one to write on
    }

    @Test func aBookIsKeptPerFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var book = CodeNoteBook.load(key: "file-/p/a.swift", geometry: geometry, folder: folder)
        book.add(named: "Second look")
        book.save(key: "file-/p/a.swift", folder: folder)
        let again = CodeNoteBook.load(key: "file-/p/a.swift", geometry: geometry, folder: folder)
        #expect(again == book)
        #expect(CodeNoteBook.load(key: "file-/p/b.swift", geometry: geometry, folder: folder).pages.map(\.name) == ["Note 1"])
    }

    @Test func webInkMovesToItsTaggedLines() throws {
        // A note written on the web page at y 300 about line 12, and ink in no note.
        let stroke = Self.stroke(at: CGPoint(x: 200, y: 300))
        let loose = Self.stroke(at: CGPoint(x: 50, y: 900))
        let note = InkNote(id: "n1", intent: .comment, text: "why", lines: [InkLines(file: "/p/a.swift", start: 12, end: 12, code: "let v12 = 12")])
        let draft = DraftNote(note: note, strokeIDs: [stroke.id], bounds: stroke.renderBounds)
        let untagged = DraftNote(note: InkNote(id: "n2", intent: .comment), strokeIDs: [loose.id], bounds: loose.renderBounds)
        let page = try #require(CodeNoteBook.earlierNotes(PKDrawing(strokes: [stroke, loose]), [draft, untagged], geometry: geometry))
        #expect(page.name == CodeNoteBook.earlierName)
        #expect(page.drafts.map(\.id) == ["n1"])
        let moved = try PKDrawing(data: page.drawing).strokes
        #expect(moved.count == 1)
        #expect(abs(moved[0].renderBounds.minY - geometry.rect(line: 12, width: 1).minY) < 0.5)
        #expect(abs(moved[0].renderBounds.minX - stroke.renderBounds.minX) < 0.5)
        #expect(page.drafts[0].strokeIDs == [moved[0].id])
        #expect(abs(page.drafts[0].bounds.minY - geometry.rect(line: 12, width: 1).minY) < 0.5)
    }

    @Test func webInkComesOverOnceAndFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stroke = Self.stroke(at: CGPoint(x: 200, y: 300))
        let note = InkNote(id: "n1", intent: .comment, lines: [InkLines(file: "/p/a.swift", start: 3, end: 3, code: nil)])
        let old = CodeNoteBook.WebSaved(drawing: PKDrawing(strokes: [stroke]).dataRepresentation(), drafts: [DraftNote(note: note, strokeIDs: [stroke.id], bounds: stroke.renderBounds)])
        try JSONEncoder().encode(old).write(to: CodeNoteBook.url("file-/p/a.swift", in: folder))
        let book = CodeNoteBook.load(key: "file-/p/a.swift", geometry: geometry, folder: folder)
        #expect(book.pages.map(\.name) == [CodeNoteBook.earlierName, "Note 1"])
        #expect(book.page.name == CodeNoteBook.earlierName)
        // The web page's own copy is left as it was.
        #expect(FileManager.default.fileExists(atPath: CodeNoteBook.url("file-/p/a.swift", in: folder).path))
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
