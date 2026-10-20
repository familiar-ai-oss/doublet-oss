import DuetKit
import SwiftUI

/// The side stage's tabs: its Overview first, then the rest in the order you opened them, a preview's name in
/// italics. On the Mac, drag one to reorder it, onto where it can go (beside what the side stage shows, a window of its
/// own, half the screen, another device), or out of the bar to give it a window of its own (let go outside Duet's
/// windows, or at a display's edge for half the screen). On iPad, hold one (or pull it down, or press it firmly with
/// Apple Pencil, or squeeze Apple Pencil Pro over it) to lift it, then let go of it where it goes; swiped sideways, the
/// bar scrolls. Drop a window's handle here to dock its pane.
struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(TabDrag.self) private var drag
    @State private var width: CGFloat = 0

    var body: some View {
        let workspace = model.workspace
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    OverviewChip()
                    #if os(macOS)
                    ForEach(workspace.tabs) { TabChip(tab: $0) }
                        .reorderable()
                    #else
                    ForEach(workspace.tabs) { TabChip(tab: $0) }
                    #endif
                }
                // The whole bar takes drops, not just the tabs: past the last one, a pane goes at the end.
                .frame(minWidth: max(0, width - 16), alignment: .leading)
                #if os(macOS)
                .reorderContainer(for: PaneTab.self) { workspace.move($0) }
                .dragContainer(for: PaneDrag.self, itemID: \.id) { ids in
                    workspace.tabs.filter { ids.contains($0.id) }.map(model.drag)
                }
                #endif
                .dropDestination(for: PaneDrag.self) { items, session in
                    model.drop(items, at: session.reorderDestination(for: PaneTab.self)?.position)
                }
                #if os(macOS)
                .dragConfiguration(.panes)
                .onDragSessionUpdated { session in
                    let ids = session.draggedItemIDs(for: PaneTab.ID.self)
                    switch session.phase {
                    case .initial, .active:
                        // Where it can go shows while it's dragged, the one under the pointer lit.
                        if !drag.isActive { withAnimation(.snappy(duration: 0.2)) { drag.dragging(workspace.tabs.first { ids.contains($0.id) }) } }
                        if let pointer = TabDrag.pointer { drag.track(pointer) }
                    case .ended(let operation):
                        let landing = drag.target, tab = drag.tab
                        withAnimation(.snappy(duration: 0.2)) { drag.dragging(nil) }
                        guard operation == .cancel || operation == .forbidden else { break }
                        // Nothing took it: let go over a target (over a pane's web view, which took the drag from
                        // it), it goes there; outside Duet's windows, it opens in a window there.
                        if let landing, let tab {
                            withAnimation(.snappy) { model.perform(landing, with: tab) }
                        } else {
                            model.draggedOut(ids)
                        }
                    default:
                        if drag.isActive { withAnimation(.snappy(duration: 0.2)) { drag.dragging(nil) } }
                    }
                }
                #endif
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            // The bar only slides when its tabs don't all fit.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            #if os(iOS)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.strip = $0 }
            // Where a lifted tab will go in the bar.
            .overlay(alignment: .leading) { ReorderCaret() }
            // A lifted tab near either end: the bar scrolls on, to the tabs beyond.
            .task(id: drag.edge) {
                let d = drag.edge
                guard d != 0 else { return }
                while !Task.isCancelled {
                    let ids = model.workspace.tabs.map(\.id)
                    let beyond = d > 0 ? ids.first { (drag.chips[$0]?.maxX ?? 0) > drag.strip.maxX + 1 }
                                       : ids.last { (drag.chips[$0]?.minX ?? .infinity) < drag.strip.minX - 1 }
                    if let beyond { withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(beyond, anchor: d > 0 ? .trailing : .leading) } }
                    try? await Task.sleep(for: .seconds(0.35))
                }
            }
            #endif
            // The selected tab in sight: when the side stage opens, and when a tab opens past the edge.
            .onAppear {
                guard let id = workspace.selectedId else { return }
                Task { @MainActor in proxy.scrollTo(id) }
            }
            .onChange(of: workspace.selectedId) { _, id in if let id { withAnimation(.snappy) { proxy.scrollTo(id) } } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
        .accessibilityIdentifier("tab-bar")
    }
}

#if os(iOS)
/// Where a lifted tab goes if it's let go now: a line between two tabs in the bar.
private struct ReorderCaret: View {
    @Environment(AppModel.self) private var model
    @Environment(TabDrag.self) private var drag

