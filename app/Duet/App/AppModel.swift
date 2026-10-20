import DuetKit
import Foundation
import Observation
import OSLog
import Security
import SwiftUI

/// A place you can open: a tab in the main window, a window of its own, or (iPhone) the tab that owns it.
enum Destination: Hashable, Codable {
    /// `lead`: the live conversation; `conversation`: an earlier one, read-only until resumed.
    /// `fleet`: every worker and its controls; `worker`: one of them.
    case inbox, lead, conversation(String), fleet, worker(String), terminal(String), diagram(String)
    /// The file viewer at a folder (nil: Claude's), and one file (at a line: shown and picked).
    case files(String?)
    case file(String, line: Int? = nil)
    /// Kept notes (every one, or those on a file or a diagram), and one note with Claude's answer.
    case notes(NotesFilter), note(String)
    /// A side chat that's been asked, and a conversation's plan.
    case sideChat(String), plan(String)
    /// What a worker's task changed (its diff), to read and write on.
    case diff(String, worker: String)
    /// A Claude Code session running outside Duet on the hub machine (in Claude Desktop, a terminal, the background), followed live.
    case outside(String)
}

/// What the sidebar shows: the conversations, or Claude's folder as a tree (an editor's explorer). ⌘⇧E switches.
enum SidebarMode: String {
    case chats, explorer
}

/// A side chat to show: one already asked (`chatId`), or a new one about something (nil: the conversation). The same
/// chat is the same value, so opening it again brings its window forward.
struct SideChatRef: Codable, Hashable, Identifiable {
    var id: String
    var chatId: String?
    var about: SideAbout?

    init(chatId: String? = nil, about: SideAbout? = nil) {
        self.id = chatId ?? "new-\(UUID().uuidString)"
        self.chatId = chatId
        self.about = about
    }
}

/// A pane docked from its window into the main window (`n` tells one docking from the next).
struct Docked: Equatable {
    let place: Destination
    let n: Int
}

/// A window to open, asked for by a menu, a command or a context menu (code without an openWindow action): a side
/// chat (a new one has no id yet), any other place, or a main window when none is open.
enum WindowRequest: Equatable {
    case side(SideChatRef), pane(Destination), main

    static func file(_ path: String) -> WindowRequest { .pane(.file(path)) }
    static func conversation(_ id: String) -> WindowRequest { .pane(.conversation(id)) }
    static func diagram(_ id: String) -> WindowRequest { .pane(.diagram(id)) }
}

/// The navigation stack of a window that shows a pane on its own (a file window), so what it opens stays in it.
@MainActor
@Observable
final class FilesStack {
    var path: [FilesRoute] = []
}

/// A step into the file viewer: a folder, a file (at a line), a kept note, or a list of notes.
enum FilesRoute: Hashable {
    case folder(String)
    case file(String, line: Int? = nil)
    case note(String)
    case notes(NotesFilter)
}

/// A diagram open full screen (iPhone; iPad and Mac show diagrams in the side stage).
struct DiagramRef: Identifiable, Hashable { let id: String }
/// An element of a diagram to pick as it opens.
struct DiagramFocus: Equatable { let diagram: String; let element: String }

/// One of a conversation's threads: a note (handwritten or typed, on a line, a diagram element or a diff), or a side
/// chat (about the conversation, a reply, a step).
enum SideThread: Identifiable {
    /// A note, and the side chat its replies are in, once it has any.
    case note(Annotation, replies: SideChat?)
    case chat(SideChat)

    var id: String {
        switch self {
        case .note(let a, _): "note-\(a.id)"
        case .chat(let c): "chat-\(c.id)"
        }
    }

    var place: Destination {
        switch self {
        case .note(let a, _): .note(a.id)
        case .chat(let c): .sideChat(c.id)
        }
    }

    var date: Date {
        switch self {
        case .note(let a, let replies): max(a.date, replies?.startedAt ?? a.date)
        case .chat(let c): c.startedAt
        }
    }

    /// Waiting for an answer: to the note, or to a reply in it.
    var waiting: Bool {
        switch self {
        case .note(let a, let replies): (!a.answered && !a.resolved) || replies?.isAnswering == true
        case .chat(let c): c.isAnswering
        }
    }

    /// The replies asked in a note's thread.
    var replyCount: Int {
        guard case .note(_, let replies?) = self else { return 0 }
        return replies.messages.filter { $0.isUser && $0.fromNote != true }.count
    }
}

/// What the side stage shows, offered by the composer as a chip and sent first with the message (unless removed), so
/// Claude knows what a question is about: "About Lexer.swift:27 (`…`): ".
struct ComposerContext: Equatable {
    /// Which thing, and what's picked in it: a chip removed comes back when this changes.
    let id: String
    let label: String
    let symbol: String
    /// What goes before the message.
    let prompt: String
}
/// A task's diff, open full screen (iOS) or as a sheet (Mac).
struct DiffRef: Identifiable, Hashable { let taskId: String; let worker: String; var id: String { taskId } }

enum PhoneTab: Hashable {
    case now, chat, workers, files, terminal
}

/// Hub settings, the live store, and UI state shared by every layout. The device token lives in the Keychain;
/// URL and device name in UserDefaults.
@MainActor
@Observable
final class AppModel {
    let store = DuetStore()
    /// This device's on-device model: the hub's Apple worker tasks, one-line summaries, routing suggestions.
    let apple = AppleIntelligence()
    /// Better names for long-question side chats, made on this device and shared through the hub.
    let sideTitles = SideChatTitles()
    /// Conversation names, made on this device.
    let titles = ConversationTitles()
    @ObservationIgnored private var wasConnected = false
    var hubURL: String = UserDefaults.standard.string(forKey: "hubURL") ?? AppIdentity.defaultHubURL
    var device: String = UserDefaults.standard.string(forKey: "device") ?? AppModel.defaultDevice
    var hasToken = false
    /// A test run's token (debug builds, from the launch environment), kept out of the Keychain.
    private var testToken: String?
    private var token: String? { testToken ?? Keychain.load(account: device) }
    var lastError: String?

    // Navigation and layout
    /// The main window's layout (iPad and Mac): the conversation in the centre, the side stage's tabs beside it, and
    /// the places floating in windows of their own.
    let workspace = Workspace(savingAs: AppModel.inPreview ? nil : AppModel.workspaceKey)

    /// Where the main window is: what its side stage shows, else the conversation in the centre. Setting it goes
    /// there, as `show` does.
    var destination: Destination? {
        get { workspace.front }
        set { if let newValue { show(newValue) } }
    }
    private(set) var backStack: [Location] = []
    private(set) var forwardStack: [Location] = []
    @ObservationIgnored private var steppingHistory = false

    /// A debug build keeps tabs of its own: it shares the installed app's settings. A test run with the sample
    /// conversation (DUET_DEMO) keeps its own too, so what it opens never comes back in the app you use.
    #if DEBUG
    static let workspaceKey = ProcessInfo.processInfo.environment["DUET_DEMO"] == "1" ? "workspace.demo" : "workspace.debug"
    #else
    static let workspaceKey: String = {
        #if os(macOS)
        // Once, the first time a Release build runs where a debug build ran before: the debug build's tabs (saved under
        // its own key) come along.
        let d = UserDefaults.standard
        if !d.bool(forKey: "workspace.tookDebugTabs") {
            d.set(true, forKey: "workspace.tookDebugTabs")
            if let tabs = d.data(forKey: "workspace.debug") { d.set(tabs, forKey: "workspace") }
        }
        #endif
        return "workspace"
    }()
    #endif

    /// Go to a place: a conversation in the centre; anything else in the side stage, beside it (its tab selected, or a
    /// new one, a preview unless `keep`); or its window forward when it floats in a window of its own. Back remembers
    /// where you were.
    func show(_ place: Destination, keep: Bool = false) {
        ProblemReports.note("show \(Self.problemName(place))")
        var place = place
        // The live conversation's own id is the live tab.
        if case .conversation(let id) = place, id == store.currentConversationId { place = .lead }
        if place != .lead, let window = workspace.window(for: place) {
            windowRequest = window
            return
        }
        moving {
            workspace.open(place, keep: keep)
            // A note's thread in the centre has what it's written on beside it.
            if case .note(let id) = place, let on = anchor(ofNote: id) {
                if case .diagram(let d) = on, let element = store.annotations[id]?.elements?.first?.id {
                    diagramFocus = DiagramFocus(diagram: d, element: element)
                }
                workspace.open(on)
            }
        }
    }

    /// What a note is written on, as a place: the file at its first line, the diagram, the diff.
    func anchor(ofNote id: String) -> Destination? {
        guard let a = store.annotations[id] else { return nil }
        switch a.surface {
        case .file(let path): return .file(path, line: a.lines?.first?.start)
        case .diagram(let d, _, _): return .diagram(d)
        case .diff(let task, let worker): return worker.map { .diff(task, worker: $0) }
        case .plan(let conversationId): return .plan(conversationId)
        }
    }

    /// Where a note is, for its thread's name: "Lexer.swift:57", "“InString” in Lexer states", "Token.swift:12 in the diff".
    func noteAnchorName(_ a: Annotation) -> String {
        let line = a.lines?.first.map { "\(Paths.name($0.file)):\($0.start)\($0.end > $0.start ? "–\($0.end)" : "")" }
        switch a.surface {
        case .file(let path): return line ?? Paths.name(path)
        case .diagram(_, _, let title):
            let on = a.elements?.first.map { "“\($0.label ?? $0.id)”" }
            return [on, title].compactMap { $0 }.joined(separator: " in ")
        case .diff: return line.map { "\($0) in the diff" } ?? "the diff"
        case .plan:
            // The step it's on: "“Refactor the lexer…” in the plan".
            let step = a.elements?.first.map { $0.label ?? $0.id }.map { $0.count > 40 ? String($0.prefix(39)) + "…" : $0 }
            return step.map { "“\($0)” in the plan" } ?? "the plan"
        }
    }

    /// Change the layout, then follow wherever that leaves the main window.
    private var sendingReports = false
    private func sendProblemReports() {
        guard case .connected = store.connection, !sendingReports else { return }
        sendingReports = true
        Task {
            await ProblemReports.shared.flush { [store] in try await store.send($0) }
            sendingReports = false
        }
    }

    /// A place as a freeze report names it: its kind, and a short id (never a file's contents).
    static func problemName(_ place: Destination) -> String {
        String(String(describing: place).prefix(90))
    }

    func moving(_ change: () -> Void) {
        let before = workspace.location
        change()
        let here = workspace.location
        ProblemReports.screen(Self.problemName(workspace.front))
        // The cards and filters follow the conversation in the centre (a side chat's own conversation).
        selectedConversation = conversationId(in: here.centre)
        // Back and forward, as in a browser or VS Code: every place you go is remembered, across tabs.
        guard !steppingHistory, before != here else { return }
        backStack.append(before)
        if backStack.count > 50 { backStack.removeFirst(backStack.count - 50) }
        forwardStack.removeAll()
    }

    /// The conversation a place in the centre belongs to; nil for the live one.
    func conversationId(in centre: Destination) -> String? {
        let id: String? = switch centre {
        case .conversation(let id): id
        case .sideChat(let s): store.sideChats[s]?.conversationId
        default: nil
        }
        return id == store.currentConversationId ? nil : id
    }

