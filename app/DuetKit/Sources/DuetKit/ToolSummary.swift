import Foundation

/// One line describing a tool call in the thread: the command, the file or the pattern, not raw JSON.
public enum ToolSummary {
    public static func text(_ tool: String, _ input: JSONValue) -> String {
        guard case .object(let o) = input else { return input.compact }
        return text(tool, o)
    }

    public static func text(_ tool: String, _ o: [String: JSONValue]) -> String {
        func s(_ k: String) -> String? { o[k]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        func within(_ p: String) -> String { s("path").map { "\(p)  in \($0)" } ?? p }
        let known: String? = switch tool {
        case "Bash": s("command").map(firstLine)
        case "Read", "Write", "Edit", "MultiEdit": s("file_path")
        case "NotebookEdit": s("notebook_path")
        case "Grep", "Glob": s("pattern").map(within)
        case "WebFetch": s("url")
        case "WebSearch": s("query")
        case "Task", "Agent": s("description")
        case "Workflow": workflowName(o)
        default: nil
        }
        if let known { return known }
        // Anything else: its first text argument, else compact JSON.
        if let first = o.keys.sorted().lazy.compactMap({ s($0) }).first { return firstLine(first) }
        return JSONValue.object(o).compact
    }

    /// "duet.delegate" for "mcp__duet__delegate" (any MCP tool reads server.tool); other tools keep their name.
    public static func displayName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.components(separatedBy: "__")
        return parts.count >= 3 ? "\(parts[1]).\(parts[2...].joined(separator: "__"))" : tool
    }

    /// What a subagent is called: the few words Claude gave it ("Find subagent handling"), else its prompt's first line.
    public static func agentLabel(_ input: JSONValue) -> String {
        guard case .object(let o) = input else { return "Subagent" }
        if let d = o["description"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { return d }
        let first = o["prompt"]?.stringValue?.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return first.isEmpty ? "Subagent" : String(first.prefix(80))
    }

    /// A workflow's name: its script's `meta` name, a saved workflow's name, or its script file's name.
    static func workflowName(_ o: [String: JSONValue]) -> String? {
        if let script = o["script"]?.stringValue,
           let m = script.firstMatch(of: #/meta\s*=\s*\{[^}]*?\bname\s*:\s*['"`]([^'"`\n]+)['"`]/#) {
            return String(m.1)
        }
        if let name = o["name"]?.stringValue, !name.isEmpty { return name }
        if let path = o["scriptPath"]?.stringValue, !path.isEmpty {
            return String(path.split(separator: "/").last ?? Substring(path)).replacingOccurrences(of: ".js", with: "")
        }
        return o["script"] == nil ? nil : "workflow"
    }

    /// Duet's own dialogue tools (delegate, answer, ask_lead…): threads show their messages, not the calls.
    public static func isDialogue(_ tool: String) -> Bool { tool.hasPrefix("mcp__duet__") }
    /// Claude Code's tool for starting a subagent (Task in older versions).
    public static func isSubagent(_ tool: String) -> Bool { tool == "Agent" || tool == "Task" }

    /// A tool call as one line: its name, then its command, file or pattern.
    public static func line(_ tool: String, _ input: JSONValue) -> String { "\(displayName(tool))  \(text(tool, input))" }

    /// An older progress line, "name {json}", where the JSON may be cut short: summarized when it parses.
    public static func legacyLine(_ s: String) -> String {
        guard let space = s.firstIndex(of: " ") else { return displayName(s) }
        let name = String(s[..<space])
        let json = s[s.index(after: space)...]
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else { return "\(displayName(name))  \(json)" }
        return line(name, v)
    }

    /// A tool result as text. MCP results arrive as a JSON array of content blocks (older hubs cut them at 500 characters).
    public static func resultText(_ s: String) -> String {
        let prefix = #"[{"type":"text","text":""#
        guard s.hasPrefix("[{") else { return s }
        if let v = try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)), case .array(let blocks) = v {
            let texts = blocks.compactMap { b -> String? in
                if case .object(let o) = b { return o["text"]?.stringValue }
                return nil
            }
            return texts.isEmpty ? s : texts.joined(separator: "\n")
        }
        guard s.hasPrefix(prefix) else { return s }
        return String(s.dropFirst(prefix.count)).replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func firstLine(_ t: String) -> String {
        let lines = t.split(separator: "\n", omittingEmptySubsequences: true)
        guard let f = lines.first else { return t }
        return lines.count > 1 ? "\(f) …" : String(f)
    }
}
