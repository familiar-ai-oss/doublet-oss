import DuetKit
import SwiftUI

/// The file viewer: folders and files on the hub machine, starting at a folder (nil: Claude's). Folders, files and notes open
/// by pushing onto the surrounding navigation stack (see `filesDestinations`).
struct FilesRoot: View {
    let path: String?

    var body: some View {
        FileBrowser(path: path)
    }
}

extension DuetStore {
    /// Connected to the hub now (requests can be answered).
    var isConnected: Bool { if case .connected = connection { true } else { false } }
}

/// Whether Claude or a worker is working in (or under) a folder right now: its listing and files keep refreshing.
@MainActor
private func workGoesOn(in folder: String, _ store: DuetStore) -> Bool {
    let inside = { (dir: String) in dir == folder || dir.hasPrefix(folder + "/") || folder.hasPrefix(dir + "/") }
    if store.leadStatus.busy, let cwd = store.leadCwd, inside(cwd) { return true }
    return store.tasks.values.contains { $0.state == "running" && ($0.cwd.map(inside) ?? false) }
}

/// One folder: its entries with their git status, the way up, and whether Claude works here.
struct FileBrowser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let path: String?
    @State private var listing: FsListing?
    @State private var problem: String?
    @State private var query = ""
    @State private var confirmMove = false
    @AppStorage("files.showHidden") private var showHidden = false

    private var compact: Bool { density == .compact }

    var body: some View {
        content
            .navigationTitle(listing.map { Paths.name($0.path) } ?? (path.map(Paths.name) ?? "Files"))
            .navigationSubtitle(listing.map { Paths.short($0.path) } ?? "")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .paneActions(search: $query, prompt: "Filter this folder") { actions }
            // Again once connected: opened at launch, it asks before the connection is up.
            .task(id: "\(path ?? "")|\(model.store.isConnected)") { if model.store.isConnected { await load() } }
            // While Claude or a worker works here, the listing keeps up (every 4 seconds).
            .task(id: listing.map { workGoesOn(in: $0.path, model.store) } ?? false) {
                guard let l = listing, workGoesOn(in: l.path, model.store) else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { await load() }
                }
            }
            .refreshable { await load() }
            .confirmationDialog("Move Claude to \(Paths.short(listing?.path ?? ""))?", isPresented: $confirmMove, titleVisibility: .visible) {
                Button("Move Claude") { if let p = listing?.path { model.moveClaude(to: p) } }
            } message: {
                Text("Claude keeps the conversation and works here from its next turn. New shells and worker tasks start here too.")
            }
    }

    @ViewBuilder private var content: some View {
        if let listing {
            List {
                Section {
                    PathBar(path: listing.path, repo: listing.repo) { model.openFiles($0, compact: compact) }
                    claudeRow(listing.path)
                    // Every kept note, from anywhere: the way back into what you've asked about.
                    if !model.store.annotations.isEmpty {
                        let waiting = model.store.annotations.values.filter { $0.status == "open" }.count
                        NavigationLink(value: FilesRoute.notes(.all)) {
                            Label("Notes" + (waiting > 0 ? " · \(waiting) waiting" : ""), systemImage: "text.bubble")
                        }
                    }
                }
                Section {
                    let shown = visible(listing.entries)
                    ForEach(shown) { e in
                        let full = Paths.join(listing.path, e.name)
                        NavigationLink(value: e.isFolder ? FilesRoute.folder(full) : .file(full)) { FileRow(entry: e, notes: noteCounts[full] ?? 0) }
                            .contextMenu { menu(for: e, full) }
                    }
                    if shown.isEmpty {
                        Text(query.isEmpty ? "Empty folder" : "Nothing matches “\(query)”").foregroundStyle(.secondary)
                    }
                } footer: {
                    let hidden = listing.entries.count - visible(listing.entries, filter: false).count
                    Text("\(listing.entries.count) items" + (hidden > 0 ? " · \(hidden) hidden" : "") + (listing.truncated ? " · only the first 3,000 are listed" : ""))
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #endif
        } else if let problem {
            ContentUnavailableView("Can't open this folder", systemImage: "folder.badge.questionmark", description: Text(problem))
        } else {
            ProgressView(model.store.isConnected ? "Listing \(path.map(Paths.short) ?? "Claude's folder")…" : "Connecting to the hub…")
        }
    }

    @ViewBuilder private func claudeRow(_ here: String) -> some View {
        if model.store.leadCwd == here {
            Label("Claude works here", systemImage: "sparkles").foregroundStyle(.stateWorking)
        } else {
            Button {
                confirmMove = true
            } label: {
                Label(model.store.leadStatus.busy ? "Move Claude here (after this turn)" : "Move Claude here", systemImage: "arrow.forward.circle")
            }
            .disabled(model.store.leadStatus.busy)
        }
    }

    @ViewBuilder private func menu(for e: FsEntry, _ full: String) -> some View {
        Button("Copy Path", systemImage: "doc.on.doc") { Pasteboard.copy(full) }
        if e.isFolder {
            Button("Open Shell Here", systemImage: "terminal") { model.openTerminal(.shell, cwd: full) }
            Button("Move Claude Here", systemImage: "arrow.forward.circle") { model.moveClaude(to: full) }
                .disabled(model.store.leadStatus.busy || model.store.leadCwd == full)
        } else {
            Button("Ask Claude About It", systemImage: "bubble.left") { model.askAbout("About \(Paths.short(full)): ", compact: compact) }
        }
    }

    private var actions: some View {
        Menu {
            if let cwd = model.store.leadCwd {
                Button("Claude's Folder", systemImage: "sparkles") { model.openFiles(cwd, compact: compact) }
            }
            Button("Home Folder", systemImage: "house") { model.openFiles("~", compact: compact) }
            let recent = model.store.recentCwds.filter { $0 != model.store.leadCwd }
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent, id: \.self) { p in Button(Paths.short(p), systemImage: "clock") { model.openFiles(p, compact: compact) } }
                }
            }
            Divider()
            Toggle("Show Hidden Files", systemImage: "eye", isOn: $showHidden)
            if let l = listing {
                Button("Open Shell Here", systemImage: "terminal") { model.openTerminal(.shell, cwd: l.path) }
                Button("Copy Path", systemImage: "doc.on.doc") { Pasteboard.copy(l.path) }
            }
            Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
        } label: {
            Label("Folders", systemImage: "folder.badge.gearshape")
        }
    }

    /// How many kept notes each file has.
    private var noteCounts: [String: Int] {
        model.store.annotations.values.reduce(into: [:]) { out, a in if case .file(let p) = a.surface { out[p, default: 0] += 1 } }
    }

    private func visible(_ entries: [FsEntry], filter: Bool = true) -> [FsEntry] {
        entries.filter { e in
            (showHidden || !e.name.hasPrefix(".")) && (!filter || query.isEmpty || e.name.localizedCaseInsensitiveContains(query))
        }
    }

    private func load() async {
        do {
            let l = try await model.listFolder(path)
            if l != listing { listing = l }
            problem = nil
        } catch {
            if listing == nil { problem = error.localizedDescription }
        }
    }
}