    func select(_ tab: PaneTab) { moving { workspace.select(tab.id) } }
    func close(_ tab: PaneTab) { moving { workspace.close(tab.id) } }
    func closeOthers(_ tab: PaneTab) { moving { workspace.closeOthers(tab.id) } }
    func keep(_ tab: PaneTab) { workspace.keep(tab.id) }
    /// The next tab (+1) or the previous one (-1).
    func stepTab(_ delta: Int) { moving { workspace.step(delta) } }

    /// The side stage on its Overview, the conversation's cards: the list to go back to and pick another. Asked for, it
    /// comes over the conversation in a narrow window too.
    func showOverview() {
        moving { workspace.showOverview() }
        overviewOverNarrow = true
    }

    /// The side stage hidden (its tabs kept) or shown again as it was. Not steps of Back and Forward.
    func hidePanel() { workspace.hidePanel() }
    func showPanel() { workspace.showPanel() }

    /// The cards (⌘⌥I, and the toolbar's button): the side stage's Overview, or put away when that's what shows already
    /// (its pane closed, when the side stage is split).
    func toggleCards() {
        if panelVisible, let pane = workspace.overviewPane {
            if workspace.split != nil { workspace.closePane(pane) } else if isWide { hidePanel() } else { overviewOverNarrow = false }
        } else {
            showOverview()
        }
    }

    /// The side stage on screen now: as you left it, except that a narrow window (iPad portrait with the sidebar) keeps
    /// its Overview away, so the conversation has the width, until you ask for it. That isn't saved: the next wide
    /// window, or the next launch, shows it again.
    var panelVisible: Bool {
        workspace.panelShown && (isWide || !workspace.overviewOnly || overviewOverNarrow)
    }

    /// In a narrow window, the Overview was asked for: it comes over the conversation.
    var overviewOverNarrow = false

    /// The main window's centre is wide enough for the side stage beside the conversation, or it isn't.
    func widthChanged(wide: Bool) {
        guard !measuredWidth || wide != isWide else { return }
        measuredWidth = true
        isWide = wide
        overviewOverNarrow = false
    }

    @ObservationIgnored private var measuredWidth = false

    /// A preview tab you're writing on or asking about stays: the next thing opened gets a tab of its own.
    func keepOpen(_ place: Destination?) {
        guard let place, let tab = workspace.tab(for: place), tab.isPreview else { return }
        keep(tab)
    }

    /// A tab into a window of its own (undock).
    func undock(_ tab: PaneTab) { openWindow(.pane(tab.place)) }

    /// The conversation in the centre, in a window of its own as well. A side chat moves there, and its conversation
    /// takes the centre.
    func undockCentre() {
        switch workspace.centre {
        case .lead: if let live = store.currentConversationId { openWindow(.conversation(live)) }
        case .conversation(let id): openWindow(.conversation(id))
        case .sideChat(let id): openWindow(.side(SideChatRef(chatId: id)))
        default: break
        }
    }

    /// A floating pane back in the main window, as a kept tab of the side stage after the selected one, selected (dock);
    /// a conversation in the centre. Its window closes itself when it sees `docked`.
    func dock(_ place: Destination) {
        dock(place) { workspace.open($0, keep: true) }
    }

    /// The same, for a window's pane dropped on the tab bar: before the tab `before` (nil: after the last).
    func dock(_ place: Destination, droppedBefore before: PaneTab.ID?) {
        dock(place) { workspace.drop($0, id: PaneTab.ID(), before: before) }
    }

    private func dock(_ place: Destination, into change: (Destination) -> Void) {
        var tabPlace = place
        // The live conversation's second window docks into the live tab.
        if case .conversation(let id) = place, id == store.currentConversationId { tabPlace = .lead }
        moving { change(tabPlace) }
        docked = Docked(place: place, n: (docked?.n ?? 0) + 1)
        // In full screen, closing a window shows the Home Screen: bring the main window back first.
        showMainWindow()
    }

    /// The last pane docked from its window: the window showing it closes.
    private(set) var docked: Docked?

