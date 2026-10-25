#if os(iOS)
import DuetKit
import SwiftUI

/// Tags the device's model suggests for each note, worked out in the background as notes close, so the review is
/// ready the moment the page is left.
@MainActor @Observable
final class TagSuggestions {
    static let shared = TagSuggestions()

    /// Suggested tags by note id (empty: nothing to suggest, or the model is off).
    private(set) var made: [String: [String]] = [:]
    @ObservationIgnored private var queue: [(id: String, note: String, code: String)] = []
    @ObservationIgnored private var working = false
    /// The device's model (set by the page that writes notes).
    @ObservationIgnored weak var apple: AppleIntelligence?

    /// Work out suggestions for these notes, unless already done or reviewed.
    func prepare(_ drafts: [DraftNote]) {
        for d in drafts where d.tagsReviewed != true && made[d.id] == nil && !queue.contains(where: { $0.id == d.id }) {
            let words = d.note.text ?? d.raw ?? ""
            guard !words.isEmpty else { made[d.id] = []; continue }
            queue.append((d.id, words, d.note.lines?.first?.code ?? ""))
        }
        Task { await work() }
    }

    private func work() async {
        guard !working else { return }
        working = true
        defer { working = false }
        while !queue.isEmpty {
            let job = queue.removeFirst()
            let existing = NoteTags.shared.all
            let raw = await apple?.suggestTags(note: job.note, code: job.code, answer: nil, existing: existing) ?? []
            made[job.id] = Self.tidy(raw, existing: existing)
        }
    }

    /// Suggestions as tags: trimmed, an existing tag's own spelling when one matches but for case, no repeats, at most
    /// `NoteTags.limit`.
    nonisolated static func tidy(_ raw: [String], existing: [String]) -> [String] {
        var out: [String] = []
        for r in raw {
            guard let t = NoteTags.clean(r) else { continue }
            let tag = existing.first { $0.caseInsensitiveCompare(t) == .orderedSame } ?? t.lowercased()
            if !out.contains(tag) { out.append(tag) }
        }
        return Array(out.prefix(NoteTags.limit))
    }
}

/// The notes written on a file since its last review, offered for tagging as the page is left: each with the tags it
/// has and the ones suggested, to confirm, edit or remove.
struct TagReview: Identifiable {
    struct Note: Identifiable {
        let id: String
        let text: String
        let line: Int?
        var tags: [String]
    }

    let id = UUID()
    /// The file's page key ("file-<path>"), and its name for the title.
    let key: String
    let path: String
    var notes: [Note]

    init(key: String, path: String, drafts: [DraftNote]) {
        self.key = key
        self.path = path
        notes = drafts.map { Note(id: $0.id, text: $0.note.text ?? $0.raw ?? "Handwritten note", line: $0.note.lines?.first?.start, tags: $0.tags ?? []) }
    }

    /// The tags chosen, onto the file's notes: the open page takes them at once, and the kept book too.
    @MainActor func apply(_ chosen: [String: [String]]) {
        for n in notes {
            let tags = Array((chosen[n.id] ?? n.tags).prefix(NoteTags.limit))
            NoteTags.shared.use(tags)
            NotificationCenter.default.post(name: NoteTags.noteTagged, object: nil, userInfo: ["key": key, "id": n.id, "tags": tags])
        }
        let key = key, all = Dictionary(notes.map { ($0.id, Array((chosen[$0.id] ?? $0.tags).prefix(NoteTags.limit))) }, uniquingKeysWith: { a, _ in a })
        Task.detached(priority: .utility) {
            CodeNoteBook.update(key: key) { book in
                for i in book.drafts.indices {
                    if let t = all[book.drafts[i].id] { book.drafts[i].tags = t; book.drafts[i].tagsReviewed = true }
                }
            }
        }
    }
}

/// The review: one small sheet with every note since the last one, its tags as chips (suggestions added), and a field
/// to add another. Done files them; Skip keeps each note's tags as they are.
struct TagReviewSheet: View {
    let review: TagReview
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: [String: [String]] = [:]
    @State private var adding: [String: String] = [:]
    private let suggestions = TagSuggestions.shared

    var body: some View {
        NavigationStack {
            List {
                ForEach(review.notes) { n in
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(n.text).font(.callout).lineLimit(3)
                            chips(n)
                            HStack {
                                TextField("Add a tag", text: Binding(get: { adding[n.id] ?? "" }, set: { adding[n.id] = $0 }))
                                    .textInputAutocapitalization(.never)
                                    .onSubmit { add(n) }
                                    .disabled(tags(n).count >= NoteTags.limit)
                                if suggestions.made[n.id] == nil { ProgressView().controlSize(.small) }
                            }
                            .font(.callout)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text(n.line.map { "\(Paths.name(review.path)):\($0)" } ?? Paths.name(review.path))
                    }
                }
            }
            .navigationTitle("Tag your notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { review.apply([:]); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { review.apply(Dictionary(review.notes.map { ($0.id, tags($0)) }, uniquingKeysWith: { a, _ in a })); dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The note's tags: what it has, with the suggestions taken in, unless changed here.
    private func tags(_ n: TagReview.Note) -> [String] {
        chosen[n.id] ?? Array((n.tags + (suggestions.made[n.id] ?? []).filter { !n.tags.contains($0) }).prefix(NoteTags.limit))
    }

    /// Every tag on offer for the note (its own, suggested, added here), each on or off.
    @ViewBuilder private func chips(_ n: TagReview.Note) -> some View {
        let on = tags(n)
        let offered = (n.tags + (suggestions.made[n.id] ?? []) + on).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if offered.isEmpty {
            Text("No tags yet").font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(offered, id: \.self) { t in
                        let isOn = on.contains(t)
                        Button { toggle(t, on: n) } label: {
                            Label(t, systemImage: isOn ? "checkmark" : "plus")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                // Chips stay neutral; a chosen one is outlined in your hand's colour (and shows a check).
                                .background(Capsule().fill(isOn ? Color.slateHigh : Color.slateWell))
                                .overlay(Capsule().strokeBorder(isOn ? Color.stateNeedsYou : Color.slateLine, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(!isOn && on.count >= NoteTags.limit)
                    }
                }
            }
        }
    }

    private func toggle(_ t: String, on n: TagReview.Note) {
        var now = tags(n)
        if let i = now.firstIndex(of: t) { now.remove(at: i) } else if now.count < NoteTags.limit { now.append(t) }
        chosen[n.id] = now
    }

    private func add(_ n: TagReview.Note) {
        guard let t = NoteTags.clean(adding[n.id] ?? "") else { return }
        let tag = NoteTags.shared.all.first { $0.caseInsensitiveCompare(t) == .orderedSame } ?? t
        var now = tags(n)
        if !now.contains(tag), now.count < NoteTags.limit { now.append(tag) }
        chosen[n.id] = now
        adding[n.id] = ""
    }
}
#endif
