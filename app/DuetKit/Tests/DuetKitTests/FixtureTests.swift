import Foundation
import Testing
@testable import DuetKit

// protocol/fixtures is written by the hub's own tests on the hub machine (`make fixtures`).
private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("protocol/fixtures")

private func lines(_ name: String) throws -> [Data] {
    let text = try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
    return text.split(separator: "\n").map { Data($0.utf8) }
}

private func serverFiles() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: fixtures.path).filter { $0.hasSuffix(".jsonl") && $0 != "client.jsonl" }.sorted()
}

/// Parsed JSON with nulls removed (Swift omits nil optionals; the hub sometimes sends explicit null).
private func normalized(_ data: Data) throws -> NSObject {
    func strip(_ v: Any) -> Any {
        if let d = v as? [String: Any] { return d.filter { !($0.value is NSNull) }.mapValues(strip) }
        if let a = v as? [Any] { return a.map(strip) }
        return v
    }
    return strip(try JSONSerialization.jsonObject(with: data)) as! NSObject
}

@Test func fixturesExist() throws {
    let files = try serverFiles()
    #expect(files.count >= 3, "run `make fixtures` first")
}

@Test(arguments: try serverFiles())
func everyFrameDecodesToAKnownType(file: String) throws {
    for line in try lines(file) {
        let frame = try JSONDecoder().decode(ServerFrame.self, from: line)
        switch frame {
        case .unknown(let t): Issue.record("unknown control frame \(t) in \(file)")
        case .event(let e): if case .unknown(let t) = e.body { Issue.record("unknown event type \(t) in \(file)") }
        default: break
        }
    }
}

@Test(arguments: try serverFiles())
func eventsRoundTripWithoutLosingFields(file: String) throws {
    for line in try lines(file) {
        guard case .event(let e) = try JSONDecoder().decode(ServerFrame.self, from: line) else { continue }
        let again = try JSONEncoder().encode(e)
        let a = try normalized(line), b = try normalized(again)
        #expect(a == b, "seq \(e.seq) \(e.type) changed in a round trip:\n\(String(decoding: line, as: UTF8.self))\n\(String(decoding: again, as: UTF8.self))")
    }
}