    /// The main window to the front (from a window of its own; it's already there otherwise).
    func showMainWindow() {
        #if os(iOS)
        // At launch iPadOS may bring back only a pane's window: the main window's scene is kept but not shown yet. If
        // there's none at all (closed in the app switcher), a new one opens.
        let open = UIApplication.shared.openSessions
        let main = mainScene.flatMap { open.contains($0) ? $0 : nil }
            ?? open.first { $0.userInfo?["com.apple.SwiftUI.sceneID"] as? String == "main" }
        if let main {
            if main.scene?.activationState != .foregroundActive {
                UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: main))
            }
        } else {
            windowRequest = .main
        }
        #else
        if let window = mainWindowRef, window.isVisible || window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
        } else {
            windowRequest = .main
        }
        #endif
    }

    /// Panes dropped on the tab bar, before the tab at `position` (nil: after the last). A tab from another main window
    /// moves there; a window's pane docks there, and its window closes.
    func drop(_ items: [PaneDrag], at position: ReorderDifference<PaneTab.ID, ReorderableSingleCollectionIdentifier>.Destination.Position?) {
        var before: PaneTab.ID?
        if case .before(let id) = position { before = id }
        for item in items {
            if item.fromWindow {
                dock(item.place, droppedBefore: before)
            } else {
                moving { workspace.drop(item.place, id: item.id, before: before) }
            }
        }
    }

    /// A window showing `place` opened. A tab showing the same place closes, so nothing's open twice: a tab dropped at
    /// the iPad's screen edge, which iPadOS opens in a window of its own.
    func floated(_ place: Destination, window: WindowRequest) {
        workspace.floated(place, window: window)
        if let tab = workspace.tab(for: place) { close(tab) }
    }

    /// A window came to the front: it's the most recent place, for the ⌃Tab switcher. The main window's is what its
    /// side stage shows, else its conversation.
    func windowActivated(_ place: Destination?) {
        workspace.touch(place ?? workspace.front)
    }

    /// What a tab carries when it's dragged.
    func drag(_ tab: PaneTab) -> PaneDrag { PaneDrag(id: tab.id, place: tab.place) }

    #if os(macOS)
    /// Where the window for a tab dragged out of the main window goes: the screen point it was dropped at.
    @ObservationIgnored private var undockPoint: CGPoint?
    /// The frame a tab's new window takes, in AppKit's screen coordinates (origin at the bottom left of the main
    /// display): half of a display (`tile`). Kept until the window appears, which takes it whatever display it's on.
    @ObservationIgnored private var undockFrames: [Destination: NSRect] = [:]

    /// Tabs dragged out of the tab bar and let go (Mac). At a display's left or right edge, the tab opens in a window on
    /// that half, and the main window takes the other, as iPad split view does. Elsewhere outside every Duet window,
    /// each opens in a window there, as in VS Code. Escape ends a drag with the button still down, and that keeps the
    /// tab where it was.
    func draggedOut(_ ids: [PaneTab.ID]) {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        let point = NSEvent.mouseLocation
        if ids.count == 1, let tab = workspace.tabs.first(where: { $0.id == ids[0] }), let edge = Self.edge(at: point) {
            tile(tab, leading: edge.leading, on: edge.screen)
            return
        }
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(point) }) else { return }
        for id in ids {
            guard let tab = workspace.tabs.first(where: { $0.id == id }) else { continue }
            undockPoint = point
            undock(tab)
        }
    }

    /// A display's left or right edge, where a tab let go goes to that half.
    private static func edge(at point: CGPoint) -> (screen: NSScreen, leading: Bool)? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return nil }
        if point.x - screen.frame.minX < 24 { return (screen, true) }
        if screen.frame.maxX - point.x < 24 { return (screen, false) }
        return nil
    }

    /// Half the screen (Mac), as iPad split view: the tab in a window of its own on the leading or trailing half of the
    /// display (the main window's, unless given), and the main window on the other half when it's on that display.
    func tile(_ tab: PaneTab, leading: Bool, on screen: NSScreen? = nil) {
        let main = Self.mainWindow
        guard let screen = screen ?? main?.screen ?? NSScreen.main else { return undock(tab) }
        let visible = screen.visibleFrame
        let half = visible.width / 2
        let left = NSRect(x: visible.minX, y: visible.minY, width: half, height: visible.height)
        let right = NSRect(x: visible.minX + half, y: visible.minY, width: visible.width - half, height: visible.height)
        undockFrames[tab.place.identity] = leading ? left : right
        if let main, main.screen == screen, !main.styleMask.contains(.fullScreen) {
            main.setFrame(leading ? right : left, display: true, animate: true)
        }
        undock(tab)
    }

    /// The main window in front (SwiftUI names its windows after their group: "main-AppWindow-1").
    private static var mainWindow: NSWindow? {
        let mains = NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
        return mains.first { $0.isKeyWindow } ?? mains.first { $0.isMainWindow } ?? mains.first
    }

    /// The frame a new window showing `place` takes, if its tab was tiled. Used once.
    func takeUndockFrame(for place: Destination) -> NSRect? {
        undockFrames.removeValue(forKey: place.identity)
    }

    /// The placement for a new window: at the point its tab was dropped, else `otherwise`. Used once. A tiled tab's
    /// window opens at its size here, and takes its frame as it appears (`takeUndockFrame`).
    func takeUndockPlacement(_ size: CGSize, display: DisplayProxy, otherwise: WindowPlacement) -> WindowPlacement {
        // A placement's coordinates are from the top left of the main display; AppKit's from its bottom left.
        let height = NSScreen.screens.first?.frame.height ?? display.bounds.height
        if let frame = undockFrames.values.first {
            return WindowPlacement(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
        }
        guard let point = undockPoint else { return otherwise }
        undockPoint = nil
        // The drop point is the window's top edge, under the pointer.
        return WindowPlacement(x: point.x - min(size.width / 2, 120), y: height - point.y - 12, width: size.width, height: size.height)
    }
    #endif

    /// Where Back goes, named for what changes there: the conversation, if it's another; else what the side stage
    /// shows then, or its Overview, or (the side stage hidden) the conversation. Places that are gone are skipped (a
    /// closed terminal).
    var backName: String? { backStack.last { stillThere($0) }.map(changes) }
    var forwardName: String? { forwardStack.last { stillThere($0) }.map(changes) }

    func goBack() { step(from: &backStack, to: &forwardStack) }
    func goForward() { step(from: &forwardStack, to: &backStack) }

    private func step(from: inout [Location], to: inout [Location]) {
        while let next = from.popLast() {
            guard stillThere(next) else { continue }
            to.append(workspace.location)
            steppingHistory = true
            moving { workspace.go(to: next) }
            steppingHistory = false
            return
        }
    }

    /// What going to a location shows that isn't on screen now, for the Back and Forward buttons' names.
    private func changes(_ l: Location) -> String {
        if l.centre != workspace.centre { return placeName(l.centre) }
        if let stage = l.stage { return placeName(stage) }
        return l.panel ? "Overview" : placeName(l.centre)
    }

    /// Back and Forward skip what's gone, and what's in a window of its own now.
    private func stillThere(_ l: Location) -> Bool {
        exists(l.centre) && l.stage.map { exists($0) && !workspace.isFloating($0) } ?? true
    }

    private func exists(_ d: Destination) -> Bool {
        switch d {
        case .terminal(let id): return store.terminals.contains { $0.id == id }
        case .diagram(let id): return store.diagrams[id] != nil
        case .sideChat(let id): return store.sideChats[id] != nil
        case .note(let id): return store.annotations[id] != nil
        case .diff(let task, _): return store.tasks[task] != nil
        case .outside(let id): return outsideSession(id) != nil
        default: return true
        }
    }

    /// A place, named for a Back button: "Conversation", "Fleet", "fleet.ts".
    func placeName(_ d: Destination) -> String {
        if d == .lead { return "Conversation" }
        let t = title(of: d)
        return t.count > 22 ? String(t.prefix(21)) + "…" : t
    }

    /// A place's name, for its tab and window: the conversation's title, the file's name, the worker's.
    func title(of d: Destination) -> String {
        switch d {
        case .inbox: "Needs You"
        case .lead: conversationTitle(store.currentConversationId)
        case .conversation(let id): conversationTitle(id)
        case .fleet: "Fleet"
        case .worker(let id): workerName(id)
        case .terminal(let id): store.terminals.first { $0.id == id }?.title ?? "Terminal"
        case .diagram(let id): store.diagrams[id]?.title ?? "Diagram"
        case .files(let root): (root ?? store.leadCwd).map(Paths.name) ?? "Files"
        case .file(let path, _): Paths.name(path)
        case .notes(.all): "Notes"
        case .notes(.file(let p)): "Notes on \(Paths.name(p))"
        case .notes(.diagram(let id)): "Notes on \(store.diagrams[id]?.title ?? "the diagram")"
        case .note(let id): store.annotations[id].map { "\($0.intent == .question ? "Question" : "Note") on \(noteAnchorName($0))" } ?? "Note"
        case .sideChat(let id): store.sideChats[id]?.title ?? "Side Chat"
        case .plan: "Plan"
        case .diff(let task, let worker): store.tasks[task]?.prompt.map(Self.short) ?? "\(workerName(worker))'s changes"
        case .outside(let id): outsideSession(id)?.name ?? "Running elsewhere"
        }
    }

    /// The start of a task's prompt, for a tab: "Rename Token.text to Token.lexeme…".
    private static func short(_ prompt: String) -> String {
        let line = prompt.split(separator: "\n").first.map(String.init) ?? prompt
        return line.count > 40 ? String(line.prefix(39)) + "…" : line
    }

    /// A place's symbol, for its tab.
    func symbol(of d: Destination) -> String {
        switch d {
        case .inbox: store.attention.isEmpty ? "tray" : "hand.raised.fill"
        case .lead: "sparkles"
        case .conversation: "bubble.left.and.text.bubble.right"
        case .fleet, .worker: "cpu"
        case .terminal(let id): store.terminals.first { $0.id == id }.map { TerminalKinds.symbol($0.kind) } ?? "terminal"
        case .diagram: "point.3.filled.connected.trianglepath.dotted"
        case .files: "folder"
        case .file(let path, _): FileIcon.symbol(name: Paths.name(path))
        case .notes: "text.bubble"
        case .note(let id): store.annotations[id].map { NoteDisplay($0.note).symbol } ?? "text.bubble"
        case .sideChat: "bubble.left.and.bubble.right"
        case .plan: "checklist"
        case .diff: "plus.forwardslash.minus"
        case .outside(let id): outsideSession(id).map(Self.symbol(of:)) ?? "rectangle.on.rectangle"
        }
    }

    /// Something's happening there: Claude working in the live conversation, a worker busy, a side chat answering.
    func isBusy(_ d: Destination) -> Bool {
        switch d {
        case .lead: store.leadStatus.busy
        case .worker(let id): store.workers.contains { $0.id == id && $0.running != nil }
        case .sideChat(let id): store.sideChats[id]?.isAnswering ?? false
        case .outside(let id): outsideSession(id)?.status == "busy"
        default: false
        }
    }

    /// The conversation a place belongs to, as a place: a diagram's, a side chat's, a plan's.
    func conversationPlace(of d: Destination) -> Destination? {
        let id: String? = switch d {
        case .diagram(let g): store.conversations.first { $0.diagramIds.contains(g) }?.id
        case .sideChat(let s): store.sideChats[s]?.conversationId
        case .plan(let c): c
        case .note(let n): store.annotations[n].flatMap(conversationId(ofNote:))
        default: nil
        }
        guard let id else { return nil }
        return id == store.currentConversationId ? .lead : .conversation(id)
    }
    /// The conversation on screen; nil is the live one. The iPhone sets it directly, the regular layout through `destination`.
    var selectedConversation: String?
    /// The conversation the side panel and filters follow: the selected one, else the live one.
    var activeConversationId: String? { selectedConversation ?? store.currentConversationId }
    var isViewingLive: Bool { selectedConversation == nil || selectedConversation == store.currentConversationId }
    /// A Resume was sent for this conversation and the hub hasn't switched to it yet.
    var resumePending: String?
    /// The iPhone's Workers tab: every task, or only the active conversation's.
    var workersShowAll = false
    /// Runs of tool calls opened and closed in conversation threads, and the calls showing their diff or result: kept
    /// here so going to a file from a diff and coming Back finds them as they were.
    var openToolRuns: Set<String> = []
    var closedToolRuns: Set<String> = []
    var openToolCalls: Set<String> = []
    var phoneTab: PhoneTab = .now
    /// Sidebar and conversation side by side from the first frame (DuetApp.init clears the state iOS would restore).
    #if os(macOS)
    var columns: NavigationSplitViewVisibility = .all
    #else
    var columns: NavigationSplitViewVisibility = .doubleColumn
    #endif
    /// The main window's centre is wide enough for the conversation with its cards or the side stage beside it
    /// (DetailView measures it). iPad starts narrow until measured.
    #if os(macOS)
    var isWide = true
    #else
    var isWide = false
    #endif
    var showTerminalPanel = false
    var terminalPanelHeight: CGFloat = 280
    /// How much of the main window's centre the side stage takes, beside the conversation (its edge drags it).
    var stageShare: CGFloat = 0.5
    var showPalette = false
    var selectedTerminal: String?
    var sidebarMode: SidebarMode = .chats
    /// Claude's folder as a tree, for the sidebar's explorer (every window shows the same one).
    let explorer = Explorer()
    /// Dictation, Talk mode and reading replies aloud, with Apple's on-device speech recognition and voices.
    let voice = VoiceController()
    /// ⌘P: find a file in Claude's folder by name.
    var showQuickOpen = false
    /// A side chat open as a sheet (iPad and iPhone; the Mac opens each in its own window).
    var sideChatSheet: SideChatRef?
    /// The iPad's floating side chat (FloatingSideChat), where it was moved and how big it was made; nil: where it
    /// first appears.
    var sideChatPanel: CGRect?
    /// The iPhone's layout is showing (an iPhone, or an iPad window in a narrow split), not the main window's centre and
    /// side stage.
    var compactLayout = false
    /// A window to open; the first window to see it opens it and clears this.
    var windowRequest: WindowRequest?
    /// Surfaces you can write on with Apple Pencil, on screen now: there a squeeze sends your notes, elsewhere it
    /// opens a side chat.
    var pencilSurfaces = 0

    // Composer
    var draft = ""
    var boost = false
    var focusComposerRequest = 0
    /// The approval card you're typing in (an edit or a note), if any. The iPhone hides the composer meanwhile,
    /// and the thread scrolls that card's row fully above the keyboard.
    var cardInput: CardInput?
    /// The iPhone Workers tab's navigation, and the task a worker screen scrolls to when it opens.
    var workersPath: [String] = []
    var focusTask: String?
    var diagramSheet: DiagramRef?
    var diffSheet: DiffRef?
    /// The iPhone's Files tab: its starting folder (nil: Claude's), and what's been opened from it. iPad and Mac open
    /// each of these as a place of its own.
    var filesRoot: String?
    var filesPath: [FilesRoute] = []
    /// A debug run with no hub: the previews' moment, fed in as events (DUET_DEMO=1).
    @ObservationIgnored private(set) var isDemo = false
    /// The latest thing you did that the iPhone should feel (PhoneRoot plays it).
    var touch: Touch?
    /// The ⌃Tab switcher, while it's up.
    var switcher: Switcher?
    #if os(iOS)
    @ObservationIgnored private var live: LiveActivityController?
    /// The main window's scene (iPad), to bring it back when a pane docks.
    @ObservationIgnored var mainScene: UISceneSession?
    #else
    /// The main window (Mac), to bring it forward when the switcher picks one of its tabs from another window.
    @ObservationIgnored weak var mainWindowRef: NSWindow?
    #endif

    static var defaultDevice: String {
        #if os(macOS)
        "mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }

    init() {
        explorer.model = self
        voice.model = self
        // Send to iPad: what another device sends here opens here.
        store.onPlaceSent = { [weak self] in self?.received($0) }
        // Xcode previews render from fed-in events; they must not touch the Keychain or the network.
        if Self.inPreview { return }
        // A write to a socket the peer closed must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Crashes and freezes go to the hub (docs/diagnostics.md): those waiting from before on connecting, new ones
        // at once.
        ProblemReports.shared.start()
        ProblemReports.shared.whenReported { [weak self] in self?.sendProblemReports() }
        #if DEBUG
        // Test runs pass settings in the launch environment so no token is ever typed into the UI. They hold for this
        // run only: a debug build shares the installed app's settings and Keychain, which must keep pointing at the hub.
        let env = ProcessInfo.processInfo.environment
        if let url = env["DUET_URL"] { hubURL = url }
        if let dev = env["DUET_DEVICE"] { device = dev }
        if let token = env["DUET_TOKEN"], !token.isEmpty { testToken = token }
        // Test runs can open on a given iPhone tab.
        switch env["DUET_TAB"] {
        case "chat": phoneTab = .chat
        case "workers": phoneTab = .workers
        case "terminal": phoneTab = .terminal
        case "files": phoneTab = .files
        default: break
        }
        if let mode = env["DUET_SIDEBAR"].flatMap(SidebarMode.init(rawValue:)) { sidebarMode = mode }
        // The sidebar hidden: a wide centre on an iPad held upright, as in landscape.
        if env["DUET_COLUMNS"] == "detail" { columns = .detailOnly }
        // Screenshots of Talk mode where there's no microphone (the simulator).
        switch env["DUET_VOICE_DEMO"] {
        case "listening": voice.preview(.listening, said: "Have the small worker rename", guess: "the helper in fleet")
        case "speaking": voice.preview(.speaking, caption: "Auto queues a small task behind the shortest queue of a small-only worker. It doesn't fall back to a large worker.")
        case "working": voice.preview(.working)
        default: break
        }
        isDemo = env["DUET_DEMO"] == "1"
        StallMonitor.shared.start()
        // Test aid for the freeze reports: block the main thread for this many seconds, 5 s after launch.
        if let freeze = env["DUET_TEST_FREEZE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                ProblemReports.note("test freeze \(freeze) s")
                let end = Date().addingTimeInterval(freeze)
                while Date() < end {}
            }
        }
        #endif
        store.onChange = { [weak self] in self?.storeChanged($0) }
        store.onFsChanged = { [weak self] in self?.explorer.changed($0) }
        // This device as an Apple worker: the hub sends it tasks for its on-device model.
        store.onAppleTask = { [weak self] t in self?.apple.run(t) { self?.send($0, quiet: true) } }
        store.onAppleCancel = { [weak self] id in self?.apple.cancel(id) }
        apple.watchAvailability { [weak self] in self?.reportApple() }
        // What you're saying gets the on-device model before titles and summaries do.
        apple.holdBackground = { [weak self] in self.map { $0.voice.isDictating || $0.voice.isTalking } ?? false }
        #if os(iOS)
        live = LiveActivityController(model: self)
        #endif
        hasToken = token != nil
        store.onPtyExit = { [weak self] id, _ in
            guard let self else { return }
            if self.selectedTerminal == id { self.selectedTerminal = self.store.terminals.first?.id }
            self.moving { self.workspace.closeAll { $0 == .terminal(id) } }
        }
        #if DEBUG
        if isDemo { PreviewData.feed(self) }
        // After the sample conversation is in, so a place can find what it's about (a note's line).
        if let dest = ProcessInfo.processInfo.environment["DUET_DEST"] { openTestPlaces(dest) }
        #endif
    }

    #if DEBUG
    /// A test run's places (DUET_DEST), opened in order from a fresh layout: "plan:s2,diagram:g1" (kept tabs, the last
    /// a preview), "diagram:g1#InString" (an element picked), "cards" for the side stage's Overview, "split" for the
    /// side stage split (the tab shown before beside the one on show), "beside:<place>" for a place in the right-hand
    /// pane, and "zoom" for the side stage filling the window (`Destination(debug:)`).
    private func openTestPlaces(_ dest: String) {
        workspace.reset()
        let names = dest.split(separator: ",").map(String.init)
        for (i, d) in names.enumerated() {
            if d == "cards" { showOverview(); continue }
            if d == "split" { toggleSplit(); continue }
            if d == "zoom" { workspace.zoom(.stage); continue }
            if d.hasPrefix("beside:"), let place = Destination(debug: String(d.dropFirst(7))) { openBeside(place); continue }
            if d.hasPrefix("diagram:"), let hash = d.firstIndex(of: "#") {
                openDiagram(String(d[d.index(d.startIndex, offsetBy: 8)..<hash]), compact: false, focus: String(d[d.index(after: hash)...]))
                continue
            }
            guard let place = Destination(debug: d) else { continue }
            if case .files(let root) = place { filesRoot = root }
            show(place, keep: i < names.count - 1)
        }
        #if os(macOS)
        // DUET_TILE=left|right: the selected tab to that half of the screen, once the main window is up.
        if let side = ProcessInfo.processInfo.environment["DUET_TILE"], let tab = workspace.selected {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                self.tile(tab, leading: side == "left")
            }
        }
        #endif
    }
    #endif

    // MARK: connection

    func save(url: String, device: String, token: String?) {
        hubURL = url
        self.device = device
        UserDefaults.standard.set(url, forKey: "hubURL")
        UserDefaults.standard.set(device, forKey: "device")
        if let token, !token.isEmpty { Keychain.save(token, account: device) }
        testToken = nil
        hasToken = self.token != nil
        connect()
    }

    /// In an Xcode preview, or hosting the app's tests (DuetTests): never the Keychain, the network or the saved layout.
    static let inPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Windows reappear (Mac), scenes reconnect (iPad): only start a connection when there isn't one.
    func connectIfNeeded() {
        ProblemReports.screen(Self.problemName(workspace.front))
        if case .idle = store.connection { connect() }
        // A web view ready for the first file or diagram opened, made once launch is over.
        if !Self.inPreview { DiagramPage.prepareSpare(after: .seconds(3)) }
    }

    func connect() {
        // The preview host is the app itself, so its windows would otherwise connect as this Mac.
        guard !Self.inPreview, !isDemo else { return }
        guard let url = URL(string: hubURL), let token else {
            lastError = "Set the hub URL and this device's token in Settings."
            return
        }
        lastError = nil
        // What this device is ("mac", "ipad", "iphone"), for the other devices' Send to iPad.
        store.connect(HubConfig(url: url, device: device, token: token, kind: Self.defaultDevice))
    }

    /// Tell the hub what this device's on-device model can do (on every connection, and when that changes).
    private func reportApple() {
        guard case .connected = store.connection else { return }
        Task {
            let status = await apple.readStatus()
            guard case .connected = store.connection else { return }
            send(.appleStatus(status), quiet: true)
        }
    }

    private func storeChanged(_ s: DuetStore) {
        refreshConversationList()
        voice.storeChanged(s)
        sideTitles.storeChanged(s, apple: apple, device: device) { [weak self] in self?.send($0, quiet: true) }
        let connected = if case .connected = s.connection { true } else { false }
        if connected, !wasConnected {
            reportApple()
            ProblemReports.note("connected")
            sendProblemReports()
        }
        if !connected, wasConnected { ProblemReports.note("disconnected") }
        wasConnected = connected
        // The hub switched to the conversation on screen (a Resume landed): it's the live one now, so the composer
        // takes over, its tab becomes the live tab, and the sidebar's selection moves to the live row in the same update.
        if let live = s.currentConversationId {
            if selectedConversation == live { selectedConversation = nil }
            if workspace.centre == .conversation(live) { moving { workspace.wentLive(live) } }
            if resumePending == live { resumePending = nil }
        }
        #if DEBUG
        DebugStatus.write(s)
        #endif
        #if os(iOS)
        live?.storeChanged(s)
        #endif
    }

    /// duet://lead and duet://approval/<id> (from the Lock Screen); duet://debug/drop drops the socket (DEBUG builds).
    func handle(url: URL) {
        switch url.host() {
        case "lead":
            phoneTab = .chat
            destination = .lead
        case "approval":
            // The decision queue: Now on iPhone, Needs You on iPad and Mac.
            phoneTab = .now
            destination = .inbox
        default:
            #if DEBUG
            if url.host() == "debug", url.path() == "/drop" { store.dropConnection() }
            // What another device hands over (Handoff), for the simulator, which has none: duet://debug/handoff?place=
            // file:/a/B.swift:3&centre=conversation:s1&draft=Hi (places as DUET_DEST names them).
            if url.host() == "debug", url.path() == "/handoff" {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
                if let place = value("place").flatMap(Destination.init(debug:)) {
                    continueHandoff(Handoff.Offer(place: place, centre: value("centre").flatMap(Destination.init(debug:)), draft: value("draft") ?? ""))
                }
            }
            // A sticky answer for a note or a side chat: duet://debug/stick?note=n-3 or ?chat=sc-1.
            if url.host() == "debug", url.path() == "/stick" {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let id = query.first(where: { $0.name == "note" })?.value { stick(.note(id)) }
                if let id = query.first(where: { $0.name == "chat" })?.value { stick(.sideChat(id)) }
            }
            // A place another device sent (Send to iPad), `minutes` ago: duet://debug/sent?place=diagram:g1&from=mac&minutes=30.
            if url.host() == "debug", url.path() == "/sent" {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
                if let place = value("place").flatMap(Destination.init(debug:)), let data = try? JSONEncoder().encode(place),
                   let json = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    let ts = (Date().timeIntervalSince1970 - (Double(value("minutes") ?? "") ?? 0) * 60) * 1000
                    let sent: JSONValue = .object(["id": .string(UUID().uuidString), "from": .string(value("from") ?? "mac"), "to": .string(device),
                                                   "place": json, "title": .string(title(of: place)), "ts": .number(ts)])
                    if let data = try? JSONEncoder().encode(sent), let p = try? JSONDecoder().decode(PlaceSent.self, from: data) { received(p) }
                }
            }
            // The tab on show lifted as a squeeze of Apple Pencil Pro over it lifts it, waiting for a tap on where it goes
            // (the simulator has no Pencil): duet://debug/lift.
            if url.host() == "debug", url.path() == "/lift", let tab = workspace.selected {
                TabDrag.underPencil?.pencilOver = tab
                _ = squeezeLiftsTab()
            }
            #if os(iOS)
            // What iPadOS does with the last tab dropped at the screen's edge: a new window with the tab's activity. The
            // simulator never gets that far (its LaunchServices doesn't look up a locally signed app's activity types).
            if url.host() == "debug", url.path() == "/edge-drop", let tab = workspace.tabs.last, tab.place != .lead {
                UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(role: .windowApplication, userActivity: PaneActivity.activity(for: tab.place)))
            }
            #endif
            #endif
        }
    }

    /// `quiet` for high-frequency messages (terminal keystrokes) whose failures need no banner.
    func send(_ m: ClientMessage, quiet: Bool = false) {
        // The kind of message only (never its text), and not each keystroke.
        if !quiet { ProblemReports.note("send \(Mirror(reflecting: m).children.first?.label ?? String(describing: m))") }
        switch m {
        case .prompt, .broadcast, .delegate: feel(.sent)
        case .approve: feel(.approved)
        case .reject: feel(.rejected)
        case .interrupt: feel(.stopped)
        // A question, written or typed on a page: its answer comes as a sticky note where you are.
        case .notes(_, let items, _, _): for n in items where n.intent == .question { stick(.note(n.id), question: n.text) }
        default: break
        }
        Task {
            do {
                try await store.send(m)
            } catch {
                if !quiet { lastError = error.localizedDescription }
                // What you'd otherwise wait on for nothing says why it didn't happen.
                switch m {
                case .setPermissionMode:
                    notice = Notice(text: "Claude's mode didn't change: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
                case .notes(_, let items, _, _):
                    notice = Notice(text: "Your notes weren't sent: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
                    let ids = Set(items.map(\.id))
                    stickies.removeAll { if case .note(let id) = $0.source { ids.contains(id) } else { false } }
                default: break
                }
            }
        }
    }

    // MARK: Claude

    /// The row for the model Claude is on: an exact match, else the named alias (Opus, not "Default").
    var currentLeadModel: LeadModel? {
        guard let info = store.leadInfo else { return nil }
        return info.models.first { $0.value == info.model }
            ?? info.models.first { $0.resolved == info.model && $0.value != "default" }
            ?? info.models.first { $0.resolved == info.model }
    }

    var leadModelName: String { currentLeadModel?.displayName ?? store.leadInfo?.model ?? "Claude" }

    /// Claude models to offer: the aliases (opus, sonnet, haiku, fable) and any model no alias already covers,
    /// leaving out "default" (a duplicate of opus) and old models with no effort levels.
    var leadModelChoices: [LeadModel] {
        let models = store.leadInfo?.models ?? []
        let aliasTargets = Set(models.filter { $0.resolved != nil && $0.resolved != $0.value }.compactMap(\.resolved))
        return models.filter { m in
            m.value != "default"
                && !(m.resolved == m.value && aliasTargets.contains(m.value))
                && (!m.effortLevels.isEmpty || m.value == store.leadInfo?.model)
        }
    }

    /// The last line or two of the reply streaming now, for status cards.
    var livePreview: String? {
        let t = store.liveText
        guard !t.isEmpty else { return nil }
        return String(t.suffix(240)).split(separator: "\n").suffix(3).joined(separator: "\n")
    }

    /// The most recent finished reply (first chunk), for the iPhone's Now screen.
    var lastReply: String? {
        for row in store.leadRows.reversed() {
            if case .chunk(_, _, 0, _, _, let text) = row { return String(text.prefix(600)) }
        }
        return nil
    }

    // MARK: conversations

    /// Live first, then the others newest first (empty ones left out): the order the sidebar and the iPhone's list use.
    /// The conversations as lists show them (the live one first, then the earlier ones with something in them, newest
    /// first): without their threads and plans, and their last activity to the minute, so a list changes when a row
    /// would read differently, not on every event Claude streams. Kept current by `storeChanged`.
    var conversationList: [Conversation] {
        if SpeedSwitches.on("list") { return listedConversations }
        // As before the fix: read live from the store, so whatever lists them redraws on every event.
        let live = store.current.map { [$0] } ?? []
        return live + store.conversations.reversed().filter { $0.id != store.currentConversationId && $0.hasContent }
    }
    private var listedConversations: [Conversation] = []

    /// Previews and the demo feed events straight into the store: they call this after.
    func refreshConversationList() {
        let live = store.current.map { [$0] } ?? []
        let list = (live + store.conversations.reversed().filter { $0.id != store.currentConversationId && $0.hasContent }).map(Self.listed)
        if list != listedConversations { listedConversations = list }
    }

    private static func listed(_ c: Conversation) -> Conversation {
        var c = c
        c.rows = []
        c.plan = []
        c.lastActivity = Date(timeIntervalSince1970: (c.lastActivity.timeIntervalSince1970 / 60).rounded(.down) * 60)
        return c
    }

    /// Show a conversation: nil, or the live one's id, is the live thread.
    func select(conversation id: String?, compact: Bool) {
        let live = id == nil || id == store.currentConversationId
        if compact {
            selectedConversation = live ? nil : id
            phoneTab = .chat
        } else {
            destination = live ? .lead : .conversation(id!)
        }
    }

    /// Move through the list: -1 newer, +1 older.
    func stepConversation(_ delta: Int) {
        let ids = conversationList.map(\.id)
        guard !ids.isEmpty else { return }
        let at = isViewingLive ? 0 : (ids.firstIndex(of: selectedConversation ?? "") ?? 0)
        select(conversation: ids[min(max(at + delta, 0), ids.count - 1)], compact: false)
    }

    /// Start a new conversation. The current one stays in the list, resumable.
    func newConversation() { send(.clear) }

    /// Continue an earlier conversation. Returns what went wrong, for the bar that asked; nil when the hub took it.
    func resume(_ id: String) async -> String? {
        guard id != store.currentConversationId else { return nil }
        guard !store.leadStatus.busy else { return "Claude is busy. Stop it, or wait for the turn to end, then resume." }
        resumePending = id
        do {
            try await store.send(.resumeSession(sessionId: id))
        } catch {
            resumePending = nil
            return error.localizedDescription
        }
        // The hub switches the live conversation as it restarts. If that never arrives, stop waiting.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            if self?.resumePending == id { self?.resumePending = nil }
        }
        return nil
    }

    func conversationTitle(_ id: String?) -> String { titles.title(for: id.flatMap { store.conversation($0) }) }

    /// The conversation a note was written in: the one with the turn Claude took it in; one not taken yet is the live
    /// conversation's.
    func conversationId(ofNote a: Annotation) -> String? {
        guard let turn = a.turn else { return store.currentConversationId }
        return store.conversations.first { $0.turnIds.contains(turn) }?.id ?? store.currentConversationId
    }

    /// A conversation's threads, waiting ones first, then newest first: its notes (handwritten or typed, on lines,
    /// diagram elements and diffs) and its side chats.
    func threads(in c: Conversation) -> [SideThread] {
        let notes = notes(in: c).map { a in SideThread.note(a, replies: a.chatId.flatMap { store.sideChats[$0] }) }
        // A side chat that continues a note is that note's thread, not one of its own.
        let chats = store.sideChats(in: c.id).filter { $0.annotationId == nil }.map(SideThread.chat)
        return (notes + chats).sorted { ($0.waiting ? 0 : 1, $1.date) < ($1.waiting ? 0 : 1, $0.date) }
    }

    /// The kept notes written in a conversation (by the turn Claude took them in), newest first. Notes Claude hasn't
    /// taken yet have no turn: they belong to the live one.
    func notes(in c: Conversation) -> [Annotation] {
        let turns = Set(c.turnIds)
        let live = c.id == store.currentConversationId
        return store.annotationList.filter { a in a.turn.map { turns.contains($0) } ?? live }
    }

    /// "7 workers · 6 idle", or what's busy, for the Fleet row.
    var fleetSummary: String {
        let all = store.workers
        let busy = all.filter { $0.running != nil }
        let n = all.count == 1 ? "1 worker" : "\(all.count) workers"
        if busy.isEmpty { return "\(n) · idle" }
        return "\(n) · \(busy.map(\.shortLabel).joined(separator: ", ")) working"
    }

    // MARK: sessions running elsewhere

    /// Claude Code sessions running outside Duet on the hub machine (Claude Desktop, a terminal, the background): busy ones
    /// first, then idle, then ended (each stays a day, to continue here), most recently active first.
    var outsideSessions: [OutsideSession] {
        func rank(_ s: OutsideSession) -> Int { s.status == "busy" ? 0 : s.live ? 1 : 2 }
        func latest(_ s: OutsideSession) -> Double { s.updatedAt ?? s.startedAt ?? 0 }
        return outsideSource.sorted { (rank($0), -latest($0)) < (rank($1), -latest($1)) }
    }

    private var outsideSource: [OutsideSession] {
        #if DEBUG
        if isDemo { return PreviewData.outside }
        #endif
        return store.outsideSessions
    }

    func outsideSession(_ id: String) -> OutsideSession? { outsideSource.first { $0.sessionId == id } }

    /// A followed session's messages: its recent ones, then each new one, about 2 s behind. Nil until followed.
    func outsideMessages(_ id: String) -> [OutsideMessage]? {
        #if DEBUG
        if isDemo { return PreviewData.outsideMessages[id] ?? [] }
        #endif
        return store.outsideMessages[id]
    }

    func followOutside(_ id: String) async throws {
        if isDemo { return }
        try await store.followOutside(id)
    }

    func unfollowOutside(_ id: String) async {
        if isDemo { return }
        await store.unfollowOutside(id)
    }

    /// Continue it in Duet: a fork while it still runs there, else the session itself. Its conversation becomes the
    /// live one, so the centre goes there. The hub refuses while Claude is in the middle of a turn here.
    func continueOutside(_ id: String) async throws {
        if isDemo { throw HubError(message: "A test run has no hub to continue it on.") }
        let continued = try await store.continueOutside(id)
        feel(.sent)
        // Waiting for Claude's turn here to end: it takes over then, and the live conversation shows it.
        if continued != nil { show(.lead) }
    }

    /// Where a session runs and how it is: "In Claude Desktop on the hub · busy", "Ended 2 hours ago, in a terminal".
    func whereLine(_ s: OutsideSession) -> String {
        let place = switch s.place {
        case "desktop": "in Claude Desktop"
        case "terminal": "in a terminal"
        case "background": "in the background"
        default: "elsewhere"
        }
        guard s.live else {
            let ago = s.endedAt.map { " " + Date(timeIntervalSince1970: $0 / 1000).formatted(.relative(presentation: .named)) } ?? ""
            return "Ended\(ago), \(place) on the hub"
        }
        return "\(place.prefix(1).uppercased() + place.dropFirst()) on the hub · \(s.status)"
    }

    /// A session's symbol, by where it runs.
    static func symbol(of s: OutsideSession) -> String {
        switch s.place {
        case "desktop": "desktopcomputer"
        case "terminal": "terminal"
        case "background": "moon.zzz"
        default: "rectangle.on.rectangle"
        }
    }

    // MARK: composer

    var mentionPrefix: String? {
        guard draft.hasPrefix("@"), !draft.contains(" ") else { return nil }
        return String(draft.dropFirst())
    }

    func mentionOptions(_ prefix: String) -> [MentionOption] {
        let all = [MentionOption(id: "claude", title: "@claude", symbol: "sparkles"), MentionOption(id: "all", title: "@all", symbol: "megaphone")]
            // Claude's subagents aren't given tasks directly: Claude starts them.
            + store.workers.filter { $0.enabled && !$0.isClaude }.map { MentionOption(id: $0.id, title: "@\($0.id)", symbol: "hammer") }
        return prefix.isEmpty ? all : all.filter { $0.id.hasPrefix(prefix.lowercased()) }
    }

    var draftTarget: DraftTarget {
        switch DraftRoute.route(draft, workers: store.workers.map(\.id)) {
        case .all: DraftTarget(kind: .all)
        case .worker(let id, _): DraftTarget(kind: .worker(id))
        default: DraftTarget(kind: .claude)
        }
    }

    func feel(_ kind: Touch.Kind) { touch = Touch(kind: kind, n: (touch?.n ?? 0) + 1) }

    /// Send the draft. `context`: the composer's chip, what the side stage shows, which goes first ("About
    /// Lexer.swift:27 (`…`): "). Once sent, its tab stays and the chip goes until something else is picked.
    func sendDraft(context: ComposerContext? = nil) {
        guard let route = DraftRoute.route(draft, workers: store.workers.map(\.id)) else { return }
        let about = context?.prompt ?? ""
        switch route {
        case .claude(let text): send(.prompt(text: about + text, boost: boost))
        case .all(let text): send(.broadcast(text: about + text))
        case .worker(let id, let task): send(.delegate(worker: id, prompt: about + task))
        }
        if let context {
            keepOpen(workspace.staged)
            removedContext = context.id
        }
        draft = ""
        boost = false
    }

    // MARK: what a message is about

    /// What's picked in each place the side stage has shown (a line of a file or a diff, an element of a diagram).
    private(set) var panelPicks: [Destination: InkAnchor] = [:]
    /// The chip the composer last had removed (its id): it stays away until the side stage shows or picks something else.
    private(set) var removedContext: String?

    /// Something picked, or let go of, in a file, a diff or a diagram.
    func picked(_ anchor: InkAnchor?, in place: Destination) {
        panelPicks[place.identity] = anchor
    }

    /// The composer's chip: what the side stage shows and what's picked in it, unless it was removed.
    var composerContext: ComposerContext? {
        guard let place = workspace.staged, let c = context(for: place, picked: panelPicks[place.identity]) else { return nil }
        return c.id == removedContext ? nil : c
    }

    /// The chip's ×: this message goes without it.
    func removeContext() { removedContext = composerContext?.id }

    /// A place in the side stage, and what's picked in it, as the composer offers it; nil for places a question isn't
    /// about (Needs You, the fleet, lists of notes, the plan, a terminal).
    func context(for place: Destination, picked: InkAnchor?) -> ComposerContext? {
        switch place {
        case .file(let path, _):
            let symbol = FileIcon.symbol(name: Paths.name(path))
            if let line = picked?.line {
                return ComposerContext(id: "file:\(path):\(line)", label: "\(Paths.name(path)):\(line)", symbol: symbol,
                                       prompt: "About \(Paths.short(path)):\(line) (`\(picked?.label ?? "")`): ")
            }
            return ComposerContext(id: "file:\(path)", label: Paths.name(path), symbol: symbol, prompt: "About \(Paths.short(path)): ")
        case .diagram(let id):
            guard let d = store.diagrams[id] else { return nil }
            let symbol = "point.3.filled.connected.trianglepath.dotted"
            if let a = picked {
                return ComposerContext(id: "diagram:\(id):\(a.id)", label: "\(d.title) › \(a.label)", symbol: symbol,
                                       prompt: "About “\(a.label)” (\(a.id)) in the diagram “\(d.title)”: ")
            }
            return ComposerContext(id: "diagram:\(id)", label: d.title, symbol: symbol, prompt: "About the diagram “\(d.title)” (\(id)): ")
        case .diff(let task, let worker):
            let symbol = "plus.forwardslash.minus"
            if let a = picked, let file = a.file, let line = a.line {
                return ComposerContext(id: "diff:\(task):\(file):\(line)", label: "\(Paths.name(file)):\(line) in the diff", symbol: symbol,
                                       prompt: "About \(file) line \(line) in \(workerName(worker))'s task \(task) (`\(a.label)`): ")
            }
            let name = title(of: place)
            return ComposerContext(id: "diff:\(task)", label: "Diff · \(name)", symbol: symbol,
                                   prompt: "About what \(workerName(worker)) changed in task \(task) (“\(name)”): ")
        case .worker(let id):
            return ComposerContext(id: "worker:\(id)", label: workerName(id), symbol: "cpu", prompt: "About the worker \(workerName(id)): ")
        case .note(let id):
            guard let a = store.annotations[id] else { return nil }
            return ComposerContext(id: "note:\(id)", label: "Note on \(a.place)", symbol: "text.bubble",
                                   prompt: "About my note on \(a.place)" + (a.text.map { " (“\($0)”)" } ?? "") + ": ")
        case .files(let folder):
            guard let path = folder ?? store.leadCwd else { return nil }
            return ComposerContext(id: "folder:\(path)", label: Paths.name(path), symbol: "folder", prompt: "About \(Paths.short(path)): ")
        default:
            return nil
        }
    }

    // MARK: workers and terminals

    // MARK: workers

    /// Opens a task on its worker's screen: the Workers tab on iPhone, that worker in the sidebar on iPad and Mac.
    func openTask(_ taskId: String, worker: String, compact: Bool) {
        focusTask = taskId
        if compact {
            phoneTab = .workers
            workersPath = [worker]
        } else {
            destination = .worker(worker)
        }
    }

    func workerName(_ id: String) -> String { store.workers.first { $0.id == id }?.shortLabel ?? id }

    /// Who a task is for: Claude, you, or the device that gave it.
    func taskOwner(_ by: String?) -> String {
        guard let by, by != device else { return "you" }
        return by == "lead" ? "Claude" : by
    }

    /// "Working for Claude · 1 queued", or the worker's plain status.
    func workerStatus(_ w: WorkerView) -> String {
        guard let id = w.running, let t = store.tasks[id] else { return w.statusText }
        if let n = w.active?.count, n > 1 { return "Working for \(taskOwner(t.by)) · \(n) at once" }
        return "Working for \(taskOwner(t.by))" + (w.queue.isEmpty ? "" : " · \(w.queue.count) queued")
    }

    /// The worker's last task, if it ended in the past hour: "Done for Claude · 3 min. ago".
    func workerRecent(_ w: WorkerView) -> String? {
        guard w.running == nil,
              let id = store.taskOrder.last(where: { store.tasks[$0]?.worker == w.id && store.taskEndedAt[$0] != nil }),
              let t = store.tasks[id], let at = store.taskEndedAt[id], Date.now.timeIntervalSince(at) < 3600 else { return nil }
        let what = t.state == "done" ? "Done" : t.state == "failed" ? "Failed" : "Cancelled"
        return "\(what) for \(taskOwner(t.by)) · \(at.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
    }

    // MARK: routing suggestions

    /// Where a request of this kind is best sent, if not to Claude: a coding task to the largest local model, a small
    /// edit to the smallest, text work to this device's Apple worker. Nil when Claude is the best (or only) choice.
    func suggestion(for route: AppleIntelligence.Route) -> RouteSuggestion? {
        let ready = store.workers.filter { $0.enabled && $0.available && $0.loaded }
        let local = ready.filter { !$0.isApple && !$0.isClaude }
        // Parameters from the name: "Qwen3.8 27B" is 27, "9B" is 9.
        let size = { (w: WorkerView) -> Double in (w.shortLabel.firstMatch(of: /(\d+(?:\.\d+)?)B\b/)).flatMap { Double($0.1) } ?? 0 }
        let pick: WorkerView?
        switch route.kind {
        case .thinking: return nil
        case .codingTask: pick = local.max { size($0) < size($1) }
        case .smallEdit: pick = local.min { size($0) < size($1) }
        // Reading and summarizing text: the smallest local model, which is free too, reads the files itself and has
        // a far bigger context than Apple's on-device one (that stays yours by @mention).
        case .textWork: pick = local.min { size($0) < size($1) }
        }
        guard let w = pick else { return nil }
        return RouteSuggestion(worker: w.id, name: w.shortLabel, reason: route.reason)
    }

    // MARK: diagrams and diffs

    /// A diagram: full screen on iPhone, beside the conversation on iPad and Mac. `focus`: an element to pick once it's
    /// drawn (opened from the code that element stands for).
    func openDiagram(_ id: String, compact: Bool, focus: String? = nil) {
        diagramFocus = focus.map { DiagramFocus(diagram: id, element: $0) }
        if compact { diagramSheet = DiagramRef(id: id) } else { destination = .diagram(id) }
    }

    /// An element to pick in a diagram as it opens (`openDiagram(_:compact:focus:)`); the diagram takes it.
    var diagramFocus: DiagramFocus?

    /// What a task changed: beside the conversation on iPad and Mac, full screen on iPhone.
    func openDiff(taskId: String, worker: String) {
        if compactLayout { diffSheet = DiffRef(taskId: taskId, worker: worker) } else { show(.diff(taskId, worker: worker)) }
    }

    // MARK: files on the hub machine

    /// The file viewer at a folder (nil: Claude's): the Files tab on iPhone, its tab on iPad and Mac.
    func openFiles(_ path: String?, compact: Bool) {
        guard compact else { show(.files(path)); return }
        filesRoot = path
        filesPath = []
        phoneTab = .files
    }

    /// A file (at a line: shown and picked): opened from its folder in the iPhone's Files tab, a tab on iPad and Mac.
    func openFile(_ path: String, line: Int? = nil, compact: Bool) {
        diagramSheet = nil
        diffSheet = nil
        guard compact else { show(.file(path, line: line)); return }
        let switching = phoneTab != .files
        openFiles((path as NSString).deletingLastPathComponent, compact: true)
        // A path set in the same update that swaps the stack's root is dropped: push once the folder is showing.
        if switching {
            Task { @MainActor in self.filesPath = [.file(path, line: line)] }
        } else {
            filesPath = [.file(path, line: line)]
        }
    }

    /// The file one of Claude's edits changed, opened at a line of the change (`newIndex` among its new text's lines;
    /// nil for a removed line, which opens where the change starts). The file is read to find where the change is now;
    /// if it isn't there any more, the file opens at its top.
    func openEdit(_ edit: FileEdit, change: Int, at newIndex: Int?, compact: Bool) {
        Task {
            let text = try? await readFile(edit.path).text
            let line = text.flatMap { edit.line(of: change, in: $0) }.map { $0 + (newIndex ?? 0) }
            openFile(edit.path, line: line, compact: compact)
        }
    }

    /// Every kept note (or those on a file or diagram).
    func openNotes(_ filter: NotesFilter = .all, compact: Bool) {
        guard compact else { show(.notes(filter)); return }
        phoneTab = .files
        filesPath = [.notes(filter)]
    }

    /// One kept note: the Files tab on iPhone, a tab on iPad and Mac.
    func showNote(_ id: String, compact: Bool) {
        guard compact else { show(.note(id)); return }
        diagramSheet = nil
        phoneTab = .files
        filesPath = [.note(id)]
    }

    /// Some kept notes, the same way.
    func showNotes(_ filter: NotesFilter, compact: Bool) {
        guard compact else { show(.notes(filter)); return }
        diagramSheet = nil
        phoneTab = .files
        filesPath = [.notes(filter)]
    }

    /// A step inside a pane (a folder's file, a note), wherever it was asked for: pushed on the iPhone's Files stack,
    /// a place of its own on iPad and Mac.
    func open(_ route: FilesRoute, compact: Bool) {
        if compact { filesPath.append(route) } else { show(route.place) }
    }

    /// A question typed about a line or an element: a note like a handwritten one, so it becomes a thread on it,
    /// answered there (a local model first). Asked about, its tab stays.
    func askHere(_ text: String, on surface: NoteSurface, lines: [InkLines]? = nil, elements: [InkElement]? = nil) {
        var note = InkNote(id: UUID().uuidString, intent: .question, text: text, elements: elements, lines: lines)
        note.typed = true
        send(.notes(surface: surface, items: [note]))
        keepOpen(workspace.staged)
        feel(.sent)
    }

    /// A reply in a note's thread: the hub continues the note in a side chat (its first reply starts it), answered like
    /// one, a local model first. The hub refuses one while the note itself is still being answered.
    func replyToNote(_ id: String, text: String) async throws {
        _ = try await store.send(.noteReply(id: id, text: text))
        feel(.sent)
        keepOpen(workspace.staged)
    }

    /// A note's handwriting, fetched once from the hub.
    func annotationInk(_ id: String) async -> PlatformImage? {
        if let i = inkCache[id] { return i }
        guard let b64 = try? await store.send(.annotationInk(id: id)).image, let data = Data(base64Encoded: b64) else { return nil }
        let image = PlatformImage(data: data)
        inkCache[id] = image
        return image
    }

    @ObservationIgnored private var inkCache: [String: PlatformImage] = [:]


    /// A folder's entries (nil: Claude's folder), with each one's git status.
    func listFolder(_ path: String?) async throws -> FsListing {
        guard let l = try await store.send(.fsList(path: path)).listing else { throw HubError(message: "The hub sent no listing.") }
        return l
    }

    func readFile(_ path: String) async throws -> FsFile {
        #if DEBUG
        if isDemo, let f = PreviewData.demoFile(path) { return f }
        #endif
        guard let f = try await store.send(.fsRead(path: path)).file else { throw HubError(message: "The hub sent no file.") }
        recentFiles[path] = f
        recentFileOrder.removeAll { $0 == path }
        recentFileOrder.append(path)
        if recentFileOrder.count > 12 { recentFiles[recentFileOrder.removeFirst()] = nil }
        return f
    }

    /// A file read recently, to show at once while it's read again.
    func recentFile(_ path: String) -> FsFile? { recentFiles[path] }
    @ObservationIgnored private var recentFiles: [String: FsFile] = [:]
    @ObservationIgnored private var recentFileOrder: [String] = []

    /// Move Claude to a folder (it keeps the conversation). New shells and worker tasks start there too.
    func moveClaude(to path: String) {
        Task {
            do { try await store.send(.setCwd(path: path)) } catch { lastError = error.localizedDescription }
        }
    }

    /// A task's changes in its worker's folder (tracked and new files), measured by the hub.
    func fetchDiff(_ taskId: String) async throws -> (diff: String, truncated: Bool) {
        #if DEBUG
        if isDemo, let d = PreviewData.diffs[taskId] { return (d, false) }
        #endif
        let ack = try await store.send(.taskDiff(taskId: taskId))
        return (ack.diff ?? "", ack.truncated ?? false)
    }

    /// Starts a message to Claude about something on screen (an element, a line), in the composer, ready to finish.
    func askAbout(_ text: String, compact: Bool) {
        diagramSheet = nil
        diffSheet = nil
        // The draft names what it's about, so the composer's chip stays away; asked about, its tab stays.
        if !compact {
            keepOpen(workspace.staged)
            removedContext = composerContext?.id
        }
        draft = text
        if compact { phoneTab = .chat } else { destination = .lead }
        focusComposerRequest += 1
    }

    /// A worker's tasks, newest first; only those of one conversation when `conversation` is given.
    func taskIds(for worker: String, conversation: String? = nil) -> [String] {
        store.taskOrder.reversed().filter { id in
            store.tasks[id]?.worker == worker && (conversation == nil || store.conversationOf(taskId: id) == conversation)
        }
    }

    /// A new terminal; a shell can start in a given folder (else Claude's).
    func openTerminal(_ kind: PtyKind, cwd: String? = nil) {
        Task {
            do {
                let ack = try await store.send(.ptyOpen(kind: kind, cols: 100, rows: 30, cwd: cwd))
                guard let id = ack.ptyId else { return }
                let title = kind == .shell ? (cwd.map { "Shell · \(Paths.name($0))" } ?? "Shell") : kind == .hub_logs ? "Hub logs" : "llmd status"
                store.addTerminal(PtyInfo(id: id, kind: kind, title: title))
                selectedTerminal = id
                #if os(macOS)
                showTerminalPanel = true
                #else
                if UIDevice.current.userInterfaceIdiom == .pad { destination = .terminal(id) } else { phoneTab = .terminal }
                #endif
            } catch { lastError = error.localizedDescription }
        }
    }

    func approveNext() {
        // Never a risky ask: those need their own card's Approve and a second confirmation.
        for item in store.attention { if case .approval(let a) = item, !a.needsCare { send(.approve(id: a.id)); return } }
    }

    // MARK: side chats and windows

    /// Open a side chat: an existing one, or a new one about something (nil: the conversation). One that's been asked
    /// is a subconversation: in the main window's centre (iPad and Mac), with the way back to its conversation above it.
    /// A new one has its own window on Mac; a sheet on iPad and iPhone (iPad can move it to a window of its own).
    func openSideChat(_ chatId: String? = nil, about: SideAbout? = nil) {
        // Asked about what the side stage shows: its tab stays.
        if about != nil, !compactLayout { keepOpen(workspace.staged) }
        if let chatId, !compactLayout {
            // A note's replies are that note's thread.
            show(store.sideChats[chatId]?.annotationId.map { .note($0) } ?? .sideChat(chatId))
            return
        }
        let ref = SideChatRef(chatId: chatId, about: about)
        #if os(macOS)
        windowRequest = .side(ref)
        #else
        sideChatSheet = ref
        #endif
    }

    /// Talk mode with Claude, on or off (⌘⇧T).
    func toggleTalk() {
        if voice.isTalkingWithClaude { voice.end(); return }
        destination = .lead
        Task { await voice.startTalk(.conversation) }
    }

    /// Dictation into the message to Claude, on or off (⌘⇧D).
    func toggleDictation() {
        if voice.isDictating("composer") { Task { await voice.stopDictation() }; return }
        destination = .lead
        focusComposerRequest += 1
        Task { await voice.startDictation("composer", into: draft) { [weak self] in self?.draft = $0 } }
    }

    /// Ask in a side chat (a new one when `chatId` is nil). Returns the chat's id once the hub has it. `voice`: asked
    /// out loud in Talk mode, so the answer opens with what sounds right spoken.
    func askSide(_ text: String, chatId: String?, about: SideAbout?, model: String?, image: String? = nil, voice: Bool = false) async throws -> String {
        let ack = try await store.send(.sideAsk(chatId: chatId, text: text, about: chatId == nil ? about : nil, model: model, image: image,
                                                imageType: image == nil ? nil : "image/jpeg", voice: voice))
        feel(.sent)
        guard let id = ack.chatId else { throw HubError(message: "The hub didn't say which side chat it started.") }
        return id
    }

    /// What's on screen, for a side chat started from a menu or a Pencil squeeze: the open file or diagram, or the
    /// worker you're looking at. Nil: the conversation itself.
    var currentAbout: SideAbout? {
        switch destination {
        case .file(let p, let line): return .file(path: p, start: line, end: line)
        case .diagram(let id): return store.diagrams[id].map { .text(label: "the diagram “\($0.title)”", text: $0.source) }
        case .worker(let id): return .text(label: "the worker \(workerName(id))")
        default: return nil
        }
    }

    /// Something in its own window (Mac, and iPad with more than one window). Something open in a tab moves to the
    /// window, so it's never open twice, and so does a side chat in the centre (its conversation takes the centre).
    /// A conversation stays in the centre too: its window is a second one.
    func openWindow(_ w: WindowRequest) {
        let place: Destination? = switch w {
        case .pane(let p): p
        case .side(let ref): ref.chatId.map { .sideChat($0) }
        case .main: nil
        }
        if let place, let tab = workspace.tab(for: place) { close(tab) }
        if case .sideChat(let id)? = place, workspace.centre == place {
            let conversation = store.sideChats[id]?.conversationId
            show(conversation.map { .conversation($0) } ?? .lead)
        }
        windowRequest = w
    }

    /// A window asked for where there's only one (iPhone): what it would show opens here instead.
    func showInPlace(_ w: WindowRequest) {
        switch w {
        case .side(let ref): sideChatSheet = ref
        case .pane(let place): showCompact(place)
        case .main: break
        }
    }

    /// A place on iPhone, in the tab that owns it (a diagram full screen, a side chat in a sheet).
    func showCompact(_ place: Destination) {
        switch place {
        case .inbox, .plan: phoneTab = .now
        case .lead: select(conversation: nil, compact: true)
        case .conversation(let id): select(conversation: id, compact: true)
        case .fleet: phoneTab = .workers; workersPath = []
        case .worker(let id): phoneTab = .workers; workersPath = [id]
        case .terminal(let id): selectedTerminal = id; phoneTab = .terminal
        case .diagram(let id): openDiagram(id, compact: true)
        case .files(let root): openFiles(root, compact: true)
        case .file(let p, let line): openFile(p, line: line, compact: true)
        case .notes(let filter): openNotes(filter, compact: true)
        case .note(let id): showNote(id, compact: true)
        case .sideChat(let id): sideChatSheet = SideChatRef(chatId: id)
        case .diff(let task, let worker): diffSheet = DiffRef(taskId: task, worker: worker)
        // Not on iPhone yet: sessions running elsewhere show in the main window of iPad and Mac.
        case .outside: break
        }
    }

    /// What the narrow layout (iPhone, an iPad in half the screen) shows, for Handoff: its sheet, else its tab's
    /// place. Nil in the Terminal tab: its shell belongs to this device.
    var compactPlace: Destination? {
        if let d = diagramSheet { return .diagram(d.id) }
        if let d = diffSheet { return .diff(d.taskId, worker: d.worker) }
        if let id = sideChatSheet?.chatId { return .sideChat(id) }
        switch phoneTab {
        case .now, .chat: return selectedConversation.map { .conversation($0) } ?? .lead
        case .workers: return workersPath.last.map { .worker($0) } ?? .fleet
        case .terminal: return nil
        case .files:
            switch filesPath.last {
            case .file(let path, let line)?: return .file(path, line: line)
            case .note(let id)?: return .note(id)
            case .notes(let filter)?: return .notes(filter)
            case .folder(let path)?: return .files(path)
            case nil: return .files(filesRoot)
            }
        }
    }

    /// What the other device handed over (Handoff): its conversation in the centre and the place beside it, as they
    /// were there; on iPhone, the place in the tab that owns it. What was being typed comes too, unless something's
    /// being typed here.
    func continueHandoff(_ offer: Handoff.Offer) {
        if compactLayout {
            showCompact(offer.place)
        } else {
            if let centre = offer.centre, centre.inCentre, centre != offer.place { show(centre) }
            show(offer.place, keep: true)
        }
        if draft.isEmpty, !offer.draft.isEmpty { draft = offer.draft }
    }

    // MARK: permission mode

    /// Claude's permission mode (LeadModeMenu), as the hub says; a demo run keeps its own.
    var permissionMode: String {
        #if DEBUG
        if isDemo { return demoPermissionMode }
        #endif
        return store.permissionMode
    }

    #if DEBUG
    var demoPermissionMode = "default"
    #endif

    func setPermissionMode(_ mode: String) {
        #if DEBUG
        if isDemo { demoPermissionMode = mode; return }
        #endif
        send(.setPermissionMode(mode))
    }

    /// The hub knows permission modes: it reports the one Claude is in. A hub from before refuses `set_permission_mode`.
    var permissionModesSupported: Bool {
        #if DEBUG
        if isDemo { return true }
        #endif
        return store.leadInfo?.permissionMode != nil
    }

    /// The hub takes notes on a plan. They came in the same hub update as the device list, so a hub that lists devices
    /// takes them; one from before would get a surface it doesn't know.
    var hubTakesPlanNotes: Bool {
        #if DEBUG
        if isDemo { return true }
        #endif
        return !store.devices.isEmpty
    }

    // MARK: Send to iPad

    /// A short notice at the top of the window in front: a place sent to another device, or one that came from one.
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var symbol: String
        /// What its Open button opens, if it has one.
        var place: Destination? = nil
        /// It was sent to write on (Write on iPad): Open brings out the Pencil tools too.
        var write = false
    }
    var notice: Notice?
    @ObservationIgnored private var receivedSends: Set<String> = []
    /// A file or a diagram sent here to write on (Write on iPad), by its identity: its view brings out the Pencil tools
    /// once it shows, and clears this (`writesWhenSent`).
    var writeRequest: Destination?

    /// Answers as sticky notes where you asked (Stickies.swift), oldest first.
    var stickies: [Sticky] = []

    /// The user's other devices, to send a place to: those with Duet open first. (Sample ones in demo runs.)
    var sendTargets: [DeviceInfo] {
        var devices = store.otherDevices
        #if DEBUG
        if isDemo { devices = PreviewData.devices.filter { $0.device != device } }
        #endif
        return devices.sorted { ($0.online ? 0 : 1, $0.device) < ($1.online ? 0 : 1, $1.device) }
    }

    /// A device as people call it: "iPad", "Mac", "iPhone", else its token's name.
    static func deviceName(_ device: String, kind: String? = nil) -> String {
        switch kind ?? device {
        case "mac": "Mac"
        case "ipad": "iPad"
        case "iphone": "iPhone"
        default: device.prefix(1).uppercased() + device.dropFirst()
        }
    }

    static func deviceSymbol(_ d: DeviceInfo) -> String {
        switch d.kind ?? d.device {
        case "mac": "laptopcomputer"
        case "ipad": "ipad"
        case "iphone": "iphone"
        default: "desktopcomputer"
        }
    }

    /// What can be sent: anything but a terminal, whose shell belongs to the device that opened it.
    static func sendable(_ place: Destination) -> Bool { Handoff.offers(place) }

    /// Open on iPad (or Mac): `place` opens on that device now if Duet is open there, else when it next is. It goes
    /// through the hub, so it needs no iCloud or Bluetooth, unlike Handoff. `write` (Write on iPad): it opens there with
    /// the Pencil tools out.
    func send(_ place: Destination, to target: DeviceInfo, write: Bool = false) {
        let name = Self.deviceName(target.device, kind: target.kind)
        let title = sendTitle(of: place)
        let json = JSONValue(encoding: place)
        let then = write ? " to write on" : ""
        feel(.sent)
        if isDemo {
            notice = Notice(text: "Sent \(title) to your \(name)\(then)", symbol: write ? "applepencil.and.scribble" : Self.deviceSymbol(target))
            return
        }
        Task {
            do {
                let queued = try await store.sendPlace(to: target.device, place: json, title: title, write: write)
                notice = Notice(text: queued ? "\(title) opens on your \(name)\(then) when Doublet is next open there" : "Sent \(title) to your \(name)\(then)",
                                symbol: write ? "applepencil.and.scribble" : Self.deviceSymbol(target))
            } catch {
                notice = Notice(text: "Couldn't send \(title) to your \(name): \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
    }

    /// A place another device sent here: it opens, if it was sent in the last 15 minutes (as with Handoff, its
    /// conversation stays); an older one waits in a notice, to open or not. One sent to write on opens with the Pencil
    /// tools out.
    func received(_ sent: PlaceSent) {
        // Each connection of this device gets it (a Mac can have more than one), and the hub sends it again until it
        // hears it arrived: once is enough.
        guard receivedSends.insert(sent.id).inserted, let place = try? sent.place.decoded(as: Destination.self) else { return }
        let from = Self.deviceName(sent.from)
        let write = sent.write == true
        if Date().timeIntervalSince(sent.date) < 15 * 60 {
            openHere(place, write: write)
            notice = Notice(text: write ? "From your \(from), to write on: \(sent.title)" : "From your \(from): \(sent.title)",
                            symbol: write ? "applepencil.and.scribble" : "arrow.down.forward.circle")
        } else {
            notice = Notice(text: "Your \(from) sent \(sent.title)\(write ? " to write on" : "") \(sent.date.formatted(.relative(presentation: .named)))",
                            symbol: "clock", place: place, write: write)
        }
    }

    /// A file on its own in a tab (the explorer's way to open one), at a line if given. `keep`: a kept tab, not a
    /// preview (a double-click).
    func open(file path: String, line: Int? = nil, keep: Bool = false) {
        diagramSheet = nil
        diffSheet = nil
        show(.file(path, line: line), keep: keep)
    }

    /// The file the main window shows, if it shows one.
    var openFilePath: String? {
        if case .file(let p, _)? = destination { return p }
        return nil
    }

    /// Show a file (or folder) in the sidebar's explorer: its folders open, it picked.
    func reveal(_ path: String) {
        sidebarMode = .explorer
        columns = .all
        explorer.reveal(path)
    }

    // MARK: command palette

    var paletteActions: [PaletteAction] {
        // What's open first: every other tab, and every window.
        var a: [PaletteAction] = workspace.tabs.filter { $0.place != workspace.staged }.map { t in
            PaletteAction(id: "tab-\(t.id)", title: "Go to Tab: \(title(of: t.place))", symbol: symbol(of: t.place)) { [weak self] in self?.select(t) }
        }
        a.append(PaletteAction(id: "overview", title: "Show the Conversation's Overview", symbol: "rectangle.grid.1x2") { [weak self] in self?.showOverview() })
        if workspace.panelShown {
            a.append(PaletteAction(id: "hide-stage", title: "Hide Side Panel", symbol: "sidebar.trailing") { [weak self] in self?.hidePanel() })
        } else {
            a.append(PaletteAction(id: "show-stage", title: "Show Side Panel", symbol: "sidebar.trailing") { [weak self] in self?.showPanel() })
        }
        for f in workspace.floating {
            a.append(PaletteAction(id: "window-\(f.place.identity)", title: "Go to Window: \(title(of: f.place))", symbol: "macwindow") { [weak self] in
                self?.windowRequest = f.window
            })
        }
        a += [
            PaletteAction(id: "go-inbox", title: "Go to Needs You", symbol: "tray") { [weak self] in self?.destination = .inbox },
            PaletteAction(id: "go-lead", title: "Go to the Live Conversation", symbol: "sparkles") { [weak self] in self?.destination = .lead },
            PaletteAction(id: "focus", title: "Message Claude", symbol: "square.and.pencil") { [weak self] in self?.destination = .lead; self?.focusComposerRequest += 1 },
            PaletteAction(id: "new-conversation", title: "New Conversation", symbol: "plus.bubble") { [weak self] in self?.newConversation() },
            PaletteAction(id: "files", title: "Show Claude's Files", symbol: "folder") { [weak self] in self?.openFiles(nil, compact: false) },
            PaletteAction(id: "explorer", title: "Show Explorer", symbol: "sidebar.left") { [weak self] in self?.sidebarMode = .explorer; self?.columns = .all },
            PaletteAction(id: "quick-open", title: "Go to File…", symbol: "doc.text.magnifyingglass") { [weak self] in self?.showQuickOpen = true },
            PaletteAction(id: "side-chat", title: "New Side Chat", symbol: "bubble.left.and.bubble.right") { [weak self] in self?.openSideChat(about: self?.currentAbout) },
            PaletteAction(id: "move", title: "Move Claude to Another Folder…", symbol: "arrow.forward.circle") { [weak self] in self?.openFiles("~", compact: false) },
        ]
        for c in conversationList where c.id != store.currentConversationId {
            let title = conversationTitle(c.id)
            a.append(PaletteAction(id: "conv-\(c.id)", title: "Open Conversation: \(title)", symbol: "bubble.left.and.text.bubble.right") { [weak self] in self?.select(conversation: c.id, compact: false) })
            if !store.leadStatus.busy {
                a.append(PaletteAction(id: "resume-\(c.id)", title: "Resume Conversation: \(title)", symbol: "arrow.uturn.backward.circle") { [weak self] in Task { _ = await self?.resume(c.id) } })
            }
        }
        a.append(PaletteAction(id: "go-fleet", title: "Go to Fleet", symbol: "cpu") { [weak self] in self?.destination = .fleet })
        a.append(PaletteAction(id: "go-notes", title: "Show All Notes", symbol: "text.bubble") { [weak self] in self?.destination = .notes(.all) })
        for w in store.workers {
            a.append(PaletteAction(id: "go-\(w.id)", title: "Go to \(w.label)", symbol: "cpu") { [weak self] in self?.destination = .worker(w.id) })
            if w.enabled {
                a.append(PaletteAction(id: "task-\(w.id)", title: "New Task for \(w.id)…", symbol: "hammer") { [weak self] in
                    self?.destination = .lead
                    self?.draft = "@\(w.id) "
                    self?.focusComposerRequest += 1
                })
            }
        }
        for m in leadModelChoices {
            a.append(PaletteAction(id: "model-\(m.value)", title: "Claude Model: \(m.displayName)", symbol: "sparkles") { [weak self] in self?.send(.setModel(m.value)) })
        }
        a.append(PaletteAction(id: "effort-auto", title: "Claude Effort: Auto", symbol: "gauge.with.dots.needle.50percent") { [weak self] in self?.send(.setEffort(nil)) })
        for l in currentLeadModel?.effortLevels ?? [] {
            a.append(PaletteAction(id: "effort-\(l.rawValue)", title: "Claude Effort: \(effortLabel(l.rawValue))", symbol: "gauge.with.dots.needle.50percent") { [weak self] in self?.send(.setEffort(l)) })
        }
        a += [
            PaletteAction(id: "shell", title: "New Shell", symbol: "terminal") { [weak self] in self?.openTerminal(.shell) },
            PaletteAction(id: "logs", title: "Open Hub Logs", symbol: "doc.text.magnifyingglass") { [weak self] in self?.openTerminal(.hub_logs) },
            PaletteAction(id: "llmd", title: "Open llmd Status", symbol: "cpu") { [weak self] in self?.openTerminal(.llmd) },
            PaletteAction(id: "pause", title: store.dialogueState?.paused == true ? "Resume Handoffs" : "Pause Handoffs", symbol: "pause.circle") { [weak self] in
                guard let self else { return }
                self.send(.setPause(!(self.store.dialogueState?.paused ?? false)))
            },
            PaletteAction(id: "compact", title: "Compact Claude's Context", symbol: "rectangle.compress.vertical") { [weak self] in self?.send(.compact) },
            PaletteAction(id: "talk", title: "Talk with Claude", symbol: "waveform") { [weak self] in self?.toggleTalk() },
            PaletteAction(id: "dictate", title: "Dictate a Message", symbol: "mic") { [weak self] in self?.toggleDictation() },
            PaletteAction(id: "approve-next", title: "Approve Next Request", symbol: "checkmark.circle") { [weak self] in self?.approveNext() },
        ]
        return a
    }
}

enum Keychain {
    private static let service = AppIdentity.bundleID + ".hub-token"

    static func save(_ token: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

#if DEBUG
/// Writes a small status file (and an OSLog line) so test scripts can check what this device sees.
enum DebugStatus {
    @MainActor private static var pending = false

    // Coalesce bursts (streaming deltas) into one write ~200 ms later, so the final state always lands.
    @MainActor static func write(_ s: DuetStore) {
        guard !pending else { return }
        pending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            pending = false
            flush(s)
        }
    }

    @MainActor private static func flush(_ s: DuetStore) {
        let lastTurn = s.turns.last
        let status: [String: Any] = [
            "connection": "\(s.connection)",
            "lastSeq": s.lastSeq, "eventCount": s.eventCount, "gaps": s.gaps, "duplicates": s.duplicates,
            "turns": s.turns.count,
            "lastTurn": lastTurn.map {
                ["id": $0.id, "prompt": $0.prompt, "ended": $0.end != nil, "finalLines": $0.finalTotal.split(separator: "\n").count,
                 "finalTail": String($0.finalTotal.suffix(40)), "streamedEqualsFinal": $0.streamedTotal == $0.finalTotal] as [String: Any]
            } ?? [:],
            "leadPhase": s.leadStatus.label,
            "attention": s.attention.map(\.id),
            "approvals": s.resolvedApprovals.values.map { "\($0.id):\($0.decision)\($0.edited ? ":edited" : ""):\($0.by)" }.sorted(),
            "workers": s.workers.map(\.id),
            "terminals": s.terminals.map(\.id),
            "currentConversation": s.currentConversationId ?? "",
            "conversations": s.conversations.map { c in
                ["id": c.id, "turns": c.turnIds.count, "rows": c.rows.count, "tasks": c.taskIds.count, "diagrams": c.diagramIds.count, "hasContent": c.hasContent] as [String: Any]
            },
            "maxStallMs": StallMonitor.shared.maxStallMs,
            "recentMaxStallMs": StallMonitor.shared.recentMaxMs(seconds: 60),
        ]
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) else { return }
        try? data.write(to: dir.appendingPathComponent("duet-status.json"), options: .atomic)
        // Also to the unified log: on macOS other processes can't read the sandbox container.
        log.notice("status \(String(decoding: data, as: UTF8.self), privacy: .public)")
    }

    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "status")
}

/// Measures main-thread responsiveness: a 50 ms tick on the main actor; anything later than that is a stall.
@MainActor
final class StallMonitor {
    static let shared = StallMonitor()
    private(set) var maxStallMs = 0.0
    private var samples: [(Date, Double)] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        Task { @MainActor in
            while true {
                let t0 = Date()
                try? await Task.sleep(for: .milliseconds(50))
                let late = (Date().timeIntervalSince(t0) - 0.05) * 1000
                if late > 100 {
                    Logger(subsystem: AppIdentity.bundleID, category: "stall").notice("stall \(Int(late)) ms")
                }
                if late > 16 {
                    maxStallMs = max(maxStallMs, late)
                    samples.append((Date(), late))
                    samples.removeAll { $0.0 < Date().addingTimeInterval(-300) }
                }
            }
        }
    }

    func recentMaxMs(seconds: Double) -> Double {
        samples.filter { $0.0 > Date().addingTimeInterval(-seconds) }.map(\.1).max() ?? 0
    }

    func reset() {
        maxStallMs = 0
        samples = []
    }
}
#endif

/// Something you did that the iPhone answers with a tap in the hand.
struct Touch: Equatable {
    enum Kind { case sent, approved, rejected, stopped }
    let kind: Kind
    let n: Int
}

/// "Give this to Qwen3.8 27B: create unit tests for parser": a suggestion made on this device, never applied by itself.
struct RouteSuggestion: Equatable {
    let worker: String
    let name: String
    let reason: String
}

/// An approval card that has the keyboard: which approval, and its row in the thread.
struct CardInput: Equatable {
    let approvalId: String
    let rowId: String
}
