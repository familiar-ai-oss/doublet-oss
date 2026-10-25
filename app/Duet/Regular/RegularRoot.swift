import DuetKit
import SwiftUI

/// iPad and Mac: a command center built around the conversation. Sidebar (what needs you, the conversations, and a
/// small system area: the fleet and terminals) · the conversation in the centre, always · beside it, its cards (plan,
/// diagrams, notes, changes, workers) or the side stage, whose tabs hold what supports it · a terminal panel under them
/// (⌘J). See docs/navigation.md.
struct RegularRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive
    /// A tab on its way somewhere in this window (lifted on iPad, dragged on the Mac).
    @State private var drag = TabDrag()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            // Steps inside a pane (a folder's file, a note) open as places of their own instead of being pushed here,
            // so Back and Forward are the one way back.
            NavigationStack(path: Binding(get: { [FilesRoute]() }, set: { if let route = $0.last { model.show(route.place) } })) {
                DetailView()
            }
        }
        // Columns side by side (never an overlay that hides the conversation), in portrait too.
        .navigationSplitViewStyle(.balanced)
        // The tab commands (Show Next Tab, Move Tab to New Window, Close Tab) apply while this window has the focus.
        .focusedSceneValue(\.mainWindow, true)
        .background { CloseTabShortcut() }
        .switcherHost()
        // Back in front: its tab is the most recent place, for ⌃Tab; and a squeeze of Apple Pencil Pro lifts its tabs.
        .onChange(of: appearsActive, initial: true) { _, active in
            guard active else { return }
            model.windowActivated(nil)
            TabDrag.underPencil = drag
            drag.choose = { [model] target, tab in withAnimation(.snappy) { model.perform(target, with: tab) } }
        }
        #if os(iOS)
        .background { SceneReader { model.mainScene = $0 } }
        #else
        .background { WindowReader { model.mainWindowRef = $0 } }
        #endif
        .sheet(isPresented: $model.showPalette) { CommandPalette() }
        .sheet(isPresented: $model.showQuickOpen) { QuickOpen() }
        #if os(iOS)
        // Notes written on a code page, offered for tagging as it's left.
        .sheet(item: $model.tagReview) { TagReviewSheet(review: $0) }
        #endif
        #if os(macOS)
        // The Mac opens a side chat in a window of its own; this sheet is only for one asked for in place.
        .sheet(item: $model.sideChatSheet) { ref in
            SideChatView(ref: ref).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        #endif
        .diffPresentation()
        .windowRequests()
        #if os(iOS)
        // Apple Pencil Pro: squeeze over a tab to lift it, elsewhere for a side chat about what's on screen (where you
        // write, a squeeze sends your notes).
        .modifier(SqueezeForSideChat())
        // A lifted tab, following the finger or the Pencil.
        .overlay { LiftedTabGhost() }
        #endif
        .environment(drag)
    }
}

/// ⌘W in the main window closes the side stage's tab on show, as in Xcode and VS Code. With the side stage closed it
/// isn't here, so ⌘W goes on to the system's Close and the window closes. A shortcut of the window's own: in the menu
/// bar the system's Close holds ⌘W, and the key window sees a shortcut before the menu bar does.
private struct CloseTabShortcut: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.workspace.staged != nil, let tab = model.workspace.selected {
            Button("Close Tab") { model.close(tab) }
                .keyboardShortcut("w")
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: Conversation?
    @State private var showSettings = false
    /// The other sessions, the fleet and the terminals, folded into one row until opened.
    @AppStorage("sidebar.machines") private var machinesOpen = false

