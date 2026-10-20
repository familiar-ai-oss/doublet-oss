import DuetKit
import SwiftUI
import UniformTypeIdentifiers

/// Opens the window a menu, command or context menu asked for (`AppModel.windowRequest`). Every window carries this;
/// the first to see a request opens it and clears it, so it opens once. Opening a window for a value that's already
/// shown brings that window forward instead.
struct WindowRequests: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var multipleWindows

    func body(content: Content) -> some View {
        content.onChange(of: model.windowRequest) {
            guard let request = model.windowRequest else { return }
            model.windowRequest = nil
            // One window only (iPhone): show it here instead.
            guard multipleWindows else { model.showInPlace(request); return }
            switch request {
            case .side(let ref): openWindow(id: "side", value: ref)
            case .pane(let place): open(place)
            case .main: openWindow(id: "main")
            }
        }
    }

    /// Each kind of pane has a window group of its own, for its size; the rest share one (`Destination.windowGroup`).
    private func open(_ place: Destination) {
        let group = place.windowGroup
        switch place {
        case .file(let path, _): openWindow(id: group, value: path)
        case .conversation(let id): openWindow(id: group, value: id)
        case .lead: if let id = model.store.currentConversationId { openWindow(id: group, value: id) }
        case .diagram(let id): openWindow(id: group, value: id)
        case .terminal(let id): openWindow(id: group, value: id)
        case .sideChat(let id): openWindow(id: group, value: SideChatRef(chatId: id))
        default: openWindow(id: group, value: place)
        }
    }
}

extension View {
    func windowRequests() -> some View { modifier(WindowRequests()) }
}

extension Destination {
    /// The window group a place opens in (DuetApp): a terminal, a side chat, a file, a conversation and a diagram have
    /// groups of their own, for their sizes; everything else shares "pane".
    var windowGroup: String {
        switch self {
        case .file: "file"
        case .conversation, .lead: "conversation"
        case .diagram: "diagram"
        case .terminal: "terminal"
        case .sideChat: "side"
        default: "pane"
        }
    }
}

extension FocusedValues {
    /// The main window has the focus, so the tab commands apply to it.
    @Entry var mainWindow: Bool?
    /// A pane in a window of its own has the focus: Window › Move to Main Window docks it.
    @Entry var dockPane: DockAction?
    /// The focused window's Keep on Top (Mac): Window › Keep on Top.
    @Entry var keepOnTop: Binding<Bool>?
}

private struct ClosesIfStillEmpty: ViewModifier {
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { dismissWindow() }
        }
    }
}

/// Docks the pane in the focused window: its place back in a tab of the main window, and the window closed.
struct DockAction {
    let place: Destination
    let run: @MainActor () -> Void
}

#if os(iOS)
/// A pane as a user activity: how a tab dropped at the iPad's screen edge says what the new window shows. Its target
/// is the place's window group, which DuetApp matches with `handlesExternalEvents(matching:)`.
enum PaneActivity {
    static let type = AppIdentity.bundleID + ".pane"

    /// The condition each window group matches: no condition is part of another.
    static func condition(_ group: String) -> String { "duet.window.\(group)" }

    static func activity(for place: Destination) -> NSUserActivity {
        let activity = NSUserActivity(activityType: type)
        activity.targetContentIdentifier = condition(place.windowGroup)
        try? activity.setTypedPayload(place)
        return activity
    }

    /// The activity for a place, as a drag item carries it.
    static func data(for place: Destination) async throws -> Data {
        let activity = activity(for: place)
        return try await withCheckedThrowingContinuation { done in
            _ = activity.loadData(withTypeIdentifier: UTType.userActivity.identifier) { data, error in
                if let data { done.resume(returning: data) } else { done.resume(throwing: error ?? CocoaError(.coderInvalidValue)) }
            }
        }
    }

    static func place(_ activity: NSUserActivity) -> Destination? {
        try? activity.typedPayload(Destination.self)
    }
}
#endif

extension View {
    /// A pane's window that came back with nothing to show (what it showed couldn't be read after an update): it
    /// closes. A window opened by a dropped tab gets its place a moment after it appears, so it waits that long.
    func closesIfStillEmpty() -> some View {
        modifier(ClosesIfStillEmpty())
    }

    /// A window opened by a tab dropped at the iPad's screen edge: it starts with no value, so the dropped place
    /// becomes its value (which SwiftUI keeps for restoration, and uses to bring it forward when it's opened again).
    func opensDroppedPane(_ open: @escaping (Destination) -> Void) -> some View {
        #if os(iOS)
        onContinueUserActivity(PaneActivity.type) { if let place = PaneActivity.place($0) { open(place) } }
        #else
        self
        #endif
    }
}

