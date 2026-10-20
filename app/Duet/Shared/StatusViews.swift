import DuetKit
import SwiftUI

/// What Claude is doing right now, with a timer and Stop. The first thing you see on every device.
struct LeadStatusCard: View {
    @Environment(AppModel.self) private var model
    var showControls = true

    var body: some View {
        let store = model.store
        let status = store.leadStatus
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PulsingSymbol(systemName: status.symbol, tint: status.phase.tint, textStyle: .title3, active: status.busy)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.busy ? status.label : "Claude is idle").font(.headline)
                    HStack(spacing: 6) {
                        Text(model.leadModelName)
                        if let e = store.effort { Text("· \(effortLabel(e.rawValue))") }
                        if let since = status.since, status.busy { Text("·"); Elapsed(since: since) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if status.busy && showControls {
                    Button(role: .destructive) { model.send(.interrupt) } label: {
                        Label("Stop", systemImage: "stop.fill").font(.callout.bold())
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .accessibilityIdentifier("stop")
                }
            }
            if let preview = model.livePreview, status.busy {
                Text(preview).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .card(tint: status.phase.tint)
        .accessibilityElement(children: .combine)
    }
}

/// A worker at a glance: status, what it's doing, speed.
struct WorkerChip: View {
    @Environment(AppModel.self) private var model
    let worker: WorkerView
    let activity: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(worker.statusColor).frame(width: 8, height: 8)
                Text(worker.shortLabel).font(.subheadline.bold()).lineLimit(1)
            }
            Text([worker.place, model.workerStatus(worker)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let line = worker.running != nil ? activity : model.workerRecent(worker) { Text(line).font(.caption).lineLimit(2) }
            HStack(spacing: 6) {
                Text("\(effortLabel(worker.effort)) effort")
                if let t = worker.tokPerS { Text("· \(Int(t)) tok/s").monospacedDigit() }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(width: 168, alignment: .leading)
        .card(tint: worker.running != nil ? .accentColor : .secondary)
    }
}

/// Connection state, dialogue budget and Pause, for the regular layouts' sidebar footer and the phone's Now screen.
struct ConnectionFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density

    var body: some View {
        // One line when it fits (iPhone, Mac); two in a narrow sidebar.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { status; Spacer(); controls }
            VStack(alignment: .leading, spacing: 6) { status; HStack { controls } }
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            Circle().fill(color(model.store.connection)).frame(width: 8, height: 8)
            Text(label(model.store.connection)).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }

    @ViewBuilder private var controls: some View {
        if let d = model.store.dialogueState {
            Toggle(isOn: Binding(get: { d.paused }, set: { model.send(.setPause($0)) })) {
                Label(d.paused ? "Paused" : "Pause", systemImage: d.paused ? "pause.circle.fill" : "pause.circle").fixedSize()
            }
            .toggleStyle(.button).controlSize(.small)
            .tint(d.paused ? .orange : .accentColor)
            .help("Pause handoffs: stops delegation and agent-started turns")
            .accessibilityLabel(d.paused ? "Handoffs paused" : "Pause handoffs")
            .accessibilityIdentifier("pause")
        }
        #if DEBUG
        // Test aid: drop the socket as a network failure would; the app resumes with no gap.
        Button("Drop") { model.store.dropConnection() }.font(.caption2).buttonStyle(.bordered).controlSize(.mini).fixedSize()
        #endif
    }

    private func color(_ c: ConnectionState) -> Color {
        switch c {
        case .connected: .green
        case .connecting, .waiting: .orange
        case .failed: .red
        case .idle: .gray
        }
    }

    private func label(_ c: ConnectionState) -> String {
        switch c {
        case .connected: SpeedSwitches.on("list") ? "Connected" : "Connected · seq \(model.store.lastSeq)"
        case .connecting: "Connecting…"
        case .waiting(_, let retry): "Reconnecting in \(String(format: "%.0f", retry)) s"
        case .failed(let e): "Failed: \(e)"
        case .idle: "Not connected"
        }
    }
}

struct SectionTitle: View {
    let title: String
    let symbol: String
    let tint: Color

    init(_ title: String, symbol: String, tint: Color) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Label(title, systemImage: symbol).font(.headline).foregroundStyle(tint)
    }
}
