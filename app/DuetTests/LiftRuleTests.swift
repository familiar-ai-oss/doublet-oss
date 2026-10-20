import CoreGraphics
import Testing
@testable import Duet

/// When a tab held in the strip lifts out of it (iPad), and when the strip scrolls instead.
struct LiftRuleTests {
    @Test func aStillFingerLiftsAfterTheHold() {
        #expect(LiftRule.verdict(.finger, translation: .zero, elapsed: 0.2) == .wait)
        #expect(LiftRule.verdict(.finger, translation: CGSize(width: 4, height: 3), elapsed: 0.3) == .lift)
    }

    @Test func movingSidewaysScrollsTheStrip() {
        #expect(LiftRule.verdict(.finger, translation: CGSize(width: 11, height: 0), elapsed: 0.1) == .fail)
        #expect(LiftRule.verdict(.finger, translation: CGSize(width: -11, height: 2), elapsed: 0.25) == .fail)
        #expect(LiftRule.verdict(.pencil, translation: CGSize(width: 14, height: 4), elapsed: 0.1) == .fail)
    }

    @Test func pullingDownLiftsAtOnce() {
        #expect(LiftRule.verdict(.finger, translation: CGSize(width: 3, height: 12), elapsed: 0.05) == .lift)
        // More across than down isn't a pull.
        #expect(LiftRule.verdict(.finger, translation: CGSize(width: 13, height: 12), elapsed: 0.05) == .fail)
    }

    @Test func movingUpDoesntLift() {
        #expect(LiftRule.verdict(.finger, translation: CGSize(width: 0, height: -11), elapsed: 0.1) == .fail)
    }

    @Test func aFirmPencilPressLiftsAtOnce() {
        #expect(LiftRule.verdict(.pencil, translation: .zero, elapsed: 0.02, force: 0.6) == .lift)
        #expect(LiftRule.verdict(.pencil, translation: .zero, elapsed: 0.02, force: 0.5) == .wait)
        // A finger has no force to press with.
        #expect(LiftRule.verdict(.finger, translation: .zero, elapsed: 0.02, force: 0.9) == .wait)
    }

    @Test func aPointerLiftsAsSoonAsItDrags() {
        #expect(LiftRule.verdict(.pointer, translation: CGSize(width: 3, height: 0), elapsed: 1) == .wait)
        #expect(LiftRule.verdict(.pointer, translation: CGSize(width: 4, height: 0), elapsed: 0.01) == .lift)
        #expect(LiftRule.verdict(.pointer, translation: CGSize(width: 0, height: -20), elapsed: 0.01) == .lift)
    }
}