@Test func clientMessagesMatchTheHubsCanonicalJSON() throws {
    // Same order as hub/test/client-fixtures.test.ts.
    let swift: [(ClientMessage, String?)] = [
        (.hello(token: "TOKEN", device: "mac", lastSeq: 42), nil),
        (.prompt(text: "Hello"), "1"),
        (.approve(id: "ab12cd34"), "2"),
        (.approve(id: "ab12cd34", updatedInput: ["command": .string("ls -la"), "timeout": .number(5000)]), "3"),
        (.reject(id: "ab12cd34", message: "Not that file"), "4"),
        (.interrupt, "5"),
        (.setEffort(.high), "6"),
        (.setEffort(nil), "7"),
        (.delegate(worker: "qwen-27b", prompt: "Fix the test", cwd: "/home/you/proj", effort: "xhigh"), "8"),
        (.cancelTask(taskId: "t-abc123"), "9"),
        (.setWorker(worker: "qwen-9b", effort: "on", temperature: 0.3, enabled: true), "10"),
        (.approveSwap(id: "s-abc123"), "11"),
        (.rejectSwap(id: "s-abc123"), "12"),
        (.answer(questionId: "q-abc123", text: "Use duet"), "13"),
        (.steer(taskId: "t-abc123", text: "Skip the docs"), "14"),
        (.setPause(true), "15"),
        (.prompt(text: "Think hard", boost: true), "16"),
        (.setWorker(worker: "qwen-9b", model: "gemma4-26b"), "17"),
        (.clear, "18"),
        (.compact, "19"),
        (.setModel("sonnet"), "20"),
        (.broadcast(text: "Status, everyone?"), "21"),
        (.ptyOpen(kind: .shell, cols: 100, rows: 30), "22"),
        (.ptyAttach(id: "pty-abc123"), "23"),
        (.ptyInput(id: "pty-abc123", data: "ls\r"), "24"),
        (.ptyResize(id: "pty-abc123", cols: 120, rows: 40), "25"),
        (.ptyClose(id: "pty-abc123"), "26"),
        (.delegate(worker: "apple-ipad", prompt: "Summarize the errors", files: ["/home/you/proj/build.log"]), "27"),
        (.appleStatus(AppleStatus(available: true, contextSize: 4096, capabilities: ["guidedGeneration", "toolCalling"], platform: "ipad", simulator: false,
                                  variant: "AFM 3 Core")), "28"),
        (.appleStatus(AppleStatus(available: false, reason: "modelNotReady", platform: "iphone")), "29"),
        (.appleProgress(taskId: "t-abc123", text: "Read part 1 of 3: disk full on /var"), "30"),
        (.appleDone(taskId: "t-abc123", ok: true, result: "Three errors, all disk full.", error: nil,
                    stats: AppleStats(inputTokens: 3900, outputTokens: 120, wallMs: 5200, firstTokenMs: 900, parts: 4, genMs: 3100)), "31"),
        (.appleDone(taskId: "t-abc123", ok: false, result: nil, error: "The text was too long for the on-device model", stats: nil), "32"),
        (.resumeSession(sessionId: "f35790a0-07ad-4715-9450-8b37023a3197"), "33"),
        (.sideAsk(text: "Why two GPUs?", about: .file(path: "/home/you/proj/fleet.ts", start: 12, end: 20), model: "haiku"), "34"),
        (.sideAsk(chatId: "sc-abc123", text: "And the 9B?"), "35"),
        (.sideAsk(text: "What is this?", about: .text(label: "qwen-27b's result", text: "Finished: 3 files"), image: "BASE64", imageType: "image/jpeg"), "36"),
        (.sideStop(chatId: "sc-abc123"), "37"),
        (.fsWatch(paths: ["/home/you/proj", "/home/you/proj/src"]), "38"),
        (.fsFiles(), "39"),
        (.prompt(text: "What does auto do?", voice: true), "40"),
        (.sideAsk(chatId: "sc-abc123", text: "Why that one?", voice: true), "41"),
        (.delegate(worker: "qwen-27b", prompt: "What changed in Speech in iOS 27? Start at https://developer.apple.com/documentation/updates/speech", profile: "research"), "42"),
        (.annotationUpdate(id: "note-1", reroute: "claude"), "43"),
        (.sideReroute(chatId: "sc-abc123"), "44"),
        (.noteReply(id: "note-1", text: "Why not undefined?"), "45"),
        (.noteReply(id: "note-1", text: "", image: "BASE64", imageType: "image/png"), "46"),
        (.outsideFollow(sessionId: "ce46f81f-ec40-4c7d-885d-547ef9d911b3"), "47"),
        (.outsideUnfollow(sessionId: "ce46f81f-ec40-4c7d-885d-547ef9d911b3"), "48"),
        (.outsideContinue(sessionId: "ce46f81f-ec40-4c7d-885d-547ef9d911b3"), "49"),
        (.setPermissionMode("plan"), "50"),
        (.setPermissionMode("bypassPermissions"), "51"),
        (.hello(token: "TOKEN", device: "studio", lastSeq: 0, kind: "mac"), nil),
        (.sendPlace(to: "ipad", place: .object(["file": .object(["path": .string("/home/you/proj/Lexer.swift"), "line": .number(27)])]), title: "Lexer.swift"), "52"),
        (.notes(surface: .plan(conversationId: "f35790a0-07ad-4715-9450-8b37023a3197"),
                items: [InkNote(id: "n-1", intent: .change, text: "Tests first", elements: [InkElement(id: "3", label: "Refactor the lexer")])]), "53"),
        (.sendPlace(to: "ipad", place: .object(["diagram": .object(["_0": .string("g1")])]), title: "Lexer states", write: true), "54"),
        (.placeSeen(id: "p-1"), "55"),
        (.openPlaces(places: [OpenPlace(place: .object(["file": .object(["_0": .string("/home/you/proj/Lexer.swift"), "line": .number(27)])]), title: "Lexer.swift"),
                              OpenPlace(place: .object(["diagram": .object(["_0": .string("g1")])]), title: "Lexer states")], current: 1), "56"),
        (.openPlaces(places: [], current: nil), "57"),
        (.sideTitle(chatId: "sc-abc123", title: "Why the Hub Uses Two GPUs"), "58"),
        (.diagnostic(DiagnosticReport(kind: "freeze", id: "f-1a2b", summary: "Freeze 2.9 s on the conversation", at: "2026-10-19T09:02:11Z", durationMs: 2900,
                                      build: "0.1 (1) debug", os: "iPadOS 27.2", model: "iPad16,6",
                                      context: ["place": .string("lead"), "recent": .array([.string("tab lift"), .string("drop: split right")])])), "59"),
        (.diagnostic(DiagnosticReport(kind: "crash", id: "mx-crash-1", summary: "Crash: EXC_CRASH (SIGABRT)", payload: "{\"callStackTree\":{}}")), "60"),
        (.agentsList, "61"),
        (.agentsScan, "62"),
        (.endpointsList, "63"),
        (.endpointAdd(name: "LM Studio", baseUrl: "http://127.0.0.1:1234/v1", model: "qwen3-coder-30b", apiKey: "local-key"), "64"),
        (.endpointUpdate(id: "lm-studio", model: "gemma4-26b", apiKey: .some(nil), enabled: false), "65"),
        (.endpointUpdate(id: "lm-studio", name: "LM Studio (Mac)", apiKey: "new-key"), "66"),
        (.endpointRemove(id: "lm-studio"), "67"),
        (.endpointTest(baseUrl: "http://127.0.0.1:1234/v1", apiKey: "local-key"), "68"),
        (.endpointTest(id: "lm-studio"), "69"),
        (.endpointAdd(name: "vLLM", baseUrl: "http://my-gpu-box:8000/v1", model: "qwen3-coder", enabled: false), "70"),
    ]
    let hub = try lines("client.jsonl")
    #expect(hub.count == swift.count, "hub/test/client-fixtures.test.ts and this list must change together (then `make fixtures`)")
    for (i, ((m, ref), line)) in zip(swift, hub).enumerated() {
        // set_effort null must stay an explicit null: compare without stripping for that one.
        let mine = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(m.json(ref: ref))) as! NSObject
        let theirs = try JSONSerialization.jsonObject(with: line) as! NSObject
        #expect(mine == theirs, "message \(i): \(m)")
    }
}

