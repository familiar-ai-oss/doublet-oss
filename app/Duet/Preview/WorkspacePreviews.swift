#if DEBUG
import DuetKit
import SwiftUI

extension PreviewData {
    /// The previews' moment fed into a running debug app (DUET_DEMO=1), so tabs and windows can be tried with no hub.
    static func feed(_ m: AppModel) {
        for line in lines {
            let json = line.replacingOccurrences(of: #""ts":T"#, with: #""ts":\#(Int(t0))"#)
            if case .event(let e) = try? JSONDecoder().decode(ServerFrame.self, from: Data(json.utf8)) { m.store.apply(e) }
        }
        // Answers being written (a side chat's, a note thread's) show at once.
        m.store.flushStreaming()
        m.refreshConversationList()
        let decoded = listings.compactMapValues { try? JSONDecoder().decode(FsListing.self, from: Data($0.utf8)) }
        m.explorer.preview(root: "/home/you/projects/parser", listings: decoded,
                           expanded: ["/home/you/projects/parser/Sources", "/home/you/projects/parser/Sources/Parser"])
    }

    /// A main window with the side stage's tabs open: a worker and a diagram kept, Fleet as the preview, and `selecting`
    /// on screen (a preview when it isn't one of those; a conversation in the centre).
    static func tabs(selecting: Destination) -> AppModel {
        let m = model()
        // Settings opens by itself on iPad until a token is saved.
        m.hasToken = true
        m.show(.worker("qwen-27b"), keep: true)
        m.show(.diagram("g1"), keep: true)
        m.show(.fleet)
        m.show(selecting)
        return m
    }

    /// A main window with the side stage on its Overview: the conversation and its cards.
    static func cards() -> AppModel {
        let m = tabs(selecting: .fleet)
        m.showOverview()
        return m
    }
}

#if os(macOS)
#Preview("Mac · tabs", traits: .fixedLayout(width: 1360, height: 820)) {
    RegularRoot().environment(PreviewData.tabs(selecting: .worker("qwen-27b"))).environment(\.density, .dense)
}

#Preview("Mac · the conversation and its cards", traits: .fixedLayout(width: 1360, height: 820)) {
    RegularRoot().environment(PreviewData.cards()).environment(\.density, .dense)
}

#Preview("Mac · a pane in a window", traits: .fixedLayout(width: 760, height: 620)) {
    PaneWindow(place: .worker("qwen-9b")).environment(PreviewData.model())
}

#Preview("Mac · the plan in a window", traits: .fixedLayout(width: 420, height: 640)) {
    PaneWindow(place: .plan("s2")).environment(PreviewData.model())
}
#endif

#if os(iOS)
#Preview("iPad · tabs", traits: .landscapeLeft) {
    RegularRoot().environment(PreviewData.tabs(selecting: .fleet)).environment(\.density, .regular)
}
#endif

#Preview("Side stage's bar", traits: .fixedLayout(width: 640, height: 120)) {
    VStack(spacing: 0) {
        StageBar()
        Spacer()
    }
    .environment(PreviewData.tabs(selecting: .worker("qwen-9b")))
    .environment(TabDrag())
}
#endif
