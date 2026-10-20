import Foundation
import Testing
@testable import Duet

/// The side stage's tabs and panes: splitting, swapping, closing and moving, what's saved, and saves from before.
@MainActor
struct WorkspaceTests {
    let lexer = Destination.file("/p/Lexer.swift", line: 27)
    let token = Destination.file("/p/Token.swift")
    let fleet = Destination.fleet
    let plan = Destination.plan("c1")

    /// A workspace saved nowhere, with kept tabs for these places (the last one on show).
    private func workspace(_ places: Destination...) -> Workspace {
        let w = Workspace(savingAs: nil)
        for p in places { w.open(p, keep: true) }
        return w
    }

    private func id(_ w: Workspace, _ place: Destination) -> PaneTab.ID { w.tab(for: place)!.id }

    // MARK: split

    @Test func splitPutsATabBesideTheOneOnShow() {
        let w = workspace(lexer, token)
        w.split(id(w, lexer), to: .trailing)
        #expect(w.tab(in: .leading)?.place == token)
        #expect(w.tab(in: .trailing)?.place.identity == lexer.identity)
        #expect(w.focus == .trailing)
        #expect(w.staged?.identity == lexer.identity)
        #expect(!w.overviewOnly)
    }

    @Test func splittingTheTabOnShowPutsTheOneBeforeItBeside() {
        let w = workspace(lexer, token)
        w.select(id(w, lexer))
        w.split(id(w, lexer), to: .leading)
        #expect(w.tab(in: .leading)?.place.identity == lexer.identity)
        #expect(w.tab(in: .trailing)?.place == token)
        #expect(w.focus == .leading)
    }

    @Test func aLoneTabSplitsBesideTheOverview() {
        let w = workspace(lexer)
        w.split(id(w, lexer), to: .trailing)
        #expect(w.split != nil)
        #expect(w.tabId(in: .leading) == nil)
        #expect(w.overviewPane == .leading)
        #expect(w.tab(in: .trailing)?.place.identity == lexer.identity)
    }

    @Test func theOverviewAloneDoesntSplitWithItself() {
        let w = Workspace(savingAs: nil)
        w.split(nil, to: .trailing)
        #expect(w.split == nil)
        #expect(w.overviewOnly)
    }

    @Test func droppingThePaneOnTheOtherSideSwaps() {
        let w = workspace(lexer, token)
        w.split(id(w, lexer), to: .trailing)
        w.split(id(w, lexer), to: .leading)
        #expect(w.tab(in: .leading)?.place.identity == lexer.identity)
        #expect(w.tab(in: .trailing)?.place == token)
        #expect(w.focus == .leading)
    }

    @Test func aThirdTabTakesThePanesPlaceAndTheOtherStaysATab() {
        let w = workspace(lexer, token, fleet)
        w.select(id(w, lexer))
        w.split(id(w, token), to: .trailing)
        w.split(id(w, fleet), to: .trailing)
        #expect(w.tab(in: .leading)?.place.identity == lexer.identity)
        #expect(w.tab(in: .trailing)?.place == fleet)
        #expect(w.tabs.count == 3)
    }

    @Test func theSamePlaceNeverShowsTwice() {
        let w = workspace(lexer, token)
        w.split(id(w, lexer), to: .trailing)
        w.focus(.leading)
        w.select(id(w, lexer))
        // Picking the tab the other pane shows focuses that pane.
        #expect(w.focus == .trailing)
        #expect(w.tab(in: .leading)?.place == token)
    }

    // MARK: closing

    @Test func closingAPanesTabClosesThePane() {
        let w = workspace(lexer, token)
        w.split(id(w, lexer), to: .trailing)
        w.close(id(w, lexer))
        #expect(w.split == nil)
        #expect(w.focus == .leading)
        #expect(w.selected?.place == token)
    }

    @Test func closingTheLeadingTabLeavesTheTrailingOne() {
        let w = workspace(lexer, token)
        w.split(id(w, lexer), to: .trailing)
        w.close(id(w, token))
        #expect(w.split == nil)
        #expect(w.selected?.place.identity == lexer.identity)
    }

