// Headless A/B for live preview (#26). Each clip is played back as a real-time
// hold of the key — samples become available at the rate they were spoken —
// through the same LivePreviewSession and SidecarClient the app uses, once
// with previews off and once on (alternating which goes first). At the end of
// the clip it "releases": cancels the preview in flight, then times release →
// final text through the app's dictate call with the app's default options.
//
//   OLIV --live-preview-bench --manifest m.jsonl --audio-root dir
//        [--offset 0] [--stride 1] [--limit 0] [--engine typhoon-turbo-mlx]
//        [--gap 1.0] [--keep-on] [--aa] [--legacy] [--score-dir DIR] [--out results.json]
//
// Prints aggregates only. --out gets per-clip numbers (ids, timings, whether
// the two finals were byte-identical) — never transcripts. --keep-on stops the
// governor from turning previews off, to measure their raw cost. --aa runs
// both arms with previews off: the noise floor of the comparison itself.
// --legacy previews as before #46 (full 30 s encode, raw text, 1–3 s apart),
// for before/after numbers from one build. --score-dir writes the last preview
// shown before each release next to that clip's final, as `oliv-dev score` /
// `semantic` input (transcripts: keep it private and local).
// Exits 1 when a clip failed or a clip's two finals differ.
//
// First-word latency is from the clip's speech onset (the first 20 ms frame
// whose RMS reaches a tenth of the clip's 95th-percentile frame RMS, and at
// least 0.005) to the first preview shown; cadence is the time between shown
// previews. Neither includes the main-thread hop and SwiftUI's redraw.

import Darwin
import Foundation

enum LivePreviewBench {
    struct Clip {
        let id: String
        let samples: [Float]
        var seconds: Double { Double(samples.count) / LivePreview.sampleRate }
    }

    private struct Run {
        var latency: Double
        var sttSeconds: Double
        var final: String
        var stats: LivePreviewSession.Stats?
        var load: Double
        /// The last preview shown before release (never printed).
        var lastShown: String?
    }

    /// How previews are made: today's, or as before #46 (`--legacy`).
    struct Mode {
        var policy: LivePreviewGovernor.Policy
        var tick: TimeInterval
        /// The light cleanup's options; nil shows the raw transcript.
        var cleanup: DictationOptions?
        var extra: [String: Any]

        static let current = Mode(policy: .init(), tick: 0.05,
                                  cleanup: DictationOptions(cleanup: true, removeFillers: true, thaiFormat: true),
                                  extra: [:])
        static let legacy = Mode(policy: .beforeShortEncode, tick: 0.2, cleanup: nil,
                                 extra: ["preview_floor": 30.0, "preview_tail": 0.0])
    }

    /// Where speech starts in `samples`, in seconds (see the header).
    static func speechOnset(_ samples: [Float], sampleRate: Double = LivePreview.sampleRate) -> Double? {
        let frame = Int(sampleRate * 0.02)
        guard frame > 0, samples.count >= frame else { return nil }
        let rms = stride(from: 0, to: samples.count - frame + 1, by: frame).map { start -> Float in
            var sum: Float = 0
            for i in start..<(start + frame) { sum += samples[i] * samples[i] }
            return (sum / Float(frame)).squareRoot()
        }
        let p95 = rms.sorted()[Int(Double(rms.count - 1) * 0.95)]
        let threshold = max(0.005, p95 / 10)
        return rms.firstIndex { $0 >= threshold }.map { Double($0 * frame) / sampleRate }
    }

    /// Samples become available at the rate they were recorded, from `start`.
    private final class SimulatedHold: @unchecked Sendable {
        let samples: [Float]
        let start = ProcessInfo.processInfo.systemUptime
        init(samples: [Float]) { self.samples = samples }

        func copyLatest(into buffer: inout [Float]) -> (copied: Int, total: Int) {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let available = min(samples.count, Int(elapsed * LivePreview.sampleRate))
            let count = min(buffer.count, available)
            buffer.withUnsafeMutableBufferPointer { destination in
                samples.withUnsafeBufferPointer { source in
                    guard count > 0, let from = source.baseAddress, let to = destination.baseAddress else { return }
                    to.update(from: from + (available - count), count: count)
                }
            }
            return (count, available)
        }
    }

    /// What fails a run: a clip that couldn't be held and released (it is
    /// missing from every total), or a clip whose two finals differ (they
    /// must be byte-identical).
    private struct Outcome {
        var failedClips = 0
        var differingFinals = 0

