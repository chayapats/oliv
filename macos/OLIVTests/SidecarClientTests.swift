// Hermetic IPC tests use a native Rust fixture; no models or credentials.
import XCTest
@testable import OLIV

final class SidecarClientTests: XCTestCase {
    private var executable: String!
    override func setUpWithError() throws {
        executable = try NativeTestSupport.executable()
    }
    private func makeClient() -> SidecarClient {
        SidecarClient(command: [executable, "sidecar"])
    }

    // Happy dictate round-trip: final/raw/timings/flags decode correctly.
    // Defaults (removeFillers off, no replacements) → both flags omitted on the
    // wire, so the echoed counts come back 0.
    func testHappyDictateRoundTrip() throws {
        let client = makeClient()
        defer { client.close() }
        let result = try client.dictate(samples: [0.0, 0.1, -0.1, 0.2], cleanup: true)
        XCTAssertEqual(result.raw, "hello world")
        XCTAssertEqual(result.final, "Hello world.")
        XCTAssertEqual(result.tSTT, 0.012, accuracy: 1e-9)
        XCTAssertEqual(result.tCleanup, 0.003, accuracy: 1e-9)
        XCTAssertTrue(result.llmRan)
        XCTAssertEqual(result.gateReason, "dict-hit")
        XCTAssertEqual(result.guardrailFlag, "ok")
        XCTAssertNil(result.cleanupError)
        XCTAssertEqual(result.fillersRemoved, 0, "remove_fillers omitted by default")
        XCTAssertEqual(result.replacementsFired, 0, "no replacements table by default")
        XCTAssertEqual(result.formatCommandsFired, 0, "vocabulary + format_commands omitted by default")
        XCTAssertEqual(result.thaiFormatFired, 0, "thai_format omitted by default")
    }

    // Thai-format payload construction: thaiFormat is omitted-when-default (the
    // happy round-trip above proves the 0 case) and sent only when on. The fake
    // echoes a 5 sentinel into thai_format_fired iff the request carried the flag.
    func testDictateSendsThaiFormatFlag() throws {
        let client = makeClient()
        defer { client.close() }
        let result = try client.dictate(
            samples: [0.0, 0.1], cleanup: true, thaiFormat: true)
        XCTAssertEqual(result.thaiFormatFired, 5, "thai_format=true was sent")
    }

    // B3/B4 payload construction: a non-empty vocabulary list and formatCommands
    // are threaded into the request; the fake packs (vocab_count*10 + flag) into
    // format_commands_fired, so 3 terms + on == 31 proves both reached the wire.
    func testDictateSendsVocabularyAndFormatCommands() throws {
        let client = makeClient()
        defer { client.close() }
        let result = try client.dictate(
            samples: [0.0, 0.1], cleanup: true,
            vocabulary: ["Grafana", "คูเบอร์เนติส", "OLIV"], formatCommands: true)
        XCTAssertEqual(result.formatCommandsFired, 31,
                       "3 vocab terms (×10) + format_commands flag (1) were both sent")
    }

    // W4-T1 payload construction: removeFillers on and a non-empty replacements
    // table are threaded into the request; the fake echoes them back through the
    // count fields (7 = the remove_fillers sentinel, count = table size).
    func testDictateSendsFillerFlagAndReplacements() throws {
        let client = makeClient()
        defer { client.close() }
        let result = try client.dictate(
            samples: [0.0, 0.1], cleanup: true, removeFillers: true,
            replacements: ["อีเมลของผม": "me@example.com", "เบอร์ผม": "080"])
        XCTAssertEqual(result.fillersRemoved, 7, "remove_fillers=true was sent")
        XCTAssertEqual(result.replacementsFired, 2, "the 2-entry table was sent")
    }

    func testPingReturnsPID() throws {
        let client = makeClient()
        defer { client.close() }
        let pid = try client.ping()
        XCTAssertGreaterThan(pid, 0)
    }

    func testWarmReportsLoadTimes() throws {
        let client = makeClient()
        defer { client.close() }
        let warm = try client.warm(cleanup: true)
        XCTAssertEqual(warm.tSTTLoad, 0.5, accuracy: 1e-9)
        XCTAssertEqual(warm.tCleanupLoad, 0.25, accuracy: 1e-9)
    }

    // Option B: a default warm OMITS background_cleanup (omit-when-default idiom),
    // so the sidecar takes the sync path. The fake's sync-path sentinel (0.5/0.25)
    // — NOT the present-but-false sentinel (-1.0) — proves the key was omitted, not
    // sent as false; cleanup_warming is absent so cleanupWarming decodes false.
    func testWarmOmitsBackgroundFlagByDefault() throws {
        let client = makeClient()
        defer { client.close() }
        let warm = try client.warm(cleanup: true)
        XCTAssertEqual(warm.tSTTLoad, 0.5, accuracy: 1e-9)
        XCTAssertEqual(warm.tCleanupLoad, 0.25, accuracy: 1e-9,
                       "sync-path sentinel — key omitted, NOT sent as false (-1.0)")
        XCTAssertFalse(warm.cleanupWarming, "no background_cleanup key => not warming")
    }

