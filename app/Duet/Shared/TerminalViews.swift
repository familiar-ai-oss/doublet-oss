import DuetKit
import SwiftTerm
import SwiftUI

/// A terminal on the hub machine with a switcher and an "open" menu. Used as the iPhone tab, an iPad/Mac sidebar
/// destination, the Mac's bottom panel and its own window.
struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    var fixedId: String? = nil
    var showsTabs = true

    var body: some View {
        let store = model.store
        let current = fixedId ?? model.selectedTerminal
        VStack(spacing: 0) {
            if showsTabs {
                HStack(spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(store.terminals) { t in
                                Button { model.selectedTerminal = t.id } label: {
                                    Label(t.title, systemImage: TerminalKinds.symbol(t.kind)).font(.caption)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background { Capsule().fill(current == t.id ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1)) }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    NewTerminalMenu()
                    if let id = current {
                        #if os(macOS)
                        OpenTerminalWindowButton(id: id)
                        #endif
                        Button("Close", systemImage: "xmark") { model.send(.ptyClose(id: id)) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.bar)
            }
            if let id = current, store.terminals.contains(where: { $0.id == id }) {
                TerminalHost(id: id).id(id)
                    .padding(.leading, 6).padding(.top, 4)
                    // Black under the top and bottom bars, but not under an iPad's floating sidebar.
                    .background(Color.black, ignoresSafeAreaEdges: [.top, .bottom])
            } else {
                ContentUnavailableView {
                    Label("No terminal open", systemImage: "terminal")
                } description: {
                    Text("A shell in the project, the hub's logs, or llmd's live status, running on the hub.")
                } actions: {
                    HStack {
                        Button("Shell") { model.openTerminal(.shell) }.buttonStyle(.borderedProminent)
                        Button("Hub logs") { model.openTerminal(.hub_logs) }.buttonStyle(.bordered)
                        Button("llmd") { model.openTerminal(.llmd) }.buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

extension View {
    /// For a terminal that fills the screen: light bar titles, readable over the black terminal.
    func terminalChrome() -> some View {
        #if os(iOS)
        toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }
}

enum TerminalKinds {
    static func symbol(_ k: PtyKind) -> String {
        switch k {
        case .shell: "terminal"
        case .hub_logs: "doc.text.magnifyingglass"
        case .llmd: "cpu"
        }
    }
}

struct NewTerminalMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Project Shell", systemImage: "terminal") { model.openTerminal(.shell) }
            Button("Hub Logs", systemImage: "doc.text.magnifyingglass") { model.openTerminal(.hub_logs) }
            Button("llmd Status", systemImage: "cpu") { model.openTerminal(.llmd) }
        } label: { Image(systemName: "plus") }
        .menuIndicator(.hidden).fixedSize()
        .accessibilityIdentifier("terminal-new")
    }
}

#if os(macOS)
struct OpenTerminalWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    let id: String

    var body: some View {
        Button("Open in Window", systemImage: "macwindow.on.rectangle") { openWindow(id: "terminal", value: id) }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
    }
}
#endif

/// Bridges one hub terminal to SwiftTerm: output in, keystrokes and size changes out.
final class TerminalBridge: NSObject, TerminalViewDelegate {
    let id: String
    let send: (ClientMessage) -> Void
    private var lastSize = (0, 0)

    init(id: String, send: @escaping (ClientMessage) -> Void) {
        self.id = id
        self.send = send
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0, (newCols, newRows) != lastSize else { return }
        lastSize = (newCols, newRows)
        send(.ptyResize(id: id, cols: newCols, rows: newRows))
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        send(.ptyInput(id: id, data: String(decoding: data, as: UTF8.self)))
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        let s = String(decoding: content, as: UTF8.self)
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

#if os(macOS)
struct TerminalHost: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let id: String

    func makeCoordinator() -> TerminalBridge { TerminalBridge(id: id) { [model] m in model.send(m, quiet: true) } }

    func makeNSView(context: Context) -> TerminalView {
        let v = TerminalView(frame: .init(x: 0, y: 0, width: 640, height: 260))
        v.terminalDelegate = context.coordinator
        v.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        model.store.attachTerminal(id) { [weak v] text in v?.feed(text: text) }
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ v: TerminalView, context: Context) {}

    static func dismantleNSView(_ v: TerminalView, coordinator: TerminalBridge) {}
}
#else
struct TerminalHost: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let id: String

    func makeCoordinator() -> TerminalBridge { TerminalBridge(id: id) { [model] m in model.send(m, quiet: true) } }

    func makeUIView(context: Context) -> TerminalView {
        let v = TerminalView(frame: .init(x: 0, y: 0, width: 390, height: 300))
        v.terminalDelegate = context.coordinator
        v.font = .monospacedSystemFont(ofSize: density == .compact ? 11 : 13, weight: .regular)
        model.store.attachTerminal(id) { [weak v] text in v?.feed(text: text) }
        return v
    }

    func updateUIView(_ v: TerminalView, context: Context) {}
}
#endif
