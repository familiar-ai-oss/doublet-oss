import DuetKit
import SwiftUI

// The side stage's panes, and where a tab can go: split beside another, the side stage filling the window, a window of
// its own, half the Mac's screen, or another device (docs/navigation.md, "Panes, and where a tab goes").

extension AppModel {
    /// The side stage split: this tab (nil: the Overview) in the pane on `side`, beside what it shows.
    func split(_ tab: PaneTab?, to side: StagePane) {
        moving { workspace.split(tab?.id, to: side) }
    }

    /// A place in the side stage's pane on `side`, beside what it shows: any place, an earlier conversation, a side chat
    /// or a session running elsewhere too, to read beside the conversation in the centre. One floating in a window of
    /// its own comes forward there instead.
    func openBeside(_ place: Destination, on side: StagePane = .trailing) {
        var place = place
        if case .conversation(let id) = place, id == store.currentConversationId { place = .lead }
        if let window = workspace.window(for: place) {
            windowRequest = window
            return
        }
        moving { workspace.open(place, beside: side) }
    }

    /// One of a split side stage's panes closed: the other is its only pane.
    func closePane(_ pane: StagePane) {
        moving { workspace.closePane(pane) }
    }

    /// The pane you're working in (focus follows touch). Not a step of Back and Forward.
    func focusPane(_ pane: StagePane) {
        workspace.focus(pane)
    }

    /// ⌘\: the side stage split (the tab shown before beside what it shows), or back to the focused pane alone.
    func toggleSplit() {
        if workspace.split != nil {
            closePane(workspace.focus.other)
        } else {
            moving { workspace.splitBesideRecent() }
        }
    }

    /// The side stage (or one of its panes) filling the window, the conversation folded into a capsule; nil: beside the
    /// conversation again.
    func zoomStage(_ zoom: StageZoom?) {
        withAnimation(.snappy) { workspace.zoom(zoom) }
    }

    /// Filling the window, or back beside the conversation.
    func toggleZoom(_ zoom: StageZoom) {
        zoomStage(workspace.zoom == zoom ? nil : zoom)
    }
}

/// Where a lifted (iPad) or dragged (Mac) tab can go.
enum DropTarget: Hashable {
    /// Back in the strip, before this tab (nil: at the end).
    case reorder(before: PaneTab.ID?)
    /// Beside what the side stage shows, on this side of it.
    case split(StagePane)
    /// A window of its own (Mac, and iPad with more than one window).
    case newWindow
    /// Half the Mac's screen, as iPad split view: the leading half or the trailing one.
    case screenHalf(leading: Bool)
    /// Another of the user's devices (its name to the hub).
    case device(String)
    /// The side stage filling the window, showing it.
    case fullScreen
}

/// A tab on its way somewhere, in one main window: lifted out of the strip and held (iPad: a finger or Apple Pencil
/// moves it, and letting go drops it where it is), or placed (iPad: lifted by a squeeze of Apple Pencil Pro, it waits for
/// a tap on where it goes), or in a system drag (Mac). While it's on its way, the window shows where it can go: the two
/// halves of the side stage, and a tray over the conversation. On iPad each of those reports where it is
/// (`dropTarget`), for finding what's under the touch; on the Mac each takes the drop itself.
@MainActor
@Observable
final class TabDrag {
    /// The tab on its way.
    private(set) var tab: PaneTab?
    /// Lifted by a squeeze: it waits for a tap on a target, rather than following a touch.
    private(set) var placing = false
    /// Where the touch is, in the window (iPad).
    private(set) var location: CGPoint = .zero
    /// What's under it.
    private(set) var target: DropTarget?
    /// Held near the strip's start (-1) or end (1), so the strip scrolls on (iPad); 0 elsewhere.
    private(set) var edge = 0
    /// Where each target is in the window (iPad), as its view reports it.
    @ObservationIgnored var frames: [DropTarget: CGRect] = [:]
    /// The strip, and each tab in it, in the window (iPad): where a tab let go in the strip goes.
    @ObservationIgnored var strip: CGRect = .zero
    @ObservationIgnored var chips: [PaneTab.ID: CGRect] = [:]
    /// When the last one landed: the touch that let go doesn't also pick a tab.
    @ObservationIgnored private(set) var landed: Date = .distantPast
    /// The tab Apple Pencil hovers over (iPad), for a squeeze to lift.
    @ObservationIgnored var pencilOver: PaneTab?
    /// The target Apple Pencil hovers over while a tab waits to be placed, for a squeeze to choose it.
    @ObservationIgnored var pencilTarget: DropTarget?
    /// Does what a target is chosen for (set by the window).
    @ObservationIgnored var choose: ((DropTarget, PaneTab) -> Void)?

