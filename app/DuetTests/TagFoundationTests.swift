#if os(iOS)
import DuetKit
import Foundation
import PencilKit
import Testing
@testable import Duet

/// The ground for seeing notes by tag across modules and over time: notes keep when they were written and which
/// module they're on, the scratchpad stays out of the filing, and the scratchpad can't be typed or listed as a tag.
@MainActor
struct TagFoundationTests {
    private static func draft(_ id: String, tags: [String]?, at: Date? = nil) -> DraftNote {
        var d = DraftNote(note: InkNote(id: id, intent: .question, text: "why \(id)?"), strokeIDs: [], bounds: .zero)
        d.tags = tags
        d.createdAt = at
        return d
    }

    @Test func notesOnTheScratchpadAreNeitherFiledNorReviewed() {
        var book = CodeNoteBook()
        book.merge(PKDrawing(), drafts: [Self.draft("a", tags: nil)], shown: ([], []), tag: NoteTags.scratchpad)
        #expect(book.drafts.first?.tags == [NoteTags.scratchpad])
        #expect(book.drafts.first?.tagsReviewed == true)
        let e = book.entries(module: "Lexer.swift")
        #expect(e.first?.scratch == true)
        #expect(e.first?.tags.isEmpty == true)
        // Not in any tag's view, nor in the tag counts.
        #expect(NoteLedger.query(e, NoteFilter()).isEmpty)
        #expect(NoteLedger.tagCounts(e).isEmpty)
    }

    @Test func everyModulesNotesCanBeSeenByTagOverTime() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var lexer = CodeNoteBook(), parser = CodeNoteBook()
        lexer.drafts = [Self.draft("a", tags: ["security"], at: t)]
        parser.drafts = [Self.draft("b", tags: ["security", "parsing"], at: t + 60)]
        lexer.save(key: "file-Sources/Lexer.swift", folder: folder)
        parser.save(key: "file-Sources/Parser.swift", folder: folder)
        let all = CodeNoteBook.allEntries(folder: folder)
        #expect(Set(all.map(\.module)) == ["Sources/Lexer.swift", "Sources/Parser.swift"])
        #expect(NoteLedger.query(all, NoteFilter(tags: ["security"])).map(\.id) == ["b", "a"])
        #expect(NoteLedger.query(all, NoteFilter(tags: ["security", "parsing"])).map(\.id) == ["b"])
    }

    @Test func theScratchpadIsNoTagYouCanTypeOrList() {
        #expect(NoteTags.clean(NoteTags.scratchpad) == "scratchpad") // typed, the hidden mark is dropped
        let tags = NoteTags(defaults: UserDefaults(suiteName: "tags-\(UUID().uuidString)")!)
        tags.use([NoteTags.scratchpad, "cyber"])
        #expect(tags.all == ["cyber"])
        tags.pick(NoteTags.scratchpad)
        #expect(tags.onScratchpad)
        #expect(tags.ranked(onFile: [NoteTags.scratchpad, "cyber"]).here == ["cyber"])
    }
}
#endif
