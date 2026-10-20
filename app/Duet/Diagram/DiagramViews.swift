import DuetKit
import SwiftUI
import WebKit

/// A note being drawn or ready to send: its strokes (by UUID), what it means and is tagged to, and where it is.
struct DraftNote: Identifiable, Equatable, Codable {
    var note: InkNote
    var strokeIDs: Set<UUID>
    var bounds: CGRect
    /// Where each tagged element was when drawn (or last moved): the ink follows them when the diagram changes.
    var tagged: [String: CGPoint]?
    /// Ink saved before `tagged`: where its first element was.
    var anchorCenter: CGPoint?
    var sent = false
    /// What the handwriting says, read by Apple Intelligence (the raw words are kept in it). Nil until read.
    var reading: HandwritingReading?
    /// What PencilKit read, while the reading is on its way.
    var raw: String?
    /// Its kind was picked from the menu or the squeeze palette: a reading doesn't change it.
    var chosen: Bool?
    var id: String { note.id }
}

extension InkNote {
    func with(intent: InkIntent) -> InkNote {
        var n = self
        n.intent = intent
        return n
    }
}

/// How a handwritten note reads: an icon and a word for what it means, what it's on, and its words.
struct NoteDisplay {
    let note: InkNote
    init(_ note: InkNote) { self.note = note }

    var symbol: String {
        switch note.intent {
        case .comment: "text.bubble"
        case .change: "pencil"
        case .question: "questionmark.bubble"
        case .remove: "xmark"
        case .approve: "checkmark"
        case .connect: "arrow.right"
        case .group: "circle.dashed"
        case .emphasize: "hand.point.right"
        }
    }

    var verb: String {
        switch note.intent {
        case .comment: "Note"
        case .change: "Change"
        case .question: "Ask"
        case .remove: "Remove"
        case .approve: "Looks right"
        case .connect: note.lines?.isEmpty == false ? "Move" : "Connect"
        case .group: "Group"
        case .emphasize: "Look at"
        }
    }

    var tint: Color {
        switch note.intent {
        case .change, .remove: .penRed
        case .question: .penChalk
        case .approve: .penGreen
        case .connect: .purple
        case .group: .orange
        case .emphasize: .yellow
        case .comment: .gray
        }
    }

    var targets: String { on(page: false) }

    /// What it's on: elements by label, and lines with their file's name, or (on the page itself) just their numbers.
    private func on(page: Bool) -> String {
        // Short enough for a chip: a node's label can run to three lines.
        let elements = (note.elements ?? []).map { e in let l = e.label ?? e.id; return l.count > 24 ? String(l.prefix(23)) + "…" : l }
        let lines = (note.lines ?? []).map { l in
            let n = l.start == l.end ? "\(l.start)" : "\(l.start)–\(l.end)"
            return page ? (l.start == l.end ? "line \(n)" : "lines \(n)") : "\(l.file.split(separator: "/").last.map(String.init) ?? l.file):\(n)"
        }
        return (elements + lines).joined(separator: note.intent == .connect ? " → " : ", ")
    }

    var chip: String {
        var s = [verb, targets].filter { !$0.isEmpty }.joined(separator: " ")
        if let t = note.text, !t.isEmpty { s += ": “\(t.count > 60 ? String(t.prefix(59)) + "…" : t)”" }
        return s
    }

    /// Its chip on the page it was written on, beside the handwriting: the page is the file, so no file name.
    var pageChip: String {
        let on = on(page: true)
        var s = verb
        if !on.isEmpty {
            s = switch note.intent {
            case .question: "Ask about \(on)"
            case .comment: "Note on \(on)"
            case .approve: "Looks right · \(on)"
            default: "\(verb) \(on)"
            }
        }
        if let t = note.text, !t.isEmpty { s += ": “\(t.count > 48 ? String(t.prefix(47)) + "…" : t)”" }
        return s
    }
}

#if os(iOS)
/// A diagram page as a plain (scrolling, zooming) view: iPhone, previews, and Claude's HTML when not annotating.
struct DiagramWebView: UIViewRepresentable {
    let page: DiagramPage
    let document: DiagramDocument
    var interactive = true

