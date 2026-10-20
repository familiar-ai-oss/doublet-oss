import DuetKit
import Foundation
import FoundationModels
import OSLog
#if os(iOS)
import UIKit
#endif

/// Apple Intelligence on this device. It runs the hub's tasks for this device's Apple worker on the on-device model,
/// and does the app's own small jobs (one-line summaries, routing suggestions) without spending Claude's time.
@MainActor @Observable
final class AppleIntelligence {
    private let model = SystemLanguageModel.default
    /// Transforming text the user supplied (logs, outputs): Apple's guardrails for exactly that.
    private let transformer = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var routes: [String: Route] = [:]
    private let log = Logger(subsystem: AppIdentity.bundleID, category: "apple")

    var isAvailable: Bool { model.isAvailable }
    /// A hub task is running on the model now (the app's own small jobs wait).
    var isBusy: Bool { !running.isEmpty }

    /// What the hub is told about this device's model.
    var status: AppleStatus { Self.status(of: model, platform: Self.platform) }

    /// The same, read off the main thread: the first read of the model's context size waits on the model's service
    /// (about 20 ms on a Mac, 900 ms in the simulator), and it comes as Duet connects (DUET_SPEED_OFF=apple reads it
    /// on the main thread, as before).
    func readStatus() async -> AppleStatus {
        guard SpeedSwitches.on("apple") else { return status }
        let model = model, platform = Self.platform
        return await Task.detached(priority: .userInitiated) { Self.status(of: model, platform: platform) }.value
    }