    @Test func closingTheTabOnShowSelectsTheNext() {
        let w = workspace(lexer, token, fleet)
        w.select(id(w, token))
        w.close(id(w, token))
        #expect(w.selected?.place == fleet)
    }

    @Test func closingAPaneKeepsTheOther() {
        let w = workspace(lexer, token)
        w.split(id(w, lexer), to: .trailing)
        w.closePane(.leading)
        #expect(w.split == nil)
        #expect(w.selected?.place.identity == lexer.identity)
        #expect(w.tabs.count == 2)
    }

    @Test func closeOthersGoesBackToOnePane() {
        let w = workspace(lexer, token, fleet)
        w.split(id(w, lexer), to: .trailing)
        w.closeOthers(id(w, lexer))
        #expect(w.tabs.map(\.place.identity) == [lexer.identity])
        #expect(w.split == nil)
        #expect(w.selected?.place.identity == lexer.identity)
    }

    // MARK: opening and stepping

    @Test func openingWhatAPaneShowsFocusesIt() {
        let w = workspace(lexer, token)
        w.split(id(w, lexer), to: .trailing)
        w.focus(.leading)
        w.open(.file("/p/Lexer.swift", line: 90))
        #expect(w.focus == .trailing)
        #expect(w.tab(in: .trailing)?.place == .file("/p/Lexer.swift", line: 90))
    }

    @Test func somethingNewOpensInTheFocusedPane() {
        let w = workspace(lexer, token)
        w.split(id(w, lexer), to: .trailing)
        w.open(fleet)
        #expect(w.tab(in: .trailing)?.place == fleet)
        #expect(w.tab(in: .leading)?.place == token)
    }

    @Test func aPreviewTheOtherPaneShowsIsntReused() {
        let w = Workspace(savingAs: nil)
        w.open(token, keep: true)
        w.open(lexer)
        #expect(w.tab(for: lexer)?.isPreview == true)
        w.split(id(w, lexer), to: .trailing)
        w.focus(.leading)
        w.open(fleet)
        // The preview stays where it is, beside: the fleet gets a tab of its own.
        #expect(w.tab(in: .trailing)?.place.identity == lexer.identity)
        #expect(w.tab(in: .leading)?.place == fleet)
        #expect(w.tabs.count == 3)
    }

    @Test func steppingSkipsWhatTheOtherPaneShows() {
        let w = workspace(lexer, token, fleet)
        w.select(id(w, lexer))
        w.split(id(w, token), to: .trailing)
        w.focus(.leading)
        // Overview, lexer, (token beside), fleet.
        w.step(1)
        #expect(w.tab(in: .leading)?.place == fleet)
        w.step(1)
        #expect(w.tabId(in: .leading) == nil)
    }

    @Test func aConversationCanSitBesideTheCentre() {
        let w = workspace(lexer)
        w.open(.conversation("c2"), beside: .trailing)
        #expect(w.tab(in: .trailing)?.place == .conversation("c2"))
        #expect(w.centre == .lead)
        // Opened in the centre, it's open once: its tab closes.
        w.open(.conversation("c2"))
        #expect(w.centre == .conversation("c2"))
        #expect(w.tab(for: .conversation("c2")) == nil)
        #expect(w.split == nil)
    }

    @Test func theCentresConversationDoesntGoBesideItself() {
        let w = workspace(lexer)
        w.open(.lead, beside: .trailing)
        #expect(w.split == nil)
        #expect(w.tab(for: .lead) == nil)
    }

    // MARK: moving

    @Test func movingTabsBeforeAnother() {
        let w = workspace(lexer, token, fleet)
        w.move([id(w, fleet)], before: id(w, lexer))
        #expect(w.tabs.map(\.place.identity) == [fleet, lexer.identity, token].map(\.identity))
        w.move([id(w, fleet)], before: nil)
        #expect(w.tabs.last?.place == fleet)
        // Onto itself: nothing moves.
        w.move([id(w, token)], before: id(w, token))
        #expect(w.tabs.map(\.place.identity) == [lexer.identity, token, fleet].map(\.identity))
    }