    func makeUIView(context: Context) -> WKWebView {
        page.web.scrollView.isScrollEnabled = interactive
        page.web.isUserInteractionEnabled = interactive
        page.fitsHeight = !interactive
        page.load(document, dark: context.environment.colorScheme == .dark)
        return page.web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        page.load(document, dark: context.environment.colorScheme == .dark)
    }
}
#else
struct DiagramWebView: NSViewRepresentable {
    let page: DiagramPage
    let document: DiagramDocument
    var interactive = true

    func makeNSView(context: Context) -> WKWebView {
        page.fitsHeight = !interactive
        page.load(document, dark: context.environment.colorScheme == .dark)
        return page.web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        page.load(document, dark: context.environment.colorScheme == .dark)
    }
}
#endif

/// A diagram in Claude's thread: its title and a picture of it. Tap to open it full size (and, on iPad, write on it).
struct DiagramCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let diagram: DiagramEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(diagram.title, systemImage: diagram.kind == .html ? "safari" : "point.3.filled.connected.trianglepath.dotted")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                if diagram.version > 1 {
                    Text("v\(diagram.version)").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                        .background { Capsule().fill(.quaternary) }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption).foregroundStyle(.secondary)
            }
            let height: CGFloat = density == .compact ? 230 : 320
            Group {
                if SpeedSwitches.on("stills") {
                    DiagramStill(diagram: diagram, height: height)
                } else {
                    LiveDiagramPreview(diagram: diagram)
                }
            }
            .frame(height: height)
            .allowsHitTesting(false)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator) }
            if let c = diagram.caption, !c.isEmpty { Text(c).font(.caption).foregroundStyle(.secondary) }
            // The code it explains, a tap away: the file opens at those lines, where the diagram shows too.
            if let explains = diagram.explains, let first = explains.first {
                Button { model.openFile(first.path, line: first.start, compact: density == .compact) } label: {
                    Label("Explains \(first.label)" + (explains.count > 1 ? " and \(explains.count - 1) more" : ""),
                          systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary) }
        .contentShape(Rectangle())
        .onTapGesture { model.openDiagram(diagram.id, compact: density == .compact) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the diagram")
        .accessibilityActions {
            if let first = diagram.explains?.first {
                Button("Show the Code It Explains") { model.openFile(first.path, line: first.start, compact: density == .compact) }
            }
        }
    }
}

/// A card's picture of a diagram: its still (DiagramStills), fitted to the card as the live page fitted itself, with a
/// spinner until it's drawn (the first time, or in the other appearance: a light still is unreadable on a dark card).
private struct DiagramStill: View {
    let diagram: DiagramEvent
    let height: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @State private var still: (key: DiagramStills.Key, still: DiagramStills.Still)?

    var body: some View {
        let dark = colorScheme == .dark
        let key = DiagramStills.Key(diagram, dark: dark, height: height)
        // Kept in memory (a card scrolled back to): shown in this frame, not after a spinner.
        let shown = DiagramStills.shared.cached(key).map { DiagramStills.Still.image($0) } ?? (still?.key == key ? still?.still : nil)
        Group {
            switch shown {
            case .image(let image)?:
                Self.image(image).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                    .padding(10)
            case .failed(let why)?:
                Text(why).font(.caption.monospaced()).foregroundStyle(.stateFailed).lineLimit(8)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case nil:
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .task(id: key) {
            if let s = await DiagramStills.shared.still(of: diagram, key: key, dark: dark, height: height) { still = (key, s) }
        }
    }

    private static func image(_ image: PlatformImage) -> Image {
        #if os(iOS)
        Image(uiImage: image)
        #else
        Image(nsImage: image)
        #endif
    }
}

/// A card's picture as a live page of its own, as before stills (DUET_SPEED_OFF=stills).
private struct LiveDiagramPreview: View {
    let diagram: DiagramEvent
    @State private var page = DiagramPage()

    var body: some View {
        DiagramWebView(page: page, document: DiagramDocument(diagram), interactive: false)
    }
}

/// A diagram full size. Tap an element to ask Claude about it; on iPad, write on it with Apple Pencil: each note is
/// tagged to what it's drawn on, and goes to Claude with a picture of the ink (Send, or squeeze a Pencil Pro).
struct DiagramScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.density) private var density
    let diagramId: String
    var inSheet = false
    @State private var version: Int?
    @State private var page = DiagramPage()
    @State private var drafts: [DraftNote] = []
    @State private var selected: InkAnchor?
    @State private var problem: String?
    @State private var search = ""
    @State private var sent = 0
    #if os(iOS)
    @State private var ink = InkController()
    #endif