    private static var platform: String {
        #if os(macOS)
        "mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }

    nonisolated private static func status(of model: SystemLanguageModel, platform: String) -> AppleStatus {
        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif
        switch model.availability {
        case .available:
            let all: [(String, LanguageModelCapabilities.Capability)] = [("reasoning", .reasoning), ("vision", .vision), ("guidedGeneration", .guidedGeneration), ("toolCalling", .toolCalling)]
            return AppleStatus(available: true, contextSize: model.contextSize, capabilities: all.filter { model.capabilities.contains($0.1) }.map(\.0),
                               platform: platform, simulator: simulator, variant: model.variant.displayName)
        case .unavailable(let reason):
            return AppleStatus(available: false, reason: "\(reason)", platform: platform, simulator: simulator)
        }
    }

    /// Calls `changed` whenever the model's availability changes (Apple Intelligence turned on, the model downloaded).
    func watchAvailability(_ changed: @escaping @MainActor () -> Void) {
        withObservationTracking { _ = model.availability } onChange: { [weak self] in
            Task { @MainActor in
                changed()
                self?.watchAvailability(changed)
            }
        }
    }

    // MARK: the hub's tasks

    /// Runs a task the hub sent this device; its progress and outcome go back through `send`.
    func run(_ t: AppleTask, send: @escaping @MainActor (ClientMessage) -> Void) {
        running[t.taskId]?.cancel()
        running[t.taskId] = Task { [weak self] in
            guard let self else { return }
            let started = Date()
            let meter = Meter()
            do {
                let answer = try await self.perform(t, meter: meter) { send(.appleProgress(taskId: t.taskId, text: $0)) }
                send(.appleDone(taskId: t.taskId, ok: true, result: answer, error: nil, stats: meter.stats(since: started)))
            } catch is CancellationError {
                // Cancelled by the hub, which already knows.
            } catch {
                self.log.error("task \(t.taskId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                // The passes it made before failing still count.
                send(.appleDone(taskId: t.taskId, ok: false, result: nil, error: Self.describe(error), stats: meter.stats(since: started)))
            }
            self.running[t.taskId] = nil
        }
    }

    func cancel(_ taskId: String) {
        running.removeValue(forKey: taskId)?.cancel()
    }

    private static let instructions = "You are a careful assistant inside Doublet, a coding team's app. Do exactly the task you're given, using only the material provided. Be concise and factual; don't invent details. If the material doesn't contain what's asked, say so."
    /// The most a pass writes: notes on a part, and the answer. Their room in the context is kept free, as the
    /// context holds what the model writes as well as what it reads.
    private static let noteTokens = 200, answerTokens = 800
    /// Room for the prompt format's own tokens, and for counting a little short.
    private static let slack = 120

    /// One pass when the material fits the context with the answer; otherwise notes on each part (and on groups of
    /// notes, if there are too many), then the answer from the notes.
    private func perform(_ t: AppleTask, meter: Meter, progress: @escaping @MainActor (String) -> Void) async throws -> String {
        guard model.isAvailable else { throw AppleError.unavailable(status.reason ?? "unavailable") }
        // What the prompt and the model's writing share: the context, less the instructions.
        let room = model.contextSize - (try await model.tokenCount(for: Instructions(Self.instructions))) - Self.slack
        let material = (t.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if material.isEmpty {
            return try await answer(t.prompt, cap: Self.answerTokens, temperature: t.temperature, meter: meter, transform: false)
        }
        let whole = "\(t.prompt)\n\n---\n\(material)"
        if try await model.tokenCount(for: whole) <= room - Self.answerTokens {
            return try await answer(whole, cap: Self.answerTokens, temperature: t.temperature, meter: meter, transform: true)
        }
        var text = material, label = "part"
        while true {
            let partRoom = room - Self.noteTokens - (try await model.tokenCount(for: Self.notesPrompt(t.prompt, label, 1, 1, "")))
            guard partRoom > 400 else { throw AppleError.tooLong("the task itself nearly fills the \(model.contextSize)-token context") }
            let notes = try await readInParts(text, task: t.prompt, label: label, room: partRoom, temperature: t.temperature, meter: meter, progress: progress)
            let final = "\(t.prompt)\n\nThe material was too long to read at once, so here are notes taken from each part of it, in order:\n\n\(notes)"
            if try await model.tokenCount(for: final) <= room - Self.answerTokens {
                progress("Writing the answer from the notes")
                return try await answer(final, cap: Self.answerTokens, temperature: t.temperature, meter: meter, transform: true)
            }
            // Too many notes to answer from: take notes on the notes. Each round must shorten them, or it would never end.
            guard notes.count < text.count * 3 / 4 else { throw AppleError.tooLong("the notes on it are as long as the text") }
            text = notes
            label = "group of notes"
        }
    }

    private static func notesPrompt(_ task: String, _ label: String, _ i: Int, _ n: Int, _ part: String) -> String {
        """
        Task: \(task)

        Below is \(label) \(i) of \(n) of the material. Write brief notes on only what matters for the task, at most \
        8 short lines. If nothing in it matters, reply with exactly: NOTHING

        \(part)
        """
    }

    private func readInParts(_ text: String, task: String, label: String, room: Int, temperature: Double?, meter: Meter,
                             progress: @MainActor (String) -> Void) async throws -> String {
        let parts = try await split(text, budget: room)
        var notes: [String] = []
        for (i, part) in parts.enumerated() {
            let n = try await answer(Self.notesPrompt(task, label, i + 1, parts.count, part), cap: Self.noteTokens, temperature: temperature, meter: meter, transform: true)
            let useful = n.filter(\.isLetter).uppercased() != "NOTHING" && !n.isEmpty
            if useful { notes.append("Part \(i + 1):\n\(n)") }
            progress("Read \(label) \(i + 1) of \(parts.count): " + (useful ? Self.gist(n) : "nothing relevant"))
        }
        return notes.isEmpty ? "(no part had anything relevant to the task)" : notes.joined(separator: "\n\n")
    }

    /// The first line of notes that says something (not a heading like "**Summary:**"), without markdown.
    private static func gist(_ notes: String) -> String {
        let lines = notes.split(separator: "\n").map { line in
            line.filter { !"*#`".contains($0) }.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-•")))
        }
        return String((lines.first { !$0.isEmpty && !$0.hasSuffix(":") } ?? lines.first ?? "").prefix(90))
    }

    /// Line-aligned parts of `text`, each as long as fits in `budget` tokens, so there are as few passes as can be.
    private func split(_ text: String, budget: Int) async throws -> [String] {
        // Characters per token for this text (logs and code run short), to guess a part's length before counting it.
        let ratio = Double(text.count) / Double(max(1, (try? await model.tokenCount(for: text)) ?? text.count / 3))
        var parts: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            try Task.checkCancellation()
            var length = min(rest.count, Int(Double(budget) * ratio * 0.95))
            while true {
                var end = rest.index(rest.startIndex, offsetBy: length)
                // End after a line break in the part's second half, if there is one.
                if end < rest.endIndex, let nl = rest[rest.index(rest.startIndex, offsetBy: length / 2)..<end].lastIndex(of: "\n") {
                    end = rest.index(after: nl)
                }
                let part = String(rest[..<end])
                let tokens = try await model.tokenCount(for: part)
                if tokens <= budget || length <= 200 {
                    parts.append(part)
                    rest = rest[end...]
                    break
                }
                // Denser than the guess: shorten it in proportion.
                length = max(200, Int(Double(length) * Double(budget) / Double(tokens) * 0.95))
            }
        }
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// One pass of the model, writing at most `cap` tokens. It streams so that the time spent writing (from the
    /// first token) is known apart from the time spent reading the prompt.
    private func answer(_ prompt: String, cap: Int, temperature: Double?, meter: Meter, transform: Bool) async throws -> String {
        try Task.checkCancellation()
        let session = LanguageModelSession(model: transform ? transformer : model, instructions: Self.instructions)
        let started = Date()
        var first: Date?
        var text = ""
        for try await snapshot in session.streamResponse(to: prompt, options: GenerationOptions(temperature: temperature, maximumResponseTokens: cap)) {
            if first == nil { first = Date() }
            text = snapshot.content
        }
        if let first {
            if meter.firstTokenMs == nil { meter.firstTokenMs = first.timeIntervalSince(started) * 1000 }
            meter.genMs += Date().timeIntervalSince(first) * 1000
        }
        meter.parts += 1
        meter.input += session.usage.input.totalTokenCount
        meter.output += session.usage.output.totalTokenCount
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a task has used: passes of the model, tokens read and written, and the time spent writing.
    private final class Meter {
        var parts = 0, input = 0, output = 0
        var genMs = 0.0
        var firstTokenMs: Double?
        func stats(since started: Date) -> AppleStats {
            AppleStats(inputTokens: input, outputTokens: output, wallMs: Date().timeIntervalSince(started) * 1000, firstTokenMs: firstTokenMs,
                       parts: parts, genMs: genMs > 0 ? genMs : nil)
        }
    }

    enum AppleError: LocalizedError {
        case unavailable(String)
        case tooLong(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let r): "Apple Intelligence isn't available on this device (\(r))"
            case .tooLong(let r): "Too long for the on-device model: \(r)"
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? LanguageModelError {
            switch e {
            case .contextSizeExceeded(let c): return "The text was too long for the on-device model (\(c.tokenCount) tokens; it takes \(c.contextSize))"
            case .guardrailViolation: return "Apple's safety guardrails stopped this request"
            case .refusal: return "The on-device model declined this request"
            case .unsupportedLanguageOrLocale: return "The on-device model doesn't support this language"
            case .rateLimited: return "The on-device model is busy (rate limited); try again shortly"
            case .timeout: return "The on-device model took too long"
            default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: the app's own small jobs

    /// While true, the app's own small jobs wait: what you're saying or writing gets the model first.
    @ObservationIgnored var holdBackground: () -> Bool = { false }

    /// Waits until the model is free for one of the app's own jobs (a hub task or dictation has it), at most `timeout`.
    private func free(within timeout: Duration = .seconds(20)) async -> Bool {
        let until = ContinuousClock.now + timeout
        while isBusy || holdBackground() {
            guard ContinuousClock.now < until, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return true
    }

    /// One request, again once if the OS is rate-limiting this app (it does when Duet isn't on screen).
    private func respond(_ session: LanguageModelSession, to input: String, maxTokens: Int) async -> String? {
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens)
        do {
            return try await session.respond(to: input, options: options).content
        } catch {
            guard "\(error)".contains("rateLimited") else { return nil }
            try? await Task.sleep(for: .seconds(5))
            return try? await session.respond(to: input, options: options).content
        }
    }

    // Lines made on this device, kept across launches (keyed by a digest of their text), so they're there at once.
    private static let savedKey = "onDeviceLines"
    @ObservationIgnored private lazy var saved: [String: String] = UserDefaults.standard.dictionary(forKey: Self.savedKey) as? [String: String] ?? [:]

    private func keep(_ key: String, _ line: String) {
        saved[key] = line
        if saved.count > 400 { for k in saved.keys.shuffled().prefix(150) { saved[k] = nil } }
        UserDefaults.standard.set(saved, forKey: Self.savedKey)
    }

    /// A line already made for this text, if any (no waiting).
    func cachedLine(_ text: String) -> String? { saved[OnDeviceText.digest(text)] }

    /// A one-line summary of a long text, made on this device once (nil when unavailable, or for short text). It's
    /// about what the text says, not Claude's narration on the way to it.
    func oneLine(_ text: String) async -> String? {
        let key = OnDeviceText.digest(text)
        if let s = saved[key] { return s }
        guard model.isAvailable, text.count > 160, await free() else { return nil }
        let input = await fitting(OnDeviceText.withoutNarration(text).prefix(6000))
        let session = LanguageModelSession(model: transformer, instructions: "Summarize text as one plain sentence of at most 14 words for a status line. No preamble, no quotes.")
        guard let raw = await respond(session, to: input, maxTokens: 60), let line = OnDeviceText.line(raw) else { return nil }
        keep(key, line)
        return line
    }

    /// What a command's output says, in one line, and whether the on-device model wrote it (else it was read from the
    /// output's own format: a test runner's totals, a compiler's errors). Nil for short or unremarkable output.
    func toolLine(_ output: String) async -> (line: String, onDevice: Bool)? {
        if let v = ToolOutput.verdict(output) { return (v, false) }
        let key = "tool-" + OnDeviceText.digest(output)
        if let s = saved[key] { return (s, true) }
        guard model.isAvailable, output.count > 600, await free() else { return nil }
        let input = await fitting(Substring(ToolOutput.excerpt(output)))
        let session = LanguageModelSession(model: transformer, instructions: """
        You read a command's output in a developer's terminal. In one line of at most 16 words, say what it shows: what         failed and where (file, test or step), or that it succeeded. Use names exactly as they appear. No preamble, no quotes.
        """)
        guard let raw = await respond(session, to: input, maxTokens: 50), let line = OnDeviceText.line(raw, maxWords: 18) else { return nil }
        keep(key, line)
        return (line, true)
    }

    /// The text cut to what fits the model's context, leaving room for the instructions and the answer.
    private func fitting(_ text: Substring) async -> String {
        var input = String(text)
        if let n = try? await model.tokenCount(for: input), n > model.contextSize - 400 {
            input = String(input.prefix(Int(Double(input.count) * Double(model.contextSize - 400) / Double(n))))
        }
        return input
    }

    /// What kind of request a message is, for suggesting where to send it.
    @Generable
    struct Route: Equatable {
        @Guide(description: "What kind of request this is")
        var kind: Kind
        @Guide(description: "Why, in at most six words")
        var reason: String

        @Generable
        enum Kind: Equatable {
            /// Planning, design, trade-offs, review, debugging, explaining, questions.
            case thinking
            /// A self-contained programming job: write tests, implement or refactor code.
            case codingTask
            /// A tiny mechanical change: rename, fix a typo, change a constant.
            case smallEdit
            /// Summarize, extract from or classify text.
            case textWork
        }
    }

    /// Names a conversation the way a sidebar lists chats (nil when the model is unavailable, or named badly). Plain
    /// text output, so the guardrails for transforming the user's own text apply.
    func title(prompt: String, reply: String?) async -> String? {
        guard model.isAvailable, await free() else { return nil }
        let session = LanguageModelSession(model: transformer, instructions: """
        Name a conversation between a developer and a coding assistant from its first request and reply, the way a \
        sidebar lists chats: three to six words in Title Case saying what it is about. Name the subject, not the act \
        of asking. Answer with the name only: no quotes, no punctuation at the end.
        """)
        var input = "Request:\n\(prompt.prefix(1500))"
        if let reply, !reply.isEmpty { input += "\n\nReply:\n\(OnDeviceText.withoutNarration(reply).prefix(1500))" }
        guard let raw = await respond(session, to: input, maxTokens: 24) else { return nil }
        return OnDeviceText.title(raw)
    }

    func route(_ text: String) async -> Route? {
        if let r = routes[text] { return r }
        guard model.isAvailable, await free(within: .seconds(2)) else { return nil }
        let session = LanguageModelSession(model: model, instructions: """
        Classify a request sent to a coding team. thinking: planning, design, trade-offs, reviewing or checking work, debugging, \
        explaining, questions. codingTask: a self-contained programming job such as writing tests or implementing or refactoring \
        code. smallEdit: a tiny mechanical change such as renaming a variable, fixing a typo or changing a constant. textWork: \
        summarizing, extracting from or classifying text.
        """)
        guard let r = try? await session.respond(to: text, generating: Route.self, options: GenerationOptions(temperature: 0)) else { return nil }
        routes[text] = r.content
        return r.content
    }
}
