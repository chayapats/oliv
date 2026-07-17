// SidecarClient tests (W3-T3) — hermetic, NO models, NO sidecar/.venv.
//
// The real sidecar loads mlx-whisper + Gemma-4 (~30s warm); that end-to-end
// proof is the Swift `--e2e-file` harness and the Python sidecar/test_sidecar.py.
// Here we drive SidecarClient against a tiny FAKE child that just speaks the
// line-JSON protocol, so we can exercise the robustness contract fast and
// deterministically: happy round-trip, timeout → typed error → respawn, garbage
// line → error + self-heal, stray/out-of-order line tolerance, ok:false without
// killing the process, and close() leaving no orphan.

import XCTest
@testable import OLIV

final class SidecarClientTests: XCTestCase {
    private var scriptPath: String!
    private var python: String!

    // A fake sidecar: reads line-JSON on stdin, answers per the protocol. Extra
    // `hang` / `garbage` / `noise` / `sttfail` commands drive the failure paths.
    private static let fakeScript = """
    import sys, os, json, time

    def send(obj):
        sys.stdout.write(json.dumps(obj) + "\\n")
        sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            send({"id": None, "ok": False, "error": "bad json"})
            continue
        rid = req.get("id")
        cmd = req.get("cmd")
        if cmd == "shutdown":
            break
        elif cmd == "ping":
            send({"id": rid, "ok": True, "pid": os.getpid()})
        elif cmd == "warm":
            # Option B wire contract. The client OMITS background_cleanup when false
            # (byte-compat) and sends true only on the async launch warm; reflect
            # KEY PRESENCE so the test can assert the omit-when-default idiom, and
            # mirror the real sidecar reply shapes (cleanup_warming only async).
            if req.get("background_cleanup"):
                send({"id": rid, "ok": True, "engine": req.get("engine"),
                      "t_stt_load": 2.0, "t_cleanup_load": 0.0, "cleanup_warming": True})
            elif "background_cleanup" in req:
                # present-but-false must NEVER happen from this client -> sentinel
                send({"id": rid, "ok": True, "engine": req.get("engine"),
                      "t_stt_load": -1.0, "t_cleanup_load": -1.0})
            else:
                # sync path, key omitted: byte-identical to the pre-Option-B reply
                send({"id": rid, "ok": True, "engine": req.get("engine"),
                      "t_stt_load": 0.5, "t_cleanup_load": 0.25})
        elif cmd == "dictate":
            # Echo the request shape back through the count fields so the test can
            # assert payload construction: remove_fillers only when the client
            # sends the flag (7 = sentinel), replacements_fired = the table size
            # (0 when omitted). B3/B4: pack the vocabulary length and the
            # format_commands flag into format_commands_fired as (len*10 + flag)
            # so ONE field proves both were threaded (0 when both omitted).
            rf = 7 if req.get("remove_fillers") else 0
            repl = len(req.get("replacements") or {})
            fmt = len(req.get("vocabulary") or []) * 10 + (1 if req.get("format_commands") else 0)
            # thai_format is omitted-when-default; echo 5 (sentinel) only when the
            # client sent the flag, so the test can assert payload construction.
            tf = 5 if req.get("thai_format") else 0
            send({"id": rid, "ok": True, "engine": req.get("engine"),
                  "raw": "hello world", "final": "Hello world.",
                  "t_stt": 0.012, "t_cleanup": 0.003, "llm_ran": True,
                  "gate_reason": "dict-hit", "guardrail_flag": "ok",
                  "cleanup_error": None,
                  "fillers_removed": rf, "replacements_fired": repl,
                  "format_commands_fired": fmt, "thai_format_fired": tf})
        elif cmd == "hang":
            time.sleep(30)
        elif cmd == "garbage":
            sys.stdout.write("this is not json at all\\n")
            sys.stdout.flush()
        elif cmd == "noise":
            send({"id": 999999, "ok": True, "stray": True})
            sys.stdout.write("garbage stray line\\n")
            sys.stdout.flush()
            send({"id": rid, "ok": True, "matched": True})
        elif cmd == "sttfail":
            send({"id": rid, "ok": False, "error": "STT backend exploded"})
        elif cmd == "prog":
            # Interim events (same id, carry "event") BEFORE the final reply —
            # the download progress shape. The client must surface these to
            # onEvent and keep reading for the real reply.
            send({"id": rid, "event": "progress", "repo": "r", "pct": 10})
            send({"id": rid, "event": "progress", "repo": "r", "pct": 90})
            send({"id": rid, "ok": True, "done": True})
        else:
            send({"id": rid, "ok": False, "error": "unknown cmd"})
    """

    override func setUpWithError() throws {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        guard let py = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("no python3 available to run the fake sidecar")
        }
        python = py
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oliv_fake_sidecar_\(UUID().uuidString).py")
        try Self.fakeScript.write(to: url, atomically: true, encoding: .utf8)
        scriptPath = url.path
    }

    override func tearDownWithError() throws {
        if let p = scriptPath { try? FileManager.default.removeItem(atPath: p) }
    }

    private func makeClient() -> SidecarClient {
        SidecarClient(command: [python, scriptPath])
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
        let client = SidecarClient(command: ["/nonexistent/oliv/python", scriptPath])
        XCTAssertThrowsError(try client.ping()) { error in
            guard case SidecarError.notSpawned = error else {
                return XCTFail("expected SidecarError.notSpawned, got \(error)")
            }
        }
    }
}