    @Test func movingKeepsWhatThePanesShow() {
        let w = workspace(lexer, token)
        w.split(id(w, lexer), to: .trailing)
        w.move([id(w, lexer)], before: id(w, token))
        #expect(w.tab(in: .trailing)?.place.identity == lexer.identity)
        #expect(w.tab(in: .leading)?.place == token)
    }

    // MARK: share and zoom

    @Test func theDividerStaysWithinItsShares() {
        let w = workspace(lexer, token)
        w.split(id(w, lexer), to: .trailing)
        w.setSplitShare(0.1)
        #expect(w.split?.share == StageSplit.shares.lowerBound)
        w.setSplitShare(0.9)
        #expect(w.split?.share == StageSplit.shares.upperBound)
    }

    @Test func aZoomedPaneThatClosesLeavesTheStageZoomed() {
        let w = workspace(lexer, token)
        w.split(id(w, lexer), to: .trailing)
        w.zoom(.pane(.trailing))
        #expect(w.zoom == .pane(.trailing))
        w.closePane(.trailing)
        #expect(w.zoom == .stage)
        w.zoom(.pane(.trailing))
        #expect(w.zoom == .stage)
        w.hidePanel()
        #expect(w.zoom == nil)
    }

    // MARK: saving

    private func defaults() -> UserDefaults {
        let name = "duet.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func aSplitComesBackAtLaunch() {
        let d = defaults()
        let w = Workspace(savingAs: "layout", in: d)
        w.open(lexer, keep: true)
        w.open(token, keep: true)
        w.split(id(w, lexer), to: .trailing)
        w.setSplitShare(0.6)
        w.focus(.leading)
        w.zoom(.stage)

        let back = Workspace(savingAs: "layout", in: d)
        #expect(back.tabs.map(\.place.identity) == w.tabs.map(\.place.identity))
        #expect(back.tab(in: .leading)?.place == token)
        #expect(back.tab(in: .trailing)?.place.identity == lexer.identity)
        #expect(back.split?.share == 0.6)
        #expect(back.focus == .leading)
        // Filling the window isn't kept.
        #expect(back.zoom == nil)
    }

    @Test func aSaveFromBeforeSplitsStillReads() throws {
        let d = defaults()
        let tab = PaneTab(place: lexer)
        // As saved before the side stage could split: no `split`, no `focus`.
        struct Old: Codable { var tabs: [PaneTab]; var selected: PaneTab.ID?; var centre: Destination?; var panel: Bool? }
        d.set(try JSONEncoder().encode(Old(tabs: [tab], selected: tab.id, centre: .lead, panel: true)), forKey: "layout")
        let w = Workspace(savingAs: "layout", in: d)
        #expect(w.selected?.id == tab.id)
        #expect(w.split == nil)
        #expect(w.focus == .leading)
    }

    @Test func aSaveFromBeforeTheCentreDropsItsConversationTabs() throws {
        let d = defaults()
        let file = PaneTab(place: lexer), conversation = PaneTab(place: .conversation("c1"))
        let saved = Workspace.Saved(tabs: [conversation, file], selected: conversation.id, centre: nil, panel: true)
        d.set(try JSONEncoder().encode(saved), forKey: "layout")
        let w = Workspace(savingAs: "layout", in: d)
        #expect(w.tabs.map(\.id) == [file.id])
        #expect(w.centre == .lead)
        #expect(w.selected == nil)
    }

    @Test func threadsAndTerminalsInTabsArentRestored() throws {
        let d = defaults()
        let tabs = [PaneTab(place: .terminal("t1")), PaneTab(place: .sideChat("s1")), PaneTab(place: .conversation("c2")), PaneTab(place: lexer)]
        let saved = Workspace.Saved(tabs: tabs, selected: tabs[3].id, centre: .lead, panel: true,
                                    split: StageSplit(trailing: tabs[1].id, share: 0.5), focus: .trailing)
        d.set(try JSONEncoder().encode(saved), forKey: "layout")
        let w = Workspace(savingAs: "layout", in: d)
        #expect(w.tabs.map(\.id) == [tabs[2].id, tabs[3].id])
        // The side chat beside is gone, so the side stage is one pane again.
        #expect(w.split == nil)
        #expect(w.selected?.id == tabs[3].id)
    }
}
