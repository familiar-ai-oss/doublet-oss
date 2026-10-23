import DuetKit
import SwiftUI

/// Claude's folder as a tree, the way an editor's explorer shows a project: folders open in place, each entry with its
/// git status, and the files Claude and its workers change marked as they change them. The open folders are watched on
/// the hub machine, so the tree keeps up with every file added, removed or written. One per app: every window's sidebar shows it.
@MainActor
@Observable
final class Explorer {
    @ObservationIgnored weak var model: AppModel?
    /// The folder the tree is for (Claude's), as of the last load.
    private(set) var root: String?
    /// Each listed folder by the path it was asked for (a link's path, not where it leads).
    private(set) var listings: [String: FsListing] = [:]
    private(set) var expanded: Set<String> = []
    private(set) var problems: [String: String] = [:]
    /// The entry picked last (the file open, or a folder you clicked).
    var selected: String?
    var query = ""
    @ObservationIgnored private var dirty: Set<String> = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    #if DEBUG
    /// Previews: a tree without the hub.
    func preview(root: String, listings: [String: FsListing], expanded: Set<String>, selected: String? = nil) {
        self.root = root
        self.listings = listings
        self.expanded = expanded
        self.selected = selected
    }
    #endif

    /// Show Claude's folder (afresh when Claude moved), and tell the hub which folders to watch. Again on reconnecting:
    /// the hub forgets a connection's folders when it closes.
    func follow(_ cwd: String?) async {
        guard let cwd else { return }
        if cwd != root {
            root = cwd
            listings = [:]
            expanded = []
            problems = [:]
        }
        await load(cwd)
        for p in expanded.sorted() { await load(p) }
        watch()
    }

    func toggle(_ path: String) {
        selected = path
        if expanded.remove(path) == nil {
            expanded.insert(path)
            if listings[path] == nil { Task { await load(path) } }
        }
        watch()
    }

    func collapseAll() {
        expanded = []
        watch()
    }

    /// Open the folders down to a file or folder (inside Claude's), and pick it.
    func reveal(_ path: String) {
        guard let root, path == root || path.hasPrefix(root + "/") else { return }
        selected = path
        var folder = (path as NSString).deletingLastPathComponent
        var chain: [String] = []
        while folder.count > root.count { chain.append(folder); folder = (folder as NSString).deletingLastPathComponent }
        expanded.formUnion(chain)
        Task { for p in chain.reversed() where listings[p] == nil { await load(p) } }
        watch()
    }

    /// A watched folder changed on the hub machine: list it again, and the folders above it (their git marks may change too).
    func changed(_ path: String) {
        guard let root else { return }
        var p = path
        while p.count >= root.count {
            if listings[p] != nil { dirty.insert(p) }
            if p == root { break }
            p = (p as NSString).deletingLastPathComponent
        }
        scheduleReload()
    }

    /// List every open folder again (after a turn or a task ends: git status can change without a folder changing).
    func refreshAll() {
        dirty.formUnion(listings.keys.filter { $0 == root || expanded.contains($0) })
        scheduleReload()
    }

    // Changes come in bursts (a worker writing several files): one reload for the lot.
    private func scheduleReload() {
        guard reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            let paths = self.dirty
            self.dirty = []
            self.reloadTask = nil
            for p in paths.sorted() { await self.load(p) }
        }
    }

    private func load(_ path: String) async {
        guard let model else { return }
        do {
            let l = try await model.listFolder(path)
            if listings[path] != l { listings[path] = l }
            problems[path] = nil
        } catch {
            if listings[path] == nil { problems[path] = error.localizedDescription }
        }
    }

    private func watch() {
        guard let root else { return }
        model?.send(.fsWatch(paths: [root] + expanded.sorted()), quiet: true)
    }

    /// The tree as rows, top to bottom: each open folder's entries under it. With a filter, the entries whose names
    /// match (among the folders open) and the folders they're in.
    func rows(showHidden: Bool) -> [ExplorerRow] {
        guard let root, let top = listings[root] else { return [] }
        var out: [ExplorerRow] = []
        func walk(_ folder: String, _ listing: FsListing, _ depth: Int) {
            for e in listing.entries where showHidden || !e.name.hasPrefix(".") {
                let p = Paths.join(folder, e.name)
                out.append(ExplorerRow(path: p, entry: e, depth: depth))
                if e.isFolder, expanded.contains(p), let child = listings[p] { walk(p, child, depth + 1) }
            }
        }
        walk(root, top, 0)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return out }
        let hits = out.filter { $0.entry.name.localizedCaseInsensitiveContains(q) }
        var keep = Set(hits.map(\.path))
        for h in hits {
            var p = (h.path as NSString).deletingLastPathComponent
            while p.count > root.count { keep.insert(p); p = (p as NSString).deletingLastPathComponent }
        }
        return out.filter { keep.contains($0.path) }
    }
}

