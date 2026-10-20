#if os(iOS)
import DuetKit
import SwiftUI

/// iPhone: a remote control and an inbox. "Now" answers "what's happening, and what needs me?" in one glance,
/// with the decisions in thumb reach; Chat, Workers and Terminal are one tap away.
struct PhoneRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let attention = model.store.attention.count
        TabView(selection: $model.phoneTab) {
            Tab("Now", systemImage: "bolt.horizontal.circle", value: PhoneTab.now) {
                NavigationStack { NowScreen() }
            }
            .badge(attention)
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right", value: PhoneTab.chat) {
                NavigationStack { PhoneChatScreen() }
            }
            Tab("Fleet", systemImage: "cpu", value: PhoneTab.workers) {
                NavigationStack(path: $model.workersPath) { PhoneWorkersScreen() }
            }
            Tab("Files", systemImage: "folder", value: PhoneTab.files) {
                NavigationStack(path: $model.filesPath) { FilesRoot(path: model.filesRoot).id(model.filesRoot).filesDestinations() }
            }
            Tab("Terminal", systemImage: "terminal", value: PhoneTab.terminal) {
                NavigationStack { TerminalScreen().navigationTitle("Terminal").navigationBarTitleDisplayMode(.inline) }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Only when there's something to show: Claude working, or decisions waiting.
        .tabViewBottomAccessory(isEnabled: model.store.leadStatus.busy || attention > 0) {
            PhoneStatusAccessory()
        }
        // Satisfying, not noisy: what you do, and the moments worth knowing about without looking.
        .sensoryFeedback(trigger: model.touch) { _, t in
            switch t?.kind {
            case .sent: .impact(weight: .light)
            case .approved: .impact(flexibility: .solid, intensity: 0.9)
            case .rejected: .impact(weight: .medium)
            case .stopped: .impact(weight: .heavy)
            case nil: nil
            }
        }
        .sensoryFeedback(trigger: model.store.beat) { _, b in
            switch b?.moment {
            case .replied, .taskDone: .success
            case .failed, .taskFailed: .error
            case .diagram: .impact(flexibility: .soft, intensity: 0.7)
            case nil: nil
            }
        }
        .fullScreenCover(item: $model.diagramSheet) { ref in
            NavigationStack { DiagramScreen(diagramId: ref.id, inSheet: true).filesDestinations() }
        }
        .sheet(item: $model.sideChatSheet) { ref in
            SideChatView(ref: ref).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .diffPresentation()
        .windowRequests()
        .environment(\.density, .compact)
    }
}

