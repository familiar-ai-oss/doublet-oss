import DuetKit
import SwiftUI

/// One composer for every device. Plain text goes to Claude; `@worker` hands a task straight to that worker;
/// `@all` goes to Claude and every running worker. Boost adds "ultrathink" to just this turn.
struct Composer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    /// The main window's conversation: what the side stage shows goes with the message, as a chip (`composerContext`).
    var showsContext = false
    @FocusState private var focused: Bool
    /// Where this device's model thinks the draft should go, if not to Claude.
    @State private var suggestion: RouteSuggestion?
    @AppStorage("suggestRoutes") private var suggestRoutes = true

    var body: some View {
        if model.voice.isTalkingWithClaude {
            TalkPanel()
        } else {
            editor
        }
    }

    private var editor: some View {
        @Bindable var model = model
        let store = model.store
        let target = model.draftTarget
        let empty = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            if let p = model.voice.problem { ProblemLine(text: p) { model.voice.clearProblem() } }
            if let prefix = model.mentionPrefix {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.mentionOptions(prefix)) { m in
                            Button { model.draft = "@\(m.id) "; focused = true } label: {
                                Label(m.title, systemImage: m.symbol)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
            // Claude in a mode other than Ask: which, and the way back.
            PermissionModeLine()
            if showsContext, let c = model.composerContext {
                ContextChip(context: c)
            }
            if target.kind != .claude {
                Label(target.title, systemImage: target.symbol).font(.caption).foregroundStyle(.secondary)
            } else if let s = suggestion {
                // A suggestion only: one tap addresses the draft to that worker.
                Button { model.draft = "@\(s.worker) " + model.draft; suggestion = nil; focused = true } label: {
                    Label("Give this to \(s.name)? \(s.reason)", systemImage: "apple.intelligence").lineLimit(1)
                }
                .font(.caption).buttonStyle(.bordered).controlSize(.small)
                .help("Suggested on this device by Apple Intelligence")
                .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .bottom, spacing: 6) {
                    TextField(placeholder, text: $model.draft, axis: .vertical)
                        .lineLimit(1...(density == .compact ? 5 : 8))
                        .focused($focused)
                        .sendsOnReturn($model.draft, send: send)
                    MicButton(field: "composer", text: $model.draft)
                        .buttonStyle(.borderless)
                }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary) }
                    // A file dragged from the explorer: its path, for Claude to read.
                    .dropDestination(for: String.self) { paths, _ in
                        let added = paths.filter { $0.hasPrefix("/") }.map(Paths.short).joined(separator: " ")
                        guard !added.isEmpty else { return false }
                        model.draft += (model.draft.isEmpty || model.draft.hasSuffix(" ") ? "" : " ") + added + " "
                        return true
                    }
                    .accessibilityIdentifier("composer")
                Toggle(isOn: $model.boost) { Label("Boost", systemImage: model.boost ? "flame.fill" : "flame") }
                    .toggleStyle(.button).labelStyle(.iconOnly)
                    .tint(.orange)
                    .help("Boost: think harder on this turn (ultrathink)")
                    .accessibilityIdentifier("boost")
                if store.leadStatus.busy && density != .compact {
                    // ⌘. lives in the Claude menu (Mac, and iPad with a keyboard).
                    Button("Stop", systemImage: "stop.circle.fill") { model.send(.interrupt) }
                        .labelStyle(.iconOnly).font(.title2).foregroundStyle(.red)
                }
                // Nothing to send: Talk mode instead, as in a phone's messages.
                if empty, !model.voice.isDictating("composer"), target.kind == .claude {
                    TalkButton(target: .conversation, big: density == .compact)
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                        .labelStyle(.iconOnly).font(density == .compact ? .largeTitle : .title)
                        .disabled(empty)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier("send")
                }
            }
            .buttonStyle(.borderless)
            // What's being heard, and Undo once Apple Intelligence has tidied it.
            DictationLive(field: "composer")
        }
        .padding(.horizontal, density == .compact ? 12 : 16).padding(.vertical, 10)
        .background(.bar)
        .onChange(of: model.focusComposerRequest) { focused = true }
        // After a pause in typing, this device's model suggests where the draft should go.
        .task(id: model.draft) {
            let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            // Not while dictating: the draft changes with every word.
            guard suggestRoutes, text.count >= 16, !text.hasPrefix("@"), !model.voice.isDictating("composer") else { suggestion = nil; return }
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let route = await model.apple.route(text), !Task.isCancelled else { return }
            withAnimation(.snappy) { suggestion = model.suggestion(for: route) }
        }
    }

    /// Sends the draft; while dictating, once the last words have settled into it.
    private func send() {
        let context = showsContext ? model.composerContext : nil
        guard model.voice.isDictating("composer") else { model.sendDraft(context: context); return }
        Task {
            await model.voice.stopDictation()
            model.sendDraft(context: context)
        }
    }

    private var placeholder: String {
        density == .compact ? "Message Claude" : "Message Claude · @worker for a task · @all for everyone"
    }
}

/// What the side stage shows, above the message: it goes with it, so Claude knows what you're asking about. × leaves
/// it out of this message.
private struct ContextChip: View {
    @Environment(AppModel.self) private var model
    let context: ComposerContext

    var body: some View {
        HStack(spacing: 6) {
            Label(context.label, systemImage: context.symbol)
                .lineLimit(1).truncationMode(.middle)
            Button { model.removeContext() } label: {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .buttonStyle(.borderless)
            .help("Send without this")
            .accessibilityLabel("Remove \(context.label)")
        }
        .font(.caption)
        .foregroundStyle(Color.accentColor)
        .padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 4)
        .background { Capsule().fill(Color.accentColor.opacity(0.12)) }
        .help("Sent with your message, so Claude knows what you're asking about")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("About \(context.label), sent with your message")
        .accessibilityIdentifier("composer-context")
    }
}

extension View {
    /// A message field that grows: Return sends, as in Claude's apps, and Shift-Return or Option-Return starts a new
    /// line. With a hardware keyboard; on the on-screen keyboard Return starts a new line and the send button sends.
    /// ⌘Return still sends too, through the send button's shortcut.
    func sendsOnReturn(_ text: Binding<String>, send: @escaping () -> Void) -> some View {
        onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                #if os(macOS)
                // A Mac field would take any Return as sending: the new line goes in here.
                text.wrappedValue += "\n"
                return .handled
                #else
                return .ignored
                #endif
            }
            guard press.modifiers.isEmpty else { return .ignored }
            send()
            return .handled
        }
        // Where the field takes Return before a key handler sees it (the Mac's field editor), it submits: send then.
        .onSubmit(send)
    }
}

/// Who a draft is addressed to.
struct DraftTarget: Equatable {
    enum Kind: Equatable { case claude, all, worker(String) }
    var kind: Kind
    var title: String {
        switch kind {
        case .claude: "To Claude"
        case .all: "To Claude and every running worker"
        case .worker(let w): "New task for \(w)"
        }
    }
    var symbol: String {
        switch kind {
        case .claude: "sparkles"
        case .all: "megaphone"
        case .worker: "hammer"
        }
    }
}

struct MentionOption: Identifiable {
    let id: String
    let title: String
    let symbol: String
}
