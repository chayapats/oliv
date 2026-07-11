// Per-app verbatim resolution tests (W3-T4) — the Swift port of the Wave-2
// [cleanup_apps] precedence (app/dictation.py / app/config.py), driven with a
// FAKE frontmost bundle id (a plain string / the injectable seam), so there is
// NO AppKit, NO frontmost permission, fully deterministic.
//
// Semantics under test (see DictationController.resolveCleanup):
//   • global OFF wins everywhere (a per-app entry can only refine a globally-on
//     config, never turn it back on);
//   • the frontmost app's membership in the verbatim set ⇒ cleanup:false
//     (verbatim bypass), matched CASE-INSENSITIVELY (macOS bundle ids);
//   • unknown app (nil / empty id) ⇒ global (on) behavior.

import XCTest
@testable import OLIV

final class VerbatimResolutionTests: XCTestCase {

    // Global off ⇒ cleanup:false no matter the app or the verbatim set.
    func testGlobalOffDisablesEverywhere() {
        XCTAssertFalse(DictationController.resolveCleanup(
            globalEnabled: false, verbatimApps: [], frontmostBundleID: "com.apple.Notes"))
        XCTAssertFalse(DictationController.resolveCleanup(
            globalEnabled: false, verbatimApps: ["com.apple.notes"], frontmostBundleID: "com.apple.Notes"))
    }

    // Global on, app NOT in the verbatim set ⇒ cleanup runs.
    func testGlobalOnNonMemberCleansUp() {
        XCTAssertTrue(DictationController.resolveCleanup(
            globalEnabled: true, verbatimApps: ["com.apple.dt.xcode"], frontmostBundleID: "com.apple.Notes"))
    }

    // Membership ⇒ verbatim bypass (cleanup:false), matched case-insensitively:
    // stored lowercased, frontmost reported mixed-case → still a hit.
    func testMembershipBypassesCaseInsensitively() {
        let verbatim: Set<String> = ["com.apple.dt.xcode"]
        XCTAssertFalse(DictationController.resolveCleanup(
            globalEnabled: true, verbatimApps: verbatim, frontmostBundleID: "com.apple.dt.Xcode"))
        XCTAssertFalse(DictationController.resolveCleanup(
            globalEnabled: true, verbatimApps: verbatim, frontmostBundleID: "COM.APPLE.DT.XCODE"))
        XCTAssertFalse(DictationController.resolveCleanup(
            globalEnabled: true, verbatimApps: verbatim, frontmostBundleID: "com.apple.dt.xcode"))
    }

    // Unknown app (nil or empty id) ⇒ the global (on) behavior, never a crash.
    func testUnknownAppFallsBackToGlobalOn() {
        XCTAssertTrue(DictationController.resolveCleanup(
            globalEnabled: true, verbatimApps: ["com.apple.notes"], frontmostBundleID: nil))
        XCTAssertTrue(DictationController.resolveCleanup(
            globalEnabled: true, verbatimApps: ["com.apple.notes"], frontmostBundleID: ""))
    }

    // Empty verbatim set ⇒ cleanup everywhere (global on).
    func testEmptyVerbatimSetCleansUp() {
        XCTAssertTrue(DictationController.resolveCleanup(
            globalEnabled: true, verbatimApps: [], frontmostBundleID: "com.apple.Notes"))
    }

    // The instance seam: frontmostBundleID is injectable, and its result feeds
    // resolveCleanup exactly as the release path does. Proves the wiring, not
    // just the pure function.
    @MainActor
    func testInstanceFrontmostSeamFeedsResolution() {
        let controller = DictationController(appState: AppState())
        controller.cleanupEnabled = true
        controller.verbatimApps = ["com.apple.dt.xcode"]

        controller.frontmostBundleID = { "com.apple.dt.Xcode" }   // verbatim app
        XCTAssertFalse(DictationController.resolveCleanup(
            globalEnabled: controller.cleanupEnabled,
            verbatimApps: controller.verbatimApps,
            frontmostBundleID: controller.frontmostBundleID()))

        controller.frontmostBundleID = { "com.apple.Notes" }      // other app
        XCTAssertTrue(DictationController.resolveCleanup(
            globalEnabled: controller.cleanupEnabled,
            verbatimApps: controller.verbatimApps,
            frontmostBundleID: controller.frontmostBundleID()))
    }
}