    /// The window whose strip Apple Pencil hovers over: a squeeze there lifts that tab (`AppModel.squeezeLiftsTab`).
    static weak var underPencil: TabDrag?

    /// Apple Pencil Pro squeezed, for a squeeze handler with no model at hand (a UIKit view's `UIPencilInteraction`):
    /// the tab the Pencil hovers over lifts (true), and the squeeze should do nothing else. Over a tab a squeeze lifts
    /// it, over a note it brings out the note's palette, anywhere else it does what it did.
    static func squeezeLiftsTab() -> Bool { underPencil?.squeezeLift() ?? false }

    var isActive: Bool { tab != nil }

    /// A tap that came with letting go of a tab: not a pick.
    var justLanded: Bool { Date().timeIntervalSince(landed) < 0.35 }

    /// Lifted, here (in the window).
    func lift(_ tab: PaneTab, at point: CGPoint, placing: Bool = false, order: [PaneTab.ID]) {
        if self.tab == nil { ProblemReports.note("tab lift") }
        self.tab = tab
        self.placing = placing
        location = point
        target = placing ? nil : hit(point, order: order)
    }

    /// Moved, here.
    func move(to point: CGPoint, order: [PaneTab.ID]) {
        guard tab != nil, !placing else { return }
        location = point
        let t = hit(point, order: order)
        if t != target { target = t }
        let e = !strip.insetBy(dx: -24, dy: -40).contains(point) ? 0 : point.x < strip.minX + 44 ? -1 : point.x > strip.maxX - 44 ? 1 : 0
        if e != edge { edge = e }
    }

    /// The Mac: a tab in a system drag, or none.
    func dragging(_ tab: PaneTab?) {
        if tab?.id != self.tab?.id { self.tab = tab }
        if tab == nil { target = nil }
    }

    /// The Mac: the drag is at this point in the window. What's under it is found from where the targets are, as on
    /// iPad: AppKit hands a drag to the view under the pointer, and over a web view in a pane (a diagram, the plan, a
    /// file) that's the web view, so a target laid over it never hears of the drag.
    func track(_ point: CGPoint) {
        let t = frames.first { $0.value.contains(point) }?.key
        if t != target { target = t }
    }

    #if os(macOS)
    /// The pointer, in the key window's SwiftUI coordinates (`.global`: from the top left of its content): where a tab
    /// in a system drag is. (The drag session's own locations are its view's, and lag the pointer.)
    static var pointer: CGPoint? {
        guard let window = NSApp.keyWindow, let content = window.contentView else { return nil }
        let p = content.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return content.isFlipped ? p : CGPoint(x: p.x, y: content.bounds.height - p.y)
    }
    #endif

    /// Let go: the tab and where it goes (nil: nowhere, so it goes back).
    func drop() -> (tab: PaneTab, target: DropTarget)? {
        defer { end() }
        guard let tab, let target else { ProblemReports.note("tab drop: nowhere"); return nil }
        ProblemReports.note("tab drop: \(target)")
        return (tab, target)
    }

    /// Let go away from any target (iPad): it waits, the targets still up, for a tap on one.
    func hold() {
        guard tab != nil else { return }
        ProblemReports.note("tab held for a target")
        landed = Date()
        placing = true
        target = nil
        edge = 0
    }

    func end() {
        if tab != nil { landed = Date() }
        tab = nil
        target = nil
        placing = false
        edge = 0
    }

    /// What's at a point in the window: a place in the strip (before the first tab whose middle is past it), or a
    /// target's view.
    private func hit(_ point: CGPoint, order: [PaneTab.ID]) -> DropTarget? {
        if strip.insetBy(dx: 0, dy: -6).contains(point) {
            let before = order.first { id in chips[id].map { point.x < $0.midX } ?? false }
            return .reorder(before: before)
        }
        return frames.first { $0.value.contains(point) }?.key
    }

    /// Apple Pencil Pro squeezed: the tab it hovers over lifts, to be placed with a tap. True when one did (or one is
    /// waiting to be placed), so the squeeze does nothing else.
    func squeezeLift() -> Bool {
        if placing {
            // Waiting to be placed: a squeeze over one of the targets chooses it.
            if let over = pencilTarget, let tab {
                end()
                choose?(over, tab)
            }
            return true
        }
        guard let tab = pencilOver, let frame = chips[tab.id] else { return false }
        lift(tab, at: CGPoint(x: frame.midX, y: frame.maxY + 24), placing: true, order: [])
        #if os(iOS)
        PencilTap.play(at: CGPoint(x: frame.midX, y: frame.midY))
        #endif
        return true
    }
}

