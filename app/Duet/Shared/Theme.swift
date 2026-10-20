import DuetKit
import SwiftUI

/// How much each device shows. iPhone favours big targets and collapsed detail; Mac favours density.
enum Density: Equatable {
    case compact // iPhone
    case regular // iPad
    case dense   // Mac

    var cardPadding: CGFloat { self == .compact ? 14 : self == .regular ? 12 : 10 }
    var codeLines: Int { self == .compact ? 6 : self == .regular ? 10 : 14 }
    /// Replies longer than this many 60-line chunks show only their first chunk until you tap "Show all": 120 lines
    /// on iPhone, 480 on iPad and Mac (enough for almost any answer; a 2,000-line dump would otherwise be laid out
    /// in full every time the thread opens).
    var collapseOver: Int { self == .compact ? 2 : 8 }
    var showsToolResults: Bool { self != .compact }
}

extension EnvironmentValues {
    @Entry var density: Density = .regular
}

extension WorkerView {
    /// Loaded: done green. Reachable but not loaded, or off: idle.
    var statusColor: Color { enabled && available && loaded ? .stateDone : .stateIdle }

    var statusText: String {
        if !enabled { return "Off" }
        if !available { return isApple ? "Unavailable · \(unavailableReason ?? "not connected")" : "Unavailable" }
        if isClaude, let n = active?.count, n > 1 { return "Working · \(n) at once" }
        if running != nil { return queue.isEmpty ? "Working" : "Working · \(queue.count) queued" }
        return loaded ? "Idle" : "Not loaded"
    }

    /// "Qwen3.8 27B" from "Qwen3.8 27B · R9700", for compact chips.
    var shortLabel: String { label.split(separator: "·").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? label }
    /// "R9700", "RTX 3060", "Mac": where it runs.
    var place: String? { label.split(separator: "·").dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } }
}

extension TaskEvent {
    /// Has a diff to show: while it runs (its changes so far), or once it has changed files. Not an Apple worker's
    /// (it changes no files) nor a Claude subagent's (it shares Claude's folder).
    var showsDiff: Bool {
        !isApple && !isClaude && (state == "running" || (evidence.map { $0 != "not a git repository" && $0 != "no changes" } ?? false))
    }
}

extension LeadStatus.Phase {
    var tint: Color {
        switch self {
        case .idle: .stateIdle
        case .approval: .stateNeedsYou
        default: .stateWorking
        }
    }
}

/// Elapsed time since a date, updating every second while visible.
struct Elapsed: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
            Text(Duration.seconds(max(0, ctx.date.timeIntervalSince(since))).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
        }
    }
}

/// A card: `slateRaised` with the hairline border, or a state's colour as its border (a decision is outlined in
/// `stateNeedsYou`). State colours never fill a card.
struct CardBackground: ViewModifier {
    var tint: Color?
    @Environment(\.density) private var density

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.radiusCard, style: .continuous)
        content
            .padding(density.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { shape.fill(.slateRaised) }
            .overlay { shape.strokeBorder(tint ?? .slateLine, lineWidth: 1) }
    }
}

extension View {
    func card(tint: Color? = nil) -> some View { modifier(CardBackground(tint: tint)) }
}

/// Display names for effort levels: "XHigh", not "Xhigh".
func effortLabel(_ level: String) -> String {
    switch level {
    case "xhigh": "XHigh"
    case "max": "Max"
    default: level.prefix(1).uppercased() + level.dropFirst()
    }
}

/// A symbol and a tint for a task state, as the task threads use them.
func taskStateSymbol(_ state: String) -> String {
    switch state {
    case "done": "checkmark.seal.fill"
    case "stopped", "out_of_room": "pause.circle.fill"
    case "background": "circle.dotted"
    case "failed": "xmark.octagon.fill"
    case "cancelled": "stop.circle"
    case "awaiting_swap": "memorychip"
    case "queued": "hourglass"
    default: "gearshape.2"
    }
}

func taskStateTint(_ state: String) -> Color {
    switch state {
    case "done": .stateDone
    case "failed": .stateFailed
    case "awaiting_swap": .stateNeedsYou // a GPU swap to allow
    case "running": .stateWorking
    default: .stateIdle // queued, stopped, out of context, in the background, cancelled
    }
}

/// Display names for task states.
func taskStateLabel(_ state: String) -> String {
    switch state {
    case "awaiting_swap": "Waiting for a GPU swap"
    case "queued": "Queued"
    case "running": "Running"
    case "done": "Done"
    case "stopped": "Stopped at its turn limit"
    case "out_of_room": "Stopped: out of context"
    case "background": "In the background (not tracked yet)"
    case "failed": "Failed"
    case "cancelled": "Cancelled"
    default: state
    }
}
