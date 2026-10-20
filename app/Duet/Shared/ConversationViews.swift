import DuetKit
import SwiftUI

/// A conversation in a list: its name, when it was last active, where Claude worked, what it holds. The live one
/// shows what Claude is doing instead.
struct ConversationRow: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let live: Bool

    var body: some View {
        let store = model.store
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.conversationTitle(conversation.id)).lineLimit(1)
                if live {
                    HStack(spacing: 4) {
                        Text(store.leadStatus.busy ? store.leadStatus.label : model.leadModelName)
                        if let since = store.leadStatus.since, store.leadStatus.busy { Text("·"); Elapsed(since: since) }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let counts { Text(counts).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
        } icon: {
            if live {
                PulsingSymbol(systemName: store.leadStatus.symbol, tint: store.leadStatus.phase.tint, active: store.leadStatus.busy)
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(.secondary)
            }
        }
        // Named once the first exchange is in; named again once Claude has replied, if it was named from the prompt alone.
        .task(id: TitleKey(id: conversation.id, hasReply: conversation.firstReply != nil)) {
            await model.titles.ensure(conversation, apple: model.apple, replayed: store.replayedOnce)
        }
        .accessibilityLabel("\(model.conversationTitle(conversation.id)), \(live ? "live" : "read-only")")
    }

    private var subtitle: String {
        [conversation.lastActivity.formatted(.relative(presentation: .named)), conversation.cwd.map(Paths.name)].compactMap(\.self).joined(separator: " · ")
    }

    private var counts: String? {
        var parts: [String] = []
        let turns = conversation.turnIds.count, tasks = conversation.taskIds.count, diagrams = conversation.diagramIds.count
        if turns > 0 { parts.append(turns == 1 ? "1 turn" : "\(turns) turns") }
        if tasks > 0 { parts.append(tasks == 1 ? "1 task" : "\(tasks) tasks") }
        if diagrams > 0 { parts.append(diagrams == 1 ? "1 diagram" : "\(diagrams) diagrams") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private struct TitleKey: Equatable { let id: String; let hasReply: Bool }
}

/// Resume, Rename…, Copy Session ID (and New Conversation on the live one), for a conversation's context menu.
struct ConversationMenuItems: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let live: Bool
    let rename: () -> Void

    var body: some View {
        if !live {
            Button("Resume", systemImage: "arrow.uturn.backward.circle") { Task { _ = await model.resume(conversation.id) } }
                .disabled(model.store.leadStatus.busy)
        }
        Button("Rename…", systemImage: "pencil", action: rename)
        Button("Copy Session ID", systemImage: "doc.on.doc") { Pasteboard.copy(conversation.id) }
        if live {
            Button("New Conversation", systemImage: "plus.bubble") { model.newConversation() }
                .disabled(model.store.leadStatus.busy)
        }
    }
}

/// Your own name for a conversation (kept on this device).
struct RenameConversationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $text).onSubmit(save)
                Text("Leave it empty to go back to the name made on this device.").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("Rename Conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
        }
        .onAppear { text = model.conversationTitle(conversation.id) }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 160)
        #endif
    }

    private func save() {
        model.titles.rename(conversation.id, to: text)
        dismiss()
    }
}

/// Under an earlier conversation's thread, where the composer would be: it's read-only, and Resume makes it live.
struct ResumeBar: View {
    @Environment(AppModel.self) private var model
    let conversationId: String
    @State private var error: String?

    var body: some View {
        let busy = model.store.leadStatus.busy
        let last = model.store.conversation(conversationId)?.lastActivity
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label {
                    Text("Read-only" + (last.map { " · last active \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                } icon: {
                    Image(systemName: "lock")
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.resumePending == conversationId {
                    ProgressView().controlSize(.small)
                    Text("Resuming…").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Resume", systemImage: "arrow.uturn.backward.circle") {
                        error = nil
                        Task { error = await model.resume(conversationId) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    .help(busy ? "Claude is busy; stop it or wait for the turn to end" : "Continue this conversation")
                    .accessibilityIdentifier("resume-\(conversationId)")
                }
            }
            if let error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.stateFailed)
                    Spacer()
                    Button("Dismiss", systemImage: "xmark") { self.error = nil }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.bar)
    }
}

#if os(iOS)
/// iPhone: every conversation, live first. Pick one to show it in Chat.
struct ConversationListSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Conversation?

    var body: some View {
        let live = model.store.currentConversationId
        NavigationStack {
            List(model.conversationList) { c in
                let isLive = c.id == live
                let selected = isLive ? model.isViewingLive : model.selectedConversation == c.id
                Button {
                    model.select(conversation: isLive ? nil : c.id, compact: true)
                    dismiss()
                } label: {
                    HStack {
                        ConversationRow(conversation: c, live: isLive)
                        Spacer()
                        if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { ConversationMenuItems(conversation: c, live: isLive) { renaming = c } }
                .accessibilityIdentifier("conversation-row-\(c.id)")
            }
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("New", systemImage: "plus.bubble") { model.newConversation(); dismiss() }
                        .disabled(model.store.leadStatus.busy)
                }
            }
            .sheet(item: $renaming) { RenameConversationSheet(conversation: $0) }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
