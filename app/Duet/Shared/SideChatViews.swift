import DuetKit
import MarkdownUI
import SwiftUI

/// A side chat: a quick question beside the conversation. On Auto, a question about the code goes to a local model
/// first, and its answer counts when the lines it cites check out; otherwise Claude answers in a copy of the
/// conversation, so it knows what's been said and done, and the conversation itself stays as it was. The answer shows as it streams, with what
/// Claude is looking at; follow-ups continue the same chat. A new one starts empty, about something or the conversation.
struct SideChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.supportsMultipleWindows) private var multipleWindows
    @Environment(\.density) private var density
    @Environment(\.appearsActive) private var appearsActive
    let ref: SideChatRef
    /// In a window of its own: no "open in window" or close button (the window has those), and Move to Main Window.
    var inWindow = false
    /// In a tab of the main window: the tab's menu moves and closes it.
    var docked = false
    /// Its window's Keep on Top (Mac).
    var keepOnTop: Binding<Bool>? = nil
    /// How it closes when it isn't a sheet: the iPad's floating side chat.
    var close: (() -> Void)? = nil
    @State private var chatId: String?
    @State private var draft = ""
    @State private var choice: String?
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var chat: SideChat? { chatId.flatMap { model.store.sideChats[$0] } }
    private var about: SideAbout? { chat?.about ?? ref.about }

    var body: some View {
        // The header and the composer are bars the answer scrolls under, as in a chat.
        transcript
            .safeAreaInset(edge: .top, spacing: 0) { VStack(spacing: 0) { header; Divider() }.background(.bar) }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    if model.voice.isTalking(in: ref.id) { TalkPanel() } else { composer }
                }
                .background(.bar)
            }
            .navigationTitle(chat?.title ?? "Side Chat")
            // Talk mode in a new side chat: it has an id once the first question is asked.
            .onChange(of: model.voice.sideChatId) { _, id in
                if chatId == nil, model.voice.isTalking(in: ref.id), let id { chatId = id }
            }
            // Closing the side chat ends Talk mode in it.
            .onDisappear { if model.voice.isTalking(in: ref.id) || model.voice.isDictating("side-\(ref.id)") { model.voice.end() } }
        .onAppear {
            if chatId == nil { chatId = ref.chatId }
            // In a tab it appears whenever the tab is picked: the keyboard waits for a tap there.
            if !docked { focused = true }
        }
        // In a window of its own, once it's been asked: the workspace knows it floats here, so opening it again from
        // the sidebar brings this window forward.
        .onChange(of: chatId) { old, new in
            guard inWindow else { return }
            if let old { model.workspace.landed(.sideChat(old)) }
            if let new { model.floated(.sideChat(new), window: .side(ref)) }
        }
        .onDisappear { if inWindow, let chatId { model.workspace.landed(.sideChat(chatId)) } }
        // Closed while Claude is still answering: the answer comes as a sticky note where you are.
        .onDisappear {
            if let chatId, let chat = model.store.sideChats[chatId], chat.isAnswering, chat.annotationId == nil {
                model.stick(.sideChat(chatId), question: chat.messages.first { $0.role == "user" }?.text)
            }
        }
        // Docked, from here or by its handle dropped on the tab bar: the chat's in a tab now.
        .onChange(of: model.docked) { _, docked in
            if inWindow, let chatId, docked?.place == .sideChat(chatId) { dismissWindow() }
        }
        .onChange(of: appearsActive) { _, active in
            if inWindow, active, let chatId { model.windowActivated(.sideChat(chatId)) }
        }
        // Window › Move to Main Window, while this window has the focus.
        .focusedSceneValue(\.dockPane, inWindow ? chatId.map { id in DockAction(place: .sideChat(id)) { dockInMainWindow(id) } } : nil)
        .onKeyPress(.escape) {
            guard !inWindow, !docked else { return .ignored }
            closeSelf()
            return .handled
        }
        .accessibilityIdentifier("side-chat")
    }

    /// Closes the sheet, or the floating side chat.
    private func closeSelf() {
        if let close { close() } else { dismiss() }
    }

    /// The chat comes back as a tab of the main window, and its window closes (on `docked`).
    private func dockInMainWindow(_ id: String) {
        model.dock(.sideChat(id))
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            // In its own window, once asked: the window's handle, to drag onto the main window's tabs.
            if inWindow, let id = chatId {
                PaneHandle(place: .sideChat(id)).foregroundStyle(Color.accentColor).font(.title3)
            } else {
                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(Color.accentColor).font(.title3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(chat?.title ?? "Side Chat").font(.headline).lineLimit(1)
                Text(knows).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            modelMenu
            // Once asked, a side chat can dock as a tab of the main window (iPad and Mac).
            if let id = chatId, density != .compact, !docked {
                Button(inWindow ? "Move to Main Window" : "Open as Tab", systemImage: "rectangle.stack.badge.plus") {
                    if inWindow {
                        dockInMainWindow(id)
                    } else {
                        model.show(.sideChat(id), keep: true)
                        closeSelf()
                    }
                }
                .help("Put this side chat in a tab of the main window")
            }
            // Once asked, it can go to your other device, as a tab can.
            if let id = chatId { SendToDevice(place: .sideChat(id)) }
            #if os(macOS)
            if let keepOnTop { KeepOnTopToggle(isOn: keepOnTop).toggleStyle(.button) }
            #endif
            if !inWindow, !docked, multipleWindows {
                Button("Open in Window", systemImage: "macwindow.badge.plus") {
                    openWindow(id: "side", value: chatId.map { SideChatRef(chatId: $0) } ?? ref)
                    closeSelf()
                }
                .help("Keep this side chat in a window of its own")
            }
            if !inWindow, !docked {
                Button("Close", systemImage: "xmark.circle.fill") { closeSelf() }
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(12)
        .frame(minHeight: 44)
        // Floating over the iPad's main window, the whole header moves the side chat.
        .movesPanel()
    }

    /// How much of the conversation the answers can draw on.
    private var knows: String {
        switch chat?.forked {
        case "whole": "Knows this conversation · adds nothing to it"
        case "before_turn": "Knows it up to Claude's last reply"
        case "none": "The conversation hadn't started"
        default: currentChoice == "auto" ? "Code questions go to a local model first" : "Answers from a copy of the conversation"
        }
    }

    /// Auto: a local model answers questions about the code (its citations checked), Claude the rest.
    private var currentChoice: String { choice ?? "auto" }

    private var modelMenu: some View {
        Menu {
            Picker("Model", selection: Binding(get: { currentChoice }, set: { choice = $0 })) {
                Text("Auto (local first)").tag("auto")
                ForEach(model.leadModelChoices) { m in Text(m.displayName).tag(m.value) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(currentChoice == "auto" ? "Auto" : model.leadModelChoices.first { $0.value == currentChoice }?.displayName ?? currentChoice.capitalized)
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background { Capsule().fill(.secondary.opacity(0.15)) }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Who answers: Auto lets a local model answer questions about the code (its citations checked) and Claude the rest; or pick a Claude model")
    }

    // MARK: transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let about { AboutChip(about: about) }
                    if let chat {
                        let latest = chat.messages.last { !$0.isUser }?.id
                        ForEach(chat.messages) { SideMessageRow(message: $0, latest: $0.id == latest) }
                        if !chat.streaming.isEmpty {
                            Text(chat.streaming).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if chat.isAnswering {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(Self.activity(chat.activity)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        if let e = chat.error { Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.stateFailed) }
                    } else {
                        Text(currentChoice == "auto"
                             ? "Ask a quick question. A question about the code goes to a local model first, and its answer counts only when the lines it cites check out. Otherwise Claude answers, in a copy of this conversation. Nothing here changes the conversation or your files."
                             : "Ask a quick question. Claude answers in a copy of this conversation, so it knows what's been said and done, and the conversation itself stays as it is. It can read files but not change anything.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.stateFailed) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat?.messages.count) { withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: chat?.streaming.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    // MARK: composer

    private var composer: some View {
        let field = "side-\(ref.id)"
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            if let p = model.voice.problem { ProblemLine(text: p) { model.voice.clearProblem() } }
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .bottom, spacing: 6) {
                    TextField(chat == nil ? "Ask about \(about?.title ?? "the conversation")…" : "Follow up…", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .sendsOnReturn($draft, send: send)
                        .accessibilityIdentifier("side-chat-field")
                    MicButton(field: field, text: $draft).font(.body)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.secondary.opacity(0.1)) }
                if chat?.isAnswering == true {
                    Button("Stop", systemImage: "stop.circle.fill") { if let id = chatId { model.send(.sideStop(chatId: id)) } }
                        .foregroundStyle(.stateFailed)
                        .keyboardShortcut(".", modifiers: .command)
                } else if empty, !model.voice.isDictating(field) {
                    // Nothing typed: ask out loud instead, and hear the answer.
                    Button("Talk", systemImage: "waveform.circle.fill") {
                        Task { await model.voice.startTalk(.side(key: ref.id, chatId: chatId, about: chatId == nil ? ref.about : nil, model: currentChoice)) }
                    }
                    .help("Ask out loud and hear the answer")
                } else {
                    Button("Ask", systemImage: "arrow.up.circle.fill", action: send)
                        .disabled(empty || sending)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            DictationLive(field: field).labelStyle(.titleAndIcon)
        }
        .labelStyle(.iconOnly)
        .font(.title2)
        .buttonStyle(.borderless)
        .padding(10)
    }

    /// "Read /home/b/proj/src/fleet.ts" as "Reading fleet.ts": what Claude is looking at, in words.
    static func activity(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Thinking" }
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            switch raw {
            case "WebSearch": return "Searching the web"
            case "WebFetch": return "Reading a web page"
            default: return raw
            }
        }
        let what = parts[1].hasPrefix("/") ? Paths.name(parts[1]) : parts[1]
        switch parts[0] {
        case "Read": return "Reading \(what)"
        case "Grep": return "Searching for \(what)"
        case "Glob": return "Looking for \(what)"
        case "WebSearch": return "Searching the web for \u{201C}\(what)\u{201D}"
        case "WebFetch": return "Reading \(URL(string: what)?.host() ?? what)"
        default: return raw
        }
    }

    private func send() {
        // Dictating: the last words settle into the field first.
        if model.voice.isDictating("side-\(ref.id)") {
            Task {
                await model.voice.stopDictation()
                send()
            }
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, chat?.isAnswering != true else { return }
        sending = true
        problem = nil
        let pick = currentChoice
        Task {
            do {
                chatId = try await model.askSide(text, chatId: chatId, about: ref.about, model: pick == "auto" ? nil : pick)
                draft = ""
            } catch {
                problem = error.localizedDescription
            }
            sending = false
        }
    }
}

/// One message: your question on the right, Claude's answer as Markdown (copy it, or take it to the conversation).
struct SideMessageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let message: SideMessageEvent
    /// The chat's latest answer: only that one can still go to Claude (once Claude has answered, the chat is Claude's).
    var latest = true

    var body: some View {
        if message.isUser {
            VStack(alignment: .trailing, spacing: 3) {
                Text(message.text).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.14)) }
                if message.image == true {
                    Label("With a picture of your notes", systemImage: "pencil.and.scribble").font(.caption2).foregroundStyle(.secondary)
                }
                if let by = message.by, by != model.device { Text(by).font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 36)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                // Parsed once per message: the panel redraws as the next answer streams in.
                Markdown(MarkdownCache.content("side-\(message.id)", message.text))
                    .markdownSoftBreakMode(.lineBreak)
                    .diagramFences()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A local answer stays short; its further points wait under "More".
                if let more = message.more, !more.isEmpty {
                    DisclosureGroup("More") {
                        Markdown(more).markdownSoftBreakMode(.lineBreak).diagramFences().textSelection(.enabled).padding(.top, 4)
                    }
                    .font(.callout)
                }
                // Who answered; a local answer can go to Claude for a check.
                if message.model != nil {
                    HStack(spacing: 8) {
                        AnswerChip(message: message)
                        if message.local == true && latest {
                            Button("Ask Claude", systemImage: "sparkles") { model.send(.sideReroute(chatId: message.chatId)) }
                                .buttonStyle(.borderless).font(.caption)
                                .help("Claude checks this answer, with what the local model found")
                        }
                    }
                }
            }
            .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(message.text) }
                    ReadAloudButton(id: message.id) { message.text }
                    Button("Use in a Message to Claude", systemImage: "arrowshape.turn.up.left") {
                        model.askAbout("From a side chat:\n\(message.text)\n\n", compact: density == .compact)
                    }
                }
        }
    }
}

/// What a side chat is about, as a chip.
struct AboutChip: View {
    let about: SideAbout

    var body: some View {
        let file = if case .file = about { true } else { false }
        Label(about.title, systemImage: file ? "doc.text" : "text.quote")
            .font(.caption).lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background { Capsule().fill(.secondary.opacity(0.12)) }
            .accessibilityLabel("About \(about.title)")
    }
}

/// A toolbar button for a quick question about what's on screen (nil: the conversation): a side chat floating over
/// the window on iPad (to move and resize; a sheet on iPhone), a popover on Mac.
struct SideChatToolbarButton: View {
    @Environment(AppModel.self) private var model
    var about: SideAbout? = nil
    @State private var shown: SideChatRef?

    var body: some View {
        #if os(iOS)
        Button("Side Chat", systemImage: "bubble.left.and.bubble.right") { model.openSideChat(about: about) }
            .help("Ask a quick question beside the conversation (⌘⇧K)")
            .accessibilityIdentifier("side-chat-button")
        #else
        Button("Side Chat", systemImage: "bubble.left.and.bubble.right") { shown = SideChatRef(about: about) }
            .help("Ask a quick question beside the conversation (⌘⇧K)")
            .accessibilityIdentifier("side-chat-button")
            .popover(item: $shown) { ref in
                SideChatView(ref: ref)
                    .frame(minWidth: 380, idealWidth: 420, minHeight: 420, idealHeight: 540)
                    .environment(model)
            }
        #endif
    }
}

/// A side chat in its own window (Mac, and iPad with more than one window).
struct SideChatWindow: View {
    @Environment(AppModel.self) private var model
    let ref: SideChatRef?
    /// Above other apps' windows, like a widget (Mac). Kept with the window, so it comes back with it.
    @SceneStorage("keepOnTop") private var keepOnTop = false

    var body: some View {
        if let ref {
            chat(ref)
                // Requests from this window (a tab picked in the ⌃Tab switcher) open even when no other window is.
                .windowRequests()
                .switcherHost()
                // In front, this chat is what the other device carries on with (Handoff).
                .handoff(ref.chatId.map { Handoff.Offer(place: .sideChat($0)) })
        } else {
            // Nothing to show: the window came back without its chat, or a dropped tab's chat is on its way.
            Color.clear.closesIfStillEmpty()
        }
    }

    private func chat(_ ref: SideChatRef) -> some View {
        #if os(macOS)
        SideChatView(ref: ref, inWindow: true, keepOnTop: $keepOnTop)
            .frame(minWidth: 340, minHeight: 380)
            .keepsOnTop(keepOnTop)
            .focusedSceneValue(\.keepOnTop, $keepOnTop)
            // Moved to half the screen: this window takes that half.
            .background(TakesUndockFrame { ref.chatId.flatMap { model.takeUndockFrame(for: .sideChat($0)) } })
        #else
        SideChatView(ref: ref, inWindow: true)
        #endif
    }
}

/// A side chat in a list (the sidebar, under its conversation): its question, and whether it's answering.
struct SideChatRow: View {
    @Environment(AppModel.self) private var model
    let chat: SideChat

    var body: some View {
        Button { model.openSideChat(chat.id) } label: {
            Label {
                Text(chat.title).lineLimit(1).truncationMode(.tail)
            } icon: {
                if chat.isAnswering {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: chat.state == "failed" ? "exclamationmark.bubble" : "bubble.left.and.bubble.right")
                        .foregroundStyle(chat.state == "failed" ? Color.stateFailed : .secondary)
                }
            }
            .font(.callout)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") { model.openWindow(.side(SideChatRef(chatId: chat.id))) }
            if let last = chat.messages.last(where: { !$0.isUser }) {
                Button("Copy Last Answer", systemImage: "doc.on.doc") { Pasteboard.copy(last.text) }
            }
        }
        .accessibilityLabel("Side chat: \(chat.title)\(chat.isAnswering ? ", answering" : "")")
    }
}

/// Moving a panel that floats over the main window by its header (the iPad's side chat): the panel gives one to what it
/// shows, and the header there takes the drag (`movesPanel()`). The drag is measured in the panel's overlay, which stays
/// still while the panel moves: measured in the panel's own space, it shifted under the finger and the panel shook.
struct PanelMover {
    let space: NamedCoordinateSpace
    /// The drag began, here (in `space`).
    let began: (CGPoint) -> Void
    /// How far it's been dragged so far; zero when it's over without ending (the system took the touch).
    let moved: (CGSize) -> Void
    /// Let go: how far it was dragged, how far it was heading (a flick), and where.
    let ended: (_ translation: CGSize, _ predicted: CGSize, _ at: CGPoint) -> Void
}

extension EnvironmentValues {
    @Entry var panelMover: PanelMover? = nil
}

extension View {
    /// The header of a panel floating over the main window (the iPad's side chat): dragging it, anywhere but its
    /// buttons, moves the panel. Anywhere else, nothing.
    func movesPanel() -> some View { modifier(MovesPanel()) }
}

private struct MovesPanel: ViewModifier {
    @Environment(\.panelMover) private var mover
    @GestureState private var dragging = false

    func body(content: Content) -> some View {
        if let mover {
            content
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: mover.space)
                        .updating($dragging) { value, state, _ in
                            if !state { mover.began(value.startLocation) }
                            state = true
                        }
                        .onChanged { mover.moved($0.translation) }
                        .onEnded { mover.ended($0.translation, $0.predictedEndTranslation, $0.location) }
                )
                // Over without ending (the system took the touch): the panel goes back to where it was.
                .onChange(of: dragging) { _, now in if !now { mover.moved(.zero) } }
        } else {
            content
        }
    }
}

