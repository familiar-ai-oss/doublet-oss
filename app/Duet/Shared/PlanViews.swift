import DuetKit
import SwiftUI

/// Claude's plan for a conversation: each step with who does it and where it stands (a step handed to a worker follows
/// its task live: queued, working, waiting on you, finished), then the conversation's tasks that aren't in the plan.
/// Tap a handed-out step to open its task.
struct PlanList: View {
    @Environment(AppModel.self) private var model
    let conversationId: String

    var body: some View {
        let store = model.store
        let items = store.planItems(conversationId)
        let others = store.unplannedTasks(conversationId)
        VStack(alignment: .leading, spacing: 12) {
            if items.isEmpty {
                Text(conversationId == store.currentConversationId
                     ? "No plan yet. Claude sets one out before it hands work to a worker, and keeps it current as the work goes."
                     : "No plan in this conversation.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                if let summary = store.planSummary(conversationId) { PlanProgress(summary: summary) }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { PlanStepRow(item: $0) }
                }
            }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(items.isEmpty ? "Tasks" : "Not in the plan").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(others, id: \.taskId) { PlanOtherTask(task: $0) }
                }
                .padding(.top, items.isEmpty ? 0 : 4)
            }
        }
        .accessibilityIdentifier("plan-\(conversationId)")
    }
}