    var body: some View {
        Group {
            if model.sidebarMode == .explorer { ExplorerSidebar() } else { conversations }
        }
        // Claude's folder as a tree (⌘⇧E) opens from the Files row; from there, back to the conversations.
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.sidebarMode == .explorer {
                Button { model.sidebarMode = .chats } label: { Label("Conversations", systemImage: "chevron.backward") }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .accessibilityIdentifier("sidebar-back-to-conversations")
            }
        }
        .safeAreaInset(edge: .bottom) {
            ConnectionFooter()
                .padding(10)
                .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial) }
                .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .sheet(item: $renaming) { RenameConversationSheet(conversation: $0) }
        .navigationTitle("Doublet")
        #if os(iOS)
        // iPad: Settings is a sheet (the Mac has its own Settings window). It opens by itself until a token is saved.
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "gear") { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .onAppear { if !model.hasToken { showSettings = true } }
        #endif
    }

    private var conversations: some View {
        @Bindable var model = model
        let store = model.store
        let live = store.currentConversationId
        // The conversation in the centre is the one picked. The other rows open beside it, in the side stage.
        return List(selection: Binding(get: { Optional(model.workspace.centre) }, set: { if let place = $0 { model.show(place) } })) {
            Section {
                NavigationLink(value: Destination.inbox) {
                    Label {
                        Text("Needs you")
                    } icon: {
                        let waiting = store.attention.count + model.newAnswers.count
                        Image(systemName: waiting == 0 ? "tray" : "hand.raised.fill")
                            .foregroundStyle(waiting == 0 ? Color.secondary : Color.stateNeedsYou)
                    }
                    .keepsOnDoubleClick(.inbox)
                    .badge(store.attention.count + model.newAnswers.count)
                }
                .accessibilityIdentifier("sidebar-inbox")
            }
            // The live conversation first (where prompts go), then the earlier ones, newest first.
            Section {
                ForEach(model.conversationList) { c in
                    let isLive = c.id == live
                    let place = isLive ? Destination.lead : .conversation(c.id)
                    NavigationLink(value: place) { ConversationRow(conversation: c, live: isLive).keepsOnDoubleClick(place) }
                        .contextMenu {
                            ConversationMenuItems(conversation: c, live: isLive) { renaming = c }
                            if !isLive {
                                Button("Open in New Tab", systemImage: "plus.square.on.square") { model.show(place, keep: true) }
                            }
                            // Beside the conversation in the centre, to read the two side by side.
                            if place != model.workspace.centre {
                                Button("Open to the Right", systemImage: "rectangle.righthalf.inset.filled") { model.openBeside(place) }
                            }
                            Button("Open in New Window", systemImage: "macwindow.badge.plus") { model.openWindow(.conversation(c.id)) }
                        }
                        .accessibilityIdentifier(isLive ? "sidebar-lead" : "sidebar-conversation-\(c.id)")
                    // Its notes live on the code they're about, and its side chats inside it: nothing more here.
                }
                if live == nil {
                    Label("Waiting for Claude…", systemImage: "bubble.left").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Conversations")
                    Spacer()
                    // The old conversation stays in the list, resumable; no confirmation needed.
                    Button("New conversation", systemImage: "plus.bubble") { model.newConversation() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                        .disabled(store.leadStatus.busy)
                        .help("New conversation (⇧⌘N)")
                        .accessibilityIdentifier("sidebar-new-conversation")
                }
            }
            // The rest, at the bottom: Claude's folder, and the machines (sessions running elsewhere, the fleet, the
            // terminals) folded into one row.
            Section {
                Button { model.sidebarMode = .explorer } label: { Label("Files", systemImage: "folder") }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar-files")
                DisclosureGroup(isExpanded: $machinesOpen) { machines } label: {
                    Label {
                        HStack {
                            Text("Machines")
                            Spacer()
                            if !machinesOpen, let busy = busyMachines { Text(busy).font(.caption).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: "server.rack")
                            .foregroundStyle(store.workers.contains { $0.running != nil } ? Color.stateWorking : Color.secondary)
                    }
                }
                .accessibilityIdentifier("sidebar-machines")
            }
        }
        .listStyle(.sidebar)
    }
}

extension Sidebar {
    /// What's busy among the machines, for the folded row ("2 running"); nil when nothing is.
    fileprivate var busyMachines: String? {
        let n = model.store.workers.filter { $0.running != nil }.count + model.outsideSessions.filter { $0.status == "busy" }.count
        return n == 0 ? nil : "\(n) running"
    }

    /// Claude Code sessions running outside Duet on the hub machine, the fleet as one row, and the open terminals.
    @ViewBuilder fileprivate var machines: some View {
        let store = model.store
        ForEach(model.outsideSessions.prefix(5)) { s in
            Button { model.show(.outside(s.sessionId)) } label: { OutsideRow(session: s) }
                .buttonStyle(.plain)
                .font(.callout)
                .contextMenu {
                    Button("Open to the Right", systemImage: "rectangle.righthalf.inset.filled") { model.openBeside(.outside(s.sessionId)) }
                }
                .accessibilityIdentifier("sidebar-outside-\(s.sessionId)")
        }
        if model.outsideSessions.count > 5 {
            Button("\(model.outsideSessions.count - 5) more sessions") { model.showOverview() }
                .buttonStyle(.plain)
                .font(.caption).foregroundStyle(.secondary)
        }
        NavigationLink(value: Destination.fleet) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fleet")
                    Text(model.fleetSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } icon: {
                Image(systemName: "cpu")
                    .foregroundStyle(store.workers.contains { $0.running != nil } ? Color.stateWorking : Color.secondary)
            }
            .keepsOnDoubleClick(.fleet)
        }
        .accessibilityIdentifier("sidebar-fleet")
        ForEach(store.terminals) { t in
            NavigationLink(value: Destination.terminal(t.id)) {
                Label(t.title, systemImage: TerminalKinds.symbol(t.kind)).keepsOnDoubleClick(.terminal(t.id))
            }
            .contextMenu {
                Button("Open in New Tab", systemImage: "plus.square.on.square") { model.show(.terminal(t.id), keep: true) }
                OpenInWindowButton(terminalId: t.id)
                Button("Close", systemImage: "xmark") { model.send(.ptyClose(id: t.id)) }
            }
        }
        NewTerminalMenu().buttonStyle(.borderless).font(.callout)
    }
}