@Test func settingsFramesDecode() throws {
    let frames = try lines("settings.jsonl").map { try JSONDecoder().decode(ServerFrame.self, from: $0) }
    guard case .ack(let scanAck) = frames[0], let scan = scanAck.scan else { Issue.record("no scan"); return }
    #expect(scan.agents.map(\.id) == ["claude", "codex", "cursor", "gemini"])
    #expect(scan.agents.map(\.state) == [.ready, .needsSignIn, .notInstalled, .ready])
    #expect(scan.agents[0].version == "2.1.303")
    #expect(scan.agents[1].signIn?.contains("codex login") == true)
    #expect(scan.agents[3].problem != nil)
    guard case .ack(let list) = frames[1], let endpoints = list.endpoints else { Issue.record("no endpoints"); return }
    #expect(endpoints.map(\.id) == ["lm-studio", "vllm"])
    #expect(endpoints[0].hasApiKey && !endpoints[1].hasApiKey && !endpoints[1].enabled)
    guard case .ack(let added) = frames[2] else { Issue.record("no ack"); return }
    #expect(added.endpoint == endpoints[0])
    guard case .ack(let ok) = frames[4], case .ack(let refused) = frames[5] else { Issue.record("no tests"); return }
    #expect(ok.test?.summary == "Connected · 3 models found")
    #expect(refused.test?.ok == false && refused.test?.status == 401)
    #expect(refused.test?.summary == "the API key was refused: Invalid API key")
    #expect(frames[7] == .endpoints(endpoints))
    #expect(frames[8] == .endpoints([]))
    guard case .event(let e) = frames[9], case .fleet(let f) = e.body else { Issue.record("no fleet"); return }
    #expect(f.workers.allSatisfy { $0.isOpenAI && $0.fromSettings == true })
}

@MainActor
private func replay(_ file: String) throws -> DuetStore {
    let store = DuetStore()
    for line in try lines(file) {
        if case .event(let e) = try JSONDecoder().decode(ServerFrame.self, from: line) { store.apply(e) }
    }
    return store
}

