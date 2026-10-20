import DuetKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct DuetApp: App {
    @State private var model = AppModel()

    init() {
        #if os(macOS)
        // Duet has tabs of its own (docs/navigation.md); macOS merging windows into window tabs would be a second kind.
        NSWindow.allowsAutomaticWindowTabbing = false
        #endif
        #if os(iOS)
        // iOS restores the split view's last display mode at launch (its edge columns in the defaults, and UIKit's own
        // state for each window in Saved Application State), and the restored mode flips iPad portrait between tiled
        // and a dimmed overlay on every other launch. Only that is cleared, so the main window starts from
        // RegularRoot's layout each time while every window still comes back showing what it showed.
        UserDefaults.standard.removeObject(forKey: "com.apple.UIKit.UISplitViewController.Root")
        SavedWindows.forgetSplitViewLayout()
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .onAppear { model.connectIfNeeded() }
                .onOpenURL { model.handle(url: $0) }
        }
        #if os(macOS)
        .defaultSize(width: 1360, height: 860)
        // Always open the main window at launch (with a menu-bar item and restoration, macOS may otherwise open none).
        .defaultLaunchBehavior(.presented)
        #endif
        .commands { DuetCommands(model: model) }

        // Panes in windows of their own (Mac; iPad with multiple windows), each with Move to Main Window. A terminal,
        // a side chat, a file, a conversation and a diagram have groups of their own, for their sizes
        // (`Destination.windowGroup`). A tab dragged out of the main window opens where it's let go (Mac), or, dropped
        // at the iPad's screen edge, in a new window of its group, which takes the dropped place as its value.
        WindowGroup("Terminal", id: "terminal", for: String.self) { $id in
            PaneWindow(place: id.map { .terminal($0) }).environment(model)
                .opensDroppedPane { if id == nil, case .terminal(let t) = $0 { id = t } }
        }
        #if os(macOS)
        .defaultSize(width: 860, height: 520)
        .defaultWindowPlacement(undocked(CGSize(width: 860, height: 520)))
        #else
        .handlesExternalEvents(matching: [PaneActivity.condition("terminal")])
        #endif

        // A side chat in a window of its own: on Mac at the screen's trailing edge, a panel beside the app.
        WindowGroup("Side Chat", id: "side", for: SideChatRef.self) { $ref in
            SideChatWindow(ref: ref).environment(model)
                .opensDroppedPane { if ref == nil, case .sideChat(let c) = $0 { ref = SideChatRef(chatId: c) } }
        }
        #if os(macOS)
        .defaultSize(width: 440, height: 620)
        .defaultWindowPlacement { content, context in
            let size = CGSize(width: 440, height: min(680, context.defaultDisplay.visibleRect.height * 0.8))
            return undocked(size, otherwise: WindowPlacement(.trailing, size: size))(content, context)
        }
        #else
        .handlesExternalEvents(matching: [PaneActivity.condition("side")])
        #endif

        WindowGroup("File", id: "file", for: String.self) { $path in
            PaneWindow(place: path.map { .file($0) }).environment(model)
                .opensDroppedPane { if path == nil, case .file(let p, _) = $0 { path = p } }
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 760)
        .defaultWindowPlacement(undocked(CGSize(width: 900, height: 760)))
        #else
        .handlesExternalEvents(matching: [PaneActivity.condition("file")])
        #endif
        WindowGroup("Conversation", id: "conversation", for: String.self) { $id in
            PaneWindow(place: id.map { .conversation($0) }).environment(model)
                .opensDroppedPane { if id == nil, case .conversation(let c) = $0 { id = c } }
        }
        #if os(macOS)
        .defaultSize(width: 760, height: 820)
        .defaultWindowPlacement(undocked(CGSize(width: 760, height: 820)))
        #else
        .handlesExternalEvents(matching: [PaneActivity.condition("conversation")])
        #endif
        WindowGroup("Diagram", id: "diagram", for: String.self) { $id in
            PaneWindow(place: id.map { .diagram($0) }).environment(model)
                .opensDroppedPane { if id == nil, case .diagram(let d) = $0 { id = d } }
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 760)
        .defaultWindowPlacement(undocked(CGSize(width: 1000, height: 760)))
        #else
        .handlesExternalEvents(matching: [PaneActivity.condition("diagram")])
        #endif
        // Everything else: the fleet, a worker, Needs You, notes, a folder, a plan.
        WindowGroup("Doublet", id: "pane", for: Destination.self) { $place in
            PaneWindow(place: place).environment(model)
                .opensDroppedPane { if place == nil { place = $0 } }
        }
        #if os(macOS)
        .defaultWindowPlacement { content, context in
            // Each pane says its size (PaneWindow.size); small ones (a plan) sit at the screen's trailing edge, like
            // side chats.
            let size = content.sizeThatFits(.unspecified)
            return undocked(size, otherwise: size.width < 500 ? WindowPlacement(.trailing, size: size) : WindowPlacement(size: size))(content, context)
        }
        #else
        .handlesExternalEvents(matching: [PaneActivity.condition("pane")])
        #endif

        #if os(macOS)
        // Ambient: status and decisions from the menu bar, without switching apps.
        MenuBarExtra {
            MenuBarPanel().environment(model)
        } label: {
            MenuBarIcon().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model).frame(width: 480)
        }
        #endif
    }

    #if os(macOS)
    /// A pane window's placement: where its tab was let go, when it was dragged out of the main window; else
    /// `otherwise` (the group's default size and the system's position, unless it says more).
    private func undocked(_ size: CGSize, otherwise: WindowPlacement = WindowPlacement()) -> (WindowLayoutRoot, WindowPlacementContext) -> WindowPlacement {
        { [model] _, context in model.takeUndockPlacement(size, display: context.defaultDisplay, otherwise: otherwise) }
    }
    #endif
}