/// The folders from the root down to this one; tap one to go there. The repo's branch, if it's in one.
struct PathBar: View {
    let path: String
    let repo: FsRepo?
    let go: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let all = Paths.ancestors(path)
                    ForEach(Array(all.enumerated()), id: \.offset) { i, p in
                        if i > 0 { Image(systemName: "chevron.forward").font(.caption2).foregroundStyle(.tertiary) }
                        Button(i == 0 ? "/" : Paths.name(p)) { go(p) }
                            .buttonStyle(.borderless)
                            .font(.callout.weight(i == all.count - 1 ? .semibold : .regular))
                            .disabled(i == all.count - 1)
                    }
                }
            }
            .defaultScrollAnchor(.trailing)
            if let repo {
                Label("\(repo.branch) · \(Paths.short(repo.root))", systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct FileRow: View {
    let entry: FsEntry
    var notes = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: FileIcon.symbol(entry)).foregroundStyle(entry.isFolder ? Color.textSecondary : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if notes > 0 {
                Label("\(notes)", systemImage: "text.bubble.fill").font(.caption2.bold()).foregroundStyle(Color.stateNeedsYou)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("\(notes) note\(notes == 1 ? "" : "s")")
            }
            if let g = entry.git { GitBadge(code: g) }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let when = entry.modified.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return entry.isFolder ? when : "\(entry.size.formatted(.byteCount(style: .file))) · \(when)"
    }
}

/// A file's or folder's git status, as one letter (a dot for a folder with changes inside).
struct GitBadge: View {
    let code: String

    var body: some View {
        let tint = Self.tint(code)
        Text(code == "•" ? "●" : code)
            .font(.caption2.bold().monospaced())
            .foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background { RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.15)) }
            .accessibilityLabel(Self.name(code))
    }

    /// The colors an editor gives git status: new green, deleted red, renamed blue, conflicted purple, changed orange.
    static func tint(_ code: String) -> Color {
        switch code {
        case "A", "?": .codeAddition
        case "D": .codeDeletion
        case "R": .blue
        case "U": .purple
        default: .orange
        }
    }

    static func name(_ code: String) -> String {
        switch code {
        case "M": "Changed"
        case "A": "Added"
        case "?": "New, not yet in git"
        case "D": "Deleted"
        case "R": "Renamed"
        case "U": "Conflict"
        default: "Changes inside"
        }
    }
}

