import DuetKit
import SwiftUI

extension View {
    /// Every button that isn't the go-ahead or Stop: bordered, neutral (Edit, Reject, Cancel, Scan Again).
    /// Declining isn't a failure, so these never take a state colour.
    func neutralBordered() -> some View {
        buttonStyle(.bordered).tint(.slateHigh).foregroundStyle(.textPrimary)
    }
}

/// A round, icon-only toolbar button with a 44pt target and a spoken label.
struct IconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
