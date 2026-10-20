#if os(macOS)
import DuetKit
import SwiftUI

/// The menu-bar item: what Claude is doing and every decision waiting on you, answerable without leaving the
/// app you're in. Plus a quick prompt.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var quick = ""

    var body: some View {
        let store = model.store
        VStack(alignment: .leading, spacing: 12) {
            LeadStatusCard()
            if store.attention.isEmpty {
                Label("Nothing needs you.", systemImage: "checkmark.seal").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.attention) { AttentionCard(item: $0) }
                    }
                }
                .frame(maxHeight: 420)
            }
            HStack(spacing: 6) {
                ForEach(store.workers.filter(\.enabled)) { w in
                    HStack(spacing: 4) {
                        Circle().fill(w.statusColor).frame(width: 7, height: 7)
                        Text(w.shortLabel).font(.caption).lineLimit(1)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background { Capsule().fill(.quaternary) }
                }
            }
            HStack {
                TextField("Ask Claude…", text: $quick).textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard !quick.isEmpty else { return }
                        model.send(.prompt(text: quick))
                        quick = ""
                    }
                Button("Open Doublet") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
        }
        .padding(14)
        .frame(width: 400)
        .environment(\.density, .dense)
    }
}

/// The menu-bar icon: a hand when something needs you, a pulsing sparkle while Claude works.
struct MenuBarIcon: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let n = model.store.attention.count
        if n > 0 {
            Label("\(n)", systemImage: "hand.raised.fill")
        } else {
            Image(systemName: model.store.leadStatus.busy ? "sparkles" : "sparkle")
        }
    }
}
#endif
