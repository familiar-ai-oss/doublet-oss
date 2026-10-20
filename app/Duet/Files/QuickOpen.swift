import DuetKit
import SwiftUI

/// ⌘P: go to a file in Claude's folder by typing part of its name or path, the way an editor's Go to File works.
/// Before you type: the files Claude and its workers changed most recently.
struct QuickOpen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var search: FileSearch?
    @State private var root: String?
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        let hits = results
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to a file in \(root.map(Paths.name) ?? "Claude's folder")", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { if let first = hits.first { open(first) } }
                    .accessibilityIdentifier("quick-open-field")
            }
            .padding(14)
            Divider()
            Group {
                if let problem {
                    ContentUnavailableView("Can't list the files", systemImage: "exclamationmark.triangle", description: Text(problem))
                } else if search == nil {
                    ProgressView("Listing \(root.map(Paths.short) ?? "Claude's folder")…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if hits.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(hits, id: \.self) { rel in
                        Button { open(rel) } label: { QuickOpenRow(rel: rel, root: root ?? "") }
                            .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 380, idealHeight: 460)
        .task { await load() }
        .onAppear { focused = true }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    /// The matches; with nothing typed, recent changes first, then the folder's first files.
    private var results: [String] {
        guard let search, let root else { return [] }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return search.rank(query) }
        let recent = model.store.touches(under: root).map { String($0.path.dropFirst(root.count + 1)) }
        return Array((recent + search.rank("", limit: 40)).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(60))
    }

    private func load() async {
        guard let cwd = model.store.leadCwd else { problem = "Claude's folder isn't known yet."; return }
        root = cwd
        do {
            let files = try await model.store.send(.fsFiles(path: cwd)).files ?? []
            search = FileSearch(files)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func open(_ rel: String) {
        guard let root else { return }
        let full = Paths.join(root, rel)
        dismiss()
        model.open(file: full)
        model.explorer.reveal(full)
    }
}

private struct QuickOpenRow: View {
    @Environment(AppModel.self) private var model
    let rel: String
    let root: String

    var body: some View {
        let name = (rel as NSString).lastPathComponent
        let folder = (rel as NSString).deletingLastPathComponent
        let touch = model.store.fileTouches[Paths.join(root, rel)]
        HStack(spacing: 10) {
            Image(systemName: FileIcon.symbol(name: name)).foregroundStyle(.secondary).frame(width: 20)
            Text(name).fontWeight(.medium).lineLimit(1)
            Text(folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if let touch, Date.now.timeIntervalSince(touch.at) < 3600 { TouchDot(touch: touch) }
        }
        .contentShape(Rectangle())
    }
}
