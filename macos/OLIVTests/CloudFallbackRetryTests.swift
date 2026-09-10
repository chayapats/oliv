// Cloud→local retry tests (W3-T4). DictationController.dictateWithFallback is a
// pure function over an injected `dictate` closure, so we drive the fallback
// logic hermetically with a FAKE seam — no real sidecar, no models. The
// invariant: a failed dictate on the opt-in Groq CLOUD engine retries ONCE on
// the local default; any other engine's failure is dropped without a retry.

import AppKit
import XCTest
@testable import OLIV

final class CloudFallbackRetryTests: XCTestCase {
    private let cloud = SidecarClient.cloudEngine
    private let local = SidecarClient.defaultEngine

    // A DictationResult stand-in tagged by which engine produced it.
    private func result(_ tag: String) -> DictationResult {
        DictationResult(raw: tag, final: tag, tSTT: 0, tCleanup: 0,
                        llmRan: false, gateReason: "", guardrailFlag: "",
                        cleanupError: nil)
    }

    private enum Boom: Error { case fail }

    // Cloud fails → retry once on local → local's result is returned; the
    // fallback is logged and both engines were attempted, cloud first.
    func testCloudFailureFallsBackToLocalOnce() {
        var attempts: [String] = []
        var logs: [String] = []
        let out = DictationController.dictateWithFallback(
            engine: cloud, cleanup: true,
            dictate: { eng, _ in
                attempts.append(eng)
                if eng == self.cloud { throw Boom.fail }
                return self.result(eng)
            },
            log: { logs.append($0) })

        XCTAssertEqual(out?.final, local, "returns the local retry's transcript")
        XCTAssertEqual(attempts, [cloud, local], "cloud attempted first, then local once")
        XCTAssertTrue(logs.contains { $0.contains("falling back to local") },
                      "the fallback is logged")
    }

    // Cloud succeeds → no retry, no fallback log.
    func testCloudSuccessDoesNotRetry() {
        var attempts: [String] = []
        var logs: [String] = []
        let out = DictationController.dictateWithFallback(
            engine: cloud, cleanup: false,
            dictate: { eng, _ in attempts.append(eng); return self.result(eng) },
            log: { logs.append($0) })

        XCTAssertEqual(out?.final, cloud)
        XCTAssertEqual(attempts, [cloud], "no retry on success")
        XCTAssertTrue(logs.isEmpty)
    }

    // A LOCAL engine's failure is NOT retried (no cheaper fallback) → nil, one try.
    func testLocalFailureIsNotRetried() {
        var attempts: [String] = []
        let out = DictationController.dictateWithFallback(
            engine: local, cleanup: true,
            dictate: { eng, _ in attempts.append(eng); throw Boom.fail },
            log: { _ in })

        XCTAssertNil(out, "local failure drops the utterance")
        XCTAssertEqual(attempts, [local], "no fallback attempt for a local engine")
    }

    // Cloud fails AND the local fallback also fails → nil, both attempted.
    func testCloudThenLocalBothFailDropsUtterance() {
        var attempts: [String] = []
        var logs: [String] = []
        let out = DictationController.dictateWithFallback(
            engine: cloud, cleanup: true,
            dictate: { eng, _ in attempts.append(eng); throw Boom.fail },
            log: { logs.append($0) })

        XCTAssertNil(out)
        XCTAssertEqual(attempts, [cloud, local])
        XCTAssertTrue(logs.contains { $0.contains("also failed") },
                      "the local fallback failure is logged")
    }

    // D3: the Thai-format post-pass flag must be gated on the SAME effective-cleanup
    // bool each dictate attempt receives. With the setting ON but effective cleanup
    // FALSE (a verbatim app / global cleanup off), thaiFormat must be false on EVERY
    // attempt — the cloud try AND the local fallback try. We drive dictateWithFallback
    // so BOTH attempts run (cloud throws → local retry) and record what the release
    // closure would send for `thai_format` on each. This FAILS if the `&& cl` gate in
    // effectiveThaiFormat is deleted (it would then send true on a cleanup-off dictate,
    // reformatting a transcript the user asked to keep byte-for-byte).
    func testThaiFormatGatedOffWhenCleanupIneffective() {
        let setting = true                       // Settings toggle ON
        var sent: [Bool] = []
        _ = DictationController.dictateWithFallback(
            engine: cloud, cleanup: false,       // effective cleanup FALSE (verbatim/off)
            dictate: { eng, cl in
                sent.append(DictationController.effectiveThaiFormat(setting: setting, cleanup: cl))
                if eng == self.cloud { throw Boom.fail }   // force the local fallback
                return self.result(eng)
            },
            log: { _ in })

        XCTAssertEqual(sent, [false, false],
                       "thaiFormat must be false on BOTH the cloud and local attempts when cleanup is off")
    }

    // Positive control: with the setting ON and effective cleanup TRUE the flag DOES
    // pass through — proving the gate lets a real formatting dictate reach the sidecar.
    func testThaiFormatPassesThroughWhenCleanupEffective() {
        var sent: [Bool] = []
        _ = DictationController.dictateWithFallback(
            engine: local, cleanup: true,
            dictate: { eng, cl in
                sent.append(DictationController.effectiveThaiFormat(setting: true, cleanup: cl))
                return self.result(eng)
            },
            log: { _ in })

        XCTAssertEqual(sent, [true], "thaiFormat passes through when cleanup is effective")
    }

    // D3, the complementary operand: with the Settings toggle OFF but effective
    // cleanup TRUE (an ordinary cleaned dictate — the user just never enabled
    // Thai-format), thaiFormat must be FALSE on EVERY attempt: the cloud try AND the
    // local fallback try. This guards the `setting &&` half of the gate that the
    // other tests (which hard-code setting=true) can't see. It FAILS if the gate body
    // is mutated to `return cleanup` — that would leave the Settings toggle
    // ineffective and reformat a normally-cleaned transcript the user didn't opt into.
    func testThaiFormatGatedOffWhenSettingDisabled() {
        let setting = false                      // Settings toggle OFF
        var sent: [Bool] = []
        _ = DictationController.dictateWithFallback(
            engine: cloud, cleanup: true,        // effective cleanup TRUE (normal clean)
            dictate: { eng, cl in
                sent.append(DictationController.effectiveThaiFormat(setting: setting, cleanup: cl))
                if eng == self.cloud { throw Boom.fail }   // force the local fallback
                return self.result(eng)
            },
            log: { _ in })

        XCTAssertEqual(sent, [false, false],
                       "thaiFormat must be false on BOTH the cloud and local attempts when the Settings toggle is off")
    }

    // A2: the release worker's paste-outcome classifier. A successfully
    // synthesized Cmd+V is .pastedOK (→ HUD hides); a usedFallback inject (here
    // forced via secure input, with Accessibility granted) is .pasteNeedsManual
    // (→ HUD tells the user to ⌘V). Hermetic: a uniquely-named pasteboard + faked
    // access/secure-input seams, so no real keys are posted.
    func testPasteOutcomeClassifiesFallback() {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.oliv.test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }

        let ok = TextInjector(pasteboard: pb)
        ok.postAccessCheck = { true }
        ok.secureInputCheck = { false }
        ok.cmdVPoster = { true }
        XCTAssertEqual(DictationController.paste("hello", with: ok), .pastedOK)

        let fallback = TextInjector(pasteboard: pb)
        fallback.postAccessCheck = { true }
        fallback.secureInputCheck = { true }   // password field → can't synthesize
        fallback.cmdVPoster = { true }
        XCTAssertEqual(DictationController.paste("secret note", with: fallback), .pasteNeedsManual)
    }
}
