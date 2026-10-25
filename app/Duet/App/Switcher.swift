import SwiftUI

/// An open tab or window, as the ⌃Tab switcher lists it.
enum SwitcherItem: Identifiable {
    case tab(PaneTab), window(Floating)

    var place: Destination {
        switch self {
        case .tab(let t): t.place
        case .window(let f): f.place
        }
    }

    var id: String {
        switch self {
        case .tab(let t): "tab-\(t.id)"
        case .window(let f): "window-\(f.place.identity)"
        }
    }
}

/// The ⌃Tab switcher while it's up: every open tab and window, most recently shown first, and the one ⌃Tab has
/// reached. It shows in the window ⌃Tab was pressed in, after a moment, so a quick ⌃Tab goes straight back to the last
/// place without flashing the list.
struct Switcher {
    let host: UUID
    var items: [SwitcherItem]
    var index: Int
    var shown = false
    /// Started with ⌃ held (Mac): letting go of it goes there, as with ⌘Tab. Otherwise a click or Return does (Mac), or
    /// a pause after the last press (iPad).
    var holding: Bool
    /// Each press, so the iPad's pause after the last one can tell it's the last.
    var presses = 1
}

extension FocusedValues {
    /// The window that has the focus, for the ⌃Tab switcher to show in.
    @Entry var switcherHost: UUID?
}

extension AppModel {
    /// ⌃Tab (+1) and ⌃⇧Tab (-1): the switcher comes up on the place before this one (or the oldest), and each press
    /// moves on. `holding`: ⌃ is down, so letting go of it chooses (Mac).
    func stepSwitcher(_ delta: Int, in host: UUID, holding: Bool) {
        if switcher != nil {
            moveSwitcher(delta)
            switcher?.presses += 1
        } else {
            let items = workspace.recentItems
            guard items.count > 1 else { return }
            switcher = Switcher(host: host, items: items, index: delta > 0 ? 1 : items.count - 1, shown: !holding, holding: holding)
            if holding {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(180))
                    if self?.switcher?.host == host { self?.switcher?.shown = true }
                }
            }
        }
        #if os(iOS)
        // iPadOS can't tell when ⌥ is let go, and the list can't take the keyboard there: a pause after the last ⌥Tab
        // goes to the place it reached (⌥⇧Tab back to the first is staying put).
        let presses = switcher?.presses
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if let self, self.switcher?.presses == presses { self.endSwitching(go: true) }
        }
        #endif
    }

    /// The switcher's highlight, down (+1) or up (-1) the list.
    func moveSwitcher(_ delta: Int) {
        guard var s = switcher else { return }
        s.index = (s.index + delta + s.items.count) % s.items.count
        switcher = s
    }

    /// The switcher goes away: to the place it reached (`go`), or back where you were.
    func endSwitching(go: Bool) {
        guard let s = switcher else { return }
        switcher = nil
        if go { self.go(to: s.items[s.index]) }
    }

    /// An open tab or window, picked from the switcher: the tab selected (its window forward), or the window forward.
    func go(to item: SwitcherItem) {
        switch item {
        case .tab(let t):
            select(t)
            showMainWindow()
        case .window(let f):
            windowRequest = f.window
        }
    }
}

extension View {
    /// A window the ⌃Tab switcher can show in: it says when it has the focus, shows the switcher when it's the one,
    /// and (Mac) chooses when ⌃ is let go.
    func switcherHost() -> some View {
        modifier(SwitcherHost())
    }
}

private struct SwitcherHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive
    @State private var id = UUID()

    func body(content: Content) -> some View {
        let here = model.switcher?.host == id ? model.switcher : nil
        content
            .focusedSceneValue(\.switcherHost, id)
            // Another window or app came to the front: the switcher goes, going nowhere.
            .onChange(of: appearsActive) { _, active in
                if !active, model.switcher?.host == id { model.endSwitching(go: false) }
            }
            .overlay {
                if let here, here.shown {
                    ZStack {
                        // A click outside the list puts it away.
                        Color.black.opacity(0.08)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { model.endSwitching(go: false) }
                        SwitcherPanel(switcher: here)
                    }
                    .transition(.opacity)
                }
            }
            #if os(macOS)
            .onModifierKeysChanged(mask: .control, initial: false) { old, new in
                // The switcher as it is now (this action can outlive the body it came from).
                guard old.contains(.control), !new.contains(.control), let s = model.switcher, s.host == id, s.holding else { return }
                model.endSwitching(go: true)
            }
            #endif
    }
}

/// The switcher's list: each open tab and window, the one ⌃Tab has reached highlighted. Click one to go there, or
/// (Mac) use the arrow keys and Return; Escape puts it away. It takes the keyboard while it's up, so those keys reach it.
private struct SwitcherPanel: View {
    @Environment(AppModel.self) private var model
    let switcher: Switcher
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Tabs and Windows").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            ForEach(Array(switcher.items.enumerated()), id: \.element.id) { i, item in
                row(item, highlighted: i == switcher.index)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.switcher?.index = i
                        model.endSwitching(go: true)
                    }
            }
        }
        .padding(8)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .return, .space: model.endSwitching(go: true)
            case .escape: model.endSwitching(go: false)
            case .downArrow: model.moveSwitcher(1)
            case .upArrow: model.moveSwitcher(-1)
            default: return .ignored
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs and windows")
        .accessibilityIdentifier("switcher")
    }

    private func row(_ item: SwitcherItem, highlighted: Bool) -> some View {
        let window = if case .window = item { true } else { false }
        return HStack(spacing: 10) {
            Image(systemName: model.symbol(of: item.place)).frame(width: 18)
            Text(model.title(of: item.place)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text(window ? "Window" : "Tab").font(.caption)
                .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
        }
        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(highlighted ? Color.stateNeedsYou : .clear)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : [.isButton])
    }
}
