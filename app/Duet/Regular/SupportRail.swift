import DuetKit
import SwiftUI

/// Beside the conversation: its Overview, in the order you'd look at it.
/// - Now: what needs you, and what Claude is doing.
/// - The work: the plan step by step, each with who's doing it (Claude or a worker), where it stands and what it
///   changed; the tasks outside the plan; and the diagrams Claude drew. The plan, the workers and the changes are one
///   list, so the work reads one way.
/// - Your notes: your own questions and notes, and your side chats, apart from the work.
/// - Elsewhere: Claude sessions running outside Duet, folded away.
/// A tap opens the thing itself beside the conversation, which stays where it is.
struct SupportRail: View {
    @Environment(AppModel.self) private var model
    let conversationId: String?

    var body: some View {
        let conversation = conversationId.flatMap { model.store.conversation($0) }
        ScrollView {
            VStack(spacing: 12) {
                NowCard(conversation: conversation)
                if let c = conversation {
                    WorkCard(conversation: c)
                    // Its side chats. Notes aren't listed here: they live on the code they're about.
                    let chats = model.threads(in: c).filter { if case .chat = $0 { true } else { false } }
                    if !chats.isEmpty { YourNotesCard(threads: chats) }
                } else {
                    hint("Claude's plan, its workers' changes and your side chats show here once a conversation starts.")
                }
                // Sessions running outside Duet, on the hub machine: any conversation's business, after this one's.
                if !model.outsideSessions.isEmpty { RunningElsewhereCard() }
            }
            .padding(10)
        }
        .swipeActionsContainer()
        .accessibilityIdentifier("support-rail")
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }
}

