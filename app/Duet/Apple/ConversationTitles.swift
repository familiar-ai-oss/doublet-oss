import DuetKit
import Foundation
import Observation

/// Names for conversations, made on this device: Apple Intelligence reads the first exchange and names it; without
/// it, the first prompt stands in. Kept in UserDefaults, so names survive relaunches (each device names for itself).
@MainActor @Observable
final class ConversationTitles {
    struct Entry: Codable, Equatable {
        var text: String
        /// Made from the prompt and Claude's reply (else from the prompt alone, to be redone once there's a reply).
        var withReply: Bool
        /// Typed by you: never replaced by the model.
        var renamed: Bool
    }

    private(set) var entries: [String: Entry] = [:]
    /// One name at a time on the model.
    @ObservationIgnored private var queue: Task<Void, Never>?
    private static let key = "conversationTitles"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let e = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = e }
    }

    /// The name to show now: the kept one, else (continued from a session outside Duet) that session's name, else the
    /// first prompt's first line, else "New conversation".
    func title(for c: Conversation?) -> String {
        if let c, let e = entries[c.id] { return e.text }
        return Self.fallback(c)
    }

    static func fallback(_ c: Conversation?) -> String {
        if let name = c?.imported?.from.name, !name.isEmpty { return name }
        guard let line = c?.firstPrompt?.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return "New conversation" }
        return line.count > 48 ? String(line.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    /// Still needs a name from the model: none yet, or one made before Claude had replied.
    func needsName(_ c: Conversation) -> Bool {
        // Continued from a session outside Duet: it keeps that session's name.
        guard c.firstPrompt != nil, !c.isProvisional, c.imported == nil else { return false }
        guard let e = entries[c.id] else { return true }
        return !e.renamed && !e.withReply && c.firstReply != nil
    }

    /// Names a conversation on the model, one at a time. Nothing happens in previews, before the first replay is
    /// in, or when it already has its name.
    func ensure(_ c: Conversation, apple: AppleIntelligence, replayed: Bool) async {
        guard replayed, !AppModel.inPreview, needsName(c), apple.isAvailable, let prompt = c.firstPrompt else { return }
        let previous = queue
        let job = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.needsName(c) else { return }
            guard let text = await apple.title(prompt: prompt, reply: c.firstReply) else { return }
            self.entries[c.id] = Entry(text: text, withReply: c.firstReply != nil, renamed: false)
            self.save()
        }
        queue = job
        await job.value
    }

    /// Your own name for it; empty goes back to the made one.
    func rename(_ id: String, to text: String?) {
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        entries[id] = t.isEmpty ? nil : Entry(text: t, withReply: true, renamed: true)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Better names for side chats asked on this device: a long question's first line makes a poor name, so once it's
/// answered, Apple Intelligence names the exchange and the hub gives the name to every device. Short questions keep
/// their own words; note threads keep their note's name. Each chat is named once.
@MainActor
final class SideChatTitles {
    private var named: Set<String>
    private var queue: Task<Void, Never>?
    private static let key = "sideChatsNamed"

    init() { named = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? []) }

    func storeChanged(_ s: DuetStore, apple: AppleIntelligence, device: String, send: @escaping (ClientMessage) -> Void) {
        guard !AppModel.inPreview, apple.isAvailable, queue == nil else { return }
        let dayAgo = Date().addingTimeInterval(-86_400)
        guard let chat = s.sideChats.values.first(where: { c in
            c.state == "idle" && c.annotationId == nil && c.by == device && c.startedAt > dayAgo && !named.contains(c.id)
                && Self.poorName(c.title) && c.messages.contains { $0.role == "assistant" }
        }), let question = chat.messages.first(where: { $0.role == "user" })?.text else { return }
        let answer = chat.messages.first { $0.role == "assistant" }?.text
        queue = Task { @MainActor [weak self] in
            defer { self?.queue = nil }
            guard let self else { return }
            self.named.insert(chat.id)
            UserDefaults.standard.set(Array(self.named.suffix(500)), forKey: Self.key)
            if let title = await apple.title(prompt: question, reply: answer), title != chat.title { send(.sideTitle(chatId: chat.id, title: title)) }
        }
    }

    /// A question's first line that doesn't name the chat well: long, cut off, or about a picture.
    static func poorName(_ title: String) -> Bool {
        title.count > 40 || title.hasSuffix("…") || title == "About the picture"
    }
}
