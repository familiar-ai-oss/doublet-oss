import XCTest

/// Last in a run: opens Duet against the firehose for a few seconds so reports still waiting in its outbox (from
/// demo-mode tests, which never connect) reach the firehose and the run's summary.
final class ZZFlushTests: XCTestCase {
    @MainActor
    func testSendWaitingReports() throws {
        guard Harness.firehose != nil else { throw XCTSkip("no firehose") }
        Harness.currentTest = name
        _ = Harness.launch()
        Thread.sleep(forTimeInterval: 6)
    }
}
