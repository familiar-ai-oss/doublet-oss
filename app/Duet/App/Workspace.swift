import Foundation
import DuetKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// A tab of the main window's side stage (after its Overview): the place it shows, and whether it's a preview (opened
/// with a single click, so the next single click reuses it, as in Xcode and VS Code).
struct PaneTab: Identifiable, Hashable, Codable {
    var id = UUID()
    var place: Destination
    var isPreview = false
}

/// A pane being dragged: a tab of the side stage, or the pane a window shows (from the handle in its toolbar). Dropped
/// on the side stage's tabs it docks there. On iPad, dropped at the screen's edge, it opens in a window of its own.
struct PaneDrag: Codable, Transferable {
    /// The tab's id; a window's pane gets a new one.
    var id: PaneTab.ID
    var place: Destination
    /// Dragged from a window: it's in a window already, so the iPad's screen edge doesn't open another.
    var fromWindow = false

    static var transferRepresentation: some TransferRepresentation {
        // Only Duet sees the pane itself: dropped on the Files app it would become a file (the Mac's pasteboard has no
        // such limit, so there a pane's drag stays in the app: `DragConfiguration.panes`).
        CodableRepresentation(contentType: .duetPane)
            .visibility(.ownProcess)
        #if os(iOS)
        // What iPadOS looks for to open a new window at the screen's edge: a user activity (DuetApp opens the place).
        DataRepresentation(exportedContentType: .userActivity) { try await PaneActivity.data(for: $0.place) }
            .exportingCondition { !$0.fromWindow }
        #endif
    }
}

#if os(macOS)
extension DragConfiguration {
    /// A pane's drag stays in Duet: let go over another app (Finder would save it as a file), nothing takes it, and
    /// outside Duet's windows the tab opens in a window there.
    static var panes: DragConfiguration { DragConfiguration(operationsWithinApp: .init(allowCopy: true), operationsOutsideApp: .init(allowCopy: false)) }
}
#endif

extension UTType {
    /// A pane dragged between Duet's windows (declared in project.yml).
    static let duetPane = UTType(exportedAs: AppIdentity.bundleID + ".pane")
    /// UIKit's type for a user activity in a drag: `NSUserActivity` writes itself as this.
    static let userActivity = UTType(importedAs: "com.apple.uikit.useractivity")
}

/// A pane in a window of its own, and how to bring that window forward again.
struct Floating: Equatable {
    let place: Destination
    let window: WindowRequest
}

/// Where the main window is: the conversation in its centre, and what the side stage beside it shows (its focused
/// pane's tab's place, or nil for the Overview), and whether the side stage shows at all. Back and Forward step between
/// these.
struct Location: Equatable {
    var centre: Destination
    var stage: Destination?
    var panel: Bool
}

/// One of the side stage's panes. Split, it shows two side by side; otherwise only the leading one.
enum StagePane: String, Codable, Hashable {
    case leading, trailing

    var other: StagePane { self == .leading ? .trailing : .leading }
}

/// The side stage split in two: what the trailing pane shows (a tab, or nil for the Overview), and the share of the
/// side stage's width the leading pane takes.
struct StageSplit: Codable, Equatable {
    var trailing: PaneTab.ID?
    var share: CGFloat = 0.5

    static let shares: ClosedRange<CGFloat> = 0.25...0.75
}

/// The side stage filling the main window, the conversation folded away until you bring it back: all of it, or one of
/// its panes when it's split.
enum StageZoom: Equatable {
    case stage
    case pane(StagePane)
}

