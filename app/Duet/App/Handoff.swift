import OSLog
import DuetKit
import SwiftUI

/// Handoff between Duet on the Mac, the iPad and the iPhone: every window advertises what it shows, and on the other
/// device Duet's icon (at the end of the Mac's Dock, in the iPad's Dock and app switcher) carries on there. The main
/// window hands over its conversation and what's beside it, and what you're typing; a pane's window, its pane. It
/// needs both apps signed by the same team (project.yml), and both devices on the same iCloud account with Handoff
/// turned on.
enum Handoff {
    /// The activity type. Both apps list it under NSUserActivityTypes in their Info.plist.
    static let placeType = AppIdentity.bundleID + ".place"

    static let log = Logger(subsystem: AppIdentity.bundleID, category: "handoff")

    /// What a window hands over: the place it shows (the side stage's tab, else its conversation), and from the main
    /// window the conversation in its centre and the composer's text.
    struct Offer: Hashable {
        var place: Destination
        var centre: Destination? = nil
        var draft: String = ""
    }

    /// What an activity carries, if it carries a place this version can read. Activities from before the centre and
    /// the draft were added carry only the place.
    static func offer(in activity: NSUserActivity) -> Offer? {
        let info = activity.userInfo ?? [:]
        guard let place = decode(info["place"]) else { return nil }
        return Offer(place: place, centre: decode(info["centre"]), draft: info["draft"] as? String ?? "")
    }

    private static func decode(_ value: Any?) -> Destination? {
        (value as? Data).flatMap { try? JSONDecoder().decode(Destination.self, from: $0) }
    }

    /// What's worth handing over. A terminal isn't: its shell belongs to the device that opened it.
    static func offers(_ place: Destination) -> Bool {
        if case .terminal = place { return false }
        return true
    }
}

extension View {
    /// This window's side of Handoff: it offers `offer` while it's the window in front (nil: nothing to hand over).
    /// The main window (`main`) also opens what the other device hands over; with none open, SwiftUI opens one for it.
    func handoff(_ offer: Handoff.Offer?, main: Bool = false) -> some View {
        modifier(HandoffSupport(offer: offer, main: main))
    }
}

struct HandoffSupport: ViewModifier {
    @Environment(AppModel.self) private var model
    let offer: Handoff.Offer?
    let main: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if main {
            offering(content)
                .onContinueUserActivity(Handoff.placeType) { activity in
                    guard let offer = Handoff.offer(in: activity) else { return }
                    Handoff.log.debug("continues \(model.title(of: offer.place), privacy: .public)")
                    model.continueHandoff(offer)
                }
                // The main window takes what's handed over; without this SwiftUI opens a new main window for every place
                // handed over (and every duet:// link). A pane's window states nothing, so iPadOS keeps a tab dropped at
                // the screen's edge for a new window of its own.
                .handlesExternalEvents(preferring: [Handoff.placeType], allowing: ["*"])
        } else {
            offering(content)
        }
    }

    private func offering(_ content: Content) -> some View {
        let offered = offer.flatMap { Handoff.offers($0.place) ? $0 : nil }
        return content
            .userActivity(Handoff.placeType, element: offered) { offer, activity in
                activity.title = model.title(of: offer.place)
                activity.isEligibleForHandoff = true
                activity.targetContentIdentifier = Handoff.placeType
                var info: [String: Any] = [:]
                if let data = try? JSONEncoder().encode(offer.place) { info["place"] = data }
                if let centre = offer.centre, centre != offer.place, let data = try? JSONEncoder().encode(centre) { info["centre"] = data }
                if !offer.draft.isEmpty { info["draft"] = offer.draft }
                // Replaced whole, so a draft sent and cleared isn't handed over later.
                activity.userInfo = info
                Handoff.log.debug("offers \(activity.title ?? "", privacy: .public)\(offer.centre == nil ? "" : " beside its conversation")\(offer.draft.isEmpty ? "" : " with a draft")")
            }
    }
}
