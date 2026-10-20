import DuetKit
import SwiftUI

// Mac and iPad together, through the hub (docs/navigation.md, "Mac and iPad together"):
// - Open on iPad: what's here opens on another of the user's devices, at once if Duet is open there, else when it next is.
// - Write on iPad: a file or a diagram opens on the iPad with the Pencil tools out.
// - On iPad: each device tells the others what it has open, and their switchers list it.
// Handoff moves where you are too, but only between apps signed by one team on one iCloud account; the hub works from
// anywhere.

extension AppModel {
    /// Open here a place another device sent or has open: in the main window as a kept tab, selected (a conversation in
    /// the centre), or in the narrow layout's tab that owns it. `write`: it was sent to write on, so the Pencil tools
    /// come out once it shows.
    func openHere(_ place: Destination, write: Bool = false) {
        continueHandoff(Handoff.Offer(place: place))
        if write { writeRequest = place.identity }
    }

    /// The user's iPads, for Write on iPad.
    var pencilTargets: [DeviceInfo] { sendTargets.filter { ($0.kind ?? $0.device) == "ipad" } }

    /// A place's name as it's sent: a file's with the line it's at ("Lexer.swift:27").
    func sendTitle(of place: Destination) -> String {
        if case .file(let path, let line?) = place { return "\(Paths.name(path)):\(line)" }
        return title(of: place)
    }

    /// What this device has open, for the other devices' switchers. The main window: an earlier conversation or a thread
    /// in the centre, the side stage's tabs, and the panes in windows of their own. The narrow layout (iPhone): what it
    /// shows. `current` is the one in front. The live conversation is left out, being the same everywhere, and so are
    /// terminals, whose shells belong to this device.
    var openHereNow: (places: [Destination], current: Int?) {
        var places: [Destination]
        let front: Destination?
        if compactLayout {
            places = compactPlace.map { [$0] } ?? []
            front = compactPlace
        } else {
            places = [workspace.centre] + workspace.tabs.map(\.place) + workspace.floating.map(\.place)
            front = workspace.recent.first
        }
        var seen = Set<Destination>()
        places = Array(places.filter { $0 != .lead && Self.sendable($0) && seen.insert($0.identity).inserted }.prefix(40))
        return (places, front.flatMap { f in places.firstIndex { $0.identity == f.identity } })
    }

    /// What the user's other devices have open, as each last told the hub, those with Duet open first. A device away
    /// for more than three days is left out: what it had open then is old news.
    var openElsewhere: [OpenElsewhere] {
        sendTargets.compactMap { d in
            guard let open = d.open ?? demoOpen(on: d) else { return nil }
            if !d.online, Date().timeIntervalSince(d.lastSeenDate ?? .distantPast) > 3 * 24 * 3600 { return nil }
            let items = open.places.enumerated().compactMap { i, p -> OpenElsewhere.Item? in
                // A place from a newer version of Duet may not read here.
                guard let place = try? p.place.decoded(as: Destination.self) else { return nil }
                return OpenElsewhere.Item(id: i, place: place, title: p.title.isEmpty ? title(of: place) : p.title, current: i == open.current)
            }
            return items.isEmpty ? nil : OpenElsewhere(device: d, items: items)
        }
    }

    /// A demo run's other Mac or iPad has a few things open, so the switcher's section can be tried without a hub.
    private func demoOpen(on d: DeviceInfo) -> OpenPlaces? {
        #if DEBUG
        guard isDemo, d.kind == "ipad" || d.kind == "mac" else { return nil }
        let places: [Destination] = [.file("/home/you/projects/parser/Sources/Parser/Lexer.swift", line: 27), .diagram("g1"), .plan("s1")]
        return OpenPlaces(places: places.map { OpenPlace(place: JSONValue(encoding: $0), title: title(of: $0)) }, current: 0,
                          ts: Date().timeIntervalSince1970 * 1000)
        #else
        return nil
        #endif
    }
}

/// What another device has open, for the switcher: the places this version can read, the one in front there marked.
struct OpenElsewhere: Identifiable {
    struct Item: Identifiable {
        let id: Int
        let place: Destination
        let title: String
        let current: Bool
    }