    private var pencil: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    private var panelShown: Bool { problem != nil || selected != nil || drafts.contains { !$0.sent } }

    var body: some View {
        let versions = model.store.diagramVersions[diagramId] ?? []
        if let d = versions.last(where: { $0.version == version }) ?? versions.last {
            surface(d)
                // On iPad the Pencil palette floats over the bottom of the screen, so the notes go top right: on the
                // page, under its links, which stay tappable.
                .overlay(alignment: .topTrailing) { if pencil, panelShown { InkPanel { bottomBar(d) } } }
                .ignoresSafeArea(edges: .bottom)
                // The code it explains, and the notes it answers: one tap away.
                .safeAreaInset(edge: .top, spacing: 0) { links(d) }
                .safeAreaInset(edge: .bottom, spacing: 0) { if !pencil { bottomBar(d) } }
                .navigationTitle(d.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    if inSheet { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                }
                // Searching handwriting is an iPad thing.
                .paneActions(search: pencil ? $search : nil, prompt: "Search your handwriting") { actions(d, versions) }
                .onAppear {
                    page.onTap = { selected = $0 }
                    page.onError = { problem = $0 }
                    if pencil { model.pencilSurfaces += 1 }
                }
                .onDisappear { if pencil { model.pencilSurfaces -= 1 } }
                // What's picked goes with a message as the composer's chip; writing on it keeps its tab.
                .onChange(of: selected?.id) { model.picked(selected, in: .diagram(diagramId)) }
                .onChange(of: drafts.isEmpty) { _, empty in if !empty { model.keepOpen(.diagram(diagramId)) } }
                // Opened from the code an element stands for: that element, picked.
                .onChange(of: model.diagramFocus, initial: true) { _, focus in
                    guard let focus, focus.diagram == diagramId else { return }
                    model.diagramFocus = nil
                    page.focus(element: focus.element)
                }
                #if os(iOS)
                // Sent here to write on (Write on iPad): the Pencil tools come out.
                .writesWhenSent(.diagram(diagramId)) { if pencil { ink.showTools() } }
                #endif
                .sensoryFeedback(.success, trigger: sent)
                .sensoryFeedback(.selection, trigger: selected?.id)
        } else {
            ContentUnavailableView("No such diagram", systemImage: "point.3.filled.connected.trianglepath.dotted")
        }
    }

    @ViewBuilder private func surface(_ d: DiagramEvent) -> some View {
        #if os(iOS)
        if pencil {
            InkSurfaceRepresentable(page: page, document: DiagramDocument(d), key: "diagram-\(d.id)", isDiff: false, controller: ink,
                                    drafts: $drafts, search: search, onSelect: { selected = $0 }, onSqueeze: { Task { await send(d) } })
        } else {
            DiagramWebView(page: page, document: DiagramDocument(d))
        }
        #else
        DiagramWebView(page: page, document: DiagramDocument(d))
        #endif
    }

    @ViewBuilder private func bottomBar(_ d: DiagramEvent) -> some View {
        VStack(spacing: 0) {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.stateFailed).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            if let selected {
                let ref = d.links?[selected.id].flatMap(CodeRef.init(link:))
                PickBar(title: selected.label, symbol: "scope",
                        showCode: ref.map { ref in { model.openFile(ref.path, line: ref.start, compact: density == .compact) } },
                        askHere: { q in
                            model.askHere(q, on: .diagram(diagramId: d.id, version: d.version, title: d.title), elements: [InkElement(id: selected.id, label: selected.label)])
                        },
                        askClaude: {
                            model.askAbout("About “\(selected.label)” (\(selected.id)) in the diagram “\(d.title)”: ", compact: density == .compact)
                            if inSheet { dismiss() }
                        })
            }
            if pencil, drafts.contains(where: { !$0.sent }) {
                NotesTray(drafts: $drafts) { Task { await send(d) } }
            }
        }
        .background(pencil ? AnyShapeStyle(.clear) : AnyShapeStyle(.bar))
    }

