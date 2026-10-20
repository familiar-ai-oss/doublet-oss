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
            Image(systemName: FileIcon.symbol(entry)).foregroundStyle(entry.isFolder ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if notes > 0 {
                Label("\(notes)", systemImage: "text.bubble.fill").font(.caption2.bold()).foregroundStyle(Color.accentColor)
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
    #endif

    private var pencil: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
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
            page.onTap = { selected = $0 }
            // A note's bubble in the margin: that note (or the notes on that line).
            page.onMark = { ids in push(ids.count == 1 ? .note(ids[0]) : .notes(.file(path))) }
            // A diagram that explains these lines: it opens beside the conversation, with the element picked.
            page.onDiagram = { id, element in model.openDiagram(id, compact: density == .compact, focus: element) }
            if pencil { model.pencilSurfaces += 1 }
        }
        .onDisappear { if pencil { model.pencilSurfaces -= 1 } }
        .task(id: "\(path)|\(model.store.isConnected)") {
            guard model.store.isConnected || model.isDemo else { return }
            await load()
            if let line { page.reveal(line: line) }
        }
        // Opened again at another line: its tab stays, and shows that line.
        .onChange(of: line) { _, l in if let l { page.reveal(line: l) } }
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
        var at: [Int: (ids: [String], state: String, cards: [NoteCard])] = [:]
        var unplaced = 0
        for a in model.store.annotations(onFile: path).sorted(by: { $0.ts < $1.ts }) {
            guard let l = a.lines?.first, let r = Reanchor.place(l, in: lines) else { unplaced += 1; continue }
            var e = at[r.lowerBound] ?? ([], "resolved", [])
            e.ids.append(a.id)
            // The most pressing wins: waiting, then answered, then resolved.
            if rank[a.status, default: 0] > rank[e.state, default: 0] { e.state = a.status }
            // Not yet resolved: a card under the line, with the answer once there is one.
            if a.status != "resolved" {
                let asked = a.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                e.cards.append(NoteCard(id: a.id, question: asked.isEmpty ? "Your handwritten note" : asked,
                                        answer: a.status == "answered" ? Self.gist(a.answer ?? "") : nil,
                                        chip: a.answered ? AnswerChip.text(for: a) : nil,
                                        waiting: a.answering == "Claude" ? "Claude is answering…" : a.answering != nil ? "A local model is reading the code…" : "Claude is answering…"))
            }
            at[r.lowerBound] = e
        }
        return (at.mapValues { LineMark(ids: $0.ids, state: $0.state, cards: $0.cards) }, unplaced)
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
        if pencil {
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
                        askHere: { q in
                            model.askHere(q, on: .file(path: path), lines: [InkLines(file: path, start: line, end: line, code: selected.label)])
                        },
                        askClaude: { model.askAbout("About \(Paths.short(path)):\(line) (`\(selected.label)`): ", compact: density == .compact) })
            }
            if pencil, drafts.contains(where: { !$0.sent }) {
                NotesTray(drafts: $drafts) { Task { await send() } }
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
                page.scrollTo(line: starts[changeIndex % starts.count])
                changeIndex += 1
            }
        }
        #if os(iOS)
        if pencil { Button("Pencil Tools", systemImage: "pencil.tip.crop.circle") { ink.toggleTools() } }
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
        } label: { Label("More", systemImage: "ellipsis.circle") }
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
    private func push(_ route: FilesRoute) {
        if let filesStack { filesStack.path.append(route) } else { model.open(route, compact: density == .compact) }
    }

    private func send() async {
        #if os(iOS)
        await ink.finishNote()
        let pending = drafts.filter { !$0.sent }
        guard !pending.isEmpty else { ink.toggleTools(); return }
        let image = await ink.snapshot()?.jpegData(compressionQuality: 0.7)?.base64EncodedString()
        model.send(.notes(surface: .file(path: path), items: await ink.items(pending), image: image, imageType: image == nil ? nil : "image/jpeg"))
        for i in drafts.indices where !drafts[i].sent { drafts[i].sent = true }
        sent += 1
        #endif
    }
}
