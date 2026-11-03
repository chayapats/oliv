// Live preview (#26, #46): show the words in the recording HUD while the key
// is held. A few times a second the newest audio is transcribed on-device —
// greedy, with the encoder run on the audio there is rather than Whisper's
// 30 s window, and the Rust text core's light cleanup (dictionary, numbers, ๆ;
// never the cleanup model) — and the HUD shows the tail of it: the words two
// previews in a row agree on as settled, the rest dimmed. The preview is never
// pasted, logged or kept: the final pass after release is exactly the one that
// ran before this feature, and it is what gets pasted.
//
// Cost control, in order of importance:
//   • the final pass never waits behind a preview: release cancels the one in
//     flight out of band, and the model helper stops it between tokens;
//   • at most one preview in flight, the next skipped until it returns;
//   • LivePreviewGovernor paces previews to the Mac: the gap between them grows
//     with what each one costs, and previews turn off until the next launch
//     when they can't keep up or when a cancelled one held up a release;
//   • on-device engines only: Groq, the OLIV API and the free trial never
//     preview (they would upload audio).

import Foundation

enum LivePreview {
    /// Only the newest audio is previewed: the HUD shows the tail anyway, and
    /// a bounded window bounds the cost of each preview.
    static let windowSeconds: Double = 12
    static let sampleRate: Double = AudioCapture.targetSampleRate
    static var windowSamples: Int { Int(windowSeconds * sampleRate) }
    /// About two lines of the expanded pill.
    static let maxCharacters = 72

    /// Allowlist: the on-device MLX engines. Anything else — Groq, the OLIV
    /// API, the free trial, an engine added later — never previews.
    static func isEligible(engine: String) -> Bool {
        OLIVSettings.Engine.local.contains { $0.id == engine }
    }

    /// The newest words of `text`, about `limit` characters, with "…" where
    /// older words were dropped. Cuts only between grapheme clusters, so a Thai
    /// vowel or tone mark never loses its consonant; prefers a word boundary
    /// when one is close.
    static func tail(_ text: String, limit: Int = maxCharacters) -> String {
        tail(LivePreviewLine(settled: "", tentative: text), limit: limit).text
    }

    /// `tail` for a line with settled and tentative words: the same cut, with
    /// each part keeping what is left of it.
    static func tail(_ line: LivePreviewLine, limit: Int = maxCharacters) -> LivePreviewLine {
        let settled = flatten(line.settled), tentative = flatten(line.tentative)
        let full = settled + tentative
        // Leading and trailing spaces never show.
        let lead = full.prefix { $0.isWhitespace }.count
        let trail = full.count == lead ? 0 : full.reversed().prefix { $0.isWhitespace }.count
        var start = lead, ellipsis = false
        if full.count - lead - trail > limit, limit > 1 {
            ellipsis = true
            start = full.count - trail - (limit - 1)
            let cut = full.dropFirst(start).dropLast(trail)
            if let space = cut.firstIndex(of: " "), cut.distance(from: cut.startIndex, to: space) <= 12 {
                start += cut.distance(from: cut.startIndex, to: space) + 1
            }
            start += full.dropFirst(start).prefix { $0.isWhitespace }.count
        }
        let end = full.count - trail
        let keptSettled = max(0, min(settled.count, end) - start)
        let shown = full.dropFirst(start).prefix(max(0, end - start))
        var result = LivePreviewLine(settled: String(shown.prefix(keptSettled)),
                                     tentative: String(shown.dropFirst(keptSettled)))
        if ellipsis {
            if result.settled.isEmpty { result.tentative = "…" + result.tentative }
            else { result.settled = "…" + result.settled }
        }
        return result
    }

    /// Newlines become spaces, so a preview is one run of text.
    private static func flatten(_ text: String) -> String {
        String(text.map { $0.isNewline ? " " : $0 })
    }

    /// What to show for `current` after `previous` (the last preview that had
    /// text): the words both agree on from the start are settled, the rest is
    /// tentative. Words are cut where the system's word breaker (which knows
    /// Thai) puts them, so half a word never settles. When the 12 s window
    /// has slid on, the agreement may start later in `previous`.
    static func line(previous: String?, current: String) -> LivePreviewLine {
        guard let previous, !previous.isEmpty, !current.isEmpty else {
            return LivePreviewLine(settled: "", tentative: current)
        }
        let old = Array(previous), new = Array(current)
        var agreed = 0
        for start in [0] + wordStarts(previous) {
            var count = 0
            while start + count < old.count, count < new.count, old[start + count] == new[count] { count += 1 }
            agreed = max(agreed, count)
            if agreed == new.count { break }
        }
        // Settle whole words only: back off to the last word end inside the
        // agreement (all of it when the texts agree to the end of `current`).
        let cut = agreed == new.count ? agreed : (wordEnds(current).last { $0 <= agreed } ?? 0)
        return LivePreviewLine(settled: String(new.prefix(cut)), tentative: String(new.dropFirst(cut)))
    }