    /// Chips under the title: each piece of code it explains, and the notes it answers or that were written on it.
    @ViewBuilder private func links(_ d: DiagramEvent) -> some View {
        let answers = model.store.annotations(answeredBy: d.id)
        let onIt = model.store.annotations(onDiagram: d.id)
        let code = d.explains ?? []
        if !code.isEmpty || !answers.isEmpty || !onIt.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(code.enumerated()), id: \.offset) { _, ref in
                        Button { model.openFile(ref.path, line: ref.start, compact: density == .compact) } label: {
                            Label("\(Paths.name(ref.path))\(ref.start.map { ":\($0)" } ?? "")\(ref.end.flatMap { e in ref.start.map { e > $0 ? "–\(e)" : "" } } ?? "")",
                                  systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                    ForEach(answers) { a in
                        Button { model.showNote(a.id, compact: density == .compact) } label: {
                            Label(a.text.map { "Answers “\($0)”" } ?? "Answers your note on \(a.lines?.first.map { "\(Paths.name($0.file)):\($0.start)" } ?? a.place)", systemImage: "text.bubble")
                        }
                    }
                    if !onIt.isEmpty {
                        Button { model.showNotes(.diagram(d.id), compact: density == .compact) } label: {
                            Label("\(onIt.count) note\(onIt.count == 1 ? "" : "s") on it", systemImage: "pencil.and.scribble")
                        }
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .background(.bar)
        }
    }

    @ViewBuilder private func actions(_ d: DiagramEvent, _ versions: [DiagramEvent]) -> some View {
        if versions.count > 1 {
            Menu {
                ForEach(versions.reversed(), id: \.version) { v in
                    Button("Version \(v.version)", systemImage: v.version == d.version ? "checkmark" : "") { version = v.version }
                }
            } label: { Label("v\(d.version)", systemImage: "clock.arrow.circlepath") }
        }
        #if os(iOS)
        if pencil {
            Button("Pencil Tools", systemImage: "pencil.tip.crop.circle") { ink.toggleTools() }
        }
        #endif
        Button("Side Chat", systemImage: "bubble.left.and.bubble.right") {
            model.openSideChat(about: .text(label: "the diagram “\(d.title)”", text: d.source))
        }
        .help("Ask a quick question about this diagram, beside the conversation (⌘⇧K)")
        Menu {
            Button("Ask Claude About It", systemImage: "bubble.left") {
                model.askAbout("About the diagram “\(d.title)” (\(d.id)): ", compact: density == .compact)
                if inSheet { dismiss() }
            }
            if density != .compact, !inSheet {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { model.openWindow(.diagram(d.id)) }
            }
            // To write on with Apple Pencil.
            WriteOnIPad(place: .diagram(d.id))
            Button("Copy Source", systemImage: "doc.on.doc") { Pasteboard.copy(d.source) }
            Button("Copy Image", systemImage: "photo") { Task { if let i = await page.snapshot() { Pasteboard.copy(i) } } }
        } label: { Label("More", systemImage: "ellipsis.circle") }
    }

    private func send(_ d: DiagramEvent) async {
        #if os(iOS)
        await ink.finishNote()
        guard drafts.contains(where: { !$0.sent }) else { ink.toggleTools(); return }
        let pending = drafts.filter { !$0.sent }
        let image = await ink.snapshot()?.jpegData(compressionQuality: 0.7)?.base64EncodedString()
        model.send(.notes(surface: .diagram(diagramId: d.id, version: d.version, title: d.title), items: await ink.items(pending), image: image, imageType: image == nil ? nil : "image/jpeg"))
        for i in drafts.indices where !drafts[i].sent { drafts[i].sent = true }
        sent += 1
        #endif
    }
}

/// The iPad's notes and picked element, floating top right, clear of the Pencil palette at the bottom. Hidden when empty.
/// On iPad the Pencil palette floats over the bottom of the screen, so the notes float top right, over the page: kept
/// small (the notes tray is one line until opened), since what's under it can't be seen. Pushing the page down
/// instead made it jump each time a note formed.
struct InkPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: 460)
            .background { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial).shadow(color: .black.opacity(0.12), radius: 10, y: 3) }
            .padding(12)
    }
}

