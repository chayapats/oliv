import AVFoundation
import CoreMedia
import Foundation
import Speech

/// How every clip in a run is transcribed.
struct Settings {
    var locale = Locale(identifier: "th_TH")
    /// A `DictationTranscriber.Preset` name; empty picks shortDictation for
    /// whole-file runs and progressiveShortDictation for streaming.
    var preset = ""
    var punctuation = true
    var frequentFinalization = false
    var streaming = false
    /// Input chunk length; in streaming mode a chunk is sent when its audio
    /// would have finished recording (real time).
    var chunkSeconds = 0.1
}

/// One result the transcriber reported, timed from the start of input.
struct Event {
    let t: Double
    let isFinal: Bool
    let text: String
    let start: Double
    var end = 0.0
    var finalization = 0.0
}

@available(macOS 26.0, *)
let presetNames: [String: DictationTranscriber.Preset] = [
    "phrase": .phrase,
    "shortDictation": .shortDictation,
    "progressiveShortDictation": .progressiveShortDictation,
    "longDictation": .longDictation,
    "progressiveLongDictation": .progressiveLongDictation,
    "timeIndexedLongDictation": .timeIndexedLongDictation,
]

@available(macOS 26.0, *)
func describe(_ p: DictationTranscriber.Preset) -> [String: Any] {
    [
        "contentHints": p.contentHints.map { "\($0)" }.sorted(),
        "transcriptionOptions": p.transcriptionOptions.map { "\($0)" }.sorted(),
        "reportingOptions": p.reportingOptions.map { "\($0)" }.sorted(),
        "attributeOptions": p.attributeOptions.map { "\($0)" }.sorted(),
    ]
}

@available(macOS 26.0, *)
func resolvedPreset(_ s: Settings) throws -> DictationTranscriber.Preset {
    let name = s.preset.isEmpty ? (s.streaming ? "progressiveShortDictation" : "shortDictation") : s.preset
    guard var p = presetNames[name] else { throw ToolError.usage("unknown preset \(name)") }
    if s.punctuation { p.transcriptionOptions.insert(.punctuation) } else { p.transcriptionOptions.remove(.punctuation) }
    // Volatile results are the live preview; whole-file runs only need finals.
    if s.streaming { p.reportingOptions.insert(.volatileResults) } else { p.reportingOptions.remove(.volatileResults) }
    if s.frequentFinalization { p.reportingOptions.insert(.frequentFinalization) }
    p.reportingOptions.remove(.alternativeTranscriptions)
    return p
}

extension CMTime {
    var secondsOrZero: Double { isNumeric ? seconds : 0 }
}

func median(_ xs: [Double]) -> Double? {
    guard !xs.isEmpty else { return nil }
    let s = xs.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

/// The committed segments of a run. Without volatile reporting every result
/// is final (macOS 27.2 then leaves `resultsFinalizationTime` at zero, so
/// `isFinal` reads false). With it, a volatile result is replaced by the next
/// result; one still pending after the analyzer finished is kept as the final
/// text for its range (`unfinalized` counts those).
func committed(_ events: [Event], volatileReporting: Bool) -> (segments: [Event], unfinalized: Int) {
    guard volatileReporting else { return (events, 0) }
    var finals: [Event] = []
    var pending: Event?
    for e in events {
        if e.isFinal { finals.append(e); pending = nil } else { pending = e }
    }
    if let pending { return (finals + [pending], 1) }
    return (finals, 0)
}

/// Segments in audio order, trimmed and joined by single spaces.
func joinSegments(_ segments: [Event]) -> String {
    segments.sorted { $0.start < $1.start }
        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

/// Transcribes one clip with a fresh analyzer (the model stays loaded for the
/// process) and returns the text plus timings.
@available(macOS 26.0, *)
func transcribe(_ clip: Clip, contextual: [String], settings: Settings,
                preset: DictationTranscriber.Preset, format: AVAudioFormat) async throws -> [String: Any] {
    let clock = ContinuousClock()
    let transcriber = DictationTranscriber(locale: settings.locale, preset: preset)
    let analyzer = SpeechAnalyzer(modules: [transcriber],
        options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
    if !contextual.isEmpty {
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextual
        try await analyzer.setContext(context)
    }
    let prepared = clock.now
    try await analyzer.prepareToAnalyze(in: format)
    let prepareSeconds = (clock.now - prepared).inSeconds
    let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
    try await analyzer.start(inputSequence: stream)
    let t0 = clock.now
    let collector = Task { () throws -> [Event] in
        var events: [Event] = []
        for try await r in transcriber.results {
            events.append(Event(t: (clock.now - t0).inSeconds, isFinal: r.isFinal,
                                text: String(r.text.characters), start: r.range.start.secondsOrZero,
                                end: r.range.end.secondsOrZero, finalization: r.resultsFinalizationTime.secondsOrZero))
        }
        return events
    }
    let rate = clip.buffer.format.sampleRate
    let chunk = AVAudioFrameCount(max(1, (settings.chunkSeconds * rate).rounded()))
    var offset: AVAudioFrameCount = 0
    while offset < clip.buffer.frameLength {
        let count = min(chunk, clip.buffer.frameLength - offset)
        if settings.streaming {
            let due = t0 + .seconds(Double(offset + count) / rate)
            try await Task.sleep(until: due, clock: clock)
        }
        input.yield(AnalyzerInput(buffer: slice(clip.buffer, from: offset, count: count)))
        offset += count
    }
    let released = (clock.now - t0).inSeconds
    input.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let finalized = (clock.now - t0).inSeconds
    let events = try await collector.value
    if ProcessInfo.processInfo.environment["OLIV_DICTATION_DEBUG"] != nil {
        for e in events {
            FileHandle.standardError.write(Data(String(format: "event t=%.3f final=%@ range=%.2f-%.2f finalizedThrough=%.2f %@\n", e.t, e.isFinal ? "yes" : "no", e.start, e.end, e.finalization, e.text).utf8))
        }
    }
    let done = (clock.now - t0).inSeconds
    let (segments, unfinalized) = committed(events, volatileReporting: preset.reportingOptions.contains(.volatileResults))
    let text = joinSegments(segments)
    var out: [String: Any] = [
        "raw": text, "final": text,
        "audio_s": clip.duration, "onset_s": clip.onset,
        "prepare_s": prepareSeconds,
        "n_segments": segments.count, "n_unfinalized": unfinalized,
    ]
    let lastFinal = segments.map(\.t).max() ?? done
    if settings.streaming {
        let shown = events.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let during = shown.filter { $0.t <= released }
        let gaps = zip(during.dropFirst(), during).map { $0.t - $1.t }
        out["released_s"] = released
        out["first_result_s"] = shown.first?.t ?? NSNull()
        out["first_result_after_onset_s"] = shown.first.map { $0.t - clip.onset } ?? NSNull()
        out["updates_before_release"] = during.count
        out["update_interval_median_s"] = median(gaps) ?? NSNull()
        out["release_to_final_s"] = max(0, lastFinal - released)
        out["finalize_return_s"] = finalized - released
        out["latency_s"] = max(0, lastFinal - released)
    } else {
        // Whole file as fast as the model goes: compute time to the last final.
        out["t_stt"] = lastFinal
        out["rtf"] = lastFinal / max(clip.duration, 0.001)
        out["latency_s"] = lastFinal
    }
    return out
}
