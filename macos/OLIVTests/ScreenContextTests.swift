// Names on screen: the Accessibility walker's caps and skips against fake
// trees, the press→release capture handoff, the capture policy, and the wire
// (local Rust worker only, never the OLIV API). Hermetic: no real AX calls.
import XCTest
@testable import OLIV

/// A fake Accessibility node.
final class FakeScreenNode: ScreenNode {
    let info: ScreenNodeInfo
    let kids: [FakeScreenNode]
    private(set) var reads = 0

    init(_ role: String, _ texts: [String] = [], subrole: String? = nil, _ kids: [FakeScreenNode] = []) {
        info = ScreenNodeInfo(role: role, subrole: subrole, texts: texts)
        self.kids = kids
    }

    func read() -> ScreenNodeInfo { reads += 1; return info }
    func children() -> [ScreenNode] { kids }
}

final class ScreenContextTests: XCTestCase {
    private func text(_ s: String) -> FakeScreenNode { FakeScreenNode("AXStaticText", [s]) }

    // MARK: Walker

    func testReadsTextInReadingOrder() {
        let window = FakeScreenNode("AXWindow", ["Acme — Slack"], [
            FakeScreenNode("AXGroup", [], [text("Kittiphan Wongsawat"), text("ส่งไฟล์ให้แล้วครับ")]),
            FakeScreenNode("AXTextArea", ["Thanks Kittiphan,"]),
        ])
        let result = ScreenTextWalker.collect(from: window)
        XCTAssertEqual(result.snippets,
                       ["Acme — Slack", "Kittiphan Wongsawat", "ส่งไฟล์ให้แล้วครับ", "Thanks Kittiphan,"])
        XCTAssertEqual(result.nodes, 5)
        XCTAssertNil(result.stopped)
    }

    func testSkipsPasswordFieldsMenusAndControls() {
        let secret = text("hunter2-in-a-child")
        let secure = FakeScreenNode("AXSecureTextField", ["hunter2"], [secret])
        let secureSubrole = FakeScreenNode("AXTextField", ["s3cret"], subrole: "AXSecureTextField")
        let menu = FakeScreenNode("AXMenu", [], [text("Open Recent")])
        let button = FakeScreenNode("AXButton", ["Send"], [text("inside a button")])
        let window = FakeScreenNode("AXWindow", [], [secure, secureSubrole, menu, button, text("Somchai")])
        let result = ScreenTextWalker.collect(from: window)
        XCTAssertEqual(result.snippets, ["Somchai"])
        XCTAssertEqual(secret.reads, 0, "a password field's subtree is never read")
    }

    func testStopsAtTheNodeCap() {
        let window = FakeScreenNode("AXWindow", [], (0..<5_000).map { text("Name\($0)") })
        var limits = ScreenTextLimits()
        limits.maxNodes = 100
        let result = ScreenTextWalker.collect(from: window, limits: limits)
        XCTAssertEqual(result.nodes, 100)
        XCTAssertEqual(result.snippets.count, 99)
        XCTAssertEqual(result.stopped, .nodes)
    }

    func testStopsAtTheDepthCap() {
        var node = text("too deep")
        for depth in (0..<10).reversed() { node = FakeScreenNode("AXGroup", ["level \(depth)"], [node]) }
        var limits = ScreenTextLimits()
        limits.maxDepth = 3
        let result = ScreenTextWalker.collect(from: node, limits: limits)
        XCTAssertEqual(result.snippets, ["level 0", "level 1", "level 2", "level 3"])
    }

    func testCharacterCapsCountUnicodeScalarsLikeRust() {
        // ส่ง is three scalars in one grapheme: the caps count scalars.
        let window = FakeScreenNode("AXWindow", [], [
            text(String(repeating: "ส่ง", count: 10)), text("Grafana"), text("never read"),
        ])
        var limits = ScreenTextLimits()
        limits.maxChars = 34
        let result = ScreenTextWalker.collect(from: window, limits: limits)
        XCTAssertEqual(result.snippets.map { $0.unicodeScalars.count }, [30, 4])
        XCTAssertEqual(result.snippets.last, "Graf")
        XCTAssertEqual(result.stopped, .chars)
    }

