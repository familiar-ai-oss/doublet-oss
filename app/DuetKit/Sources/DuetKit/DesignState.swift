// Colour follows state: the five states every screen draws from, each with its token, symbol and word.

/// What something is doing, as the design system's state map names it. Views pass one of these, never a colour.
public enum DesignState: String, CaseIterable, Sendable {
    case working, needsYou, done, failed, idle

    public var token: Token {
        switch self {
        case .working: Tokens.stateWorking
        case .needsYou: Tokens.stateNeedsYou
        case .done: Tokens.stateDone
        case .failed: Tokens.stateFailed
        case .idle: Tokens.stateIdle
        }
    }

    /// The symbol that goes with the colour, so colour is never the only cue.
    public var symbol: String {
        switch self {
        case .working: "gearshape.2"
        case .needsYou: "hand.raised.fill"
        case .done: "checkmark.seal.fill"
        case .failed: "xmark.octagon.fill"
        case .idle: "hourglass"
        }
    }

    /// The default word: "Needs you", sentence case.
    public var word: String {
        switch self {
        case .working: "Working"
        case .needsYou: "Needs you"
        case .done: "Done"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }

    /// Needs you is the one filled badge; every other state is an outline.
    public var filled: Bool { self == .needsYou }
}
