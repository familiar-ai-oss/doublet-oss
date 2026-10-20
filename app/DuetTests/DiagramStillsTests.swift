import DuetKit
import Foundation
import Testing
@testable import Duet

/// The stills diagram cards show (DiagramStills): what names one, and drawing them off screen.
@MainActor
struct DiagramStillsTests {
    private func diagram(_ source: String, kind: DiagramKind = .mermaid, id: String = "g1", version: Int = 1) -> DiagramEvent {
        DiagramEvent(id: id, version: version, title: "Lexer states", kind: kind, source: source)
    }

    /// A source no earlier run drew, so it isn't on disk yet.
    private func fresh() -> String { "stateDiagram-v2\n    [*] --> Start\n    Start --> Done: t\(UUID().uuidString.prefix(8))" }

    @Test func aStillIsNamedByWhatItShows() {
        let a = diagram("stateDiagram-v2\n    [*] --> Start")
        let key = DiagramStills.Key(a, dark: false, height: 320)
        // Another diagram, version or hub with the same source shows the same thing.
        #expect(DiagramStills.Key(diagram(a.source, id: "fh-7", version: 3), dark: false, height: 320) == key)
        #expect(DiagramStills.Key(a, dark: true, height: 320) != key)
        #expect(DiagramStills.Key(a, dark: false, height: 230) != key)
        #expect(DiagramStills.Key(diagram(a.source + "\n    Start --> [*]"), dark: false, height: 320) != key)
        #expect(DiagramStills.Key(diagram(a.source, kind: .html), dark: false, height: 320) != key)
    }

    @Test func drawsAMermaidDiagramFittedToTheCard() async {
        let d = diagram(fresh())
        let key = DiagramStills.Key(d, dark: false, height: 320)
        let still = await DiagramStills.shared.still(of: d, key: key, dark: false, height: 320)
        guard case .image(let image)? = still else { Issue.record("no still: \(String(describing: still))"); return }
        // Inside the card's 320 pt, less the page's margins, and drawn at the screen's scale.
        #expect(image.size.height > 40 && image.size.height <= 300)
        #expect(image.size.width > 20 && image.size.width <= 1180)
        #expect(image.scale >= 2)
        #expect(DiagramStills.shared.cached(key) != nil)
        // Dark is drawn on its own.
        let darkKey = DiagramStills.Key(d, dark: true, height: 320)
        #expect(DiagramStills.shared.cached(darkKey) == nil)
        guard case .image? = await DiagramStills.shared.still(of: d, key: darkKey, dark: true, height: 320) else { Issue.record("no dark still"); return }
    }

    @Test func drawsClaudesPageAtACardsWidth() async {
        let d = diagram("<!doctype html><body style='margin:16px'><h3>Step \(UUID().uuidString.prefix(8))</h3></body>", kind: .html)
        let key = DiagramStills.Key(d, dark: false, height: 230)
        guard case .image(let image)? = await DiagramStills.shared.still(of: d, key: key, dark: false, height: 230) else { Issue.record("no still"); return }
        #expect(image.size == CGSize(width: 720, height: 230))
    }

    @Test func aBrokenDiagramSaysWhy() async {
        let d = diagram("flowchart TD\n    A --> t\(UUID().uuidString.prefix(8)) -->")
        let key = DiagramStills.Key(d, dark: false, height: 320)
        guard case .failed(let why)? = await DiagramStills.shared.still(of: d, key: key, dark: false, height: 320) else { Issue.record("drew it"); return }
        #expect(!why.isEmpty)
    }

    @Test func aCardThatGoesAwayStopsWaiting() async {
        let d = diagram(fresh())
        let key = DiagramStills.Key(d, dark: false, height: 320)
        let waiting = Task { await DiagramStills.shared.still(of: d, key: key, dark: false, height: 320) }
        // Waiting its turn by now (a drawing takes far longer).
        try? await Task.sleep(for: .milliseconds(10))
        waiting.cancel()
        #expect(await waiting.value == nil)
    }
}
