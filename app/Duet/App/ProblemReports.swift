import CryptoKit
import DuetKit
import Foundation
import MetricKit
import OSLog
import Synchronization
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// What went wrong on this device, sent to the hub to keep (hub/src/diagnostics.ts, docs/diagnostics.md):
/// - **Freezes**: a watch thread notices when the main thread hasn't answered for a second, and reports how long it
///   lasted, what was on screen and the last few things you did.
/// - **Crashes, hangs, CPU and disk overuse, slow launches**: the system's own reports (MetricKit), with their call
///   stacks, delivered the next time Duet runs.
/// - **Closing unexpectedly**: Duet ended while it was open (a crash, the system's watchdog, memory), noticed at the
///   next launch, with what it was doing then.
///
/// Reports wait in an outbox (Application Support) until the hub acks them, so one from a crash goes the next time Duet
/// connects. Nothing here touches the main thread's work except a tiny ping, and the trail holds only names of places
/// and actions, never what you typed.
final class ProblemReports: Sendable {
    /// Duet's report (to the hub); MetricKit's own is `MetricKit.DiagnosticReport`.
    typealias Report = DuetKit.DiagnosticReport

    static let shared = ProblemReports()

    /// How long the main thread must be stuck before it counts as a freeze.
    static let freezeThreshold: TimeInterval = 1.0

    private struct State {
        var trail: [(Date, String)] = []
        var trailChanged = false
        var screen = ""
        var active = true
        var lastPong = Date()
        var frozenSince: Date?
        var frozenScreen = ""
        var frozenTrail: [String] = []
    }

    /// The previous run, saved as it goes, to report what it was doing if it never closed cleanly.
    private struct LastRun: Codable {
        var started: Date
        var saved: Date
        var build: String
        var screen: String
        var trail: [String]
        /// Closed normally, or went to the background (iOS may end it there; that's not a problem).
        var clean: Bool
        var frozenSince: Date?
    }

    private let state = Mutex(State())
    private let started = Date()
    private let log = Logger(subsystem: AppIdentity.bundleID, category: "problems")
    private let dir: URL
    private let outbox: URL
    private let lastRunFile: URL
    private let metrics = Mutex<MetricManager?>(nil)
    private let launched = Mutex(false)

    let build: String
    let model: String
    let os: String

    private init() {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        dir = base
        outbox = base.appendingPathComponent("outbox", isDirectory: true)
        lastRunFile = base.appendingPathComponent("last-run.json")
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        let flavour = "debug"
        #else
        let flavour = "release"
        #endif
        build = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) \(flavour)"
        #if os(macOS)
        model = Self.sysctl("hw.model")
        let platform = "macOS"
        #else
        model = Self.sysctl("hw.machine")
        let platform = model.hasPrefix("iPad") ? "iPadOS" : "iOS"
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        os = "\(platform) \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: what you were doing

    /// One step of the trail ("show lead", "tab lift", "ink"). Cheap; any thread.
    static func note(_ what: String) {
        shared.state.withLock { s in
            s.trail.append((Date(), what))
            if s.trail.count > 30 { s.trail.removeFirst(s.trail.count - 30) }
            s.trailChanged = true
        }
    }

    /// What's in front now, for a report's one line.
    static func screen(_ what: String) {
        shared.state.withLock { s in
            if s.screen != what { s.screen = what; s.trailChanged = true }
        }
    }

    // MARK: start

    /// Starts watching, once: reports how the last run ended, takes the system's reports, and watches for freezes.
    func start() {
        let first = launched.withLock { l in defer { l = true }; return !l }
        guard first else { return }
        reportLastRun()
        saveLastRun(clean: false)
        observeLifecycle()
        startMetricKit()
        startWatch()
    }

    private func reportLastRun() {
        guard let data = try? Data(contentsOf: lastRunFile), let last = try? JSONDecoder().decode(LastRun.self, from: data), !last.clean else { return }
        var summary = "Doublet closed unexpectedly while open"
        if let since = last.frozenSince {
            summary += String(format: ", %.0f s into a freeze", max(1, last.saved.timeIntervalSince(since)))
        }
        if !last.screen.isEmpty { summary += " on \(last.screen)" }
        enqueue(Report(kind: "exit", id: "exit-\(Int(last.started.timeIntervalSince1970))", summary: summary,
                                 at: Self.iso(last.saved), build: last.build, os: os, model: model,
                                 context: ["screen": .string(last.screen), "recent": .array(last.trail.map { .string($0) }),
                                           "started": .string(Self.iso(last.started)),
                                           "note": .string("Also ends this way: stopping Doublet from Xcode, or a crash the system reports separately.")]))
    }

