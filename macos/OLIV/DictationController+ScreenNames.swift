// Names on screen: start or drop this press's screen capture (ScreenContext).

import Foundation

extension DictationController {
    /// Start reading the focused window for this press when the policy
    /// allows (opted in, on-device cleanup in this app, not a password
    /// manager, Accessibility granted, no secure input). Returns at once.
    func startScreenCapture() {
        dropScreenCapture()
        guard screenNames else { return }
        let app = frontmostBundleID()
        let cleanup = Self.resolveCleanup(globalEnabled: cleanupEnabled, verbatimApps: verbatimApps,
                                          frontmostBundleID: app)
        guard ScreenContext.shouldCapture(
            enabled: screenNames, engine: sttEngine, cleanup: cleanup,
            frontmostBundleID: app, ownBundleID: Bundle.main.bundleIdentifier,
            accessibilityTrusted: ScreenContext.accessibilityTrusted(),
            secureInput: ScreenContext.secureInputActive()) else { return }
        screenCapture = ScreenContextCapture.start(root: ScreenContext.focusedWindow)
    }

    /// Stop and discard this press's capture (a cancelled or failed press).
    func dropScreenCapture() {
        screenCapture?.cancel()
        screenCapture = nil
    }
}