    func testOneLongTextCannotCrowdOutTheRest() {
        let document = FakeScreenNode("AXTextArea", [String(repeating: "a", count: 10_000)])
        let result = ScreenTextWalker.collect(from: FakeScreenNode("AXWindow", [], [document, text("Somchai")]))
        XCTAssertEqual(result.snippets.first?.count, ScreenTextLimits().maxSnippetChars)
        XCTAssertEqual(result.snippets.last, "Somchai")
    }

    func testStopsAtTheSnippetCap() {
        let window = FakeScreenNode("AXWindow", [], (0..<20).map { text("Name\($0)") })
        var limits = ScreenTextLimits()
        limits.maxSnippets = 5
        let result = ScreenTextWalker.collect(from: window, limits: limits)
        XCTAssertEqual(result.snippets.count, 5)
        XCTAssertEqual(result.stopped, .snippets)
    }

    func testStopsAtTheTimeBudgetKeepingWhatItRead() {
        // A slow app: every node costs 10 ms of the 250 ms budget.
        var clock: TimeInterval = 0
        let window = FakeScreenNode("AXWindow", [], (0..<1_000).map { text("Name\($0)") })
        let result = ScreenTextWalker.collect(from: window, now: { clock += 0.010; return clock })
        XCTAssertEqual(result.stopped, .budget)
        XCTAssertLessThan(result.nodes, 30)
        XCTAssertFalse(result.snippets.isEmpty)
    }

    func testStopsWhenCancelled() {
        var checks = 0
        let window = FakeScreenNode("AXWindow", [], (0..<100).map { text("Name\($0)") })
        let result = ScreenTextWalker.collect(from: window, isCancelled: { checks += 1; return checks > 3 })
        XCTAssertEqual(result.stopped, .cancelled)
        XCTAssertEqual(result.nodes, 3)
    }

    /// The walker's own cost on a large synthetic window (2,000 nodes, the
    /// node cap): far inside the budget, so the budget is spent on the app's
    /// Accessibility replies, not here.
    func testWalkerOverheadOnALargeWindowIsSmall() {
        let rows = (0..<400).map { i in
            FakeScreenNode("AXRow", [], [
                FakeScreenNode("AXImage", ["Avatar of Person \(i)"]),
                text("Person \(i) Saelee"), text("10:\(i % 60) AM"),
                text("ส่งไฟล์ Figma ให้แล้วนะครับ เดี๋ยวบ่ายนี้ประชุมต่อ \(i)"),
            ])
        }
        let window = FakeScreenNode("AXWindow", ["Acme"], rows)
        // Text caps lifted so the walk reaches the node cap.
        var limits = ScreenTextLimits()
        limits.maxSnippets = .max
        limits.maxChars = .max
        let start = ProcessInfo.processInfo.systemUptime
        let result = ScreenTextWalker.collect(from: window, limits: limits)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(result.nodes, limits.maxNodes)
        XCTAssertEqual(result.stopped, .nodes)
        XCTAssertLessThan(elapsed, limits.budget)
    }

    // MARK: Press → release handoff

    func testTakeReturnsAFinishedWalkOnce() {
        let queue = DispatchQueue(label: "test.screen")
        let capture = ScreenContextCapture.start(queue: queue) {
            FakeScreenNode("AXWindow", ["Kittiphan"])
        }
        queue.sync {}
        XCTAssertEqual(capture.take(), ["Kittiphan"])
        XCTAssertNil(capture.take(), "one-shot: the text is released")
    }

    func testAnUnfinishedWalkIsDroppedAtRelease() {
        let queue = DispatchQueue(label: "test.screen")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let capture = ScreenContextCapture.start(queue: queue) {
            entered.signal()
            release.wait()   // an app slow to answer
            return FakeScreenNode("AXWindow", ["Kittiphan"])
        }
        entered.wait()
        XCTAssertNil(capture.take(), "not ready at release: this dictation goes without")
        release.signal()
        queue.sync {}
        XCTAssertNil(capture.take(), "a late finish is discarded")
    }

