import DuetKit
import SwiftUI

extension DesignState {
    var color: Color { token.color }
}

/// A state as a capsule: its symbol and word in the state's colour, outlined; Needs you is the one filled badge.
struct StateBadge: View {
    let state: DesignState
    var word: String?
    var showsSymbol = true

    var body: some View {
        let label = HStack(spacing: DS.space4) {
            if showsSymbol { Image(systemName: state.symbol).imageScale(.small) }
            Text(word ?? state.word)
        }
        .font(.caption.weight(.bold))
        .padding(.vertical, DS.space2)
        .padding(.horizontal, DS.space8)
        if state.filled {
            label.foregroundStyle(.onNeedsYou).background(Capsule().fill(.stateNeedsYou))
        } else {
            label.foregroundStyle(state.color).overlay(Capsule().strokeBorder(state.color, lineWidth: 1))
        }
    }
}

/// A neutral tag: a profile, a version, a message kind. Machine words, so mono.
struct TagBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.monospaced())
            .foregroundStyle(.textSecondary)
            .padding(.vertical, 1)
            .padding(.horizontal, DS.space6)
            .background(Capsule().fill(.slateHigh))
    }
}

/// A settings value's provenance: "Default" quietly, "Changed" in the working colour so you can see what you moved.
struct DefaultTag: View {
    let changed: Bool

    var body: some View {
        Text(changed ? "Changed" : "Default")
            .font(.caption)
            .foregroundStyle(changed ? .stateWorking : .textSecondary)
    }
}
