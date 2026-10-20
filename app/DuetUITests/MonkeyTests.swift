import XCTest

/// Random input for minutes at a time: taps on whatever is on screen, taps anywhere, scrolls, long presses, tab lifts
/// dragged anywhere, typing, rotation and trips to the background. It fails when Duet crashes, or when Duet's own
/// freeze watch (ProblemReports) reports a freeze longer than DUET_MONKEY_MAX_FREEZE seconds (3 by default): with the
/// firehose as the hub, the test reads those reports back from it. Steps that took XCUITest over two seconds are
/// listed too, but they aren't freezes: XCUITest snapshots the whole screen before each, which is slow on its own.
///
/// The trail of steps is attached to the result. To replay a run, give its seed: TEST_RUNNER_DUET_MONKEY_SEED=<seed>.
final class MonkeyTests: XCTestCase {
    override func setUp() {
        Harness.currentTest = name
        continueAfterFailure = false
    }

    @MainActor
    func testRandomInput() throws {
        let seconds = Double(Harness.env["DUET_MONKEY_SECONDS"] ?? "") ?? 180
        let seed = UInt64(Harness.env["DUET_MONKEY_SEED"] ?? "") ?? UInt64(Date().timeIntervalSince1970)
        var rng = SeededRandom(seed: seed)
        let app = Harness.launch()
        // A reply streaming the whole time, when the firehose is the hub.
        Harness.call("/stream?chars=200000&rate=40&tools=20")

        let began = Date()
        var trail: [String] = ["seed \(seed)"]
        var slow: [String] = []
        let deadline = Date().addingTimeInterval(seconds)
        var step = 0
        defer {
            Harness.call("/stop")
            let report = trail.joined(separator: "\n") + (slow.isEmpty ? "" : "\n\nSlow steps:\n" + slow.joined(separator: "\n"))
            let a = XCTAttachment(string: report)
            a.name = "monkey trail (seed \(seed))"
            a.lifetime = .keepAlways
            add(a)
        }

        while Date() < deadline {
            step += 1
            let started = Date()
            let what = act(app, &rng, step: step)
            let took = Date().timeIntervalSince(started)
            let line = String(format: "%4d %5.2fs %@", step, took, what)
            trail.append(line)
            if took > 2 { slow.append(line) }

            switch app.state {
            case .runningForeground: break
            case .runningBackground, .runningBackgroundSuspended:
                // A link opened elsewhere (Safari), or the step went to the background on purpose.
                app.activate()
                trail.append("     back to Duet")
            default:
                XCTFail("Duet stopped (\(app.state.rawValue)) after step \(step): \(what). Seed \(seed).\n" + trail.suffix(15).joined(separator: "\n"))
                return
            }
        }
        // Freezes Duet reported while this ran (the firehose keeps them).
        let maxFreeze = Double(Harness.env["DUET_MONKEY_MAX_FREEZE"] ?? "") ?? 3
        Thread.sleep(forTimeInterval: 1.5)
        let reports = Harness.reports(since: began)
        let freezes = reports.filter { ($0["kind"] as? String) == "freeze" }
        let lines = reports.map { "\($0["kind"] ?? "?") \($0["summary"] ?? "")" }
        trail.append("\nDuet's own reports during the run (\(reports.count)):\n" + lines.joined(separator: "\n"))
        print("monkey: \(step) steps, \(slow.count) slow to drive, \(freezes.count) freezes reported, seed \(seed)")
        lines.forEach { print("monkey report: \($0)") }
        let worst = freezes.compactMap { $0["durationMs"] as? Double }.max() ?? 0
        XCTAssertLessThan(worst / 1000, maxFreeze, "Duet froze for \(Int(worst)) ms. Seed \(seed).")
        XCTAssertFalse(reports.contains { ($0["kind"] as? String) == "exit" || ($0["kind"] as? String) == "crash" },
                       "Duet reported a crash or an unexpected exit. Seed \(seed).")
    }

    /// One random step; says what it did.
    @MainActor
    private func act(_ app: XCUIApplication, _ rng: inout SeededRandom, step: Int) -> String {
        let window = app.windows.firstMatch
        let frame = window.frame
        func point(_ x: Double, _ y: Double) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }
        func anywhere() -> (Double, Double) {
            (Double.random(in: 8...(frame.width - 8), using: &rng), Double.random(in: 30...(frame.height - 8), using: &rng))
        }