    func testCancelDiscards() {
        let queue = DispatchQueue(label: "test.screen")
        let capture = ScreenContextCapture.start(queue: queue) { FakeScreenNode("AXWindow", ["Kittiphan"]) }
        queue.sync {}
        capture.cancel()
        XCTAssertNil(capture.take())
    }

    func testNoWindowIsAnEmptyList() {
        let queue = DispatchQueue(label: "test.screen")
        let capture = ScreenContextCapture.start(queue: queue) { nil }
        queue.sync {}
        XCTAssertEqual(capture.take(), [])
    }

    // MARK: Policy

    private func allowed(enabled: Bool = true, engine: String = SidecarClient.defaultEngine,
                         cleanup: Bool = true, app: String? = "com.tinyspeck.slackmacgap",
                         trusted: Bool = true, secure: Bool = false) -> Bool {
        ScreenContext.shouldCapture(enabled: enabled, engine: engine, cleanup: cleanup,
                                    frontmostBundleID: app, ownBundleID: "com.oliv.app",
                                    accessibilityTrusted: trusted, secureInput: secure)
    }

    func testCapturesOnlyWhenOptedInWithOnDeviceCleanup() {
        XCTAssertTrue(allowed())
        XCTAssertTrue(allowed(engine: "groq-large-v3"), "Groq: the text pipeline still runs on this Mac")
        XCTAssertFalse(allowed(enabled: false), "opt-in")
        XCTAssertFalse(allowed(engine: OLIVAPIClient.engineID), "the server runs cleanup: never read the screen")
        XCTAssertFalse(allowed(cleanup: false), "cleanup off or a verbatim app")
    }

    func testSkipsPasswordManagersOLIVSecureInputAndMissingAccess() {
        for app in ["com.1password.1password", "com.apple.Passwords", "com.bitwarden.desktop",
                    "com.apple.keychainaccess"] {
            XCTAssertFalse(allowed(app: app), app)
        }
        XCTAssertFalse(allowed(app: "com.oliv.app"))
        XCTAssertFalse(allowed(app: nil), "unknown app")
        XCTAssertFalse(allowed(trusted: false))
        XCTAssertFalse(allowed(secure: true), "a password field is active")
    }

    func testVerbatimAppsResolveToNoCleanup() {
        let verbatim: Set<String> = ["com.apple.terminal"]
        XCTAssertFalse(DictationController.resolveCleanup(globalEnabled: true, verbatimApps: verbatim,
                                                         frontmostBundleID: "com.apple.Terminal"))
    }

    // MARK: Setting

    @MainActor
    func testTheSettingIsOffByDefaultAndPersists() {
        let suite = "oliv.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = OLIVSettings(defaults: defaults, keychain: InMemoryKeychain())
        XCTAssertFalse(settings.screenNames, "opt-in")
        var changed = 0
        settings.onChange = { changed += 1 }
        settings.screenNames = true
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(OLIVSettings(defaults: defaults, keychain: InMemoryKeychain()).screenNames)
    }

    // MARK: Wire

    func testLocalBodyCarriesScreenTextOnlyWithCleanup() {
        let on = SidecarClient.dictateBody(engine: SidecarClient.defaultEngine, pcmB64: "", cleanup: true,
                                           screenText: ["Kittiphan"])
        XCTAssertEqual(on["screen_text"] as? [String], ["Kittiphan"])
        let off = SidecarClient.dictateBody(engine: SidecarClient.defaultEngine, pcmB64: "", cleanup: false,
                                            screenText: ["Kittiphan"])
        XCTAssertNil(off["screen_text"])
        let none = SidecarClient.dictateBody(engine: SidecarClient.defaultEngine, pcmB64: "", cleanup: true)
        XCTAssertNil(none["screen_text"], "defaults dictate stays byte-identical")
    }

    func testRemoteBodyNeverCarriesScreenText() throws {
        var options = DictationOptions(cleanup: true)
        options.screenText = ["Kittiphan Wongsawat", "ส่งไฟล์ให้แล้ว"]
        let data = try OLIVAPIClient.requestBody(samples: [0], options: options)
        let wire = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(wire.contains("Kittiphan"))
        XCTAssertFalse(wire.contains("screen"))
    }
}
