// Names on screen: start or drop this press's screen capture (ScreenContext).

import Foundation

extension DictationController {
    /// Start reading the focused window for this press when the policy
    /// allows (opted in, on-device cleanup in this app, not Command mode, not
    /// a password manager, Accessibility granted, no secure input). Returns
    /// at once; call it after `recordingMode` is set for this press.
    func startScreenCapture() {
        dropScreenCapture()
        guard screenNames, let target = ScreenContext.frontmostApp() else { return }
        let cleanup = Self.resolveCleanup(globalEnabled: cleanupEnabled, verbatimApps: verbatimApps,
                                          frontmostBundleID: target.bundleID)
        let ownBundleID = Bundle.main.bundleIdentifier
        guard ScreenContext.shouldCapture(
            enabled: screenNames, engine: sttEngine, mode: recordingMode, cleanup: cleanup,
            frontmostBundleID: target.bundleID, ownBundleID: ownBundleID,
            accessibilityTrusted: ScreenContext.accessibilityTrusted(),
            secureInput: ScreenContext.secureInputActive()) else { return }
        // The walk runs later, on its own queue: it reads only the approved
        // app's window (by process id), and keeps nothing unless that app
        // still has focus before and after it. Switching to a password
        // manager in between is never read.
        let verbatimApps = self.verbatimApps
        screenCapture = ScreenContextCapture.start(
            approved: {
                ScreenContext.stillApproved(target, focused: ScreenContext.focusedApp(),
                                            verbatimApps: verbatimApps, ownBundleID: ownBundleID)
            },
            root: { ScreenContext.focusedWindow(of: target) })
    }

    /// Stop and discard this press's capture (a cancelled or failed press).
    func dropScreenCapture() {
        screenCapture?.cancel()
        screenCapture = nil
    }
}
