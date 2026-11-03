// oliv-apple-dictation: feeds WAV clips to SpeechAnalyzer + DictationTranscriber
// and writes results that `oliv-dev score`, `oliv-dev semantic`, `oliv-dev eval
// --replay` and `oliv-dev contextasr score|run --stt-replay` read. Private
// transcripts go only to the files you name. See benchmark/dictation-transcriber.md.
import AVFoundation
import Foundation
import Speech

enum ToolError: Error, CustomStringConvertible {
    case usage(String), unavailable(String), notInstalled(String)
    var description: String {
        switch self {
        case .usage(let m): "usage: \(m)\n\n\(helpText)"
        case .unavailable(let m): m
        case .notInstalled(let m): m
        }
    }
}

let helpText = """
oliv-apple-dictation status
    Locale support, asset state, presets and authorization; changes nothing.
oliv-apple-dictation install [--locale th_TH]
    Reserve the locale and download Apple's on-device model through AssetInventory.
oliv-apple-dictation run --manifest FILE --out FILE [options]
    --audio-root DIR        relative clip paths resolve here (default: the manifest's directory)
    --buckets a,b           id-prefix buckets to keep; --limit N per bucket (0 = all)
    --stream                feed audio at real-time speed with volatile results (latency mode)
    --chunk SECONDS         input chunk length (default 0.1)
    --preset NAME           DictationTranscriber preset (default shortDictation, or
                            progressiveShortDictation with --stream)
    --no-punctuation        drop the punctuation transcription option
    --frequent-finalization add the frequentFinalization reporting option
    --contextual none|vocab|keywords
                            AnalysisContext.contextualStrings from each row's `vocab`
                            (the user's list) or `keywords` (an oracle list); default none
    --hyps-out FILE         also write {utt_id, condition, text, raw} JSONL rows
    --label TEXT            label stored in the results
    --warmup N              discarded warm-up transcriptions of the first clip (default 1)
    --locale ID             default th_TH
Manifest rows are oliv-dev manifest JSONL: id, path, reference, optional keywords, vocab,
utt_id, condition. Blank lines and lines starting with # are skipped.
OLIV_DICTATION_DEBUG=1 prints every result (time, finality, range, text) to stderr.
"""

extension Duration {
    var inSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

struct Args {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    init(_ argv: ArraySlice<String>, flags known: Set<String>) throws {
        var it = argv.makeIterator()
        while let a = it.next() {
            guard a.hasPrefix("--") else { throw ToolError.usage("unexpected argument \(a)") }
            let key = String(a.dropFirst(2))
            if known.contains(key) { flags.insert(key); continue }
            guard let v = it.next() else { throw ToolError.usage("--\(key) needs a value") }
            values[key] = v
        }
    }
}

func writeJSON(_ value: Any, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try data.write(to: url)
}

func jsonLine(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
}

/// The id prefix, as `oliv-dev`'s `metrics::bucket`.
func bucket(_ id: String) -> String {
    let prefix = String(id.prefix { $0.isASCII && $0.isLowercase })
    return prefix.isEmpty ? id : prefix
}

func osVersion() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}

func authorization() -> String {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: "authorized"
    case .denied: "denied"
    case .restricted: "restricted"
    case .notDetermined: "notDetermined"
    @unknown default: "unknown"
    }
}

@available(macOS 26.0, *)
func statusName(_ s: AssetInventory.Status) -> String {
    switch s {
    case .unsupported: "unsupported"
    case .supported: "supported (not installed)"
    case .downloading: "downloading"
    case .installed: "installed"
    @unknown default: "unknown"
    }
}

@available(macOS 26.0, *)
func resolveLocale(_ id: String) async throws -> Locale {
    guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
        throw ToolError.unavailable("DictationTranscriber does not support \(id) on this Mac")
    }
    return locale
}