/// The main window's layout (iPad and Mac): a conversation in the centre, always, and beside it the side stage, a
/// panel whose first tab is the conversation's Overview (its cards) and whose other tabs hold everything that supports
/// it (files, diffs, diagrams, workers, terminals, notes, the plan; and a second conversation, a side chat or a session
/// running elsewhere, to read beside the one in the centre). The side stage can split in two, a tab in each pane (or the
/// Overview in one); the focused pane is the one ⌘W, the composer's chip, Handoff and Back go by. Places floating in
/// windows of their own are tracked too. A place is open once: opening it again selects its tab. The layout is saved,
/// so it comes back at launch.
@MainActor
@Observable
final class Workspace {
    /// The conversation in the centre: the live one, an earlier one, or a side chat (a subconversation of one).
    private(set) var centre: Destination = .lead
    /// The side stage's tabs after its Overview, in the order they were opened (or dragged into).
    private(set) var tabs: [PaneTab] = []
    /// What the leading pane shows (the side stage's only pane unless it's split): a tab, or nil for the Overview.
    private(set) var leadingId: PaneTab.ID?
    /// The side stage split in two (nil: one pane).
    private(set) var split: StageSplit?
    /// The pane with the focus (always the leading one unless split).
    private(set) var focus: StagePane = .leading
    /// The side stage filling the window; nil: beside the conversation. Not saved.
    private(set) var zoom: StageZoom?
    /// The side stage shows, beside the conversation (or over it, in a narrow window). Hidden, it keeps its tabs.
    private(set) var panelShown = true
    /// In the order their windows opened. Opening one of these places brings its window forward instead of adding a tab.
    private(set) var floating: [Floating] = []
    /// Places most recently shown first, tabs and windows alike: the order the ⌃Tab switcher lists them in.
    private(set) var recent: [Destination] = []
    @ObservationIgnored private let key: String?
    @ObservationIgnored private let defaults: UserDefaults

