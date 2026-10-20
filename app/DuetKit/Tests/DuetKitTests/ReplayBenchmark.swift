import Foundation
import Testing
@testable import DuetKit

/// How long the store takes to apply a long history, as a hub replays it at launch (1,250 turns, about 7,500 events,
/// shaped like hub/tools/firehose.ts makes them). Off by default; run it on its own, in each build configuration:
///
///     DUET_BENCH=1 swift test --filter replayBenchmark
///     DUET_BENCH=1 swift test -c release --filter replayBenchmark
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["DUET_BENCH"] == "1"))
func replayBenchmark() throws {
    let lines = history(turns: 1250)
    let decodeStart = ContinuousClock.now
    let events: [HubEvent] = try lines.compactMap {
        if case .event(let e) = try JSONDecoder().decode(ServerFrame.self, from: Data($0.utf8)) { e } else { nil }
    }
    let decoded = ContinuousClock.now - decodeStart
    var best = Duration.seconds(1000)
    for _ in 0..<3 {
        let store = DuetStore()
        let t0 = ContinuousClock.now
        for e in events { store.apply(e) }
        best = min(best, ContinuousClock.now - t0)
        #expect(store.leadRows.count > 1250)
    }
    print("REPLAY \(events.count) events: apply \(best.formatted(.units(allowed: [.milliseconds]))), decode \(decoded.formatted(.units(allowed: [.milliseconds])))")
}

private func history(turns: Int) -> [String] {
    let conv = "f1re-h05e-0000-4000-8000-000000000001"
    var seq = 0
    var out: [String] = []
    func emit(_ body: [String: Any]) {
        seq += 1
        var b = body
        b["conversationId"] = conv
        b["seq"] = seq
        b["ts"] = 1_792_400_000_000 + seq
        out.append(String(decoding: try! JSONSerialization.data(withJSONObject: b), as: UTF8.self))
    }
    let words = "the parser keeps every token with its range so a diagnostic can point at the exact column while the lexer streams states".split(separator: " ")
    func paragraph(_ n: Int, _ seed: Int) -> String { (0..<n).map { String(words[(seed * 7 + $0 * 13) % words.count]) }.joined(separator: " ") + "." }
    func reply(_ i: Int) -> String {
        ["## Step \(i)", paragraph(40, i), "- `Lexer.swift`: " + paragraph(12, i + 1),
         "```swift\n" + (0..<12).map { "    let token\($0) = lexer.next()" }.joined(separator: "\n") + "\n```",
         "| File | Lines |\n|---|---|\n" + (0..<6).map { "| f\($0).ts | \($0 * 37 + i) |" }.joined(separator: "\n"),
         paragraph(60, i + 3)].joined(separator: "\n\n")
    }
    let output = (0..<400).map { "[\($0)] case passed (\($0 % 13) ms)" }.joined(separator: "\n")
    emit(["type": "session", "state": "ready", "sessionId": conv, "model": "claude-haiku-5-5"])
    for t in 1...turns {
        emit(["type": "user", "turn": t, "text": "Question \(t): " + paragraph(18, t), "by": "ipad"])
        emit(["type": "turn_start", "turn": t])
        let tool = ["id": "toolu_\(t)", "name": "Bash", "input": ["command": "swift test --filter Case\(t)", "description": "Run the tests"]] as [String: Any]
        emit(["type": "assistant", "turn": t, "text": "", "toolUses": [tool]])
        emit(["type": "tool_result", "turn": t, "toolUseId": "toolu_\(t)", "isError": false, "preview": String(output.prefix(2000)), "tail": String(output.suffix(1500))])
        emit(["type": "assistant", "turn": t, "text": reply(t), "toolUses": [] as [Any]])
        emit(["type": "turn_end", "turn": t, "subtype": "success", "isError": false, "interrupted": false, "durationMs": 4200, "numTurns": 2])
    }
    return out
}
