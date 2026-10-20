import Foundation

/// Where a composer message goes. Plain text and `@claude …` go to Claude; `@all …` goes to Claude and every running
/// worker; `@<worker> …` becomes a task for that worker. An unknown `@name` is just text for Claude.
public enum DraftRoute: Equatable, Sendable {
    case claude(String)
    case all(String)
    case worker(id: String, task: String)

    public static func route(_ draft: String, workers: [String]) -> DraftRoute? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.hasPrefix("@"), let space = text.firstIndex(where: { $0 == " " || $0 == "\n" }) else { return .claude(text) }
        let name = text[text.index(after: text.startIndex)..<space].lowercased()
        let body = text[space...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .claude(text) }
        switch name {
        case "claude": return .claude(body)
        case "all": return .all(body)
        default: return workers.contains(name) ? .worker(id: name, task: body) : .claude(text)
        }
    }
}