/// The notes you've written and not sent, each as a chip (hold one to change what it means, or delete it), and the one
/// way to send them. Questions become threads on what they're written on, answered there (a local model first); notes
/// that ask for changes go to Claude in the conversation, to act on.
struct NotesTray: View {
    @Binding var drafts: [DraftNote]
    let onSend: () -> Void
    /// The notes one by one (to change what one means, or delete it): folded away until asked for, so the tray stays a
    /// single line over the page.
    @State private var showsNotes = false

    var body: some View {
        let pending = drafts.filter { !$0.sent }
        let questions = pending.allSatisfy { $0.note.intent == .question }
        VStack(alignment: .leading, spacing: 8) {
            if showsNotes {
                notes(pending)
            }
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy) { showsNotes.toggle() }
                } label: {
                    Label(pending.count == 1 ? "1 note" : "\(pending.count) notes", systemImage: showsNotes ? "chevron.up" : "chevron.down")
                        .labelStyle(TrailingIconLabelStyle())
                        .font(.callout.bold())
                }
                .buttonStyle(.borderless)
                .accessibilityHint(showsNotes ? "Folds the notes away" : "Shows each note, to change what it means or delete it")
                Text(questions ? "· answered here" : "· or squeeze the Pencil").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button(questions ? "Ask" : "Send to Claude", systemImage: questions ? "questionmark.bubble" : "paperplane.fill", action: onSend)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(questions ? "Each question becomes a thread on what it's written on, answered there"
                                                 : "Claude gets these in the conversation, to act on")
            }
        }
        .padding(10)
    }

    @ViewBuilder private func notes(_ pending: [DraftNote]) -> some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pending) { d in
                        NoteChip(note: d.note)
                            .contextMenu {
                                ForEach(InkIntent.allCases, id: \.self) { intent in
                                    let shown = NoteDisplay(d.note.with(intent: intent))
                                    Button(shown.verb, systemImage: shown.symbol) { set(d.id) { $0.note.intent = intent; $0.chosen = true } }
                                }
                                Divider()
                                Button("Delete Note", systemImage: "trash", role: .destructive) { drafts.removeAll { $0.id == d.id } }
                            }
                    }
                }
            }
    }

    private func set(_ id: String, _ change: (inout DraftNote) -> Void) {
        guard let i = drafts.firstIndex(where: { $0.id == id }) else { return }
        change(&drafts[i])
    }
}

/// A label with its icon after the title ("3 notes ⌄").
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon.font(.caption.bold()) }
    }
}

/// What's picked on a page (a line of a file or a diff, an element of a diagram), and what to do about it: Ask Here
/// types a question that becomes a thread on it, answered beside it like a handwritten one; Ask Claude asks in the
/// conversation, with it named.
struct PickBar: View {
    let title: String
    let symbol: String
    var monospaced = false
    /// A diagram element that stands for code: its code.
    var showCode: (() -> Void)? = nil
    let askHere: (String) -> Void
    let askClaude: () -> Void
    @State private var asking = false
    @State private var question = ""
    @FocusState private var focused: Bool

