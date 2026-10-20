import DuetKit
import SwiftUI

/// A tool call in Claude's thread, with its result once it's back.
struct ToolCall: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let edit: FileEdit?
    var result: Result?

    struct Result: Equatable {
        let preview: String
        let isError: Bool
    }

    /// What kind of step it is, for a run's summary.
    enum Kind { case edit, read, command, search, web, other }

    var kind: Kind {
        switch name {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": .edit
        case "Read": .read
        case "Bash": .command
        case "Grep", "Glob": .search
        case "WebFetch", "WebSearch": .web
        default: .other
        }
    }

    /// The call a result row belongs to: "t2-ru9" is the result of "t2-uu9".
    static func callId(ofResult id: String) -> String? {
        guard let r = id.range(of: "-r") else { return nil }
        return id.replacingCharacters(in: r, with: "-u")
    }
}

/// The thread as it's shown: its rows, except that tool calls side by side are one run, which opens to show each call,
/// and Claude's subagents started together are one line.
enum ThreadItem: Identifiable, Equatable {
    case row(LeadRow)
    case run([ToolCall])
    /// Claude's subagents started together (their task ids, in order): one line where Claude started them, which says
    /// how many are running and done. Their reports fold into it.
    case agents([String])
    /// A subagent's report that came after you'd said something since it started: one line where it landed, so a
    /// late finish shows where you are.
    case agentResult(id: String, taskId: String)

    var id: String {
        switch self {
        case .row(let r): r.id
        case .run(let calls): "run-" + calls[0].id
        case .agents(let ids): "agents-" + ids[0]
        case .agentResult(let id, _): id
        }
    }

    var isAgents: Bool { if case .agents = self { true } else { false } }

    /// Rows into items. Each result joins its call in the run. A result whose call isn't there (an approval card took
    /// the call's place) stays a row of its own, shown where results are shown (`showResults`) or when it failed.
    /// Subagent TASK cards side by side are one launch, and each one's RESULT card joins it (`agents`).
    static func group(_ rows: [LeadRow], showResults: Bool) -> [ThreadItem] {
        var items: [ThreadItem] = []
        var run: [ToolCall] = []
        // Where each subagent's launch is, whether the last item can take one more, and where you last said something.
        var launchAt: [String: Int] = [:]
        var launchOpen = false
        var lastSaid = -1
        func endRun() {
            if !run.isEmpty { items.append(.run(run)) }
            run = []
        }
        for row in rows {
            switch row {
            case .tool(let id, let name, let summary, let edit):
                launchOpen = false
                run.append(ToolCall(id: id, name: name, summary: summary, edit: edit))
            case .toolResult(let id, let preview, let isError):
                if let call = ToolCall.callId(ofResult: id), let i = run.lastIndex(where: { $0.id == call }) {
                    run[i].result = ToolCall.Result(preview: preview, isError: isError)
                } else {
                    endRun()
                    launchOpen = false
                    if showResults || isError { items.append(.row(row)) }
                }
            case .agent(_, let d) where d.taskId.hasPrefix("sa-") && d.kind == "TASK":
                endRun()
                if launchOpen, case .agents(let ids) = items.last {
                    items[items.count - 1] = .agents(ids + [d.taskId])
                } else {
                    items.append(.agents([d.taskId]))
                }
                launchAt[d.taskId] = items.count - 1
                launchOpen = true
            case .agent(let id, let d) where d.taskId.hasPrefix("sa-") && d.kind == "RESULT":
                endRun()
                launchOpen = false
                if let at = launchAt[d.taskId] {
                    // Its launch shows it; a line here too only if you've said something since.
                    if lastSaid > at { items.append(.agentResult(id: id, taskId: d.taskId)) }
                } else {
                    // Started before this thread's rows (an older log): its card, as before.
                    items.append(.row(row))
                }
            default:
                endRun()
                launchOpen = false
                if case .prompt = row { lastSaid = items.count }
                if case .notes = row { lastSaid = items.count }
                items.append(.row(row))
            }
        }
        endRun()
        return items
    }
}

