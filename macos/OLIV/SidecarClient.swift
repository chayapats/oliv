// SidecarClient (W3-T3) — the app-side half of the STT+cleanup venv bridge.
//
// Wave-3 architecture: this Swift app owns all macOS integration and delegates
// BOTH heavy pipeline stages (STT + cleanup) to one bundled Python sidecar
// (sidecar/sidecar_server.py) spoken to over a line-oriented JSON stdio
// protocol. This is the Swift twin of app/cleanup.py's CleanupClient: same
// spawn-lazily / bounded-read / kill-and-respawn-on-trouble discipline, ported
// to Foundation Process + a reader Thread + an NSCondition line queue.
//
// Protocol (see sidecar/sidecar_server.py's module docstring — it IS the spec):
//   {"cmd":"ping"}                                   -> {"ok",pid}
//   {"cmd":"warm","engine","cleanup"}                -> {"ok",t_stt_load,t_cleanup_load}
//   {"cmd":"dictate","engine","cleanup","pcm_b64"}   -> {"ok",raw,final,t_stt,t_cleanup,...}
//   {"cmd":"shutdown"} | EOF on stdin                -> exit 0
// Every request carries a monotonically increasing "id" echoed back on the
// reply; the client matches replies by id and drains stray/out-of-order lines.
// The server's stdout carries ONLY protocol JSON (fd discipline enforced
// server-side); its stderr (mlx/HF chatter) we discard.
//
// ROBUSTNESS CONTRACT (ported verbatim in spirit from app/cleanup.py)
// ------------------------------------------------------------------
// Foundation's FileHandle reads block uninterruptibly, so a wedged sidecar
// would hang the app forever. Instead a reader Thread drains stdout into a
// bounded LineQueue and every request does a bounded get. A request that times
// out / hits EOF / sees a dead process leaves the sidecar in an unknown state,
// so we KILL it and RESPAWN on the next call (self-heal); the caller gets a
// typed SidecarError and never crashes. Requests are serialized over a single
// serial queue — the sidecar is single-threaded, one request in flight.
//
// FAILURE PHILOSOPHY (who loses what)
// -----------------------------------
// A cleanup failure is NOT a client-visible failure: the server degrades to
// final==raw with cleanup_error set and still replies ok:true, exactly like
// CleanupClient's "never lose/corrupt the transcript" guarantee — so dictate()
// returns success with cleanupError populated. Only comms failure (spawn /
// timeout / dead pipe / bad JSON) or an STT failure (ok:false) throws; on the
// Swift side the raw transcript lives inside the sidecar, so there is nothing
// to fall back to here — the caller drops the utterance (log, return to idle).

import Foundation

/// One dictate reply, decoded from the sidecar's JSON (see the docstring).
struct DictationResult {
    let raw: String
    let final: String
    let tSTT: Double
    let tCleanup: Double
    let llmRan: Bool
    let gateReason: String
    let guardrailFlag: String
    /// Server-side cleanup degrade reason (final == raw). nil when cleanup ran
    /// clean or was disabled. Informational only — NOT a client failure.
    let cleanupError: String?
    /// W4-T1 counts (informational): filler tokens stripped pre-cleanup, and
    /// user replacement snippets fired in the final pass. 0 when the feature was
    /// off / nothing matched. Defaulted so callers/tests that don't care (and
    /// older reply shapes) construct/decode unchanged.
    var fillersRemoved: Int = 0
    var replacementsFired: Int = 0
    /// B4 count (informational): spoken formatting commands (new line / paragraph
    /// / bullet) that fired. 0 when the feature was off / nothing matched.
    var formatCommandsFired: Int = 0
    /// Thai-format count (informational): reduplication collapses + converted
    /// number runs from the deterministic post-pass. 0 when the feature was off /
    /// nothing matched (also 0 decoded from an older sidecar that omits the key).
    var thaiFormatFired: Int = 0
}

