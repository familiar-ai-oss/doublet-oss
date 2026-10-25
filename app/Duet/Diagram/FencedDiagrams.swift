import CryptoKit
import DuetKit
import MarkdownUI
import SwiftUI

/// A diagram written into an answer as a ```mermaid block instead of drawn with Doublet's diagram tool (a side chat has
/// no tool to draw with): shown as a diagram card, not as its source. It's the answer's own, so it isn't in the
/// conversation's diagrams; a tap opens it full size here.
enum FencedDiagram {
    /// The diagram a fenced code block shows, if its language is Mermaid and it has something in it. `info` is the
    /// fence's info string ("mermaid", "Mermaid title=x", …): its first word is the language.
    static func diagram(info: String?, source: String) -> DiagramEvent? {
        let language = info?.split(whereSeparator: \.isWhitespace).first?.lowercased()
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard language == "mermaid", !source.isEmpty else { return nil }
        let hash = SHA256.hash(data: Data(source.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return DiagramEvent(id: "fence-\(hash)", version: 1, title: title(source) ?? "Diagram", kind: .mermaid, source: source, by: "answer")
    }

    /// Mermaid's own title, from front matter (`---\ntitle: …\n---`) or a `title …` line (journey, gantt, pie).
    static func title(_ source: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            for line in lines[1..<end] where line.hasPrefix("title:") {
                let t = line.dropFirst(6).trimmingCharacters(in: CharacterSet.whitespaces.union(["\"", "'"]))
                if !t.isEmpty { return t }
            }
        }
        for line in lines.prefix(3) where line.hasPrefix("title ") {
            let t = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return nil
    }
}

extension View {
    /// Markdown here shows ```mermaid blocks as diagram cards; other code blocks look as they always did (MarkdownUI's
    /// basic theme).
    func diagramFences() -> some View {
        markdownBlockStyle(\.codeBlock) { configuration in
            if let d = FencedDiagram.diagram(info: configuration.language, source: configuration.content) {
                FencedDiagramCard(diagram: d)
                    .markdownMargin(top: .zero, bottom: .em(1))
            } else {
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.15))
                        .relativePadding(.leading, length: .rem(1))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.94))
                        }
                }
                .markdownMargin(top: .zero, bottom: .em(1))
            }
        }
    }
}

/// A fenced diagram's card; a tap opens it full size in a sheet (it has no place of its own to open in).
private struct FencedDiagramCard: View {
    let diagram: DiagramEvent
    @State private var open = false

    var body: some View {
        DiagramCard(diagram: diagram, open: { open = true })
            .sheet(isPresented: $open) { FencedDiagramSheet(diagram: diagram) }
    }
}

private struct FencedDiagramSheet: View {
    let diagram: DiagramEvent
    @Environment(\.dismiss) private var dismiss
    @State private var page = DiagramPage()

    var body: some View {
        NavigationStack {
            DiagramWebView(page: page, document: DiagramDocument(diagram))
                .navigationTitle(diagram.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Copy Source", systemImage: "doc.on.doc") { Pasteboard.copy(diagram.source) }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 480)
        #endif
    }
}