@MainActor
@Test func phase1ReplayStreamsMatchFinalText() throws {
    let s = try replay("p1.jsonl")
    let ended = s.turns.filter { $0.end != nil && !$0.streamedTotal.isEmpty && $0.end?.interrupted == false }
    #expect(!ended.isEmpty)
    for t in ended { #expect(t.streamedTotal == t.finalTotal, "turn \(t.id)") }
    #expect(s.openApprovals.isEmpty, "every approval was resolved")
    #expect(s.turns.contains { $0.end?.interrupted == true }, "the interrupt test's turn is marked")
    #expect(s.session?.account?.subscription?.lowercased().contains("max") == true)
}

@MainActor
@Test func phase3ReplayHasTheWholeDialogue() throws {
    let s = try replay("p3.jsonl")
    let task = try #require(s.cards.first { $0.kind == "TASK" && $0.from == "lead" })
    let thread = s.cards.filter { $0.taskId == task.taskId }.map(\.kind)
    #expect(thread == ["TASK", "QUESTION", "ANSWER", "RESULT"])
    #expect(s.tasks[task.taskId]?.state == "done")
    #expect(s.dialogueState?.openQuestions == 0)
}

@MainActor
@Test func phase2ReplayKeepsTaskHistory() throws {
    let s = try replay("p2.jsonl")
    #expect(s.workers.contains { $0.id == "qwen-27b" && $0.loaded })
    let done = s.tasks.values.filter { $0.state == "done" }
    #expect(done.count >= 3)
    #expect(done.allSatisfy { $0.prompt != nil && $0.stats != nil }, "merged task events keep prompt and stats")
    #expect(s.tasks.values.contains { $0.state == "cancelled" })
}

@MainActor
@Test func phase5ReplayHasModelsContextAndCatalog() throws {
    let s = try replay("p5.jsonl")
    let info = try #require(s.leadInfo)
    #expect(info.models.contains { $0.value == "haiku" && $0.effortLevels.contains(.max) })
    #expect(s.catalog.contains { $0.id == "gemma4-26b" && !$0.loaded && $0.evicts.contains("qwen3.5-9b-3060") })
    let notes = s.turns.flatMap(\.items).compactMap { if case .note(_, let t) = $0 { t } else { nil } }
    #expect(notes.contains { $0.hasPrefix("Compacted by") }, "\(notes)")
    #expect(notes.contains { $0.hasPrefix("Context cleared by") })
    #expect(s.workers.contains { ($0.tokPerS ?? 0) > 0 })
}

@MainActor
@Test func conversationsReplayGroupsByTagAndResumes() throws {
    let s = try replay("p7.jsonl")
    // Two conversations; a Clear made the second; the first was resumed and is live again.
    #expect(s.conversations.count == 2, "\(s.conversations.map(\.id))")
    #expect(s.conversations.allSatisfy { !$0.isProvisional && $0.hasContent })
    #expect(s.currentConversationId == s.conversations.first?.id)
    #expect(s.leadInfo?.conversationId == s.currentConversationId)
    let first = try #require(s.conversations.first)
    #expect(first.turnIds.count >= 2, "its first turn, and the one after it was resumed")
    #expect(first.rows.contains { if case .note(_, let t) = $0 { t.hasPrefix("Resumed by") } else { false } })
    // Every lead-turn event in the recording carries a tag.
    for line in try lines("p7.jsonl") {
        guard case .event(let e) = try JSONDecoder().decode(ServerFrame.self, from: line) else { continue }
        switch e.body {
        case .user, .turnStart, .assistant, .turnEnd, .session, .context: #expect(e.conversationId != nil, "seq \(e.seq) \(e.type) is tagged")
        case .fleet, .modelCatalog: #expect(e.conversationId == nil, "seq \(e.seq) \(e.type) is hub-wide")
        default: break
        }
    }
}

@Test func terminalFramesDecode() throws {
    var kinds = Set<String>()
    for line in try lines("p5.jsonl") {
        switch try JSONDecoder().decode(ServerFrame.self, from: line) {
        case .ptyList: kinds.insert("list")
        case .ptyData(_, let d): if d.contains("PTY-42") { kinds.insert("data") }
        case .ptyExit: kinds.insert("exit")
        case .ack(let a): if a.ptyId != nil { kinds.insert("ack") }
        default: break
        }
    }
    #expect(kinds == ["list", "data", "exit", "ack"])
}

@MainActor
@Test func streamingIsThrottledThenFlushed() {
    let s = DuetStore()
    s.apply(HubEvent(seq: 1, ts: 0, body: .user(UserEvent(turn: 1, text: "count", by: "t"))))
    for i in 2...2001 { s.apply(HubEvent(seq: i, ts: 0, body: .textDelta(TextDeltaEvent(turn: 1, text: "\(i - 1)\n")))) }
    #expect(s.turns[0].streaming.isEmpty, "2,000 deltas cause no publish until the 15 Hz tick")
    s.flushStreaming()
    #expect(s.turns[0].streaming.split(separator: "\n").count == 2000)
    s.apply(HubEvent(seq: 2002, ts: 0, body: .assistant(AssistantEvent(turn: 1, text: s.turns[0].streamedTotal, toolUses: []))))
    #expect(s.turns[0].streaming.isEmpty && s.turns[0].finalTotal == s.turns[0].streamedTotal)
}