/// Picks the layout for the device at hand.
struct RootView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        Group {
            #if os(iOS)
            if sizeClass == .compact {
                PhoneRoot() // iPhone, or iPad in a narrow split
            } else {
                RegularRoot().environment(\.density, .regular)
            }
            #else
            RegularRoot().environment(\.density, .dense)
            #endif
        }
        // Carry on where you were on the other device (Handoff), and pick up what it hands over.
        .handoff(handoffOffer, main: true)
        // Open on iPad: what was sent, and what came from another device (iPhone; the main window of iPad and Mac
        // shows it under its toolbar, in DetailView).
        .overlay(alignment: .top) { if compact { NoticeBanner() } }
        .animation(.snappy, value: model.notice)
        .onChange(of: compact, initial: true) { _, compact in model.compactLayout = compact }
        // What's open here, for the other devices' switchers ("On Mac").
        .reportsOpenPlaces()
    }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// What the main window hands over: what the side stage shows (else the conversation), with the conversation and
    /// what you're typing. The narrow layout (iPhone, an iPad in half the screen) hands over what it shows.
    private var handoffOffer: Handoff.Offer? {
        if compact { return model.compactPlace.map { Handoff.Offer(place: $0, draft: model.draft) } }
        return Handoff.Offer(place: model.workspace.front, centre: model.workspace.centre, draft: model.draft)
    }
}

/// Duet's menus. Most work on iPad with a hardware keyboard too (hold ⌘ to see them).
struct DuetCommands: Commands {
    let model: AppModel
    @FocusedValue(\.mainWindow) private var mainWindow
    @FocusedValue(\.dockPane) private var dockPane
    @FocusedValue(\.switcherHost) private var switcherHost
    @FocusedValue(\.keepOnTop) private var keepOnTop

    /// ⌘W closes the side stage's tab on show; with the side stage closed, it closes the window.
    private var closesTab: Bool { mainWindow == true && model.workspace.staged != nil }

    /// The side stage's tabs (its Overview and the rest) to step through, or a hidden side stage to show.
    private var stepsTabs: Bool { mainWindow == true && (!model.workspace.tabs.isEmpty || !model.workspace.panelShown) }

    /// What Open on iPad sends from the Window menu: the pane in the focused window, else what the main window's side
    /// stage shows, else its conversation. Nil for a terminal, whose shell belongs to this device.
    private var inFront: Destination? {
        let place = dockPane?.place ?? (mainWindow == true ? model.workspace.front : nil)
        return place.flatMap { AppModel.sendable($0) ? $0 : nil }
    }


    /// The switcher's modifier: ⌃ on the Mac, ⌥ on iPad.
    private static var switcherModifier: EventModifiers {
        #if os(macOS)
        .control
        #else
        .option
        #endif
    }