/// One of Claude's subagents as the thread shows it: its name, kind and where it is.
struct AgentStatus: Identifiable, Equatable {
    /// `background`: running in the background, until it really ends. `untracked`: an older hub's stand-in, which
    /// stopped following it when it went to the background (older logs).
    enum State: Equatable { case running, background, done, failed, stopped, untracked }

    let id: String
    let worker: String
    let label: String
    let kind: String
    let state: State
    /// The first line of its report, once it's done (or why it failed).
    let report: String?

    @MainActor
    init(taskId: String, store: DuetStore) {
        let task = store.tasks[taskId]
        id = taskId
        worker = task?.worker ?? "claude-agent"
        label = store.agentLabels[taskId] ?? task?.label ?? task?.prompt.flatMap { $0.split(separator: "\n").first.map(String.init) } ?? "Subagent"
        // "claude-general-purpose" reads "General-purpose".
        let k = worker.hasPrefix("claude-") ? String(worker.dropFirst("claude-".count)) : worker
        kind = k.prefix(1).uppercased() + k.dropFirst()
        let state: State
        switch task?.state {
        case "done": state = task?.backgroundUntracked == true ? .untracked : .done
        case "failed": state = .failed
        case "cancelled": state = .stopped
        default: state = task?.inBackground == true ? .background : .running
        }
        self.state = state
        report = state == .done || state == .failed
            ? task?.result.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: true).first.map { String($0.prefix(160)) } }
            : nil
    }

    var words: String {
        switch state {
        case .running: "running"
        case .background: "running in the background"
        case .done: "done"
        case .failed: "failed"
        case .stopped: "stopped"
        case .untracked: "in the background · not tracked yet"
        }
    }

    /// Still at work: running, in the background or not.
    var isRunning: Bool { state == .running || state == .background }

    var symbol: String {
        switch state {
        case .running, .background: "circle.lefthalf.filled"
        case .done: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .stopped: "stop.circle"
        case .untracked: "circle.dotted"
        }
    }

    var tint: Color {
        switch state {
        case .failed: .orange
        case .running, .background: .accentColor
        default: .secondary
        }
    }

    /// A launch in a line: "4 agents · 1 running · 1 in the background · 1 done · 1 failed".
    static func summary(_ agents: [AgentStatus]) -> String {
        func count(_ s: State) -> Int { agents.filter { $0.state == s }.count }
        if count(.untracked) == agents.count { return "\(agents.count) agents in the background · not tracked yet" }
        if count(.background) == agents.count { return "\(agents.count) agents running in the background" }
        var parts = ["\(agents.count) agents"]
        if count(.running) > 0 { parts.append("\(count(.running)) running") }
        if count(.background) > 0 { parts.append("\(count(.background)) in the background") }
        if count(.done) > 0 { parts.append("\(count(.done)) done") }
        if count(.failed) > 0 { parts.append("\(count(.failed)) failed") }
        if count(.stopped) > 0 { parts.append("\(count(.stopped)) stopped") }
        if count(.untracked) > 0 { parts.append("\(count(.untracked)) in the background") }
        return parts.joined(separator: " · ")
    }
}

/// Claude's subagents started together, as one line where Claude started them: "4 agents · 2 running · 2 done". It
/// opens to one line per agent, by the name Claude gave it. It changes only when an agent starts or ends (what each is
/// doing stays on its task's screen), and a launch of one is that agent's line, which opens its task.
struct AgentLaunchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let taskIds: [String]
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        let agents = taskIds.map { AgentStatus(taskId: $0, store: model.store) }
        if agents.count == 1 {
            AgentStatusRow(agent: agents[0])
        } else {
            VStack(alignment: .leading, spacing: density == .dense ? 4 : 6) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.bold())
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 16)
                        Image(systemName: Self.symbol(agents)).foregroundStyle(Self.tint(agents))
                        Text(AgentStatus.summary(agents)).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(density == .dense ? .callout : .subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(AgentStatus.summary(agents))
                .accessibilityValue(isOpen ? "Showing each agent" : "")
                .accessibilityHint(isOpen ? "Hides the agents" : "Shows each agent")
                .accessibilityIdentifier("agent-launch")
                if isOpen {
                    ForEach(agents) { AgentStatusRow(agent: $0) }
                        .padding(.leading, 22)
                }
            }
            .animation(.snappy, value: isOpen)
        }
    }

    private static func symbol(_ agents: [AgentStatus]) -> String {
        if agents.contains(where: \.isRunning) { return "circle.lefthalf.filled" }
        if agents.contains(where: { $0.state == .failed }) { return "exclamationmark.triangle" }
        if agents.allSatisfy({ $0.state == .untracked }) { return "circle.dotted" }
        return "checkmark.circle"
    }

    private static func tint(_ agents: [AgentStatus]) -> Color {
        if agents.contains(where: { $0.state == .failed }) { return .orange }
        if agents.contains(where: \.isRunning) { return .accentColor }
        return .secondary
    }
}