enum FileIcon {
    static func symbol(_ e: FsEntry) -> String {
        if e.isFolder { return e.link == true ? "folder.badge.gearshape" : "folder.fill" }
        return symbol(name: e.name)
    }

    /// A file's symbol from its name.
    static func symbol(name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "py", "ts", "tsx", "js", "jsx", "rs", "go", "c", "h", "cpp", "m", "java", "kt", "rb", "sh", "zsh": return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "rtf": return "doc.plaintext"
        case "json", "toml", "yaml", "yml", "xml", "plist": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "zip", "gz", "tar", "xz", "bz2": return "doc.zipper"
        case "log": return "list.bullet.rectangle"
        default: return "doc"
        }
    }
}

/// One file: its text with line numbers and the lines changed since the last commit. Tap a line to ask Claude about
/// it; on iPad, write on it with Apple Pencil and the notes go to Claude tagged to those lines.
struct FileViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    /// A file window's own stack: what this file opens (its notes) stays in that window.
    @Environment(FilesStack.self) private var filesStack: FilesStack?
    let path: String
    /// Show and pick this line when it opens (from a note or a diagram).
    var line: Int? = nil
    @State private var file: FsFile?
    @State private var problem: String?
    @State private var page = DiagramPage()
    @State private var drafts: [DraftNote] = []
    @State private var selected: InkAnchor?
    @State private var sent = 0
    @State private var changeIndex = 0
    #if os(iOS)
    @State private var ink = InkController()
    @State private var nativeInk = NativeInkController()
    /// Code drawn natively under a canvas that is the page, as in Notes (being built; the web page otherwise).
    @AppStorage("nativeCodePage") private var nativeCode = false
    /// The tags the code pages are seen through, shared across files.
    @State private var tags = NoteTags.shared
    /// Once there are many tags: the ones Apple Intelligence says matter for this file and what's being written.
    @State private var relevant: [String] = []
    /// A tag being renamed (or made), and its new name.
    @State private var renaming: String?
    @State private var newName = ""
    #endif

    private var pencil: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    /// The notes the tray offers to send: on the native page, not the questions (they ask themselves).
    private var trayDrafts: Binding<[DraftNote]> {
        guard nativePage else { return $drafts }
        return Binding(get: { drafts.filter { !Self.asksItself($0) } },
                       set: { kept in drafts = drafts.filter { Self.asksItself($0) } + kept })
    }

    /// A note on the native page that's sent as soon as it's read: a question in words (not one only by ink colour).
    static func asksItself(_ d: DraftNote) -> Bool {
        d.span != nil && d.note.intent == .question && (CodeQuestion.asks(d.note.text) || d.reading?.kind == .question)
    }

    /// The file is on the native page (iPad, with the setting on).
    private var nativePage: Bool {
        #if os(iOS)
        pencil && nativeCode
        #else
        false
        #endif
    }

    private var panelShown: Bool { selected != nil || file?.truncated == true || drafts.contains { !$0.sent } }

    var body: some View {
        Group {
            if let file {
                if file.binary || file.text == nil {
                    ContentUnavailableView("Not a text file", systemImage: "doc.zipper",
                                           description: Text("\(file.size.formatted(.byteCount(style: .file))). Open it in a shell to work with it."))
                } else {
                    surface(file)
                }
            } else if let problem {
                ContentUnavailableView("Can't open this file", systemImage: "exclamationmark.triangle", description: Text(problem))
            } else {
                ProgressView("Reading \(Paths.name(path))…")
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) { if !pencil { bottomBar } }
        .overlay(alignment: .topTrailing) { if pencil, panelShown { InkPanel { bottomBar } } }
        .navigationTitle(Paths.name(path))
        .navigationSubtitle(subtitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .paneActions { actions }
        .onAppear {
            NoteGists.shared.apple = model.apple
            #if os(iOS)
            TagSuggestions.shared.apple = model.apple
            #endif
            page.onTap = { selected = $0 }
            // A note's bubble in the margin: that note (or the notes on that line).
            page.onMark = { ids in push(ids.count == 1 ? .note(ids[0]) : .notes(.file(path))) }
            // A diagram that explains these lines: it opens beside the conversation, with the element picked.
            page.onDiagram = { id, element in model.openDiagram(id, compact: density == .compact, focus: element) }
            if pencil { model.pencilSurfaces += 1 }
        }
        .onDisappear {
            if pencil { model.pencilSurfaces -= 1 }
            // The page is left (another file, or closed): its new notes are offered for tagging.
            reviewTags()
        }
        .task(id: "\(path)|\(model.store.isConnected)") {
            guard model.store.isConnected || model.isDemo else { return }
            await load()
            if let line { reveal(line) }
        }
        // Opened again at another line: its tab stays, and shows that line.
        .onChange(of: line) { _, l in if let l { reveal(l) } }
        // While work goes on in its folder, the file keeps up: its folder is checked every 4 seconds, and the file is
        // read again when it changed.
        .task(id: workGoesOn(in: (path as NSString).deletingLastPathComponent, model.store)) {
            guard workGoesOn(in: (path as NSString).deletingLastPathComponent, model.store) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                let folder = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
                if let e = try? await model.listFolder(folder).entries.first(where: { $0.name == name }), e.mtime != file?.mtime || e.size != file?.size {
                    await load()
                }
            }
        }
        .sensoryFeedback(.success, trigger: sent)
        .sensoryFeedback(.selection, trigger: selected?.id)
        // What's picked goes with a message as the composer's chip; writing on it keeps its tab.
        .onChange(of: selected?.id) { model.picked(selected, in: .file(path)) }
        .onChange(of: drafts.isEmpty) { _, empty in if !empty { model.keepOpen(.file(path)) } }
        #if os(iOS)
        // Tags for each note are worked out as it closes, so the review is ready when the page is left.
        .onChange(of: drafts) { _, now in if nativePage { TagSuggestions.shared.prepare(now) } }
        #endif
        #if os(iOS)
        // Sent here to write on (Write on iPad): the Pencil tools come out.
        .writesWhenSent(.file(path)) { if pencil { ink.showTools() } }
        #endif
    }

    private var subtitle: String {
        guard let file else { return Paths.short((path as NSString).deletingLastPathComponent) }
        var parts = [Paths.short((path as NSString).deletingLastPathComponent)]
        if let n = file.changed?.count, n > 0 { parts.append("\(n) line\(n == 1 ? "" : "s") changed") } else if file.git == "?" { parts.append("new") }
        return parts.joined(separator: " · ")
    }

    /// The kept notes on this file, each at the line its code is on now; and how many no longer match the file.
    private func marks(_ text: String) -> (marks: [Int: LineMark], unplaced: Int) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let rank = ["open": 2, "answered": 1, "resolved": 0]
        var at: [Int: (ids: [String], state: String, cards: [NoteCard], history: [NoteCard], answering: Bool)] = [:]
        var unplaced = 0
        // Seen through a tag: only its notes have marks.
        let shown: Set<String>? = {
            #if os(iOS)
            return nativePage ? nativeInk.shownNotes : nil
            #else
            return nil
            #endif
        }()
        for a in model.store.annotations(onFile: path).sorted(by: { $0.ts < $1.ts }) where shown?.contains(a.id) ?? true {
            guard let l = a.lines?.first, let r = Reanchor.place(l, in: lines) else { unplaced += 1; continue }
            var e = at[r.lowerBound] ?? ([], "resolved", [], [], false)
            // Being answered now (or asked a moment ago and not yet picked up): its pill pulses.
            if a.answering != nil || (a.status == "open" && a.intent == .question && Date().timeIntervalSince(a.date) < 120) { e.answering = true }
            e.ids.append(a.id)
            // The most pressing wins: waiting, then answered, then resolved.
            if rank[a.status, default: 0] > rank[e.state, default: 0] { e.state = a.status }
            // Not yet resolved: a card under the line, with the answer once there is one. Every note goes in the
            // line's history, with a gist for its pill (made on this device; its first words until then).
            let plain = NoteCard.of(a)
            let gist = NoteGists.shared.gist(question: plain.question, code: NoteGist.code(around: r.lowerBound, in: lines),
                                             answer: a.answered ? a.answer.map(NoteGist.firstSentence) : nil)
            if a.status != "resolved" { e.cards.append(NoteCard(id: plain.id, question: plain.question, answer: a.status == "answered" ? plain.answer : nil, chip: plain.chip, waiting: plain.waiting)) }
            e.history.append(NoteCard.of(a, gist: gist))
            at[r.lowerBound] = e
        }
        return (at.mapValues { LineMark(ids: $0.ids, state: $0.state, cards: $0.cards, history: $0.history, answering: $0.answering) }, unplaced)
    }

    /// The start of an answer for its card: its first paragraph of prose, after any "Let me look…" on the way there,
    /// with Markdown's marks gone.
    static func gist(_ markdown: String) -> String {
        var fence = false
        var paragraphs: [[String]] = [[]]
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { fence.toggle(); continue }
            if fence || line.hasPrefix("|") { continue }
            if line.isEmpty { if !(paragraphs.last ?? []).isEmpty { paragraphs.append([]) }; continue }
            paragraphs[paragraphs.count - 1].append(line)
        }
        var prose = paragraphs.filter { !$0.isEmpty }.map { $0.joined(separator: " ") }
        while prose.count > 1, prose[0].range(of: #"^(Let me|Let's|I'll|I will|Now I'll|First, I'll)\b"#, options: .regularExpression) != nil {
            prose.removeFirst()
        }
        let plain = (prose.first ?? "")
            .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        return plain.isEmpty ? "Claude answered: open it to read." : plain
    }

    /// The diagrams that explain this file (their latest versions), drawn on the lines they explain.
    private func peeks(_ text: String) -> [DiagramPeek] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return DiagramPeek.all(for: path, lineCount: lines.last == "" ? lines.count - 1 : lines.count, in: model.store.diagrams.values)
    }

    @ViewBuilder private func surface(_ f: FsFile) -> some View {
        let doc = DiagramDocument.code(path: f.path, text: f.text ?? "", changed: f.changed ?? [], removedAfter: f.removedAfter ?? [],
                                       marks: marks(f.text ?? "").marks, peeks: peeks(f.text ?? ""))
        #if os(iOS)
        if pencil, nativeCode {
            NativeCodeInkRepresentable(path: f.path, text: f.text ?? "", controller: nativeInk, drafts: $drafts, tag: tags.current,
                                       decor: CodePageDecor(changed: Set(f.changed ?? []), removedAfter: Set(f.removedAfter ?? []),
                                                            marks: marks(f.text ?? "").marks, peeks: peeks(f.text ?? "")),
                                       onSelect: { selected = $0 }, onMark: { ids in page.onMark?(ids) },
                                       onDiagram: { id, element in page.onDiagram?(id, element) },
                                       onQuestion: { id in Task { await send(only: [id]) } },
                                       onCancel: { id in
                                           drafts.removeAll { $0.id == id }
                                           if model.store.annotations[id] != nil { model.send(.annotationUpdate(id: id, delete: true)) }
                                       },
                                       onErased: { id in
                                           if model.store.annotations[id] != nil { model.send(.annotationUpdate(id: id, delete: true)) }
                                       },
                                       onResolve: { ids in for id in ids { model.send(.annotationUpdate(id: id, status: "resolved")) } },
                                       onSeen: { model.sawAnswers($0) })
        } else if pencil {
            InkSurfaceRepresentable(page: page, document: doc, key: "file-\(f.path)", isDiff: true, controller: ink,
                                    drafts: $drafts, search: "", onSelect: { selected = $0 }, onSqueeze: { Task { await send() } })
        } else {
            DiagramWebView(page: page, document: doc)
        }
        #else
        DiagramWebView(page: page, document: doc)
        #endif
    }

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 0) {
            if file?.truncated == true {
                Label("This file is over 1 MB; only its first megabyte is shown.", systemImage: "scissors").font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if let selected, let line = selected.line {
                PickBar(title: "Line \(line)", symbol: "text.line.first.and.arrowtriangle.forward", monospaced: true,
                        askHere: nativePage ? nil : { q in
                            model.askHere(q, on: .file(path: path), lines: [InkLines(file: path, start: line, end: line, code: selected.label)])
                        },
                        askClaude: { model.askAbout("About \(Paths.short(path)):\(line) (`\(selected.label)`): ", compact: density == .compact) })
            }
            // On the native page, a question written with the Pencil asks itself: the tray holds the other notes.
            if pencil, drafts.contains(where: { !$0.sent && !(nativePage && Self.asksItself($0)) }) {
                NotesTray(drafts: trayDrafts, squeezeSends: !nativePage) { Task { await send() } }
            }
        }
        .background(pencil ? AnyShapeStyle(.clear) : AnyShapeStyle(.bar))
    }

    @ViewBuilder private var actions: some View {
        let notes = model.store.annotations(onFile: path).count
        if notes > 0 {
            Button { push(.notes(.file(path))) } label: { Label("\(notes) Note\(notes == 1 ? "" : "s")", systemImage: "text.bubble") }
                .labelStyle(.titleAndIcon)
                .help("Your notes on this file, with Claude's answers")
        }
        if let changed = file?.changed, !changed.isEmpty {
            Button("Next Change", systemImage: "arrow.down.to.line") {
                let starts = changeStarts(changed)
                let to = starts[changeIndex % starts.count]
                #if os(iOS)
                if pencil, nativeCode { nativeInk.scrollTo(line: to) } else { page.scrollTo(line: to) }
                #else
                page.scrollTo(line: to)
                #endif
                changeIndex += 1
            }
        }
        #if os(iOS)
        if pencil { Button("Pencil Tools", systemImage: "pencil.tip.crop.circle") { nativeCode ? nativeInk.toggleTools() : ink.toggleTools() } }
        if pencil, nativeCode { tagMenu }
        #endif
        Button("Side Chat", systemImage: "bubble.left.and.bubble.right") { model.openSideChat(about: .file(path: path)) }
            .help("Ask a quick question about this file, beside the conversation (⌘⇧K)")
        Menu {
            Button("Ask Claude About This File", systemImage: "bubble.left") { model.askAbout("About \(Paths.short(path)): ", compact: density == .compact) }
            if density != .compact {
                Button("Reveal in Explorer", systemImage: "sidebar.left") { model.reveal(path) }
                if filesStack == nil { Button("Open in New Window", systemImage: "macwindow.badge.plus") { model.openWindow(.file(path)) } }
            }
            // To write on with Apple Pencil, at the line picked here.
            WriteOnIPad(place: .file(path, line: selected?.line ?? line))
            Button("Copy Path", systemImage: "doc.on.doc") { Pasteboard.copy(path) }
            if let text = file?.text { Button("Copy Text", systemImage: "doc.on.clipboard") { Pasteboard.copy(text) } }
            Button("Open Shell Here", systemImage: "terminal") { model.openTerminal(.shell, cwd: (path as NSString).deletingLastPathComponent) }
            Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
            #if os(iOS)
            if pencil { Toggle("Native Page (Prototype)", systemImage: "pencil.and.outline", isOn: $nativeCode) }
            #endif
        } label: { Label("More", systemImage: "ellipsis.circle") }
    }

    #if os(iOS)
    /// The tag the page is seen through: the page's title. Picking one carries over to every file; anything written
    /// then is filed under it.
    @ViewBuilder private var tagMenu: some View {
        let ranked = tags.ranked(onFile: nativeInk.fileTags)
        Menu {
            // Another tag: the notes written under this one are offered for tagging first.
            Picker("Tag", selection: Binding(get: { tags.current }, set: { reviewTags(); tags.pick($0) })) {
                Text("All Notes").tag(String?.none)
                // Write freely: nothing there is filed or reviewed.
                Label("Scratchpad", systemImage: "scribble").tag(Optional(NoteTags.scratchpad))
                if !relevant.isEmpty {
                    // Many tags: the few that matter here, then the rest out of the way.
                    Section("Suggested Here") { ForEach(relevant, id: \.self) { Text($0).tag(Optional($0)) } }
                } else if !ranked.here.isEmpty {
                    Section("On This File") { ForEach(ranked.here, id: \.self) { Text($0).tag(Optional($0)) } }
                }
                let rest = (relevant.isEmpty ? ranked.other : ranked.here + ranked.other).filter { !relevant.contains($0) }
                if !rest.isEmpty {
                    Section(relevant.isEmpty ? "Other Tags" : "More") { ForEach(rest.prefix(40), id: \.self) { Text($0).tag(Optional($0)) } }
                }
            }
            Divider()
            Button("New Tag…", systemImage: "plus") { newName = ""; renaming = "" }
            if let current = tags.current, !tags.onScratchpad {
                Button("Rename “\(current)”…", systemImage: "pencil") { newName = current; renaming = current }
                Button("Delete “\(current)”", systemImage: "trash", role: .destructive) { tags.delete(current) }
            }
            Divider()
            // Long lines wrap on the file's paper, cut to the width it was first shown at; this cuts it again.
            Button("Reflow to This Width", systemImage: "text.alignleft") { nativeInk.reflow() }
        } label: {
            Label(tags.onScratchpad ? "Scratchpad" : tags.current ?? "All Notes", systemImage: tags.onScratchpad ? "scribble" : "tag")
        }
            // With many tags, Apple Intelligence picks the ones for this file and what's being written (after lift).
            .task(id: "\(path)|\(tags.all.count)|\(drafts.last?.id ?? "")") { await rankTags() }
            .labelStyle(.titleAndIcon)
            .help("See this file's notes through one tag. New notes are filed under it.")
            .alert(renaming == "" ? "New Tag" : "Rename Tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button(renaming == "" ? "Create" : "Rename") {
                    if let old = renaming { old.isEmpty ? tags.pick(newName) : tags.rename(old, to: newName) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                if renaming != "" { Text("Renamed on every file. A name that's already a tag merges the two.") }
            }
    }
    #endif

    /// Above this many tags, the menu leads with the ones Apple Intelligence picks for this file.
    private static let manyTags = 12

    private func rankTags() async {
        #if os(iOS)
        guard tags.all.count > Self.manyTags else { relevant = []; return }
        let apple = model.apple
        let asking = drafts.last.map { $0.reading?.text ?? $0.raw ?? "" } ?? ""
        let code = file?.text.map { String($0.prefix(600)) } ?? ""
        relevant = await apple.relevantTags(all: tags.all, module: path, code: code, asking: asking) ?? []
        #endif
    }

    /// The notes written here since the last review, offered for tagging (switching tag or file, or closing the page).
    private func reviewTags() {
        #if os(iOS)
        // The scratchpad isn't filed.
        guard nativePage, model.tagReview == nil, !tags.onScratchpad else { return }
        let notes = nativeInk.unreviewed()
        guard !notes.isEmpty else { return }
        TagSuggestions.shared.prepare(notes)
        model.tagReview = TagReview(key: "file-\(path)", path: path, drafts: notes)
        #endif
    }

    /// The first line of each run of changed lines.
    private func changeStarts(_ lines: [Int]) -> [Int] {
        let all = Set(lines)
        return lines.sorted().filter { !all.contains($0 - 1) }
    }

    private func load() async {
        // Back to a file read a moment ago (its tab again): show it at once, then check it on the hub machine.
        if file == nil, SpeedSwitches.on("files"), let kept = model.recentFile(path) { file = kept }
        do {
            let f = try await model.readFile(path)
            if f != file { file = f }
            problem = nil
        } catch {
            if file == nil { problem = error.localizedDescription }
        }
    }

    /// What this file opens (its notes): in its window's own stack, else where the layout opens things.
    /// Show and pick a line, on whichever page shows the file.
    private func reveal(_ line: Int) {
        #if os(iOS)
        if pencil, nativeCode { nativeInk.reveal(line: line); return }
        #endif
        page.reveal(line: line)
    }

    private func push(_ route: FilesRoute) {
        if let filesStack { filesStack.path.append(route) } else { model.open(route, compact: density == .compact) }
    }

    /// Just these notes, now: a question written with the Pencil, read and tagged, asks itself without sweeping up
    /// the other notes waiting on the page.
    private func send(only ids: Set<String>) async {
        #if os(iOS)
        let pending = drafts.filter { ids.contains($0.id) && !$0.sent }
        guard !pending.isEmpty else { return }
        let image = await nativeInk.snapshot(only: ids)?.jpegData(compressionQuality: 0.7)?.base64EncodedString()
        model.send(.notes(surface: .file(path: path), items: await nativeInk.items(pending), image: image, imageType: image == nil ? nil : "image/jpeg"))
        for i in drafts.indices where ids.contains(drafts[i].id) { drafts[i].sent = true }
        #endif
    }

    private func send() async {
        #if os(iOS)
        if nativeCode { await nativeInk.finishNote() } else { await ink.finishNote() }
        let pending = drafts.filter { !$0.sent }
        guard !pending.isEmpty else { nativeCode ? nativeInk.toggleTools() : ink.toggleTools(); return }
        let picture = nativeCode ? await nativeInk.snapshot() : await ink.snapshot()
        let image = picture?.jpegData(compressionQuality: 0.7)?.base64EncodedString()
        let items = nativeCode ? await nativeInk.items(pending) : await ink.items(pending)
        model.send(.notes(surface: .file(path: path), items: items, image: image, imageType: image == nil ? nil : "image/jpeg"))
        for i in drafts.indices where !drafts[i].sent { drafts[i].sent = true }
        sent += 1
        #endif
    }
}