/// The sidebar's two views, as an editor's activity bar has them: the conversations, and Claude's folder.
struct SidebarModePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("Sidebar", selection: $model.sidebarMode) {
            Label("Conversations", systemImage: "bubble.left.and.text.bubble.right").tag(SidebarMode.chats)
            Label("Explorer", systemImage: "folder").tag(SidebarMode.explorer)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Conversations, or Claude's folder as a tree (⌘⇧E)")
        .accessibilityIdentifier("sidebar-mode")
    }
}

#if os(iOS)
/// Apple Pencil Pro's squeeze, where nothing else takes it: a side chat about what's on screen. Only when the
/// Pencil's squeeze is set to show a palette (Settings › Apple Pencil): a side chat is this app's palette.
struct SqueezeForSideChat: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.preferredPencilSqueezeAction) private var preferred

    func body(content: Content) -> some View {
        content.onPencilSqueeze { phase in
            guard case .ended = phase else { return }
            // Over a tab, it lifts the tab, to place with a tap.
            if model.squeezeLiftsTab() { return }
            guard preferred == .showContextualPalette, model.pencilSurfaces == 0, model.sideChatSheet == nil else { return }
            model.openSideChat(about: model.currentAbout)
        }
    }
}
#endif

/// Opens a terminal in its own window (Mac, and iPad with more than one window). Open in a tab, the tab moves there.
struct OpenInWindowButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.supportsMultipleWindows) private var multi
    let terminalId: String

    var body: some View {
        if multi {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") { model.openWindow(.pane(.terminal(terminalId))) }
        }
    }
}

extension View {
    /// A sidebar row: a single click opens its place as a preview tab; a double-click keeps the tab, as in an editor.
    func keepsOnDoubleClick(_ place: Destination) -> some View {
        modifier(KeepsOnDoubleClick(place: place))
    }
}

private struct KeepsOnDoubleClick: ViewModifier {
    @Environment(AppModel.self) private var model
    let place: Destination

    func body(content: Content) -> some View {
        content.simultaneousGesture(TapGesture(count: 2).onEnded { model.show(place, keep: true) })
    }
}

