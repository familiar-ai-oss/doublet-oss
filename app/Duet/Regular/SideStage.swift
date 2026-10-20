import DuetKit
import SwiftUI

/// The side stage: a panel beside the conversation for what supports it. Its first tab, the Overview, is the
/// conversation's cards (what needs you, the work, your notes): the list you start from and come back to. Whatever you
/// open (a file, a diff, a diagram, a worker, a terminal, notes, the plan, or a second conversation to read beside this
/// one) gets a tab after it. The conversation stays in the centre while things open and close here. The panel is a
/// column on its Overview and widens for a tab. It can split in two, a tab in each pane, and it can fill the window,
/// the conversation folded into a capsule that brings it back. Its bar has the tabs, every open tab and window, Fill
/// Window, and Hide (the tabs stay). What a tab shows keeps its actions in the panel, in a row under the pane's location
/// bar (`paneActions`): the window's toolbar is the conversation's. In a narrow window it comes over the conversation
/// instead, which shows at its edge.
struct SideStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    /// The width of the main window's centre: a tab takes its share of it (`AppModel.stageShare`).
    let available: CGFloat
    var overlay = false

    /// The least a tab and the conversation beside it get.
    static let minWidth: CGFloat = 360
    static let conversationMinWidth: CGFloat = 420
    /// Narrower than this, a split side stage shows only its focused pane.
    static let splitMinWidth: CGFloat = 561

    /// The Overview's width: a column of cards.
    static func overviewWidth(dense: Bool) -> CGFloat { dense ? 336 : 356 }

    static func width(available: CGFloat, share: CGFloat, overview: Bool, dense: Bool) -> CGFloat {
        if overview { return overviewWidth(dense: dense) }
        return min(max(available * share, minWidth), max(minWidth, available - conversationMinWidth))
    }

    var body: some View {
        let workspace = model.workspace
        let overview = workspace.overviewOnly
        let zoomed = workspace.zoom != nil
        HStack(spacing: 0) {
            if !overlay, !overview, !zoomed { StageResizeHandle(available: available) }
            VStack(spacing: 0) {
                StageBar()
                Divider()
                StagePanes()
                    // While a tab is on its way: its halves, to split it beside what it shows.
                    .overlay { StageDropZones() }
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator) }
            // The shadow comes from a plain shape behind the panel. Taken from the live page and ink inside it, it was
            // worked out again off-screen whenever the ink changed, which can make writing lag.
            .background { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background).shadow(color: .black.opacity(0.14), radius: 16, y: 6) }
            .padding(.vertical, 8).padding(.trailing, 8).padding(.leading, overlay || overview || zoomed ? 8 : 0)
        }
        .frame(width: frameWidth(overview: overview))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side panel")
        .accessibilityIdentifier("side-stage")
    }

    private func frameWidth(overview: Bool) -> CGFloat {
        let dense = density == .dense
        // Filling the window: all of the centre.
        if model.workspace.zoom != nil { return available }
        guard overlay else { return Self.width(available: available, share: model.stageShare, overview: overview, dense: dense) }
        return overview ? min(Self.overviewWidth(dense: dense), max(Self.minWidth, available - 48)) : max(Self.minWidth, available - 48)
    }
}