    var body: some View {
        if case .reorder(let before)? = drag.target, let x = x(before) {
            Capsule().fill(Color.accentColor)
                .frame(width: 3, height: 30)
                .offset(x: x - 1.5)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// In the bar: just before the tab `before`, or after the last one.
    private func x(_ before: PaneTab.ID?) -> CGFloat? {
        let frame = before.flatMap { drag.chips[$0] } ?? model.workspace.tabs.last.flatMap { drag.chips[$0.id] }.map { CGRect(x: $0.maxX + 4, y: 0, width: 0, height: 0) }
        guard let frame else { return nil }
        return frame.minX - 2 - drag.strip.minX
    }
}
#endif

/// The side stage's first tab: the conversation's Overview, its cards. It's always there and doesn't move.
struct OverviewChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let workspace = model.workspace
        let pane = workspace.overviewPane
        let selected = pane != nil
        let dense = density == .dense
        HStack(spacing: 6) {
            Image(systemName: "rectangle.grid.1x2")
                .font(dense ? .caption : .footnote)
                .foregroundStyle(selected && (workspace.split == nil || workspace.focus == pane) ? Color.accentColor : .secondary)
            Text("Overview").lineLimit(1)
                .foregroundStyle(selected ? .primary : .secondary)
            if workspace.split != nil, let pane { PaneMarker(pane: pane) }
        }
        .font(dense ? .callout : .subheadline)
        .padding(.horizontal, 10)
        .frame(minHeight: dense ? 26 : 36)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TabChip.fill(selected: selected, hovering: hovering, dark: colorScheme == .dark))
                .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture { model.showOverview() }
        .onHover { hovering = $0 }
        .help("This conversation's cards: what needs you, the plan, diagrams, notes, changes and workers")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overview")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { model.showOverview() }
        .accessibilityIdentifier("tab-overview")
    }
}

/// One tab: its symbol and name, a dot while something's happening in it, and its close button (on a tab on show,
/// or under the pointer). Click to go there; double-click to keep a preview. Its menu is a right-click away; on iPad it's
/// also behind ⋯ on a tab on show, where a touch and hold lifts the tab instead (`TabLiftGesture`).
struct TabChip: View {
    @Environment(AppModel.self) private var model
    @Environment(TabDrag.self) private var drag
    @Environment(\.density) private var density
    @Environment(\.colorScheme) private var colorScheme
    let tab: PaneTab
    @State private var hovering = false
    /// iPad: the menu a right-click opens.
    @State private var showsMenu = false

    private var dense: Bool { density == .dense }

    /// A tab on show stands up from the bar: white in light mode, a lighter grey in dark mode.
    static func fill(selected: Bool, hovering: Bool, dark: Bool) -> AnyShapeStyle {
        if selected { return dark ? AnyShapeStyle(Color.white.opacity(0.14)) : AnyShapeStyle(.background) }
        return hovering ? AnyShapeStyle(.secondary.opacity(0.12)) : AnyShapeStyle(.clear)
    }