    /// Character offsets where words start / end in `text`.
    private static func wordStarts(_ text: String) -> [Int] { words(text).map(\.start) }
    private static func wordEnds(_ text: String) -> [Int] { words(text).map(\.end) }
    private static func words(_ text: String) -> [(start: Int, end: Int)] {
        var result: [(Int, Int)] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) {
            _, range, _, _ in
            result.append((text.distance(from: text.startIndex, to: range.lowerBound),
                           text.distance(from: text.startIndex, to: range.upperBound)))
        }
        return result
    }
}

/// One preview as the HUD shows it: words two previews in a row agreed on,
/// then the newest, still-moving words (drawn dimmer).
struct LivePreviewLine: Equatable {
    var settled: String
    var tentative: String
    var text: String { settled + tentative }
    var isEmpty: Bool { settled.isEmpty && tentative.isEmpty }
}

/// One preview's outcome. `skipped` names why there is no text: "cancelled",
/// "silent", "noSpeech", "notLoaded" (previews never load a model) or "failed".
struct LivePreviewResult: Equatable {
    var text: String
    var skipped: String?
    /// The text before the light cleanup (only when asked for; evaluation).
    var raw: String?
    /// Seconds per stage, for the harness: "sidecar" (the Rust worker's whole
    /// turn), "stt" (its wait on the model helper), "clean", and the helper's
    /// "audio" (decoding the request), "mel", "encode", "decode", plus
    /// "frames" (encoder input frames). Never any text.
    var timings: [String: Double] = [:]

    /// The model decoded this preview, whether or not it has text to show:
    /// "noSpeech" is a full decode whose text was a known hallucination, and
    /// "failed" a decode that errored part way. Every other reason skips the
    /// preview before the model runs, so it costs next to nothing and says
    /// nothing about what a preview costs on this Mac.
    var ranModel: Bool { skipped == nil || skipped == "noSpeech" || skipped == "failed" }
    var failed: Bool { skipped == "failed" }
}

extension SidecarClient {
    /// Transcribe the newest audio for the HUD. Shares the request queue with
    /// `dictate`; see `cancelPreviews(through:)` for why release never waits.
    /// `cleanup`: the dictation's options, for the light cleanup (no model);
    /// nil shows the raw transcript. `extra` adds evaluation-only fields.
    func preview(samples: [Float], engine: String, seq: Int, cleanup: DictationOptions? = nil,
                 extra: [String: Any] = [:]) throws -> LivePreviewResult {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let body = Self.previewBody(engine: engine, pcmB64: data.base64EncodedString(), seq: seq, cleanup: cleanup)
            .merging(extra) { _, new in new }
        let reply = try exchange(body, timeout: SidecarClient.dictateTimeout)
        return Self.previewResult(reply)
    }

    /// The `preview` request: the dictate request's options (so the light
    /// cleanup matches the final's dictionary, words and formatting), minus
    /// names on screen, plus the preview number.
    nonisolated static func previewBody(engine: String, pcmB64: String, seq: Int,
                                        cleanup options: DictationOptions?) -> [String: Any] {
        var body: [String: Any] = ["engine": engine, "pcm_b64": pcmB64]
        if let options {
            body = dictateBody(engine: engine, pcmB64: pcmB64, cleanup: options.cleanup,
                               removeFillers: options.removeFillers, replacements: options.replacements,
                               vocabulary: options.vocabulary, formatCommands: options.formatCommands,
                               thaiFormat: options.thaiFormat, dictionary: options.dictionary)
            body["light_cleanup"] = true
        }
        body["cmd"] = "preview"
        body["preview_seq"] = seq
        return body
    }

    nonisolated static func previewResult(_ reply: [String: Any]) -> LivePreviewResult {
        var timings: [String: Double] = [:]
        for (key, field) in [("sidecar", "t_sidecar"), ("stt", "t_stt"), ("clean", "t_clean")] {
            if let value = (reply[field] as? NSNumber)?.doubleValue { timings[key] = value }
        }
        for (key, value) in reply["timings"] as? [String: Any] ?? [:] {
            if let value = (value as? NSNumber)?.doubleValue { timings[key] = value }
        }
        return LivePreviewResult(text: reply["text"] as? String ?? "", skipped: reply["skipped"] as? String,
                                 raw: reply["raw"] as? String, timings: timings)
    }