extension AppModel {
    /// Apple Pencil Pro squeezed: if it hovers over a tab, the tab lifts, to be placed with a tap (true). Every squeeze
    /// handler asks this first: over a tab a squeeze lifts it, over a note it brings out the note's palette, and
    /// anywhere else it does what it did (sends what's written, or opens a side chat).
    func squeezeLiftsTab() -> Bool { TabDrag.squeezeLiftsTab() }

    /// A tab dropped where it goes.
    func perform(_ target: DropTarget, with tab: PaneTab) {
        switch target {
        case .reorder(let before):
            workspace.move([tab.id], before: before)
        case .split(let side):
            split(tab, to: side)
        case .newWindow:
            openInNewWindow(tab.place)
        case .screenHalf(let leading):
            #if os(macOS)
            tile(tab, leading: leading)
            #else
            _ = leading
            #endif
        case .device(let name):
            if let device = sendTargets.first(where: { $0.device == name }) { send(tab.place, to: device) }
        case .fullScreen:
            select(tab)
            zoomStage(workspace.split != nil ? .pane(workspace.pane(of: tab.id) ?? workspace.focus) : .stage)
        }
    }

    /// Tabs dropped on a target by a system drag (Mac), from this window's strip or another's.
    func perform(_ target: DropTarget, with items: [PaneDrag]) {
        for item in items {
            if let tab = workspace.tabs.first(where: { $0.id == item.id }) {
                perform(target, with: tab)
            } else if case .newWindow = target {
                openInNewWindow(item.place)
            }
        }
    }

    /// A place in a window of its own: on iPad a new window beside the app (`prominent`: one that comes forward over
    /// the others, almost the whole screen, which is Pop Out); on the Mac, a window as Move to New Window opens. A tab
    /// showing it moves there.
    func openInNewWindow(_ place: Destination, prominent: Bool = false) {
        #if os(iOS)
        guard UIApplication.shared.supportsMultipleScenes else { return showInPlace(.pane(place)) }
        if let tab = workspace.tab(for: place) { close(tab) }
        let options = UIWindowScene.ActivationRequestOptions()
        options.placement = prominent ? UIWindowSceneProminentPlacement() : UIWindowSceneStandardPlacement()
        var request = UISceneSessionActivationRequest(role: .windowApplication)
        // The window group that shows it takes it (`opensDroppedPane`), as with a tab dropped at the screen's edge.
        request.userActivity = PaneActivity.activity(for: place)
        request.options = options
        UIApplication.shared.activateSceneSession(for: request) { [weak self] error in
            Task { @MainActor in
                self?.notice = Notice(text: "Couldn't open a window: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
        #else
        openWindow(.pane(place))
        #endif
    }
}

extension View {
    /// Where a tab on its way can go: on iPad this view says where it is in the window, for finding what's under the
    /// touch; on the Mac it takes the drop.
    func dropTarget(_ target: DropTarget) -> some View {
        modifier(DropTargetModifier(target: target))
    }
}

private struct DropTargetModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(TabDrag.self) private var drag
    let target: DropTarget

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { drag.frames[target] = $0 }
            .onDisappear { drag.frames[target] = nil }
            // Apple Pencil over it while a tab waits to be placed: a squeeze chooses it.
            .onHover { inside in
                if inside { drag.pencilTarget = target } else if drag.pencilTarget == target { drag.pencilTarget = nil }
            }
            #if os(macOS)
            // Where it can, the target takes the drop itself (over the conversation); over a pane's web view the
            // drag ends unclaimed, and the strip performs it (`TabStrip`).
            .dropDestination(for: PaneDrag.self) { items, _ in
                model.perform(target, with: items)
                drag.end()
                return true
            }
            #endif
    }
}

/// While a tab is on its way: the side stage's two halves, to split it beside what the side stage shows. Over the
/// side stage's panes.
struct StageDropZones: View {
    @Environment(AppModel.self) private var model
    @Environment(TabDrag.self) private var drag

    var body: some View {
        if drag.isActive {
            HStack(spacing: 10) {
                zone(.leading)
                zone(.trailing)
            }
            .padding(12)
            .background { PlacingDismiss() }
            .transition(.opacity)
        }
    }