struct ExplorerRow: Identifiable, Equatable {
    let path: String
    let entry: FsEntry
    let depth: Int
    var id: String { path }
}

/// Who changed a file: Claude in purple, each worker in a color of its own (the same on every device).
enum ActorTint {
    private static let palette: [Color] = [.teal, .orange, .pink, .indigo, .mint, .brown, .cyan]
    static func color(_ actor: String) -> Color {
        actor == "lead" ? .purple : palette[actor.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % palette.count]
    }
}

/// The sidebar's explorer: Claude's folder as a tree, with a filter, and the folder's actions in its header.
struct ExplorerSidebar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("files.showHidden") private var showHidden = false

    var body: some View {
        @Bindable var explorer = model.explorer
        let store = model.store
        List {
                Section {
                    let rows = explorer.rows(showHidden: showHidden)
                    ForEach(rows) { r in
                        ExplorerRowView(row: r)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 10))
                    }
                    if let root = explorer.root, let problem = explorer.problems[root], explorer.listings[root] == nil {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                    } else if explorer.root == nil || explorer.listings[explorer.root!] == nil {
                        Label(store.isConnected ? "Listing Claude's folder…" : "Connecting to the hub…", systemImage: "hourglass").foregroundStyle(.secondary)
                    } else if rows.isEmpty {
                        Text(explorer.query.isEmpty ? "Empty folder" : "Nothing in the open folders matches “\(explorer.query)”").foregroundStyle(.secondary)
                    }
                } header: {
                    ExplorerHeader(showHidden: $showHidden)
                }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 26)
        // Claude's folder, again when it moves or the connection comes back.
        .task(id: "\(store.leadCwd ?? "")|\(store.isConnected)") { if store.isConnected { await explorer.follow(store.leadCwd) } }
        // A turn or a task ended: git status may have changed anywhere.
        .onChange(of: store.leadStatus.busy) { _, busy in if !busy { explorer.refreshAll() } }
        .onChange(of: store.recentResults.first?.taskId) { explorer.refreshAll() }
        .onChange(of: model.openFilePath) { _, p in if let p { explorer.selected = p } }
    }
}

/// The folder's name and branch, and what you can do with it.
private struct ExplorerHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var showHidden: Bool

    var body: some View {
        @Bindable var explorer = model.explorer
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            // Narrows the open folders as you type (a file's folders stay, so it still reads as a tree).
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).font(.caption)
                TextField("Filter open folders", text: $explorer.query)
                    .textFieldStyle(.plain).font(.callout).textCase(nil)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("explorer-filter")
                if !explorer.query.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { explorer.query = "" }
                        .labelStyle(.iconOnly).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.secondary.opacity(0.12)) }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 2)
    }

    private var titleRow: some View {
        let explorer = model.explorer
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(explorer.root.map(Paths.name) ?? "Explorer").font(.subheadline.bold()).textCase(nil).lineLimit(1)
                if let repo = explorer.root.flatMap({ explorer.listings[$0]?.repo }) {
                    Label(repo.branch, systemImage: "arrow.triangle.branch").font(.caption2).textCase(nil).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Group {
                Button("Go to File", systemImage: "doc.text.magnifyingglass") { model.showQuickOpen = true }
                    .help("Go to File (⌘P)")
                Button("Collapse Folders", systemImage: "arrow.down.right.and.arrow.up.left") { explorer.collapseAll() }
                    .help("Collapse all folders")
            }
            .labelStyle(.iconOnly)
            Menu {
                Toggle("Show Hidden Files", systemImage: "eye", isOn: $showHidden)
                if let root = explorer.root {
                    Button("Open Shell Here", systemImage: "terminal") { model.openTerminal(.shell, cwd: root) }
                    Button("Copy Path", systemImage: "doc.on.doc") { Pasteboard.copy(root) }
                    Button("Show in File Viewer", systemImage: "folder") { model.openFiles(root, compact: false) }
                }
                Button("Reload", systemImage: "arrow.clockwise") { explorer.refreshAll() }
            } label: { Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
                .menuIndicator(.hidden)
        }
    }
}