/// The main window's centre: the conversation, always (the live one, an earlier one, or a side chat), and beside it
/// its cards or the side stage, where what supports it opens (files, diagrams, workers, terminals, notes, the plan).
/// The terminal panel is under them, staying while the rest changes. In a narrow window (iPad portrait) the cards are
/// a popover and the side stage comes over the conversation.
struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(TabDrag.self) private var drag
    @Environment(\.density) private var density
    @State private var width: CGFloat = 0

    /// Wide enough for the conversation with its cards or the side stage beside it.
    static let wideWidth: CGFloat = 800

    private static var backPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    var body: some View {
        @Bindable var model = model
        let workspace = model.workspace
        let wide = model.isWide
        let overview = workspace.overviewOnly
        let shown = model.panelVisible
        let zoomed = shown && workspace.zoom != nil
        VStack(spacing: 0) {
            // The side stage stays one view whether it's beside the conversation or over it, so what it shows (a
            // scroll position, a note being written) survives the window changing width.
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    CentrePane()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Folded away while the side stage fills the window: it stays as it was, under it, unseen
                        // (the toolbar's glass would show it).
                        .opacity(zoomed ? 0 : 1)
                        .accessibilityHidden(zoomed)
                        // While a tab is on its way, the tray over it takes the drag, not what the conversation shows.
                        .allowsHitTesting(!drag.isActive)
                        // Where a tab on its way can go, besides the side stage's halves.
                        .overlay {
                            if wide, !zoomed {
                                ZStack {
                                    PlacingDismiss()
                                    CentreDropTray()
                                }
                            }
                        }
                    if wide, shown, !zoomed {
                        // Room for the side stage, which is drawn over it.
                        Color.clear.frame(width: SideStage.width(available: width, share: model.stageShare, overview: overview, dense: density == .dense))
                    }
                }
                if !wide, shown, !zoomed {
                    // Over the conversation, which shows at the edge: a tap there puts the side stage away.
                    Color.black.opacity(0.12)
                        .contentShape(Rectangle())
                        .onTapGesture { if overview { model.overviewOverNarrow = false } else { model.hidePanel() } }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
                if shown {
                    SideStage(available: width, overlay: !wide)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if !wide || zoomed {
                    CentreDropTray().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                // Last, so its buttons end the toolbar, after what the side stage shows adds.
                TrailingToolbar()
            }
            #if os(iOS)
            // A side chat floats over the conversation and the side stage, to move and resize like a small window
            // (it can still go to a tab, or a window of its own).
            .overlay {
                if let ref = model.sideChatSheet {
                    // Below the toolbar, which floats over the content, and above the keyboard.
                    // The overlay is laid out inside the safe area already: below the toolbar, above the keyboard and
                    // right of the sidebar. (Its safe area insets are the window's, so adding them counted the toolbar
                    // and the keyboard twice, and the chat couldn't go near either.)
                    GeometryReader { geo in
                        FloatingSideChat(ref: ref, room: CGRect(origin: .zero, size: geo.size),
                                         origin: geo.frame(in: .global).origin)
                    }
                    // Its drags are measured here, where nothing moves with them.
                    .coordinateSpace(.named(FloatingSideChat.space))
                    .transition(.opacity)
                }
            }
            .animation(.snappy, value: model.sideChatSheet)
            #endif
            // The conversation, folded while the side stage fills the window: the way back to it.
            .overlay(alignment: .bottomLeading) { if zoomed { ConversationCapsule() } }
            .animation(.snappy, value: zoomed)
            // Answers to what you asked, as sticky notes: over the side stage's foot, or above the composer.
            .overlay { StickyLayer(bottom: wide && shown ? 0 : 64) }
            // Under the toolbar: a place sent to another device, or one that came from one.
            .overlay(alignment: .top) { NoticeBanner() }
            .animation(.snappy, value: model.notice)
            .animation(.snappy(duration: 0.25), value: shown)
            .animation(.snappy(duration: 0.25), value: overview)
            if model.showTerminalPanel {
                PanelResizeHandle(height: $model.terminalPanelHeight)
                TerminalScreen().frame(height: model.terminalPanelHeight)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            width = w
            model.widthChanged(wide: w >= Self.wideWidth)
        }
        #if os(iOS)
        // The window's title is the conversation's; the side stage names what it shows in its own bar.
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Never shown: what's pushed opens as a place (RegularRoot), but links need a destination to be active.
        .filesDestinations()
        .toolbar {
            // Back to where you were, by name, and forward again: across the conversation and the side stage. At the
            // leading edge on iPad too, where `.navigation` items go to the trailing end while the sidebar is hidden.
            ToolbarItemGroup(placement: Self.backPlacement) {
                if let back = model.backName {
                    Button { model.goBack() } label: {
                        Label(back, systemImage: "chevron.backward")
                    }
                    #if os(iOS)
                    .labelStyle(.titleAndIcon)
                    #endif
                    .help("Back to \(back) (⌘[)")
                    .accessibilityLabel("Back to \(back)")
                }
                if let forward = model.forwardName {
                    Button("Forward", systemImage: "chevron.forward") { model.goForward() }
                        .help("Forward to \(forward) (⌘])")
                }
            }
            .visibilityPriority(.high)
        }
    }
}

/// The main window's own toolbar buttons, after the conversation's and the side stage's: the terminal panel and the
/// cards, at the trailing end, over the side of the window the cards are on. A toolbar lists items in the order of the
/// views that give them, so these come from a view after both.
private struct TrailingToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Color.clear
            .frame(width: 0)
            .accessibilityHidden(true)
            .toolbar {
                ToolbarItemGroup {
                    // The terminal panel is in a conversation's More menu (and ⌘J).
                    InspectorToggle().labelStyle(.titleAndIcon)
                }
                .visibilityPriority(.high)
            }
    }
}

