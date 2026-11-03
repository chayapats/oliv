// Live preview (#26): show the words in the recording HUD while the key is
// held. Every so often the newest audio is transcribed on-device — speech to
// text only, greedy, no cleanup model — and the HUD shows the tail of it. The
// preview is never pasted, logged or kept: the final pass after release is
// exactly the one that ran before this feature, and it is what gets pasted.
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
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit, limit > 1 else { return flat }
        var cut = Substring(flat.suffix(limit - 1))
        if let space = cut.firstIndex(of: " "), cut.distance(from: cut.startIndex, to: space) <= 12 {
            cut = cut[cut.index(after: space)...]
        }
        return "…" + cut.trimmingCharacters(in: .whitespaces)
    }
}

/// One preview's outcome. `skipped` names why there is no text: "cancelled",
/// "silent", "noSpeech", "notLoaded" (previews never load a model) or "failed".
struct LivePreviewResult: Equatable {
    var text: String
    var skipped: String?

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
    func preview(samples: [Float], engine: String, seq: Int) throws -> LivePreviewResult {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let reply = try exchange(["cmd": "preview", "engine": engine, "preview_seq": seq,
                                  "pcm_b64": data.base64EncodedString()],
                                 timeout: SidecarClient.dictateTimeout)
        return LivePreviewResult(text: reply["text"] as? String ?? "", skipped: reply["skipped"] as? String)
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
    struct Policy: Equatable {
        /// Fastest cadence (start to start).
        var minInterval: TimeInterval = 1.0
        /// Slowest cadence worth showing.
        var maxInterval: TimeInterval = 3.0
        /// Previews may keep the GPU busy at most this share of the time. The
        /// gap between previews grows with their cost to honour it, so this is
        /// their real-time factor against the speech that arrives in between.
        /// A preview that can't honour it even at `maxInterval` (here: one
        /// taking over 0.9 s) is slow. (Per second of the audio window it
        /// transcribes, the factor would mostly measure Whisper's fixed 30 s
        /// encode on short windows, so that is only reported, by the harness.)
        var maxBusyFraction: Double = 0.3
        /// Consecutive slow previews that turn previews off for the app run.
        var slowLimit = 2
        /// A release that waited longer than this for a cancelled preview to
        /// stop has cost the final pass too much…
        var maxReleaseWait: TimeInterval = 0.15
        /// …and this many in a row turn previews off for the app run.
        var releaseWaitLimit = 2
        /// No preview before this much audio, or before this much is new.
        var minAudio: TimeInterval = 1.0
        var minNewAudio: TimeInterval = 0.5
        /// The first measured preview of the run warms the GPU kernels; it
        /// paces the next one but never counts as slow.
        var warmUpPreviews = 1
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

    func decide(now: TimeInterval, lastStart: TimeInterval?, inFlight: Bool,
                audioSeconds: Double, previewedAudioSeconds: Double) -> Decision {
        if isDisabled { return .off }
        if inFlight { return .busy }
        if audioSeconds < policy.minAudio || audioSeconds - previewedAudioSeconds < policy.minNewAudio {
            return .wait
        }
        if let lastStart, now - lastStart < interval { return .wait }
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

/// The governor and preview numbering for the whole app run, shared by every
/// hold. Thread-safe.
final class LivePreviewPacer: @unchecked Sendable {
    private let lock = NSLock()
    private var governor: LivePreviewGovernor
    private var lastSeq = 0

    init(policy: LivePreviewGovernor.Policy = .init()) {
        governor = LivePreviewGovernor(policy: policy)
    }

    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return !governor.isDisabled }
    var interval: TimeInterval { lock.lock(); defer { lock.unlock() }; return governor.interval }

    /// Strictly increasing for the app run, so a late cancel can only ever
    /// cancel older previews (the sidecar remembers the highest one).
    func nextSeq() -> Int { lock.lock(); defer { lock.unlock() }; lastSeq += 1; return lastSeq }

    func decide(now: TimeInterval, lastStart: TimeInterval?, inFlight: Bool,
                audioSeconds: Double, previewedAudioSeconds: Double) -> LivePreviewGovernor.Decision {
        lock.lock(); defer { lock.unlock() }
        return governor.decide(now: now, lastStart: lastStart, inFlight: inFlight,
                               audioSeconds: audioSeconds, previewedAudioSeconds: previewedAudioSeconds)
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
        var show: (_ session: LivePreviewSession, _ text: String) -> Void
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
    private var stats = Stats()
    private let stopLock = NSLock()
    private var stopped = false

    init(pacer: LivePreviewPacer, hooks: Hooks, tick: TimeInterval = 0.2,
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
                            audioSeconds: audioSeconds, previewedAudioSeconds: previewedAudio) {
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
        stats.shown += 1
        hooks.show(self, result.text)
    }
}
