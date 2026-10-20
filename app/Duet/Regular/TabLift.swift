import SwiftUI
#if os(iOS)
import UIKit
#endif

/// When a tab held in the side stage's strip lifts out of it to be dropped somewhere else (iPad): a rule apart from the
/// touches, so it can be tested. A finger lifts a tab by holding it still for a moment, or at once by pulling it down out
/// of the strip; moved sideways first, it doesn't lift, so the strip scrolls. Apple Pencil lifts it the same ways, or at
/// once with a firm press. A pointer (a trackpad or a mouse) lifts it as soon as it drags. (A squeeze of Apple Pencil Pro
/// while it hovers over a tab lifts it too: `TabDrag.squeezeLift`.)
struct LiftRule {
    enum Input: Equatable { case finger, pencil, pointer }
    enum Verdict: Equatable { case wait, lift, fail }

    /// How long a finger or the Pencil holds a tab still before it lifts.
    static let hold: TimeInterval = 0.3
    /// How far it can wander meanwhile.
    static let slop: CGFloat = 10
    /// How far down out of the strip lifts it at once.
    static let pull: CGFloat = 12
    /// The Pencil's force, as a share of its most, that lifts it at once.
    static let press: CGFloat = 0.55
    /// How far a pointer drags before it lifts.
    static let pointerDrag: CGFloat = 4

    /// - Parameters:
    ///   - translation: how far it's moved since it came down (down is positive).
    ///   - elapsed: how long it's been down.
    ///   - force: the Pencil's force as a share of its most; nil when there's none.
    static func verdict(_ input: Input, translation: CGSize, elapsed: TimeInterval, force: CGFloat? = nil) -> Verdict {
        let across = abs(translation.width), down = translation.height
        let distance = (translation.width * translation.width + translation.height * translation.height).squareRoot()
        if input == .pointer { return distance >= pointerDrag ? .lift : .wait }
        if input == .pencil, let force, force > press { return .lift }
        // Pulled down out of the strip.
        if down >= pull, down > across { return .lift }
        // Moved sideways, or up, before it lifted: the strip scrolls instead.
        if distance > slop { return .fail }
        return elapsed >= hold ? .lift : .wait
    }
}

#if os(iOS)
/// A tap in the hand on Apple Pencil Pro (`UICanvasFeedbackGenerator`): a panel or a tab picked up, or settling into
/// place. Nothing with a finger, since an iPad has no Taptic Engine.
@MainActor
enum PencilTap {
    private static weak var window: UIWindow?
    private static var generator: UICanvasFeedbackGenerator?

    /// `point`: where it happened, in the window.
    static func play(at point: CGPoint) {
        guard let key = UIApplication.shared.connectedScenes.lazy.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        if window !== key || generator == nil {
            generator = UICanvasFeedbackGenerator(view: key)
            window = key
        }
        generator?.alignmentOccurred(at: point)
    }
}
#endif

#if os(iOS)
/// Lifting a tab out of the strip (iPad), by `LiftRule`, then carrying it: where it is, in the window, as it moves,
/// until it's let go. A right-click (a pointer's second button) isn't a lift: it opens the tab's menu.
struct TabLiftGesture: UIGestureRecognizerRepresentable {
    let lifted: (CGPoint) -> Void
    let moved: (CGPoint) -> Void
    let ended: (CGPoint) -> Void
    let cancelled: () -> Void
    let secondaryClick: () -> Void

    func makeUIGestureRecognizer(context: Context) -> TabLiftRecognizer {
        let recognizer = TabLiftRecognizer()
        recognizer.secondaryClick = secondaryClick
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: TabLiftRecognizer, context: Context) {
        recognizer.secondaryClick = secondaryClick
    }

    func handleUIGestureRecognizerAction(_ recognizer: TabLiftRecognizer, context: Context) {
        let point = context.converter.location(in: .global)
        switch recognizer.state {
        case .began: lifted(point)
        case .changed: moved(point)
        case .ended: ended(point)
        case .cancelled, .failed: cancelled()
        default: break
        }
    }
}

/// The lift itself. It waits while a finger or the Pencil is held still, and fails as soon as the touch moves sideways,
/// so the strip's scrolling, which waits for it to fail, takes over.
final class TabLiftRecognizer: UIGestureRecognizer {
    var secondaryClick: (() -> Void)?
    private weak var touch: UITouch?
    private var start: CGPoint = .zero
    private var began: TimeInterval = 0
    private var input: LiftRule.Input = .finger
    /// Lifts the tab once it's been held still long enough.
    private var holding: Task<Void, Never>?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, touches.count == 1, let t = touches.first else {
            // A second finger: not a lift.
            if state == .possible { state = .failed }
            return
        }
        if event.buttonMask.contains(.secondary) {
            state = .failed
            secondaryClick?()
            return
        }
        touch = t
        start = t.location(in: nil)
        began = t.timestamp
        input = switch t.type {
        case .pencil: .pencil
        case .indirectPointer: .pointer
        default: .finger
        }
        if input != .pointer {
            holding = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(LiftRule.hold))
                guard !Task.isCancelled else { return }
                self?.decide(after: LiftRule.hold)
            }
        }
        decide(after: 0)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t) else { return }
        switch state {
        case .possible: decide(after: t.timestamp - began)
        case .began, .changed: state = .changed
        default: break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t) else { return }
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t) else { return }
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        holding?.cancel()
        holding = nil
        touch = nil
        super.reset()
    }

    /// The strip's scrolling waits for this to fail: a tab held still, pulled down or pressed lifts instead.
    override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer && other.view is UIScrollView
    }

    private func decide(after elapsed: TimeInterval) {
        guard state == .possible, let t = touch else { return }
        let p = t.location(in: nil)
        let force: CGFloat? = input == .pencil && t.maximumPossibleForce > 0 ? t.force / t.maximumPossibleForce : nil
        switch LiftRule.verdict(input, translation: CGSize(width: p.x - start.x, height: p.y - start.y), elapsed: elapsed, force: force) {
        case .lift: state = .began
        case .fail: state = .failed
        case .wait: break
        }
    }
}
#endif
