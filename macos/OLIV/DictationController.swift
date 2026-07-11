// Dictation coordinator — wires HotkeyMonitor + AudioCapture + TextInjector
// into the press/record/release/paste loop and drives AppState (W3-T2).
//
// This is the Swift analogue of app/audio.py's DictationSession + the
// app/dictation.py DictationApp failure philosophy: any stage failing must
// NEVER crash the app or lose text — log and return to idle. The heavy work
// (bounded stop → transcribe → paste) runs OFF the main thread so the hotkey
// tap thread and the UI are never blocked; only AppState transitions touch the
// main actor.
//
//   press   → idle → recording, AudioCapture.start()
//   release → recording → processing, then on a worker:
//               samples = AudioCapture.stop()   (bounded)
//               text    = await transcriber(samples)  (W3-T3 sidecar; nil = no-op)
//               TextInjector.inject(text)
//             → idle
//
// The `transcriber` hook defaults to nil so W3-T2 is complete and testable
// without STT; W3-T3 plugs the Python sidecar in here.

import AppKit
import Foundation

@MainActor
final class DictationController {
    private let appState: AppState
    private let audio: AudioCapture
    private let injector: TextInjector
    private var hotkey: HotkeyMonitor?

    /// samples → transcript. nil / no-op until W3-T3 wires the sidecar in. Kept
    /// as a fallback seam (tests / future backends); when `sidecar` is set it
    /// takes precedence in the release path.
    var transcriber: (([Float]) async -> String?)?

    /// W3-T3: the STT + cleanup sidecar. When set, `release` transcribes+cleans
    /// via it and pastes `final`. nil = the controller is STT-less (W3-T2 mode).
    var sidecar: SidecarClient?

    /// STT engine id handed to the sidecar (its DEFAULT_ENGINE).
    var sttEngine: String = SidecarClient.defaultEngine

    /// Cleanup global on/off (menu/Settings default on). The Wave-2 per-app
    /// override lives in `verbatimApps`; `resolveCleanup` folds the two together
    /// at release-time (W3-T4).
    var cleanupEnabled: Bool = true

    /// W4-T1 Feature B: strip filler words before cleanup (Settings default ON).
    /// Sent per-dictate.
    var removeFillers: Bool = true

    /// W4-T1 Feature A: user replacements/snippets (spoken → replacement). Sent
    /// per-dictate; an empty table is omitted from the request.
    var replacements: [String: String] = [:]

    /// B3 custom vocabulary: terms sent per-dictate to bias STT recognition (an
    /// empty list is omitted from the request). B4 formatting-command toggle
    /// (default OFF). Both live-applied from Settings via the coordinator.
    var vocabulary: [String] = []
    var formatCommands: Bool = false

    /// W3-T4 per-app verbatim list — lowercased bundle ids the user wants left
    /// VERBATIM (cleanup bypassed). This is the simplified Swift model of
    /// Wave-2's `[cleanup_apps]` on/off table: since the global switch already
    /// carries "on", the only per-app signal worth storing is "off", so the
    /// table collapses to a membership Set ("verbatim in these apps"). See
    /// `resolveCleanup` for the ported precedence.
    var verbatimApps: Set<String> = []

    /// Which push-to-talk key the tap listens for. Change it live via
    /// `applyHotkey(_:)` (Settings › General); a bare set only takes effect at
    /// the next `start()`.
    var hotkeyKey: HotkeyKey = .default

    /// W4-T2 Feature A: the floating recording HUD (pill). Injected by the
    /// coordinator; nil in headless/e2e and hermetic tests. Show/hide is driven
    /// purely by the status transitions below, so the pill mirrors the state
    /// machine exactly and never lingers.
    var hud: RecordingHUDController?

    /// "Show recording indicator" (Settings › General, default ON). When off the
    /// HUD is never shown; live-applied via the coordinator.
    var showHUD: Bool = true

