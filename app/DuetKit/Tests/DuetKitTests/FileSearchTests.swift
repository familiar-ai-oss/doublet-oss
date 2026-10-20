import Testing
@testable import DuetKit

@Test func goToFileFindsTheFileYouMeanFirst() {
    let s = FileSearch([
        "test/fleet-old/x.ts", "src/fleet.ts", "src/dialogue.ts", "docs/fleet-notes.md", "src/profiles.ts",
        "app/Duet/Files/Explorer.swift", "app/DuetKit/Sources/DuetKit/FileSearch.swift", "README.md",
    ])
    let fleet = s.rank("fleet")
    #expect(fleet.first == "src/fleet.ts", "in the name, together, and the shortest such path")
    #expect(fleet.firstIndex(of: "docs/fleet-notes.md")! < fleet.firstIndex(of: "test/fleet-old/x.ts")!, "a match in a folder's name counts least")
    #expect(s.rank("expl").first == "app/Duet/Files/Explorer.swift")
    #expect(s.rank("fs sw").first == "app/DuetKit/Sources/DuetKit/FileSearch.swift", "spaces ignored, letters in order")
    #expect(s.rank("dlg").first == "src/dialogue.ts")
    #expect(s.rank("zzz").isEmpty)
    #expect(s.rank("").count == 8 && s.rank("", limit: 3).count == 3, "nothing typed: the first files")
    #expect(s.rank("SRC/PRO") == ["src/profiles.ts"], "any case")
}