        var exitCode: Int32 { failure == nil ? 0 : 1 }

        /// Why the run failed; nil when it passed.
        var failure: String? {
            var reasons: [String] = []
            if failedClips > 0 { reasons.append("\(failedClips) clip(s) failed and are left out of the totals") }
            if differingFinals > 0 { reasons.append("\(differingFinals) clip(s) had finals that differ between the arms") }
            return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
        }
    }

    /// The pacer for the measured holds, and one for the warm-up. Separate
    /// governors, so the warm-up never paces what is measured, but one preview
    /// numbering: the sidecar skips every preview numbered at or below the
    /// highest it was told to cancel, so measured previews numbered from 1
    /// again would be skipped after a warm-up release cancelled one.
    /// The gate is byte-identical finals: Swift's `==` treats canonically
    /// equivalent strings (composed é vs e + combining accent) as equal, so
    /// compare the UTF-8 bytes.
    static func sameBytes(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    static func pacers(policy: LivePreviewGovernor.Policy) -> (warmUp: LivePreviewPacer, measured: LivePreviewPacer) {
        let sequence = LivePreviewSequence()
        return (LivePreviewPacer(sequence: sequence), LivePreviewPacer(policy: policy, sequence: sequence))
    }

    static func run(args: [String], launch: SidecarClient.Launch = SidecarClient.resolveLaunch()) -> Int32 {
        if args.contains("--cost") { return LivePreviewCostBench.run(args: args, launch: launch) }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let manifest = value("--manifest"), let root = value("--audio-root") else {
            FileHandle.standardError.write(Data("usage: --live-preview-bench --manifest FILE --audio-root DIR\n".utf8))
            return 2
        }
        let offset = Int(value("--offset") ?? "") ?? 0
        let stride = max(1, Int(value("--stride") ?? "") ?? 1)
        let limit = Int(value("--limit") ?? "") ?? 0
        let engine = value("--engine") ?? SidecarClient.defaultEngine
        let gap = Double(value("--gap") ?? "") ?? 1.0
        let control = args.contains("--aa")
        var mode = args.contains("--legacy") ? Mode.legacy : Mode.current
        if args.contains("--keep-on") {
            mode.policy.slowLimit = .max
            mode.policy.releaseWaitLimit = .max
        }
        let policy = mode.policy

        let clips: [Clip]
        do {
            clips = try load(manifest: manifest, root: root, offset: offset, stride: stride, limit: limit)
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            return 1
        }
        guard !clips.isEmpty else { return 1 }
        print("=== OLIV live-preview \(control ? "A/A control (previews off in both arms)" : "A/B"): "
            + "\(clips.count) clips, engine \(engine)\(args.contains("--legacy") ? ", previews as before #46" : "") ===")
        print("  load averages at start: \(loadAverages())")

        let client = SidecarClient(command: launch.command, environment: launch.environment)
        defer { client.close() }
        do {
            _ = try client.warm(engine: engine, cleanup: true)
        } catch {
            FileHandle.standardError.write(Data("FAIL: warm: \(error)\n".utf8))
            return 1
        }
        let (warmUp, pacer) = pacers(policy: policy)
        // Warm the GPU kernels for both paths once; not measured.
        _ = try? hold(clips[0], previews: true, engine: engine, client: client, pacer: warmUp, mode: mode)

        var rows: [[String: Any]] = []
        var off: [Double] = [], on: [Double] = [], deltas: [Double] = [], loads: [Double] = []
        var identical = 0, inFlight: [(wait: Double, delta: Double)] = []
        var started = 0, shown = 0, skippedBusy = 0, previewSeconds: [Double] = []
        var finalSTT: [Double] = [], skipped: [String: Int] = [:], realTimeFactors: [Double] = []
        var firstWord: [Double] = [], cadence: [Double] = [], noneShown = 0
        var releaseJump: [(id: String, final: String, preview: String)] = []
        var outcome = Outcome()
        for (index, clip) in clips.enumerated() {
            do {
                var runs: [Bool: Run] = [:]
                for previews in index % 2 == 0 ? [false, true] : [true, false] {
                    Thread.sleep(forTimeInterval: gap)
                    runs[previews] = try hold(clip, previews: previews && !control, engine: engine,
                                              client: client, pacer: pacer, mode: mode)
                }
                guard let a = runs[false], let b = runs[true] else {
                    outcome.failedClips += 1
                    continue
                }
                off.append(a.latency); on.append(b.latency); deltas.append(b.latency - a.latency)
                loads.append(contentsOf: [a.load, b.load])
                let same = sameBytes(a.final, b.final)
                if same { identical += 1 } else { outcome.differingFinals += 1 }
                let stats = b.stats ?? LivePreviewSession.Stats()
                started += stats.started; shown += stats.shown; skippedBusy += stats.skippedBusy
                previewSeconds += stats.previewSeconds
                realTimeFactors += zip(stats.previewSeconds, stats.previewAudioSeconds).map { $0 / $1 }
                finalSTT.append(a.sttSeconds)
                skipped.merge(stats.skipped, uniquingKeysWith: +)
                if stats.inFlightAtStop { inFlight.append((stats.releaseWait ?? 0, b.latency - a.latency)) }
                let onset = speechOnset(clip.samples)
                var clipFirstWord: Double?
                if !control {
                    if let first = stats.shownAt.first, let onset {
                        clipFirstWord = first - onset
                        firstWord.append(first - onset)
                    } else if stats.shownAt.isEmpty {
                        noneShown += 1
                    }
                    cadence += zip(stats.shownAt.dropFirst(), stats.shownAt).map { $0 - $1 }
                    releaseJump.append((clip.id, b.final, b.lastShown ?? ""))
                }
                rows.append(["id": clip.id, "seconds": clip.seconds, "latency_off": a.latency,
                             "latency_on": b.latency, "identical": same, "previews": stats.started,
                             "shown": stats.shown, "in_flight_at_release": stats.inFlightAtStop,
                             "release_wait": stats.releaseWait as Any? ?? NSNull(),
                             "load_off": a.load, "load_on": b.load,
                             "speech_onset": onset as Any? ?? NSNull(),
                             "first_word": clipFirstWord as Any? ?? NSNull(), "shown_at": stats.shownAt,
                             "preview_seconds": stats.previewSeconds])
                print(String(format: "  %3d/%d  off %4.0f ms  on %4.0f ms  previews %d%@%@",
                             index + 1, clips.count, a.latency * 1000, b.latency * 1000, stats.started,
                             stats.inFlightAtStop ? "  in flight at release" : "",
                             same ? "" : "  FINAL DIFFERS"))
            } catch {
                outcome.failedClips += 1
                FileHandle.standardError.write(Data("  clip \(index + 1) failed: \(error)\n".utf8))
            }
        }

        func ms(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "n/a" }
            return String(format: "median %.0f ms, p90 %.0f ms, mean %.0f ms",
                          percentile(values, 0.5) * 1000, percentile(values, 0.9) * 1000,
                          values.reduce(0, +) / Double(values.count) * 1000)
        }
        let summary: [String: Any] = [
            "clips": off.count, "engine": engine,
            "off": stats(off), "on": stats(on), "delta": stats(deltas),
            "identical_finals": identical,
            "previews_started": started, "previews_shown": shown, "skipped_busy": skippedBusy,
            "preview_seconds": stats(previewSeconds), "final_stt_seconds": stats(finalSTT),
            "preview_real_time_factor": stats(realTimeFactors),
            "skipped": skipped,
            "in_flight_at_release": inFlight.count,
            "release_wait": stats(inFlight.map(\.wait)), "in_flight_delta": stats(inFlight.map(\.delta)),
            "load1": stats(loads), "previews_still_on": pacer.isEnabled, "final_interval": pacer.interval,
            "first_word": stats(firstWord), "cadence": stats(cadence), "holds_without_preview": noneShown,
            "failed_clips": outcome.failedClips, "differing_finals": outcome.differingFinals,
        ]
        print("\n  clips: \(off.count)")
        print("  release → text, previews off: \(ms(off))")
        print("  release → text, previews on:  \(ms(on))")
        print("  paired difference (on − off): \(ms(deltas))")
        print("  finals byte-identical: \(identical)/\(off.count)")
        print("  previews: \(started) started, \(shown) shown, \(skippedBusy) ticks skipped while one ran; "
            + "each \(ms(previewSeconds)); without text: \(skipped.sorted { $0.key < $1.key })")
        print("  the final pass's own STT (previews off): \(ms(finalSTT))")
        print(String(format: "  preview real-time factor (seconds per second of audio window): median %.2f, p90 %.2f",
                     percentile(realTimeFactors, 0.5), percentile(realTimeFactors, 0.9)))
        if !control {
            print("  first word (speech onset → first preview shown): \(ms(firstWord)); "
                + "holds with no preview shown: \(noneShown)")
            print("  cadence (between shown previews): \(ms(cadence))")
        }
        print("  in flight at release: \(inFlight.count); release waited \(ms(inFlight.map(\.wait))); "
            + "their difference \(ms(inFlight.map(\.delta)))")
        print(String(format: "  1-min load average at release: median %.1f, min %.1f, max %.1f",
                     percentile(loads, 0.5), loads.min() ?? 0, loads.max() ?? 0))
        print("  previews still on at the end: \(pacer.isEnabled), interval \(String(format: "%.2f", pacer.interval)) s")
        print("  load averages at end: \(loadAverages())")
        if let out = value("--out") {
            let report: [String: Any] = ["summary": summary, "clips": rows]
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: out), options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("FAIL: could not write \(out)\n".utf8))
                return 1
            }
        }
        if let directory = value("--score-dir"), !releaseJump.isEmpty {
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let clips = releaseJump.filter { !$0.final.isEmpty }
                    .map { ["id": $0.id, "reference": $0.final, "final": $0.preview] }
                let data = try JSONSerialization.data(withJSONObject: ["clips": clips], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("last-preview-vs-final.json"),
                               options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("FAIL: could not write the score file\n".utf8))
                return 1
            }
        }
        if let failure = outcome.failure { print("  FAIL: \(failure)") }
        return outcome.exitCode
    }

    /// Hold the key for the clip's length (previews running or not), release,
    /// and time release → final text.
    private static func hold(_ clip: Clip, previews: Bool, engine: String, client: SidecarClient,
                             pacer: LivePreviewPacer, mode: Mode) throws -> Run {
        let hold = SimulatedHold(samples: clip.samples)
        var session: LivePreviewSession?
        let shown = LastShown()
        if previews {
            session = LivePreviewSession(pacer: pacer, hooks: .init(
                latestSamples: { hold.copyLatest(into: &$0) },
                transcribe: { samples, seq in
                    try client.preview(samples: samples, engine: engine, seq: seq, cleanup: mode.cleanup,
                                       extra: mode.extra)
                },
                cancel: { client.cancelPreviews(through: $0) },
                show: { _, line in shown.set(line.text) }), tick: mode.tick)
            session?.start()
        }
        Thread.sleep(forTimeInterval: max(0, hold.start + clip.seconds - ProcessInfo.processInfo.systemUptime))
        let load = loadAverage1()
        let released = ProcessInfo.processInfo.systemUptime
        session?.stop()
        let result = try client.dictate(samples: clip.samples, engine: engine, cleanup: true,
                                        removeFillers: true, thaiFormat: true)
        let latency = ProcessInfo.processInfo.systemUptime - released
        // Let a cancelled preview's bookkeeping land before reading the stats.
        if let session { waitForQuiet(session) }
        return Run(latency: latency, sttSeconds: result.tSTT, final: result.textToPaste,
                   stats: session?.currentStats, load: load, lastShown: shown.text)
    }

    private final class LastShown: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ text: String) { lock.lock(); value = text; lock.unlock() }
        var text: String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func waitForQuiet(_ session: LivePreviewSession) {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            let stats = session.currentStats
            if !stats.inFlightAtStop || stats.releaseWait != nil { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    static func load(manifest: String, root: String, offset: Int, stride: Int, limit: Int) throws -> [Clip] {
        let lines = try String(contentsOfFile: manifest, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var clips: [Clip] = []
        for (index, line) in lines.enumerated() where index >= offset && (index - offset) % stride == 0 {
            if limit > 0 && clips.count >= limit { break }
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = row["id"] as? String, let path = row["path"] as? String else { continue }
            let samples = try AudioCapture.decodeFile(at: (root as NSString).appendingPathComponent(path))
            if !samples.isEmpty { clips.append(Clip(id: id, samples: samples)) }
        }
        return clips
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = p * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down)), high = Int(rank.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
    }

    static func stats(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else { return ["n": 0] }
        return ["n": values.count, "median": percentile(values, 0.5), "p90": percentile(values, 0.9),
                "mean": values.reduce(0, +) / Double(values.count), "min": values.min()!, "max": values.max()!]
    }

    static func loadAverage1() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads[0] : -1
    }

    static func loadAverages() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "unavailable" }
        return String(format: "%.2f %.2f %.2f", loads[0], loads[1], loads[2])
    }
}