@available(macOS 26.0, *)
func status(_ args: Args) async throws {
    let id = args.values["locale"] ?? "th_TH"
    let supported = await DictationTranscriber.supportedLocales
    let installed = await DictationTranscriber.installedLocales
    let lang = String(id.prefix(2))
    print("macOS \(osVersion())")
    print("speech recognition authorization (this tool): \(authorization())")
    print("DictationTranscriber supported \(lang)*: \(supported.filter { $0.identifier.hasPrefix(lang) }.map(\.identifier)) of \(supported.count)")
    print("DictationTranscriber installed: \(installed.map(\.identifier).sorted())")
    let st = await SpeechTranscriber.supportedLocales
    print("SpeechTranscriber supported \(lang)*: \(st.filter { $0.identifier.hasPrefix(lang) }.map(\.identifier)) of \(st.count)")
    if let r = SFSpeechRecognizer(locale: Locale(identifier: id)) {
        print("SFSpeechRecognizer \(id): supportsOnDeviceRecognition=\(r.supportsOnDeviceRecognition) (never used here)")
    }
    print("AssetInventory reserved: \(await AssetInventory.reservedLocales.map(\.identifier)) (max \(AssetInventory.maximumReservedLocales))")
    let locale = try await resolveLocale(id)
    let module = DictationTranscriber(locale: locale, preset: .shortDictation)
    print("\(locale.identifier) asset: \(statusName(await AssetInventory.status(forModules: [module])))")
    if let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) {
        print("best audio format: \(f)")
    }
    for name in presetNames.keys.sorted() {
        let m = DictationTranscriber(locale: locale, preset: presetNames[name]!)
        let s = statusName(await AssetInventory.status(forModules: [m]))
        print("preset \(name) [asset \(s)]: \(describe(presetNames[name]!))")
    }
}

@available(macOS 26.0, *)
func install(_ args: Args) async throws {
    let locale = try await resolveLocale(args.values["locale"] ?? "th_TH")
    let module = DictationTranscriber(locale: locale, preset: .shortDictation)
    let reserved = await AssetInventory.reservedLocales
    if !reserved.contains(where: { $0.identifier == locale.identifier }) {
        let ok = try await AssetInventory.reserve(locale: locale)
        print("reserve \(locale.identifier): \(ok)")
    }
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
        print("\(locale.identifier) asset: \(statusName(await AssetInventory.status(forModules: [module]))); nothing to download")
        return
    }
    let progress = request.progress
    let ticker = Task {
        while !Task.isCancelled {
            print(String(format: "downloading %.0f%% (%lld of %lld)", progress.fractionCompleted * 100,
                         progress.completedUnitCount, progress.totalUnitCount))
            try? await Task.sleep(for: .seconds(5))
        }
    }
    try await request.downloadAndInstall()
    ticker.cancel()
    print("\(locale.identifier) asset: \(statusName(await AssetInventory.status(forModules: [module])))")
}

func loadManifest(_ url: URL) throws -> [[String: Any]] {
    var ids = Set<String>()
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") { return nil }
        guard let row = try JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
              let id = row["id"] as? String, row["path"] is String else {
            throw ToolError.usage("manifest row without id/path in \(url.path)")
        }
        guard ids.insert(id).inserted else { throw ToolError.usage("duplicate manifest id \(id)") }
        return row
    }
}