    private var trimmed: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol).font(monospaced ? .callout.monospaced() : .callout).lineLimit(1)
                Spacer()
                if let showCode {
                    Button("Show Code", systemImage: "chevron.left.forwardslash.chevron.right", action: showCode).buttonStyle(.bordered)
                }
                Button("Ask Here", systemImage: "questionmark.bubble") { asking.toggle() }
                    .buttonStyle(.bordered)
                    .help("A question about \(title), answered beside it and kept as its thread")
                    .accessibilityIdentifier("ask-here")
                Button("Ask Claude", systemImage: "bubble.left", action: askClaude)
                    .buttonStyle(.borderedProminent)
                    .help("Ask in the conversation, with \(title) named")
            }
            if asking {
                HStack(spacing: 8) {
                    TextField("A question about \(title)", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                        .sendsOnReturn($question, send: submit)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.secondary) }
                    Button("Ask", systemImage: "arrow.up.circle.fill", action: submit)
                        .labelStyle(.iconOnly).font(.title2)
                        .buttonStyle(.borderless)
                        .disabled(trimmed.isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .onAppear { focused = true }
            }
        }
        .padding(10)
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        askHere(trimmed)
        question = ""
        asking = false
    }
}

/// A note waiting to be sent, in the tray on the page it was written on.
struct NoteChip: View {
    let note: InkNote
    var body: some View {
        let d = NoteDisplay(note)
        Label(d.pageChip, systemImage: d.symbol)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background { Capsule().fill(d.tint.opacity(0.14)) }
            .overlay { Capsule().strokeBorder(d.tint.opacity(0.5)) }
    }
}

/// Handwritten notes in Claude's thread: what each one means and what it's on. Tap to see the diagram.
struct NotesBubble: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let by: String
    let notes: Notes

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: "pencil.and.scribble").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(notes.items) { n in
                    let d = NoteDisplay(n)
                    Label {
                        Text(d.chip).font(.callout)
                    } icon: {
                        Image(systemName: d.symbol).foregroundStyle(d.tint)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor.opacity(0.14)) }
            .onTapGesture {
                switch notes.surface {
                case .diagram(let id, _, _): model.openDiagram(id, compact: density == .compact)
                case .diff(let task, let worker?): model.openDiff(taskId: task, worker: worker)
                case .diff: break
                case .file(let path): model.openFile(path, compact: density == .compact)
                case .plan(let id): if density == .compact { model.showCompact(.plan(id)) } else { model.show(.plan(id)) }
                }
            }
            HStack(spacing: 6) {
                // Kept with Claude's answer: where it stands.
                if let a = notes.items.lazy.compactMap({ model.store.annotations[$0.id] }).first {
                    NoteStatus(annotation: a)
                }
                Text(by == model.device ? "You, with Apple Pencil" : by)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, density == .compact ? 32 : 80)
    }

    private var title: String {
        switch notes.surface {
        case .diagram(_, _, let t): "Notes on “\(t ?? "a diagram")”"
        case .diff(let task, let worker): "Notes on \(worker.map { model.workerName($0) } ?? "a worker")'s diff · \(task)"
        case .file(let path): "Notes on \(Paths.short(path))"
        case .plan: "Notes on the plan"
        }
    }
}