/// One subagent: "Map the lexer's states · Explore · done", then the first line of its report. A tap opens its task.
struct AgentStatusRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let agent: AgentStatus

    var body: some View {
        Button { model.openTask(agent.id, worker: agent.worker, compact: density == .compact) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: agent.symbol).foregroundStyle(agent.tint).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Text(agent.label).foregroundStyle(agent.state == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))) \(Text("· \(agent.kind) · \(agent.words)").foregroundStyle(.secondary))")
                        .lineLimit(density == .compact ? 2 : 1)
                    if let report = agent.report {
                        Text(report).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(density == .dense ? .callout : .subheadline)
        .contextMenu {
            Button("Open Task", systemImage: "arrow.up.right.square") { model.openTask(agent.id, worker: agent.worker, compact: density == .compact) }
            if let report = agent.report { Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(report) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens what this agent did")
        .accessibilityIdentifier("agent-\(agent.id)")
    }
}

/// A run of Claude's tool calls: one line that says what they did ("Edited Lexer.swift, read 2 files"), which opens to
/// each call. An edit opens to its diff, and a line of the diff opens the file there. A run of one call is that call.
struct ToolRunView: View {
    @Environment(\.density) private var density
    let calls: [ToolCall]
    /// Showing each call.
    let isOpen: Bool
    /// The run Claude is in the middle of.
    let working: Bool
    let toggle: () -> Void
    /// The calls showing their diff or result.
    @Binding var openCalls: Set<String>

    var body: some View {
        if calls.count == 1 {
            ToolCallRow(call: calls[0], isOpen: openCalls.contains(calls[0].id)) { toggleCall(calls[0].id) }
        } else {
            VStack(alignment: .leading, spacing: density == .dense ? 4 : 6) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.bold())
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: 16)
                        Text(Self.summary(calls)).lineLimit(1)
                        EditCounts(added: calls.compactMap(\.edit).map(\.added).reduce(0, +),
                                   removed: calls.compactMap(\.edit).map(\.removed).reduce(0, +))
                        if working { ProgressView().controlSize(.mini) }
                        if calls.contains(where: { $0.result?.isError == true }) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(density == .dense ? .callout : .subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Self.summary(calls))
                .accessibilityValue(isOpen ? "Showing each step" : "")
                .accessibilityHint(isOpen ? "Hides the steps" : "Shows each step")
                if isOpen {
                    ForEach(calls) { call in
                        ToolCallRow(call: call, isOpen: openCalls.contains(call.id)) { toggleCall(call.id) }
                    }
                    .padding(.leading, 22)
                }
            }
            .animation(.snappy, value: isOpen)
        }
    }

    private func toggleCall(_ id: String) {
        withAnimation(.snappy) {
            if openCalls.contains(id) { openCalls.remove(id) } else { openCalls.insert(id) }
        }
    }

    /// What a run did, in a line: "Edited Lexer.swift, read 2 files, ran a command".
    static func summary(_ calls: [ToolCall]) -> String {
        let kinds = Dictionary(grouping: calls, by: \.kind)
        func files(_ k: ToolCall.Kind) -> Set<String> { Set((kinds[k] ?? []).map(\.summary)) }
        func count(_ k: ToolCall.Kind) -> Int { kinds[k]?.count ?? 0 }
        var parts: [String] = []
        let edited = files(.edit), read = files(.read)
        if !edited.isEmpty { parts.append(edited.count == 1 ? "edited \(Paths.name(edited.first!))" : "edited \(edited.count) files") }
        if !read.isEmpty { parts.append(read.count == 1 ? "read \(Paths.name(read.first!))" : "read \(read.count) files") }
        if count(.command) > 0 { parts.append(count(.command) == 1 ? "ran a command" : "ran \(count(.command)) commands") }
        if count(.search) > 0 { parts.append(count(.search) == 1 ? "searched once" : "searched \(count(.search)) times") }
        if count(.web) > 0 { parts.append(count(.web) == 1 ? "looked on the web" : "looked on the web \(count(.web)) times") }
        if count(.other) > 0 { parts.append(count(.other) == 1 ? "1 more step" : "\(count(.other)) more steps") }
        let line = parts.joined(separator: ", ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}

/// One tool call: what it did, to what ("Edited Lexer.swift +4 −1"). An edit opens to its diff; a file read opens
/// the file; anything else opens to its result.
struct ToolCallRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let call: ToolCall
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        let failed = call.result?.isError == true
        VStack(alignment: .leading, spacing: 6) {
            Button(action: primary) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: failed ? "exclamationmark.triangle" : symbol)
                        .foregroundStyle(failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                    Text("\(Text(verb).foregroundStyle(.secondary)) \(Text(target).foregroundStyle(.primary))")
                        .lineLimit(density == .compact ? 1 : 2)
                        .truncationMode(.middle)
                    if let edit = call.edit { EditCounts(added: edit.added, removed: edit.removed) }
                    if navigates {
                        Image(systemName: "arrow.up.forward").font(.caption2.bold()).foregroundStyle(.tertiary)
                    } else if opens {
                        Image(systemName: "chevron.right")
                            .font(.caption2.bold()).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!opens && !navigates)
            .font(density == .dense ? .callout : .subheadline)
            .help(help)
            if call.name == "Workflow" {
                Text("Its agents aren't shown in Doublet yet").font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
            }
            // A command's long output, in one line: what failed and where, or that it passed.
            if call.kind == .command, let result = call.result {
                OutputLine(output: result.preview, isError: result.isError).padding(.leading, 22)
            }
            if isOpen {
                if let edit = call.edit {
                    EditDiffView(edit: edit)
                } else if let result = call.result {
                    Text(result.preview).font(.caption.monospaced()).lineLimit(density == .dense ? 12 : 6)
                        .foregroundStyle(result.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                        .padding(.leading, 22)
                }
            }
        }
    }

    /// Something to show under it: the diff, or the result.
    private var opens: Bool { call.edit != nil || call.result != nil }
    /// A file read: it opens the file.
    private var navigates: Bool { call.edit == nil && call.kind == .read }

    private func primary() {
        if navigates { model.openFile(call.summary, compact: density == .compact) } else { toggle() }
    }

    private var help: String {
        if call.edit != nil { return isOpen ? "Hide the change" : "Show the change" }
        if navigates { return "Open \(Paths.name(call.summary))" }
        return isOpen ? "Hide the result" : "Show the result"
    }

    private var verb: String {
        switch call.name {
        case "Edit", "MultiEdit", "NotebookEdit": "Edited"
        case "Write": "Wrote"
        case "Read": "Read"
        case "Bash": "Ran"
        case "Grep": "Searched for"
        case "Glob": "Looked for"
        case "WebFetch": "Read"
        case "WebSearch": "Searched the web for"
        case "Agent", "Task": "Started"
        case "Workflow": "Started workflow"
        default: LeadStatusName.tool(call.name)
        }
    }

    private var target: String {
        switch call.name {
        case "Edit", "MultiEdit", "NotebookEdit", "Write", "Read": Paths.name(call.summary)
        default: call.summary
        }
    }

    private var symbol: String {
        switch call.name {
        case "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Write": "doc.badge.plus"
        case "Read": FileIcon.symbol(name: Paths.name(call.summary))
        case "Bash": "terminal"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Agent", "Task": "person.2"
        case "Workflow": "arrow.triangle.branch"
        default: "wrench.and.screwdriver"
        }
    }
}

/// Lines added and removed: "+4 −1", in green and red.
struct EditCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        if added > 0 || removed > 0 {
            HStack(spacing: 4) {
                if added > 0 { Text("+\(added)").foregroundStyle(.green) }
                if removed > 0 { Text("−\(removed)").foregroundStyle(.red) }
            }
            .font(.caption.monospacedDigit().bold())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(added) lines added, \(removed) removed")
        }
    }
}

