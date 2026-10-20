import DuetKit
import MarkdownUI
import SwiftUI

/// An answer as a sticky note where you asked (iPad and Mac): a question written on a page or asked with Ask Here, or
/// a side chat closed while Claude was still answering. It shows the short answer as it comes, More for the rest, and
/// the way into its thread. Drag it by its top row anywhere in the window (it stays where it's left, whatever else comes
/// and goes), pin it to keep it while you go to another conversation, pop it out into a window of its own, or close it.
/// Its thread stays under its conversation either way.
struct Sticky: Identifiable, Equatable {
    enum Source: Hashable {
        case note(String)
        case sideChat(String)
    }

    let id = UUID()
    let source: Source
    /// What was asked, until the hub has the note (a handwritten one's recognized text).
    var question: String?
    /// The conversation it was asked in: unpinned, it shows while that conversation is in the centre.
    var conversationId: String?
    var pinned = false
    /// Where it was dragged to (its top leading corner, in its window's sticky layer); nil: never moved, so it stacks
    /// in the corner with the others.
    var origin: CGPoint?
    var expanded = false

    /// Its thread, in the centre.
    var thread: Destination {
        switch source {
        case .note(let id): .note(id)
        case .sideChat(let id): .sideChat(id)
        }
    }
}

/// What a sticky shows now.
struct StickyContent {
    /// Where it was asked: "Lexer.swift:27", "“Escape” in Lexer states", a side chat's title.
    var title: String
    var question: String
    /// The answer (Markdown), or what's streamed of it so far.
    var answer: String?
    var streaming = false
    /// While there's no answer to show: who has it, what Claude is doing, or why it couldn't answer.
    var status: String?
    var failed = false
    /// Who answered and how ("qwen-27b · 2 citations checked · 14 s").
    var by: String?

    /// The answer's start, at most 65 words: its first paragraph of prose, without "Let me look…" or Markdown's
    /// marks; and whether there's more to it.
    @MainActor static func short(_ markdown: String) -> (text: String, more: Bool) {
        let gist = FileViewer.gist(markdown)
        let words = gist.split(whereSeparator: \.isWhitespace)
        if words.count > 65 { return (words.prefix(65).joined(separator: " ") + "…", true) }
        let paragraphs = markdown.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (gist, paragraphs.count > 1)
    }
}

extension AppModel {
    /// A question was asked: its answer comes as a sticky note where you are (iPad and Mac). One per thread.
    func stick(_ source: Sticky.Source, question: String? = nil) {
        guard !compactLayout, !stickies.contains(where: { $0.source == source }) else { return }
        withAnimation(.snappy) {
            stickies.append(Sticky(source: source, question: question, conversationId: activeConversationId))
        }
    }

    func unstick(_ id: Sticky.ID) {
        withAnimation(.snappy) { stickies.removeAll { $0.id == id } }
    }

    func updateSticky(_ id: Sticky.ID, _ change: (inout Sticky) -> Void) {
        guard let i = stickies.firstIndex(where: { $0.id == id }) else { return }
        change(&stickies[i])
    }

    /// The window a sticky shows in: the one showing what its note is on, if that's in a window of its own; else the
    /// main window (nil).
    func stickyWindow(_ s: Sticky) -> Destination? {
        guard case .note(let id) = s.source, let on = anchor(ofNote: id), workspace.window(for: on) != nil else { return nil }
        return on.identity
    }

    /// The stickies a window shows now, newest last. The main window: pinned ones, and those asked in the conversation
    /// in its centre, but not one whose thread is the centre itself. A pane's window: those asked about what it shows.
    func shownStickies(in window: Destination?) -> [Sticky] {
        let here = conversationId(in: workspace.centre) ?? activeConversationId
        let shown = stickies.filter { s in
            guard stickyWindow(s) == window?.identity else { return false }
            if window != nil { return true }
            if workspace.centre == s.thread { return false }
            return s.pinned || s.conversationId == nil || s.conversationId == here
        }
        return Array(shown.suffix(4))
    }

