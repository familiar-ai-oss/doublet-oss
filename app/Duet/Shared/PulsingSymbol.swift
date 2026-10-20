import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// An SF Symbol that pulses while something is under way (Claude working, a step in progress), for the status lines.
///
/// SwiftUI's own `.symbolEffect(.pulse)` redraws on the main thread every frame (120 a second on a ProMotion iPad) for
/// as long as it runs, which takes time from touches. This one is a Core Animation opacity animation on the symbol's
/// layer: the system's render server plays it, at no more than 30 frames a second, with no work on the main thread.
struct PulsingSymbol: View {
    let systemName: String
    let tint: Color
    var textStyle: Font.TextStyle = .body
    let active: Bool

    var body: some View {
        if SpeedSwitches.on("pulse") {
            PulsingSymbolView(systemName: systemName, tint: tint, textStyle: textStyle, active: active)
                .fixedSize()
                .accessibilityHidden(true)
        } else {
            // As before the fix.
            Image(systemName: systemName).font(.system(textStyle)).foregroundStyle(tint).symbolEffect(.pulse, isActive: active)
        }
    }
}

private let pulseKey = "duet.pulse"

private func pulse() -> CABasicAnimation {
    let a = CABasicAnimation(keyPath: "opacity")
    a.fromValue = 1.0
    a.toValue = 0.3
    a.duration = 0.9
    a.autoreverses = true
    a.repeatCount = .infinity
    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
    a.isRemovedOnCompletion = false
    return a
}

#if os(iOS)
private struct PulsingSymbolView: UIViewRepresentable {
    let systemName: String
    let tint: Color
    let textStyle: Font.TextStyle
    let active: Bool

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .center
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        let config = UIImage.SymbolConfiguration(textStyle: Self.uiStyle(textStyle))
        v.image = UIImage(systemName: systemName, withConfiguration: config)
        v.tintColor = UIColor(tint)
        let running = v.layer.animation(forKey: pulseKey) != nil
        if active, !running { v.layer.add(pulse(), forKey: pulseKey) }
        if !active, running { v.layer.removeAnimation(forKey: pulseKey) }
    }

    static func uiStyle(_ s: Font.TextStyle) -> UIFont.TextStyle {
        switch s {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
#else
private struct PulsingSymbolView: NSViewRepresentable {
    let systemName: String
    let tint: Color
    let textStyle: Font.TextStyle
    let active: Bool

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.wantsLayer = true
        v.setContentHuggingPriority(.required, for: .horizontal)
        v.setContentHuggingPriority(.required, for: .vertical)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        let config = NSImage.SymbolConfiguration(textStyle: Self.nsStyle(textStyle))
        v.image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        v.contentTintColor = NSColor(tint)
        guard let layer = v.layer else { return }
        let running = layer.animation(forKey: pulseKey) != nil
        if active, !running { layer.add(pulse(), forKey: pulseKey) }
        if !active, running { layer.removeAnimation(forKey: pulseKey) }
    }

    static func nsStyle(_ s: Font.TextStyle) -> NSFont.TextStyle {
        switch s {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
#endif