    private func saveLastRun(clean: Bool) {
        let (screen, trail, frozen) = state.withLock { s in
            s.trailChanged = false
            return (s.screen, s.trail.map { Self.line($0) }, s.frozenSince)
        }
        let run = LastRun(started: started, saved: Date(), build: build, screen: screen, trail: trail, clean: clean, frozenSince: frozen)
        if let data = try? JSONEncoder().encode(run) { try? data.write(to: lastRunFile, options: .atomic) }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        #if os(iOS)
        // In the background iOS may end Duet at any time; that isn't a problem to report.
        _ = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [self] _ in
            state.withLock { $0.active = false }
            Self.note("background")
            saveLastRun(clean: true)
        }
        _ = center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [self] _ in
            state.withLock { $0.active = true; $0.lastPong = Date() }
            Self.note("foreground")
            saveLastRun(clean: false)
        }
        #else
        _ = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [self] _ in
            saveLastRun(clean: true)
        }
        #endif
        // Quit by the system (an update, a reinstall, logging out): a clean end too.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        term.setEventHandler { [self] in
            saveLastRun(clean: true)
            // End the way SIGTERM would have: not exit(), which runs the process's teardown on this thread while the
            // main thread is still going.
            signal(SIGTERM, SIG_DFL)
            raise(SIGTERM)
        }
        term.resume()
        termSource.withLock { $0 = term }
    }
    private let termSource = Mutex<DispatchSourceSignal?>(nil)

    // MARK: the system's reports

    private func startMetricKit() {
        let manager = MetricManager()
        metrics.withLock { $0 = manager }
        Task.detached(priority: .utility) { [self] in
            for await report in manager.diagnosticReports { take(report) }
        }
    }

    private func take(_ report: MetricKit.DiagnosticReport) {
        let payload = (try? JSONEncoder().encode(report)).map { String(decoding: $0, as: UTF8.self) }
        let digest = SHA256.hash(data: Data((payload ?? "\(report.timeRange)").utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let (kind, summary, ms) = Self.describe(report.result)
        let env = report.environment
        enqueue(Report(kind: kind, id: "mx-\(kind)-\(digest)", summary: summary, at: Self.iso(report.timeRange.end), durationMs: ms,
                                 build: "\(env.applicationVersion) (\(env.applicationBuildVersion))", os: "\(env.osVersion.platform) \(env.osVersion.number)",
                                 model: env.deviceType, context: ["from": .string("MetricKit"), "lowPower": .bool(env.lowPowerModeEnabled)],
                                 payload: payload.map { String($0.prefix(500_000)) }))
    }

    static func describe(_ result: DiagnosticResult) -> (kind: String, summary: String, ms: Double?) {
        func seconds(_ m: Measurement<UnitDuration>) -> Double { m.converted(to: .seconds).value }
        switch result {
        case .crash(let c):
            var parts: [String] = []
            if let cat = c.terminationCategory { parts.append(cat.description) }
            if let t = c.exceptionType { parts.append("exception \(t)") }
            if let s = c.signal { parts.append(signalName(s)) }
            if let r = c.terminationReason { parts.append(r.description) }
            if let e = c.exceptionReason { parts.append("\(e.exceptionName): \(e.composedMessage)") }
            return ("crash", "Crash: " + (parts.isEmpty ? "no details" : parts.joined(separator: " · ")).prefix(240), nil)
        case .hang(let h):
            let s = seconds(h.hangDuration)
            return ("hang", String(format: "Hang %.1f s (the system's report)", s), s * 1000)
        case .cpuException(let c):
            return ("cpu", String(format: "Too much CPU: %.0f s over %.0f s", seconds(c.totalCPUTime), seconds(c.totalSampledTime)), nil)
        case .diskWriteException(let d):
            return ("disk", String(format: "Too many disk writes: %.0f MB", d.totalBytesWritten.converted(to: .megabytes).value), nil)
        case .appLaunch(let l):
            let s = seconds(l.launchDuration)
            return ("launch", String(format: "Slow launch: %.1f s", s), s * 1000)
        case .memoryException:
            return ("crash", "Ended by the system: over its memory limit", nil)
        @unknown default:
            return ("crash", "A report of a kind this build doesn't know", nil)
        }
    }

    private static func signalName(_ s: Int) -> String {
        switch Int32(s) {
        case SIGABRT: "SIGABRT"
        case SIGSEGV: "SIGSEGV"
        case SIGBUS: "SIGBUS"
        case SIGILL: "SIGILL"
        case SIGTRAP: "SIGTRAP"
        case SIGKILL: "SIGKILL"
        default: "signal \(s)"
        }
    }

    // MARK: freezes

    private func startWatch() {
        let thread = Thread { [self] in
            var last = Date()
            var sinceSave: TimeInterval = 0
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                let now = Date()
                // The whole process was stopped (the background, a debugger): that's not the main thread stuck.
                let stopped = now.timeIntervalSince(last) > 1.0
                last = now
                DispatchQueue.main.async { [self] in state.withLock { $0.lastPong = Date() } }
                tick(now, stopped: stopped)
                sinceSave += 0.25
                if sinceSave >= 5 {
                    sinceSave = 0
                    if state.withLock({ $0.trailChanged && $0.active }) { saveLastRun(clean: false) }
                }
            }
        }
        thread.name = "Doublet freeze watch"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func tick(_ now: Date, stopped: Bool) {
        enum Step { case none, began, ended(Date, String, [String]) }
        let step: Step = state.withLock { s in
            if stopped || !s.active {
                s.lastPong = now
                s.frozenSince = nil
                return .none
            }
            let lag = now.timeIntervalSince(s.lastPong)
            if s.frozenSince == nil, lag >= Self.freezeThreshold {
                s.frozenSince = s.lastPong
                s.frozenScreen = s.screen
                s.frozenTrail = s.trail.map { Self.line($0) }
                return .began
            }
            if let since = s.frozenSince, lag < 0.5 {
                s.frozenSince = nil
                return .ended(since, s.frozenScreen, s.frozenTrail)
            }
            return .none
        }
        switch step {
        case .none: break
        case .began:
            // If the system ends Duet during it, the next launch says so.
            saveLastRun(clean: false)
        case .ended(let since, let screen, let trail):
            let ms = now.timeIntervalSince(since) * 1000
            // Launch freezes (loading the conversation, opening the restored pages) read differently from ones in use.
            let afterLaunch = since.timeIntervalSince(started)
            log.notice("freeze \(Int(ms)) ms on \(screen, privacy: .public), \(Int(afterLaunch)) s after launch")
            var context: [String: JSONValue] = ["screen": .string(screen), "recent": .array(trail.map { .string($0) }),
                                                "sinceLaunch": .number((afterLaunch * 10).rounded() / 10)]
            if let label = Self.testLabel { context["test"] = .string(label) }
            enqueue(Report(kind: "freeze", id: "fz-\(Int(since.timeIntervalSince1970 * 1000))",
                           summary: String(format: "Freeze %.1f s", ms / 1000) + (afterLaunch < 20 ? " at launch" : "") + (screen.isEmpty ? "" : " on \(screen)"),
                           at: Self.iso(since), durationMs: ms, build: build, os: os, model: model, context: context))
            saveLastRun(clean: false)
        }
    }

    // MARK: the outbox

    func enqueue(_ r: Report) {
        guard let data = try? JSONEncoder().encode(r) else { return }
        try? data.write(to: outbox.appendingPathComponent("\(r.id).json"), options: .atomic)
        log.notice("report \(r.kind, privacy: .public): \(r.summary, privacy: .public)")
        if let ready = onReport.withLock({ $0 }) { DispatchQueue.main.async { ready() } }
    }

    /// Called (on the main thread) when a report is waiting: the app sends it now if it's connected.
    func whenReported(_ ready: @escaping @MainActor @Sendable () -> Void) {
        onReport.withLock { $0 = ready }
    }
    private let onReport = Mutex<(@MainActor @Sendable () -> Void)?>(nil)

    /// The reports waiting to go, oldest first.
    func pending() -> [Report] {
        let files = (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
            .compactMap { try? JSONDecoder().decode(Report.self, from: Data(contentsOf: $0)) }
    }

    /// Sends what's waiting; each leaves the outbox once the hub has it. Stops at the first that doesn't go (offline,
    /// or a hub too old to know reports: they wait for the next connection). One the hub refuses as malformed goes.
    @MainActor func flush(_ send: @MainActor (ClientMessage) async throws -> Ack) async {
        for r in pending() {
            let file = outbox.appendingPathComponent("\(r.id).json")
            do {
                _ = try await send(.diagnostic(r))
                try? FileManager.default.removeItem(at: file)
            } catch let e as HubError where !e.message.contains("unknown message type") && e.message != "not connected" {
                log.notice("hub refused report \(r.id, privacy: .public): \(e.message, privacy: .public)")
                try? FileManager.default.removeItem(at: file)
            } catch {
                return
            }
        }
    }

    // MARK: helpers

    private static func line(_ step: (Date, String)) -> String {
        let f = Date.ISO8601FormatStyle(includingFractionalSeconds: false).time(includingFractionalSeconds: false)
        return "\(step.0.formatted(f)) \(step.1)"
    }

    static func iso(_ d: Date) -> String { d.formatted(.iso8601) }

    /// Test runs name themselves (DUET_TEST_LABEL), so their reports can be told apart.
    #if DEBUG
    static let testLabel = ProcessInfo.processInfo.environment["DUET_TEST_LABEL"]
    #else
    static let testLabel: String? = nil
    #endif

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

private extension URL {
    var modificationDate: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}