    /// `key`: where the layout is saved (nil: nowhere, for previews), in `defaults`.
    init(savingAs key: String?, in defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        if let key, let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            restore(saved)
        }
        touch(front)
    }

    /// The tab with this id.
    func tab(id: PaneTab.ID?) -> PaneTab? { id.flatMap { id in tabs.first { $0.id == id } } }
    /// What a pane shows: a tab's id, or nil for the Overview.
    func tabId(in pane: StagePane) -> PaneTab.ID? { pane == .leading ? leadingId : split?.trailing }
    func tab(in pane: StagePane) -> PaneTab? { tab(id: tabId(in: pane)) }
    /// The panes on show: the leading one, and the trailing one when split.
    var panes: [StagePane] { split == nil ? [.leading] : [.leading, .trailing] }
    /// The pane showing a tab, if one does.
    func pane(of id: PaneTab.ID) -> StagePane? { panes.first { tabId(in: $0) == id } }
    /// The pane showing the Overview, if one does.
    var overviewPane: StagePane? { panes.first { tabId(in: $0) == nil } }

    /// The focused pane's tab (nil: the Overview): what ⌘W closes and Move to New Window moves.
    var selectedId: PaneTab.ID? { tabId(in: focus) }
    var selected: PaneTab? { tab(in: focus) }
    /// What the side stage shows, while its focused pane shows a tab.
    var staged: Destination? { panelShown ? selected?.place : nil }
    /// A pane of the side stage shows the Overview, the conversation's cards.
    var showsOverview: Bool { panelShown && overviewPane != nil }
    /// The side stage is the Overview alone, a column of cards; with a tab in it, it's wider.
    var overviewOnly: Bool { split == nil && leadingId == nil }
    /// Where you are: what the side stage shows, else the conversation.
    var front: Destination { staged ?? centre }
    var location: Location { Location(centre: centre, stage: staged, panel: panelShown) }

    /// The tab showing a place (a file at any line, the file viewer at any folder).
    func tab(for place: Destination) -> PaneTab? {
        let key = place.identity
        return tabs.first { $0.place.identity == key }
    }

    // MARK: the centre and the side stage

    /// Show a place. A conversation goes in the centre (a tab showing it beside closes: it's open once). Anything else
    /// goes in the side stage (which shows): its own tab (now at `place`, such as a file's new line or the file viewer's
    /// new folder), its pane focused if it's on show; else the preview tab reused, unless the other pane shows it; else
    /// a new tab after the selected one. It shows in the focused pane. `keep`: a kept tab, not a preview.
    func open(_ place: Destination, keep: Bool = false) {
        if place.inCentre {
            setCentre(place)
        } else {
            openTab(place, keep: keep)
        }
        touch(place)
        save()
    }

    /// A conversation in the centre. Shown beside in a pane before, its tab closes, so it's open once.
    private func setCentre(_ place: Destination) {
        centre = place
        if let tab = tab(for: place) { remove(tab.id) }
    }

    /// A place in a tab, shown in the focused pane (or focusing the pane that shows it already).
    private func openTab(_ place: Destination, keep: Bool) {
        if let i = tabs.firstIndex(where: { $0.place.identity == place.identity }) {
            tabs[i].place = place
            if keep { tabs[i].isPreview = false }
            show(tabs[i].id)
        } else if !keep, let i = tabs.firstIndex(where: { $0.isPreview && !(split != nil && pane(of: $0.id) == focus.other) }) {
            tabs[i].place = place
            show(tabs[i].id)
        } else {
            let tab = PaneTab(place: place, isPreview: !keep)
            let after = selectedId.flatMap { id in tabs.firstIndex { $0.id == id } }
            tabs.insert(tab, at: after.map { $0 + 1 } ?? 0)
            show(tab.id)
        }
        panelShown = true
    }

    /// A tab (nil: the Overview) in the focused pane; one already on show has its pane focused instead.
    private func show(_ id: PaneTab.ID?) {
        if let pane = panes.first(where: { tabId(in: $0) == id }) {
            focus = pane
        } else {
            set(id, in: focus)
        }
    }

    private func set(_ id: PaneTab.ID?, in pane: StagePane) {
        switch pane {
        case .leading: leadingId = id
        case .trailing: split?.trailing = id
        }
        // Never the same thing twice side by side.
        if let s = split, s.trailing == leadingId {
            split = nil
            focus = .leading
        }
    }

    /// Back (or forward) to where the window was: its conversation in the centre, and its place in the side stage's
    /// focused pane (in its tab, or the preview tab again) or the Overview, and the side stage shown or hidden as it was.
    func go(to location: Location) {
        centre = location.centre
        if let place = location.stage {
            openTab(place, keep: false)
        } else {
            show(nil)
        }
        panelShown = location.panel
        touch(front)
        save()
    }

    /// The side stage on its Overview, the conversation's cards: its pane focused if one shows it, else in the focused
    /// pane.
    func showOverview() {
        show(nil)
        panelShown = true
        touch(centre)
        save()
    }

    /// The side stage hidden (its tabs kept), or shown again as it was.
    func hidePanel() {
        panelShown = false
        zoom = nil
        touch(centre)
        save()
    }

    func showPanel() {
        panelShown = true
        touch(front)
        save()
    }

    /// A pane dropped on the side stage's tabs, before the tab `before` (nil: after the last), kept and selected: a tab
    /// dragged from another main window moves there, and a window's pane docks there. A conversation goes in the centre.
    func drop(_ place: Destination, id: PaneTab.ID, before: PaneTab.ID?) {
        if place.inCentre {
            open(place)
            return
        }
        var tab = PaneTab(id: id, place: place)
        if let i = tabs.firstIndex(where: { $0.id == id || $0.place.identity == place.identity }) {
            tab.id = tabs[i].id
            tabs.remove(at: i)
        }
        let at = before.flatMap { b in tabs.firstIndex { $0.id == b } } ?? tabs.endIndex
        tabs.insert(tab, at: at)
        show(tab.id)
        panelShown = true
        touch(place)
        save()
    }

    /// A tab picked in the strip: its pane focused if it's on show, else in the focused pane.
    func select(_ id: PaneTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        show(id)
        panelShown = true
        touch(front)
        save()
    }

    /// The focused pane's next tab (+1) or previous one (-1), the Overview first, wrapping around, skipping what the
    /// other pane shows. A hidden side stage shows again on the tab it had.
    func step(_ delta: Int) {
        defer { save() }
        guard panelShown else { panelShown = true; return }
        var order: [PaneTab.ID?] = [nil] + tabs.map { Optional($0.id) }
        if split != nil {
            let other = tabId(in: focus.other)
            order.removeAll { $0 == other }
        }
        guard !order.isEmpty else { return }
        let i = order.firstIndex(of: selectedId) ?? 0
        set(order[((i + delta) % order.count + order.count) % order.count], in: focus)
        touch(front)
    }

    /// A preview kept: the next single click opens a tab of its own.
    func keep(_ id: PaneTab.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].isPreview else { return }
        tabs[i].isPreview = false
        save()
    }

    /// Close a tab. Split, a pane's tab closing closes the pane: the other one is the side stage's only pane. Otherwise
    /// closing the tab on show selects the one after it, else the one before, as Safari does; closing the last one goes
    /// back to the Overview.
    func close(_ id: PaneTab.ID) {
        remove(id)
        save()
    }

    private func remove(_ id: PaneTab.ID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let shownIn = pane(of: id)
        tabs.remove(at: i)
        guard let shownIn else { return }
        if split != nil {
            dropPane(shownIn)
        } else {
            leadingId = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id
        }
        touch(front)
    }

    /// Every tab but this one. Split, the side stage goes back to one pane: this tab if it was on show, else the
    /// Overview if that was, else this tab.
    func closeOthers(_ id: PaneTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let shown = panes.map { tabId(in: $0) }
        tabs.removeAll { $0.id != id }
        split = nil
        focus = .leading
        leadingId = shown.contains(id) || !shown.contains(nil) ? id : nil
        zoomStillFits()
        touch(front)
        save()
    }

    /// Close the tabs whose places are gone (a closed terminal); a side chat that's gone leaves the centre to the live
    /// conversation.
    func closeAll(where gone: (Destination) -> Bool) {
        for t in tabs where gone(t.place) { close(t.id) }
        if gone(centre) {
            centre = .lead
            save()
        }
    }

    /// Tabs dragged into a new order (the Mac's strip).
    func move(_ difference: ReorderDifference<PaneTab.ID, ReorderableSingleCollectionIdentifier>) {
        let before: PaneTab.ID? = switch difference.destination.position {
        case .before(let id): id
        case .end: nil
        }
        move(difference.sources, before: before)
    }

    /// Tabs moved in the strip, in their order, before the tab `before` (nil: to the end).
    func move(_ ids: [PaneTab.ID], before: PaneTab.ID?) {
        let moving = Set(ids)
        let moved = tabs.filter { moving.contains($0.id) }
        guard !moved.isEmpty, !(before.map(moving.contains) ?? false) else { return }
        tabs.removeAll { moving.contains($0.id) }
        tabs.insert(contentsOf: moved, at: before.flatMap { b in tabs.firstIndex { $0.id == b } } ?? tabs.endIndex)
        save()
    }

    /// The conversation `id` went live (a Resume landed): the centre shows it as the live conversation now.
    func wentLive(_ id: String) {
        guard centre == .conversation(id) else { return }
        centre = .lead
        save()
    }

    // MARK: split

    /// A tab (nil: the Overview) in the pane on `side`, beside what the side stage shows: dropped on that half of the
    /// side stage, or Open on the Right (Left). Split already, it takes that pane's place (what was there stays a tab),
    /// or the two panes swap if it's in the other one. Not split, what the side stage shows goes to the other side; if
    /// that's this tab, the other side gets the tab shown before it, else the Overview.
    func split(_ id: PaneTab.ID?, to side: StagePane) {
        guard id == nil || tabs.contains(where: { $0.id == id }) else { return }
        if split != nil {
            let here = tabId(in: side), there = tabId(in: side.other)
            if id == there {
                place(id, on: side, beside: here)
            } else if id != here {
                set(id, in: side)
            }
        } else {
            let shown = leadingId
            let beside = id == shown ? recentTab(besides: id) : shown
            guard beside != id else { return }
            split = StageSplit()
            place(id, on: side, beside: beside)
        }
        if split != nil { focus = side }
        panelShown = true
        zoomStillFits()
        touch(front)
        save()
    }

    /// A place in a pane beside the side stage's other one: any place, a conversation too (to read one beside the one in
    /// the centre), in a kept tab of its own. Not the conversation in the centre: that stays there.
    func open(_ place: Destination, beside side: StagePane) {
        guard place.identity != centre.identity else { return }
        let id: PaneTab.ID
        if let tab = tab(for: place) {
            id = tab.id
            if let i = tabs.firstIndex(where: { $0.id == id }) {
                tabs[i].place = place
                tabs[i].isPreview = false
            }
        } else {
            let tab = PaneTab(place: place)
            let after = selectedId.flatMap { id in tabs.firstIndex { $0.id == id } }
            tabs.insert(tab, at: after.map { $0 + 1 } ?? tabs.endIndex)
            id = tab.id
        }
        split(id, to: side)
        touch(place)
    }

    /// ⌘\: the side stage split, what it shows on the left and the tab shown before it on the right (else the
    /// Overview), focused.
    func splitBesideRecent() {
        guard split == nil else { return }
        let other = recentTab(besides: leadingId)
        guard other != leadingId else { return }
        split = StageSplit(trailing: other)
        focus = .trailing
        panelShown = true
        touch(front)
        save()
    }

    private func place(_ id: PaneTab.ID?, on side: StagePane, beside other: PaneTab.ID?) {
        if side == .leading {
            leadingId = id
            split?.trailing = other
        } else {
            leadingId = other
            split?.trailing = id
        }
    }

    /// The tab most recently shown, but not `id`: what goes beside a tab split off from the side stage's only pane.
    private func recentTab(besides id: PaneTab.ID?) -> PaneTab.ID? {
        for r in recent {
            if let t = tabs.first(where: { $0.place.identity == r && $0.id != id }) { return t.id }
        }
        return tabs.first { $0.id != id }?.id
    }

    /// One pane closes: the other one is the side stage's only pane.
    func closePane(_ pane: StagePane) {
        guard split != nil else { return }
        dropPane(pane)
        touch(front)
        save()
    }

    private func dropPane(_ pane: StagePane) {
        guard let s = split else { return }
        if pane == .leading { leadingId = s.trailing }
        split = nil
        focus = .leading
        zoomStillFits()
    }

    /// The pane you're working in: what ⌘W, the composer's chip and Handoff go by.
    func focus(_ pane: StagePane) {
        guard panes.contains(pane), pane != focus else { return }
        focus = pane
        touch(front)
        save()
    }

    /// How much of the side stage's width the leading pane takes, as the divider between them is dragged (saved when
    /// `save`).
    func setSplitShare(_ share: CGFloat, save: Bool = true) {
        guard split != nil else { return }
        split?.share = min(StageSplit.shares.upperBound, max(StageSplit.shares.lowerBound, share))
        if save { self.save() }
    }

    // MARK: zoom

    /// The side stage filling the window (nil: beside the conversation again). A pane only while it's split.
    func zoom(_ zoom: StageZoom?) {
        if case .pane(let p) = zoom, !panes.contains(p) || split == nil {
            self.zoom = .stage
        } else {
            self.zoom = zoom
        }
        if zoom != nil { panelShown = true }
        if case .pane(let p) = self.zoom { focus = p }
    }

    /// A zoomed pane that closed: the whole side stage stays zoomed.
    private func zoomStillFits() {
        if case .pane = zoom, split == nil { zoom = .stage }
    }

    #if DEBUG
    /// A fresh layout, for a test run that opens places of its own (DUET_DEST).
    func reset() {
        centre = .lead
        tabs = []
        leadingId = nil
        split = nil
        focus = .leading
        zoom = nil
        panelShown = true
    }
    #endif

    // MARK: floating

    func isFloating(_ place: Destination) -> Bool {
        let key = place.identity
        return floating.contains { $0.place.identity == key }
    }

    /// A window showing `place` opened (once, though its content can appear again).
    func floated(_ place: Destination, window: WindowRequest) {
        let key = place.identity
        floating.removeAll { $0.place.identity == key }
        floating.append(Floating(place: place, window: window))
        touch(place)
    }

    /// That window closed.
    func landed(_ place: Destination) {
        if let i = floating.firstIndex(where: { $0.place == place }) { floating.remove(at: i) }
    }

    func window(for place: Destination) -> WindowRequest? {
        let key = place.identity
        return floating.last { $0.place.identity == key }?.window
    }

    // MARK: recent

    /// A place was shown: its tab was picked, or its window came to the front.
    func touch(_ place: Destination) {
        let key = place.identity
        if recent.first == key { return }
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        if recent.count > 60 { recent.removeLast(recent.count - 60) }
    }

    /// Every open tab and window, most recently shown first (those never shown keep their order, after the rest).
    var recentItems: [SwitcherItem] {
        let items = tabs.map { SwitcherItem.tab($0) } + floating.map { SwitcherItem.window($0) }
        let rank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated()
            .sorted { a, b in (rank[a.element.place.identity] ?? Int.max, a.offset) < (rank[b.element.place.identity] ?? Int.max, b.offset) }
            .map(\.element)
    }

    // MARK: saving

    /// What's saved. `selected` is the leading pane's tab. Saved before the side stage had an Overview, `stageOpen`
    /// false meant the cards were showing; saved before the side stage at all, `centre` is nil and the conversation was
    /// a tab like the rest. `split` and `focus` are saved since the side stage could split.
    struct Saved: Codable {
        var tabs: [PaneTab]
        var selected: PaneTab.ID?
        var centre: Destination?
        var panel: Bool?
        var stageOpen: Bool?
        var split: StageSplit?
        var focus: StagePane?
    }

    private func save() {
        guard let key, let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: key)
    }

    var saved: Saved {
        Saved(tabs: tabs, selected: leadingId, centre: centre, panel: panelShown, split: split, focus: split == nil ? nil : focus)
    }

    /// The saved layout, less the terminals (their shells ended with the app), and the threads and sessions running
    /// elsewhere in tabs (they may be gone by the next launch). Conversations saved as tabs before the side stage are
    /// left out: the conversation is the centre now. Since then a conversation can be a tab, to read beside the centre.
    private func restore(_ saved: Saved) {
        let legacy = saved.centre == nil
        // A conversation comes back in the centre; a thread (a side chat, a note) may be gone by the next launch, so the
        // conversation it belonged to is the place to start.
        centre = switch saved.centre {
        case .conversation(let id)?: .conversation(id)
        default: .lead
        }
        var kept = saved.tabs.filter { t in
            switch t.place {
            case .terminal, .sideChat, .note, .outside: return false
            case .lead, .conversation: return !legacy && t.place != centre
            default: return true
            }
        }
        // One preview at most, as when they were saved; anything else is a kept tab.
        if let first = kept.firstIndex(where: \.isPreview) {
            for i in kept.indices where i != first { kept[i].isPreview = false }
        }
        tabs = kept
        func valid(_ id: PaneTab.ID?) -> PaneTab.ID? { id.flatMap { id in kept.contains { $0.id == id } ? id : nil } }
        leadingId = saved.stageOpen == false ? nil : valid(saved.selected)
        if let s = saved.split, valid(s.trailing) == s.trailing, s.trailing != leadingId {
            split = StageSplit(trailing: s.trailing, share: min(StageSplit.shares.upperBound, max(StageSplit.shares.lowerBound, s.share)))
            focus = saved.focus ?? .leading
        } else {
            split = nil
            focus = .leading
        }
        panelShown = saved.panel ?? true
    }
}

