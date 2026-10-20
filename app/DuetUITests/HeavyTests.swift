import XCTest

/// Heavy scenarios, measured: hitches while scrolling a long conversation and while a reply streams in, CPU and memory
/// while it does, a flood of events at once, many tabs, and launch. The numbers land in the test report; a baseline
/// set in Xcode turns a regression into a failure.
///
/// The streaming ones need the firehose (hub/tools/firehose.ts) as the hub, so the history is long and the replies
/// fast: TEST_RUNNER_DUET_URL=ws://127.0.0.1:7898/ws. The rest run on the demo conversation.
final class HeavyTests: XCTestCase {
    override func setUp() {
        Harness.currentTest = name
    }

    private var options: XCTMeasureOptions {
        let o = XCTMeasureOptions()
        o.iterationCount = Int(Harness.env["DUET_MEASURE_ITERATIONS"] ?? "") ?? 3
        return o
    }

    private func requireFirehose() throws {
        guard Harness.firehose != nil, Harness.call("/health") != nil else {
            throw XCTSkip("needs the firehose as the hub (TEST_RUNNER_DUET_URL=ws://127.0.0.1:7898/ws)")
        }
    }

    /// Opening Duet on a long history (the firehose's, like a real hub's thousands of events): how long until the
    /// conversation is up and Duet answers. Each opening replays the whole history; its freeze, if any, is reported.
    @MainActor
    func testOpenWithLongHistory() throws {
        try requireFirehose()
        measure(metrics: [XCTClockMetric()], options: options) {
            let app = Harness.launch()
            let thread = app.descendants(matching: .any).matching(identifier: "lead-thread").firstMatch
            XCTAssertTrue(thread.waitForExistence(timeout: 60), "no conversation")
            // A tap that has to wait for Duet to be free: the measure ends when Duet answers it.
            thread.swipeUp(velocity: .slow)
        }
    }

    /// The conversation with its whole history: scrolling it, fast, up and back down.
    @MainActor
    func testScrollLongConversation() throws {
        try requireFirehose()
        let app = Harness.launch()
        let thread = app.descendants(matching: .any).matching(identifier: "lead-thread").firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 60), "no conversation")
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            for _ in 0..<3 { thread.swipeDown(velocity: .fast) }
            for _ in 0..<3 { thread.swipeUp(velocity: .fast) }
        }
    }

    /// A long reply streaming in, with tool runs and their output, while you scroll and type.
    @MainActor
    func testStreamingWhileScrollingAndTyping() throws {
        try requireFirehose()
        let app = Harness.launch()
        let thread = app.descendants(matching: .any).matching(identifier: "lead-thread").firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 60), "no conversation")
        let composer = app.textViews["composer"]
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            Harness.call("/stream?chars=12000&rate=80&tools=4")
            let end = Date().addingTimeInterval(8)
            while Date() < end {
                thread.swipeDown(velocity: .slow)
                thread.swipeUp(velocity: .fast)
                if composer.exists, composer.isHittable { composer.tap(); composer.typeText("does this stay smooth ") }
            }
            Harness.call("/stop")
        }
    }

    /// Claude working while you only watch: a reply trickling in, the status pulsing, its timer ticking. What Duet
    /// costs while you're not touching it.
    @MainActor
    func testWatchingClaudeWork() throws {
        try requireFirehose()
        let app = Harness.launch()
        let thread = app.descendants(matching: .any).matching(identifier: "lead-thread").firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 30), "no conversation")
        Harness.call("/stream?chars=200000&rate=3&tools=0")
        Thread.sleep(forTimeInterval: 2)
        measure(metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            Thread.sleep(forTimeInterval: 10)
        }
        Harness.call("/stop")
    }

    /// 5,000 events at once (a reconnect after a long time away looks like this): how long until Duet answers a tap.
    @MainActor
    func testEventFlood() throws {
        try requireFirehose()
        let app = Harness.launch()
        let thread = app.descendants(matching: .any).matching(identifier: "lead-thread").firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 60), "no conversation")
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            Harness.call("/burst?events=5000")
            // XCUITest waits for the app to be idle before it acts, so this measures how long the flood takes.
            thread.swipeUp(velocity: .fast)
            XCTAssertEqual(app.state, .runningForeground)
        }
    }

    /// Seven tabs in the side stage, switched between over and over.
    @MainActor
    func testSwitchingManyTabs() throws {
        let app = Harness.launch(dest: "fleet,notes,inbox,plan:s2,diagram:g1,conversation:s1,file:/home/you/projects/parser/Sources/Parser/Lexer.swift:27", demo: true)
        let tabs = app.buttons.matching(identifier: "tab")
        XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 15), "no tabs")
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)], options: options) {
            for round in 0..<2 {
                for i in 0..<tabs.count {
                    let t = tabs.element(boundBy: round == 0 ? i : tabs.count - 1 - i)
                    if t.isHittable { t.tap() }
                }
            }
        }
    }

    /// The side stage split, filled to the window and back, and its divider dragged.
    @MainActor
    func testSplitAndFill() throws {
        let app = Harness.launch(dest: "plan:s2,diagram:g1,split", demo: true)
        let zoom = app.buttons["stage-zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 15), "no side stage")
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)], options: options) {
            for _ in 0..<3 {
                if zoom.isHittable { zoom.tap() }
                if zoom.isHittable { zoom.tap() }
            }
        }
    }

    @MainActor
    func testLaunch() throws {
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            _ = Harness.launch(demo: true)
        }
    }
}
