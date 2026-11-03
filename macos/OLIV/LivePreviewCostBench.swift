// What one live preview costs, and how close it is to the final text (#46).
// No hold is simulated: each clip's first N seconds are previewed directly, for
// each window length and each encoder setting, and the final pass runs once on
// the whole clip with the app's default options.
//
//   OLIV --live-preview-bench --cost --manifest m.jsonl --audio-root dir
//        [--offset 0] [--stride 1] [--limit 0] [--engine typhoon-turbo-mlx]
//        [--windows 1,2,3,4,6,8,12] [--configs 30:0,0:1,4:1]
//        [--score-dir DIR] [--out results.json]
//
// A config is `floor:tail` in seconds: the encoder runs on max(audio + tail,
// floor), at most Whisper's 30 s window; `30:0` is the full window, which is
// what previews did before #46 and what every final pass does. "all" is the
// whole clip (its newest 12 s), what the preview sees at release.
//
// Prints aggregates only (timings per stage and window). --score-dir writes,
// per config, `oliv-dev score` / `oliv-dev semantic` inputs (reference vs
// "final" text per clip) — they hold transcripts, so point it at a private
// local directory. --out gets per-preview timings, never text.

import Foundation

enum LivePreviewCostBench {
    struct Config: Hashable {
        let floor: Double
        let tail: Double
        var label: String { String(format: "f%gt%g", floor, tail) }
        var isFull: Bool { floor >= 30 }
    }

    private struct Sample {
        let config: Config
        let window: String
        let audioSeconds: Double
        let total: Double
        let timings: [String: Double]
        let ranModel: Bool
    }

    private struct Texts {
        var raw = ""
        var text = ""
    }

    static func run(args: [String], launch: SidecarClient.Launch = SidecarClient.resolveLaunch()) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let manifest = value("--manifest"), let root = value("--audio-root") else {
            FileHandle.standardError.write(Data("usage: --live-preview-bench --cost --manifest FILE --audio-root DIR\n".utf8))
            return 2
        }
        let engine = value("--engine") ?? SidecarClient.defaultEngine
        let windows = (value("--windows") ?? "1,2,3,4,6,8,12").split(separator: ",").compactMap { Double($0) }
        let configs = (value("--configs") ?? "30:0,0:1,4:1").split(separator: ",").compactMap { item -> Config? in
            let parts = item.split(separator: ":").compactMap { Double($0) }
            return parts.count == 2 ? Config(floor: parts[0], tail: parts[1]) : nil
        }
        let clips: [LivePreviewBench.Clip]
        do {
            clips = try LivePreviewBench.load(manifest: manifest, root: root,
                                              offset: Int(value("--offset") ?? "") ?? 0,
                                              stride: max(1, Int(value("--stride") ?? "") ?? 1),
                                              limit: Int(value("--limit") ?? "") ?? 0)
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            return 1
        }
        guard !clips.isEmpty, !configs.isEmpty else { return 1 }
        print("=== OLIV live-preview cost: \(clips.count) clips, engine \(engine), "
            + "configs \(configs.map(\.label).joined(separator: " ")), windows \(windows) ===")
        print("  load averages at start: \(LivePreviewBench.loadAverages())")

        let client = SidecarClient(command: launch.command, environment: launch.environment)
        defer { client.close() }
        do {
            _ = try client.warm(engine: engine, cleanup: true)
        } catch {
            FileHandle.standardError.write(Data("FAIL: warm: \(error)\n".utf8))
            return 1
        }
        let sequence = LivePreviewSequence()
        // The app's default dictation options: the light cleanup uses the same.
        let options = DictationOptions(cleanup: true, removeFillers: true, thaiFormat: true)
        func preview(_ samples: [Float], _ config: Config) throws -> (LivePreviewResult, Double) {
            let began = ProcessInfo.processInfo.systemUptime
            let result = try client.preview(samples: samples, engine: engine, seq: sequence.next(), cleanup: options,
                                            extra: ["preview_floor": config.floor, "preview_tail": config.tail,
                                                    "include_raw": true])
            return (result, ProcessInfo.processInfo.systemUptime - began)
        }
        // Warm every shape once; not measured.
        for config in configs {
            for window in windows + [12] {
                _ = try? preview(Array(clips[0].samples.prefix(Int(window * LivePreview.sampleRate))), config)
            }
        }