/// The side stage's panes: one, or two side by side with a divider between them when it's split. A split side stage
/// too narrow for both (a narrow window), or with one pane filling the window, shows that one.
private struct StagePanes: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 0

    var body: some View {
        let workspace = model.workspace
        let split = workspace.split
        let solo = soloPane(workspace)
        HStack(spacing: 0) {
            // The leading pane keeps its place whether or not the side stage is split, so what it shows (a scroll
            // position, a note being written) survives a split and its end.
            if solo != .trailing {
                StagePaneView(pane: .leading)
                    .frame(width: split != nil && solo == nil ? leadingWidth(split!.share) : nil)
            }
            if split != nil, solo == nil {
                SplitDivider(width: width - SplitDivider.width)
            }
            if split != nil, solo != .leading {
                StagePaneView(pane: .trailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The one pane on show: the only one, the one filling the window, or the focused one when both don't fit; nil when
    /// both show.
    private func soloPane(_ workspace: Workspace) -> StagePane? {
        guard workspace.split != nil else { return .leading }
        if case .pane(let p) = workspace.zoom { return p }
        return width < SideStage.splitMinWidth ? workspace.focus : nil
    }

    private func leadingWidth(_ share: CGFloat) -> CGFloat {
        max(0, (width - SplitDivider.width) * share)
    }
}

/// One of the side stage's panes: its bar (where it is; split, also Fill Window and Close for this pane) and what it
/// shows, a tab's place or the conversation's Overview. Split, the focused pane's bar has a line in the accent colour
/// along its top, and a touch anywhere in a pane focuses it.
private struct StagePaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(TabDrag.self) private var drag
    let pane: StagePane

    var body: some View {
        let workspace = model.workspace
        let tab = workspace.tab(in: pane)
        let split = workspace.split != nil
        VStack(spacing: 0) {
            if split || tab != nil {
                PaneBar(pane: pane, tab: tab, split: split, focused: split && workspace.focus == pane)
                Divider()
            }
            Group {
                if let tab {
                    PaneContent(place: tab.place)
                        .environment(\.inSidePanel, true)
                } else {
                    SupportRail(conversationId: model.activeConversationId)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // While a tab is on its way, what the pane shows takes no touches or drags: a web view in it (a diagram,
            // the plan, a file) would take the drag on the Mac, from the halves laid over it.
            .allowsHitTesting(!drag.isActive)
        }
        .contentShape(Rectangle())
        // Focus follows touch: the pane you're working in is the one ⌘W, the composer's chip and Handoff go by.
        .simultaneousGesture(TapGesture().onEnded { if split { model.focusPane(pane) } })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(split ? (pane == .leading ? "Left pane" : "Right pane") : "Side panel content")
        .accessibilityIdentifier("stage-pane-\(pane.rawValue)")
    }
}

/// A pane's bar: where it is (its location bar, or the Overview's name), and while the side stage is split, Fill Window
/// and Close for this pane.
private struct PaneBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let pane: StagePane
    let tab: PaneTab?
    let split: Bool
    let focused: Bool

    var body: some View {
        let dense = density == .dense
        let filling = model.workspace.zoom == .pane(pane)
        HStack(spacing: 0) {
            if let tab {
                LocationBar(place: tab.place)
            } else {
                Label("Overview", systemImage: "rectangle.grid.1x2")
                    .labelStyle(.titleAndIcon)
                    .font(dense ? .caption : .footnote)
                    .padding(.horizontal, 12)
                    .frame(height: dense ? 24 : 30)
                Spacer(minLength: 0)
            }
            if split {
                HStack(spacing: dense ? 6 : 10) {
                    Button(filling ? "Back Beside the Conversation" : StageZoomButton.fillName,
                           systemImage: filling ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                        model.toggleZoom(.pane(pane))
                    }
                    .help(filling ? "Put the conversation back beside it" : "This pane fills the window; the conversation folds away until you bring it back")
                    .accessibilityIdentifier("pane-fill-\(pane.rawValue)")
                    Button("Close Pane", systemImage: "xmark") { model.closePane(pane) }
                        .help("Close this pane; its tab stays in the strip")
                        .accessibilityIdentifier("pane-close-\(pane.rawValue)")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(dense ? .caption : .footnote)
                .padding(.horizontal, dense ? 8 : 12)
            }
        }
        .frame(minHeight: dense ? 24 : 30)
        .overlay(alignment: .top) {
            if focused { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
    }
}

/// Between a split side stage's panes: drag it to share the width differently, double-click (or double-tap) it to share
/// it evenly again. On iPad it's a finger's width, with a grabber, though it takes a point of the panes' room.
private struct SplitDivider: View {
    @Environment(AppModel.self) private var model
    /// The panes' room to share, less the divider.
    let width: CGFloat
    @State private var start: CGFloat?

    static let width: CGFloat = 1

    private static var reach: CGFloat {
        #if os(iOS)
        28
        #else
        8
        #endif
    }

    var body: some View {
        Rectangle().fill(.separator)
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .frame(width: Self.reach)
            #if os(iOS)
            .overlay { Capsule().fill(.secondary.opacity(0.4)).frame(width: 5, height: 44) }
            #endif
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(.columnResize)
            #endif
            // In the window's space: the divider moves with the drag.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let s = start ?? model.workspace.split?.share ?? 0.5
                    start = s
                    model.workspace.setSplitShare(s + g.translation.width / max(width, 1), save: false)
                }
                .onEnded { _ in
                    start = nil
                    model.workspace.setSplitShare(model.workspace.split?.share ?? 0.5)
                })
            .onTapGesture(count: 2) { withAnimation(.snappy) { model.workspace.setSplitShare(0.5) } }
            .padding(.horizontal, -(Self.reach - Self.width) / 2)
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

/// The side stage's bar: its tabs, then every open tab and window, Fill Window (Full Screen on iPad), and Hide. On the
/// Mac it also has Move to New Window and Open on another device; on iPad those are in a tab's ⋯ menu, and where a
/// lifted tab can be dropped.
struct StageBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    @Environment(\.supportsMultipleWindows) private var multipleWindows

    var body: some View {
        let dense = density == .dense
        HStack(spacing: 0) {
            TabStrip()
            Divider().padding(.vertical, 8)
            HStack(spacing: dense ? 10 : 16) {
                OpenItemsMenu()
                #if os(macOS)
                if multipleWindows, let tab = model.workspace.selected {
                    Button("Move to New Window", systemImage: "macwindow.badge.plus") { model.undock(tab) }
                        .help("Move \(model.title(of: tab.place)) to a window of its own")
                        .accessibilityIdentifier("stage-undock")
                }
                if let tab = model.workspace.selected { SendToDevice(place: tab.place) }
                #endif
                if !model.workspace.overviewOnly || model.workspace.zoom != nil { StageZoomButton() }
                Button("Hide Side Panel", systemImage: "xmark") { model.hidePanel() }
                    .help("Hide the side panel; its tabs stay. The toolbar's cards button shows the Overview again (⌘⌥I).")
                    .accessibilityIdentifier("stage-hide")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, dense ? 10 : 14)
        }
        .frame(height: dense ? 36 : 46)
        .background(.bar)
    }
}

/// The side stage filling the window, the conversation folded into a capsule that brings it back (⌃⌘↩, or Escape),
/// or beside the conversation again.
struct StageZoomButton: View {
    @Environment(AppModel.self) private var model

    /// What filling the window is called: Fill Window on the Mac, where Full Screen is the system's; Full Screen on iPad.
    static var fillName: String {
        #if os(macOS)
        "Fill Window"
        #else
        "Full Screen"
        #endif
    }

    var body: some View {
        let zoomed = model.workspace.zoom != nil
        Button(zoomed ? "Back Beside the Conversation" : Self.fillName,
               systemImage: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
            model.toggleZoom(.stage)
        }
        .help(zoomed ? "Put the conversation back beside the side panel (⌃⌘↩)" : "The side panel fills the window; the conversation folds away until you bring it back (⌃⌘↩)")
        .accessibilityIdentifier("stage-zoom")
    }
}

extension EnvironmentValues {
    /// Shown in the side stage, beside the conversation, rather than in a window of its own, a sheet or on iPhone.
    @Entry var inSidePanel = false
}

extension View {
    /// What a pane can do: in the toolbar of a window of its own, a sheet or the iPhone; in the side stage, in a row
    /// under its location bar, so the main window's toolbar keeps to the conversation's. A pane that can be searched
    /// passes `search`: its field goes in the toolbar (`searchable`), or at the start of that row.
    func paneActions<Actions: View>(search: Binding<String>? = nil, prompt: LocalizedStringKey = "Search",
                                    @ViewBuilder _ actions: () -> Actions) -> some View {
        modifier(PaneActions(search: search, prompt: prompt, actions: actions()))
    }
}

private struct PaneActions<Actions: View>: ViewModifier {
    @Environment(\.inSidePanel) private var inSidePanel
    let search: Binding<String>?
    let prompt: LocalizedStringKey
    let actions: Actions

    func body(content: Content) -> some View {
        content
            // The row tops the pane, however small what it shows (a spinner while it loads).
            .frame(maxWidth: inSidePanel ? .infinity : nil, maxHeight: inSidePanel ? .infinity : nil)
            .safeAreaInset(edge: .top, spacing: 0) {
                if inSidePanel { PaneActionBar(search: search, prompt: prompt) { actions } }
            }
            .modifier(Searchable(text: inSidePanel ? nil : search, prompt: prompt))
            .toolbar {
                if !inSidePanel { ToolbarItemGroup { actions } }
            }
    }
}

/// `searchable`, when there's something to search.
private struct Searchable: ViewModifier {
    let text: Binding<String>?
    let prompt: LocalizedStringKey

    func body(content: Content) -> some View {
        if let text { content.searchable(text: text, prompt: prompt) } else { content }
    }
}

/// A pane's actions in the side stage: a compact row under its location bar, its search field first if it has one.
/// The buttons line up with the side stage's own, above them.
private struct PaneActionBar<Actions: View>: View {
    @Environment(\.density) private var density
    let search: Binding<String>?
    let prompt: LocalizedStringKey
    @ViewBuilder let actions: Actions

    var body: some View {
        let dense = density == .dense
        HStack(spacing: dense ? 10 : 16) {
            if let search {
                PanelSearchField(text: search, prompt: prompt).frame(maxWidth: 320)
            }
            Spacer(minLength: 0)
            actions.fixedSize()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, dense ? 10 : 14)
        .frame(height: dense ? 30 : 40)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane-actions")
    }
}

/// A search field in that row, where `searchable` would put one in the window's toolbar.
private struct PanelSearchField: View {
    @Environment(\.density) private var density
    @Binding var text: String
    let prompt: LocalizedStringKey

    var body: some View {
        let dense = density == .dense
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .foregroundStyle(.secondary)
            }
        }
        .font(dense ? .callout : .subheadline)
        .padding(.horizontal, 8)
        .frame(height: dense ? 22 : 30)
        .background { Capsule().fill(.secondary.opacity(0.12)) }
    }
}

/// The side stage's edge: drag it to give the side stage more or less of the window, double-click (or double-tap) it to
/// switch between half the window and the most it can have. On iPad it's a finger's width, with a grabber.
private struct StageResizeHandle: View {
    @Environment(AppModel.self) private var model
    let available: CGFloat
    @State private var start: CGFloat?

    /// The most of the window's centre the side stage takes.
    static let widest: CGFloat = 0.75

    private static var reach: CGFloat {
        #if os(iOS)
        28
        #else
        8
        #endif
    }

    var body: some View {
        Color.clear
            .frame(width: Self.reach)
            #if os(iOS)
            .overlay { Capsule().fill(.secondary.opacity(0.4)).frame(width: 5, height: 44) }
            #endif
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(.columnResize)
            #endif
            // In the window's coordinates: the handle moves with the drag.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { g in
                let s = start ?? model.stageShare
                start = s
                model.stageShare = min(Self.widest, max(0.3, s - g.translation.width / max(available, 1)))
            }.onEnded { _ in start = nil })
            .onTapGesture(count: 2) {
                withAnimation(.snappy) { model.stageShare = model.stageShare < Self.widest - 0.05 ? Self.widest : 0.5 }
            }
            .accessibilityHidden(true)
    }
}
