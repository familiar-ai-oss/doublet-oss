import DuetKit
import SwiftUI

/// ⌘K: everything by name. Type a few letters, Return runs the top match.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let actions = model.paletteActions.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search commands", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .onSubmit { if let a = actions.first { run(a) } }
            }
            .padding(14)
            Divider()
            List(actions) { a in
                Button { run(a) } label: {
                    Label(a.title, systemImage: a.symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 440)
        .onAppear { focused = true }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func run(_ a: PaletteAction) {
        dismiss()
        a.run()
    }
}

struct PaletteAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let run: () -> Void
}