/// An edit's diff, line by line. Click a line to open the file there, where that line is now.
struct EditDiffView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let edit: FileEdit
    @State private var showAll = false

    /// Long diffs (a whole file written) show their start until you ask for the rest.
    private static let shortLength = 40

    /// Each change's lines, as many as are shown.
    private func shown(_ changes: [[DiffLine]]) -> [(change: Int, lines: [DiffLine])] {
        var left = showAll ? Int.max : Self.shortLength
        return changes.enumerated().map { c, lines in
            let some = Array(lines.prefix(max(0, left)))
            left -= some.count
            return (c, some)
        }
    }

    var body: some View {
        let changes = edit.changes.map(\.lines)
        let total = changes.map(\.count).reduce(0, +)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown(changes), id: \.change) { c, lines in
                if c > 0, !lines.isEmpty { Divider().padding(.vertical, 2) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Button { model.openEdit(edit, change: c, at: line.newIndex, compact: density == .compact) } label: {
                        DiffLineView(line: line)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(Paths.name(edit.path)) here")
                }
            }
            HStack {
                if total > Self.shortLength {
                    Button(showAll ? "Show Less" : "Show All \(total) Lines") { withAnimation(.snappy) { showAll.toggle() } }
                }
                Spacer()
                Button("Open \(Paths.name(edit.path))", systemImage: "arrow.up.forward.square") {
                    model.openEdit(edit, change: 0, at: 0, compact: density == .compact)
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .background { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.secondary) }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.leading, 22)
    }
}