#if os(iOS)
/// A side chat floating over the main window (iPad), like a small window of its own inside the app: drag its header
/// (anywhere but its buttons) to move it anywhere in the window, drag its corner to make it bigger or smaller, or tap the
/// size button (or double-tap the grabber) to switch between small and large. Let go, it stays inside the window, carries
/// on a little when flicked, and settles against an edge it's let go near, with a tap in the hand on Apple Pencil Pro. It
/// stays over the conversation and the side stage while you work; closing it keeps the chat under its conversation.
struct FloatingSideChat: View {
    @Environment(AppModel.self) private var model
    let ref: SideChatRef
    /// The room it has, in `space`: the main window's conversation and side stage, below the toolbar and above the
    /// keyboard.
    let room: CGRect
    /// Where `space` is in the window, for Apple Pencil Pro's tap in the hand.
    var origin: CGPoint = .zero
    /// How far its header is being dragged.
    @State private var moving: CGSize = .zero
    @GestureState private var growing: CGSize = .zero

    /// RegularRoot's overlay, which stays still while the chat moves: what its drags are measured in.
    nonisolated static let space = "duet.floating"
    static let small = CGSize(width: 400, height: 540)
    static let minimum = CGSize(width: 320, height: 300)
    private static let margin: CGFloat = 8
    /// Let go this near an edge of the room, it settles against it.
    private static let snap: CGFloat = 24

