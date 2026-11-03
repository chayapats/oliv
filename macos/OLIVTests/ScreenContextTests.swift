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
    /// Children handed out, and the largest batch asked for.
    private(set) var fetched = 0
    private(set) var largestAsk = 0

    init(_ role: String, _ texts: [String] = [], subrole: String? = nil, _ kids: [FakeScreenNode] = []) {
        info = ScreenNodeInfo(role: role, subrole: subrole, texts: texts)
        self.kids = kids
    }

    func read() -> ScreenNodeInfo { reads += 1; return info }
    func children(from index: Int, max: Int) -> [ScreenNode] {
        largestAsk = Swift.max(largestAsk, max)
        let batch = Array(kids.dropFirst(index).prefix(max))
        fetched += batch.count
        return batch
    }
}

/// Counts what `AXScreenNode.shownValue` asks the app for.
private final class ValueCalls {
    var visibleRange = 0
    var ranges: [Int] = []   // lengths asked of kAXStringForRange
    var values = 0
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
        let names = (0..<100).map { text("Name\($0)") }
        let window = FakeScreenNode("AXWindow", [], names)
        let result = ScreenTextWalker.collect(from: window, isCancelled: { names[1].reads > 0 })
        XCTAssertEqual(result.stopped, .cancelled)
        XCTAssertEqual(result.nodes, 3)
        XCTAssertEqual(names[2].reads, 0)
    }

    func testChildrenAreFetchedOnlyWithinTheNodeBudget() {
        // A list of 5,000: no more children leave the app than can be read.
        let window = FakeScreenNode("AXWindow", [], (0..<5_000).map { text("Name\($0)") })
        var limits = ScreenTextLimits()
        limits.maxNodes = 100
        let result = ScreenTextWalker.collect(from: window, limits: limits)
        XCTAssertEqual(result.nodes, 100)
        XCTAssertEqual(window.fetched, 99, "the root plus 99 children fill the budget")
        XCTAssertLessThanOrEqual(window.largestAsk, limits.childBatch)

        // Nested lists: children queued anywhere count against the budget.
        let rows = (0..<50).map { i in FakeScreenNode("AXRow", [], (0..<100).map { text("Person \(i)-\($0)") }) }
        let inbox = FakeScreenNode("AXWindow", [], rows)
        limits.maxNodes = 300
        let nested = ScreenTextWalker.collect(from: inbox, limits: limits)
        XCTAssertEqual(nested.nodes, 300)
        XCTAssertEqual(nested.stopped, .nodes)
        XCTAssertLessThanOrEqual(inbox.fetched + rows.reduce(0) { $0 + $1.fetched }, limits.maxNodes - 1)
        XCTAssertEqual(nested.snippets.prefix(3), ["Person 0-0", "Person 0-1", "Person 0-2"], "reading order")
    }

    func testStaticTextWithItsTextReadIsALeaf() {
        let inner = text("inline run")
        let label = FakeScreenNode("AXStaticText", ["Kittiphan"], [inner])
        let hollow = FakeScreenNode("AXStaticText", [], [text("Somchai")])
        let result = ScreenTextWalker.collect(from: FakeScreenNode("AXWindow", [], [label, hollow]))
        XCTAssertEqual(result.snippets, ["Kittiphan", "Somchai"])
        XCTAssertEqual(label.fetched, 0, "no children call for text already read")
        XCTAssertEqual(inner.reads, 0)
        XCTAssertEqual(hollow.fetched, 1, "static text without a value is still walked into")
    }

    func testNoChildrenAreFetchedOnceTheTimeBudgetIsSpent() {
        var clock: TimeInterval = 0
        let window = FakeScreenNode("AXWindow", [], (0..<5_000).map { text("Name\($0)") })
        let result = ScreenTextWalker.collect(from: window, now: { clock += 0.010; return clock })
        XCTAssertEqual(result.stopped, .budget)
        XCTAssertLessThanOrEqual(window.fetched, ScreenTextLimits().childBatch)
    }

    // MARK: What a node read copies out of the app

    private func shown(_ role: String, length: Int?, visible: CFRange?, calls: ValueCalls) -> String? {
        let document = String(repeating: "ก", count: 50_000)
        return AXScreenNode.shownValue(
            role: role, length: length, cap: 4_000,
            visibleRange: { calls.visibleRange += 1; return visible },
            string: { range in
                calls.ranges.append(range.length)
                return String(document.prefix(range.length))
            },
            value: { calls.values += 1; return document })
    }

    func testTheFirstReadNeverCopiesAValue() {
        XCTAssertFalse(AXScreenNode.attributes.contains(kAXValueAttribute as String),
                       "a text area's value is its whole document")
        XCTAssertEqual(AXScreenNode.maxValueChars, ScreenTextLimits().maxSnippetChars)
    }

    func testATextAreaGivesOnlyItsVisibleRange() {
        let scrolled = ValueCalls()
        let text = shown("AXTextArea", length: 1_000_000, visible: CFRange(location: 500_000, length: 2_000),
                         calls: scrolled)
        XCTAssertEqual(text?.count, 2_000)
        XCTAssertEqual(scrolled.values, 0, "the document is never copied")
        XCTAssertEqual(scrolled.ranges, [2_000])

        let tall = ValueCalls()   // more on screen than a snippet keeps
        _ = shown("AXTextArea", length: 1_000_000, visible: CFRange(location: 0, length: 50_000), calls: tall)
        XCTAssertEqual(tall.ranges, [4_000])
        XCTAssertEqual(tall.values, 0)
    }

    func testWithoutAVisibleRangeOnlyAShortTextAreaIsCopied() {
        let long = ValueCalls()
        XCTAssertNil(shown("AXTextArea", length: 1_000_000, visible: nil, calls: long))
        XCTAssertEqual(long.values, 0)
        let unknown = ValueCalls()
        XCTAssertNil(shown("AXTextArea", length: nil, visible: nil, calls: unknown))
        XCTAssertEqual(unknown.values, 0, "an unknown length could be a whole document")
        let short = ValueCalls()
        XCTAssertNotNil(shown("AXTextArea", length: 300, visible: nil, calls: short))
        XCTAssertEqual(short.values, 1)
    }

    func testOtherLongValuesAreCutBeforeTheyAreCopied() {
        let long = ValueCalls()
        XCTAssertEqual(shown("AXStaticText", length: 1_000_000, visible: nil, calls: long)?.count, 4_000)
        XCTAssertEqual(long.values, 0)
        XCTAssertEqual(long.ranges, [4_000])
        XCTAssertEqual(long.visibleRange, 0)
        let label = ValueCalls()
        XCTAssertNotNil(shown("AXStaticText", length: 12, visible: nil, calls: label))
        XCTAssertEqual(label.values, 1)
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
        let capture = ScreenContextCapture.start(queue: queue, approved: { true }) {
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
        let capture = ScreenContextCapture.start(queue: queue, approved: { true }) {
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
        let capture = ScreenContextCapture.start(queue: queue, approved: { true }) {
            FakeScreenNode("AXWindow", ["Kittiphan"])
        }
        queue.sync {}
        capture.cancel()
        XCTAssertNil(capture.take())
    }

    func testNoWindowIsAnEmptyList() {
        let queue = DispatchQueue(label: "test.screen")
        let capture = ScreenContextCapture.start(queue: queue, approved: { true }) { nil }
        queue.sync {}
        XCTAssertEqual(capture.take(), [])
    }

    func testNothingIsReadWhenTheApprovedAppLostFocusBeforeTheWalk() {
        let queue = DispatchQueue(label: "test.screen")
        let vault = FakeScreenNode("AXWindow", ["Vault — 1Password"])
        var looked = false
        let capture = ScreenContextCapture.start(queue: queue, approved: { false }) {
            looked = true
            return vault
        }
        queue.sync {}
        XCTAssertFalse(looked, "no window is looked up")
        XCTAssertEqual(vault.reads, 0)
        XCTAssertEqual(capture.take(), [])
    }

    func testWhatWasReadIsDiscardedWhenFocusMovesDuringTheWalk() {
        let queue = DispatchQueue(label: "test.screen")
        var asked = 0
        let window = FakeScreenNode("AXWindow", ["Kittiphan"])
        let capture = ScreenContextCapture.start(queue: queue, approved: { asked += 1; return asked == 1 }) {
            window
        }
        queue.sync {}
        XCTAssertEqual(window.reads, 1, "the walk ran")
        XCTAssertEqual(asked, 2, "asked again after the walk")
        XCTAssertEqual(capture.take(), [], "focus moved: nothing is kept")
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

    func testTextIsKeptOnlyWhileTheApprovedProcessHasFocus() {
        let slack = ScreenCaptureTarget(pid: 101, bundleID: "com.tinyspeck.slackmacgap")
        func kept(_ focused: ScreenCaptureTarget?, target: ScreenCaptureTarget = slack,
                  verbatim: Set<String> = []) -> Bool {
            ScreenContext.stillApproved(target, focused: focused, verbatimApps: verbatim, ownBundleID: "com.oliv.app")
        }
        XCTAssertTrue(kept(slack))
        XCTAssertTrue(kept(ScreenCaptureTarget(pid: 101, bundleID: "com.tinyspeck.SlackMacGap")))
        XCTAssertFalse(kept(ScreenCaptureTarget(pid: 202, bundleID: "com.1password.1password")),
                       "switched to a password manager")
        XCTAssertFalse(kept(ScreenCaptureTarget(pid: 303, bundleID: "com.tinyspeck.slackmacgap")), "another process")
        XCTAssertFalse(kept(ScreenCaptureTarget(pid: 101, bundleID: "com.apple.Passwords")), "a reused pid")
        XCTAssertFalse(kept(nil), "focus unknown")
        XCTAssertFalse(kept(slack, verbatim: ["com.tinyspeck.slackmacgap"]), "now a verbatim app")
        for skipped in ["com.bitwarden.desktop", "com.oliv.app"] {
            let app = ScreenCaptureTarget(pid: 404, bundleID: skipped)
            XCTAssertFalse(kept(app, target: app), skipped)
        }
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
