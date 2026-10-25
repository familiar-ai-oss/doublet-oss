import DuetKit
import MarkdownUI
import SwiftUI

/// Any item that needs you, rendered as its decision card.
struct AttentionCard: View {
    let item: AttentionItem

    var body: some View {
        VStack {
            switch item {
            case .approval(let a): ApprovalCard(approvalId: a.id, request: a)
            case .question(let q): QuestionCard(question: q)
            case .swap(let s): SwapCard(swap: s)
            }
        }
    }
}

/// Approve · Edit · Reject (with an optional note). Editing and the note open inside the card, so the conversation
/// stays in view and nothing modal slides over it. Once decided the card shrinks to one row saying what ran and who
/// decided. An ask Claude Code marks risky (`needsCare`) has no one-tap approve: Approve asks again, Reject comes first.
struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let approvalId: String
    let request: ApprovalRequestEvent
    @State private var mode = Mode.deciding
    @State private var note = ""
    @State private var draft = ""
    @State private var draftError: String?
    @State private var confirmingApprove = false
    @FocusState private var fieldFocused: Bool

    private enum Mode { case deciding, editing, noting }

    private var command: String? { request.input["command"]?.stringValue }
    /// Claude asking to leave plan mode (ExitPlanMode): its plan, in Markdown, to approve, edit, or send back.
    private var plan: String? { request.plan ?? (request.tool == "ExitPlanMode" ? request.input["plan"]?.stringValue : nil) }

    var body: some View {
        if let r = model.store.resolvedApprovals[approvalId] {
            ResolvedApprovalRow(request: request, resolution: r)
        } else if let questions = AskedQuestion.parse(request) {
            AskedQuestionsCard(approvalId: approvalId, request: request, questions: questions)
        } else {
            pending
        }
    }

    private var pending: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(plan != nil ? "Claude's plan is ready" : request.title ?? "Claude wants to run \(request.displayName ?? request.tool)",
                      systemImage: plan != nil ? "list.bullet.clipboard" : "hand.raised.fill")
                    .font(density == .compact ? .headline : .subheadline.bold())
                    .foregroundStyle(.stateNeedsYou)
                Spacer()
                if request.title != nil { Text(request.tool).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }
            if mode == .editing {
                editor
            } else if let plan {
                // The plan to read before it starts: it scrolls in the card.
                ScrollView {
                    Markdown(plan).markdownSoftBreakMode(.lineBreak).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: density == .compact ? 300 : 420)
                .padding(10)
                .background { RoundedRectangle(cornerRadius: 8).fill(.background.secondary) }
            } else {
                Text(command ?? JSONValue.object(request.input).compact)
                    .font(.callout.monospaced())
                    .lineLimit(density.codeLines)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { RoundedRectangle(cornerRadius: 8).fill(.background.secondary) }
            }
            if request.needsCare {
                Label("Check this one closely before approving.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold()).foregroundStyle(.stateFailed)
            }
            if let d = request.description, density != .compact, mode != .editing { Text(d).font(.caption).foregroundStyle(.secondary) }
            // The note to Claude: always there on iPad and Mac; on iPhone once you ask for it.
            if mode == .noting || (mode == .deciding && density != .compact) {
                TextField(plan != nil ? "What to change, to keep planning (optional)"
                          : density == .compact ? "Why, or what to do instead" : "Note to Claude if you reject (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder).font(density == .compact ? .callout : .caption)
                    .focused($fieldFocused)
                    .accessibilityIdentifier("reject-note-\(approvalId)")
            }
            buttons
        }
        .card(tint: request.needsCare ? .stateFailed : .stateNeedsYou)
        .confirmationDialog("Approve this?", isPresented: $confirmingApprove, titleVisibility: .visible) {
            Button("Approve") { model.send(.approve(id: approvalId)) }
        } message: {
            Text(command ?? request.tool)
        }
        .onChange(of: mode) { _, m in
            fieldFocused = m != .deciding
            if m == .deciding {
                if model.cardInput?.approvalId == approvalId { model.cardInput = nil }
            } else {
                model.cardInput = CardInput(approvalId: approvalId, rowId: "t\(request.turn)-a\(approvalId)")
            }
        }
        .onDisappear { if model.cardInput?.approvalId == approvalId { model.cardInput = nil } }
    }

    /// The call as editable text: the command for a shell call, the JSON input for anything else.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if command != nil {
                    TextField("Command", text: $draft, axis: .vertical).lineLimit(1...12)
                } else {
                    TextEditor(text: $draft).frame(minHeight: 120, maxHeight: 280).scrollContentBackground(.hidden)
                }
            }
            .font(.callout.monospaced())
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .focused($fieldFocused)
            .padding(8)
            .background { RoundedRectangle(cornerRadius: 8).fill(.background.secondary) }
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.stateNeedsYou.opacity(0.6)) }
            .accessibilityIdentifier("edit-field-\(approvalId)")
            Text(draftError ?? (plan != nil ? "Claude works from the plan as you've edited it." : "Claude runs exactly this instead, and is told you edited it."))
                .font(.caption).foregroundStyle(draftError == nil ? Color.secondary : Color.stateFailed)
        }
    }

    @ViewBuilder private var buttons: some View {
        let compact = density == .compact
        switch mode {
        case .editing:
            HStack(spacing: 8) {
                Button { allowEdited() } label: {
                    Label(plan != nil ? "Approve Edited Plan" : "Allow Edited", systemImage: "checkmark").frame(maxWidth: compact ? .infinity : nil)
                }
                .needsYouProminent()
                .accessibilityIdentifier("edit-save-\(approvalId)")
                cancelButton
            }
            .controlSize(compact ? .large : .regular)
            .labelStyle(.titleAndIcon).lineLimit(1)
        case .noting:
            HStack(spacing: 8) {
                Button(role: .destructive) { reject() } label: {
                    Label("Reject", systemImage: "xmark").frame(maxWidth: compact ? .infinity : nil)
                }
                .failedProminent()
                .accessibilityIdentifier("reject-with-note-\(approvalId)")
                cancelButton
            }
            .controlSize(compact ? .large : .regular)
            .labelStyle(.titleAndIcon).lineLimit(1)
        case .deciding where compact && request.needsCare:
            // Risky: Reject is the big one; Approve asks again.
            VStack(spacing: 8) {
                rejectButton(wide: true).failedProminent()
                HStack(spacing: 8) {
                    editButton(wide: true)
                    approveButton(wide: true)
                    noteButton
                }
            }
            .controlSize(.large)
            .labelStyle(.titleAndIcon).lineLimit(1)
        case .deciding where compact:
            // iPhone: a full-width Approve under the thumb, then Edit, Reject, and Reject with a note.
            VStack(spacing: 8) {
                approveButton(wide: true)
                HStack(spacing: 8) {
                    editButton(wide: true)
                    rejectButton(wide: true)
                    noteButton
                }
            }
            .controlSize(.large)
            .labelStyle(.titleAndIcon).lineLimit(1)
        case .deciding where request.needsCare:
            HStack(spacing: 8) {
                rejectButton(wide: false)
                editButton(wide: false)
                approveButton(wide: false)
            }
            .labelStyle(.titleAndIcon).lineLimit(1)
        case .deciding:
            HStack(spacing: 8) {
                approveButton(wide: false)
                editButton(wide: false)
                rejectButton(wide: false)
            }
            .labelStyle(.titleAndIcon).lineLimit(1)
        }
    }

    @ViewBuilder private func approveButton(wide: Bool) -> some View {
        let label = Label(plan != nil ? "Approve Plan" : "Approve", systemImage: "checkmark").frame(maxWidth: wide ? .infinity : nil)
        if request.needsCare {
            Button { confirmingApprove = true } label: { label }
                .buttonStyle(.bordered).tint(.stateNeedsYou)
                .accessibilityIdentifier("approve-\(approvalId)")
        } else {
            Button { model.send(.approve(id: approvalId)) } label: { label }
                .needsYouProminent()
                .accessibilityIdentifier("approve-\(approvalId)")
        }
    }

    private func editButton(wide: Bool) -> some View {
        Button { startEditing() } label: {
            Label("Edit", systemImage: "pencil").frame(maxWidth: wide ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("edit-\(approvalId)")
    }

    private func rejectButton(wide: Bool) -> some View {
        Button(role: .destructive) { reject() } label: {
            Label(plan != nil ? "Keep Planning" : "Reject", systemImage: plan != nil ? "arrow.uturn.backward" : "xmark").frame(maxWidth: wide ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("reject-\(approvalId)")
    }

    private var noteButton: some View {
        Button { mode = .noting } label: { Image(systemName: "text.bubble") }
            .buttonStyle(.bordered)
            .accessibilityLabel("Reject with a note")
            .accessibilityIdentifier("reject-note-button-\(approvalId)")
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel) {
            mode = .deciding
            draftError = nil
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(.cancelAction)
    }

    private func startEditing() {
        if let plan {
            draft = plan
        } else if let command {
            draft = command
        } else {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            draft = (try? enc.encode(JSONValue.object(request.input))).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        }
        draftError = nil
        mode = .editing
    }

    private func allowEdited() {
        var input = request.input
        if plan != nil {
            input["plan"] = .string(draft)
        } else if command != nil {
            input["command"] = .string(draft)
        } else {
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(draft.utf8)), case .object(let o) = v else {
                draftError = "That isn't a JSON object."
                return
            }
            input = o
        }
        model.send(.approve(id: approvalId, updatedInput: input))
    }

    private func reject() {
        model.send(.reject(id: approvalId, message: note.isEmpty ? nil : note))
        note = ""
    }
}

/// Claude's questions to you (AskUserQuestion, which plan mode has it use): each with its options, one or several to
/// pick. The answers go back as the call's `answers` (question → what you chose).
struct AskedQuestion: Identifiable {
    struct Option: Identifiable {
        let label: String
        let detail: String?
        var id: String { label }
    }

    let text: String
    let header: String?
    let options: [Option]
    let multiple: Bool
    var id: String { text }

    static func parse(_ r: ApprovalRequestEvent) -> [AskedQuestion]? {
        guard r.tool == "AskUserQuestion", case .array(let list)? = r.input["questions"] else { return nil }
        let questions: [AskedQuestion] = list.compactMap { q in
            guard case .object(let o) = q, let text = o["question"]?.stringValue else { return nil }
            var options: [Option] = []
            if case .array(let opts)? = o["options"] {
                for opt in opts {
                    if case .object(let oo) = opt, let label = oo["label"]?.stringValue { options.append(Option(label: label, detail: oo["description"]?.stringValue)) }
                }
            }
            var multiple = false
            if case .bool(let b)? = o["multiSelect"] { multiple = b }
            return AskedQuestion(text: text, header: o["header"]?.stringValue, options: options, multiple: multiple)
        }
        return questions.isEmpty ? nil : questions
    }
}

/// Claude asking you before it goes on (AskUserQuestion): each question with its options to pick, and room for your
/// own answer. Send Answers gives them to Claude; Let Claude Decide tells it to choose and say what it chose.
struct AskedQuestionsCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let approvalId: String
    let request: ApprovalRequestEvent
    let questions: [AskedQuestion]
    @State private var picked: [String: Set<String>] = [:]
    @State private var own: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(questions.count == 1 ? "Claude has a question" : "Claude has \(questions.count) questions", systemImage: "questionmark.bubble.fill")
                .font(density == .compact ? .headline : .subheadline.bold())
                .foregroundStyle(.stateNeedsYou)
            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 8) {
                    if let header = q.header { Text(header.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary) }
                    Text(q.text).font(.callout.weight(.semibold))
                    ForEach(q.options) { option in
                        let on = picked[q.text, default: []].contains(option.label)
                        Button { toggle(q, option.label) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: on ? (q.multiple ? "checkmark.square.fill" : "largecircle.fill.circle") : (q.multiple ? "square" : "circle"))
                                    .foregroundStyle(on ? Color.stateNeedsYou : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                    if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                    TextField("Or your own answer", text: Binding(get: { own[q.text, default: ""] }, set: { own[q.text] = $0 }), axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                }
            }
            HStack(spacing: 8) {
                Button { sendAnswers() } label: { Label("Send Answers", systemImage: "paperplane.fill") }
                    .needsYouProminent()
                    .disabled(!questions.allSatisfy { answer($0) != nil })
                    .accessibilityIdentifier("answer-\(approvalId)")
                Button { model.send(.reject(id: approvalId, message: "Decide for yourself, and say what you chose.")) } label: {
                    Label("Let Claude Decide", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
            }
            .labelStyle(.titleAndIcon).lineLimit(1)
        }
        .card(tint: .stateNeedsYou)
    }

    /// The answer to one question: your own words, else what you picked.
    private func answer(_ q: AskedQuestion) -> String? {
        let typed = own[q.text, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let chosen = q.options.map(\.label).filter { picked[q.text, default: []].contains($0) }
        return chosen.isEmpty ? nil : chosen.joined(separator: ", ")
    }

    private func toggle(_ q: AskedQuestion, _ label: String) {
        var set = picked[q.text, default: []]
        if q.multiple {
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
        } else {
            set = [label]
        }
        picked[q.text] = set
    }

    private func sendAnswers() {
        var input = request.input
        var answers: [String: JSONValue] = [:]
        for q in questions { if let a = answer(q) { answers[q.text] = .string(a) } }
        input["answers"] = .object(answers)
        model.send(.approve(id: approvalId, updatedInput: input))
    }
}

/// A decided approval as one row: what ran (an edited call shows its new command over the struck original),
/// or what was refused, then who decided and their note.
struct ResolvedApprovalRow: View {
    @Environment(\.density) private var density
    let request: ApprovalRequestEvent
    let resolution: ApprovalResolvedEvent

    var body: some View {
        let allowed = resolution.decision == "allow"
        let asked = ToolSummary.text(request.tool, request.input)
        let ran = resolution.updatedInput.map { ToolSummary.text(request.tool, $0) }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(LeadStatusName.tool(request.tool))  \(Text(ran ?? asked).foregroundStyle(allowed ? .primary : .secondary))")
                    .font(.caption.monospaced())
                    .lineLimit(density == .compact ? 2 : 4)
                if ran != nil {
                    Text(asked).strikethrough().font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2)
                }
                Text(verdict).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        resolution.decision != "allow" ? "xmark.circle.fill" : resolution.edited ? "pencil.circle.fill" : "checkmark.circle.fill"
    }

    private var tint: Color {
        resolution.decision != "allow" ? .stateFailed : resolution.edited ? .stateWorking : .stateDone
    }

    private var verdict: String {
        let who = resolution.by
        if resolution.decision == "allow" { return resolution.edited ? "Edited and approved by \(who)" : "Approved by \(who)" }
        if who == "abort" { return "Cancelled" }
        if resolution.message == "interrupted" { return "Stopped by \(who)" }
        return "Rejected by \(who)" + (resolution.message.map { ": \($0)" } ?? "")
    }
}

/// A worker asking whoever gave it the task. Options are one tap; anything else is typed.
struct QuestionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let question: DialogueEvent
    @State private var answer = ""

    var body: some View {
        let open = model.store.attention.contains { $0.id == "q-\(question.id)" }
        VStack(alignment: .leading, spacing: 10) {
            Label("\(question.from) asks", systemImage: "questionmark.bubble.fill")
                .font(density == .compact ? .headline : .subheadline.bold()).foregroundStyle(.stateNeedsYou)
            Text(question.text).font(.callout).textSelection(.enabled)
            if open {
                if let opts = question.options, !opts.isEmpty {
                    FlowButtons(options: opts) { model.send(.answer(questionId: question.id, text: $0)) }
                }
                HStack {
                    TextField("Answer", text: $answer, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                        .sendsOnReturn($answer, send: send)
                    Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                        .labelStyle(.iconOnly).font(.title2).disabled(answer.isEmpty)
                }
            } else {
                Text("Answered").font(.caption).foregroundStyle(.secondary)
            }
        }
        .card(tint: .stateNeedsYou)
    }

    private func send() {
        guard !answer.isEmpty else { return }
        model.send(.answer(questionId: question.id, text: answer))
        answer = ""
    }
}

/// A row of option buttons that wraps.
struct FlowButtons: View {
    let options: [String]
    let action: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { ForEach(options, id: \.self) { o in Button(o) { action(o) }.buttonStyle(.bordered) } }
            VStack(alignment: .leading) { ForEach(options, id: \.self) { o in Button(o) { action(o) }.buttonStyle(.bordered) } }
        }
    }
}

