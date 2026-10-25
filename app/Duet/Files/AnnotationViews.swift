import DuetKit
import MarkdownUI
import SwiftUI

/// Which kept notes a list shows.
enum NotesFilter: Hashable, Codable {
    case all
    case file(String)
    case diagram(String)
}

/// Every kept note, newest first, grouped by what it was written on: a question on a file with Claude's answer,
/// the diagram Claude drew for it, a note on a diagram. The way back into anything you've worked through.
struct AnnotationsList: View {
    @Environment(AppModel.self) private var model
    let filter: NotesFilter
    @State private var show: Show = .all

    enum Show: String, CaseIterable { case all = "All", waiting = "Waiting", answered = "Answered", resolved = "Resolved" }

    var body: some View {
        let notes = model.store.annotationList.filter(matches).filter(shown)
        let groups = Dictionary(grouping: notes, by: \.place)
        List {
            Picker("Show", selection: $show) { ForEach(Show.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
            if notes.isEmpty {
                ContentUnavailableView(show == .all ? "No notes yet" : "None \(show.rawValue.lowercased())", systemImage: "pencil.and.scribble",
                                       description: Text("Write on a file or a diagram with Apple Pencil on iPad, and send it to Claude. Each note is kept here with Claude's answer."))
            }
            ForEach(groups.keys.sorted { (groups[$0]?.first?.ts ?? 0) > (groups[$1]?.first?.ts ?? 0) }, id: \.self) { place in
                Section(place) {
                    ForEach(groups[place] ?? []) { a in
                        NavigationLink(value: FilesRoute.note(a.id)) { AnnotationRow(annotation: a) }
                    }
                }
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        switch filter {
        case .all: "Notes"
        case .file(let p): "Notes on \(Paths.name(p))"
        case .diagram(let id): "Notes on \(model.store.diagrams[id]?.title ?? "the diagram")"
        }
    }

    private func matches(_ a: Annotation) -> Bool {
        switch (filter, a.surface) {
        case (.all, _): true
        case (.file(let p), .file(let q)): p == q
        case (.diagram(let d), .diagram(let e, _, _)): d == e
        default: false
        }
    }

    private func shown(_ a: Annotation) -> Bool {
        switch show {
        case .all: true
        case .waiting: a.status == "open"
        case .answered: a.answered
        case .resolved: a.resolved
        }
    }
}

extension Annotation {
    /// What it was written on, for grouping: `~/proj/calc.py`, “How Duet fits together”, a task's diff.
    var place: String {
        switch surface {
        case .file(let p): Paths.short(p)
        case .diagram(_, _, let t): "“\(t ?? "A diagram")”"
        case .diff(let task, _): "Diff · \(task)"
        case .plan: "The plan"
        }
    }
}

struct AnnotationRow: View {
    let annotation: Annotation

    var body: some View {
        let d = NoteDisplay(annotation.note)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: d.symbol).foregroundStyle(d.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(annotation.text.map { "“\($0)”" } ?? d.chip).lineLimit(2)
                HStack(spacing: 6) {
                    NoteStatus(annotation: annotation)
                    if !d.targets.isEmpty { Text(d.targets).lineLimit(1) }
                    Text(annotation.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Waiting, Claude on it, answered (with a diagram), or resolved.
struct NoteStatus: View {
    @Environment(AppModel.self) private var model
    let annotation: Annotation

    var body: some View {
        let (text, symbol, tint): (String, String, Color) = switch annotation.status {
        case "answered": (annotation.diagrams?.isEmpty == false ? "Answered · diagram" : "Answered", "checkmark.bubble.fill", .stateDone)
        case "resolved": ("Resolved", "checkmark.circle", .secondary)
        default: (annotation.turn != nil && model.store.leadStatus.busy ? "Claude is on it" : "Waiting", "ellipsis.bubble", .stateWorking)
        }
        Label(text, systemImage: symbol).foregroundStyle(tint).labelStyle(.titleAndIcon)
    }
}

/// One kept note, as a thread: what you asked (and your handwriting), what it's on, the answer (a local model's, or
/// Claude's) and the diagrams Claude drew for it. On iPad and Mac it's a conversation of its own, in the centre, with
/// what it's written on beside it. It stays here; Post to the Chat brings it into the conversation.
struct AnnotationDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    /// A window's own stack, when it's pushed in one.
    @Environment(FilesStack.self) private var filesStack: FilesStack?
    let id: String
    /// Another note on the same file, stepped to with the arrows or picked from its history: shown in this tab.
    @State private var stepped: String?
    @State private var showsHistory = false
    @State private var ink: PlatformImage?
    @State private var confirmDelete = false
    @State private var reply = ""
    @State private var sending = false
    @State private var replyProblem: String?

    private var compact: Bool { density == .compact }
    /// The note shown: the tab's, or one stepped to.
    private var current: String { stepped ?? id }

    var body: some View {
        if let a = model.store.annotations[current] {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if case .file(let path) = a.surface { onFile(a, path: path) }
                    header(a)
                    if let ink { inkView(ink) }
                    target(a)
                    answer(a)
                    diagrams(a)
                    replies(a)
                }
                .padding(compact ? 16 : 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { threadBar(a) }
            .navigationTitle(model.title(of: .note(current)))
            // Opened, its answer has been seen: it leaves Needs you.
            .onAppear { model.sawAnswers([current]) }
            .onChange(of: a.answered) { _, answered in if answered { model.sawAnswers([current]) } }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup {
                    Button(a.resolved ? "Reopen" : "Resolve", systemImage: a.resolved ? "arrow.uturn.backward.circle" : "checkmark.circle") {
                        model.send(.annotationUpdate(id: current, status: a.resolved ? "open" : "resolved"))
                    }
                    Menu {
                        Button("Post to the Chat", systemImage: "arrow.up.message") { postToChat(a) }
                        Button("Delete Note", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                }
            }
            .confirmationDialog("Delete this note?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Note", role: .destructive) {
                    let conversation = model.conversationPlace(of: .note(current)) ?? .lead
                    model.send(.annotationUpdate(id: current, delete: true))
                    // Out of the way: popped off the stack it was pushed on (a window's, the iPhone's), or, in the centre,
                    // its conversation takes the centre again.
                    if let stack = filesStack {
                        if stack.path.last == .note(current) { stack.path.removeLast() }
                    } else if compact {
                        if model.filesPath.last == .note(current) { model.filesPath.removeLast() }
                    } else if model.workspace.centre == .note(current) {
                        model.show(conversation)
                    }
                }
            } message: {
                Text("Its handwriting and Claude's answer go with it. The conversation keeps what was said.")
            }
            .task(id: "\(current)|\(a.ink == true)") { ink = nil; if a.ink == true { ink = await model.annotationInk(current) } }
        } else {
            ContentUnavailableView("This note was deleted", systemImage: "trash")
        }
    }

    /// A note on a file: arrows through the other notes on that file, by line, and where this one is among them; and the
    /// file's history, every note on it, newest first.
    @ViewBuilder private func onFile(_ a: Annotation, path: String) -> some View {
        let all = model.store.annotations(onFile: path)
        let byLine = all.sorted { ($0.lines?.first?.start ?? 0, $0.ts) < ($1.lines?.first?.start ?? 0, $1.ts) }
        let i = byLine.firstIndex { $0.id == a.id } ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Button { step(to: byLine[i - 1].id) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 32) }
                    .disabled(i == 0)
                    .accessibilityLabel("Previous question")
                Button { step(to: byLine[i + 1].id) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 32) }
                    .disabled(i + 1 >= byLine.count)
                    .accessibilityLabel("Next question")
                Text("\(i + 1) of \(byLine.count) · \(Paths.name(path))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(showsHistory ? "Hide History" : "History", systemImage: "clock.arrow.circlepath") { showsHistory.toggle() }
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            if showsHistory {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(all.sorted { $0.ts > $1.ts }, id: \.id) { n in
                        let c = NoteCard.of(n)
                        Button { step(to: n.id) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    if let l = n.lines?.first?.start { Text("Line \(l)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                    Text(c.question).font(.subheadline.weight(n.id == a.id ? .semibold : .regular)).lineLimit(2)
                                }
                                Text(c.answer ?? (c.resolved ? "Resolved" : c.waiting)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }

    /// Another note, in this tab.
    private func step(to other: String) {
        stepped = other == id ? nil : other
        showsHistory = false
    }

    @ViewBuilder private func header(_ a: Annotation) -> some View {
        let d = NoteDisplay(a.note)
        VStack(alignment: .leading, spacing: 8) {
            Label(model.title(of: .note(a.id)), systemImage: d.symbol).font(.subheadline.bold()).foregroundStyle(d.tint)
            if let t = a.text, !t.isEmpty { Text("“\(t)”").font(.title3) }
            HStack(spacing: 8) {
                NoteStatus(annotation: a)
                Text("\(a.by == model.device ? "You" : a.by) · \(a.date.formatted(.relative(presentation: .named)))")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func inkView(_ image: PlatformImage) -> some View {
        #if os(iOS)
        let img = Image(uiImage: image)
        #else
        let img = Image(nsImage: image)
        #endif
        return img.resizable().scaledToFit()
            .frame(maxWidth: 360, maxHeight: 160, alignment: .leading)
            .padding(10)
            .background { RoundedRectangle(cornerRadius: 12).fill(Color.white) }
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator) }
            .accessibilityLabel("Your handwriting")
    }

    /// The code (or diagram elements) it was written on, with the way there.
    @ViewBuilder private func target(_ a: Annotation) -> some View {
        switch a.surface {
        case .file(let path):
            ForEach(Array((a.lines ?? []).enumerated()), id: \.offset) { _, l in
                CodeSnippet(path: path, lines: l) { model.openFile(path, line: l.start, compact: compact) }
            }
            if a.lines?.isEmpty ?? true {
                Button("Open \(Paths.name(path))", systemImage: "doc.text") { model.openFile(path, compact: compact) }
            }
        case .diff(let task, _):
            ForEach(Array((a.lines ?? []).enumerated()), id: \.offset) { _, l in
                let path = model.store.tasks[task]?.cwd.map { Paths.join($0, l.file) } ?? l.file
                CodeSnippet(path: path, lines: l) { model.openFile(path, line: l.start, compact: compact) }
            }
        case .diagram(let diagramId, _, let title):
            HStack {
                Label(title ?? "Diagram", systemImage: "point.3.filled.connected.trianglepath.dotted")
                Spacer()
                Button("Open") { model.openDiagram(diagramId, compact: compact) }.buttonStyle(.bordered)
            }
            .font(.callout)
        case .plan(let conversationId):
            // The steps it was written on.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(a.elements ?? [], id: \.id) { step in
                    Label(step.label ?? step.id, systemImage: "checklist").lineLimit(2)
                }
                Button("Open the Plan", systemImage: "checklist") {
                    if compact { model.showCompact(.plan(conversationId)) } else { model.show(.plan(conversationId)) }
                }
                .buttonStyle(.bordered)
            }
            .font(.callout)
        }
    }

    @ViewBuilder private func answer(_ a: Annotation) -> some View {
        if let text = a.answer, !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label(a.answeredLocally ? "Answer" : "Claude's answer", systemImage: a.answeredLocally ? "cpu" : "sparkles")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if a.answered { AnswerChip(annotation: a) }
                }
                Markdown(Self.withoutNarration(text)).markdownSoftBreakMode(.lineBreak).textSelection(.enabled)
                // A local answer stays short; its further points wait under "More".
                if let more = a.more, !more.isEmpty {
                    DisclosureGroup("More") {
                        Markdown(more).markdownSoftBreakMode(.lineBreak).textSelection(.enabled).padding(.top, 4)
                    }
                    .font(.callout)
                }
                // A local model answered: Claude can check it, while it's the thread's latest answer (after a reply, the
                // reply's answer has the button).
                if a.answeredLocally, !hasReplies(a) {
                    Button("Ask Claude", systemImage: "sparkles") { model.send(.annotationUpdate(id: a.id, reroute: "claude")) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Claude checks this answer, with what the local model found")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary) }
        } else if a.status == "open" {
            if let chat = a.chatId.flatMap({ model.store.sideChats[$0] }), chat.isAnswering {
                // Claude answering in the note's thread: its answer as it comes.
                VStack(alignment: .leading, spacing: 8) {
                    Label("Claude's answer", systemImage: "sparkles").font(.caption.bold()).foregroundStyle(.secondary)
                    if chat.streaming.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(SideChatView.activity(chat.activity)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    } else {
                        Text(chat.streaming).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary) }
            } else if a.answering == nil, let why = a.escalated, !why.isEmpty {
                // Claude couldn't answer: why, and another try.
                VStack(alignment: .leading, spacing: 8) {
                    Label(why, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.stateFailed)
                    Button("Ask Claude Again", systemImage: "sparkles") { model.send(.annotationUpdate(id: a.id, reroute: "claude")) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                Label(a.answering == "Claude" ? (a.escalated.map { "Claude has it (\($0)); the answer appears here." } ?? "Claude has it; the answer appears here.")
                      : a.answering != nil ? "A local model is reading the code; its answer appears here once its citations check out."
                      : a.turn != nil ? "Claude has it; the answer appears here." : "Waiting for Claude.", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        // Claude was asked about a local model's answer: that answer is still here.
        if let local = a.localAnswer, !local.isEmpty {
            DisclosureGroup("The local model's answer") {
                Markdown(local).markdownSoftBreakMode(.lineBreak).textSelection(.enabled).padding(.top, 6)
            }
            .font(.callout)
        }
    }

    @ViewBuilder private func diagrams(_ a: Annotation) -> some View {
        let shown = (a.diagrams ?? []).compactMap { model.store.diagrams[$0] }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Diagram\(shown.count == 1 ? "" : "s") Claude drew for it", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(shown) { DiagramCard(diagram: $0) }
            }
        }
    }

    /// The answer without "Let me read…" before it: what Claude said while it worked, kept by older hubs.
    static func withoutNarration(_ text: String) -> String {
        var paragraphs = text.components(separatedBy: "\n\n")
        while paragraphs.count > 1, paragraphs[0].range(of: #"^(Let me|Let's|I'll|I will|Now I'll|First, I'll)\b"#, options: .regularExpression) != nil {
            paragraphs.removeFirst()
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// The thread's replies, after the note and its answer above: the side chat that continues the note, less its first
    /// two messages (the note and its answer, shown above).
    @ViewBuilder private func replies(_ a: Annotation) -> some View {
        if let chatId = a.chatId, let chat = model.store.sideChats[chatId] {
            let shown = chat.messages.filter { $0.fromNote != true }
            let latest = chat.messages.last { !$0.isUser }?.id
            // While the note itself is being answered (Claude, in the thread), that answer shows above, as the note's.
            let replying = a.status != "open"
            if !shown.isEmpty || (replying && (chat.isAnswering || chat.error != nil)) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(shown) { SideMessageRow(message: $0, latest: $0.id == latest) }
                    if replying {
                        if !chat.streaming.isEmpty {
                            Text(chat.streaming).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if chat.isAnswering {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(SideChatView.activity(chat.activity)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        if let e = chat.error { Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.stateFailed) }
                    }
                }
                .accessibilityIdentifier("note-replies")
            }
        }
    }

    /// Under the thread: a reply (once the note is answered), and Post to the Chat to bring it into the conversation.
    private func threadBar(_ a: Annotation) -> some View {
        let chat = a.chatId.flatMap { model.store.sideChats[$0] }
        let answering = chat?.isAnswering == true
        let waiting = a.status == "open"
        let empty = reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("This thread stays beside the conversation.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Post to the Chat", systemImage: "arrow.up.message") { postToChat(a) }
                    .buttonStyle(.borderless).font(.caption)
                    .help("Start a message in the conversation with this question and its answer, for you to add to")
                    .accessibilityIdentifier("post-to-chat")
            }
            if let replyProblem { Label(replyProblem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.stateFailed) }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(waiting ? "Reply once it's answered" : "Reply…", text: $reply, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .disabled(waiting)
                    .sendsOnReturn($reply) { send(a) }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.secondary.opacity(0.1)) }
                    .accessibilityIdentifier("note-reply-field")
                if answering, let chatId = a.chatId {
                    Button("Stop", systemImage: "stop.circle.fill") { model.send(.sideStop(chatId: chatId)) }
                        .foregroundStyle(.stateFailed)
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Reply", systemImage: "arrow.up.circle.fill") { send(a) }
                        .disabled(waiting || empty || sending)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier("note-reply")
                }
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, compact ? 12 : 16).padding(.vertical, 10)
        .background(.bar)
    }

    private func hasReplies(_ a: Annotation) -> Bool {
        guard let chatId = a.chatId, let chat = model.store.sideChats[chatId] else { return false }
        return chat.messages.contains { $0.fromNote != true }
    }

    /// A reply in this thread, answered here like the note was.
    private func send(_ a: Annotation) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, a.status != "open" else { return }
        sending = true
        replyProblem = nil
        Task {
            do {
                try await model.replyToNote(a.id, text: text)
                reply = ""
            } catch {
                replyProblem = error.localizedDescription
            }
            sending = false
        }
    }

    /// The question and the start of its answer, in the composer of the live conversation, for you to add to.
    private func postToChat(_ a: Annotation) {
        let asked = a.text.map { "“\($0)”" } ?? "my handwritten note"
        let answer = a.answer.map { " Its answer: \(FileViewer.gist($0))" } ?? ""
        model.askAbout("From my thread on \(model.noteAnchorName(a)) (\(asked)).\(answer)\n\n", compact: compact)
    }
}

/// Who answered, at a glance: a local model with its citations checked against the code, or Claude and why the
/// question went to it.
struct AnswerChip: View {
    let text: String
    let local: Bool

    init(annotation a: Annotation) {
        text = Self.text(for: a)
        local = a.answeredLocally
    }

    init(message m: SideMessageEvent) {
        text = Self.text(who: m.model ?? "Claude", local: m.local == true, checked: m.checked, ms: m.ms, escalated: m.escalated)
        local = m.local == true
    }

    var body: some View {
        Label(text, systemImage: local ? "cpu" : "sparkles")
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background { Capsule().fill(.secondary.opacity(0.12)) }
            .help(text)
    }

    static func text(for a: Annotation) -> String {
        text(who: a.answeredBy ?? "Claude", local: a.answeredLocally, checked: a.checked, ms: a.ms, escalated: a.escalated)
    }

    /// "qwen-27b · 2 citations checked · 14 s", or "Sonnet · it couldn't settle: who calls it".
    static func text(who: String, local: Bool, checked: Citations?, ms: Double?, escalated: String?) -> String {
        var parts = [["haiku": "Haiku", "sonnet": "Sonnet", "opus": "Opus", "claude": "Claude"][who.lowercased()] ?? who]
        if local, let c = checked { parts.append(c.claims == 1 ? "1 citation checked" : "\(c.claims) citations checked") }
        if let ms { parts.append(ms < 60_000 ? "\(Int((ms / 1000).rounded())) s" : "\(Int((ms / 60_000).rounded())) min") }
        if !local, let escalated, !escalated.isEmpty { parts.append(escalated) }
        return parts.joined(separator: " · ")
    }
}

/// Lines of a file, shown small, with a button to open them.
struct CodeSnippet: View {
    let path: String
    let lines: InkLines
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("\(Paths.name(path)):\(lines.start)\(lines.end > lines.start ? "–\(lines.end)" : "")", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.callout.monospaced()).lineLimit(1)
                Spacer()
                Button("Open", action: open).buttonStyle(.bordered).controlSize(.small)
            }
            if let code = lines.code, !code.isEmpty {
                Text(code.split(separator: "\n").prefix(8).joined(separator: "\n"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(8)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background { RoundedRectangle(cornerRadius: 8).fill(.background.secondary) }
            }
        }
    }
}

extension View {
    /// Folders, files and notes open by pushing onto the surrounding navigation stack.
    func filesDestinations() -> some View {
        navigationDestination(for: FilesRoute.self) { route in
            switch route {
            case .folder(let p): FileBrowser(path: p)
            case .file(let p, let line): FileViewer(path: p, line: line)
            case .note(let id): AnnotationDetail(id: id)
            case .notes(let filter): AnnotationsList(filter: filter)
            }
        }
    }
}