    /// Stop previews up to `seq`, including one being decoded right now. Sent
    /// out of band, so it reaches the sidecar while that preview still holds
    /// the request queue; the dictate queued behind it then runs at once.
    func cancelPreviews(through seq: Int) {
        sendOutOfBand(["cmd": "cancel_preview", "through": seq])
    }
}

/// How often to preview, and whether to at all, on this Mac. A pure value;
/// LivePreviewPacer keeps one for the whole app run.
struct LivePreviewGovernor: Equatable {
    /// Tuned in #46 for previews that encode only the audio there is (about
    /// 0.15–0.3 s each on an M4 Pro for a few seconds of speech).
    struct Policy: Equatable {
        /// Fastest cadence (start to start).
        var minInterval: TimeInterval = 0.3
        /// Slowest cadence worth showing.
        var maxInterval: TimeInterval = 1.5
        /// Previews may keep the GPU busy at most this share of the time. The
        /// gap between previews grows with their cost to honour it. While the
        /// key is held nothing else needs the GPU, and release cancels the
        /// preview in flight, so the share is high. A preview that can't
        /// honour it even at `maxInterval` (here: one taking over 1.125 s) is
        /// slow: a slower Mac (a base M1, by GPU size, takes about 3× as long)
        /// spaces previews out, and turns them off when they take that long.
        var maxBusyFraction: Double = 0.75
        /// Consecutive slow previews that turn previews off for the app run.
        var slowLimit = 2
        /// A release that waited longer than this for a cancelled preview to
        /// stop has cost the final pass too much…
        var maxReleaseWait: TimeInterval = 0.15
        /// …and this many in a row turn previews off for the app run.
        var releaseWaitLimit = 2
        /// No preview before this much audio, or before this much is new.
        var minAudio: TimeInterval = 0.5
        var minNewAudio: TimeInterval = 0.25
        /// A preview the sidecar found silent never reached the model, so it
        /// cost next to nothing: the next one may start this soon after it,
        /// with this much new audio, so the first words aren't held back by
        /// the silence before them. nil: paced like any other preview.
        var afterSilence: TimeInterval? = 0.1
        /// The first measured preview of the run warms the GPU kernels; it
        /// paces the next one but never counts as slow.
        var warmUpPreviews = 1

        /// The policy before #46 (1–3 s apart, 30% of the GPU, from 1 s of
        /// audio), for the harness's before/after comparison.
        static let beforeShortEncode = Policy(minInterval: 1.0, maxInterval: 3.0, maxBusyFraction: 0.3,
                                              minAudio: 1.0, minNewAudio: 0.5, afterSilence: nil)
    }

    enum Decision: Equatable { case start, wait, busy, off }

    let policy: Policy
    private(set) var interval: TimeInterval
    private(set) var disabledReason: String?
    private var measured = 0
    private var slowStreak = 0
    private var failureStreak = 0
    private var releaseWaitStreak = 0

    init(policy: Policy = Policy()) {
        self.policy = policy
        interval = policy.minInterval
    }

    var isDisabled: Bool { disabledReason != nil }

    /// `lastWasSilent`: the last preview was skipped as silence (see
    /// `Policy.afterSilence`).
    func decide(now: TimeInterval, lastStart: TimeInterval?, inFlight: Bool,
                audioSeconds: Double, previewedAudioSeconds: Double, lastWasSilent: Bool = false) -> Decision {
        if isDisabled { return .off }
        if inFlight { return .busy }
        let quick = lastWasSilent ? policy.afterSilence : nil
        if audioSeconds < policy.minAudio
            || audioSeconds - previewedAudioSeconds < min(policy.minNewAudio, quick ?? .infinity) {
            return .wait
        }
        if let lastStart, now - lastStart < min(interval, quick ?? .infinity) { return .wait }
        return .start
    }

    /// The model decoded a preview (text or not): `seconds` of wall time,
    /// request to reply.
    mutating func record(seconds: Double) {
        guard !isDisabled, seconds >= 0 else { return }
        failureStreak = 0
        measure(seconds: seconds)
    }

    /// A preview failed: the sidecar errored or timed out (`seconds` nil), or
    /// the model ran and its decode failed after `seconds`. That time paces
    /// the next preview and counts toward the slow guard like any decode.
    mutating func recordFailure(seconds: Double? = nil) {
        guard !isDisabled else { return }
        if let seconds, seconds >= 0 {
            measure(seconds: seconds)
            if isDisabled { return }
        }
        failureStreak += 1
        if failureStreak >= policy.slowLimit { disabledReason = "previews failed" }
    }