/// One card: a header (its symbol, title and a short summary) that opens the thing itself, and a few lines under it.
struct RailCard<Content: View>: View {
    let title: String
    let symbol: String
    var summary: String? = nil
    var tint: Color = .secondary
    var open: (() -> Void)? = nil
    /// A card of a color of its own (your notes, apart from the work).
    var highlight: Color? = nil
    /// A card that folds: its header shows whether it's open, and `open` folds or unfolds it.
    var expanded: Bool? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let open {
                Button(action: open) { header.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens it beside the conversation")
            } else {
                header
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary)
                .overlay { if let highlight { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(highlight.opacity(0.12)) } }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(highlight.map { AnyShapeStyle($0.opacity(0.45)) } ?? AnyShapeStyle(.separator.opacity(0.6)))
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            if let summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let expanded {
                Image(systemName: "chevron.forward").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            } else if open != nil {
                Image(systemName: "chevron.forward").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Now: what needs you, from every conversation (the first decision, ready to answer), and what Claude is doing in
/// this one, with its next step.
private struct NowCard: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation?

    var body: some View {
        let store = model.store
        let items = store.attention
        RailCard(title: "Now", symbol: "clock", tint: .stateWorking) {
            if !items.isEmpty {
                Button { model.show(.inbox) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.stateNeedsYou).frame(width: 18)
                        Text("Needs you").font(.callout.weight(.medium))
                        Spacer(minLength: 4)
                        Text("\(items.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Image(systemName: "chevron.forward").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("card-needs-you")
                // Small controls: the card's buttons fit the column.
                if let first = items.first { AttentionCard(item: first).controlSize(.small) }
            }
            claude
        }
        .accessibilityIdentifier("card-now")
    }

    /// Claude, the conversation's lead: what it's doing now (or that this is an earlier conversation), and its next
    /// step in the plan.
    private var claude: some View {
        let store = model.store
        let live = conversation == nil || conversation?.id == store.currentConversationId
        let status = store.leadStatus
        let next = conversation.flatMap { store.planSummary($0.id)?.next }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: live ? status.symbol : "clock.arrow.circlepath")
                .foregroundStyle(live ? status.phase.tint : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude · \(model.leadModelName)").font(.callout.weight(.medium)).lineLimit(1)
                Text(live ? status.label : "An earlier conversation: read it, or resume it")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let next {
                    Text("Next: \(next.step.text)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if live, status.busy, let since = status.since {
                Text(since, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card-claude")
    }
}

/// The work: the plan step by step, each with who does it (Claude or a worker), where it stands, what it's doing now and
/// what it changed; then the conversation's tasks outside the plan (all of its tasks, with no plan); then the diagrams
/// Claude drew. A step opens its task (Claude's own, the plan); its change size opens the diff. The header opens the
/// whole plan.
private struct WorkCard: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    @State private var showsAll = false

    var body: some View {
        let store = model.store
        let id = conversation.id
        let items = store.planItems(id)
        let summary = store.planSummary(id)
        let tasks: [TaskEvent] = items.isEmpty ? conversation.taskIds.reversed().compactMap { store.tasks[$0] } : store.unplannedTasks(id)
        let diagrams = conversation.diagramIds.reversed().compactMap { store.diagrams[$0] }
        let live = id == store.currentConversationId
        let limit = showsAll ? Int.max : 6
        RailCard(title: "The work", symbol: "hammer", summary: summary.map { "\($0.done) of \($0.total) done" } ?? count(tasks),
                 tint: .stateWorking, open: items.isEmpty ? nil : { model.show(.plan(id)) }) {
            if items.isEmpty, tasks.isEmpty, diagrams.isEmpty {
                Text(live ? "As Claude works, its plan, its workers' tasks and their changes show here." : "No plan or tasks in this conversation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let summary {
                ProgressView(value: Double(summary.done), total: Double(max(summary.total, 1)))
                    .tint(summary.done == summary.total ? .stateDone : .stateWorking)
            }
            ForEach(items.prefix(limit)) { WorkStepRow(item: $0, conversationId: id) }
            if !tasks.isEmpty {
                if !items.isEmpty { subheading("Not in the plan") }
                ForEach(tasks.prefix(limit), id: \.taskId) { WorkTaskRow(task: $0) }
            }
            if !diagrams.isEmpty {
                subheading(diagrams.count == 1 ? "A diagram Claude drew" : "Diagrams Claude drew")
                ForEach(diagrams.prefix(showsAll ? diagrams.count : 3)) { d in
                    Button { model.openDiagram(d.id, compact: false) } label: { DiagramLine(diagram: d) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("card-diagram-\(d.id)")
                }
            }
            if items.count > 6 || tasks.count > 6 || diagrams.count > 3 {
                Button(showsAll ? "Show less" : "Show all") { withAnimation(.snappy) { showsAll.toggle() } }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .accessibilityIdentifier("card-work")
    }

    private func count(_ tasks: [TaskEvent]) -> String? {
        tasks.isEmpty ? nil : tasks.count == 1 ? "1 task" : "\(tasks.count) tasks"
    }

    private func subheading(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
    }
}

/// One step of the plan in the work: what it is, who does it and where it stands, what it's doing now, and the size of
/// its change.
private struct WorkStepRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let item: PlanItem
    let conversationId: String

    var body: some View {
        let owner = item.step.isClaudes ? "Claude" : model.workerName(item.owner)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: PlanStepRow.symbol(item.phase)).foregroundStyle(PlanStepRow.tint(item.phase)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.step.text)
                    .font(.callout.weight(item.phase == .active || item.phase == .needsYou ? .semibold : .regular))
                    .foregroundStyle(item.phase == .done || item.phase == .cancelled ? .secondary : .primary)
                    .lineLimit(2)
                Text("\(owner) · \(PlanStepRow.label(item.phase, claudes: item.step.isClaudes))")
                    .font(.caption2).foregroundStyle(item.step.isClaudes ? Color.stateWorking : .secondary).lineLimit(1)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let task = item.task, task.showsDiff { ChangeButton(task: task) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let task = item.task { model.openTask(task.taskId, worker: task.worker, compact: density == .compact) } else { model.show(.plan(conversationId)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("work-step-\(item.step.id)")
    }
}

/// A task in the work that isn't a step of the plan: what it was asked, who has it and where it stands, and its change.
private struct WorkTaskRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let task: TaskEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: taskStateSymbol(task.displayState)).foregroundStyle(taskStateTint(task.displayState)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.prompt.flatMap { $0.split(separator: "\n").first.map(String.init) } ?? "Task \(task.taskId)")
                    .font(.callout).lineLimit(2)
                Text("\(model.workerName(task.worker)) · \(taskStateLabel(task.displayState))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if task.showsDiff { ChangeButton(task: task) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.openTask(task.taskId, worker: task.worker, compact: density == .compact) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("work-task-\(task.taskId)")
    }
}

/// The size of a task's change, which opens its diff beside the conversation ("changing" while it runs with none yet).
private struct ChangeButton: View {
    @Environment(AppModel.self) private var model
    let task: TaskEvent

    var body: some View {
        Button { model.openDiff(taskId: task.taskId, worker: task.worker) } label: {
            if let stat = DiffStat(task.evidence), !stat.isEmpty {
                DiffStatLabel(stat: stat)
            } else {
                Text(task.state == "running" ? "changing" : "changes").font(.caption)
            }
        }
        .buttonStyle(.borderless)
        .help(UIDiffHint.text)
        .accessibilityIdentifier("work-change-\(task.taskId)")
    }
}

/// A diagram by name: its title, version, and the code it explains.
private struct DiagramLine: View {
    let diagram: DiagramEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: diagram.kind == .html ? "safari" : "point.3.filled.connected.trianglepath.dotted")
                .font(.caption).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(diagram.title).font(.callout).lineLimit(1)
                if let explains = diagram.explains, let first = explains.first {
                    Text("Explains \(first.label)" + (explains.count > 1 ? " and \(explains.count - 1) more" : ""))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if diagram.version > 1 { Text("v\(diagram.version)").font(.caption2.bold()).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
    }
}

extension CodeRef {
    /// "Lexer.swift:40–58".
    var label: String {
        var s = Paths.name(path)
        if let start { s += ":\(start)" + (end.map { $0 != start ? "–\($0)" : "" } ?? "") }
        return s
    }
}

/// Your notes: what you asked or wrote down in the conversation (questions and notes on its files, diagrams, diffs
/// and plan, and your side chats), apart from the work and in a color of their own, waiting ones first. Each opens its
/// thread in the centre, with what it's on beside it.
private struct YourNotesCard: View {
    @Environment(AppModel.self) private var model
    let threads: [SideThread]
    @State private var showsAll = false

    var body: some View {
        let waiting = threads.filter(\.waiting).count
        RailCard(title: "Side chats", symbol: "bubble.left.and.bubble.right", summary: waiting > 0 ? "\(waiting) waiting" : "\(threads.count)",
                 tint: .orange, highlight: .yellow) {
            ForEach(showsAll ? threads : Array(threads.prefix(4))) { t in
                Button { model.show(t.place) } label: { ThreadRow(item: t) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("card-thread-\(t.id)")
            }
            if threads.count > 4 {
                Button(showsAll ? "Show fewer" : "Show all \(threads.count)") { withAnimation(.snappy) { showsAll.toggle() } }
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .accessibilityIdentifier("card-your-notes")
    }
}

/// A thread in a list (the sidebar, the Threads card): what was asked, what it's on, and whether it's answered.
struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    let item: SideThread

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.tail)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch item {
        case .note(let a, _): a.text.map { "“\($0)”" } ?? NoteDisplay(a.note).chip
        case .chat(let c): c.title
        }
    }

    private var subtitle: String {
        switch item {
        case .note(let a, let replies):
            let state = replies?.isAnswering == true ? "answering" : a.resolved ? "resolved"
                : a.answered ? (a.answeredLocally ? "answered here" : "Claude answered") : "waiting"
            let count = item.replyCount
            return [model.noteAnchorName(a), state, count == 0 ? nil : count == 1 ? "1 reply" : "\(count) replies"].compactMap { $0 }.joined(separator: " · ")
        case .chat(let c):
            let state = c.isAnswering ? "answering" : c.state == "failed" ? "failed" : nil
            return [c.about?.title ?? "Side chat", state].compactMap { $0 }.joined(separator: " · ")
        }
    }

    @ViewBuilder private var icon: some View {
        switch item {
        case .note(_, let replies?) where replies.isAnswering:
            ProgressView().controlSize(.mini)
        case .note(let a, _):
            Image(systemName: a.ink == true ? "pencil.and.scribble" : "questionmark.bubble")
                .foregroundStyle(a.resolved ? Color.secondary : a.answered ? .stateDone : .stateWorking)
        case .chat(let c):
            if c.isAnswering {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: c.state == "failed" ? "exclamationmark.bubble" : "bubble.left.and.bubble.right")
                    .foregroundStyle(c.state == "failed" ? Color.stateFailed : .secondary)
            }
        }
    }
}

/// The size of a change, from the last line of `git diff --stat`: "3 files changed, 25 insertions(+), 23 deletions(-)".
struct DiffStat: Equatable {
    var files = 0, added = 0, removed = 0

    init() {}

    init?(_ evidence: String?) {
        guard let line = evidence?.split(separator: "\n").last.map(String.init), line.contains("changed") else { return nil }
        func count(_ pattern: Regex<(Substring, Substring)>) -> Int { line.firstMatch(of: pattern).flatMap { Int($0.1) } ?? 0 }
        files = count(#/(\d+) files? changed/#)
        added = count(#/(\d+) insertions?\(\+\)/#)
        removed = count(#/(\d+) deletions?\(-\)/#)
    }

    var isEmpty: Bool { added == 0 && removed == 0 }
    var label: String { "+\(added) −\(removed)" }

    static func + (a: DiffStat, b: DiffStat) -> DiffStat {
        var s = DiffStat()
        s.files = a.files + b.files
        s.added = a.added + b.added
        s.removed = a.removed + b.removed
        return s
    }
}

private struct DiffStatLabel: View {
    let stat: DiffStat

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(stat.added)").foregroundStyle(.codeAddition)
            Text("−\(stat.removed)").foregroundStyle(.codeDeletion)
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stat.added) lines added, \(stat.removed) removed")
    }
}