@available(macOS 26.0, *)
func run(_ args: Args) async throws {
    guard let manifestPath = args.values["manifest"], let outPath = args.values["out"] else {
        throw ToolError.usage("run needs --manifest and --out")
    }
    let manifest = URL(fileURLWithPath: manifestPath)
    let root = URL(fileURLWithPath: args.values["audio-root"] ?? manifest.deletingLastPathComponent().path)
    var settings = Settings()
    settings.streaming = args.flags.contains("stream")
    settings.punctuation = !args.flags.contains("no-punctuation")
    settings.frequentFinalization = args.flags.contains("frequent-finalization")
    settings.preset = args.values["preset"] ?? ""
    if let c = args.values["chunk"] { settings.chunkSeconds = Double(c) ?? 0.1 }
    let contextualSource = args.values["contextual"] ?? "none"
    guard ["none", "vocab", "keywords"].contains(contextualSource) else {
        throw ToolError.usage("--contextual must be none, vocab or keywords")
    }
    settings.locale = try await resolveLocale(args.values["locale"] ?? "th_TH")
    let preset = try resolvedPreset(settings)
    let probe = DictationTranscriber(locale: settings.locale, preset: preset)
    let asset = await AssetInventory.status(forModules: [probe])
    // Never trigger a download mid-run: the model must already be on this Mac.
    guard asset == .installed else {
        throw ToolError.notInstalled("\(settings.locale.identifier) asset is \(statusName(asset)); run `install` first")
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else {
        throw ToolError.unavailable("no compatible audio format")
    }
    let wanted = Set((args.values["buckets"] ?? "").split(separator: ",").map(String.init))
    let limit = Int(args.values["limit"] ?? "0") ?? 0
    var perBucket: [String: Int] = [:]
    let rows = try loadManifest(manifest).filter { row in
        let b = bucket(row["id"] as! String)
        if !wanted.isEmpty && !wanted.contains(b) { return false }
        let n = perBucket[b, default: 0]
        if limit > 0 && n >= limit { return false }
        perBucket[b] = n + 1
        return true
    }
    guard !rows.isEmpty else { throw ToolError.usage("no selected manifest rows") }
    func audioURL(_ row: [String: Any]) -> URL {
        let p = row["path"] as! String
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : root.appendingPathComponent(p)
    }
    func contextual(_ row: [String: Any]) -> [String] {
        contextualSource == "none" ? [] : (row[contextualSource] as? [String] ?? [])
    }
    if let missing = rows.first(where: { !FileManager.default.fileExists(atPath: audioURL($0).path) }) {
        throw ToolError.usage("missing audio for \(missing["id"]!): \(audioURL(missing).path)")
    }
    let warmups = Int(args.values["warmup"] ?? "1") ?? 1
    let started = ContinuousClock.now
    var warm: [Double] = []
    if warmups > 0 {
        let clip = try loadClip(audioURL(rows[0]), as: format)
        for _ in 0..<warmups {
            let t = ContinuousClock.now
            var quick = settings
            quick.streaming = false
            _ = try await transcribe(clip, contextual: [], settings: quick, preset: try resolvedPreset(quick), format: format)
            warm.append((ContinuousClock.now - t).inSeconds)
        }
    }
    var hyps: FileHandle?
    if let h = args.values["hyps-out"] {
        let url = URL(fileURLWithPath: h)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        hyps = try FileHandle(forWritingTo: url)
    }
    var clips: [[String: Any]] = []
    var failures = 0
    for (n, row) in rows.enumerated() {
        let id = row["id"] as! String
        var clip: [String: Any] = ["id": id, "bucket": bucket(id)]
        for key in ["difficulty", "reference", "keywords", "utt_id", "condition"] {
            if let v = row[key] { clip[key] = v }
        }
        let terms = contextual(row)
        clip["n_contextual"] = terms.count
        do {
            let audio = try loadClip(audioURL(row), as: format)
            for (k, v) in try await transcribe(audio, contextual: terms, settings: settings, preset: preset, format: format) {
                clip[k] = v
            }
        } catch {
            failures += 1
            clip["raw"] = ""
            clip["final"] = ""
            clip["error"] = "\(error)"
        }
        if let hyps {
            let line = try jsonLine(["utt_id": row["utt_id"] ?? id, "condition": row["condition"] ?? "none",
                                     "text": clip["raw"]!, "raw": clip["raw"]!])
            hyps.write(Data((line + "\n").utf8))
        }
        clips.append(clip)
        if (n + 1) % 25 == 0 || n + 1 == rows.count {
            print("Transcribed \(n + 1)/\(rows.count) clips (\(failures) failed)")
        }
    }
    try hyps?.close()
    var options = describe(preset)
    options["preset"] = settings.preset.isEmpty ? (settings.streaming ? "progressiveShortDictation" : "shortDictation") : settings.preset
    let report: [String: Any] = [
        "label": args.values["label"] ?? "apple-dictation",
        "runtime": "apple-speech-analyzer",
        "engine": "apple-dictation-\(settings.locale.identifier)",
        "cleanup_model": NSNull(),
        "manifest": manifest.path,
        "mode": settings.streaming ? "stream" : "file",
        "latency_scope": settings.streaming
            ? "audio fed in real time; latency_s = end of audio (key release) to the last final result"
            : "whole file fed at once; latency_s = time to the last final result (no file conversion)",
        "config": [
            "locale": settings.locale.identifier, "options": options, "chunk_s": settings.chunkSeconds,
            "contextual": contextualSource, "audio_format": "\(format)", "asset": statusName(asset),
            "macos": osVersion(), "warmup_s": warm, "wall_s": (ContinuousClock.now - started).inSeconds,
        ] as [String: Any],
        "clips": clips,
        "failures": failures,
    ]
    try writeJSON(report, to: URL(fileURLWithPath: outPath))
    print("\(clips.count) clips, \(failures) failed; wrote \(outPath)")
}

func main() async -> Int32 {
    let argv = CommandLine.arguments
    guard argv.count >= 2 else { print(helpText); return 2 }
    guard #available(macOS 26.0, *) else {
        print("SpeechAnalyzer and DictationTranscriber need macOS 26 or later")
        return 1
    }
    do {
        let args = try Args(argv.dropFirst(2), flags: ["stream", "no-punctuation", "frequent-finalization"])
        switch argv[1] {
        case "status": try await status(args)
        case "install": try await install(args)
        case "run": try await run(args)
        case "help", "--help", "-h": print(helpText)
        default: throw ToolError.usage("unknown command \(argv[1])")
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 1
    }
}

exit(await main())