        var samples: [Sample] = []
        var loads: [Double] = []
        var finals: [String: (raw: String, text: String)] = [:]
        var texts: [Config: [String: [String: Texts]]] = [:]   // config → clip → window → texts
        var failed = 0
        for (index, clip) in clips.enumerated() {
            do {
                loads.append(LivePreviewBench.loadAverage1())
                let final = try client.dictate(samples: clip.samples, engine: engine, cleanup: true,
                                               removeFillers: true, thaiFormat: true)
                finals[clip.id] = (final.raw, final.textToPaste)
                var cuts: [(String, [Float])] = windows.filter { $0 < clip.seconds }.map { window in
                    (String(format: "%g", window), Array(clip.samples.prefix(Int(window * LivePreview.sampleRate))))
                }
                cuts.append(("all", Array(clip.samples.suffix(LivePreview.windowSamples))))
                for config in configs {
                    for (window, audio) in cuts {
                        let (result, total) = try preview(audio, config)
                        samples.append(Sample(config: config, window: window,
                                              audioSeconds: Double(audio.count) / LivePreview.sampleRate,
                                              total: total, timings: result.timings, ranModel: result.ranModel))
                        texts[config, default: [:]][clip.id, default: [:]][window] =
                            Texts(raw: result.raw ?? "", text: result.text)
                    }
                }
                print(String(format: "  %3d/%d  %4.1f s  load %.1f", index + 1, clips.count, clip.seconds,
                             loads.last ?? -1))
            } catch {
                failed += 1
                FileHandle.standardError.write(Data("  clip \(index + 1) failed: \(error)\n".utf8))
            }
        }

        // Timings per config and window: medians of previews the model ran.
        func median(_ values: [Double]) -> Double { LivePreviewBench.percentile(values, 0.5) }
        let order = windows.map { String(format: "%g", $0) } + ["all"]
        print("\n  per preview, median ms (model ran); ipc = everything outside the sidecar's and helper's own work")
        print("  config   window   n  audio s  frames  total  ipc  helper-audio  mel  encode  decode  clean  p90 total  tok/s p99  repeat  limit")
        var summary: [String: Any] = [:]
        for config in configs {
            var rows: [String: Any] = [:]
            for window in order {
                let group = samples.filter { $0.config == config && $0.window == window && $0.ranModel }
                guard !group.isEmpty else { continue }
                func stage(_ key: String) -> [Double] { group.compactMap { $0.timings[key] } }
                let ipc = group.compactMap { sample -> Double? in
                    guard let sidecar = sample.timings["sidecar"], let stt = sample.timings["stt"] else { return nil }
                    let helper = ["audio", "mel", "encode", "decode"].compactMap { sample.timings[$0] }.reduce(0, +)
                    return (sample.total - sidecar) + (stt - helper)
                }
                let tokenRates = group.compactMap { sample in sample.timings["tokens"].map { $0 / sample.audioSeconds } }
                let row: [String: Any] = [
                    "n": group.count, "audio_seconds": median(group.map(\.audioSeconds)),
                    "frames": median(stage("frames")), "total": LivePreviewBench.stats(group.map(\.total)),
                    "ipc": LivePreviewBench.stats(ipc), "helper_audio": LivePreviewBench.stats(stage("audio")),
                    "mel": LivePreviewBench.stats(stage("mel")), "encode": LivePreviewBench.stats(stage("encode")),
                    "decode": LivePreviewBench.stats(stage("decode")), "clean": LivePreviewBench.stats(stage("clean")),
                    "tokens_per_second": LivePreviewBench.stats(tokenRates),
                    "repeat_stops": stage("repeat").reduce(0, +), "limit_stops": stage("limit").reduce(0, +),
                ]
                rows[window] = row
                print(String(format: "  %-8@ %6@ %3d  %7.1f  %6.0f  %5.0f %4.0f  %12.1f %4.1f  %6.0f  %6.0f  %5.1f  %9.0f  %8.1f  %6.0f  %5.0f",
                             config.label, window, group.count, median(group.map(\.audioSeconds)),
                             median(stage("frames")), median(group.map(\.total)) * 1000, median(ipc) * 1000,
                             median(stage("audio")) * 1000, median(stage("mel")) * 1000,
                             median(stage("encode")) * 1000, median(stage("decode")) * 1000,
                             median(stage("clean")) * 1000,
                             LivePreviewBench.percentile(group.map(\.total), 0.9) * 1000,
                             LivePreviewBench.percentile(tokenRates, 0.99), stage("repeat").reduce(0, +),
                             stage("limit").reduce(0, +)))
            }
            summary[config.label] = rows
        }
        print(String(format: "\n  1-min load average per clip: median %.1f, min %.1f, max %.1f",
                     median(loads), loads.min() ?? 0, loads.max() ?? 0))
        print("  load averages at end: \(LivePreviewBench.loadAverages())")

