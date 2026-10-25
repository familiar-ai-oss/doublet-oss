import DuetKit
import Testing
@testable import Duet

/// A ```mermaid block in an answer shows as a diagram card (FencedDiagram): which blocks, and the diagram each makes.
struct FencedDiagramTests {
    /// The side chat's answer of 2026-10-23 that showed as source: it had no diagram tool, so it wrote one.
    private let flowchart = """
    flowchart LR
      Q["Catch the second spots<br/>(6 of 20 misses)"]
      Q --> T1["Word list (today)<br/>15 / 84"]
      T1 --> R["Best: ~25%"]
    """

    @Test func aMermaidBlockIsADiagram() throws {
        let d = try #require(FencedDiagram.diagram(info: "mermaid", source: flowchart + "\n"))
        #expect(d.kind == .mermaid)
        #expect(d.source == flowchart)
        #expect(d.title == "Diagram")
        #expect(d.id.hasPrefix("fence-"))
        // The same source is the same diagram (its still is kept, its card keeps its place); another isn't.
        #expect(FencedDiagram.diagram(info: "mermaid", source: flowchart)?.id == d.id)
        #expect(FencedDiagram.diagram(info: "mermaid", source: flowchart + "\n  R --> Q")?.id != d.id)
    }

    @Test func theLanguageIsTheInfoStringsFirstWord() {
        #expect(FencedDiagram.diagram(info: "Mermaid", source: flowchart) != nil)
        #expect(FencedDiagram.diagram(info: "  mermaid title=x", source: flowchart) != nil)
        #expect(FencedDiagram.diagram(info: "swift", source: flowchart) == nil)
        #expect(FencedDiagram.diagram(info: "mermaidjs", source: flowchart) == nil)
        #expect(FencedDiagram.diagram(info: nil, source: flowchart) == nil)
        #expect(FencedDiagram.diagram(info: "", source: flowchart) == nil)
    }

    @Test func anEmptyBlockStaysCode() {
        #expect(FencedDiagram.diagram(info: "mermaid", source: "") == nil)
        #expect(FencedDiagram.diagram(info: "mermaid", source: " \n\n ") == nil)
    }

    @Test func mermaidsOwnTitleNamesTheCard() {
        let front = "---\ntitle: \"Second spots\"\n---\nflowchart LR\n  A --> B"
        #expect(FencedDiagram.diagram(info: "mermaid", source: front)?.title == "Second spots")
        #expect(FencedDiagram.title("pie\n  title Misses\n  \"wording\" : 3") == "Misses")
        #expect(FencedDiagram.title("journey\n  title A day\n  section Morning") == "A day")
        #expect(FencedDiagram.title("flowchart LR\n  A --> B") == nil)
        // Front matter that never closes isn't a title.
        #expect(FencedDiagram.title("---\ntitle: x\nflowchart LR") == nil)
    }
}
