import DuetKit
import SwiftUI

extension EnvironmentValues {
    /// The Pencil is on the page. Floating panels drop their glass and shadow until it lifts: anything composited over
    /// or beside the ink costs the writing frames (Notes parity).
    @Entry var pencilDown = false
}

/// A floating panel (header, composer, popover, pill): glass with the one panel shadow, or an opaque `slateRaised`
/// fill with no shadow while the Pencil is down or Reduce Transparency is on.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = DS.radiusPanel
    @Environment(\.pencilDown) private var pencilDown
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let opaque = pencilDown || reduceTransparency
        content
            .background {
                if opaque {
                    shape.fill(.slateRaised)
                } else {
                    shape.fill(.regularMaterial)
                        .shadow(color: .black.opacity(DS.shadowOpacity), radius: DS.shadowRadius, y: DS.shadowY)
                }
            }
            .overlay { shape.strokeBorder(.slateLine, lineWidth: 1) }
    }
}

extension View {
    func glassPanel(radius: CGFloat = DS.radiusPanel) -> some View { modifier(GlassPanel(radius: radius)) }
}