extension Destination {
    /// A conversation (the live one, an earlier one) or a thread (a side chat, a note): what the main window's centre
    /// shows, never a tab of the side stage.
    var inCentre: Bool {
        switch self {
        case .lead, .conversation, .sideChat, .note, .outside: true
        default: false
        }
    }

    /// What makes two places the same pane: a file at another line is that file, and the file viewer at another
    /// folder is the file viewer.
    var identity: Destination {
        switch self {
        case .file(let path, _): .file(path)
        case .files: .files(nil)
        default: self
        }
    }
}

#if DEBUG
extension Destination {
    /// A place named in a test run's launch environment: "inbox", "lead", "fleet", "notes", "conversation:<id>",
    /// "diagram:<id>", "plan:<id>", "worker:<id>", "sidechat:<id>", "note:<id>", "files:<folder>", "file:<path>[:<line>]",
    /// "diff:<task>@<worker>", "outside:<session>".
    init?(debug s: String) {
        let colon = s.firstIndex(of: ":")
        let kind = colon.map { String(s[..<$0]) } ?? s
        let arg = colon.map { String(s[s.index(after: $0)...]) } ?? ""
        switch kind {
        case "inbox": self = .inbox
        case "lead": self = .lead
        case "fleet": self = .fleet
        case "notes": self = .notes(.all)
        case "conversation": self = .conversation(arg)
        case "diagram": self = .diagram(arg)
        case "plan": self = .plan(arg)
        case "worker": self = .worker(arg)
        case "sidechat": self = .sideChat(arg)
        case "note": self = .note(arg)
        case "outside": self = .outside(arg)
        case "diff":
            let parts = arg.split(separator: "@", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            self = .diff(parts[0], worker: parts[1])
        case "files": self = .files(arg.isEmpty ? nil : arg)
        case "file":
            if let c = arg.lastIndex(of: ":"), let line = Int(arg[arg.index(after: c)...]) {
                self = .file(String(arg[..<c]), line: line)
            } else {
                self = .file(arg)
            }
        default: return nil
        }
    }
}
#endif

extension FilesRoute {
    /// The same step as a place of its own: in the main window, what used to be pushed inside a pane opens as a place.
    var place: Destination {
        switch self {
        case .folder(let p): .files(p)
        case .file(let p, let line): .file(p, line: line)
        case .note(let id): .note(id)
        case .notes(let filter): .notes(filter)
        }
    }
}