    /// 0.1.5: record pasted transcripts into AppState's in-memory history
    /// (Settings › General, default ON). Seeded + live-applied like every other
    /// knob; read at release time so mid-utterance flips can't half-apply.
    var historyEnabled: Bool = true

    /// Frontmost app's bundle id at utterance release — the app the user
    /// actually dictated into. Ported deliberately from app/dictation.py: the
    /// app resolves this ONCE, at release, NOT at paste time (the release-app's
    /// policy applies, not whatever has focus a few hundred ms later). A test
    /// seam: overridable so the resolution logic runs hermetically with a fake
    /// frontmost, no AppKit / permissions. Never throws (nil == unknown app).
    var frontmostBundleID: () -> String? = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private var didWarmSidecar = false

    init(
        appState: AppState,
        audio: AudioCapture = AudioCapture(),
        injector: TextInjector = TextInjector()
    ) {
        self.appState = appState
        self.audio = audio
        self.injector = injector

        // W4-T2: stream the tap's live input levels into the HUD waveform.
        // AudioCapture delivers on the main queue (throttled ~24 Hz); forward it
        // to the pill when metering is on. A strictly cosmetic side channel.
        self.audio.onLevel = { [weak self] level in
            MainActor.assumeIsolated {
                guard let self = self, self.showHUD else { return }
                self.hud?.update(level: level)
            }
        }
    }

    /// Install the push-to-talk tap. Idempotent. If the tap can't be created
    /// (Input Monitoring not granted), we log and stay dormant — the app keeps
    /// running so onboarding can prompt for the grant later. Never throws to
    /// the caller (failure philosophy: never crash).
    func start() {
        installHotkey()
        warmSidecarIfNeeded()
    }