/// Loading a model evicts what's on that GPU, so it always asks, and says what goes.
struct SwapCard: View {
    @Environment(AppModel.self) private var model
    let swap: SwapRequestEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(swap.worker) needs \(swap.model)", systemImage: "memorychip").font(.headline).foregroundStyle(.stateNeedsYou)
            Text(swap.evicts.isEmpty ? "Loads on \(swap.device); nothing is evicted." : "Loads on \(swap.device) and evicts \(swap.evicts.joined(separator: ", ")).")
                .font(.callout)
            HStack {
                Button("Load \(swap.model)") { model.send(.approveSwap(id: swap.id)) }.buttonStyle(.borderedProminent)
                Button("Cancel Task", role: .destructive) { model.send(.rejectSwap(id: swap.id)) }.buttonStyle(.bordered)
            }
        }
        .card(tint: .stateNeedsYou)
    }
}

/// Everything that needs you, newest last. Swipe right to approve, left to reject, on iPhone and iPad.
struct AttentionList: View {
    @Environment(AppModel.self) private var model
    var emptyText = "Nothing needs you."

    var body: some View {
        let items = model.store.attention
        LazyVStack(alignment: .leading, spacing: 12) {
            if items.isEmpty {
                Label(emptyText, systemImage: "checkmark.seal").foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(items) { item in
                AttentionCard(item: item)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if case .approval(let a) = item, !a.needsCare {
                            Button { model.send(.approve(id: a.id)) } label: { Label("Approve", systemImage: "checkmark") }.tint(.stateDone)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if case .approval(let a) = item {
                            Button(role: .destructive) { model.send(.reject(id: a.id)) } label: { Label("Reject", systemImage: "xmark") }
                        }
                    }
            }
        }
        .sensoryFeedback(.warning, trigger: items.count) { old, new in new > old }
    }
}
