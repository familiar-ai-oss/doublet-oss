// The Doublet design system: Familiar's cool slate layers, one meaning per state colour, Exo 2 for display type.
// Names follow the design system's tokens.json (slate-base → slateBase). Every colour has a dark and a light value.
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An sRGB colour from 0xRRGGBB or 0xRRGGBBAA, as the tokens write them.
public struct Hex: Equatable, Sendable {
    public let r, g, b, a: Double

    public init(_ rgb: UInt32, alpha: Double = 1) {
        r = Double((rgb >> 16) & 0xff) / 255
        g = Double((rgb >> 8) & 0xff) / 255
        b = Double(rgb & 0xff) / 255
        a = alpha
    }

    /// #ffffff14 → Hex(0xffffff, alpha: 0x14/255).
    public init(rgba: UInt32) { self.init(rgba >> 8, alpha: Double(rgba & 0xff) / 255) }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// This colour laid over an opaque one.
    public func over(_ below: Hex) -> Hex {
        Hex(r: r * a + below.r * (1 - a), g: g * a + below.g * (1 - a), b: b * a + below.b * (1 - a))
    }

    private init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b; a = 1 }

    /// WCAG contrast ratio between two opaque colours, 1...21.
    public static func contrast(_ x: Hex, _ y: Hex) -> Double {
        let (hi, lo) = x.luminance > y.luminance ? (x.luminance, y.luminance) : (y.luminance, x.luminance)
        return (hi + 0.05) / (lo + 0.05)
    }
}

/// One token: its dark and light values.
public struct Token: Sendable {
    public let dark: Hex
    public let light: Hex

    public init(dark: Hex, light: Hex) { self.dark = dark; self.light = light }
    public init(_ both: Hex) { dark = both; light = both }

    public var color: Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? self.dark.uiColor : self.light.uiColor })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? self.dark.nsColor : self.light.nsColor
        })
        #endif
    }
}

#if canImport(UIKit)
extension Hex { var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) } }
#else
extension Hex { var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) } }
#endif

/// The token values. Views use the `Color` statics below; tests check these.
public enum Tokens {
    // Surfaces: Familiar's L0, L2, L4, L1 and its 8% hairline.
    public static let slateBase = Token(dark: Hex(0x0a0d14), light: Hex(0xf3f4f7))
    public static let slateRaised = Token(dark: Hex(0x151a25), light: Hex(0xffffff))
    public static let slateHigh = Token(dark: Hex(0x212b3f), light: Hex(0xe6e8ee))
    public static let slateWell = Token(dark: Hex(0x0f1319), light: Hex(0xeef0f4))
    public static let slateLine = Token(dark: Hex(rgba: 0xffffff14), light: Hex(0xd9dce3))

    public static let textPrimary = Token(dark: Hex(0xe8edf5), light: Hex(0x0a0d14))
    public static let textSecondary = Token(dark: Hex(0x9ba5b8), light: Hex(0x5f6573))

    // States: each colour means one thing.
    /// Running now. Titles, the live dot, progress. Never fills a button or a card.
    public static let stateWorking = Token(dark: Hex(0x4da6ff), light: Hex(0x1a66b8))
    public static let stateWorkingHalo = Token(dark: Hex(rgba: 0x4da6ff47), light: Hex(rgba: 0x1a66b82e))
    /// Finished. Always with its symbol and word.
    public static let stateDone = Token(dark: Hex(0x10b981), light: Hex(0x046c4e))
    /// Waiting on you: the border of a decision card and the fill of its one main button. White is your hand.
    public static let stateNeedsYou = Token(dark: Hex(0xffffff), light: Hex(0x0a0d14))
    /// Failed or risky. Always with its symbol and word.
    public static let stateFailed = Token(dark: Hex(0xf87171), light: Hex(0xc62828))
    public static let stateIdle = textSecondary
    public static let onNeedsYou = Token(dark: Hex(0x0a0d14), light: Hex(0xffffff))
    public static let onFailed = Token(dark: Hex(0x0a0d14), light: Hex(0xffffff))

    // Pencil.
    public static let penChalk = stateNeedsYou
    public static let penRed = stateFailed
    public static let penGreen = stateDone
    public static let pencilTether = Token(dark: Hex(rgba: 0xffffff8c), light: Hex(rgba: 0x0a0d148c))
    public static let pencilHover = stateNeedsYou