    private mutating func measure(seconds: Double) {
        measured += 1
        let wanted = seconds / policy.maxBusyFraction
        interval = min(policy.maxInterval, max(policy.minInterval, wanted))
        guard measured > policy.warmUpPreviews else { return }
        let slow = wanted > policy.maxInterval
        slowStreak = slow ? slowStreak + 1 : 0
        if slowStreak >= policy.slowLimit { disabledReason = "previews can't keep up on this Mac" }
    }

    /// A release found a preview in flight and waited `seconds` for it to stop.
    mutating func recordRelease(waited seconds: Double) {
        guard !isDisabled else { return }
        releaseWaitStreak = seconds > policy.maxReleaseWait ? releaseWaitStreak + 1 : 0
        if releaseWaitStreak >= policy.releaseWaitLimit {
            disabledReason = "a cancelled preview delayed the final text"
        }
    }
}

/// Preview numbers for one sidecar. Strictly increasing, so a late cancel can
/// only ever cancel older previews: the sidecar remembers the highest one it
/// was told to cancel and skips every preview numbered at or below it.
/// Thread-safe.
final class LivePreviewSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0

    func next() -> Int { lock.lock(); defer { lock.unlock() }; last += 1; return last }
}

/// The governor and preview numbering for the whole app run, shared by every
/// hold. Thread-safe.
final class LivePreviewPacer: @unchecked Sendable {
    private let lock = NSLock()
    private var governor: LivePreviewGovernor
    private let sequence: LivePreviewSequence

    /// Pacers that talk to the same sidecar must share `sequence`.
    init(policy: LivePreviewGovernor.Policy = .init(), sequence: LivePreviewSequence = .init()) {
        governor = LivePreviewGovernor(policy: policy)
        self.sequence = sequence
    }

    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return !governor.isDisabled }
    var interval: TimeInterval { lock.lock(); defer { lock.unlock() }; return governor.interval }

    func nextSeq() -> Int { sequence.next() }

    func decide(now: TimeInterval, lastStart: TimeInterval?, inFlight: Bool,
                audioSeconds: Double, previewedAudioSeconds: Double,
                lastWasSilent: Bool = false) -> LivePreviewGovernor.Decision {
        lock.lock(); defer { lock.unlock() }
        return governor.decide(now: now, lastStart: lastStart, inFlight: inFlight,
                               audioSeconds: audioSeconds, previewedAudioSeconds: previewedAudioSeconds,
                               lastWasSilent: lastWasSilent)
    }

    func record(seconds: Double) {
        update { $0.record(seconds: seconds) }
    }

    func recordRelease(waited seconds: Double) {
        update { $0.recordRelease(waited: seconds) }
    }

    func recordFailure(seconds: Double? = nil) {
        update { $0.recordFailure(seconds: seconds) }
    }

    private func update(_ change: (inout LivePreviewGovernor) -> Void) {
        lock.lock()
        let wasDisabled = governor.isDisabled
        change(&governor)
        let reason = wasDisabled ? nil : governor.disabledReason
        lock.unlock()
        // Says why, never what was said.
        if let reason { NSLog("OLIV live preview: off until OLIV restarts — %@", reason) }
    }
}

/// Previews for one hold of the key: started when the mic is live, stopped
/// at release. Ticks on a private queue; transcribes on another, one at a time.
final class LivePreviewSession: @unchecked Sendable {
    struct Hooks {
        /// Copy the newest audio into the buffer (see AudioCapture.copyLatestSamples).
        var latestSamples: (inout [Float]) -> (copied: Int, total: Int)
        /// Blocking; `seq` identifies the preview for cancellation.
        var transcribe: (_ samples: [Float], _ seq: Int) throws -> LivePreviewResult
        /// Stop previews up to `seq`, even mid-decode. Must not block.
        var cancel: (_ through: Int) -> Void
        /// New text for the HUD, on the session's queue; never called after stop().
        var show: (_ session: LivePreviewSession, _ line: LivePreviewLine) -> Void
    }

    /// What one hold did; for tests and the latency harness. Never any text.
    struct Stats: Equatable {
        var started = 0
        var skippedBusy = 0
        var shown = 0
        var inFlightAtStop = false
        /// Release → the cancelled preview returned (nil when none was in flight).
        var releaseWait: TimeInterval?
        /// Every preview the model decoded, text or not (see `ranModel`).
        var previewSeconds: [Double] = []
        /// Seconds of audio each of those previews transcribed.
        var previewAudioSeconds: [Double] = []
        /// Previews that came back without text, by reason.
        var skipped: [String: Int] = [:]
        /// When each shown preview reached `show`, seconds after start().
        var shownAt: [TimeInterval] = []
    }

