// OLIV unit tests. W3-T1 seeds the target so `xcodebuild test` is wired
// from day one; W3-T2 fills it with the ported hotkey state-machine, audio
// bounded-stop, and clipboard round-trip suites.

import XCTest
@testable import OLIV

final class DictationStatusTests: XCTestCase {
    /// Every status must have a distinct menu-bar symbol — the icon is the
    /// only always-visible recording indicator, so two states sharing a
    /// symbol would make one of them invisible to the user.
    func testStatusSymbolsAreDistinct() {
        let all: [DictationStatus] = [.idle, .recording, .processing]
        let symbols = Set(all.map(\.symbolName))
        XCTAssertEqual(symbols.count, all.count)
    }
}

@MainActor
final class OnboardingWindowLifecycleTests: XCTestCase {
    // Closing Setup must RELEASE the window: a retained NSHostingController
    // keeps OnboardingView alive, and its 1 s permission/model poll would keep
    // firing forever behind a closed window. show() after close rebuilds fresh.
    func testCloseReleasesWindowAndShowRebuilds() {
        let controller = OnboardingWindowController(
            permissions: PermissionsModel(), models: ModelState(), onClose: {})
        controller.show()
        guard let first = controller.window else {
            return XCTFail("show() must create the window")
        }
        first.close()
        XCTAssertNil(controller.window,
                     "close must release the window (and its poll timer)")
        controller.show()
        XCTAssertNotNil(controller.window)
        XCTAssertNotIdentical(controller.window, first,
                              "show() after close must build a fresh window")
        controller.window?.close()
    }
}