    var body: some View {
        let shown = placed(frame, moving: moving, growing: growing)
        VStack(spacing: 0) {
            grabber(large: isLarge(shown.size))
            FloatingChatContent(ref: ref)
        }
        .environment(\.panelMover, mover)
        .frame(width: shown.width, height: shown.height)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator) }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background)
                .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        }
        .overlay(alignment: .bottomTrailing) { resizeCorner }
        .offset(x: shown.minX, y: shown.minY)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floating-side-chat")
    }

    /// Where it was left; at first, small, against the trailing edge.
    private var frame: CGRect {
        model.sideChatPanel ?? CGRect(x: room.maxX - Self.small.width - 16, y: room.minY + 12, width: Self.small.width, height: Self.small.height)
    }

    /// The header's drag (and the grabber's): it moves the chat.
    private var mover: PanelMover {
        PanelMover(space: .named(Self.space),
                   began: { PencilTap.play(at: CGPoint(x: origin.x + $0.x, y: origin.y + $0.y)) },
                   moved: { moving = $0 },
                   ended: { release($0, heading: $1, at: $2) })
    }

    /// A frame moved and resized by the gestures in progress, kept inside the room.
    private func placed(_ f: CGRect, moving: CGSize = .zero, growing: CGSize = .zero) -> CGRect {
        let m = Self.margin
        let width = clamp(f.width + growing.width, Self.minimum.width, room.width - 2 * m)
        let height = clamp(f.height + growing.height, Self.minimum.height, room.height - 2 * m)
        let x = clamp(f.minX + moving.width, room.minX + m, room.maxX - width - m)
        let y = clamp(f.minY + moving.height, room.minY + m, room.maxY - height - m)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }

    private func isLarge(_ s: CGSize) -> Bool { s.width > Self.small.width + 60 || s.height > Self.small.height + 80 }

    /// Let go: a flick carries it on a quarter of the way it was heading; it stays inside the room, and settles against
    /// an edge it's near.
    private func release(_ translation: CGSize, heading predicted: CGSize, at point: CGPoint) {
        let carry = CGSize(width: translation.width + (predicted.width - translation.width) / 4,
                           height: translation.height + (predicted.height - translation.height) / 4)
        var f = placed(frame, moving: carry)
        let settled = settle(&f)
        withAnimation(.snappy) {
            model.sideChatPanel = f
            moving = .zero
        }
        if settled { PencilTap.play(at: CGPoint(x: origin.x + point.x, y: origin.y + point.y)) }
    }

    /// Against an edge of the room it's within `snap` of; true when that moved it.
    private func settle(_ f: inout CGRect) -> Bool {
        let m = Self.margin
        var moved = false
        func near(_ gap: CGFloat) -> Bool { gap > 0.5 && gap < Self.snap }
        if near(f.minX - room.minX - m) { f.origin.x = room.minX + m; moved = true }
        else if near(room.maxX - m - f.maxX) { f.origin.x = room.maxX - m - f.width; moved = true }
        if near(f.minY - room.minY - m) { f.origin.y = room.minY + m; moved = true }
        else if near(room.maxY - m - f.maxY) { f.origin.y = room.maxY - m - f.height; moved = true }
        return moved
    }

    /// The grabber over the chat's header, with the size button: it moves the chat too, and a double tap switches size.
    private func grabber(large: Bool) -> some View {
        ZStack {
            Capsule().fill(.secondary.opacity(0.45)).frame(width: 44, height: 5)
            HStack {
                Spacer()
                Button(large ? "Smaller" : "Larger", systemImage: large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    toggleSize(large: large)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption.bold())
                .frame(minWidth: 44, minHeight: 28)
                .contentShape(Rectangle())
                .help(large ? "Make it small again" : "Make it large")
                .accessibilityIdentifier("side-chat-size")
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .onTapGesture(count: 2) { toggleSize(large: large) }
        .movesPanel()
        .accessibilityLabel("Side chat: drag to move")
    }

    /// The corner to resize it by: half outside the chat, so it takes no taps from the composer.
    private var resizeCorner: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(.regularMaterial, in: Circle())
            .overlay { Circle().strokeBorder(.separator) }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .offset(x: 16, y: 16)
            .gesture(
                // In the overlay's space too: the corner moves as the chat grows.
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                    .updating($growing) { value, state, _ in state = value.translation }
                    .onEnded { value in model.sideChatPanel = placed(frame, growing: value.translation) }
            )
            .accessibilityLabel("Resize the side chat")
    }

    /// Small, or large: the room's whole height, and its width up to a comfortable reading width.
    private func toggleSize(large: Bool) {
        let f = placed(frame)
        let size = large ? Self.small : CGSize(width: min(room.width - 2 * Self.margin, 760), height: room.height - 2 * Self.margin)
        withAnimation(.snappy) {
            // Grows toward the middle: its trailing edge stays where it is.
            model.sideChatPanel = placed(CGRect(x: f.maxX - size.width, y: large ? f.minY : room.minY + Self.margin, width: size.width, height: size.height))
        }
    }
}

/// What the floating side chat shows: the chat itself, in a view of its own, so moving the panel doesn't redraw it.
private struct FloatingChatContent: View {
    @Environment(AppModel.self) private var model
    let ref: SideChatRef

    var body: some View {
        SideChatView(ref: ref, close: { model.sideChatSheet = nil })
    }
}
#endif