/// The conversation in the centre, with a bar above it that leads back when it isn't the live conversation.
struct CentrePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let centre = model.workspace.centre
        Group {
            // A side chat names its conversation in the window's subtitle (it sets no subtitle of its own, and the
            // side stage's would show).
            if case .sideChat = centre, let c = model.conversationPlace(of: centre) {
                PaneContent(place: centre).navigationSubtitle("Side chat · \(model.title(of: c))")
            } else if case .note = centre, let c = model.conversationPlace(of: centre) {
                PaneContent(place: centre).navigationSubtitle("Thread · \(model.title(of: c))")
            } else {
                PaneContent(place: centre)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if centre != .lead { CentreBar(place: centre) }
        }
    }
}

/// Above a conversation in the centre that isn't the live one: where it is (an earlier conversation, or a side chat
/// under the conversation it belongs to, a step back), and the way to the live conversation.
struct CentreBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let place: Destination

    var body: some View {
        HStack(spacing: 0) {
            LocationBar(place: place, fromConversation: true)
            if model.conversationPlace(of: place) != .lead {
                Button { model.show(.lead) } label: { Label("Live Conversation", systemImage: "sparkles") }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .font(density == .dense ? .caption : .footnote)
                    .padding(.horizontal, 12)
                    .help("Back to the live conversation, where your messages go")
                    .accessibilityIdentifier("centre-live")
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("centre-bar")
    }
}

/// What a place shows: in the main window's centre or a pane of its side stage, or (`inWindow`) in a window of its own.
struct PaneContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.inSidePanel) private var inSidePanel
    let place: Destination
    var inWindow = false

    var body: some View {
        switch place {
        case .inbox: InboxScreen()
        case .lead:
            if inWindow { ConversationPane(id: model.store.currentConversationId) } else if inSidePanel { SideConversation(id: nil) } else { LeadScreen() }
        case .conversation(let id):
            if inWindow { ConversationPane(id: id) } else if inSidePanel { SideConversation(id: id) }
            else { LeadScreen(conversationId: model.store.conversation(id) == nil ? nil : id) }
        case .fleet: FleetScreen()
        case .worker(let id): WorkerDetail(workerId: id).id(id)
        case .terminal(let id): TerminalPane(id: id).id(id)
        case .diagram(let id): DiagramScreen(diagramId: id).id(id)
        case .files(let root): FilesRoot(path: root).id(root)
        case .file(let path, let line): FileViewer(path: path, line: line).id(path)
        case .notes(let filter): AnnotationsList(filter: filter).id(filter)
        case .note(let id): AnnotationDetail(id: id).id(id)
        case .sideChat(let id): SideChatView(ref: SideChatRef(chatId: id), inWindow: inWindow, docked: !inWindow).id(id)
        case .plan(let id): PlanPane(conversationId: id).id(id)
        case .diff(let task, let worker): DiffScreen(taskId: task, worker: worker, inSheet: false).id(task)
        case .outside(let id): OutsideSessionView(id: id).id(id)
        }
    }
}

/// A conversation in a pane of the side stage, to read beside the one in the centre: the live one with its composer,
/// or an earlier one with Resume. Its name is in the pane's bar; the window's title and toolbar stay the centre's.
struct SideConversation: View {
    @Environment(AppModel.self) private var model
    /// nil: the live conversation.
    let id: String?

    var body: some View {
        let store = model.store
        let live = id == nil || id == store.currentConversationId
        if live || id.flatMap({ store.conversation($0) }) != nil {
            LeadThread(conversationId: live ? nil : id)
                .id(id ?? "live")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if live { Composer() } else if let id { ResumeBar(conversationId: id) }
                }
        } else {
            ContentUnavailableView("No such conversation", systemImage: "bubble.left")
        }
    }
}