    /// What a sticky shows: the question, and the answer as far as it's come (or who has it).
    func stickyContent(_ s: Sticky) -> StickyContent {
        switch s.source {
        case .note(let id):
            guard let a = store.annotations[id] else {
                return StickyContent(title: "Your question", question: s.question ?? "Your handwritten note", status: "Sending…")
            }
            var c = StickyContent(title: noteAnchorName(a), question: s.question ?? a.text ?? "Your handwritten note")
            if a.answered, let answer = a.answer, !answer.isEmpty {
                c.answer = AnnotationDetail.withoutNarration(answer)
                c.by = AnswerChip.text(for: a)
            } else if let chat = a.chatId.flatMap({ store.sideChats[$0] }), chat.isAnswering {
                if chat.streaming.isEmpty { c.status = SideChatView.activity(chat.activity) } else { c.answer = chat.streaming }
                c.streaming = true
            } else if a.answering == nil, let why = a.escalated, !why.isEmpty {
                c.status = why
                c.failed = true
            } else {
                c.status = a.answering == "Claude" ? "Claude is answering…" : a.answering != nil ? "A local model is reading the code…" : "Waiting for Claude…"
            }
            return c
        case .sideChat(let id):
            guard let chat = store.sideChats[id] else { return StickyContent(title: "Side chat", question: s.question ?? "", status: "Waiting…") }
            var c = StickyContent(title: chat.title, question: chat.messages.first { $0.role == "user" }?.text ?? s.question ?? chat.title)
            if chat.isAnswering {
                if chat.streaming.isEmpty { c.status = SideChatView.activity(chat.activity) } else { c.answer = chat.streaming }
                c.streaming = true
            } else if let last = chat.messages.last(where: { $0.role != "user" }) {
                c.answer = last.text
                c.by = last.model
            } else if let error = chat.error {
                c.status = error
                c.failed = true
            }
            return c
        }
    }
}

/// The stickies a window shows, over all of it: those never moved stack in its bottom trailing corner, newest at the
/// bottom; a moved one stays where it was left. Only the stickies take touches; the rest of the layer lets them through.
struct StickyLayer: View {
    @Environment(AppModel.self) private var model
    /// The pane's window it's in; nil for the main window.
    var window: Destination? = nil
    /// Room kept free at the bottom of the corner (above the main window's composer).
    var bottom: CGFloat = 0

    /// The layer's own space, which stays still while a sticky moves: what a sticky's drag is measured in.
    nonisolated static let space = "duet.stickies"

    var body: some View {
        let shown = model.shownStickies(in: window)
        // Where each was left goes in the layout itself: a change there lays them out again.
        StickyArrangement(bottom: bottom, origins: shown.map(\.origin)) {
            ForEach(shown) { StickyNote(sticky: $0) }
        }
        .coordinateSpace(.named(Self.space))
        .animation(.snappy, value: model.stickies)
    }
}

/// The sticky layer's layout. It fills what it's given; stickies never moved stack up from its bottom trailing corner
/// (the last, newest, lowest), and a moved one goes where it was left, kept 8 points inside the layer.
private struct StickyArrangement: Layout {
    var bottom: CGFloat
    /// Where each sticky was left, in order; nil: never moved.
    var origins: [CGPoint?]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.maxY - bottom - 16
        for (i, subview) in subviews.enumerated().reversed() {
            let size = subview.sizeThatFits(.unspecified)
            if i < origins.count, let origin = origins[i] {
                let x = min(max(bounds.minX + origin.x, bounds.minX + 8), max(bounds.minX + 8, bounds.maxX - size.width - 8))
                let top = min(max(bounds.minY + origin.y, bounds.minY + 8), max(bounds.minY + 8, bounds.maxY - size.height - 8))
                subview.place(at: CGPoint(x: x, y: top), anchor: .topLeading, proposal: ProposedViewSize(size))
            } else {
                subview.place(at: CGPoint(x: bounds.maxX - 16, y: y), anchor: .bottomTrailing, proposal: ProposedViewSize(size))
                y -= size.height + 10
            }
        }
    }
}