    let device: DeviceInfo
    let items: [Item]
    var id: String { device.device }

    /// "On iPad", and when Duet isn't open there, how long ago it was.
    @MainActor var heading: String {
        let name = AppModel.deviceName(device.device, kind: device.kind)
        guard !device.online, let seen = device.lastSeenDate else { return "On \(name)" }
        return "On \(name) (\(seen.formatted(.relative(presentation: .named))))"
    }
}

/// Open on iPad (or Mac, or iPhone): one item for each of the user's other devices, for a menu (a tab's, or a toolbar's
/// menu of devices). Nothing for a terminal, whose shell belongs to this device.
struct OpenOnDevices: View {
    @Environment(AppModel.self) private var model
    let place: Destination

    var body: some View {
        if AppModel.sendable(place) {
            ForEach(model.sendTargets) { target in
                let name = AppModel.deviceName(target.device, kind: target.kind)
                Button("Open on \(name)", systemImage: AppModel.deviceSymbol(target)) { model.send(place, to: target) }
                    .help(target.online ? "Open \(model.title(of: place)) on your \(name)" : "Open \(model.title(of: place)) on your \(name) when Doublet is next open there")
                    .accessibilityIdentifier("open-on-\(target.device)")
            }
        }
    }
}

/// Write on iPad: a file (at its picked line) or a diagram opens on the iPad, ready for Apple Pencil, its tools out.
/// One item for each of the user's iPads; nothing when there's none.
struct WriteOnIPad: View {
    @Environment(AppModel.self) private var model
    let place: Destination

    var body: some View {
        let iPads = model.pencilTargets
        ForEach(iPads) { target in
            Button(iPads.count == 1 ? "Write on iPad" : "Write on \(target.device)", systemImage: "applepencil.and.scribble") {
                model.send(place, to: target, write: true)
            }
            .help(target.online ? "Open \(model.title(of: place)) on your iPad to write on with Apple Pencil"
                                : "Open \(model.title(of: place)) on your iPad to write on, when Doublet is next open there")
            .accessibilityIdentifier("write-on-\(target.device)")
        }
    }
}

/// The switcher's sections for the user's other devices ("On iPad"): what each has open, the one in front there
/// checked. Picking one opens it here.
struct OnOtherDevices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(model.openElsewhere) { other in
            Section(other.heading) {
                ForEach(other.items) { item in
                    Toggle(isOn: Binding(get: { item.current }, set: { _ in model.openHere(item.place) })) {
                        Label(item.title, systemImage: model.symbol(of: item.place))
                    }
                    .accessibilityIdentifier("on-\(other.device.device)-\(item.id)")
                }
            }
        }
    }
}

extension View {
    /// Tells the hub what this device has open, for the other devices' switchers (the main window carries it).
    func reportsOpenPlaces() -> some View {
        background { OpenPlacesReporter() }
    }

    /// A file or a diagram sent here to write on (Write on iPad): `showTools` brings out the Pencil tools, once.
    func writesWhenSent(_ place: Destination, showTools: @escaping () -> Void) -> some View {
        modifier(WritesWhenSent(place: place.identity, showTools: showTools))
    }
}

/// Reports what this device has open (`AppModel.openHereNow`) a moment after it changes, and again on each connection.
private struct OpenPlacesReporter: View {
    @Environment(AppModel.self) private var model

    private struct Report: Equatable {
        var places: [OpenPlace]
        var current: Int?
        var connected: Bool
    }

    var body: some View {
        let open = model.openHereNow
        let report = Report(places: open.places.map { OpenPlace(place: JSONValue(encoding: $0), title: model.title(of: $0)) },
                            current: open.current, connected: model.store.isConnected)
        Color.clear
            .task(id: report) {
                guard report.connected, !model.isDemo else { return }
                // A burst of changes (closing tabs, a drag, going back and forth) makes one report.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                try? await model.store.reportOpenPlaces(report.places, current: report.current)
            }
    }
}

private struct WritesWhenSent: ViewModifier {
    @Environment(AppModel.self) private var model
    let place: Destination
    let showTools: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: model.writeRequest, initial: true) { _, request in
            guard request == place else { return }
            model.writeRequest = nil
            showTools()
        }
    }
}
