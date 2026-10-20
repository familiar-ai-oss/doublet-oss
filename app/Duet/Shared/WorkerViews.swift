import DuetKit
import MarkdownUI
import SwiftUI

/// A worker row for lists and the sidebar: status, what it's doing, speed.
struct WorkerRow: View {
    @Environment(AppModel.self) private var model
    let worker: WorkerView
    let activity: String?

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(worker.statusColor).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(worker.shortLabel).lineLimit(1)
                Text([worker.place, model.workerStatus(worker)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                // What it's doing now, or what it finished last.
                if let line = worker.running != nil ? activity : model.workerRecent(worker) {
                    Text(line).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let t = worker.tokPerS, worker.running != nil {
                Text("\(Int(t)) tok/s").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// Everything about one worker: controls, a direct task field, and its task threads (newest first).
struct WorkerDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let workerId: String
    @State private var task = ""

    var body: some View {
        let store = model.store
        if let w = store.workers.first(where: { $0.id == workerId }) {
            // iPhone: the active conversation's tasks unless asked for all (iPad and Mac filter in the inspector instead).
            let scope = density == .compact && !model.workersShowAll ? model.activeConversationId : nil
            let ids = model.taskIds(for: w.id, conversation: scope)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if w.isClaude {
                            SubagentInfo(worker: w)
                        } else {
                            WorkerControls(worker: w)
                            taskField(w)
                        }
                        if ids.isEmpty {
                            if scope != nil, !model.taskIds(for: w.id).isEmpty {
                                Text("No tasks in this conversation.").foregroundStyle(.secondary)
                                Button("Show all tasks") { model.workersShowAll = true }.buttonStyle(.bordered).controlSize(.small)
                            } else {
                                Text(w.isClaude ? "Claude hasn't used this kind of subagent yet." : "No tasks yet.").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(ids, id: \.self) { id in
                            if let t = store.tasks[id] { TaskThreadView(task: t, lines: store.taskLines[id] ?? []).id(id) }
                        }
                    }
                    .padding(density == .compact ? 14 : 20)
                }
                .scrollDismissesKeyboard(.interactively)
                // Opened from one of Claude's messages: go to that task (widening the scope if it's in another conversation).
                .task(id: model.focusTask) {
                    guard let id = model.focusTask else { return }
                    if !ids.contains(id) {
                        guard scope != nil, model.taskIds(for: w.id).contains(id) else { return }
                        model.workersShowAll = true
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                    withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) }
                    model.focusTask = nil
                }
            }
            .navigationTitle(w.shortLabel)
            // Where it runs: the GPU, or for Apple Intelligence, the device (there's one per device).
            .navigationSubtitle(w.place ?? "")
        } else {
            ContentUnavailableView("No such worker", systemImage: "cpu")
        }
    }
}

extension WorkerDetail {
    /// A task straight to this worker, without Claude.
    func taskField(_ w: WorkerView) -> some View {
        HStack(alignment: .bottom) {
            TextField("Give \(w.shortLabel) a task", text: $task, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...6)
            Button("Delegate", systemImage: "hammer.fill") {
                model.send(.delegate(worker: w.id, prompt: task))
                task = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(task.trimmingCharacters(in: .whitespaces).isEmpty || !w.enabled)
        }
    }
}

/// One kind of Claude's own subagents: what it is, and what's different from a local worker.
struct SubagentInfo: View {
    @Environment(AppModel.self) private var model
    let worker: WorkerView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(worker.active?.isEmpty == false ? Color.accentColor : .green).frame(width: 10, height: 10)
                Text(model.workerStatus(worker)).font(.headline)
            }
            LabeledContent("Model") { Text("Claude, on your Max plan").foregroundStyle(.secondary) }
            Text("One of Claude's own subagents. Claude starts these with its Agent tool and gets each one's report when it finishes; what they say and do shows here as they work. They can't ask Claude questions or take messages mid-task, and they stop when Claude's turn does.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }
}

/// Model (with what loading it evicts), effort (only this model's levels), temperature, on/off.
struct WorkerControls: View {
    @Environment(AppModel.self) private var model
    let worker: WorkerView
    @State private var temperature = 0.7

    var body: some View {
        let catalog = model.store.catalog
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(worker.statusColor).frame(width: 10, height: 10)
                Text(worker.statusText).font(.headline)
                Spacer()
                if let t = worker.tokPerS { Label("\(Int(t)) tok/s", systemImage: "speedometer").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Toggle("Enabled", isOn: Binding(get: { worker.enabled }, set: { model.send(.setWorker(worker: worker.id, enabled: $0)) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if worker.isApple {
                AppleWorkerInfo(worker: worker)
            } else {
            LabeledContent("Model") {
                if worker.backend == "llmd" {
                    Menu {
                        ForEach(catalog) { m in
                            Button { model.send(.setWorker(worker: worker.id, model: m.id)) } label: {
                                if m.id == worker.model { Label(m.id, systemImage: "checkmark") }
                                else if m.loaded { Text("\(m.id) · loaded") }
                                else { Text("\(m.id) · evicts \(m.evicts.isEmpty ? "nothing" : m.evicts.joined(separator: ", "))") }
                            }
                        }
                    } label: { Text(worker.model).lineLimit(1) }
                    .fixedSize()
                    .accessibilityIdentifier("model-\(worker.id)")
                } else {
                    Text(worker.model).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            if !worker.loaded, worker.enabled {
                Label("Not loaded: the next task asks before loading it onto the GPU.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                Picker("Effort", selection: Binding(get: { worker.effort }, set: { model.send(.setWorker(worker: worker.id, effort: $0)) })) {
                    ForEach(worker.effortLevels, id: \.self) { Text(effortLabel($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("effort-\(worker.id)")
                if worker.verifiedEffort == false { Text("This model's effort mapping hasn't been measured yet.").font(.caption2).foregroundStyle(.orange) }
            }
            }
            HStack {
                Text("Temperature").font(.callout)
                Slider(value: $temperature, in: 0...1.5, step: 0.05) { editing in
                    if !editing { model.send(.setWorker(worker: worker.id, temperature: .some(temperature))) }
                }
                Text(worker.temperature.map { String(format: "%.2f", $0) } ?? "default").font(.caption.monospacedDigit()).frame(width: 54, alignment: .trailing)
                if worker.temperature != nil {
                    Button("Reset") { model.send(.setWorker(worker: worker.id, temperature: .some(nil))) }.font(.caption).buttonStyle(.borderless)
                }
            }
        }
        .card()
        .onAppear { temperature = worker.temperature ?? 0.7 }
    }
}

/// One task: its prompt, progress, dialogue cards, and the result with the hub-measured diff summary.
struct TaskThreadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let task: TaskEvent
    let lines: [TaskLine]
    @State private var steer = ""
    @State private var showAll = false

    private var active: Bool { ["running", "queued", "awaiting_swap"].contains(task.state) }
    /// On a device's Apple Intelligence, a task reads the files it was given and changes nothing: no folder, diff or steering.
    private var onDevice: Bool { task.isApple }

    var body: some View {
        let shown = showAll || lines.count <= 12 ? lines : Array(lines.suffix(12))
        VStack(alignment: .leading, spacing: 8) {
            // State and buttons on one line where they fit (a worker's screen); the buttons below it in a narrow column.
            ViewThatFits(in: .horizontal) {
                HStack { status; Spacer(); buttons }
                VStack(alignment: .leading, spacing: 6) { status; HStack { buttons } }
            }
            if let p = task.prompt { Text(p).font(.callout).lineLimit(showAll ? nil : 4) }
            if onDevice, let files = task.files, !files.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        Text("Reading").font(.caption).foregroundStyle(.secondary)
                        ForEach(files, id: \.self) { f in
                            Button(Paths.name(f), systemImage: "doc.text") { model.openFile(f, compact: density == .compact) }
                                .buttonStyle(.bordered).controlSize(.small)
                                .accessibilityHint("Opens \(Paths.short(f))")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if lines.count > shown.count {
                Button("Show \(lines.count - shown.count) earlier lines") { showAll = true }.font(.caption).buttonStyle(.borderless)
            }
            ForEach(shown) { line in TaskLineView(line: line) }
            if active, task.state == "running", !onDevice, !task.isClaude {
                HStack {
                    TextField("Steer this task", text: $steer).textFieldStyle(.roundedBorder).font(.callout)
                        .onSubmit(sendSteer)
                    Button("Send", systemImage: "arrow.turn.down.right", action: sendSteer).disabled(steer.isEmpty)
                }
            }
        }
        .card(tint: tint)
    }

    private var status: some View {
        HStack {
            Label(taskStateLabel(task.displayState), systemImage: symbol).font(.subheadline.bold()).foregroundStyle(tint).fixedSize()
            Text(task.taskId).font(.caption.monospaced()).foregroundStyle(.tertiary)
            Text("for \(model.taskOwner(task.by))").font(.caption).foregroundStyle(.secondary)
            if let pos = task.queuePosition, task.state == "queued", pos > 0 { Text("· #\(pos) in queue").font(.caption) }
        }
        .lineLimit(1)
    }

    @ViewBuilder private var buttons: some View {
        if let cwd = task.cwd, !onDevice {
            Button("Files", systemImage: "folder") { model.openFiles(cwd, compact: density == .compact) }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityHint("Shows the folder this task works in")
        }
        if task.showsDiff {
            Button("Diff", systemImage: "plus.forwardslash.minus") { model.openDiff(taskId: task.taskId, worker: task.worker) }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityHint(UIDiffHint.text)
        }
        if active, !task.isClaude {
            Button("Stop", systemImage: "stop.circle") { model.send(.cancelTask(taskId: task.taskId)) }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }

    private func sendSteer() {
        guard !steer.isEmpty else { return }
        model.send(.steer(taskId: task.taskId, text: steer))
        steer = ""
    }

    private var symbol: String {
        switch task.displayState {
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

    private var tint: Color {
        switch task.displayState {
        case "done": .green
        case "stopped", "out_of_room": .orange
        case "failed": .red
        case "awaiting_swap": .orange
        case "running": .accentColor
        default: .secondary
        }
    }
}

struct TaskLineView: View {
    let line: TaskLine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch line {
            case .text(_, let s): Markdown(s).markdownSoftBreakMode(.lineBreak).textSelection(.enabled)
            case .tools(_, let tools):
                ForEach(tools, id: \.self) { Label($0, systemImage: "wrench.and.screwdriver").font(.caption.monospaced()).lineLimit(2).foregroundStyle(.secondary) }
            case .toolResult(_, let s): Text(s).font(.caption2.monospaced()).lineLimit(3).foregroundStyle(.tertiary)
            case .card(_, let c): DialogueLine(card: c)
            case .state(_, let t):
                // The thread already shows the worker's last message, which is the task's result. An Apple worker's
                // messages are its passes over the text, so its answer is shown here.
                if ["done", "failed"].contains(t.state) { ResultCard(task: t, showsResult: t.isApple) }
            }
        }
    }
}

/// TASK · STEER · QUESTION · ANSWER · STATUS · RESULT · CANCEL · ESCALATE, as a compact threaded line.
struct DialogueLine: View {
    @Environment(AppModel.self) private var model
    let card: DialogueEvent

    var body: some View {
        if card.kind == "QUESTION", model.store.attention.contains(where: { $0.id == "q-\(card.id)" }) {
            QuestionCard(question: card)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(card.kind).font(.caption2.bold()).foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background { Capsule().fill(color.opacity(0.14)) }
                Text("\(card.from) → \(card.to)").font(.caption2).foregroundStyle(.secondary)
                if card.kind != "TASK" && card.kind != "RESULT" { Text(card.text).font(.caption).lineLimit(4) }
            }
            if let r = card.refused { Text(r).font(.caption2).foregroundStyle(.red) }
        }
    }

    private var color: Color {
        switch card.kind {
        case "QUESTION", "ESCALATE": .orange
        case "ANSWER": .green
        case "STEER": .purple
        case "CANCEL": .red
        case "RESULT": .teal
        default: .blue
        }
    }
}

/// The worker's summary plus what the hub measured itself (git diff --stat), and the task's numbers.
struct ResultCard: View {
    let task: TaskEvent
    var showsResult = true

    /// "110.7 s · 15 passes · read 47,712 tokens, wrote 916 · 31 tok/s": an Apple task reads much more than it writes.
    private static func passes(_ s: TaskStats) -> String {
        "\(String(format: "%.1f", s.wallMs / 1000)) s · \(s.requests == 1 ? "1 pass" : "\(s.requests) passes") · read \(s.inputTokens.formatted()) tokens, wrote \(s.outputTokens.formatted())"
            + (s.genTokPerS.map { String(format: " · %.0f tok/s", $0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsResult, let r = task.result, !r.isEmpty {
                Text((try? AttributedString(markdown: r, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(r))
                    .font(.callout).textSelection(.enabled)
            }
            if let e = task.error, task.state == "failed" { Text(e).font(.caption).foregroundStyle(.red) }
            switch task.isApple || task.isClaude ? nil : task.evidence {  // Nothing measured: an Apple worker changes no files; a subagent shares Claude's folder.
            case nil: EmptyView()
            case "not a git repository": Label("Not a git repo, so no diff to show", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            case "no changes": Label("No file changes", systemImage: "doc").font(.caption).foregroundStyle(.secondary)
            case let ev?:
                Text(ev).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background { RoundedRectangle(cornerRadius: 8).fill(.background.secondary) }
            }
            if let s = task.stats {
                Text(task.isApple ? Self.passes(s) : "\(String(format: "%.1f", s.wallMs / 1000)) s · \(s.requests) requests · \(s.outputTokens) tokens\(s.genTokPerS.map { String(format: " · %.0f tok/s", $0) } ?? "")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// An Apple worker: which device's on-device model it is, its context and what it can do, or why it can't run.
struct AppleWorkerInfo: View {
    @Environment(AppModel.self) private var model
    let worker: WorkerView

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Model") {
                // "AFM 3 Core · 4,096-token context": the system picks the model for the device.
                Text([worker.variant ?? "On-device", worker.contextSize.map { "\($0.formatted())-token context" }].compactMap(\.self).joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
            if !worker.available {
                Label("Unavailable: \(worker.unavailableReason ?? "not connected").", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(about).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Where it runs and what it's good for. Duet sends it text and nothing else, whatever else the model can do.
    private var about: String {
        let place = worker.device == model.device ? "this device" : "the \(worker.place ?? "other device") while Doublet is open there"
        return "Runs on \(place), free and private: the gist of long text, and extracting from or classifying short text. It can't run tools or read files (the hub sends it the text), and its counts across long text are unreliable."
    }
}

extension View {
    /// Adds a one-line summary of `text` above (or below) this view, made on this device by Apple Intelligence
    /// when the text is long; nothing when that's unavailable.
    func onDeviceSummary(_ text: String?, key: String, edge: VerticalEdge = .top, spacing: CGFloat = 8) -> some View {
        modifier(OnDeviceSummary(key: key, text: text, edge: edge, spacing: spacing))
    }
}

struct OnDeviceSummary: ViewModifier {
    @Environment(AppModel.self) private var model
    let key: String
    let text: String?
    let edge: VerticalEdge
    let spacing: CGFloat
    @State private var line: String?

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            if edge == .bottom { content }
            if let line {
                // The model writes `code` in backticks: shown as code, as in the thread.
                Label {
                    Text((try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line))
                } icon: {
                    Image(systemName: "apple.intelligence")
                }
                .font(.callout.weight(.medium)).lineLimit(2)
                .accessibilityLabel("Summary: \(line)")
            }
            if edge == .top { content }
        }
        // On a view that's always there: a task on the line alone would never start, as there's no line yet.
        // A line made before (on an earlier launch too) shows at once; otherwise it's made now.
        .task(id: key) {
            guard let text else { return }
            if let cached = model.apple.cachedLine(text) { line = cached; return }
            line = await model.apple.oneLine(text)
        }
    }
}