    /// Build + start the tap on the current `hotkeyKey`. Idempotent (no-op if a
    /// tap is already live). If tap creation fails (Input Monitoring not yet
    /// granted) we log and stay dormant — a later `start()` retries, so the app
    /// picks up the grant without a relaunch once onboarding prompts for it.
    private func installHotkey() {
        guard hotkey == nil else { return }
        let monitor = HotkeyMonitor(
            key: hotkeyKey,
            onPress: { [weak self] in
                // Fires on the tap thread — hop to main (FIFO) for AppState.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handlePress() }
                }
            },
            onRelease: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handleRelease() }
                }
            }
        )
        do {
            try monitor.start()
            hotkey = monitor
        } catch {
            NSLog("OLIV DictationController: hotkey monitor could not start (\(error)) — "
                + "push-to-talk disabled until Input Monitoring is granted")
        }
    }

    /// Live-apply a new push-to-talk key (Settings › General): tear the current
    /// tap down and install a fresh one on `key`. The monitor's stop() fires a
    /// balancing release if a hold was in flight, so no stuck-recording state
    /// survives the swap. No-op when the key is unchanged and a tap is live.
    func applyHotkey(_ key: HotkeyKey) {
        if key == hotkeyKey, hotkey != nil { return }
        hotkeyKey = key
        hotkey?.stop()
        hotkey = nil
        installHotkey()
    }

    /// Fold the global cleanup switch and the per-app verbatim list into the
    /// single `cleanup` flag one utterance carries — the Swift port of
    /// app/dictation.py's per-app precedence (W2-T3):
    ///   • global OFF  ⇒ cleanup:false EVERYWHERE (the switch always wins; a
    ///     per-app entry can only REFINE a globally-on config, never turn it on);
    ///   • else the frontmost app's bundle id ∈ verbatimApps ⇒ verbatim bypass
    ///     = cleanup:false for THIS utterance (the collapsed "off" entry);
    ///   • else cleanup:true.
    /// Bundle ids match case-insensitively (macOS treats them so — both sides
    /// lowercased). A nil/empty frontmost id is "unknown app" ⇒ the global (on)
    /// behavior, exactly like a missing config key; never crashes.
    /// `nonisolated` — a pure function of its arguments, so it needs no main
    /// actor (callable from the release path AND from hermetic tests).
    nonisolated static func resolveCleanup(globalEnabled: Bool,
                                           verbatimApps: Set<String>,
                                           frontmostBundleID: String?) -> Bool {
        guard globalEnabled else { return false }
        guard let bid = frontmostBundleID?.lowercased(), !bid.isEmpty else { return true }
        return !verbatimApps.contains(bid)
    }

    /// Cloud→local fallback (W3-T4): run one dictate and, if it was on the opt-in
    /// Groq CLOUD engine and failed (a comms SidecarError OR an ok:false STT
    /// failure — both surface as a throw from `dictate`), retry ONCE on the local
    /// default engine before giving up. A local engine's failure is NOT retried
    /// (it has no cheaper fallback). Returns the successful result, or nil when
    /// the utterance is ultimately dropped.
    ///
    /// `dictate` is injected (the transcribe closure), so this is exercised
    /// hermetically with a fake — no real sidecar. `nonisolated` + pure over its
    /// arguments (its only side effect is `log`).
    nonisolated static func dictateWithFallback(
        engine: String,
        cleanup: Bool,
        localEngine: String = SidecarClient.defaultEngine,
        dictate: (_ engine: String, _ cleanup: Bool) throws -> DictationResult,
        log: (String) -> Void = { NSLog("%@", $0) }
    ) -> DictationResult? {
        do {
            return try dictate(engine, cleanup)
        } catch {
            // Only the cloud engine gets a second try on the local default; any
            // other engine (or an already-local engine) is dropped as before.
            guard engine == SidecarClient.cloudEngine, engine != localEngine else {
                log("OLIV: sidecar dictate failed (\(error)) — utterance dropped, returning to idle")
                return nil
            }
            log("OLIV: Groq cloud dictate failed (\(error)) — falling back to local \(localEngine), retrying once")
            do {
                return try dictate(localEngine, cleanup)
            } catch {
                log("OLIV: local fallback dictate also failed (\(error)) — utterance dropped, returning to idle")
                return nil
            }
        }
    }

    /// Front-load the sidecar's models at app start, NON-BLOCKING: the warm can
    /// take a couple of minutes (model load + first-run downloads), so it runs
    /// on a background queue and the app stays responsive. A failed warm is
    /// non-fatal — STT/cleanup just load lazily on the first dictate. Idempotent.
    private func warmSidecarIfNeeded() {
        guard let sidecar = sidecar, !didWarmSidecar else { return }
        didWarmSidecar = true
        let engine = sttEngine
        let cleanup = cleanupEnabled
        // Reap the child promptly on quit. Use the NON-BLOCKING terminateNow():
        // close() takes the serial requestQueue, which an in-flight warm holds for
        // the whole model load, so it would freeze the main thread on quit ("not
        // responding"). terminateNow() SIGKILLs the child off-queue; it also
        // EOF-exits when our pipe closes, so we never orphan.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in sidecar.terminateNow() }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let warm = try sidecar.warm(engine: engine, cleanup: cleanup)
                NSLog("OLIV sidecar warmed: stt=\(warm.tSTTLoad)s cleanup=\(warm.tCleanupLoad)s")
            } catch {
                NSLog("OLIV sidecar warm failed (\(error)) — STT/cleanup will load "
                    + "lazily on the first dictate")
            }
        }
    }

    /// Tear down the tap. The monitor's stop() fires a balancing release if a
    /// hold was active; guard against that leaving a stuck state by resetting to
    /// idle here.
    func stop() {
        hotkey?.stop()
        hotkey = nil
        if appState.status != .idle {
            appState.status = .idle
        }
        hud?.hide()
    }

    // MARK: Transitions (main actor)

    private func handlePress() {
        // Respect the master toggle — off means the hotkey is ignored entirely.
        guard appState.dictationEnabled else { return }
        // Ignore a press we can't cleanly start from (mid-processing / already
        // recording); the state machine debounces at its level too. Mid-
        // processing gets a visible acknowledgement — 🧑 smoke found a silent
        // drop here reads as "the hotkey is flaky" when dictating back-to-back.
        guard appState.status == .idle else {
            if appState.status == .processing, showHUD { hud?.flashBusy() }
            return
        }

        appState.status = .recording
        do {
            try audio.start()
            if showHUD { hud?.show(phase: .recording) }
        } catch {
            NSLog("OLIV DictationController: audio start failed (\(error)) — returning to idle")
            appState.status = .idle
            hud?.hide()
        }
    }

    private func handleRelease() {
        // Only act on a release that ends an active recording. A balancing
        // release fired by stop() while already idle/processing is a no-op.
        guard appState.status == .recording else { return }
        appState.status = .processing
        // Switch the SAME pill to the calm processing animation (no re-fade).
        if showHUD { hud?.show(phase: .processing) }

        let audio = self.audio
        let injector = self.injector
        let hud = self.hud
        let transcriber = self.transcriber
        let appState = self.appState
        let sidecar = self.sidecar
        let engine = self.sttEngine
        let removeFillers = self.removeFillers
        let replacements = self.replacements
        let vocabulary = self.vocabulary
        let formatCommands = self.formatCommands
        // Resolve cleanup ONCE, here at release (main actor), against the app the
        // user actually dictated into — NOT at paste time (see frontmostBundleID
        // / app/dictation.py). A per-app verbatim entry passes cleanup:false so
        // the sidecar returns raw, byte-identical (verbatim bypass).
        let cleanup = DictationController.resolveCleanup(
            globalEnabled: cleanupEnabled,
            verbatimApps: verbatimApps,
            frontmostBundleID: frontmostBundleID())

        // Off-main worker: bounded stop → transcribe → paste. Any failure here
        // is swallowed + logged; we always return to idle so the app can't get
        // stuck (port of DictationApp's never-crash / never-lose-text stance).
        // A1/A2: the worker now reports a ReleaseOutcome so a dropped utterance
        // (STT/comms failure) or a paste that couldn't be synthesized (missing
        // Accessibility / secure input) shows a brief HUD notice instead of
        // vanishing silently — the whole point of the reliability pass.
        // `self` is captured weakly ONLY to re-read historyEnabled at record
        // time (see below); everything else stays a release-time local.
        Task.detached { [weak self] in
            let samples = audio.stop()
            // The capture ceiling truncated this utterance: the transcript still
            // pastes, but the user must be TOLD the tail was cut (never silent).
            let capped = audio.stats?.capped ?? false
            let outcome: ReleaseOutcome
            // Menu "Last:" line — set on the sidecar path only (the transcriber
            // seam has no timings to report).
            var stats: LastDictationStats?
            // What actually went to the pasteboard — recorded into the menu
            // history below only when the utterance landed (never on failure).
            var pastedText: String?

            if samples.isEmpty {
                outcome = .nothingToDo   // tapped without speaking; not an error
            } else if let sidecar = sidecar {
                // W3-T3: STT + cleanup via the sidecar; paste `final`. A cleanup
                // failure degrades server-side to final==raw (still success).
                // W3-T4: a failed dictate on the opt-in Groq CLOUD engine retries
                // ONCE on the local default before giving up (dictateWithFallback
                // logs the fallback); any other engine's failure returns nil —
                // the utterance is dropped (raw transcript lives inside the
                // sidecar, nothing to fall back to). nil now surfaces to the user.
                let result = DictationController.dictateWithFallback(
                    engine: engine, cleanup: cleanup,
                    dictate: { eng, cl in
                        try sidecar.dictate(samples: samples, engine: eng, cleanup: cl,
                                            removeFillers: removeFillers,
                                            replacements: replacements,
                                            vocabulary: vocabulary,
                                            formatCommands: formatCommands)
                    })
                if let result = result {
                    if let err = result.cleanupError {
                        NSLog("OLIV: cleanup degraded to raw (\(err)) — pasting raw transcript")
                    }
                    // No stats/history for an empty transcript (silent hold /
                    // no-speech gate): "Last: 0.9s · 0 chars" would advertise
                    // a dictate that produced nothing. The paste call itself
                    // keeps its long-standing unconditional shape.
                    if !result.final.isEmpty {
                        stats = LastDictationStats(chars: result.final.count,
                                                   sttSeconds: result.tSTT,
                                                   cleanupSeconds: result.tCleanup)
                        pastedText = result.final
                    }
                    outcome = DictationController.paste(result.final, with: injector)
                } else {
                    outcome = .transcribeFailed
                }
            } else if let transcriber = transcriber {
                // W3-T2 fallback seam (tests / no sidecar): nil is "no-op", not a
                // user-facing failure.
                let text = await transcriber(samples)
                if let text = text, !text.isEmpty {
                    pastedText = text
                    outcome = DictationController.paste(text, with: injector)
                } else {
                    outcome = .nothingToDo
                }
            } else {
                outcome = .nothingToDo
            }

            // Freeze the worker-local vars for the Sendable hop below (a captured
            // var in concurrent code is a Swift-6 error). The weak `self` binding
            // is itself a var — rebind it to a let for the same reason.
            let frozenStats = stats
            let frozenPastedText = pastedText
            let controller = self
            await MainActor.run {
                appState.status = .idle
                if let stats = frozenStats { appState.lastDictation = stats }
                // History records only text that LANDED (pasted, or on the
                // clipboard awaiting ⌘V) and only while the toggle is on; a
                // dropped/empty utterance is not history. The knob is re-read
                // NOW, not captured at release: the user may flip history off
                // during the 1–2 s of processing, and recording with the stale
                // value would retain a transcript that clearTranscripts() just
                // promised was gone.
                if controller?.historyEnabled == true, let text = frozenPastedText,
                   outcome == .pastedOK || outcome == .pasteNeedsManual {
                    appState.recordTranscript(text)
                }
                switch outcome {
                case .pastedOK, .nothingToDo:
                    if capped {
                        hud?.notice("Hit the 10-minute recording limit — the end was cut off",
                                    systemImage: "exclamationmark.triangle.fill")
                    } else {
                        hud?.hide()   // quick fade on completion
                    }
                case .transcribeFailed:
                    hud?.notice("Couldn’t transcribe — try again",
                                systemImage: "exclamationmark.triangle.fill")
                case .pasteNeedsManual:
                    hud?.notice("Text is on the clipboard — press ⌘V",
                                systemImage: "doc.on.clipboard")
                }
            }
        }
    }

    /// Paste `text` and classify the result for the end-of-utterance HUD notice
    /// (A2): a synthesized Cmd+V is `pastedOK`; a `usedFallback` result (missing
    /// Accessibility OR active secure input — the text is on the clipboard but
    /// wasn't pasted) is `pasteNeedsManual` so the user is told to ⌘V. `nonisolated`
    /// + pure over its arguments so it runs on the off-main worker (and is
    /// unit-testable with an injector whose access/secure-input seams are faked).
    nonisolated static func paste(_ text: String, with injector: TextInjector) -> ReleaseOutcome {
        injector.inject(text).usedFallback ? .pasteNeedsManual : .pastedOK
    }
}

/// What the release worker ended up doing — drives the end-of-utterance HUD
/// feedback (A1/A2). Success/empty hide the pill; the two failure cases show a
/// brief notice so a dropped utterance or an un-synthesized paste is never silent.
enum ReleaseOutcome: Equatable {
    case pastedOK
    case nothingToDo               // no audio captured / empty transcript
    case transcribeFailed          // STT or comms failed → utterance dropped
    case pasteNeedsManual          // text left on the clipboard; user must ⌘V
}
