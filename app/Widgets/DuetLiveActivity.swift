import ActivityKit
import AppIntents
import DuetKit
import SwiftUI
import WidgetKit

@main
struct DuetWidgets: WidgetBundle {
    var body: some Widget { DuetLiveActivity() }
}

/// Claude at a glance on the Lock Screen and in the Dynamic Island: what it's doing and for how long, how fast the
/// hub machine's GPUs are generating, and the request waiting on you, with Approve and Reject.
struct DuetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DuetActivityAttributes.self) { context in
            LockScreenView(state: context.state, stale: context.isStale)
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(DuetLink.open(context.state))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Claude", systemImage: s.symbol).font(.headline).foregroundStyle(s.tint).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let since = s.sinceDate, s.busy {
                        Text(since, style: .timer).font(.headline.monospacedDigit()).multilineTextAlignment(.trailing)
                            .frame(maxWidth: 72, alignment: .trailing).padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.phase).font(.subheadline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let a = s.approval {
                        ApprovalRow(approval: a)
                    } else if !s.workers.isEmpty {
                        WorkerSpeeds(workers: s.workers)
                    }
                }
            } compactLeading: {
                Image(systemName: s.symbol).foregroundStyle(s.tint)
            } compactTrailing: {
                CompactTrailing(state: s)
            } minimal: {
                Image(systemName: s.symbol).foregroundStyle(s.tint)
            }
            .keylineTint(s.tint)
            .widgetURL(DuetLink.open(s))
        }
    }
}

struct LockScreenView: View {
    let state: LiveContent
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: state.symbol).font(.title2).foregroundStyle(state.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Claude").font(.caption).foregroundStyle(.secondary)
                    Text(state.phase).font(.headline).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let since = state.sinceDate, state.busy {
                    Text(since, style: .timer).font(.title3.monospacedDigit()).multilineTextAlignment(.trailing)
                        .frame(maxWidth: 84, alignment: .trailing)
                }
            }
            if let a = state.approval {
                ApprovalRow(approval: a)
            } else if !state.workers.isEmpty {
                WorkerSpeeds(workers: state.workers)
            }
            if stale {
                Text("Not updated lately. Open Doublet to catch up.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}

/// The request: which tool and what it runs, then Reject and Approve. A risky one opens Duet instead of approving here,
/// as its card in the app asks twice.
struct ApprovalRow: View {
    let approval: LiveContent.Approval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(approval.tool).font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background { Capsule().fill(.orange.opacity(0.25)) }
                Text(approval.summary).font(.caption.monospaced()).lineLimit(2)
            }
            HStack(spacing: 8) {
                Button(intent: RejectIntent(approvalId: approval.id)) {
                    Label("Reject", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .tint(.red)
                if approval.risky {
                    Link(destination: DuetLink.approval(approval.id)) {
                        Label("Review in Doublet", systemImage: "exclamationmark.shield").frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background { Capsule().fill(.orange.opacity(0.3)) }
                    }
                } else {
                    Button(intent: ApproveIntent(approvalId: approval.id)) {
                        Label("Approve", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .tint(.green)
                }
            }
            .font(.subheadline.bold())
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }
}

/// Each enabled worker's last generation speed; the R9700's first, biggest.
struct WorkerSpeeds: View {
    let workers: [LiveContent.Worker]

    var body: some View {
        let ordered = workers.sorted { a, b in a.place.contains("R9700") && !b.place.contains("R9700") }
        HStack(alignment: .bottom, spacing: 16) {
            ForEach(Array(ordered.prefix(3).enumerated()), id: \.element.id) { i, w in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Circle().fill(w.busy ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        Text(w.place.isEmpty ? w.name : w.place).font(.caption2.bold()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(w.tokPerS.map { "\(Int($0.rounded()))" } ?? "–")
                            .font(i == 0 ? .title2.bold().monospacedDigit() : .headline.monospacedDigit())
                            .contentTransition(.numericText())
                        Text("tok/s").font(.caption2).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(w.busy ? .primary : .secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Beside the island's camera: how many decisions wait, else the R9700's speed while it works, else the timer.
struct CompactTrailing: View {
    let state: LiveContent

    var body: some View {
        if state.waiting > 0 {
            Text("\(state.waiting)").font(.caption.bold()).foregroundStyle(.orange)
        } else if let w = state.mainWorker, w.busy, let rate = w.tokPerS {
            Text("\(Int(rate.rounded()))").font(.caption.bold().monospacedDigit()).foregroundStyle(.green)
                .contentTransition(.numericText())
        } else if let since = state.sinceDate, state.busy {
            Text(since, style: .timer).font(.caption.monospacedDigit()).multilineTextAlignment(.trailing).frame(maxWidth: 44)
        }
    }
}

enum DuetLink {
    static func open(_ s: LiveContent) -> URL { s.approval.map { approval($0.id) } ?? URL(string: "doublet://lead")! }
    static func approval(_ id: String) -> URL { URL(string: "doublet://approval/\(id)")! }
}

extension LiveContent {
    /// The app's colors: orange when something waits on you, purple while workers run, blue while Claude works.
    var tint: Color {
        if waiting > 0 { return .orange }
        if symbol == "person.2.wave.2" { return .purple }
        return busy ? .blue : .green
    }
}

#Preview("Lock Screen: approval", as: .content, using: DuetActivityAttributes(hub: "hub")) {
    DuetLiveActivity()
} contentStates: {
    LiveContent(phase: "Needs your approval", symbol: "hand.raised.fill", busy: true, since: Date.now.timeIntervalSince1970 - 74, waiting: 1,
                approval: .init(id: "a1", tool: "Bash", summary: "rm -rf build && make", risky: false),
                workers: [.init(id: "qwen-27b", name: "Qwen3.8 27B", place: "R9700", tokPerS: 131, busy: true)])
    LiveContent(phase: "Waiting on workers", symbol: "person.2.wave.2", busy: true, since: Date.now.timeIntervalSince1970 - 312, waiting: 0, approval: nil,
                workers: [.init(id: "qwen-27b", name: "Qwen3.8 27B", place: "R9700", tokPerS: 131, busy: true),
                          .init(id: "qwen-9b", name: "Qwen3.5 9B", place: "RTX 3060", tokPerS: 61, busy: false)])
}