/// How far along the plan is, and Claude's own next step.
struct PlanProgress: View {
    let summary: PlanSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(summary.done) of \(summary.total) done").font(.caption.bold())
                if summary.queued > 0 { Text("· \(summary.queued) queued").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if summary.needsYou > 0 {
                    Label(summary.needsYou == 1 ? "1 needs you" : "\(summary.needsYou) need you", systemImage: "hand.raised.fill")
                        .font(.caption.bold()).foregroundStyle(.orange)
                }
            }
            ProgressView(value: Double(summary.done), total: Double(max(summary.total, 1)))
                .tint(summary.done == summary.total ? .green : .accentColor)
            if let next = summary.next {
                Text("Claude next: \(next.step.text)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One step: what it is, who does it and where it stands, and a line of detail.
struct PlanStepRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let item: PlanItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            PulsingSymbol(systemName: Self.symbol(item.phase), tint: Self.tint(item.phase), active: item.phase == .active && !item.step.isClaudes)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.step.text)
                    .font(.callout.weight(item.phase == .active || item.phase == .needsYou ? .semibold : .regular))
                    .foregroundStyle(item.phase == .done || item.phase == .cancelled ? .secondary : .primary)
                HStack(spacing: 6) {
                    Label(owner, systemImage: item.step.isClaudes ? "sparkles" : "cpu")
                        .font(.caption.bold()).foregroundStyle(item.step.isClaudes ? Color.accentColor : .secondary)
                    Text(Self.label(item.phase, claudes: item.step.isClaudes)).font(.caption).foregroundStyle(Self.tint(item.phase))
                    if let p = item.task?.profile, p != "general" {
                        Text(p).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                            .background { Capsule().fill(.secondary.opacity(0.15)) }
                    }
                }
                if let d = item.detail, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(density == .compact ? 2 : 3)
                }
            }
            Spacer(minLength: 0)
            if item.task != nil { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let t = item.task { model.openTask(t.taskId, worker: t.worker, compact: density == .compact) } }
        .contextMenu {
            if let t = item.task {
                Button("Open Task", systemImage: "arrow.up.right.square") { model.openTask(t.taskId, worker: t.worker, compact: density == .compact) }
            }
            Button("Ask in a Side Chat", systemImage: "bubble.left.and.bubble.right") {
                let detail = [item.detail, item.task?.prompt].compactMap { $0 }.joined(separator: "\n\n")
                model.openSideChat(about: .text(label: "the plan step “\(item.step.text)” (\(owner), \(Self.label(item.phase, claudes: item.step.isClaudes).lowercased()))", text: detail.isEmpty ? nil : detail))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.task != nil ? .isButton : [])
        .accessibilityIdentifier("plan-step-\(item.step.id)")
    }

    private var owner: String { item.step.isClaudes ? "Claude" : model.workerName(item.owner) }

    static func symbol(_ p: PlanItem.Phase) -> String {
        switch p {
        case .pending: "circle"
        case .active: "circle.lefthalf.filled"
        case .queued: "hourglass"
        case .needsYou: "hand.raised.fill"
        case .review: "checkmark.circle"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    static func tint(_ p: PlanItem.Phase) -> Color {
        switch p {
        case .pending, .queued, .cancelled: .secondary
        case .active: .accentColor
        case .needsYou: .orange
        case .review: .teal
        case .done: .green
        case .failed: .red
        }
    }

    static func label(_ p: PlanItem.Phase, claudes: Bool) -> String {
        switch p {
        case .pending: "To do"
        case .active: claudes ? "On it" : "Working"
        case .queued: "Queued"
        case .needsYou: "Needs you"
        case .review: "Finished · Claude reviews it"
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

/// A task of the conversation's that no step names: yours, one of Claude's subagents, or one from before the plan.
private struct PlanOtherTask: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let task: TaskEvent

    var body: some View {
        Button { model.openTask(task.taskId, worker: task.worker, compact: density == .compact) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: taskStateSymbol(task.displayState)).foregroundStyle(taskStateTint(task.displayState)).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.prompt.flatMap { $0.split(separator: "\n").first.map(String.init) } ?? task.taskId).font(.callout).lineLimit(2)
                    Text("\(model.workerName(task.worker)) · \(taskStateLabel(task.displayState)) · for \(model.taskOwner(task.by))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The plan in three lines, for the top of the inspector: progress, what's happening now, and what Claude does next.
struct PlanGlance: View {
    @Environment(AppModel.self) private var model
    let conversationId: String
    var onOpen: () -> Void

    var body: some View {
        if let s = model.store.planSummary(conversationId) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 5) {
                    PlanProgress(summary: s)
                    ForEach(s.now.prefix(3)) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: PlanStepRow.symbol(item.phase)).foregroundStyle(PlanStepRow.tint(item.phase)).font(.caption)
                            Text("\(item.step.isClaudes ? "Claude" : model.workerName(item.owner)): \(item.step.text)").font(.caption).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the whole plan")
            .accessibilityIdentifier("plan-glance")
        }
    }
}

/// The plan as a page Apple Pencil can write on (iPad): one element per step, its `data-duet` the step's id, so a
/// note is tagged to the steps it's written on (the hub's plan notes), as one on a diagram is to its elements.
enum PlanPageHTML {
    static func page(_ items: [PlanItem], summary: PlanSummary?, owner: (PlanItem) -> String, margin: Bool) -> String {
        let rows = items.map { item in
            let detail = item.detail.flatMap { $0.isEmpty ? nil : "<div class=\"detail\">\(escape($0))</div>" } ?? ""
            return """
            <div class="step \(item.phase.rawValue)" data-duet="\(escape(item.step.id))">
            <span class="mark">\(glyph(item.phase))</span>
            <div class="body"><div class="label">\(escape(item.step.text))</div>\
            <div class="meta"><b>\(escape(owner(item)))</b> · \(escape(PlanStepRow.label(item.phase, claudes: item.step.isClaudes)))</div>\(detail)</div>
            </div>
            """
        }.joined(separator: "\n")
        let head = summary.map { s in
            "<div class=\"summary\">\(s.done) of \(s.total) done\(s.next.map { " · Claude next: \(escape($0.step.text))" } ?? "")</div>"
        } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; --fg: #1d1d1f; --dim: #6e6e73; --line: rgba(0,0,0,.08); }
        @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --dim: #98989d; --line: rgba(255,255,255,.12); } }
        body { font-family: -apple-system, sans-serif; color: var(--fg); background: transparent; margin: 0;
               padding: 18px \(margin ? "30%" : "18px") 60px 18px; -webkit-text-size-adjust: 100%; }
        .summary { font-size: 13px; color: var(--dim); margin: 0 0 12px 10px; }
        .step { display: flex; gap: 12px; padding: 12px 10px; border-bottom: 1px solid var(--line); border-radius: 10px; }
        .mark { width: 20px; flex: none; text-align: center; font-size: 17px; line-height: 1.3; color: var(--dim); }
        .label { font-size: 17px; line-height: 1.3; }
        .meta, .detail { font-size: 13px; color: var(--dim); margin-top: 3px; }
        .active .label, .needsYou .label { font-weight: 600; }
        .done .label, .cancelled .label { color: var(--dim); }
        .active .mark, .active .meta b { color: #0a84ff; }
        .needsYou .mark { color: #ff9f0a; } .review .mark { color: #30b0c7; } .done .mark { color: #30d158; } .failed .mark { color: #ff453a; }
        .duet-hot { outline: 2px solid rgba(255,149,0,.9); outline-offset: -2px; }
        .duet-sel { outline: 2px solid rgba(10,132,255,.95); outline-offset: -2px; }
        </style></head><body>
        \(head)
        \(rows)
        </body></html>
        """
    }

    static func glyph(_ p: PlanItem.Phase) -> String {
        switch p {
        case .pending: "○"
        case .active: "◐"
        case .queued: "⧗"
        case .needsYou: "✋"
        case .review: "◎"
        case .done: "✓"
        case .failed: "⚠"
        case .cancelled: "✕"
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

#if os(iOS)
/// The plan on iPad, as a page Apple Pencil writes on, like code and diagrams: a question on a step is answered in its
/// thread (and as a sticky note where you are); anything else (cross it out, "do this first", "use the 27B") redirects
/// Claude on that step. A finger taps a step to open its task.
struct PlanInkSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let conversationId: String
    @State private var page = DiagramPage()
    @State private var ink = InkController()
    @State private var drafts: [DraftNote] = []
    @State private var sent = 0

    var body: some View {
        let store = model.store
        let items = store.planItems(conversationId)
        let html = PlanPageHTML.page(items, summary: store.planSummary(conversationId),
                                     owner: { $0.step.isClaudes ? "Claude" : model.workerName($0.owner) }, margin: DiagramPage.writesInMargin)
        InkSurfaceRepresentable(page: page, document: .html(html), key: "plan-\(conversationId)", isDiff: false, controller: ink,
                                drafts: $drafts, search: "", onSelect: { open($0, in: items) }, onSqueeze: { Task { await send() } })
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .topTrailing) {
                if drafts.contains(where: { !$0.sent }) {
                    InkPanel { NotesTray(drafts: $drafts) { Task { await send() } } }
                }
            }
            .paneActions {
                Button("Pencil Tools", systemImage: "pencil.tip.crop.circle") { ink.toggleTools() }
            }
            .sensoryFeedback(.success, trigger: sent)
            // Written on, its tab stays.
            .onChange(of: drafts.isEmpty) { _, empty in if !empty { model.keepOpen(.plan(conversationId)) } }
            .accessibilityIdentifier("plan-ink-\(conversationId)")
    }

    /// A step tapped: its task, if it's been handed out.
    private func open(_ anchor: InkAnchor?, in items: [PlanItem]) {
        guard let anchor, let task = items.first(where: { $0.step.id == anchor.id })?.task else { return }
        model.openTask(task.taskId, worker: task.worker, compact: density == .compact)
    }

    private func send() async {
        await ink.finishNote()
        let pending = drafts.filter { !$0.sent }
        guard !pending.isEmpty else { ink.toggleTools(); return }
        let image = await ink.snapshot()?.jpegData(compressionQuality: 0.7)?.base64EncodedString()
        model.send(.notes(surface: .plan(conversationId: conversationId), items: await ink.items(pending), image: image, imageType: image == nil ? nil : "image/jpeg"))
        for i in drafts.indices where !drafts[i].sent { drafts[i].sent = true }
        sent += 1
    }
}
#endif