/// One entry: open or close a folder, open a file; its git status in the colors an editor uses, and who changed it.
struct ExplorerRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let row: ExplorerRow

    var body: some View {
        let e = row.entry
        let explorer = model.explorer
        let open = explorer.isExpanded(row.path)
        let picked = explorer.selected == row.path || model.openFilePath == row.path
        // A click opens a file as a preview tab; a double-click keeps the tab, as in an editor.
        Button {
            if e.isFolder { explorer.toggle(row.path) } else { explorer.selected = row.path; model.open(file: row.path) }
        } label: {
            label(e, open: open)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !e.isFolder { model.open(file: row.path, keep: true) } })
        .listRowBackground(picked ? RoundedRectangle(cornerRadius: 6).fill(Color.slateHigh).padding(.horizontal, 6) : nil)
        .contextMenu { menu }
        .draggable(row.path)
        .accessibilityLabel("\(e.isFolder ? "Folder" : "File") \(e.name)\(e.git.map { ", \(GitBadge.name($0))" } ?? "")")
        .accessibilityHint(e.isFolder ? (open ? "Closes the folder" : "Opens the folder") : "Opens the file")
    }

    private func label(_ e: FsEntry, open: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .opacity(e.isFolder ? 1 : 0)
                .frame(width: 10)
            Image(systemName: e.isFolder ? (open ? "folder" : "folder.fill") : FileIcon.symbol(e))
                .font(.callout)
                .foregroundStyle(e.isFolder ? Color.textSecondary : .secondary)
                .frame(width: 18)
            Text(e.name)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(e.git.map { $0 == "•" ? GitBadge.tint($0).opacity(0.85) : GitBadge.tint($0) } ?? .primary)
                .strikethrough(e.git == "D")
            Spacer(minLength: 4)
            // Who changed it lately; the mark fades after 10 minutes (checked every 20 seconds).
            TimelineView(.periodic(from: .now, by: 20)) { _ in
                if let touch = recentTouch { TouchDot(touch: touch, folder: e.isFolder) }
            }
            let notes = noteCount
            if notes > 0 { Image(systemName: "text.bubble.fill").font(.caption2).foregroundStyle(Color.stateNeedsYou).help("\(notes) note\(notes == 1 ? "" : "s")") }
            if let g = e.git {
                Text(g == "•" ? "●" : g).font(.caption2.monospaced().bold()).foregroundStyle(GitBadge.tint(g))
                    .help(GitBadge.name(g))
            }
        }
        .font(density == .dense ? .callout : .body)
        .padding(.leading, CGFloat(row.depth) * 14)
        .padding(.vertical, density == .dense ? 0 : 2)
        .contentShape(Rectangle())
    }

    /// The latest change Claude or a worker made here (to the file, or anything in the folder) in the past 10 minutes.
    private var recentTouch: FileTouch? {
        let store = model.store
        let t = row.entry.isFolder ? store.touches(under: row.path).first?.touch : store.fileTouches[row.path]
        guard let t, Date.now.timeIntervalSince(t.at) < 600 else { return nil }
        return t
    }

    private var noteCount: Int {
        guard !row.entry.isFolder else { return 0 }
        return model.store.annotations(onFile: row.path).count
    }

    @ViewBuilder private var menu: some View {
        let p = row.path
        if row.entry.isFolder {
            Button(model.explorer.isExpanded(p) ? "Close Folder" : "Open Folder", systemImage: "folder") { model.explorer.toggle(p) }
            Button("Open Shell Here", systemImage: "terminal") { model.openTerminal(.shell, cwd: p) }
            Button("Move Claude Here", systemImage: "arrow.forward.circle") { model.moveClaude(to: p) }
                .disabled(model.store.leadStatus.busy || model.store.leadCwd == p)
        } else {
            Button("Open in New Tab", systemImage: "plus.square.on.square") { model.open(file: p, keep: true) }
            Button("Open in New Window", systemImage: "macwindow.badge.plus") { model.openWindow(.file(p)) }
            Divider()
            Button("Ask in a Side Chat", systemImage: "bubble.left.and.bubble.right") { model.openSideChat(about: .file(path: p)) }
            Button("Ask Claude About It", systemImage: "bubble.left") { model.askAbout("About \(Paths.short(p)): ", compact: false) }
        }
        Divider()
        Button("Copy Path", systemImage: "doc.on.doc") { Pasteboard.copy(p) }
        if let root = model.explorer.root, p.hasPrefix(root + "/") {
            Button("Copy Relative Path", systemImage: "doc.on.doc") { Pasteboard.copy(String(p.dropFirst(root.count + 1))) }
        }
    }
}

/// A pencil in the color of whoever last changed it (Claude purple, each worker its own), pulsing for the first minute.
/// Distinct from git's marks: this is who is at work here, not what git sees.
struct TouchDot: View {
    @Environment(AppModel.self) private var model
    let touch: FileTouch
    var folder = false

    var body: some View {
        let fresh = Date.now.timeIntervalSince(touch.at) < 60
        let who = touch.by == "lead" ? "Claude" : model.workerName(touch.by)
        Image(systemName: "pencil.circle.fill")
            .font(.system(size: folder ? 10 : 12))
            .foregroundStyle(.white, ActorTint.color(touch.by))
            .opacity(folder ? 0.75 : 1)
            .phaseAnimator([false, true], trigger: fresh) { dot, on in dot.scaleEffect(fresh && on ? 1.25 : 1) } animation: { _ in fresh ? .easeInOut(duration: 0.8) : nil }
            .help("\(folder ? "Something inside was changed" : "Changed") by \(who) · \(touch.at.formatted(.relative(presentation: .named)))")
            .accessibilityLabel("Changed by \(who)")
    }
}