#if os(iOS)
/// The windows iPadOS saved when Duet last quit (Library/Saved Application State), which it opens again at launch.
enum SavedWindows {
    /// Drops UIKit's own saved layout for the main windows, where the split view keeps its columns, and keeps each
    /// window with what SwiftUI saved for it (the place a pane's window shows). Called before any window opens.
    static func forgetSplitViewLayout() {
        let files = FileManager.default
        guard let library = files.urls(for: .libraryDirectory, in: .userDomainMask).first, let id = Bundle.main.bundleIdentifier,
              let sessions = try? files.contentsOfDirectory(at: library.appending(path: "Saved Application State/\(id).savedState"),
                                                            includingPropertiesForKeys: nil) else { return }
        for session in sessions {
            // SwiftUI names the window group each window came from in its session's userInfo.
            guard let data = try? Data(contentsOf: session.appending(path: "userInfo.data")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  info["com.apple.SwiftUI.sceneID"] as? String == "main" else { continue }
            try? files.removeItem(at: session.appending(path: "internalUserInfo.data"))
        }
    }
}

/// Reports the scene of the window it's in (iPad): the main window's, so docking a pane can bring that window back.
struct SceneReader: UIViewRepresentable {
    let found: (UISceneSession) -> Void

    func makeUIView(context: Context) -> Probe { Probe(found: found) }
    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        let found: (UISceneSession) -> Void

        init(found: @escaping (UISceneSession) -> Void) {
            self.found = found
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let session = window?.windowScene?.session { found(session) }
        }
    }
}
#endif

/// The density a window's content uses: Mac dense, iPad regular.
let windowDensity: Density = {
    #if os(macOS)
    .dense
    #else
    .regular
    #endif
}()

/// A pane in a window of its own (undocked): the place's content, with its own navigation (notes opened from a file
/// stay in its window), and in the toolbar its handle, Move to Main Window and (Mac) Keep on Top. While the window is
/// open, the workspace knows the place is here, so opening it again brings this window forward instead of adding a tab.
struct PaneWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.appearsActive) private var appearsActive
    let place: Destination?
    @State private var stack = FilesStack()
    /// Above other apps' windows, like a widget (Mac). Kept with the window, so it comes back with it.
    @SceneStorage("keepOnTop") private var keepOnTop = false

    var body: some View {
        @Bindable var stack = stack
        Group {
            if let place {
                NavigationStack(path: $stack.path) {
                    PaneContent(place: place, inWindow: true)
                        // Answers to what was asked about this pane, as sticky notes.
                        .overlay { StickyLayer(window: place) }
                        // Under the toolbar: this window sent to another device.
                        .overlay(alignment: .top) { NoticeBanner() }
                        .animation(.snappy, value: model.notice)
                        .filesDestinations()
                        .toolbar {
                            ToolbarItemGroup(placement: .navigation) {
                                PaneHandle(place: place)
                                Button("Move to Main Window", systemImage: "rectangle.stack.badge.plus") { model.dock(place) }
                                    .help("Put this back in a tab of the main window")
                                    .accessibilityIdentifier("dock-button")
                                SendToDevice(place: place)
                                #if os(macOS)
                                KeepOnTopToggle(isOn: $keepOnTop)
                                #endif
                            }
                        }
                }
                .environment(stack)
                .focusedSceneValue(\.dockPane, DockAction(place: place) { model.dock(place) })
                .onAppear { model.floated(place, window: .pane(place)) }
                .onDisappear { model.workspace.landed(place) }
                // Docked, from here or by its handle dropped on the tab bar: the pane's in a tab now.
                .onChange(of: model.docked) { _, docked in if docked?.place.identity == place.identity { dismissWindow() } }
                .onChange(of: appearsActive) { _, active in if active { model.windowActivated(place) } }
                // In front, this window is what the other device carries on with (Handoff).
                .handoff(Handoff.Offer(place: place))
                #if os(macOS)
                // A tab moved to half the screen: this window takes that half, on whichever display it is.
                .background(TakesUndockFrame { model.takeUndockFrame(for: place) })
                #endif
                .frame(idealWidth: Self.size(place).width, idealHeight: Self.size(place).height)
            } else {
                ContentUnavailableView("Nothing to show", systemImage: "macwindow")
                    .closesIfStillEmpty()
            }
        }
        .environment(\.density, windowDensity)
        // Requests from this window (Open in New Window) open even when the main window is closed.
        .windowRequests()
        .switcherHost()
        #if os(macOS)
        .keepsOnTop(keepOnTop)
        .focusedSceneValue(\.keepOnTop, $keepOnTop)
        #endif
    }

    /// The size a window opens at (Mac): a plan small, like a widget beside the app.
    static func size(_ place: Destination) -> CGSize {
        switch place {
        case .plan: CGSize(width: 420, height: 640)
        case .worker, .note, .notes: CGSize(width: 760, height: 760)
        default: CGSize(width: 900, height: 720)
        }
    }
}

/// A window's handle: the pane's symbol at the start of its toolbar. Drag it onto the main window's tabs to put the
/// pane back there, where it's dropped.
struct PaneHandle: View {
    @Environment(AppModel.self) private var model
    let place: Destination