        if let directory = value("--score-dir") {
            do {
                try writeScoreFiles(directory: directory, configs: configs, texts: texts, finals: finals)
                print("  wrote scorer inputs to \(directory) (transcripts: keep private)")
            } catch {
                FileHandle.standardError.write(Data("FAIL: could not write score files: \(error)\n".utf8))
                return 1
            }
        }
        if let out = value("--out") {
            let rows = samples.map { sample -> [String: Any] in
                ["config": sample.config.label, "window": sample.window, "audio_seconds": sample.audioSeconds,
                 "total": sample.total, "timings": sample.timings, "ran_model": sample.ranModel]
            }
            let report: [String: Any] = ["summary": summary, "previews": rows,
                                         "load1": LivePreviewBench.stats(loads), "failed_clips": failed]
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: out), options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("FAIL: could not write \(out)\n".utf8))
                return 1
            }
        }
        return failed == 0 ? 0 : 1
    }

    /// `oliv-dev score` / `semantic` read `{"clips":[{id, reference, final}]}`.
    /// Pairs whose reference is empty are left out (nothing to compare with).
    private static func writeScoreFiles(directory: String, configs: [Config],
                                        texts: [Config: [String: [String: Texts]]],
                                        finals: [String: (raw: String, text: String)]) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        func write(_ name: String, _ pairs: [(id: String, reference: String, hypothesis: String)]) throws {
            let clips = pairs.filter { !$0.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { ["id": $0.id, "reference": $0.reference, "final": $0.hypothesis] }
            guard !clips.isEmpty else { return }
            let data = try JSONSerialization.data(withJSONObject: ["clips": clips], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".json"), options: .atomic)
        }
        let full = configs.first(where: \.isFull)
        for config in configs {
            let byClip = texts[config] ?? [:]
            let ids = byClip.keys.sorted()
            try write("\(config.label)-raw-vs-finalraw", ids.compactMap { id in
                guard let all = byClip[id]?["all"], let final = finals[id] else { return nil }
                return (id, final.raw, all.raw)
            })
            try write("\(config.label)-raw-vs-final", ids.compactMap { id in
                guard let all = byClip[id]?["all"], let final = finals[id] else { return nil }
                return (id, final.text, all.raw)
            })
            try write("\(config.label)-clean-vs-final", ids.compactMap { id in
                guard let all = byClip[id]?["all"], let final = finals[id] else { return nil }
                return (id, final.text, all.text)
            })
            guard let full, full != config, let reference = texts[full] else { continue }
            var prefix: [(String, String, String)] = []
            for id in ids {
                for (window, mine) in byClip[id] ?? [:] where window != "all" {
                    if let theirs = reference[id]?[window] { prefix.append(("\(id)@\(window)", theirs.raw, mine.raw)) }
                }
            }
            try write("\(config.label)-raw-vs-full-prefix", prefix.sorted { $0.0 < $1.0 })
        }
    }
}
