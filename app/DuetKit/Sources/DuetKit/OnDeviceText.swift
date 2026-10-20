import CryptoKit
import Foundation

/// Text around Apple's on-device model: stable keys for what it made, input with the noise taken out, and its output
/// cleaned up (or refused) before anyone sees it.
public enum OnDeviceText {
    /// A stable key for a text, the same on every launch (a String's `hashValue` isn't).
    public static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.prefix(6000).utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// Claude's narration before the answer ("Let me check the file.", "I'll look at…") taken out, so a summary is about
    /// what it found rather than what it was about to do. The text as it was when that would leave nothing.
    public static func withoutNarration(_ text: String) -> String {
        var paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let narration = #"^(Let me|Let's|I'll|I will|Now I'll|Now let me|First, I'll|First, let me|I'm going to|Okay, (let me|I'll))\b"#
        while paragraphs.count > 1, paragraphs[0].range(of: narration, options: .regularExpression) != nil { paragraphs.removeFirst() }
        return paragraphs.isEmpty ? text : paragraphs.joined(separator: "\n\n")
    }

    /// A model's one-liner, cleaned: no wrapping quotes, labels or preamble, at most `maxWords` words. Nil for a
    /// refusal or nothing.
    public static func line(_ raw: String, maxWords: Int = 24) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.split(separator: "\n").first { s = String(first) }
        s = s.replacingOccurrences(of: #"^(Summary|Here'?s (a|the) (one-line )?summary|One-line summary|Line)\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ ").union(.whitespaces))
        guard !s.isEmpty, !refuses(s) else { return nil }
        let words = s.split(whereSeparator: \.isWhitespace)
        return words.count > maxWords ? words.prefix(maxWords).joined(separator: " ") + "…" : s
    }

    /// A name for a conversation or side chat: 2–8 words, without quotes or a full stop. Nil otherwise.
    public static func title(_ raw: String) -> String? {
        guard let l = line(raw, maxWords: 12) else { return nil }
        let t = l.trimmingCharacters(in: CharacterSet(charactersIn: ".!:;,").union(.whitespaces))
        let words = t.split(whereSeparator: \.isWhitespace)
        return (2...8).contains(words.count) ? words.joined(separator: " ") : nil
    }