/// The conversation, folded away while the side stage fills the window: its name, and a dot while Claude works in it.
/// Tap it (or press Escape, or ⌃⌘↩) to put it back beside the side stage.
private struct ConversationCapsule: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let centre = model.workspace.centre
        Button { model.zoomStage(nil) } label: {
            HStack(spacing: 10) {
                Image(systemName: model.symbol(of: centre)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Conversation").font(.caption2).foregroundStyle(.secondary)
                    Text(model.title(of: centre)).font(.callout.weight(.medium)).lineLimit(1)
                }
                if model.isBusy(centre) { Circle().fill(Color.stateWorking).frame(width: 7, height: 7) }
                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.caption.bold()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: 340, alignment: .leading)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.separator) }
            .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .padding(16)
        .help("Bring the conversation back beside the side panel (Escape, ⌃⌘↩)")
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityLabel("Conversation: \(model.title(of: centre)). Bring it back")
        .accessibilityIdentifier("conversation-capsule")
    }
}

/// A terminal filling its pane, while its shell runs.
struct TerminalPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.inSidePanel) private var inSidePanel
    let id: String

    var body: some View {
        if let t = model.store.terminals.first(where: { $0.id == id }) {
            let screen = TerminalScreen(fixedId: id, showsTabs: false).navigationTitle(t.title)
            // Its window's bar goes dark over it; in the side stage, the window's bar is the conversation's.
            if inSidePanel { screen } else { screen.terminalChrome() }
        } else {
            ContentUnavailableView("Terminal closed", systemImage: "terminal")
        }
    }
}

/// A conversation's plan on its own: a tab, or a small window beside the app, like a widget.
struct PlanPane: View {
    @Environment(AppModel.self) private var model
    let conversationId: String

    var body: some View {
        Group {
            #if os(iOS)
            // iPad: a page Apple Pencil writes on, as code and diagrams are (a question on a step, or a redirect).
            if UIDevice.current.userInterfaceIdiom == .pad, model.hubTakesPlanNotes, !model.store.planItems(conversationId).isEmpty {
                PlanInkSurface(conversationId: conversationId)
            } else {
                list
            }
            #else
            list
            #endif
        }
        .navigationTitle("Plan")
        .navigationSubtitle(model.conversationTitle(conversationId))
    }

