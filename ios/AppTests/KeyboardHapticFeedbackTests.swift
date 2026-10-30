import XCTest
import UIKit

/// These tests observe public UIKit feedback requests. They cannot establish
/// whether hardware played a vibration or how strong it felt to a person.
@MainActor
final class KeyboardHapticFeedbackTests: XCTestCase {
    func testDetachedViewNeverRequestsFeedbackOrCreatesAnInteraction() {
        let view = UIView()
        let feedback = KeyboardHapticFeedback(view: view, isVoiceOverRunning: { false })
        var events: [KeyboardHapticFeedback.Event] = []
        feedback.onFeedbackRequested = { event, _ in events.append(event) }

        feedback.keyPressed()
        feedback.deleteRepeated()

        XCTAssertNil(view.window)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(feedback.requestedPulseCount, 0)
        XCTAssertTrue(generators(in: view).isEmpty)
    }

    func testVoiceOverSuppressesExtraFeedbackAndReleasesPreparedInteraction() throws {
        let view = hostedView()
        var voiceOver = true
        let feedback = KeyboardHapticFeedback(view: view, isVoiceOverRunning: { voiceOver })
        defer { feedback.reset() }
        var events: [KeyboardHapticFeedback.Event] = []
        feedback.onFeedbackRequested = { event, _ in events.append(event) }

        feedback.keyPressed()
        feedback.deleteRepeated()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(generators(in: view).isEmpty)

        voiceOver = false
        feedback.keyPressed()
        XCTAssertEqual(events, [.keyPress])
        XCTAssertNotNil(try XCTUnwrap(generators(in: view).first).view)

        voiceOver = true
        feedback.keyPressed()
        XCTAssertEqual(events, [.keyPress], "VoiceOver activation must not add a second feedback source")
        XCTAssertTrue(generators(in: view).isEmpty,
                      "Suppression must release a generator prepared before VoiceOver became active")
    }

    func testPhysicalPressHasOnePulseAndLaterDeleteRepeatIsWeaker() async throws {
        let view = hostedView()
        let feedback = KeyboardHapticFeedback(view: view, isVoiceOverRunning: { false })
        defer { feedback.reset() }
        var events: [(KeyboardHapticFeedback.Event, CGFloat)] = []
        feedback.onFeedbackRequested = { events.append(($0, $1)) }

        feedback.keyPressed()
        feedback.deleteRepeated()
        XCTAssertEqual(events.map(\.0), [.keyPress],
                       "The initial Delete action must not double the touch-down pulse")

        try await Task.sleep(for: .milliseconds(120))
        feedback.deleteRepeated()
        feedback.deleteRepeated()
        XCTAssertEqual(events.map(\.0), [.keyPress, .deleteRepeat],
                       "One logical repeat must not become a pulse for every deletion in a word batch")
        let press = try XCTUnwrap(events.first)
        let repeated = try XCTUnwrap(events.dropFirst().first)
        XCTAssertGreaterThan(press.1, 0)
        XCTAssertLessThanOrEqual(press.1, 0.6, "Keyboard feedback should remain subtle")
        XCTAssertGreaterThan(repeated.1, 0)
        XCTAssertLessThan(repeated.1, press.1, "Continuous Delete feedback must be lighter")
        XCTAssertEqual(feedback.requestedPulseCount, 2)

        // A slightly early 60 ms repeat must not become alternating feedback.
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(55))
            feedback.deleteRepeated()
        }
        XCTAssertEqual(feedback.requestedPulseCount, 5)
    }

    func testDistinctRapidKeyPressesAreNotThrottledAndReuseOneGenerator() throws {
        let view = hostedView()
        let feedback = KeyboardHapticFeedback(view: view, isVoiceOverRunning: { false })
        defer { feedback.reset() }
        var events: [KeyboardHapticFeedback.Event] = []
        feedback.onFeedbackRequested = { event, _ in events.append(event) }

        feedback.keyPressed()
        let first = try XCTUnwrap(generators(in: view).first)
        feedback.keyPressed()
        feedback.keyPressed()

        XCTAssertEqual(events, [.keyPress, .keyPress, .keyPress])
        XCTAssertEqual(generators(in: view).count, 1)
        XCTAssertTrue(generators(in: view).first === first,
                      "Rapid typing should reuse the prepared generator rather than allocate one per key")
    }

    func testIdleDoesNotCreateRequestsAndResetDetachesTheGenerator() async throws {
        let view = hostedView()
        let feedback = KeyboardHapticFeedback(view: view, isVoiceOverRunning: { false })
        defer { feedback.reset() }
        var events: [KeyboardHapticFeedback.Event] = []
        feedback.onFeedbackRequested = { event, _ in events.append(event) }

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(generators(in: view).isEmpty,
                      "Showing a keyboard must not create a feedback interaction before a physical action")

        feedback.keyPressed()
        let first = try XCTUnwrap(generators(in: view).first)
        feedback.reset()
        XCTAssertNil(first.view)
        XCTAssertTrue(generators(in: view).isEmpty)

        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(events, [.keyPress], "Cancellation must not leave an autonomous repeat or prepare task")
        XCTAssertTrue(generators(in: view).isEmpty)

        feedback.keyPressed()
        XCTAssertEqual(events, [.keyPress, .keyPress])
        XCTAssertEqual(generators(in: view).count, 1)
        XCTAssertFalse(generators(in: view).first === first,
                       "A new interaction after lifecycle cleanup must start from a fresh generator")
    }

    private func generators(in view: UIView) -> [UIImpactFeedbackGenerator] {
        view.interactions.compactMap { $0 as? UIImpactFeedbackGenerator }
    }

    private func hostedView() -> UIView {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 300))
        let controller = UIViewController()
        window.rootViewController = controller
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 240))
        controller.view.addSubview(view)
        window.isHidden = false
        window.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            for interaction in view.interactions where interaction is UIImpactFeedbackGenerator {
                view.removeInteraction(interaction)
            }
            window.isHidden = true
            window.rootViewController = nil
        }
        return view
    }
}