/// One line of a diff: + or − in the margin, and the line on green or red.
struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mark).foregroundStyle(tint).frame(width: 10)
            Text(line.text.isEmpty ? " " : line.text)
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(line.kind == .kept ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Spacer(minLength: 0)
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 8).padding(.vertical, 1)
        .background(tint.opacity(line.kind == .kept ? 0 : 0.12))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.kind == .added ? "Added" : line.kind == .removed ? "Removed" : "Unchanged"): \(line.text)")
    }

    private var mark: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .kept: " "
        }
    }

    private var tint: Color {
        switch line.kind {
        case .added: .green
        case .removed: .red
        case .kept: .clear
        }
    }
}

/// A command's output in one line, under its row. Read straight from the output when it's a test run, a type check or
/// a build (no model); otherwise, for long output, written by Apple Intelligence on this device and labelled so.
/// Never sent to Claude: Claude reads the output itself.
struct OutputLine: View {
    @Environment(AppModel.self) private var model
    let output: String
    let isError: Bool
    @State private var line: (text: String, onDevice: Bool)?

    var body: some View {
        Group {
            if let line {
                Label {
                    Text(line.text).lineLimit(2)
                } icon: {
                    Image(systemName: line.onDevice ? "apple.intelligence" : failed(line.text) ? "xmark.circle" : "checkmark.circle")
                        .foregroundStyle(line.onDevice ? AnyShapeStyle(.secondary) : failed(line.text) ? AnyShapeStyle(.orange) : AnyShapeStyle(.green))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(line.onDevice ? "Summarized on this device by Apple Intelligence" : "Read from the output")
                .accessibilityLabel(line.onDevice ? "Summary: \(line.text)" : line.text)
            }
        }
        .task(id: output) {
            // Short output is its own summary.
            guard output.count > 400 || output.split(separator: "\n").count > 6 || ToolOutput.verdict(output) != nil else { return }
            if let r = await model.apple.toolLine(output) { line = (r.line, r.onDevice) }
        }
    }

    private func failed(_ s: String) -> Bool { isError || s.range(of: #"(?i)\bfail|error"#, options: .regularExpression) != nil }
}