/// A task's diff: every changed line, with room to write in the margin on iPad. Notes on a running task steer
/// that worker; on a finished one they go to Claude.
struct DiffScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.density) private var density
    let taskId: String
    let worker: String
    /// Full screen with Done (iPhone); else a tab of the side stage, or a window of its own.
    var inSheet = true
    @State private var page = DiagramPage()
    @State private var diff: String?
    @State private var truncated = false
    @State private var problem: String?
    @State private var drafts: [DraftNote] = []
    @State private var selected: InkAnchor?
    @State private var sent = 0
    #if os(iOS)
    @State private var ink = InkController()
    #endif

    private var pencil: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    private var panelShown: Bool { truncated || problem != nil || selected != nil || drafts.contains { !$0.sent } }

    var body: some View {
        if inSheet {
            NavigationStack { content }
        } else {
            content
        }
    }

    private var place: Destination { .diff(taskId, worker: worker) }

    private var content: some View {
        Group {
            if let diff {
                surface(diff)
            } else if let problem {
                ContentUnavailableView("No diff", systemImage: "doc.text.magnifyingglass", description: Text(problem))
            } else {
                ProgressView("Getting the diff from the hub…")
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) { if !pencil { bottomBar } }
        .overlay(alignment: .topTrailing) { if pencil, panelShown { InkPanel { bottomBar } } }
        .navigationTitle("\(model.workerName(worker)) · \(taskId)")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if inSheet { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .paneActions {
            Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
            #if os(iOS)
            if pencil { Button("Pencil Tools", systemImage: "pencil.tip.crop.circle") { ink.toggleTools() } }
            #endif
        }
        .sensoryFeedback(.success, trigger: sent)
        .task(id: model.store.isConnected) { if model.store.isConnected || model.isDemo { await load() } }
        .onAppear { page.onTap = { selected = $0 } }
        // What's picked goes with a message as the composer's chip; writing on it keeps its tab.
        .onChange(of: selected?.id) { model.picked(selected, in: place) }
        .onChange(of: drafts.isEmpty) { _, empty in if !empty { model.keepOpen(place) } }
    }

    @ViewBuilder private func surface(_ diff: String) -> some View {
        #if os(iOS)
        if pencil {
            InkSurfaceRepresentable(page: page, document: .diff(diff), key: "diff-\(taskId)", isDiff: true, controller: ink,
                                    drafts: $drafts, search: "", onSelect: { selected = $0 }, onSqueeze: { Task { await send() } })
        } else {
            DiagramWebView(page: page, document: .diff(diff))
        }
        #else
        DiagramWebView(page: page, document: .diff(diff))
        #endif
    }

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 0) {
            if truncated {
                Label("This diff is long; only its first part is shown.", systemImage: "scissors").font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if let selected, let file = selected.file, let line = selected.line {
                PickBar(title: "\(file):\(line)", symbol: "text.line.first.and.arrowtriangle.forward", monospaced: true,
                        askHere: { q in
                            model.askHere(q, on: .diff(taskId: taskId, worker: worker), lines: [InkLines(file: file, start: line, end: line, code: selected.label)])
                        },
                        askClaude: {
                            model.askAbout("About \(file) line \(line) in \(model.workerName(worker))'s task \(taskId) (`\(selected.label)`): ", compact: density == .compact)
                            if inSheet { dismiss() }
                        })
            }
            if pencil, drafts.contains(where: { !$0.sent }) {
                NotesTray(drafts: $drafts) { Task { await send() } }
            }
        }
        .background(pencil ? AnyShapeStyle(.clear) : AnyShapeStyle(.bar))
    }

    private func load() async {
        do {
            let (text, cut) = try await model.fetchDiff(taskId)
            diff = text
            truncated = cut
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func send() async {
        #if os(iOS)
        await ink.finishNote()
        let pending = drafts.filter { !$0.sent }
        guard !pending.isEmpty else { ink.toggleTools(); return }
        let image = await ink.snapshot()?.jpegData(compressionQuality: 0.7)?.base64EncodedString()
        model.send(.notes(surface: .diff(taskId: taskId, worker: worker), items: await ink.items(pending), image: image, imageType: image == nil ? nil : "image/jpeg"))
        for i in drafts.indices where !drafts[i].sent { drafts[i].sent = true }
        sent += 1
        #endif
    }
}

/// Copy text or an image, on either platform.
enum Pasteboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    static func copy(_ image: PlatformImage) {
        #if os(iOS)
        UIPasteboard.general.image = image
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        #endif
    }
}

extension View {
    /// A task's diff: full screen on iPhone and iPad (room to write), a sheet on Mac.
    func diffPresentation() -> some View { modifier(DiffPresentation()) }
}

private struct DiffPresentation: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        #if os(iOS)
        content.fullScreenCover(item: $model.diffSheet) { ref in DiffScreen(taskId: ref.taskId, worker: ref.worker) }
        #else
        content.sheet(item: $model.diffSheet) { ref in DiffScreen(taskId: ref.taskId, worker: ref.worker).frame(minWidth: 760, minHeight: 560) }
        #endif
    }
}

enum UIDiffHint {
    #if os(iOS)
    static var text: String { UIDevice.current.userInterfaceIdiom == .pad ? "Shows every changed line; write on it with Apple Pencil" : "Shows every changed line" }
    #else
    static let text = "Shows every changed line"
    #endif
}