    var body: some View {
        let title = model.title(of: place)
        let symbol = model.symbol(of: place)
        Image(systemName: symbol)
            .foregroundStyle(.secondary)
            .frame(width: Self.reach, height: Self.reach)
            .contentShape(Rectangle())
            .draggable(PaneDrag(id: PaneTab.ID(), place: place, fromWindow: true)) {
                Label(title, systemImage: symbol)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            #if os(macOS)
            .dragConfiguration(.panes)
            #endif
            .help("Drag onto the main window's tabs to put \(title) back there")
            .accessibilityLabel("\(title): drag to the main window's tabs")
            .accessibilityIdentifier("pane-handle")
    }

    /// A finger's width on iPad.
    private static var reach: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }
}

#if os(macOS)
/// A window opened for a tab moved to half the screen (Mac) takes that half as it appears, whichever display it's on:
/// a placement only knows the main display.
struct TakesUndockFrame: NSViewRepresentable {
    let take: () -> NSRect?

    func makeNSView(context: Context) -> Probe { Probe(take: take) }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        let take: () -> NSRect?

        init(take: @escaping () -> NSRect?) {
            self.take = take
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let frame = take() else { return }
            // After SwiftUI has placed the window.
            DispatchQueue.main.async { window.setFrame(frame, display: true) }
        }
    }
}

/// Keep on Top: the window floats above other apps' windows, like a widget, or goes back among them.
struct KeepOnTopToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { Label("Keep on Top", systemImage: isOn ? "pin.fill" : "pin") }
            .help(isOn ? "Stop keeping this window above other windows" : "Keep this window above other apps' windows")
            .accessibilityIdentifier("keep-on-top")
    }
}

extension View {
    /// The window this view is in floats above other apps' windows (`onTop`), or sits among them. SwiftUI sets a level
    /// only for a whole window group (`windowLevel`), so one window's is set through AppKit.
    func keepsOnTop(_ onTop: Bool) -> some View {
        background(WindowLevelSetter(onTop: onTop))
    }
}

private struct WindowLevelSetter: NSViewRepresentable {
    let onTop: Bool

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.onTop = onTop }

    final class Probe: NSView {
        var onTop = false { didSet { if onTop != oldValue { apply() } } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            window?.level = onTop ? .floating : .normal
        }
    }
}

/// Reports the window it's in (Mac): the main window's, so the ⌃Tab switcher can bring it forward.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> Probe { Probe(found: found) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        let found: (NSWindow) -> Void

        init(found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found(window) }
        }
    }
}
#endif

/// A conversation in a window of its own: the live one with its composer, or an earlier one to read.
struct ConversationPane: View {
    @Environment(AppModel.self) private var model
    let id: String?

    var body: some View {
        if let id, model.store.conversation(id) != nil {
            let live = id == model.store.currentConversationId
            LeadThread(conversationId: live ? nil : id)
                .id(id)
                .safeAreaInset(edge: .bottom, spacing: 0) { if live { Composer() } }
                .navigationTitle(model.conversationTitle(id))
                .toolbar { ToolbarItem { SideChatToolbarButton() } }
        } else {
            ContentUnavailableView("No such conversation", systemImage: "bubble.left")
        }
    }
}

/// Open on iPad (or Mac), for a toolbar: the place opens on another of the user's devices, through the hub. One device:
/// a button; more: a menu of them. Nothing when there's no other device, or for a terminal.
struct SendToDevice: View {
    @Environment(AppModel.self) private var model
    let place: Destination

    var body: some View {
        let targets = AppModel.sendable(place) ? model.sendTargets : []
        if targets.count == 1 {
            OpenOnDevices(place: place)
        } else if !targets.isEmpty {
            Menu("Open on Another Device", systemImage: "arrow.up.forward.app") {
                OpenOnDevices(place: place)
            }
            .help("Open \(model.title(of: place)) on another device")
            .accessibilityIdentifier("open-on-device")
        }
    }
}

/// A short notice at the top of the window in front (`AppModel.notice`): a place sent to another device, or one that
/// came from one. It goes by itself; one with Open waits longer.
struct NoticeBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        if let notice = model.notice, appearsActive {
            HStack(spacing: 10) {
                Image(systemName: notice.symbol).foregroundStyle(.tint)
                Text(notice.text).lineLimit(2)
                if let place = notice.place {
                    Button("Open") {
                        model.notice = nil
                        model.openHere(place, write: notice.write)
                    }
                    .bold()
                }
                Button("Dismiss", systemImage: "xmark") { withAnimation(.snappy) { model.notice = nil } }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.separator) }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.top, 8).padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(notice.place == nil ? 4 : 12))
                if model.notice?.id == notice.id { withAnimation(.snappy) { model.notice = nil } }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("notice")
        }
    }
}