    static func refuses(_ s: String) -> Bool {
        s.range(of: #"^(I'm sorry|Sorry|I can'?t|I cannot|I am unable|I'm unable|As an AI)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// What a command's output says, in one line: read straight from the formats test runners, compilers and builds
/// print, so most runs need no model at all.
public enum ToolOutput {
    /// The run's verdict ("2 of 85 tests failed: FleetTests.auto, …", "Build failed: 3 errors, first a.swift:12 …"), or
    /// nil when the output isn't one this knows.
    public static func verdict(_ out: String) -> String? {
        let lines = out.components(separatedBy: .newlines)
        func first(_ pattern: String) -> [String]? {
            for l in lines.reversed() { if let m = groups(l, pattern) { return m } }
            return nil
        }
        // Swift Testing.
        if let m = first(#"Test run with (\d+) tests?.* passed after"#) { return "All \(m[1]) tests passed" }
        if let m = first(#"Test run with (\d+) tests?.* failed after .* with (\d+) issues?"#) {
            return failed(of: m[1], issues: m[2], names: names(lines, #"✘ Test (\w+)\(.*\) (recorded an issue|failed)"#))
        }
        // XCTest.
        if let m = first(#"Executed (\d+) tests?, with (\d+) failures?"#) {
            return m[2] == "0" ? "All \(m[1]) tests passed" : failed(m[2], of: m[1], names: names(lines, #"Test Case '-\[\S+ (\w+)\]' failed"#))
        }
        // node --test (TAP).
        if let total = first(#"^# tests (\d+)"#), let fail = first(#"^# fail (\d+)"#) {
            return fail[1] == "0" ? "All \(total[1]) tests passed" : failed(fail[1], of: total[1], names: names(lines, #"^\s*not ok \d+ - (.+)$"#))
        }
        // Jest and npm test.
        if let m = first(#"Tests:\s+(?:(\d+) failed, )?.*?(\d+) total"#) {
            return m[1].isEmpty ? "All \(m[2]) tests passed" : failed(m[1], of: m[2], names: names(lines, #"✕ (.+?)( \(\d+ ?ms\))?$"#))
        }
        // pytest.
        if let m = first(#"=+ (?:(\d+) failed)?(?:, )?(?:(\d+) passed)?.* in [\d.]+s"#), !(m[1].isEmpty && m[2].isEmpty) {
            let failedCount = Int(m[1]) ?? 0, passed = Int(m[2]) ?? 0
            return failedCount == 0 ? "All \(passed) tests passed" : failed(m[1], of: String(failedCount + passed), names: names(lines, #"^FAILED (\S+)"#))
        }
        // cargo test.
        if let m = first(#"test result: (ok|FAILED)\. (\d+) passed; (\d+) failed"#) {
            let total = String((Int(m[2]) ?? 0) + (Int(m[3]) ?? 0))
            return m[1] == "ok" ? "All \(total) tests passed" : failed(m[3], of: total, names: names(lines, #"^test (\S+) \.\.\. FAILED"#))
        }
        // TypeScript.
        let tsErrors = lines.compactMap { groups($0, #"^(\S+?)\((\d+),\d+\): error (TS\d+): (.+)$"#) }
        if !tsErrors.isEmpty { return "\(count(tsErrors.count, "type error")), first \(Paths.name(tsErrors[0][1])):\(tsErrors[0][2]) \(tsErrors[0][4])".clipped(110) }
        // xcodebuild and swift build.
        let compileErrors = lines.compactMap { groups($0, #"^(\S+?):(\d+):\d+: error: (.+)$"#) }
        if lines.contains(where: { $0.contains("** BUILD FAILED **") || $0.contains("** TEST FAILED **") }) || !compileErrors.isEmpty {
            guard let e = compileErrors.first else { return "Build failed" }
            return "Build failed: \(count(compileErrors.count, "error")), first \(Paths.name(e[1])):\(e[2]) \(e[3])".clipped(110)
        }
        if lines.contains(where: { $0.contains("** TEST SUCCEEDED **") }) { return "Tests passed" }
        if lines.contains(where: { $0.contains("** BUILD SUCCEEDED **") }) || first(#"^Build complete!"#) != nil { return "Build succeeded" }
        return nil
    }

    /// The part of a long output worth a model's time: its error lines and its end, within `limit` characters.
    public static func excerpt(_ out: String, limit: Int = 3000) -> String {
        guard out.count > limit else { return out }
        let errors = out.components(separatedBy: .newlines).filter { $0.range(of: #"(?i)\b(error|failed|fatal|exception|panic)\b"#, options: .regularExpression) != nil }.prefix(12).joined(separator: "\n")
        let room = max(800, limit - errors.count)
        return (errors.isEmpty ? "" : errors + "\n…\n") + String(out.suffix(room))
    }

    private static func failed(_ n: String, of total: String, names: [String]) -> String {
        let list = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
        return "\(n) of \(total) tests failed\(list.isEmpty ? "" : ": \(list)")".clipped(110)
    }

    private static func failed(of total: String, issues: String, names: [String]) -> String {
        let list = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
        return "\(count(Int(issues) ?? 0, "issue")) in \(total) tests\(list.isEmpty ? "" : ": \(list)")".clipped(110)
    }

    private static func names(_ lines: [String], _ pattern: String) -> [String] {
        var seen: [String] = []
        for l in lines { if let m = groups(l, pattern), !seen.contains(m[1]) { seen.append(m[1]) } }
        return seen
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// The pattern's capture groups in `line` (index 0 is the whole match; a group that didn't take part is "").
    private static func groups(_ line: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: line).map { String(line[$0]) } ?? "" }
    }
}

private extension String {
    func clipped(_ n: Int) -> String { count > n ? String(prefix(n - 1)) + "…" : self }
}
