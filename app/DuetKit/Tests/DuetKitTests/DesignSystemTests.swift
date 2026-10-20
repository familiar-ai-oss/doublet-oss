import Testing
@testable import DuetKit

private let surfaces: [(String, Token)] = [
    ("slateBase", Tokens.slateBase), ("slateRaised", Tokens.slateRaised),
    ("slateHigh", Tokens.slateHigh), ("slateWell", Tokens.slateWell),
]

/// Text colours that must read on every slate surface, in both themes, and the ratio tokens.json promises.
private let text: [(String, Token, Double)] = [
    ("textPrimary", Tokens.textPrimary, 12),
    ("textSecondary", Tokens.textSecondary, 4.7),
    ("stateWorking", Tokens.stateWorking, 4.7),
    ("stateDone", Tokens.stateDone, 5.2),
    ("stateFailed", Tokens.stateFailed, 4.5),
    ("stateNeedsYou", Tokens.stateNeedsYou, 12),
]

@Test(arguments: text)
func textReadsOnEverySurface(_ t: (String, Token, Double)) {
    for (surface, s) in surfaces {
        let dark = Hex.contrast(t.1.dark, s.dark), light = Hex.contrast(t.1.light, s.light)
        #expect(dark >= t.2, "\(t.0) on \(surface), dark: \(dark)")
        #expect(light >= t.2, "\(t.0) on \(surface), light: \(light)")
    }
}

@Test func buttonLabelsReadOnTheirFills() {
    for theme in [\Token.dark, \Token.light] {
        #expect(Hex.contrast(Tokens.onNeedsYou[keyPath: theme], Tokens.stateNeedsYou[keyPath: theme]) >= 4.5)
        #expect(Hex.contrast(Tokens.onFailed[keyPath: theme], Tokens.stateFailed[keyPath: theme]) >= 4.5)
    }
}

@Test func hairlineIsEightPercentWhiteInDark() {
    #expect(abs(Tokens.slateLine.dark.a - 0x14 / 255.0) < 0.001)
    let line = Tokens.slateLine.dark.over(Tokens.slateRaised.dark)
    // Decorative: visible, but never strong enough to be the only sign of a state.
    #expect(Hex.contrast(line, Tokens.slateRaised.dark) < 3)
}