    private var list: some View {
        ScrollView {
            PlanList(conversationId: conversationId)
                .frame(maxWidth: 760, alignment: .leading)
                .padding(16)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A conversation's thread with its controls in the toolbar: the live one with the composer, or an earlier one
/// read-only with Resume.
struct LeadScreen: View {
    @Environment(AppModel.self) private var model
    /// nil: the live conversation.
    var conversationId: String? = nil
    @State private var confirmNew = false

    var body: some View {
        @Bindable var model = model
        let store = model.store
        let isLive = conversationId == nil || conversationId == store.currentConversationId
        let conversation = (conversationId ?? store.currentConversationId).flatMap { store.conversation($0) }
        LeadThread(conversationId: conversationId)
            .id(conversationId ?? "live") // a fresh scroll position and expansion state per conversation
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isLive { Composer(showsContext: true) } else if let id = conversationId { ResumeBar(conversationId: id) }
            }
        .navigationTitle(model.conversationTitle(conversationId ?? store.currentConversationId))
        // On iPad too: the window's subtitle is the conversation's, not what the side stage shows.
        .navigationSubtitle(isLive ? (store.leadStatus.busy ? store.leadStatus.label : model.leadModelName)
                                   : "Read-only" + (conversation.map { " · last active \($0.lastActivity.formatted(.relative(presentation: .named)))" } ?? ""))
        .toolbar {
            ToolbarItemGroup {
                // Where Claude works on the hub machine (or worked, in an earlier conversation): its files.
                if let cwd = isLive ? store.leadCwd : conversation?.cwd {
                    Button { model.openFiles(isLive ? nil : cwd, compact: false) } label: { Label(Paths.name(cwd), systemImage: "folder") }
                        .labelStyle(.titleAndIcon)
                        .help("\(isLive ? "Claude works" : "Claude worked") in \(Paths.short(cwd)). Show its files.")
                }
                // Claude: its model, effort and mode, in one menu named for the model.
                if isLive {
                    Menu {
                        LeadModelMenu()
                        LeadEffortMenu()
                        LeadModeMenu()
                    } label: { Label(model.leadModelName, systemImage: "sparkles") }
                        .labelStyle(.titleAndIcon)
                        .help("Claude's model, effort and permission mode")
                } else if let id = conversationId {
                    Button("Resume", systemImage: "arrow.uturn.backward.circle") { Task { _ = await model.resume(id) } }
                        .labelStyle(.titleAndIcon)
                        .disabled(store.leadStatus.busy || model.resumePending == id)
                        .help("Continue this conversation")
                }
            }
            // Everything else, in one menu.
            ToolbarItemGroup {
                Menu {
                    if isLive {
                        SideChatToolbarButton()
                        Button("Compact", systemImage: "rectangle.compress.vertical") { model.send(.compact) }
                            .disabled(store.leadStatus.busy)
                            .help("Summarize the conversation to free context")
                        Button("New Conversation", systemImage: "plus.bubble") { confirmNew = true }
                            .disabled(store.leadStatus.busy)
                            .help("Start a new conversation; this one stays in the sidebar (⇧⌘N)")
                    }
                    // This conversation on the iPad (or Mac).
                    SendToDevice(place: isLive ? .lead : conversationId.map { .conversation($0) } ?? .lead)
                    Toggle(isOn: $model.showTerminalPanel) { Label("Terminal Panel", systemImage: "terminal") }
                } label: { Label("More", systemImage: "ellipsis.circle") }
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("conversation-more")
            }
            .visibilityPriority(.low)
        }
        .confirmationDialog("Start a new conversation?", isPresented: $confirmNew, titleVisibility: .visible) {
            Button("New Conversation") { model.newConversation() }
        } message: {
            Text("This conversation stays in the sidebar and can be resumed. Workers and terminals are unaffected.")
        }
    }
}

/// Drag to resize the terminal panel. On iPad it's a finger's height, with a grabber.
struct PanelResizeHandle: View {
    @Binding var height: CGFloat
    @State private var start: CGFloat?

    private static var reach: CGFloat {
        #if os(iOS)
        28
        #else
        7
        #endif
    }

    var body: some View {
        Rectangle().fill(.separator).frame(height: 1)
            .frame(maxWidth: .infinity)
            .frame(height: Self.reach)
            #if os(iOS)
            .overlay { Capsule().fill(.secondary.opacity(0.4)).frame(width: 44, height: 5) }
            #endif
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(.rowResize)
            #endif
            // In the window's space: measured in its own, which moves with the panel's edge, the drag shook.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { g in
                let s = start ?? height
                start = s
                height = min(720, max(140, s - g.translation.height))
            }.onEnded { _ in start = nil })
            .accessibilityHidden(true)
    }
}

/// Every decision waiting on you, as a grid of cards.
struct InboxScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LeadStatusCard()
                NewAnswers()
                AttentionList(emptyText: model.newAnswers.isEmpty ? "Nothing needs you right now." : "Nothing else needs you.")
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .swipeActionsContainer()
        .navigationTitle("Needs you")
    }
}

/// Answers to questions you asked, not yet seen: one short row each, opening the file at the question's line (where
/// the answer opens under it). Seen, a row leaves.
struct NewAnswers: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let answers = model.newAnswers
        if !answers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("New answers").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(answers) { a in
                    Button { open(a) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place(a)).font(.subheadline.weight(.semibold))
                            Text(FileViewer.gist(a.answer ?? "")).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .card()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// "Answer on Lexer.swift:21".
    private func place(_ a: Annotation) -> String {
        if case .file(let path) = a.surface {
            return "Answer on \(Paths.name(path))" + (a.lines?.first.map { ":\($0.start)" } ?? "")
        }
        return "Answer to “\(NoteGist.fallback(a.text ?? "your question"))”"
    }

    private func open(_ a: Annotation) {
        if case .file(let path) = a.surface {
            model.open(.file(path, line: a.lines?.first?.start), compact: false)
        } else {
            model.open(.note(a.id), compact: false)
        }
        model.sawAnswers([a.id])
    }
}

/// The conversation's cards: the side stage's Overview, or the side stage hidden when that's what it shows already.
struct InspectorToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Toggle(isOn: Binding(get: { model.panelVisible && model.workspace.overviewPane != nil }, set: { _ in model.toggleCards() })) {
            Label("Details", systemImage: "sidebar.trailing")
        }
        .help("This conversation's Overview: its plan, diagrams, notes and changes, as cards (⌘⌥I)")
        .accessibilityIdentifier("inspector-toggle")
    }
}