/// What `warm` reports back (model load times, seconds).
struct WarmResult {
    let tSTTLoad: Double
    let tCleanupLoad: Double
    /// True when the sidecar took the async background-cleanup path (Option B):
    /// STT loaded synchronously and warm returned immediately, with Gemma still
    /// loading on a daemon thread. `tCleanupLoad` is 0.0 in that case (the load is
    /// not timed into the reply). Defaults false, so an absent key — the sync path,
    /// cleanup disabled, or an older sidecar — decodes as false. Informational: the
    /// caller may ignore it (used only so the warm NSLog isn't a misleading 0.0s).
    var cleanupWarming: Bool = false
}

/// Outcome of a `download` (W3-T4 first-run onboarding / Settings model fetch).
/// `ok == false` names the first repo that failed (the sidecar stops there);
/// `downloaded` is whatever finished before that. NOT a comms failure — the
/// sidecar stays alive, so this comes back as a value, never a throw.
struct DownloadResult {
    let ok: Bool
    let downloaded: [String]
    let failedRepo: String?
    let error: String?
}

/// Every SidecarClient failure surfaces as one of these so the caller can turn
/// it into "drop utterance gracefully" without crashing. Mirrors the reasons
/// CleanupClient folds into `used_fallback`.
enum SidecarError: Error, CustomStringConvertible {
    /// The child could not be spawned (venv/script missing, exec failed).
    case notSpawned(String)
    /// Bounded read expired or the sidecar died mid-request → killed, will
    /// respawn on the next call.
    case timeout(String)
    /// Write to a dead pipe → killed, will respawn.
    case processDied(String)
    /// The sidecar replied ok:false (e.g. STT failed). Process stays alive.
    case replyError(String)

    var description: String {
        switch self {
        case let .notSpawned(m): return "sidecar not spawned: \(m)"
        case let .timeout(m): return "sidecar timeout: \(m)"
        case let .processDied(m): return "sidecar process died: \(m)"
        case let .replyError(m): return "sidecar returned an error: \(m)"
        }
    }
}

final class SidecarClient {
    static let defaultEngine = "typhoon-turbo-mlx"
    /// The opt-in CLOUD engine id (W3-T4). Named here so the controller's
    /// cloud→local fallback and the settings gating share one source of truth.
    static let cloudEngine = "groq-large-v3"

    // Bounded read budgets. warm is LONG (model loads + first-run HF downloads
    // are slow — the sidecar's warm front-loads both stages); dictate is the
    // per-utterance ceiling; ping is a fast liveness probe.
    static let warmTimeout: TimeInterval = 120.0
    static let dictateTimeout: TimeInterval = 30.0
    static let pingTimeout: TimeInterval = 5.0
    // download is a first-run model fetch (multi-GB over the network); treat the
    // timeout as an INACTIVITY watchdog rather than a hard ceiling — readReply
    // resets the deadline on every interim progress line, so a slow-but-alive
    // download runs as long as it keeps making progress, and only a genuine
    // 30-minute stall trips the timeout.
    static let downloadTimeout: TimeInterval = 1800.0

    private let command: [String]     // [executable, args...]
    // Extra environment for the child, merged over the inherited env (nil =
    // inherit only). W3-T4 uses this to point the BUNDLED sidecar at an
    // app-owned HF_HOME + OLIV_ROOT; dev spawns pass nil (inherit → default
    // HF cache, so dev e2e reuses already-downloaded models).
    private let environment: [String: String]?
    let engine: String

    // All of these are touched ONLY on `requestQueue` (spawn / forceKill /
    // writeLine / readReply run inside a queued transaction), so no lock is
    // needed beyond the queue itself.
    // userInitiated: the user is holding the key waiting on their transcript.
    // Matching QoS on the reader Thread keeps the request→reply chain free of
    // priority inversions.
    private let requestQueue = DispatchQueue(label: "com.oliv.sidecar.requests", qos: .userInitiated)
    private var proc: Process?
    private var stdinHandle: FileHandle?
    private var stdoutPipe: Pipe?
    // Fresh per spawn so a respawn can never read a dead child's leftover lines
    // (the CleanupClient "fresh queue per process" rule).
    private var lineQueue = LineQueue()
    private var reqID = 0