    private func zone(_ side: StagePane) -> some View {
        Button {
            place(.split(side))
        } label: {
            // The look follows what's under the drag in a view of its own: redrawn mid-drag, the drop target itself lost
            // track of the drag on the Mac.
            ZoneLook(side: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .dropTarget(.split(side))
        .accessibilityLabel(side == .leading ? "Open on the Left" : "Open on the Right")
        .accessibilityIdentifier("drop-split-\(side.rawValue)")
    }

    /// A squeezed tab, placed with a tap.
    private func place(_ target: DropTarget) {
        if drag.placing, let tab = drag.tab {
            drag.end()
            withAnimation(.snappy) { model.perform(target, with: tab) }
        }
    }
}

/// One of the side stage's halves while a tab is on its way: lit when the tab is over it.
private struct ZoneLook: View {
    @Environment(TabDrag.self) private var drag
    let side: StagePane

    var body: some View {
        let targeted = drag.target == .split(side)
        VStack(spacing: 8) {
            Image(systemName: side == .leading ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled")
                .font(.title)
            Text(side == .leading ? "Open on the Left" : "Open on the Right").font(.callout.weight(.medium))
        }
        .foregroundStyle(targeted ? Color.white : Color.accentColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: targeted ? [] : [6, 5]))
        }
    }
}

/// While a tab is on its way, over the conversation: the other places it can go. A window of its own, half the Mac's
/// screen, each of the user's other devices, or the side stage filling the window with it.
struct CentreDropTray: View {
    @Environment(AppModel.self) private var model
    @Environment(TabDrag.self) private var drag
    @Environment(\.supportsMultipleWindows) private var multipleWindows

    var body: some View {
        if drag.isActive, let tab = drag.tab {
            VStack(spacing: 10) {
                Text(drag.placing ? "Tap where \(model.title(of: tab.place)) goes" : "Drop \(model.title(of: tab.place)) on where it goes")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1)
                // Tiles wrap onto more rows in a narrow window.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { tiles(for: tab) }
                    VStack(spacing: 10) { tiles(for: tab) }
                }
                if drag.placing {
                    Button("Cancel") { withAnimation(.snappy) { drag.end() } }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator) }
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
            .padding(16)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("drop-tray")
        }
    }

    @ViewBuilder private func tiles(for tab: PaneTab) -> some View {
        if multipleWindows {
            tile(.newWindow, "New Window", "macwindow.badge.plus")
        }
        #if os(macOS)
        tile(.screenHalf(leading: true), "Left Half", "rectangle.lefthalf.inset.filled")
        tile(.screenHalf(leading: false), "Right Half", "rectangle.righthalf.inset.filled")
        #endif
        if AppModel.sendable(tab.place) {
            ForEach(model.sendTargets) { d in
                tile(.device(d.device), "Open on \(AppModel.deviceName(d.device, kind: d.kind))", AppModel.deviceSymbol(d), dim: !d.online)
            }
        }
        tile(.fullScreen, StageZoomButton.fillName, "arrow.up.left.and.arrow.down.right")
    }

    private func tile(_ target: DropTarget, _ title: String, _ symbol: String, dim: Bool = false) -> some View {
        Button {
            if drag.placing, let tab = drag.tab {
                drag.end()
                withAnimation(.snappy) { model.perform(target, with: tab) }
            }
        } label: {
            // Lit in a view of its own, so the drop target isn't redrawn mid-drag (`ZoneLook`).
            TileLook(target: target, title: title, symbol: symbol, dim: dim)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .dropTarget(target)
        .accessibilityLabel(title)
        .accessibilityIdentifier("drop-\(title)")
    }
}

/// A tile of the tray: lit when the tab is over it.
private struct TileLook: View {
    @Environment(TabDrag.self) private var drag
    let target: DropTarget
    let title: String
    let symbol: String
    let dim: Bool

    var body: some View {
        let targeted = drag.target == target
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2)
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(targeted ? Color.white : dim ? Color.secondary : Color.primary)
        .frame(width: 112, height: 76)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(targeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.background.secondary))
        }
        .scaleEffect(targeted ? 1.06 : 1)
        .animation(.snappy(duration: 0.15), value: targeted)
    }
}

/// While a tab waits to be placed (let go away from a target, or lifted by a squeeze): a tap here, away from the
/// targets, puts it back.
struct PlacingDismiss: View {
    @Environment(TabDrag.self) private var drag

    var body: some View {
        if drag.placing {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy) { drag.end() } }
                .accessibilityHidden(true)
        }
    }
}

/// The lifted tab following the finger or Pencil (iPad), over everything; and, while it's over the strip, nothing
/// else (the strip shows where it'll go).
struct LiftedTabGhost: View {
    @Environment(AppModel.self) private var model
    @Environment(TabDrag.self) private var drag

    var body: some View {
        GeometryReader { geo in
            if let tab = drag.tab, !drag.placing {
                let origin = geo.frame(in: .global).origin
                Label(model.title(of: tab.place), systemImage: model.symbol(of: tab.place))
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5) }
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
                    .scaleEffect(1.05)
                    .fixedSize()
                    // Just under and beside the touch, so the finger doesn't hide it.
                    .position(x: drag.location.x - origin.x + 8, y: drag.location.y - origin.y + 30)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