    // Diffs.
    public static let diffAdded = Token(dark: Hex(0x12391e), light: Hex(0xe6ffec))
    public static let diffRemoved = Token(dark: Hex(0x3d1418), light: Hex(0xffebe9))
    public static let diffChangedBar = Token(Hex(0x2da44e))
    public static let diffRemovedMark = Token(Hex(0xcf222e))
    /// +/− counts and added/removed lines shown as code.
    public static let codeAddition = Token(dark: Hex(0x7ee787), light: Hex(0x116329))
    public static let codeDeletion = Token(dark: Hex(0xff7b72), light: Hex(0xa40e26))

    /// Familiar's blue, for brand graphics.
    public static let brandBlue = Token(Hex(0x4da6ff))
}

extension ShapeStyle where Self == Color {
    public static var slateBase: Color { Tokens.slateBase.color }
    public static var slateRaised: Color { Tokens.slateRaised.color }
    public static var slateHigh: Color { Tokens.slateHigh.color }
    public static var slateWell: Color { Tokens.slateWell.color }
    public static var slateLine: Color { Tokens.slateLine.color }
    public static var textPrimary: Color { Tokens.textPrimary.color }
    public static var textSecondary: Color { Tokens.textSecondary.color }
    public static var stateWorking: Color { Tokens.stateWorking.color }
    public static var stateWorkingHalo: Color { Tokens.stateWorkingHalo.color }
    public static var stateDone: Color { Tokens.stateDone.color }
    public static var stateNeedsYou: Color { Tokens.stateNeedsYou.color }
    public static var stateFailed: Color { Tokens.stateFailed.color }
    public static var stateIdle: Color { Tokens.stateIdle.color }
    public static var onNeedsYou: Color { Tokens.onNeedsYou.color }
    public static var onFailed: Color { Tokens.onFailed.color }
    public static var penChalk: Color { Tokens.penChalk.color }
    public static var penRed: Color { Tokens.penRed.color }
    public static var penGreen: Color { Tokens.penGreen.color }
    public static var pencilTether: Color { Tokens.pencilTether.color }
    public static var pencilHover: Color { Tokens.pencilHover.color }
    public static var diffAdded: Color { Tokens.diffAdded.color }
    public static var diffRemoved: Color { Tokens.diffRemoved.color }
    public static var diffChangedBar: Color { Tokens.diffChangedBar.color }
    public static var diffRemovedMark: Color { Tokens.diffRemovedMark.color }
    public static var codeAddition: Color { Tokens.codeAddition.color }
    public static var codeDeletion: Color { Tokens.codeDeletion.color }
}

/// Radii and spacing.
public enum DS {
    public static let radiusWell: CGFloat = 8
    public static let radiusCard: CGFloat = 14
    public static let radiusPanel: CGFloat = 20

    public static let space2: CGFloat = 2
    public static let space4: CGFloat = 4
    public static let space6: CGFloat = 6
    public static let space8: CGFloat = 8
    public static let space10: CGFloat = 10
    public static let space12: CGFloat = 12
    public static let space16: CGFloat = 16
    /// Nesting under a row's symbol.
    public static let indent: CGFloat = 22

    /// Exo 2, Doublet's display face (SIL OFL). Falls back to the system font when it isn't bundled.
    public static let brandFamily = "Exo 2"
}

extension Font {
    /// Screen titles and onboarding: Exo 2 ExtraBold 28, scaling with Dynamic Type.
    public static var dsDisplay: Font { .custom(DS.brandFamily, size: 28, relativeTo: .title).weight(.heavy) }
    /// Section labels over a group of cards; use with `.overline()` for the caps and tracking.
    public static var dsOverline: Font { .custom(DS.brandFamily, size: 11, relativeTo: .caption2).weight(.semibold) }
    /// The wordmark: Exo 2 Black. Never for running text.
    public static var dsWordmark: Font { .custom(DS.brandFamily, size: 44, relativeTo: .largeTitle).weight(.black) }
}

extension View {
    /// A decision's one main button (Approve, Allow, Send Answers): filled `stateNeedsYou`, labelled `onNeedsYou`.
    public func needsYouProminent() -> some View {
        buttonStyle(.borderedProminent).tint(.stateNeedsYou).foregroundStyle(.onNeedsYou)
    }

    /// Stop and other destructive main buttons: filled `stateFailed`, labelled `onFailed`.
    public func failedProminent() -> some View {
        buttonStyle(.borderedProminent).tint(.stateFailed).foregroundStyle(.onFailed)
    }

    /// An overline section label: Exo 2 SemiBold 11, uppercase, 0.08em tracking, secondary text.
    public func overline() -> some View {
        font(.dsOverline).textCase(.uppercase).tracking(0.88).foregroundStyle(.textSecondary)
    }
}