        // Every so often: dismiss what's covering things, rotate, or go to the background and back.
        if step % 25 == 0, app.alerts.count + app.sheets.count > 0 {
            let button = (app.alerts.firstMatch.exists ? app.alerts.firstMatch : app.sheets.firstMatch).buttons.firstMatch
            if button.exists { button.tap() }
            return "dismiss a dialog"
        }
        if step % 45 == 0 {
            let orientations: [UIDeviceOrientation] = [.portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown]
            let o = orientations.randomElement(using: &rng)!
            XCUIDevice.shared.orientation = o
            return "rotate to \(o.rawValue)"
        }
        if step % 70 == 0 {
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: Double.random(in: 0.3...3, using: &rng))
            app.activate()
            return "background and back"
        }

        let roll = Int.random(in: 0..<100, using: &rng)
        switch roll {
        case 0..<38:
            // Something meant to be tapped: from one snapshot of the screen (fast, unlike querying each element).
            guard let snap = try? app.snapshot() else { return "no snapshot" }
            var targets: [(String, CGRect)] = []
            func collect(_ s: XCUIElementSnapshot) {
                if [.button, .cell, .link, .tab, .switch, .segmentedControl, .menuItem, .textField, .textView].contains(s.elementType),
                   s.isEnabled, s.frame.width > 4, s.frame.height > 4, frame.intersects(s.frame) {
                    targets.append((s.identifier.isEmpty ? s.label : s.identifier, s.frame))
                }
                s.children.forEach(collect)
            }
            collect(snap)
            guard let (name, f) = targets.randomElement(using: &rng) else { return "nothing to tap" }
            point(f.midX - frame.minX, f.midY - frame.minY).tap()
            return "tap \(name.prefix(50))"
        case 38..<50:
            let (x, y) = anywhere()
            point(x, y).tap()
            return String(format: "tap at %.0f,%.0f", x, y)
        case 50..<70:
            let (x, y) = anywhere()
            let dy = Double.random(in: -500...500, using: &rng), dx = Double.random(in: -120...120, using: &rng)
            point(x, y).press(forDuration: 0.02, thenDragTo: point(x + dx, y + dy), withVelocity: .fast, thenHoldForDuration: 0)
            return String(format: "scroll %.0f,%.0f by %.0f,%.0f", x, y, dx, dy)
        case 70..<78:
            let (x, y) = anywhere()
            point(x, y).press(forDuration: Double.random(in: 0.4...1.2, using: &rng))
            return String(format: "long press at %.0f,%.0f", x, y)
        case 78..<88:
            // Lift a tab and drop it anywhere (split, a new window, back where it was).
            let tabs = app.buttons.matching(identifier: "tab")
            let n = tabs.count
            guard n > 0 else { return "no tab to lift" }
            let tab = tabs.element(boundBy: Int.random(in: 0..<n, using: &rng))
            guard tab.isHittable else { return "tab not hittable" }
            let (x, y) = anywhere()
            tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.4, thenDragTo: point(x, y), withVelocity: .slow, thenHoldForDuration: Double.random(in: 0...0.6, using: &rng))
            return String(format: "lift a tab to %.0f,%.0f", x, y)
        case 88..<96:
            let field = app.textViews["composer"].exists ? app.textViews["composer"] : app.textFields.firstMatch
            guard field.exists, field.isHittable else { return "no field" }
            field.tap()
            // Typing needs the field focused; a tap that opened something else instead isn't a failure.
            guard (field.value(forKey: "hasKeyboardFocus") as? Bool) == true else { return "field didn't take focus" }
            let words = ["why", "does", "the", "lexer", "drop", "tokens", "😀", "\n", "fix", "it", "please", "`code`"]
            field.typeText((0..<Int.random(in: 1...8, using: &rng)).map { _ in words.randomElement(using: &rng)! }.joined(separator: " "))
            return "type into \(field.identifier.isEmpty ? "a field" : field.identifier)"
        default:
            // A two-finger pinch: zoomable pages (diagrams, files).
            let (x, y) = anywhere()
            window.coordinate(withNormalizedOffset: CGVector(dx: x / frame.width, dy: y / frame.height)).tap()
            if let e = app.webViews.allElementsBoundByIndex.first, e.isHittable { e.pinch(withScale: Double.random(in: 0.5...2, using: &rng), velocity: 2) }
            return "pinch"
        }
    }
}