/// The pill above the tab bar: what Claude is doing and how many decisions wait. Tap to go to Now.
struct PhoneStatusAccessory: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.store.leadStatus
        let n = model.store.attention.count
        Button {
            // Idle: a shortcut to ask Claude. Otherwise: jump to what's happening.
            if n == 0 && !s.busy { model.phoneTab = .chat; model.focusComposerRequest += 1 } else { model.phoneTab = .now }
        } label: {
            HStack(spacing: 8) {
                PulsingSymbol(systemName: n > 0 ? "hand.raised.fill" : s.busy ? s.symbol : "square.and.pencil",
                              tint: n > 0 ? .stateNeedsYou : s.busy ? s.phase.tint : .stateIdle, active: s.busy)
                Text(n > 0 ? "\(n) waiting on you" : s.busy ? s.label : "Message Claude").lineLimit(1)
                // How long it has waited on you; otherwise how long Claude has been at it.
                if let since = n > 0 ? model.store.waitingSince : s.busy ? s.since : nil { Elapsed(since: since).foregroundStyle(.secondary) }
                Spacer()
                if s.busy {
                    Button("Stop", systemImage: "stop.fill") { model.send(.interrupt) }
                        .labelStyle(.iconOnly).foregroundStyle(.stateFailed)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("status-accessory")
    }
}

/// Now: Claude's status, everything that needs you (tap or swipe), the workers, and recent results.
struct NowScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        let store = model.store
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LeadStatusCard()
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(store.attention.isEmpty ? "Nothing needs you" : "Needs you · \(store.attention.count)",
                                 symbol: store.attention.isEmpty ? "checkmark.seal" : "hand.raised.fill",
                                 tint: store.attention.isEmpty ? .secondary : .stateNeedsYou)
                    if !store.attention.isEmpty { AttentionList() }
                }
                // Claude's plan for the live conversation: who is doing what, what's done, what Claude does next.
                if let id = store.currentConversationId, store.planSummary(id) != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Plan", symbol: "checklist", tint: .secondary)
                        PlanList(conversationId: id).card()
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Workers", symbol: "cpu", tint: .secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(store.workers) { w in
                                NavigationLink(value: w.id) { WorkerChip(worker: w, activity: store.workerActivity[w.id]) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollClipDisabled()
                }
                if let reply = model.lastReply {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Claude's last reply", symbol: "sparkles", tint: .secondary)
                        Button { model.phoneTab = .chat } label: {
                            // Bold, code and links as in the thread; lists and headings stay plain lines.
                            Text((try? AttributedString(markdown: reply, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(reply))
                                .font(.callout).lineLimit(6).multilineTextAlignment(.leading)
                                // The gist first, from this device's model, when the reply is long.
                                .onDeviceSummary(reply, key: "reply-\(reply.hashValue)")
                                .frame(maxWidth: .infinity, alignment: .leading).card()
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !store.recentResults.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Recent results", symbol: "checkmark.seal", tint: .secondary)
                        ForEach(store.recentResults.prefix(4), id: \.taskId) { t in
                            NavigationLink(value: t.worker) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(t.worker) · \(taskStateLabel(t.displayState))").font(.caption.bold()).foregroundStyle(taskStateTint(t.displayState))
                                        .onDeviceSummary(t.result, key: "result-\(t.taskId)", edge: .bottom, spacing: 6)
                                    if let p = t.prompt { Text(p).font(.callout).lineLimit(2) }
                                    if let e = t.evidence, !t.isApple, !t.isClaude { Text(e).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3) }
                                }
                                .card()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                ConnectionFooter().padding(.top, 8)
            }
            .padding(16)
        }
        .swipeActionsContainer()
        .navigationTitle("Doublet")
        .navigationDestination(for: String.self) { WorkerDetail(workerId: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarPinnedTrailing) {
                Button("Ask Claude", systemImage: "square.and.pencil") { model.phoneTab = .chat; model.focusComposerRequest += 1 }
            }
            ToolbarOverflowMenu {
                Button("Settings", systemImage: "gear") { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .refreshable { model.connect() }
    }
}

/// Chat: the active conversation's thread (long replies and tool output collapsed), Claude's controls in the bar,
/// and the list of conversations a tap away. An earlier conversation shows read-only, with Resume where the composer was.
struct PhoneChatScreen: View {
    @Environment(AppModel.self) private var model
    @State private var confirmNew = false
    @State private var showConversations = false

    var body: some View {
        let store = model.store
        let active = model.activeConversationId
        let isLive = model.isViewingLive
        let conversation = active.flatMap { store.conversation($0) }
        LeadThread(conversationId: model.selectedConversation)
            .id(model.selectedConversation ?? "live")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isLive, let id = model.selectedConversation {
                    ResumeBar(conversationId: id)
                } else if model.cardInput == nil {
                    // While you edit a command or write a note in a card, that card has the keyboard to itself.
                    Composer()
                }
            }
            .navigationTitle(model.conversationTitle(active))
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle(isLive ? model.leadModelName : "Read-only")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Conversations", systemImage: "list.bullet") { showConversations = true }
                        .accessibilityIdentifier("conversations-button")
                }
                if isLive {
                    ToolbarItem(placement: .topBarPinnedTrailing) { LeadModelMenu() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Side Chat", systemImage: "bubble.left.and.bubble.right") { model.openSideChat() }
                            .accessibilityIdentifier("side-chat-button")
                    }
                }
                ToolbarOverflowMenu {
                    if isLive { LeadEffortMenu() }
                    if isLive { LeadModeMenu() }
                    if let cwd = isLive ? store.leadCwd : conversation?.cwd {
                        Button("Files in \(Paths.short(cwd))", systemImage: "folder") { model.openFiles(isLive ? nil : cwd, compact: true) }
                    }
                    diagramsMenu(conversation)
                    Button("Tasks in this conversation", systemImage: "cpu") { model.workersShowAll = false; model.phoneTab = .workers }
                    if isLive {
                        Button("Compact", systemImage: "rectangle.compress.vertical") { model.send(.compact) }
                            .disabled(store.leadStatus.busy)
                        Button("New conversation…", systemImage: "plus.bubble") { confirmNew = true }
                            .disabled(store.leadStatus.busy)
                    } else if let id = model.selectedConversation {
                        Button("Resume this conversation", systemImage: "arrow.uturn.backward.circle") { Task { _ = await model.resume(id) } }
                            .disabled(store.leadStatus.busy)
                    }
                }
            }
            .sheet(isPresented: $showConversations) { ConversationListSheet() }
            .confirmationDialog("Start a new conversation?", isPresented: $confirmNew, titleVisibility: .visible) {
                Button("New Conversation") { model.newConversation() }
            } message: {
                Text("This conversation stays in the list and can be resumed. Workers and terminals are unaffected.")
            }
    }

    /// This conversation's diagrams, and every other one's behind a submenu.
    @ViewBuilder private func diagramsMenu(_ conversation: Conversation?) -> some View {
        let store = model.store
        let mine = conversation?.diagramIds.reversed() ?? []
        let others = store.diagramOrder.reversed().filter { !mine.contains($0) }
        if !mine.isEmpty || !others.isEmpty {
            Menu("Diagrams", systemImage: "point.3.filled.connected.trianglepath.dotted") {
                Section(mine.isEmpty ? "None in this conversation" : "This conversation") {
                    ForEach(mine, id: \.self) { id in diagramButton(id) }
                }
                if !others.isEmpty {
                    Menu("Other conversations") { ForEach(others, id: \.self) { id in diagramButton(id) } }
                }
            }
        }
    }

    @ViewBuilder private func diagramButton(_ id: String) -> some View {
        if let d = model.store.diagrams[id] {
            Button(d.version > 1 ? "\(d.title) (v\(d.version))" : d.title) { model.openDiagram(id, compact: true) }
        }
    }
}

struct PhoneWorkersScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let store = model.store
        let scope = model.workersShowAll ? nil : model.activeConversationId
        List {
            Section {
                // The active conversation's tasks, or every task; WorkerDetail follows the same choice.
                Picker("Show", selection: $model.workersShowAll) {
                    Text("This conversation").tag(false)
                    Text("All").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("workers-scope")
                ForEach(store.workers) { w in
                    NavigationLink(value: w.id) {
                        HStack {
                            WorkerRow(worker: w, activity: store.workerActivity[w.id])
                            let n = model.taskIds(for: w.id, conversation: scope).count
                            if n > 0 { Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }
                    }
                }
            } footer: {
                Text("Workers are local models on the hub (and your Mac, when it's enabled), and Apple Intelligence on your devices while Doublet is open. Type @worker in Chat to give one a task.")
            }
        }
        .navigationTitle("Fleet")
        .navigationDestination(for: String.self) { WorkerDetail(workerId: $0) }
    }
}
#endif