    // W3-T4 cloud fallback: the opt-in Groq API key injected into the child's
    // env as GROQ_API_KEY when the toggle is on (nil = not injected, local-only).
    // Touched only on requestQueue (read in spawn, written via setGroqAPIKey).
    private var groqAPIKey: String?

    // MARK: Init / root resolution

    /// Designated init — spawns `command[0]` with the rest as arguments, with
    /// `environment` merged over the inherited env. Tests point this at a
    /// scripted fake child; production uses the convenience init.
    init(
        command: [String],
        environment: [String: String]? = nil,
        engine: String = SidecarClient.defaultEngine
    ) {
        self.command = command
        self.environment = environment
        self.engine = engine
    }

    /// Dev/prod init: resolves the bundled runtime if the .app ships one, else
    /// the dev repo venv (see `resolveLaunch()`). This is what the app and the
    /// `--e2e-file` harness construct.
    convenience init(engine: String = SidecarClient.defaultEngine) {
        let launch = SidecarClient.resolveLaunch()
        self.init(command: launch.command, environment: launch.environment, engine: engine)
    }

    /// How a production sidecar is launched: the python+script command, any
    /// extra env, the OLIV_ROOT it resolves to, and whether it came from the
    /// packaged bundle (vs the dev repo). `bundled` is surfaced so the e2e
    /// harness can print which runtime it used.
    struct Launch {
        let command: [String]               // [python, sidecar_server.py]
        let environment: [String: String]?  // extra env merged over inherited
        let root: String                    // OLIV_ROOT
        let bundled: Bool
    }

