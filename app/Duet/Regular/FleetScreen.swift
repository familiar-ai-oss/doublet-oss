import DuetKit
import SwiftUI

/// Every worker, whatever conversation it worked in: the local models on the hub machine, Claude's own subagents, and Apple
/// Intelligence on the connected devices. Each opens its screen (controls, a direct task, every task it ran).
/// Finished tasks from every conversation show underneath, newest first.
struct FleetScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let local = store.workers.filter { !$0.isApple && !$0.isClaude }
        let subagents = store.workers.filter(\.isClaude)
        let apple = store.workers.filter(\.isApple)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group("Local models", symbol: "memorychip", local, empty: "No local workers are configured.")
                if !subagents.isEmpty { group("Claude's subagents", symbol: "sparkles", subagents, empty: "") }
                if !apple.isEmpty { group("Apple Intelligence", symbol: "apple.intelligence", apple, empty: "") }
                if !store.recentResults.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Recent results", symbol: "checkmark.seal", tint: .secondary)
                        ForEach(store.recentResults.prefix(8), id: \.taskId) { t in
                            Button { model.openTask(t.taskId, worker: t.worker, compact: false) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text("\(model.workerName(t.worker)) · \(taskStateLabel(t.displayState))").font(.caption.bold()).foregroundStyle(taskStateTint(t.displayState))
                                        Spacer()
                                        // Which conversation it was for: the way back to its context.
                                        if let c = store.conversationOf(taskId: t.taskId) {
                                            Text(model.conversationTitle(c)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                                        }
                                    }
                                    .onDeviceSummary(t.result, key: "result-\(t.taskId)", edge: .bottom, spacing: 4)
                                    if let p = t.prompt { Text(p).font(.caption).lineLimit(2) }
                                    ResultCard(task: t)
                                }
                                .card()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .swipeActionsContainer()
        .navigationTitle("Fleet")
        #if os(macOS)
        .navigationSubtitle(model.fleetSummary)
        #endif
    }

    private func group(_ title: String, symbol: String, _ workers: [WorkerView], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title, symbol: symbol, tint: .secondary)
            if workers.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(workers) { w in
                Button { model.destination = .worker(w.id) } label: {
                    WorkerRow(worker: w, activity: model.store.workerActivity[w.id])
                        .card(tint: w.running != nil ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fleet-\(w.id)")
            }
        }
    }
}
