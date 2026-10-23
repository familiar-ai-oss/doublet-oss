import DuetKit
import MarkdownUI
import SwiftUI

/// One conversation's thread: the live one, or an earlier one read-only. Finished rows come prepared from the store;
/// the reply that is streaming lives in its own view, so only it redraws at 15 Hz. The view stays on the newest
/// output until you scroll away from it. Callers give it `.id(conversationId)` so that resets when switching.
struct LeadThread: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    /// nil: the live conversation.
    var conversationId: String? = nil
    @State private var following = true
    @State private var expanded: Set<String> = []
    @State private var userScrolling = false
    /// The thread's items as last grouped, reused while its rows are the same array (most updates to the store touch
    /// other things: a conversation's last activity, a worker, a side chat).
    @State private var grouped = Grouped()

    var body: some View {
        let isLive = conversationId == nil || conversationId == model.store.currentConversationId
        // Catching up on a long history (at launch): a line saying so, not a thread redrawn as each slice lands.
        if isLive, let c = model.store.catchingUp {
            CatchingUp(progress: c)
        } else {
            thread(isLive: isLive)
        }
    }

    @ViewBuilder
    private func thread(isLive: Bool) -> some View {
        // Filter before the ForEach (a bare `if` in a lazy ForEach defeats SwiftUI's identity fast path).
        let rows = (conversationId.map(model.store.rows(for:)) ?? model.store.leadRows).filter(isVisible)
        // Tool calls side by side read as one line that opens (progressive disclosure, as in Claude Code).
        let items = grouped.items(rows, showResults: density.showsToolResults)
        let working = isLive && model.store.leadStatus.busy ? items.last?.id : nil
        let inset = density == .compact ? 14.0 : 18.0
        // A plain List: lazy like a LazyVStack, but self-sizing and bottom-anchoring stay reliable with very tall rows.
        ScrollViewReader { proxy in
            List {
                // Continued from a session that ran outside Duet: where it came from, and what was said there.
                if let imported = (conversationId ?? model.store.currentConversationId).flatMap({ model.store.conversation($0) })?.imported {
                    ImportedHeader(imported: imported)
                        .listRowInsets(EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                if SpeedSwitches.on("sections") {
                    // In sections of a fixed size: List finds each self-sizing row's separator by walking the rows of
                    // its section, so one long section made every live-reply tick and new row cost O(thread).
                    ForEach(ThreadSection.split(items)) { section in
                        Section {
                            ForEach(section.items) { item in itemRow(item, working: working, inset: inset) }
                        }
                        .listSectionSeparator(.hidden)
                    }
                } else {
                    ForEach(items) { item in itemRow(item, working: working, inset: inset) }
                }
                // What you sent while Claude works, until Claude takes it (then it is a row above, as any message).
                ForEach((conversationId ?? model.store.currentConversationId).flatMap { model.store.conversation($0)?.waiting } ?? [], id: \.id) { q in
                    WaitingPrompt(prompt: q, inset: density == .compact ? 32 : 80)
                        .listRowInsets(EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                if isLive {
                    // It grows the content; the content-size watch below keeps the end in view (once per change).
                    LiveReply()
                        .listRowInsets(EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                Color.clear.frame(height: 8).id(LeadThread.bottomId)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Drag the thread down to put the keyboard away, as in Messages.
            .scrollDismissesKeyboard(.interactively)
            .environment(\.defaultMinListRowHeight, 0)
            .markdownSoftBreakMode(.lineBreak) // Claude's line breaks are meant as line breaks
            // Only your own scrolling decides whether the thread follows: content growing below you (rows measured
            // late, a card taking its tool call's place, a reply streaming) never counts as scrolling away.
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: Bool.self) { g in
                // At the bottom when the last 60 pt of content are visible above the bottom inset (composer, tab bar).
                g.visibleRect.maxY - g.contentInsets.bottom >= g.contentSize.height - 60
            } action: { _, atBottom in
                if userScrolling, following != atBottom { following = atBottom }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
                if following, new != old { proxy.scrollTo(LeadThread.bottomId, anchor: .bottom) }
            }
            // Open on the newest message (List ignores defaultScrollAnchor); coming back to the tab keeps your place.
            .onAppear { if following, !rows.isEmpty { proxy.scrollTo(LeadThread.bottomId, anchor: .bottom) } }
            .onChange(of: FollowKey(count: rows.count, last: rows.last?.id)) {
                if following { proxy.scrollTo(LeadThread.bottomId, anchor: .bottom) }
            }
            // A card you're typing in: once the keyboard is up, show all of it, buttons included.
            .task(id: model.cardInput?.rowId) {
                guard let row = model.cardInput?.rowId else { return }
                try? await Task.sleep(for: .milliseconds(350))
                withAnimation(.snappy) { proxy.scrollTo(row, anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !following {
                    // Says so when what's below is waiting on you.
                    let waiting = isLive && !model.store.openApprovals.isEmpty
                    Button {
                        following = true
                        withAnimation(.snappy) { proxy.scrollTo(LeadThread.bottomId, anchor: .bottom) }
                    } label: {
                        Label(waiting ? "Approval waiting" : "Latest", systemImage: waiting ? "hand.raised.fill" : "arrow.down")
                            .font(.callout.bold())
                    }
                    .buttonStyle(.borderedProminent).tint(waiting ? .stateNeedsYou : .slateHigh).foregroundStyle(waiting ? Color.onNeedsYou : .textPrimary)
                    .clipShape(.capsule).padding()
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy, value: following)
        }
        .accessibilityIdentifier("lead-thread")
    }

    private func itemRow(_ item: ThreadItem, working: String?, inset: CGFloat) -> some View {
        // A launch of Claude's subagents stays one line while they run: it opens only when you open it.
        let busy = working == item.id && !item.isAgents
        // Equatable: a row that reads the same isn't drawn (or its Markdown measured) again.
        return ThreadItemView(item: item, expandedMessages: expanded, working: busy,
                              runOpen: runOpen(item.id, working: busy), openCalls: Bindable(model).openToolCalls) { id in
            following = false // you're reading this message; don't pull you to its end
            expanded.insert(id)
        } toggleRun: {
            toggleRun(item.id, working: busy)
        }
        .equatable()
        .listRowInsets(EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    static let bottomId = "thread-bottom"

    private struct FollowKey: Equatable { let count: Int; let last: String? }

    /// A stretch of the thread's items, named by where it starts, so appending only touches the last one.
    struct ThreadSection: Identifiable {
        static let size = 50
        let id: Int
        let items: ArraySlice<ThreadItem>

        static func split(_ items: [ThreadItem]) -> [ThreadSection] {
            stride(from: 0, to: items.count, by: size).map { ThreadSection(id: $0, items: items[$0..<min($0 + size, items.count)]) }
        }
    }

    /// Memo for the grouping: a class, so the body can update it as it reads.
    private final class Grouped {
        private var rows: [LeadRow] = []
        private var showResults = false
        private var cached: [ThreadItem] = []

        func items(_ rows: [LeadRow], showResults: Bool) -> [ThreadItem] {
            // `==` on arrays sharing storage is immediate.
            if SpeedSwitches.on("rows"), rows == self.rows, showResults == self.showResults { return cached }
            self.rows = rows
            self.showResults = showResults
            cached = ThreadItem.group(rows, showResults: showResults)
            return cached
        }
    }

    // A very long reply shows its first 60 lines until you ask for the rest (see Density.collapseOver). Tool results
    // join their calls (ThreadItem.group).
    private func isVisible(_ row: LeadRow) -> Bool {
        guard case .chunk(_, let msg, let index, let count, _, _) = row else { return true }
        return index == 0 || count <= density.collapseOver || expanded.contains(msg)
    }

    /// A run shows each call when you've opened it, or while Claude is in the middle of it.
    private func runOpen(_ id: String, working: Bool) -> Bool {
        model.openToolRuns.contains(id) || (working && !model.closedToolRuns.contains(id))
    }

    private func toggleRun(_ id: String, working: Bool) {
        withAnimation(.snappy) {
            if runOpen(id, working: working) {
                model.openToolRuns.remove(id)
                model.closedToolRuns.insert(id)
            } else {
                model.closedToolRuns.remove(id)
                model.openToolRuns.insert(id)
            }
        }
    }
}

/// A prompt the hub holds for Claude while it works: your words, dimmed, and that it waits.
private struct WaitingPrompt: View {
    let prompt: QueuedEvent
    let inset: Double

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(prompt.text ?? "").textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.stateNeedsYou.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                .foregroundStyle(.secondary)
            Label("Waiting for Claude…", systemImage: "clock")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, inset)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for Claude: \(prompt.text ?? "")")
    }
}

/// One item of the thread: a row, or a run of tool calls. A single-root container keeps the lazy stack's identity
/// fast path.
private struct ThreadItemView: View, Equatable {
    @Environment(\.density) private var density
    let item: ThreadItem
    let expandedMessages: Set<String>
    let working: Bool
    let runOpen: Bool
    @Binding var openCalls: Set<String>
    let expand: (String) -> Void
    let toggleRun: () -> Void

    var body: some View {
        switch item {
        case .row(let row):
            LeadRowView(row: row, expanded: expandedMessages.contains(Self.messageId(row) ?? ""), expand: expand)
        case .run(let calls):
            ToolRunView(calls: calls, isOpen: runOpen, working: working, toggle: toggleRun, openCalls: $openCalls)
                .padding(.top, density == .dense ? 8 : 12)
        case .agents(let ids):
            AgentLaunchView(taskIds: ids, isOpen: runOpen, toggle: toggleRun)
                .padding(.top, density == .dense ? 8 : 12)
        case .agentResult(_, let taskId):
            AgentLaunchView(taskIds: [taskId], isOpen: false, toggle: {})
                .padding(.top, density == .dense ? 8 : 12)
        }
    }

    private static func messageId(_ row: LeadRow) -> String? {
        if case .chunk(_, let msg, _, _, _, _) = row { return msg }
        return nil
    }

    /// The same when it would show the same: the closures only carry the item's id.
    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated {
            SpeedSwitches.on("rows") && a.item == b.item && a.working == b.working && a.runOpen == b.runOpen
                && a.expanded == b.expanded && a.callsOpen == b.callsOpen
        }
    }

    /// Whether this item's message is expanded, rather than the whole set (one message opening redraws only it).
    private var expanded: Bool { rowOf(item).flatMap(Self.messageId).map(expandedMessages.contains) ?? false }
    /// The open calls of this run only.
    private var callsOpen: Set<String> {
        guard case .run(let calls) = item else { return [] }
        return openCalls.intersection(calls.map(\.id))
    }
    private func rowOf(_ item: ThreadItem) -> LeadRow? { if case .row(let r) = item { r } else { nil } }
}

/// One finished row. A single-root container keeps the lazy stack's identity fast path.
struct LeadRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let row: LeadRow
    let expanded: Bool
    let expand: (String) -> Void

    // Continuation chunks of a message sit flush against the previous chunk.
    private var topPadding: CGFloat {
        if case .chunk(_, _, let index, _, _, _) = row, index > 0 { return 3 } // one line's leading, so the seam doesn't show
        return density == .dense ? 8 : 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch row {
            case .prompt(_, let text, let by, let voice):
                VStack(alignment: .trailing, spacing: 3) {
                    Text(text).textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.slateHigh) }
                    // Spoken: what the recognizer heard, which may not be word for word.
                    Label(by == model.device ? "You" : by, systemImage: "waveform")
                        .labelStyle(SpokenLabelStyle(spoken: voice))
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityLabel(voice ? "Said out loud by \(by == model.device ? "you" : by)" : (by == model.device ? "You" : by))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, density == .compact ? 32 : 80)
            case .chunk(let id, let msg, let index, let count, let lines, let text):
                Markdown(MarkdownCache.content(id, text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if index == 0, count > density.collapseOver, !expanded {
                    Button("Show all \(lines) lines", systemImage: "chevron.down") { expand(msg) }
                        .font(.callout).buttonStyle(.bordered)
                }
                // Under a reply's last part (or its first, while the rest is folded away): copy it, or ask about it.
                if index == count - 1 || (index == 0 && count > density.collapseOver && !expanded) {
                    ReplyActions(message: msg)
                }
            case .tool(_, let name, let summary, _):
                Label {
                    Text("\(LeadStatusName.tool(name))  \(Text(summary).foregroundStyle(.tertiary))")
                        .lineLimit(density == .compact ? 1 : 2)
                } icon: { Image(systemName: "wrench.and.screwdriver") }
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            case .toolResult(_, let preview, let isError):
                Text(preview).font(.caption2.monospaced()).lineLimit(density == .dense ? 6 : 3)
                    .foregroundStyle(isError ? AnyShapeStyle(.stateFailed) : AnyShapeStyle(.tertiary))
                    .padding(.leading, 22)
            case .agent(_, let message):
                AgentLine(message: message)
            case .diagram(_, let diagram):
                // One Claude drew while answering a note stays in that note's thread (and the Diagrams card).
                if diagram.by != "thread" { DiagramCard(diagram: diagram) }
            case .notes(_, let by, let notes):
                NotesBubble(by: by, notes: notes)
            case .approval(_, let id):
                if let req = model.store.approvals[id] {
                    ApprovalCard(approvalId: id, request: req)
                }
            case .note(_, let text):
                Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            case .footer(_, let end):
                HStack(spacing: 6) {
                    Image(systemName: end.interrupted ? "stop.circle" : end.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    Text(end.interrupted ? "Stopped" : end.isError ? end.subtype : "Done")
                    if let ms = end.durationMs { Text("· \(String(format: "%.1f", ms / 1000)) s") }
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.bottom, 6)
            }
        }
        .padding(.top, topPadding)
    }
}

enum LeadStatusName {
    static func tool(_ name: String) -> String {
        name.hasPrefix("mcp__duet__") ? "duet." + name.dropFirst("mcp__duet__".count) : name
    }
}

/// The conversation while a long history comes in at launch.
private struct CatchingUp: View {
    let progress: DuetStore.CatchUp

    var body: some View {
        VStack(spacing: 10) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .frame(maxWidth: 260)
            Text("Catching up on the conversation…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("catching-up")
    }
}

/// A finished reply's parsed Markdown, kept by its row, so a row scrolled back into view (or drawn again) isn't parsed
/// again. The oldest go past the limit.
@MainActor
enum MarkdownCache {
    private static var kept: [String: (text: String, content: MarkdownContent)] = [:]
    private static var order: [String] = []

    static func content(_ id: String, _ text: String) -> MarkdownContent {
        guard SpeedSwitches.on("rows") else { return MarkdownContent(text) }
        if let k = kept[id], k.text == text { return k.content }
        let c = MarkdownContent(text)
        if kept[id] == nil { order.append(id) }
        kept[id] = (text, c)
        if order.count > 1500 { kept[order.removeFirst()] = nil }
        return c
    }
}

/// The reply that is streaming now: plain text in 60-line chunks (only the last chunk changes), published at 15 Hz.
struct LiveReply: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let text = model.store.liveText
        let status = model.store.leadStatus
        VStack(alignment: .leading, spacing: 0) {
            if text.isEmpty, status.busy, status.phase != .approval {
                // Before the first words arrive: say Claude is on it, so a long think doesn't read as nothing happening.
                HStack(spacing: DS.space8) {
                    PulsingSymbol(systemName: status.symbol, tint: status.phase.tint, active: true)
                    Text(status.label + "…").foregroundStyle(.textSecondary)
                }
                .padding(.vertical, DS.space4)
                .accessibilityElement(children: .combine)
            } else if !text.isEmpty {
                ForEach(Array(LeadRow.split(text).enumerated()), id: \.offset) { _, chunk in
                    Text(chunk).frame(maxWidth: .infinity, alignment: .leading)
                }
                ProgressView().controlSize(.small).padding(.top, 6)
            }
        }
    }
}

/// Under each of Claude's replies, as in Claude's apps: copy it, or ask a quick question about it in a side chat.
/// A name, with a waveform before it when the message was spoken.
struct SpokenLabelStyle: LabelStyle {
    let spoken: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            if spoken { configuration.icon }
            configuration.title
        }
    }
}

struct ReplyActions: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        HStack(spacing: 14) {
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(model.store.messageText(message)) }
                .help("Copy this reply")
            ReadAloudButton(id: message) { model.store.messageText(message) }
            Button("Side Chat", systemImage: "bubble.left.and.bubble.right") {
                model.openSideChat(about: .text(label: "Claude's reply", text: model.store.messageText(message)))
            }
            .help("Ask a quick question about this reply, beside the conversation")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}

/// A message between Claude and one of its workers, in Claude's thread: the task it handed out, a question and its
/// answer, a result with what the worker wrote. Tap one to open that task on the worker's screen.
struct AgentLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let message: DialogueEvent

    var body: some View {
        // A question Claude passed on to you is about its task's worker.
        let worker = message.kind == "ESCALATE" ? model.store.tasks[message.taskId]?.worker ?? message.to : message.from == "lead" ? message.to : message.from
        let name = model.workerName(worker)
        let result = message.kind == "RESULT" ? ResultParts(message.text) : nil
        let tint = tint(result)
        // What it changed: nothing to show when nothing changed, or for an Apple worker ("not applicable": it changes no
        // files).
        let changes = result?.changes.flatMap { c in ["no changes", "not a git repository"].contains(c) || c.hasPrefix("not applicable") ? nil : c }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol(result)).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(title(name, result)).font(.subheadline.bold()).foregroundStyle(tint)
                if let result {
                    Text(result.summary).font(.callout).lineLimit(density == .compact ? 4 : 6)
                    if let out = result.output {
                        Markdown(Self.excerpt(out))
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background { RoundedRectangle(cornerRadius: 8).fill(.background.secondary) }
                    }
                    // A tap on what it changed shows the diff, beside the conversation.
                    if let changes {
                        Button { model.openDiff(taskId: message.taskId, worker: worker) } label: {
                            Label {
                                Text(changes).font(.caption.monospaced()).lineLimit(4).multilineTextAlignment(.leading)
                            } icon: {
                                Image(systemName: "plus.forwardslash.minus").font(.caption)
                            }
                        }
                        .buttonStyle(.borderless)
                        .help("Show what \(name) changed, beside the conversation")
                        .accessibilityIdentifier("agent-changes-\(message.taskId)")
                    }
                } else {
                    Text(message.text).font(.callout).lineLimit(message.kind == "TASK" ? (density == .compact ? 3 : 5) : 6)
                }
                if let options = message.options, message.kind == "QUESTION", !options.isEmpty {
                    Text(options.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                if let refused = message.refused { Text(refused).font(.caption).foregroundStyle(.stateFailed) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.08)) }
        .contentShape(Rectangle())
        .onTapGesture { model.openTask(message.taskId, worker: worker, compact: density == .compact) }
        .contextMenu {
            Button("Open Task", systemImage: "arrow.up.right.square") { model.openTask(message.taskId, worker: worker, compact: density == .compact) }
            if changes != nil {
                Button("Show Changes", systemImage: "plus.forwardslash.minus") { model.openDiff(taskId: message.taskId, worker: worker) }
            }
            Button("Ask in a Side Chat", systemImage: "bubble.left.and.bubble.right") {
                model.openSideChat(about: .text(label: "“\(title(name, result))”", text: message.text))
            }
            Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(message.text) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this task on \(name)'s screen")
        .accessibilityActions {
            if changes != nil {
                Button("Show Changes") { model.openDiff(taskId: message.taskId, worker: worker) }
            }
        }
    }

    /// The first 20 lines; the task screen has the rest.
    private static func excerpt(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count > 20 ? lines.prefix(20).joined(separator: "\n") + "\n…" : s
    }

    private func title(_ name: String, _ result: ResultParts?) -> String {
        switch message.kind {
        case "TASK": "Asked \(name)"
        case "STEER": "Told \(name)"
        case "CANCEL": "Cancelled \(name)'s task"
        case "QUESTION": "\(name) asks"
        case "ANSWER": "Answered \(name)"
        case "ESCALATE": "Passed \(name)'s question to you"
        case "STATUS": "\(name) reports"
        case "RESULT": result?.ok == false ? "\(name) failed" : "\(name) finished"
        default: "\(message.kind.capitalized) · \(name)"
        }
    }

    private func symbol(_ result: ResultParts?) -> String {
        switch message.kind {
        case "TASK": "hammer"
        case "STEER": "arrow.triangle.turn.up.right.circle"
        case "CANCEL": "xmark.circle"
        case "QUESTION": "questionmark.bubble"
        case "ANSWER": "arrowshape.turn.up.left"
        case "ESCALATE": "person.fill.questionmark"
        case "RESULT": result?.ok == false ? "exclamationmark.triangle" : "checkmark.seal"
        default: "text.bubble"
        }
    }

    private func tint(_ result: ResultParts?) -> Color {
        switch message.kind {
        case "QUESTION", "ESCALATE": .stateNeedsYou
        case "RESULT": result?.ok == false ? .stateFailed : .stateDone
        case "STATUS", "CANCEL": .secondary
        default: .stateWorking
        }
    }
}