/// One sticky: where it was asked, the question, the short answer (all of it under More), and its thread.
struct StickyNote: View {
    @Environment(AppModel.self) private var model
    @Environment(\.density) private var density
    @Environment(\.supportsMultipleWindows) private var multipleWindows
    let sticky: Sticky
    @GestureState private var drag: CGSize = .zero
    /// Where it is in the layer while it isn't being dragged: where a drag starts from.
    @State private var rest: CGRect = .zero

    var body: some View {
        let c = model.stickyContent(sticky)
        VStack(alignment: .leading, spacing: 8) {
            header(c)
            Text(c.question)
                .font(.callout.weight(.semibold))
                .lineLimit(sticky.expanded ? 6 : 2)
            answer(c)
            footer(c)
        }
        .padding(12)
        .frame(width: density == .dense ? 300 : 340, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.yellow.opacity(0.14))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.yellow.opacity(0.5)) }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(StickyLayer.space)) } action: { if drag == .zero { rest = $0 } }
        .offset(drag)
        .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Answer: \(c.question)")
        .accessibilityIdentifier("sticky")
    }

    /// Where it was asked; then pin, pop out, and close. The whole row is the handle to drag it by (anywhere but its
    /// buttons), at least as tall as a finger.
    private func header(_ c: StickyContent) -> some View {
        HStack(spacing: 10) {
            Label(c.title, systemImage: sticky.thread.isNote ? "note.text" : "bubble.left.and.bubble.right")
                .labelStyle(.titleAndIcon)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Drag to move it")
            Button(sticky.pinned ? "Unpin" : "Pin", systemImage: sticky.pinned ? "pin.fill" : "pin") {
                model.updateSticky(sticky.id) { $0.pinned.toggle() }
            }
            .help(sticky.pinned ? "Show it only with its conversation" : "Keep it here while you go to another conversation")
            if multipleWindows {
                Button("Open in Window", systemImage: "macwindow.badge.plus") {
                    model.unstick(sticky.id)
                    switch sticky.source {
                    case .note(let id): model.openWindow(.pane(.note(id)))
                    case .sideChat(let id): model.openWindow(.side(SideChatRef(chatId: id)))
                    }
                }
                .help("Its thread in a window of its own, to keep anywhere")
            }
            Button("Close", systemImage: "xmark") { model.unstick(sticky.id) }
                .help("Close it; its thread stays under its conversation")
                .accessibilityIdentifier("sticky-close")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.caption)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .gesture(
            // In the layer's space, which stays still while the sticky moves under the finger.
            DragGesture(minimumDistance: 3, coordinateSpace: .named(StickyLayer.space))
                .updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    let origin = CGPoint(x: rest.minX + value.translation.width, y: rest.minY + value.translation.height)
                    withAnimation(.snappy) { model.updateSticky(sticky.id) { $0.origin = origin } }
                }
        )
        .padding(.vertical, -8)
    }

    @ViewBuilder private func answer(_ c: StickyContent) -> some View {
        if let answer = c.answer {
            if sticky.expanded, !c.streaming {
                ScrollView {
                    Markdown(answer).markdownSoftBreakMode(.lineBreak).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(StickyContent.short(answer).text).textSelection(.enabled)
                    if c.streaming { ProgressView().controlSize(.mini) }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let status = c.status {
            HStack(spacing: 6) {
                if c.failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(status).font(.callout).foregroundStyle(c.failed ? .orange : .secondary).lineLimit(2)
            }
        }
    }

    private func footer(_ c: StickyContent) -> some View {
        HStack(spacing: 12) {
            if let answer = c.answer, !c.streaming, StickyContent.short(answer).more {
                Button(sticky.expanded ? "Less" : "More") {
                    withAnimation(.snappy) { model.updateSticky(sticky.id) { $0.expanded.toggle() } }
                }
            }
            if let by = c.by { Text(by).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 0)
            Button("Open Thread") {
                model.unstick(sticky.id)
                model.show(sticky.thread)
            }
            .help("Its whole thread, in the centre")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

private extension Destination {
    var isNote: Bool { if case .note = self { true } else { false } }
}
