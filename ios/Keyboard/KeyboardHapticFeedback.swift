import UIKit

/// A small tactile response to deliberate keyboard touches. UIKit owns playback
/// and honors its hardware, power, and system haptics restrictions.
/// This helper never configures an audio session or keeps an idle task running.
@MainActor
final class KeyboardHapticFeedback {
    enum Event: Equatable {
        case keyPress
        case deleteRepeat
    }

    private weak var view: UIView?
    private var generator: UIImpactFeedbackGenerator?
    private let clock = ContinuousClock()
    private var lastPulse: ContinuousClock.Instant?
    private let isVoiceOverRunning: () -> Bool

#if DEBUG
    /// Records an admitted UIKit request, not proof of a physical vibration.
    /// Contains no key identity, document context, or typed text.
    var onFeedbackRequested: ((Event, CGFloat) -> Void)?
    private(set) var requestedPulseCount = 0
#endif

    init(view: UIView, isVoiceOverRunning: @escaping () -> Bool = { UIAccessibility.isVoiceOverRunning }) {
        self.view = view
        self.isVoiceOverRunning = isVoiceOverRunning
    }

    /// Call once at an enabled key's physical touch-down. Do not call again on
    /// release, a slide to a neighboring key, or accessibility activation.
    func keyPressed() {
        request(.keyPress, intensity: 0.55)
    }

    /// Call once per logical Delete repeat. A word batch still gets one pulse,
    /// regardless of the number of document-proxy deletions needed to finish it.
    func deleteRepeated() {
        let now = clock.now
        // Only repetition is throttled; distinct rapid key presses are never
        // dropped by this helper. This also rejects an immediate duplicate pulse
        // for the initial Delete action already covered by keyPressed().
        // Leave scheduling tolerance below the 60 ms character cadence, or
        // ordinary jitter would suppress every other repeat's light feedback.
        if let lastPulse, lastPulse.duration(to: now) < .milliseconds(40) { return }
        request(.deleteRepeat, intensity: 0.32)
    }

    /// Cancel/lifecycle cleanup. The modern generator is a UIInteraction, so
    /// remove it from its view as well as releasing our reference.
    func reset() {
        if let generator { generator.view?.removeInteraction(generator) }
        generator = nil
        lastPulse = nil
    }

    private func request(_ event: Event, intensity: CGFloat) {
        guard let view, view.window != nil, !view.isHidden, !isVoiceOverRunning() else {
            reset()
            return
        }
        let feedback: UIImpactFeedbackGenerator
        if let generator {
            feedback = generator
        } else {
            // The view-associated initializer is public on iOS 17.5 and later.
            // Construct lazily, only after an explicit physical interaction.
            feedback = UIImpactFeedbackGenerator(style: .light, view: view)
            generator = feedback
        }
        feedback.impactOccurred(intensity: intensity)
        lastPulse = clock.now
#if DEBUG
        requestedPulseCount += 1
        onFeedbackRequested?(event, intensity)
#endif
        // Apple's prepare() guidance explicitly recommends preparing AFTER a
        // pulse when another event is imminent. The prepared state expires on
        // its own after seconds; no timer continuously keeps it alive.
        feedback.prepare()
    }
}