    /// ⌃Tab started from the keyboard, with ⌃ still down: letting go of it chooses (Mac). The iPad can't tell when
    /// ⌥ is let go, so there Return or a click chooses (SwitcherPanel).
    private var holdingControl: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.control)
        #else
        false
        #endif
    }

    var body: some Commands {
        // Close Tab (⌘W) is the main window's own shortcut (CloseTabShortcut): the system's Close holds ⌘W in this
        // menu. This item shows it's there and works with the mouse.
        CommandGroup(after: .newItem) {
            Button("Close Tab") { if model.workspace.staged != nil, let tab = model.workspace.selected { model.close(tab) } }
                .disabled(!closesTab)
        }
        CommandMenu("Claude") {
            Button("Message Claude") { model.destination = .lead; model.focusComposerRequest += 1 }
                .keyboardShortcut("l")
            Button("Stop") { model.send(.interrupt) }
                .keyboardShortcut(".")
            Button("Approve Next Request") { model.approveNext() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Divider()
            Button(model.voice.isTalkingWithClaude ? "End Talk Mode" : "Talk with Claude") { model.toggleTalk() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button(model.voice.isDictating("composer") ? "Stop Dictating" : "Dictate a Message") { model.toggleDictation() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            // ⌘N is the window group's new window.
            Button("New Conversation") { model.newConversation() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.store.leadStatus.busy)
            Button("Resume This Conversation") { if let id = model.selectedConversation { Task { _ = await model.resume(id) } } }
                .disabled(model.isViewingLive || model.store.leadStatus.busy)
            Button("Newer Conversation") { model.stepConversation(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
            Button("Older Conversation") { model.stepConversation(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
            Divider()
            Button("Compact Context") { model.send(.compact) }
            Button("Pause or Resume Handoffs") { model.send(.setPause(!(model.store.dialogueState?.paused ?? false))) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("New Side Chat") { model.openSideChat(about: model.currentAbout) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Command Palette…") { model.showPalette = true }
                .keyboardShortcut("k")
        }
        // ⌘P is Go to File here, as in an editor (Duet prints nothing).
        CommandGroup(replacing: .printItem) {
            Button("Go to File…") { model.showQuickOpen = true }
                .keyboardShortcut("p")
        }
        CommandMenu("Terminal") {
            Button("New Shell") { model.openTerminal(.shell) }
                .keyboardShortcut("`", modifiers: [.control, .shift])
            Button("Hub Logs") { model.openTerminal(.hub_logs) }
            Button("llmd Status") { model.openTerminal(.llmd) }
            Divider()
            Button("Show or Hide Terminal Panel") { model.showTerminalPanel.toggle() }
                .keyboardShortcut("j")
        }
        CommandGroup(after: .sidebar) {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(model.backName == nil)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(model.forwardName == nil)
            // As in Safari and Xcode.
            Button("Show Next Tab") { model.stepTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(!stepsTabs)
            Button("Show Previous Tab") { model.stepTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(!stepsTabs)
            // Most recent first, like ⌘Tab: hold ⌃ and press Tab to move down the list, let go to go there. iPadOS keeps
            // ⌃Tab for moving the keyboard focus, so there it's ⌥Tab.
            Button("Switch to Recent Tab or Window") { if let switcherHost { model.stepSwitcher(1, in: switcherHost, holding: holdingControl) } }
                .keyboardShortcut(.tab, modifiers: Self.switcherModifier)
                .disabled(switcherHost == nil || model.workspace.recentItems.count < 2)
            Button("Switch Back Through Recent") { if let switcherHost { model.stepSwitcher(-1, in: switcherHost, holding: holdingControl) } }
                .keyboardShortcut(.tab, modifiers: Self.switcherModifier.union(.shift))
                .disabled(switcherHost == nil || model.workspace.recentItems.count < 2)
            Divider()
            Button("Needs You") { model.destination = .inbox }
                .keyboardShortcut("1")
            Button("Live Conversation") { model.destination = .lead }
                .keyboardShortcut("2")
            Button("Fleet") { model.destination = .fleet }
                .keyboardShortcut("3")
            Button(model.sidebarMode == .explorer ? "Show Conversations" : "Show Explorer") {
                model.sidebarMode = model.sidebarMode == .explorer ? .chats : .explorer
                model.columns = .all
            }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Reveal Open File in Explorer") { if let p = model.openFilePath { model.reveal(p) } }
                .disabled(model.openFilePath == nil)
            Button("Show or Hide Conversation Details") { model.toggleCards() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button(model.workspace.panelShown ? "Hide Side Panel" : "Show Side Panel") {
                if model.workspace.panelShown { model.hidePanel() } else { model.showPanel() }
            }
                .disabled(mainWindow != true)
            // Two tabs side by side in the side panel, the conversation still in the centre; or back to one.
            Button(model.workspace.split == nil ? "Split Side Panel" : "Close Split") { model.toggleSplit() }
                .keyboardShortcut("\\")
                .disabled(mainWindow != true || (model.workspace.split == nil && model.workspace.tabs.isEmpty))
            // The side panel filling the window, the conversation folded into a capsule; or back beside it.
            Button(model.workspace.zoom == nil ? StageZoomButton.fillName : "Side Panel Back Beside the Conversation") {
                model.zoomStage(model.workspace.zoom == nil ? .stage : nil)
            }
                .keyboardShortcut(.return, modifiers: [.control, .command])
                .disabled(mainWindow != true || (!model.workspace.panelShown && model.workspace.zoom == nil))
        }
        // Undock the side stage's tab or the conversation, or dock the window that has the focus.
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Move Tab to New Window") { if model.workspace.staged != nil, let tab = model.workspace.selected { model.undock(tab) } }
                .disabled(!closesTab)
            Button("Open Conversation in New Window") { model.undockCentre() }
                .disabled(mainWindow != true)
            Button("Move to Main Window") { dockPane?.run() }
                .disabled(dockPane == nil)
            #if os(macOS)
            // A pane's window above other apps' windows, like a widget.
            Toggle("Keep on Top", isOn: keepOnTop ?? .constant(false))
                .disabled(keepOnTop == nil)
            #endif
            // What's in front, on another of the user's devices: Open on iPad, Open on Mac.
            let targets = model.sendTargets
            if !targets.isEmpty {
                Divider()
                ForEach(targets) { target in
                    Button("Open on \(AppModel.deviceName(target.device, kind: target.kind))") { if let inFront { model.send(inFront, to: target) } }
                        .disabled(inFront == nil)
                }
            }
        }
    }
}
