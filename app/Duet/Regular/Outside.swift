import DuetKit
import MarkdownUI
import SwiftUI

/// A Claude Code session running outside Duet on the hub machine (in Claude Desktop, a terminal or the background), in the
/// centre: followed live and read-only, what's said there showing here about 2 s later. Duet can't type into it (Claude
/// Code has no way to), so Continue in Duet takes it over: a fork while it still runs there, which keeps running
/// untouched; the session itself once it has ended. Its conversation then becomes the live one.
struct OutsideSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    let id: String
    @State private var problem: String?
    @State private var continuing = false
    /// Asked while Claude was mid-turn here: the hub continues it when the turn ends.
    @State private var queued = false

    var body: some View {
        let session = model.outsideSession(id)
        let messages = model.outsideMessages(id)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let messages {
                        if messages.isEmpty {
                            Text("Nothing said there yet.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(messages) { OutsideMessageRow(message: $0) }
                    } else if problem == nil {
                        ProgressView("Following it…").frame(maxWidth: .infinity)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(density == .compact ? 14 : 18)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages?.count) { withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { continueBar(session) }
        .navigationTitle(session?.name ?? "Running elsewhere")
        .navigationSubtitle(session.map(model.whereLine) ?? "")
        // Followed while it's on screen; the hub stops sending once it's gone.
        .task(id: id) {
            do { try await model.followOutside(id) } catch { problem = error.localizedDescription }
        }
        .onDisappear { Task { await model.unfollowOutside(id) } }
        .accessibilityIdentifier("outside-session")
    }

    private func continueBar(_ session: OutsideSession?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session {
                Label(model.whereLine(session), systemImage: AppModel.symbol(of: session))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(session.status == "busy" ? Color.stateWorking : .primary)
                Text(session.live
                     ? "Doublet follows it as it runs, and can't type into it. Continue in Doublet to talk to it here: you get a copy with everything said, and it keeps running there."
                     : "It has ended there. Continue in Doublet to pick it up here, as it was.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("This session isn't running elsewhere any more.").font(.caption).foregroundStyle(.secondary)
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.stateFailed) }
            if model.store.leadStatus.busy {
                Label(queued ? "It continues here as soon as Claude's current turn ends." : "Claude is in the middle of a turn here: continuing takes over once that turn ends.", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(queued ? AnyShapeStyle(.secondary) : AnyShapeStyle(.stateNeedsYou))
            }
            HStack {
                if let cwd = session?.cwd { Label(Paths.short(cwd), systemImage: "folder").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button {
                    continueHere()
                } label: {
                    Label(continuing ? "Continuing…" : queued ? "Waiting for the Turn to End" : model.store.leadStatus.busy ? "Continue When the Turn Ends" : "Continue in Doublet",
                          systemImage: "arrow.uturn.forward.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(session == nil || continuing || queued)
                .help(model.store.leadStatus.busy ? "Claude is in the middle of a turn here: this one takes over when it ends"
                      : session?.live == true ? "Fork it into Doublet: it keeps running there" : "Resume it in Doublet")
                .accessibilityIdentifier("continue-in-duet")
            }
        }
        .padding(.horizontal, density == .compact ? 12 : 16).padding(.vertical, 10)
        .background(.bar)
        .onChange(of: model.store.leadStatus.busy) { _, busy in if !busy { queued = false } }
    }

    private func continueHere() {
        continuing = true
        problem = nil
        Task {
            do {
                try await model.continueOutside(id)
                queued = model.store.leadStatus.busy
            } catch { problem = error.localizedDescription }
            continuing = false
        }
    }
}

/// One message of a session from outside Duet: what was said, and the tools Claude reached for.
struct OutsideMessageRow: View {
    let message: OutsideMessage

    var body: some View {
        if message.role == "user" {
            if !message.text.isEmpty {
                Text(message.text).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.slateHigh) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, 48)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty {
                    Markdown(message.text).markdownSoftBreakMode(.lineBreak).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array((message.tools ?? []).enumerated()), id: \.offset) { _, tool in
                    Label(tool, systemImage: "wrench.and.screwdriver")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

/// A session running elsewhere, in a list (the sidebar, the card): its name, and where and how it runs.
struct OutsideRow: View {
    @Environment(AppModel.self) private var model
    let session: OutsideSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: AppModel.symbol(of: session))
                .foregroundStyle(session.status == "busy" ? Color.stateWorking : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).lineLimit(1).truncationMode(.tail)
                Text(model.whereLine(session).replacingOccurrences(of: " on the hub", with: "") + " · " + Paths.name(session.cwd))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if session.status == "busy" { Circle().fill(Color.stateWorking).frame(width: 6, height: 6) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The Overview's last card, folded away until you open it: Claude sessions running outside Duet on the hub machine, busy ones
/// first. Each opens in the centre, live, with Continue in Duet.
struct RunningElsewhereCard: View {
    @Environment(AppModel.self) private var model
    @State private var showsAll = false
    /// Folded unless you opened it; this device remembers.
    @AppStorage("overview.elsewhereOpen") private var open = false

    var body: some View {
        let sessions = model.outsideSessions
        let busy = sessions.filter { $0.status == "busy" }.count
        let summary = (sessions.count == 1 ? "1 session" : "\(sessions.count) sessions") + (busy > 0 ? " · \(busy) busy" : "")
        RailCard(title: "Elsewhere", symbol: "rectangle.on.rectangle", summary: summary,
                 open: { withAnimation(.snappy) { open.toggle() } }, expanded: open) {
            if open { rows(sessions) }
        }
        .accessibilityIdentifier("card-running-elsewhere")
    }

    @ViewBuilder private func rows(_ sessions: [OutsideSession]) -> some View {
            ForEach(showsAll ? sessions : Array(sessions.prefix(4))) { s in
                Button { model.show(.outside(s.sessionId)) } label: { OutsideRow(session: s) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("card-outside-\(s.sessionId)")
            }
            if sessions.count > 4 {
                Button(showsAll ? "Show fewer" : "Show all \(sessions.count)") { withAnimation(.snappy) { showsAll.toggle() } }
                    .buttonStyle(.borderless).font(.caption)
            }
    }
}

/// The start of a conversation continued from a session that ran outside Duet: where it came from (and whether as a
/// copy, since it still ran there), and what was said there, folded away.
struct ImportedHeader: View {
    @Environment(AppModel.self) private var model
    let imported: ConversationImportEvent
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continued from \(Self.place(imported.from)): \(imported.from.name)").font(.subheadline.weight(.semibold))
                    Text(imported.forked ? "A copy: it kept running there, in \(Paths.short(imported.from.cwd))."
                                         : "It had ended there; this is that session, picked up here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: AppModel.symbol(of: imported.from)).foregroundStyle(.secondary)
            }
            if !imported.messages.isEmpty {
                DisclosureGroup(isExpanded: $shown) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(imported.messages) { OutsideMessageRow(message: $0) }
                    }
                    .padding(.top, 8)
                } label: {
                    Text(imported.messages.count == 1 ? "Its last message" : "Its last \(imported.messages.count) messages").font(.callout)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary) }
        .padding(.vertical, 6)
        .accessibilityIdentifier("imported-header")
    }

    static func place(_ s: OutsideSession) -> String {
        switch s.place {
        case "desktop": "Claude Desktop"
        case "terminal": "a terminal"
        case "background": "the background"
        default: "elsewhere"
        }
    }
}