    /// Resolve the sidecar launch config (W3-T4 packaging). Order:
    ///   (1) BUNDLED: if `Resources/oliv-runtime` ships inside the .app, run
    ///       its embedded CPython on the staged source tree, with OLIV_ROOT =
    ///       oliv-runtime/root and HF_HOME = ~/Library/Application Support/
    ///       OLIV/models (created here) so model storage is app-owned;
    ///   (2) DEV fallback: the repo's `sidecar/.venv` python + repo root, no env
    ///       override (inherits the default HF cache so dev e2e reuses models).
    static func resolveLaunch() -> Launch {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let runtime = res.appendingPathComponent("oliv-runtime")
            let python = runtime.appendingPathComponent("python/bin/python3")
            let root = runtime.appendingPathComponent("root")
            let script = root.appendingPathComponent("sidecar/sidecar_server.py")
            if fm.fileExists(atPath: python.path), fm.fileExists(atPath: script.path) {
                let models = SidecarClient.bundledModelsDir()
                try? fm.createDirectory(atPath: models, withIntermediateDirectories: true)
                // PYTHONDONTWRITEBYTECODE keeps the sidecar from writing __pycache__
                // into the code-signed runtime on first import — that would break
                // the bundle's seal (and later notarization). Imports run from .py.
                let env = ["OLIV_ROOT": root.path,
                           "HF_HOME": models,
                           "PYTHONDONTWRITEBYTECODE": "1"]
                return Launch(command: [python.path, script.path],
                              environment: env, root: root.path, bundled: true)
            }
        }
        let devRoot = SidecarClient.defaultDevRoot()
        return Launch(command: [devRoot + "/sidecar/.venv/bin/python",
                                devRoot + "/sidecar/sidecar_server.py"],
                      environment: nil, root: devRoot, bundled: false)
    }

    /// App-owned model store: ~/Library/Application Support/OLIV/models. Used
    /// as HF_HOME for the bundled sidecar so downloads never touch the dev cache.
    static func bundledModelsDir() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OLIV/models").path
    }

    /// The HF_HOME the sidecar will actually read/write, mirroring
    /// `resolveLaunch()`'s environment so onboarding/Settings check the SAME
    /// place the sidecar downloads into (W3-T4): bundled → the app-owned models
    /// dir; dev → $HF_HOME if set, else the default ~/.cache/huggingface. Repos
    /// live under `<home>/hub/models--<org>--<name>` (the HF hub cache layout).
    /// Exposed here (not duplicated in the UI) so there is one source of truth.
    static func modelsHome() -> String {
        let launch = resolveLaunch()
        if let hf = launch.environment?["HF_HOME"], !hf.isEmpty { return hf }
        if let env = ProcessInfo.processInfo.environment["HF_HOME"], !env.isEmpty { return env }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface").path
    }

    /// On-disk cache directory for one repo id inside `modelsHome()`:
    /// `<home>/hub/models--<org>--<name>`. Existence + materialized weights ==
    /// present (the presence/size walk lives in ModelState).
    static func repoCacheDir(_ repo: String) -> String {
        let dirName = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        return (modelsHome() as NSString).appendingPathComponent("hub/\(dirName)")
    }

    /// Locate the repo root for a DEV build (the fallback when no bundled runtime
    /// is present). Order: OLIV_DEV_ROOT env override, else derive from this
    /// source file's compiled-in path (…/macos/OLIV/SidecarClient.swift → up 3
    /// = repo root).
    static func defaultDevRoot() -> String {
        if let env = ProcessInfo.processInfo.environment["OLIV_DEV_ROOT"],
           !env.isEmpty {
            return env
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OLIV/
            .deletingLastPathComponent()   // macos/
            .deletingLastPathComponent()   // repo root
            .path
    }

    deinit {
        // Never orphan the child (also the app-quit guard: even if this never
        // runs, the sidecar exits on stdin EOF when our end of the pipe closes).
        requestQueue.sync { self.forceKill() }
    }

    // MARK: Public API

    /// Front-load both stages so the first real dictate is warm. LONG timeout.
    /// Throws on any comms failure (non-fatal to the caller — cleanup/STT just
    /// load lazily on the first dictate instead).
    @discardableResult
    func warm(engine: String? = nil, cleanup: Bool,
              backgroundCleanup: Bool = false) throws -> WarmResult {
        var body: [String: Any] = [
            "cmd": "warm",
            "engine": engine ?? self.engine,
            "cleanup": cleanup,
        ]
        // Omit-when-default (like thai_format / remove_fillers / vocabulary): the
        // key is absent unless the caller opts in, so a default warm is byte-
        // identical on the wire to the pre-Option-B request (eval / CLI / OLIVMain
        // stay fully synchronous). Option B: the launch warm (DictationController)
        // passes true so warm returns after STT while Gemma loads in the background.
        if backgroundCleanup { body["background_cleanup"] = true }
        let reply = try exchange(body, timeout: SidecarClient.warmTimeout)
        return WarmResult(
            tSTTLoad: SidecarClient.double(reply["t_stt_load"]),
            tCleanupLoad: SidecarClient.double(reply["t_cleanup_load"]),
            cleanupWarming: (reply["cleanup_warming"] as? Bool) ?? false
        )
    }

    /// Transcribe (+optionally clean) one utterance. `samples` are the little-
    /// endian Float32 mono 16 kHz array AudioCapture produces — base64-encoded
    /// straight into pcm_b64 (exactly what the sidecar decodes with
    /// np.frombuffer(dtype=float32)). Throws only on comms failure or STT
    /// failure; a cleanup failure comes back as success with cleanupError set.
    ///
    /// W4-T1: `removeFillers` (default OFF — the app passes the Settings value,
    /// which defaults ON) strips filler words before cleanup; `replacements`
    /// (default empty — OMITTED from the request when empty, keeping the wire
    /// backward-compatible) is the user's spoken→replacement snippet table
    /// applied as a final boundary-guarded pass.
    ///
    /// B3 `vocabulary` (default empty — omitted when empty) is a term list the
    /// sidecar joins into a Whisper initial_prompt to bias the decode toward
    /// those words/spellings. B4 `formatCommands` (default OFF) turns on the
    /// spoken formatting-command pass (new line / paragraph / bullet). Both are
    /// omitted-when-default so a defaults dictate stays byte-identical on the wire.
    func dictate(samples: [Float], engine: String? = nil, cleanup: Bool,
                 removeFillers: Bool = false,
                 replacements: [String: String] = [:],
                 vocabulary: [String] = [],
                 formatCommands: Bool = false,
                 thaiFormat: Bool = false) throws -> DictationResult {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        var body: [String: Any] = [
            "cmd": "dictate",
            "engine": engine ?? self.engine,
            "cleanup": cleanup,
            "pcm_b64": data.base64EncodedString(),
        ]
        // Protocol default is false/absent; send the flag only when on, and the
        // table only when non-empty, so a defaults-off dictate is byte-identical
        // on the wire to the pre-W4-T1 request.
        if removeFillers { body["remove_fillers"] = true }
        if !replacements.isEmpty { body["replacements"] = replacements }
        if !vocabulary.isEmpty { body["vocabulary"] = vocabulary }
        if formatCommands { body["format_commands"] = true }
        if thaiFormat { body["thai_format"] = true }
        let reply = try exchange(body, timeout: SidecarClient.dictateTimeout)
        return DictationResult(
            raw: reply["raw"] as? String ?? "",
            final: reply["final"] as? String ?? "",
            tSTT: SidecarClient.double(reply["t_stt"]),
            tCleanup: SidecarClient.double(reply["t_cleanup"]),
            llmRan: reply["llm_ran"] as? Bool ?? false,
            gateReason: reply["gate_reason"] as? String ?? "",
            guardrailFlag: reply["guardrail_flag"] as? String ?? "",
            cleanupError: reply["cleanup_error"] as? String,
            fillersRemoved: (reply["fillers_removed"] as? NSNumber)?.intValue ?? 0,
            replacementsFired: (reply["replacements_fired"] as? NSNumber)?.intValue ?? 0,
            formatCommandsFired: (reply["format_commands_fired"] as? NSNumber)?.intValue ?? 0,
            thaiFormatFired: (reply["thai_format_fired"] as? NSNumber)?.intValue ?? 0
        )
    }

    /// Set the opt-in Groq API key injected into the sidecar's spawn env as
    /// GROQ_API_KEY (W3-T4 cloud fallback). Pass the key when the toggle is on, or
    /// nil/empty to clear it (local-only). A CHANGE closes the current child so
    /// the NEXT request respawns with the updated env — the existing self-heal
    /// respawn path, so a key/toggle edit takes effect without a relaunch. No-op
    /// when the value is unchanged (so unrelated settings edits don't respawn).
    func setGroqAPIKey(_ key: String?) {
        let normalized = (key?.isEmpty ?? true) ? nil : key
        let changed: Bool = requestQueue.sync {
            if normalized == groqAPIKey { return false }
            groqAPIKey = normalized
            return true
        }
        if changed { close() }   // graceful shutdown; next call respawns with new env
    }

    /// Fast liveness probe. Returns the sidecar's pid.
    @discardableResult
    func ping(timeout: TimeInterval = SidecarClient.pingTimeout) throws -> Int {
        let reply = try exchange(["cmd": "ping"], timeout: timeout)
        return (reply["pid"] as? NSNumber)?.intValue ?? -1
    }

    /// snapshot_download each repo into the sidecar's HF_HOME (first-run
    /// onboarding / Settings). `onProgress` fires per whole-percent change from
    /// the interim protocol events, on the request queue (a background thread) —
    /// the caller must hop to the main actor to touch UI. A per-repo failure is
    /// NOT thrown: it comes back as `DownloadResult(ok: false, failedRepo:)`
    /// (the sidecar stays alive). Only a genuine comms failure (spawn / stall /
    /// dead pipe) throws a SidecarError. LONG inactivity-watchdog timeout.
    @discardableResult
    func download(repos: [String],
                  onProgress: @escaping (_ repo: String, _ pct: Int) -> Void) throws -> DownloadResult {
        let reply = try exchange(
            ["cmd": "download", "repos": repos],
            timeout: SidecarClient.downloadTimeout,
            onEvent: { event in
                guard (event["event"] as? String) == "progress",
                      let repo = event["repo"] as? String,
                      let pct = (event["pct"] as? NSNumber)?.intValue else { return }
                onProgress(repo, pct)
            },
            // A per-repo failure replies ok:false but the sidecar keeps serving,
            // so surface it as a value rather than the generic replyError throw.
            treatOkFalseAsReply: true)
        return DownloadResult(
            ok: reply["ok"] as? Bool ?? false,
            downloaded: (reply["downloaded"] as? [String]) ?? [],
            failedRepo: reply["failed_repo"] as? String,
            error: reply["error"] as? String)
    }

    /// Shut the sidecar down cleanly: send shutdown, close our stdin (belt-and-
    /// suspenders EOF), wait briefly, then force-terminate. Idempotent; leaves
    /// no orphan. Mirrors CleanupClient.close().
    func close() {
        requestQueue.sync {
            guard let proc = self.proc else { return }
            if proc.isRunning {
                // Best-effort graceful shutdown; ignore a broken pipe.
                try? self.writeLine(["cmd": "shutdown"])
                try? self.stdinHandle?.close()
            }
            if SidecarClient.waitForExit(proc, timeout: 5.0) {
                self.dropProcess()   // graceful exit — just release handles.
            } else {
                self.forceKill()     // still up after 5s — terminate/kill.
            }
        }
    }

    /// Immediate, NON-BLOCKING teardown for app termination. Unlike `close()`,
    /// this never touches `requestQueue`, so quitting can never be frozen behind
    /// an in-flight request. A `warm` holds the serial `requestQueue` for the
    /// ENTIRE (cold) model load — tens of seconds — and `close()`'s
    /// `requestQueue.sync` on the main thread would block there the whole time,
    /// which macOS shows as "OLIV is not responding" and a quit that appears to
    /// hang. Here we SIGKILL the child directly and close our stdin; the child
    /// would also EOF-exit once the pipe closes, so this just reaps it at once.
    /// Reading `proc` off the queue is a deliberate, benign race — ARC keeps the
    /// Process alive across the access, and kill() on an already-dead pid is a
    /// harmless no-op (ESRCH). Use ONLY on the terminate path.
    func terminateNow() {
        if let pid = proc?.processIdentifier, pid > 0 {
            kill(pid, SIGKILL)
        }
        try? stdinHandle?.close()
    }

    // MARK: Serialized request/reply transaction

    /// Drive one request→reply on the serial queue. Ported from
    /// CleanupClient.clean/warm_up's shared body. INTERNAL so tests can exercise
    /// the raw protocol (garbage/timeout/stray-line paths) via a fake child.
    ///
    /// `onEvent` (W3-T4): interim protocol lines that share this request's id
    /// but carry an `"event"` field (e.g. download `"progress"`) are surfaced
    /// here instead of being mistaken for the final reply — the read keeps going
    /// until the true reply arrives, resetting its deadline on each event so a
    /// long-but-progressing job (download) doesn't trip the timeout.
    /// `treatOkFalseAsReply`: return an ok:false reply as a value instead of
    /// throwing replyError — used by `download`, whose per-repo failures are a
    /// result, not a comms error (the sidecar stays alive either way).
    @discardableResult
    func exchange(_ body: [String: Any], timeout: TimeInterval,
                  onEvent: (([String: Any]) -> Void)? = nil,
                  treatOkFalseAsReply: Bool = false) throws -> [String: Any] {
        try requestQueue.sync {
            guard ensureSpawned() else {
                throw SidecarError.notSpawned("could not launch \(command.first ?? "?")")
            }
            reqID += 1
            let rid = reqID
            var payload = body
            payload["id"] = rid
            lineQueue.drain()            // discard stale lines before this request
            do {
                try writeLine(payload)
            } catch {
                forceKill()              // dead pipe → respawn next call
                throw SidecarError.processDied("write failed: \(error)")
            }
            guard let reply = readReply(id: rid, timeout: timeout, onEvent: onEvent) else {
                // Timeout or EOF: sidecar is in an unknown state → kill, respawn
                // on the next call (the CleanupClient self-heal rule).
                forceKill()
                let cmd = body["cmd"] as? String ?? "?"
                throw SidecarError.timeout("'\(cmd)' timed out or sidecar died (>\(timeout)s)")
            }
            if !treatOkFalseAsReply, let ok = reply["ok"] as? Bool, ok == false {
                // The sidecar rejected THIS request (bad cmd / STT failure) but
                // is still alive and serving — do NOT kill it.
                let msg = reply["error"] as? String ?? "sidecar returned ok:false"
                throw SidecarError.replyError(msg)
            }
            return reply
        }
    }

    // MARK: Lifecycle (all called on requestQueue)

    private var isAlive: Bool { proc != nil && (proc?.isRunning ?? false) }

    private func ensureSpawned() -> Bool {
        if isAlive { return true }
        if proc != nil { forceKill() }   // reap a dead handle before respawning
        return spawn()
    }

    private func spawn() -> Bool {
        guard let exe = command.first else { return false }
        guard FileManager.default.isExecutableFile(atPath: exe)
            || FileManager.default.fileExists(atPath: exe) else {
            NSLog("OLIV SidecarClient: executable not found: \(exe)")
            return false
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = Array(command.dropFirst())
        // Merge our overrides over the inherited env: the bundled OLIV_ROOT +
        // app-owned HF_HOME (if any), plus the opt-in GROQ_API_KEY when the cloud
        // fallback is on. With neither, leave `environment` unset so the child
        // inherits unchanged (dev spawns, local-only). Setting it to an explicit
        // copy of the inherited env is otherwise equivalent to inheriting.
        if environment != nil || groqAPIKey != nil {
            var merged = ProcessInfo.processInfo.environment
            if let extra = environment { for (k, v) in extra { merged[k] = v } }
            if let key = groqAPIKey, !key.isEmpty { merged["GROQ_API_KEY"] = key }
            proc.environment = merged
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // The sidecar re-points fd 1 at stderr, so its stderr carries only
        // chatter/tracebacks — discard it (a diagnostic log file is W3-T4).
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            NSLog("OLIV SidecarClient: spawn failed for \(exe): \(error)")
            return false
        }

        self.proc = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutPipe = stdoutPipe
        // Fresh queue for this process; capture it + the handle by value so the
        // reader never touches self (no data race with the request queue).
        let queue = LineQueue()
        self.lineQueue = queue
        let readHandle = stdoutPipe.fileHandleForReading
        let reader = Thread { SidecarClient.readerLoop(readHandle, into: queue) }
        reader.name = "oliv-sidecar-reader"
        reader.qualityOfService = .userInitiated
        reader.start()
        return true
    }

    /// Terminate (bounded), release handles. Leaves self.proc == nil. Port of
    /// CleanupClient._kill.
    private func forceKill() {
        guard let proc = self.proc else { return }
        if proc.isRunning {
            proc.terminate()   // SIGTERM
            if !SidecarClient.waitForExit(proc, timeout: 2.0) {
                kill(proc.processIdentifier, SIGKILL)
                _ = SidecarClient.waitForExit(proc, timeout: 2.0)
            }
        }
        dropProcess()
    }

    /// Release process handles without signalling (the child already exited).
    private func dropProcess() {
        try? stdinHandle?.close()   // signals EOF to a still-graceful child
        stdinHandle = nil
        // The reader Thread owns the stdout read handle; it ends on EOF when the
        // child dies and releases the fd. Dropping our Pipe ref here is enough.
        stdoutPipe = nil
        proc = nil
    }

    // MARK: I/O primitives (on requestQueue, except the reader)

    private func writeLine(_ obj: [String: Any]) throws {
        guard let handle = stdinHandle else {
            throw SidecarError.processDied("no stdin handle")
        }
        let data = try SidecarClient.encode(obj)
        try handle.write(contentsOf: data)
    }

    /// Read lines until one parses as JSON with the matching id AND is a final
    /// reply, or timeout/EOF. Skips blank / non-JSON / stray-id lines (tolerate
    /// out-of-order & garbage). Port of CleanupClient._read_reply, extended for
    /// W3-T4 interim events: a matched-id line carrying an `"event"` field is
    /// handed to `onEvent` and does NOT end the read (the deadline is reset so a
    /// still-progressing job survives the base timeout as an inactivity budget).
    private func readReply(id: Int, timeout: TimeInterval,
                           onEvent: (([String: Any]) -> Void)?) -> [String: Any]? {
        var deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            guard let item = lineQueue.get(timeout: remaining) else {
                return nil   // timed out
            }
            guard case let .line(text) = item else {
                return nil   // EOF sentinel: the sidecar exited
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let obj = SidecarClient.decode(trimmed) else {
                // Non-JSON on the protocol channel — skip and keep reading, same
                // as CleanupClient (logs debug, drains until the real reply).
                continue
            }
            // Stray/foreign id under the lock is unexpected; skip it.
            guard (obj["id"] as? NSNumber)?.intValue == id else { continue }
            if obj["event"] != nil {
                // Interim event for THIS request (e.g. download progress): surface
                // it and keep reading for the final reply, refreshing the deadline.
                onEvent?(obj)
                deadline = Date().addingTimeInterval(timeout)
                continue
            }
            return obj
        }
    }

    // MARK: Static helpers (pure)

    /// Blocking reader: split the sidecar's stdout into newline-delimited lines
    /// and push each into `queue`, then an EOF sentinel. Runs on its own Thread
    /// so a wedged sidecar blocks HERE, never the request queue — the Swift
    /// equivalent of CleanupClient's daemon reader thread.
    private static func readerLoop(_ handle: FileHandle, into queue: LineQueue) {
        var buffer = [UInt8]()
        while true {
            let chunk = handle.availableData   // blocks; empty Data == EOF
            if chunk.isEmpty { break }
            buffer.append(contentsOf: chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineBytes = Array(buffer[..<nl])
                buffer.removeSubrange(...nl)
                if let s = String(bytes: lineBytes, encoding: .utf8) {
                    queue.put(.line(s))
                }
            }
        }
        if !buffer.isEmpty, let s = String(bytes: buffer, encoding: .utf8) {
            queue.put(.line(s))
        }
        queue.put(.eof)
    }

    private static func encode(_ obj: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: obj, options: [])
        data.append(0x0A)   // newline framing
        return data
    }

    private static func decode(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    /// JSON numbers arrive as NSNumber whether the source was int or float;
    /// bridge both to Double.
    private static func double(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    /// Bounded wait for a child to exit (polling — Foundation reaps the zombie
    /// via its own proc dispatch source, so isRunning flips cleanly). Returns
    /// true if it exited within `timeout`.
    private static func waitForExit(_ proc: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            usleep(20_000)   // 20 ms
        }
        return !proc.isRunning
    }

    // MARK: Test seams

    #if DEBUG
    /// Test-only: is the child process currently running? Read on the request
    /// queue so it never races spawn/forceKill.
    var _isAliveForTests: Bool { requestQueue.sync { isAlive } }
    /// Test-only: the current child's pid, or nil if none.
    var _pidForTests: Int32? { requestQueue.sync { proc?.processIdentifier } }
    #endif
}

/// Thread-safe FIFO of stdout lines with a bounded (deadline) get — the
/// NSCondition analogue of CleanupClient's queue.Queue. `.eof` marks the pipe
/// closing (worker exited).
private final class LineQueue {
    enum Item {
        case line(String)
        case eof
    }

    private let cond = NSCondition()
    private var items: [Item] = []

    func put(_ item: Item) {
        cond.lock()
        items.append(item)
        cond.signal()
        cond.unlock()
    }

    /// Discard buffered lines before a new request (CleanupClient._drain_queue).
    func drain() {
        cond.lock()
        items.removeAll()
        cond.unlock()
    }

    /// Bounded get: returns the next item, or nil if `timeout` elapses first.
    func get(timeout: TimeInterval) -> Item? {
        cond.lock()
        defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while items.isEmpty {
            if !cond.wait(until: deadline) { return nil }   // timed out
        }
        return items.removeFirst()
    }
}
