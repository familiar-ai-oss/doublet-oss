import XCTest

/// Launching Duet for a pressure test, and talking to the stand-in hub (hub/tools/firehose.ts).
///
/// Settings come from the test runner's environment: `xcodebuild` passes each `TEST_RUNNER_X` as `X`.
/// - `DUET_URL`: the hub (ws://127.0.0.1:7898/ws for the firehose). Without one, Duet runs its demo conversation.
/// - `DUET_TOKEN`, `DUET_DEVICE`: for a real hub (the sandbox); the firehose takes any token.
/// - `DUET_MONKEY_SECONDS`, `DUET_MONKEY_SEED`: how long the random-input test runs, and its seed (to replay one).
/// - `TSAN_OPTIONS`, `ASAN_OPTIONS`, `UBSAN_OPTIONS`, `MTC_*`: passed on to the app, for the sanitizer schemes.
enum Harness {
    static let env = ProcessInfo.processInfo.environment

    static var hubURL: String? { env["DUET_URL"].flatMap { $0.isEmpty ? nil : $0 } }

    /// The test running now (set in each test's setUp), passed to Duet so its reports say which test they came from.
    nonisolated(unsafe) static var currentTest = ""

    /// The firehose's HTTP side: ws://host:port/ws → http://host:port.
    static var firehose: URL? {
        guard let s = hubURL, var c = URLComponents(string: s), s.contains("7898") || env["DUET_FIREHOSE"] == "1" else { return nil }
        c.scheme = c.scheme == "wss" ? "https" : "http"
        c.path = ""
        return c.url
    }

    /// Duet, launched fresh: against the hub when one is given, else the demo. `dest`: places to open (DUET_DEST).
    static func launch(dest: String? = "lead", demo: Bool = false, extra: [String: String] = [:]) -> XCUIApplication {
        // Landscape, as a 13-inch iPad usually sits (the sidebar shows), whatever an earlier test (the random one
        // rotates) left.
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        var e: [String: String] = [:]
        if let url = hubURL, !demo {
            e["DUET_URL"] = url
            e["DUET_DEVICE"] = env["DUET_DEVICE"] ?? "ipad"
            e["DUET_TOKEN"] = env["DUET_TOKEN"] ?? "firehose"
        } else {
            e["DUET_DEMO"] = "1"
            e["DUET_TOKEN"] = "demo"
        }
        // Every launch opens a fresh layout (DUET_DEST), so a test never inherits what an earlier one left open.
        if let dest { e["DUET_DEST"] = dest }
        e["DUET_TEST_LABEL"] = currentTest
        for (k, v) in env where ["TSAN_OPTIONS", "ASAN_OPTIONS", "UBSAN_OPTIONS", "DUET_SPEED_OFF"].contains(k) || k.hasPrefix("MTC_") { e[k] = v }
        e.merge(extra) { $1 }
        app.launchEnvironment = e
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "Duet didn't come up")
        return app
    }

    /// GET on the firehose (`/stream?chars=…`, `/burst?events=…`, `/stop`, `/health`); nil without one.
    @discardableResult
    static func call(_ path: String) -> [String: Any]? {
        guard let base = firehose, let url = URL(string: path, relativeTo: base) else { return nil }
        let done = XCTestExpectation(description: path)
        nonisolated(unsafe) var out: [String: Any]?
        URLSession.shared.dataTask(with: url) { data, _, _ in
            out = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done.fulfill()
        }.resume()
        _ = XCTWaiter.wait(for: [done], timeout: 10)
        return out
    }

    /// The crash and freeze reports Duet sent the firehose since a moment (an exit report from an earlier run's end
    /// arrives at the start of the next, so only ones received after `since` count).
    static func reports(since: Date) -> [[String: Any]] {
        guard let base = firehose, let url = URL(string: "/diagnostics", relativeTo: base) else { return [] }
        let done = XCTestExpectation(description: "reports")
        nonisolated(unsafe) var out: [[String: Any]] = []
        URLSession.shared.dataTask(with: url) { data, _, _ in
            out = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            done.fulfill()
        }.resume()
        _ = XCTWaiter.wait(for: [done], timeout: 10)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return out.filter { ($0["received"] as? String).flatMap(f.date(from:)).map { $0 >= since } ?? false }
    }

    /// Whether Claude's side is still streaming (the firehose's turn).
    static var streaming: Bool { (call("/health")?["streaming"] as? Bool) ?? false }
}

/// A small, seedable random source, so a failing random run can be replayed exactly.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
