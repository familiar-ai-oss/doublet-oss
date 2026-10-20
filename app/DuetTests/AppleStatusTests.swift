import DuetKit
import Testing
@testable import Duet

/// What Duet tells the hub about this device's on-device model, read off the main thread as it connects.
@MainActor
struct AppleStatusTests {
    @Test func readingOffTheMainThreadSaysTheSame() async {
        let apple = AppleIntelligence()
        let read = await apple.readStatus()
        #expect(read == apple.status)
        #expect(read.platform == "ipad" || read.platform == "iphone")
        #expect(read.simulator == true)
    }
}