    // Option B: warm(backgroundCleanup: true) sends background_cleanup == true, and
    // the async reply {t_stt_load, t_cleanup_load: 0.0, cleanup_warming: true}
    // parses to cleanupWarming == true with a zero cleanup-load time.
    func testWarmBackgroundCleanupAsync() throws {
        let client = makeClient()
        defer { client.close() }
        let warm = try client.warm(cleanup: true, backgroundCleanup: true)
        XCTAssertEqual(warm.tSTTLoad, 2.0, accuracy: 1e-9)
        XCTAssertEqual(warm.tCleanupLoad, 0.0, accuracy: 1e-9,
                       "async path does not time the (background) Gemma load")
        XCTAssertTrue(warm.cleanupWarming,
                      "background_cleanup=true => async warm reports cleanup_warming")
    }

    // Timeout → typed error → the child is killed → the next call respawns and
    // works (self-heal). The CleanupClient "kill + respawn on next call" rule.
    func testTimeoutKillsAndRespawnsOnNextCall() throws {
        let client = makeClient()
        defer { client.close() }

        let firstPID = try client.ping()
        XCTAssertGreaterThan(firstPID, 0)

        XCTAssertThrowsError(try client.exchange(["cmd": "hang"], timeout: 0.6)) { error in
            guard case SidecarError.timeout = error else {
                return XCTFail("expected SidecarError.timeout, got \(error)")
            }
        }
        XCTAssertFalse(client._isAliveForTests, "hung child should have been killed")

        let secondPID = try client.ping()   // respawns
        XCTAssertGreaterThan(secondPID, 0)
        XCTAssertNotEqual(secondPID, firstPID, "should be a fresh child after respawn")
    }

    // A garbage (non-JSON) line with no matching reply → the read drains it,
    // times out, throws, and self-heals on the next call.
    func testGarbageLineErrorsThenSelfHeals() throws {
        let client = makeClient()
        defer { client.close() }

        XCTAssertThrowsError(try client.exchange(["cmd": "garbage"], timeout: 0.6)) { error in
            guard case SidecarError.timeout = error else {
                return XCTFail("expected SidecarError.timeout, got \(error)")
            }
        }
        // Self-heal: the next call respawns and round-trips.
        XCTAssertGreaterThan(try client.ping(), 0)
    }

    // Stray/out-of-order lines (wrong id + a garbage line) before the real reply
    // are drained until the matching id arrives.
    func testStrayLinesAreTolerated() throws {
        let client = makeClient()
        defer { client.close() }
        let reply = try client.exchange(["cmd": "noise"], timeout: 3.0)
        XCTAssertEqual(reply["matched"] as? Bool, true)
    }

    // ok:false (e.g. STT failure) surfaces a typed error but does NOT kill the
    // sidecar — it stays alive and serves the next request.
    func testOkFalseDoesNotKillProcess() throws {
        let client = makeClient()
        defer { client.close() }
        let pid = try client.ping()

        XCTAssertThrowsError(try client.exchange(["cmd": "sttfail"], timeout: 3.0)) { error in
            guard case SidecarError.replyError = error else {
                return XCTFail("expected SidecarError.replyError, got \(error)")
            }
        }
        XCTAssertTrue(client._isAliveForTests, "ok:false must not kill the sidecar")
        XCTAssertEqual(try client.ping(), pid, "same child still serving after ok:false")
    }

    // close() reaps the child — no orphan left behind.
    func testCloseLeavesNoChild() throws {
        let client = makeClient()
        _ = try client.ping()   // spawn
        XCTAssertTrue(client._isAliveForTests)
        let pid = try XCTUnwrap(client._pidForTests)

        client.close()

        XCTAssertFalse(client._isAliveForTests)
        // kill(pid, 0) probes existence: -1/ESRCH means the process is gone.
        XCTAssertNotEqual(kill(pid, 0), 0, "child pid \(pid) should no longer exist")
    }

    // W3-T4: interim event lines (same id, carry "event") are surfaced to
    // onEvent and do NOT end the read — the final reply is still returned. This
    // is the download-progress drain: without it, the first progress line would
    // be mistaken for the reply.
    func testInterimEventsSurfacedBeforeFinalReply() throws {
        let client = makeClient()
        defer { client.close() }
        var pcts: [Int] = []
        let reply = try client.exchange(["cmd": "prog"], timeout: 3.0, onEvent: { event in
            if (event["event"] as? String) == "progress",
               let pct = (event["pct"] as? NSNumber)?.intValue {
                pcts.append(pct)
            }
        })
        XCTAssertEqual(pcts, [10, 90], "both interim progress events surfaced, in order")
        XCTAssertEqual(reply["done"] as? Bool, true, "final reply returned, not an interim line")
    }

    // Spawn failure (bad executable path) surfaces as a typed error, never a crash.
    func testSpawnFailureIsTyped() {
        let client = SidecarClient(command: ["/nonexistent/oliv/worker"])
        XCTAssertThrowsError(try client.ping()) { error in
            guard case SidecarError.notSpawned = error else {
                return XCTFail("expected SidecarError.notSpawned, got \(error)")
            }
        }
    }
}