    var body: some View {
        let workspace = model.workspace
        // On show in a pane (both, when the side stage is split); the focused one's symbol in the accent colour.
        let pane = workspace.pane(of: tab.id)
        let selected = pane != nil
        let focused = selected && (workspace.split == nil || workspace.focus == pane)
        let name = model.title(of: tab.place)
        HStack(spacing: 6) {
            Image(systemName: model.symbol(of: tab.place))
                .font(dense ? .caption : .footnote)
                .foregroundStyle(focused ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(name).italic(tab.isPreview).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(selected ? .primary : .secondary)
            if workspace.split != nil, let pane { PaneMarker(pane: pane) }
            if model.isBusy(tab.place) {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
            if tab.place == .inbox, !model.store.attention.isEmpty {
                Text("\(model.store.attention.count)").font(.caption2.bold().monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background { Capsule().fill(.orange) }
            }
            #if os(iOS)
            if selected {
                Menu {
                    TabMenu(tab: tab)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(name): more")
                .accessibilityIdentifier("tab-more")
            }
            #endif
            Button { model.close(tab) } label: {
                Image(systemName: "xmark").font(.system(size: dense ? 9 : 11, weight: .bold))
                    .frame(width: dense ? 16 : 26, height: dense ? 16 : 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(selected || hovering ? 1 : 0)
            .help("Close Tab")
        }
        .font(dense ? .callout : .subheadline)
        .padding(.leading, 10).padding(.trailing, 4)
        // As wide as its name, up to a limit: the bar's spare width stays free.
        .frame(maxWidth: 240, minHeight: dense ? 26 : 36)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Self.fill(selected: selected, hovering: hovering, dark: colorScheme == .dark))
                .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // Lifted, it waits here faintly while it's on its way.
        .opacity(drag.tab?.id == tab.id ? 0.35 : 1)
        .onTapGesture {
            // The touch that let go of a lifted tab isn't a pick.
            guard !drag.justLanded else { return }
            // Waiting to be placed: a tap on a tab puts it back.
            if drag.placing { withAnimation(.snappy) { drag.end() }; return }
            model.select(tab)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if tab.isPreview { model.keep(tab) } })
        .onHover { inside in
            hovering = inside
            // Apple Pencil over it (or a pointer): a squeeze lifts it.
            if inside {
                drag.pencilOver = tab
                TabDrag.underPencil = drag
            } else if drag.pencilOver?.id == tab.id {
                drag.pencilOver = nil
            }
        }
        #if os(macOS)
        .contextMenu { TabMenu(tab: tab) }
        #else
        // Where it is, for a lifted tab let go in the bar.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.chips[tab.id] = $0 }
        .onDisappear { drag.chips[tab.id] = nil }
        .gesture(TabLiftGesture(
            lifted: { point in
                withAnimation(.snappy(duration: 0.2)) { drag.lift(tab, at: point, order: model.workspace.tabs.map(\.id)) }
                PencilTap.play(at: point)
            },
            moved: { point in drag.move(to: point, order: model.workspace.tabs.map(\.id)) },
            ended: { point in
                let order = model.workspace.tabs.map(\.id)
                drag.move(to: point, order: order)
                // Let go where it was, or anywhere but a target: the targets stay up, to tap one (or tap away, or
                // Cancel). Letting go on the tray or a half still acts at once.
                var stays = drag.target == nil
                if case .reorder(let before)? = drag.target, let i = order.firstIndex(of: tab.id),
                   before == tab.id || before == (i + 1 < order.count ? order[i + 1] : nil) { stays = true }
                if stays {
                    withAnimation(.snappy) { drag.hold() }
                } else if let landing = drag.drop() {
                    withAnimation(.snappy) { model.perform(landing.target, with: landing.tab) }
                }
            },
            cancelled: { if drag.tab?.id == tab.id, !drag.placing { withAnimation(.snappy) { drag.end() } } },
            secondaryClick: { showsMenu = true }))
        // A right-click: its menu, beside it.
        .confirmationDialog(name, isPresented: $showsMenu, titleVisibility: .visible) { TabMenu(tab: tab) }
        #endif
        .help(tab.isPreview ? "\(name) (a preview: double-click to keep it open)" : name)
        .id(tab.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name + (tab.isPreview ? ", preview" : ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction { model.select(tab) }
        .accessibilityActions { TabMenu(tab: tab) }
        .accessibilityIdentifier("tab")
    }
}

/// Which pane of a split side stage a tab (or the Overview) is on show in: a half-filled rectangle on its chip.
struct PaneMarker: View {
    let pane: StagePane

    var body: some View {
        Image(systemName: pane == .leading ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(pane == .leading ? "on the left" : "on the right")
    }
}

/// A tab's menu: keep it; open it beside what the side stage shows, or fill the window with it; move it into a window
/// of its own or to another device; close it or the others.
struct TabMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.supportsMultipleWindows) private var multipleWindows
    let tab: PaneTab

    var body: some View {
        let workspace = model.workspace
        let pane = workspace.pane(of: tab.id)
        if tab.isPreview {
            Button("Keep Open", systemImage: "pin") { model.keep(tab) }
        }
        // Split: two tabs side by side in the side panel, the conversation still in the centre.
        if pane != .trailing {
            Button("Open to the Right", systemImage: "rectangle.righthalf.inset.filled") { model.split(tab, to: .trailing) }
        }
        if pane != .leading || workspace.split == nil {
            Button("Open to the Left", systemImage: "rectangle.lefthalf.inset.filled") { model.split(tab, to: .leading) }
        }
        if workspace.split != nil {
            Button("Close Split", systemImage: "rectangle") { model.closePane((pane ?? workspace.focus).other) }
        }
        Button(StageZoomButton.fillName, systemImage: "arrow.up.left.and.arrow.down.right") {
            model.select(tab)
            model.zoomStage(workspace.split != nil ? .pane(workspace.pane(of: tab.id) ?? workspace.focus) : .stage)
        }
        Divider()
        if multipleWindows {
            Button("Move to New Window", systemImage: "macwindow.badge.plus") { model.undock(tab) }
            #if os(iOS)
            // A window of its own that comes forward over the others, almost the whole screen.
            Button("Pop Out", systemImage: "arrow.up.forward.app") { model.openInNewWindow(tab.place, prominent: true) }
            #endif
            #if os(macOS)
            // Half the screen, as iPad split view (or let go of a tab at a display's edge).
            Button("Move to Left Half", systemImage: "rectangle.lefthalf.inset.filled") { model.tile(tab, leading: true) }
            Button("Move to Right Half", systemImage: "rectangle.righthalf.inset.filled") { model.tile(tab, leading: false) }
            #endif
        }
        // Open on iPad, Open on Mac: one for each of the user's other devices.
        OpenOnDevices(place: tab.place)
        Divider()
        Button("Close Tab", systemImage: "xmark") { model.close(tab) }
        Button("Close Other Tabs", systemImage: "xmark.square") { model.closeOthers(tab) }
            .disabled(!model.workspace.tabs.contains { $0.id != tab.id })
    }
}

/// The switcher: every open tab and window, and what the user's other devices have open ("On iPad"). Pick one to go
/// there; one from another device opens here.
struct OpenItemsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let workspace = model.workspace
        Menu {
            Section("Tabs") {
                Toggle(isOn: Binding(get: { workspace.showsOverview }, set: { _ in model.showOverview() })) {
                    Label("Overview", systemImage: "rectangle.grid.1x2")
                }
                ForEach(workspace.tabs) { t in
                    Toggle(isOn: Binding(get: { workspace.panelShown && workspace.pane(of: t.id) != nil }, set: { _ in model.select(t) })) {
                        Label(model.title(of: t.place), systemImage: model.symbol(of: t.place))
                    }
                }
            }
            if !workspace.floating.isEmpty {
                Section("Windows") {
                    ForEach(Array(workspace.floating.enumerated()), id: \.offset) { _, f in
                        Button(model.title(of: f.place), systemImage: "macwindow") { model.windowRequest = f.window }
                    }
                }
            }
            OnOtherDevices()
            Divider()
            Button("Close Other Tabs", systemImage: "xmark.square") { if let t = workspace.selected { model.closeOthers(t) } }
                .disabled(!workspace.tabs.contains { $0.id != workspace.selectedId })
        } label: {
            Label("Open Tabs and Windows", systemImage: "square.on.square")
        }
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Every open tab and window, and what your other devices have open")
        .accessibilityIdentifier("open-items")
    }
}

/// Where you are: the path down to what's showing, such as Fleet › Qwen3.8 27B, or ~ › projects › parser ›
/// Lexer.swift. Each step but the last takes you there, so it's also the way up.
struct LocationBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let place: Destination
    /// Without the first step to the sidebar's list of conversations (above the centre, where the way back is a
    /// conversation, not the list).
    var fromConversation = false

    var body: some View {
        let steps = model.trail(of: place).filter { !(fromConversation && $0.showsConversations) }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    if i > 0 {
                        Image(systemName: "chevron.forward").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    if !step.above.isEmpty {
                        // The folders above where the path starts: one tap away, in a menu.
                        Menu {
                            ForEach(Array(step.above.enumerated()), id: \.offset) { _, a in
                                Button(a.title, systemImage: "folder") { go(a) }
                            }
                        } label: {
                            Text(step.title)
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("The folders above: " + step.above.map(\.title).joined(separator: " › "))
                        .accessibilityLabel("Folders above")
                    } else if i < steps.count - 1, step.goes {
                        Button { go(step) } label: { label(step) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    } else {
                        label(step).foregroundStyle(i == steps.count - 1 ? .primary : .secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        // From the leading edge when it fits; scrolled to its end (where you are) when it doesn't.
        .defaultScrollAnchor(.leading, for: .alignment)
        .defaultScrollAnchor(.trailing, for: .initialOffset)
        .font(density == .dense ? .caption : .footnote)
        .frame(height: density == .dense ? 24 : 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Location")
        .accessibilityIdentifier("location-bar")
    }

    private func label(_ step: TrailStep) -> some View {
        Label {
            Text(step.title).lineLimit(1)
        } icon: {
            if let s = step.symbol { Image(systemName: s) }
        }
        .labelStyle(.titleAndIcon)
    }

    private func go(_ step: TrailStep) {
        if let place = step.place {
            model.show(place)
        } else if step.showsConversations {
            model.sidebarMode = .chats
            model.columns = .all
        } else if step.showsOverview {
            model.showOverview()
        }
    }
}

/// One step on the way down to a place: its name, and where it goes.
struct TrailStep: Hashable {
    let title: String
    var symbol: String? = nil
    var place: Destination? = nil
    /// The conversations: the sidebar's list of them.
    var showsConversations = false
    /// The side stage's Overview: the cards a place was picked from.
    var showsOverview = false
    /// A "…" step: the folders above where the path starts, top first, in a menu.
    var above: [TrailStep] = []

    var goes: Bool { place != nil || showsConversations || showsOverview || !above.isEmpty }
}

extension AppModel {
    /// The way down to a place, from the top: Conversations › its name; Fleet › a worker; ~ › projects › a file; the
    /// conversation a diagram, a side chat or a plan belongs to › it.
    func trail(of d: Destination) -> [TrailStep] {
        let here = TrailStep(title: title(of: d), symbol: symbol(of: d))
        switch d {
        case .lead, .conversation:
            return [TrailStep(title: "Conversations", showsConversations: true), here]
        case .inbox, .fleet, .notes(.all):
            return [here]
        case .worker:
            return [TrailStep(title: "Fleet", place: .fleet), here]
        case .terminal:
            return [TrailStep(title: "Terminals"), here]
        case .diagram, .sideChat, .plan:
            guard let c = conversationPlace(of: d) else { return [here] }
            return [TrailStep(title: title(of: c), place: c), here]
        case .files(let root):
            // The folder itself is the last step.
            var steps = folders(root ?? store.leadCwd)
            guard !steps.isEmpty else { return [here] }
            steps[steps.count - 1].symbol = "folder"
            return steps
        case .file(let path, _):
            return folders((path as NSString).deletingLastPathComponent) + [here]
        case .notes(.file(let p)):
            return [TrailStep(title: Paths.name(p), place: .file(p)), here]
        case .notes(.diagram(let id)):
            return [TrailStep(title: title(of: .diagram(id)), place: .diagram(id)), here]
        case .note:
            // A thread, under the conversation it's in.
            guard let c = conversationPlace(of: d) else { return [TrailStep(title: "Notes", place: .notes(.all)), here] }
            return [TrailStep(title: title(of: c), place: c), here]
        case .outside:
            // The Running Elsewhere card lists them, on the Overview.
            return [TrailStep(title: "Running elsewhere", symbol: "rectangle.on.rectangle", showsOverview: true), here]
        case .diff(_, let worker):
            // The Changes card lists them, on the Overview.
            return [TrailStep(title: "Changes", symbol: "plus.forwardslash.minus", showsOverview: true),
                    TrailStep(title: workerName(worker), place: .worker(worker)), here]
        }
    }

    /// A folder's steps, each opening the file viewer there. Inside the folder Claude works in, they start at that
    /// folder, with the folders above it behind "…" (going up stays one tap away, but isn't the first step). Elsewhere
    /// they run from home (~) down, or from the root for a folder outside home, and a long way down keeps its last
    /// three, the rest behind "…".
    private func folders(_ path: String?) -> [TrailStep] {
        guard let path, !path.isEmpty else { return [] }
        let underHome = Paths.short(path).hasPrefix("~")
        let all: [TrailStep] = Paths.ancestors(path).compactMap { a in
            let short = Paths.short(a)
            if underHome, !short.hasPrefix("~") { return nil }
            return TrailStep(title: short == "~" ? "~" : Paths.name(a), place: .files(a))
        }
        func trimmed(_ p: String) -> String { p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p }
        if let cwd = store.leadCwd.map(trimmed), let i = all.firstIndex(where: { $0.place == .files(cwd) }), i > 0 {
            return [TrailStep(title: "…", above: Array(all[..<i]))] + all[i...]
        }
        if all.count > 4 {
            return [TrailStep(title: "…", above: Array(all.dropLast(3)))] + all.suffix(3)
        }
        return all
    }
}