    private let pacer: LivePreviewPacer
    private let hooks: Hooks
    private let tick: TimeInterval
    private let now: () -> TimeInterval
    private let queue = DispatchQueue(label: "com.oliv.live-preview", qos: .userInitiated)
    private let work = DispatchQueue(label: "com.oliv.live-preview.work", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    // Confined to `queue`, except `stopped`, which `work` also reads under `stopLock`.
    private var buffer: [Float]
    private var inFlight: Int?
    private var lastStart: TimeInterval?
    private var previewedAudio: Double = 0
    private var stoppedAt: TimeInterval?
    private var startedAt: TimeInterval?
    /// The last preview that had text, for what is settled (LivePreview.line).
    private var lastText: String?
    /// The last preview came back "silent" (it never reached the model).
    private var lastSilent = false
    private var stats = Stats()
    private let stopLock = NSLock()
    private var stopped = false

    init(pacer: LivePreviewPacer, hooks: Hooks, tick: TimeInterval = 0.05,
         windowSamples: Int = LivePreview.windowSamples,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.pacer = pacer
        self.hooks = hooks
        self.tick = tick
        self.now = now
        buffer = [Float](repeating: 0, count: windowSamples)
    }

    func start() {
        queue.sync {
            guard timer == nil, !isStopped else { return }
            startedAt = now()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + tick, repeating: tick, leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.onTick() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Release: no more previews, and the one in flight (if any) is cancelled
    /// at once. Returns without waiting for it.
    func stop() {
        queue.sync {
            stopLock.lock(); stopped = true; stopLock.unlock()
            timer?.cancel()
            timer = nil
            guard let seq = inFlight else { return }
            stats.inFlightAtStop = true
            stoppedAt = now()
            hooks.cancel(seq)
        }
    }

    var currentStats: Stats { queue.sync { stats } }

    private var isStopped: Bool { stopLock.lock(); defer { stopLock.unlock() }; return stopped }

    private func onTick() {
        guard !isStopped else { return }
        var none: [Float] = []
        let total = hooks.latestSamples(&none).total
        let audioSeconds = Double(total) / LivePreview.sampleRate
        switch pacer.decide(now: now(), lastStart: lastStart, inFlight: inFlight != nil,
                            audioSeconds: audioSeconds, previewedAudioSeconds: previewedAudio,
                            lastWasSilent: lastSilent) {
        case .busy:
            stats.skippedBusy += 1
            return
        case .wait:
            return
        case .off:
            timer?.cancel()
            timer = nil
            return
        case .start:
            break
        }
        let (copied, _) = hooks.latestSamples(&buffer)
        guard copied > 0 else { return }
        let samples = Array(buffer.prefix(copied))
        let seq = pacer.nextSeq()
        inFlight = seq
        lastStart = now()
        previewedAudio = audioSeconds
        stats.started += 1
        let previewSeconds = Double(copied) / LivePreview.sampleRate
        work.async { [self] in
            // Released before this preview was even sent: don't send it.
            let result: LivePreviewResult?
            let began = now()
            if isStopped {
                result = LivePreviewResult(text: "", skipped: "cancelled")
            } else {
                result = try? hooks.transcribe(samples, seq)
            }
            let elapsed = now() - began
            queue.async { [self] in finish(seq: seq, result: result, elapsed: elapsed, audioSeconds: previewSeconds) }
        }
    }

    private func finish(seq: Int, result: LivePreviewResult?, elapsed: Double, audioSeconds: Double) {
        guard inFlight == seq else { return }
        inFlight = nil
        lastSilent = result?.skipped == "silent"
        if let stoppedAt {
            let waited = now() - stoppedAt
            stats.releaseWait = waited
            pacer.recordRelease(waited: waited)
            return
        }
        guard let result else {
            // The sidecar errored or timed out: nothing says the model ran.
            pacer.recordFailure()
            return
        }
        if let reason = result.skipped { stats.skipped[reason, default: 0] += 1 }
        // Skipped before decoding: cost next to nothing, so it neither paces
        // nor resets the guards.
        guard result.ranModel else { return }
        stats.previewSeconds.append(elapsed)
        stats.previewAudioSeconds.append(audioSeconds)
        if result.failed {
            pacer.recordFailure(seconds: elapsed)
            return
        }
        pacer.record(seconds: elapsed)
        guard !isStopped, !result.text.isEmpty else { return }
        let line = LivePreview.line(previous: lastText, current: result.text)
        lastText = result.text
        stats.shown += 1
        stats.shownAt.append(now() - (startedAt ?? 0))
        hooks.show(self, line)
    }
}
