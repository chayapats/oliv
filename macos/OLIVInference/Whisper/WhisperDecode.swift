// Native adaptation of mlx-whisper 0.4.3's decoding/transcribe policy (MIT).
import Foundation
import MLX
import MLXNN
import MLXRandom

extension WhisperModel {
    struct Transcript {
        let text: String
        let avgLogprob: Double
        let language: String
        let samplingFallbacks: Int
        let benchmarkSeed: UInt64?
    }
    private struct Decoded {
        let tokens: [Int]
        let avgLogprob: Double
        let noSpeechProbability: Float
        let temperature: Float
    }

    /// Thrown when `shouldStop` asks a live preview to give up mid-decode.
    struct Stopped: Error {}

    /// How a live preview runs the encoder, and where its time went.
    final class PreviewEncode {
        /// The encoder runs on at least this many seconds…
        let floorSeconds: Double
        /// …and on the audio plus this much (zero) tail, whichever is longer,
        /// never more than Whisper's 30 s window. 30 / 0 is the full window.
        let tailSeconds: Double
        private(set) var melSeconds = 0.0
        private(set) var encodeSeconds = 0.0
        private(set) var decodeSeconds = 0.0
        /// Encoder input frames of the last segment (3000 = the full window).
        private(set) var encodedFrames = 0
        /// Tokens decoded (text and timestamps), and whether a guard below cut
        /// the decode short.
        private(set) var tokens = 0
        private(set) var stoppedRepeat = false
        private(set) var stoppedLimit = false

        func tokenLimit(audioFrames: Int) -> Int { PreviewDecodeGuard.tokenLimit(audioFrames: audioFrames) }

        func decoded(tokens count: Int, repeated: Bool, limited: Bool) {
            tokens += count
            stoppedRepeat = stoppedRepeat || repeated
            stoppedLimit = stoppedLimit || limited
        }

        init(floorSeconds: Double, tailSeconds: Double) {
            self.floorSeconds = floorSeconds
            self.tailSeconds = tailSeconds
        }

        /// Encoder input frames for `content` frames of audio.
        func frames(content: Int) -> Int {
            PreviewDecodeGuard.encoderFrames(content: content, floorSeconds: floorSeconds, tailSeconds: tailSeconds)
        }

        var isFullWindow: Bool { floorSeconds >= Double(WhisperAudioConfig.chunkLengthSeconds) }

        func add(mel: Double = 0, encode: Double = 0, decode: Double = 0) {
            melSeconds += mel; encodeSeconds += encode; decodeSeconds += decode
        }

        func encoded(frames: Int) { encodedFrames = frames }
    }

    /// Compute one spectrogram for the entire capture, then seek by Whisper's
    /// timestamp boundaries. Each recording owns its tokens and KV cache.
    /// Live previews pass `shouldStop`: it is polled between groups of encoder
    /// layers, between the decoder passes and after each token. Without it
    /// (the final transcription) the computation is exactly as before.
    ///
    /// `preview` (live previews only) runs the encoder on the audio there is
    /// instead of a 30 s window padded with silence (see PreviewEncode), and
    /// records where the time went. Without it the window is 30 s, as Whisper
    /// was trained, and nothing is measured.
    func transcribe(_ samples: [Float], language requested: String?, initialPrompt: String?, fallback: Bool,
                    shouldStop: (() -> Bool)? = nil, preview: PreviewEncode? = nil) throws -> Transcript {
        let stop = { if let shouldStop, shouldStop() { throw Stopped() } }
        guard let tokenizer else { throw RuntimeError.invalidModel }
        if let requested, tokenizer.resolveLanguage(requested) == nil { throw RuntimeError.invalidLanguage }
        // Research runs need paired, repeatable temperature fallback. Normal
        // dictation retains its sampling policy when this override is absent.
        var benchmarkSeed: UInt64?
        if let raw = ProcessInfo.processInfo.environment["OLIV_WHISPER_BENCHMARK_SEED"] {
            guard let seed = UInt64(raw) else { throw RuntimeError.invalidRequest }
            benchmarkSeed = seed
            MLXRandom.seed(seed)
        }
        let clock = ContinuousClock()
        var started = clock.now
        func lap() -> Double {
            let now = clock.now
            defer { started = now }
            let elapsed = started.duration(to: now)
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        // A short encode needs only enough silence after the audio for the last
        // frames' FFT to see zeros, as they do in the 30 s window.
        let padFrames = preview.map { $0.isFullWindow ? 3000 : 100 } ?? 3000
        let padded = MLX.padded(MLXArray(samples), widths: [.init((0, padFrames * WhisperAudioConfig.hopLength))])
        let mel = WhisperAudio.logMelSpectrogram(padded, nMels: config.numMelBins).transposed(1, 0)
        if let preview { eval(mel); preview.add(mel: lap()) }
        let contentFrames = max(0, mel.shape[0] - padFrames)
        var language = requested
        var allTokens = initialPrompt.map { tokenizer.inner.encode(" " + $0.trimmingCharacters(in: .whitespacesAndNewlines), special: false) } ?? []
        let initialCount = allTokens.count
        var promptReset = 0, seek = 0
        var scores = [Double]()
        var samplingFallbacks = 0
        while seek < contentFrames {
            try stop()
            let segmentSize = min(3000, contentFrames - seek)
            var features = mel[seek..<(seek + segmentSize)]
            let wanted = preview.map { $0.frames(content: segmentSize) } ?? 3000
            let window: Int
            if let coreMLEncoder {
                guard let supported = coreMLEncoder.windows.covering(wanted) else { throw RuntimeError.invalidModel }
                window = supported
            } else { window = wanted }
            if segmentSize < window { features = MLX.padded(features, widths: [.init((0, window - segmentSize)), .init((0, 0))]) }
            let input = features.asType(.float16).expandedDimensions(axis: 0)
            if preview != nil { _ = lap() }
            // Core ML completes one bounded encoder prediction. Cancellation
            // is checked before and immediately after it, then per token.
            let encoder = try encodeAudio(input, shouldStop: shouldStop)
            eval(encoder)
            if let preview { preview.add(encode: lap()); preview.encoded(frames: window) }
            try stop()
            if language == nil {
                var cache = (0..<config.decoderLayers).map { _ in WhisperLayerCache() }
                let hidden = model.decoder(tokens: MLXArray([Int32(tokenizer.startOfTranscriptId)]).expandedDimensions(axis: 0), startPosition: 0, encoderHidden: encoder, caches: &cache)
                let logits = model.decoder.projectToVocab(hidden[0, -1])
                let languages = tokenizer.languageToId.sorted { $0.key < $1.key }
                let ids = MLXArray(languages.map { Int32($0.value) })
                language = languages[logits[ids].argMax().item(Int.self)].key
                try stop()
            }
            var prefix = tokenizer.buildPromptTokens(language: language, timestamps: true)
            let prompt = allTokens.dropFirst(promptReset)
            if !prompt.isEmpty, let previous = tokenizer.prevSotId {
                prefix = [previous] + prompt.suffix(config.maxTargetPositions / 2 - 1) + prefix
            }
            var candidate: Decoded?
            for temperature: Float in fallback ? [0, 0.2, 0.4, 0.6, 0.8, 1] : [0] {
                if temperature > 0 { samplingFallbacks += 1 }
                let result = try decode(encoder: encoder, prefix: prefix, temperature: temperature, stop: stop,
                                        preview: preview.map { ($0, $0.tokenLimit(audioFrames: segmentSize)) })
                candidate = result
                let text = tokenizer.decode(tokens: result.tokens)
                let compressed = try (Data(text.utf8) as NSData).compressed(using: .zlib)
                let ratio = Double(text.utf8.count) / Double(max(1, compressed.length))
                if (result.avgLogprob >= -1 && ratio <= 2.4) || result.noSpeechProbability > 0.6 { break }
            }
            guard let result = candidate else { break }
            if result.noSpeechProbability > 0.6 && result.avgLogprob <= -1 {
                seek += segmentSize
                if let preview { preview.add(decode: lap()) }
                continue
            }
            let tokens = result.tokens
            let singleEnding = tokens.count >= 2 && tokens[tokens.count - 2] < tokenizer.timestampBeginId && tokens.last! >= tokenizer.timestampBeginId
            let boundaries = (1..<max(1, tokens.count)).filter { tokens[$0 - 1] >= tokenizer.timestampBeginId && tokens[$0] >= tokenizer.timestampBeginId }
            var accepted = [Int]()
            if !boundaries.isEmpty {
                var last = 0
                for boundary in boundaries + (singleEnding ? [tokens.count] : []) {
                    let segment = Array(tokens[last..<boundary])
                    if !tokenizer.decode(tokens: segment).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        accepted += segment
                        scores.append(result.avgLogprob)
                    }
                    last = boundary
                }
                if singleEnding { seek += segmentSize }
                else {
                    // Guarantee progress even if a model emits a zero boundary.
                    seek += min(segmentSize, max(1, (tokens[last - 1] - tokenizer.timestampBeginId) * 2))
                }
            } else {
                accepted = tokens
                if !tokenizer.decode(tokens: tokens).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { scores.append(result.avgLogprob) }
                seek += segmentSize
            }
            allTokens += accepted
            if result.temperature > 0.5 { promptReset = allTokens.count }
            Memory.clearCache()
            if let preview { preview.add(decode: lap()) }
        }
        return Transcript(text: tokenizer.decode(tokens: Array(allTokens.dropFirst(initialCount))),
                          avgLogprob: scores.isEmpty ? -10 : scores.reduce(0, +) / Double(scores.count),
                          language: language ?? "en", samplingFallbacks: samplingFallbacks, benchmarkSeed: benchmarkSeed)
    }

    /// `preview` (live previews only) bounds the decode: at most `limit`
    /// tokens, and a repeated run of text tokens ends it (see PreviewEncode).
    private func decode(encoder: MLXArray, prefix: [Int], temperature: Float, stop: () throws -> Void,
                        preview: (encode: PreviewEncode, limit: Int)? = nil) throws -> Decoded {
        let tokenizer = tokenizer!
        var caches = (0..<config.decoderLayers).map { _ in WhisperLayerCache() }
        var hidden = model.decoder(tokens: MLXArray(prefix.map(Int32.init)).expandedDimensions(axis: 0), startPosition: 0, encoderHidden: encoder, caches: &caches)
        let sot = prefix.firstIndex(of: tokenizer.startOfTranscriptId)!
        let noSpeech = tokenizer.noSpeechId.map { softmax(model.decoder.projectToVocab(hidden[0, sot]), axis: -1)[$0].item(Float.self) } ?? 0
        var logits = model.decoder.projectToVocab(hidden[0, -1]).asType(.float32)
        var suppressed = Set(generationConfig?.suppressTokens ?? [])
        for id in [tokenizer.startOfTranscriptId, tokenizer.prevSotId, tokenizer.sotLmId, tokenizer.transcribeId, tokenizer.translateId, tokenizer.noSpeechId].compactMap({ $0 }) { suppressed.insert(id) }
        var mask = [Float](repeating: 0, count: config.vocabSize)
        for id in suppressed where id >= 0 && id < mask.count { mask[id] = -.infinity }
        let regularMask = MLXArray(mask)
        for id in tokenizer.inner.encode(" ", special: false) where id >= 0 && id < mask.count { mask[id] = -.infinity }
        mask[tokenizer.endOfTextId] = -.infinity
        let firstMask = MLXArray(mask)
        var tokens = [Int](), total: Float = 0
        let limit = min(config.maxTargetPositions / 2, config.maxTargetPositions - prefix.count, preview?.limit ?? .max)
        var repeated = false, ended = false
        for step in 0..<max(1, limit) {
            var filtered = logits + (step == 0 ? firstMask : regularMask)
            filtered = timestampRules(filtered, tokens: tokens, tokenizer: tokenizer)
            try stop()
            let next = temperature == 0 ? filtered.argMax().item(Int.self) : categorical(filtered / temperature).item(Int.self)
            total += (filtered[next] - filtered.logSumExp()).item(Float.self)
            if next == tokenizer.endOfTextId { ended = true; break }
            tokens.append(next)
            if preview != nil, let start = PreviewDecodeGuard.repeatStart(tokens, timestampBegin: tokenizer.timestampBeginId) {
                tokens.removeSubrange(start...)
                repeated = true
                break
            }
            hidden = model.decoder(tokens: MLXArray([Int32(next)]).expandedDimensions(axis: 0), startPosition: prefix.count + step, encoderHidden: encoder, caches: &caches)
            logits = model.decoder.projectToVocab(hidden[0, -1]).asType(.float32)
            eval(logits)
        }
        preview?.encode.decoded(tokens: tokens.count, repeated: repeated, limited: !ended && !repeated)
        return Decoded(tokens: tokens, avgLogprob: Double(total) / Double(tokens.count + 1), noSpeechProbability: noSpeech, temperature: temperature)
    }

    private func timestampRules(_ logits: MLXArray, tokens: [Int], tokenizer: WhisperTokenizer) -> MLXArray {
        var mask = [Float](repeating: 0, count: config.vocabSize)
        let begin = tokenizer.timestampBeginId
        mask[tokenizer.noTimestampsId] = -.infinity
        let lastTimestamp = tokens.last.map { $0 >= begin } ?? false
        let priorTimestamp = tokens.count < 2 || tokens[tokens.count - 2] >= begin
        if lastTimestamp {
            let range = priorTimestamp ? begin..<mask.count : 0..<tokenizer.endOfTextId
            for i in range { mask[i] = -.infinity }
        }
        if let timestamp = tokens.last(where: { $0 >= begin }) {
            let minimum = timestamp + (lastTimestamp && !priorTimestamp ? 0 : 1)
            for i in begin..<min(minimum, mask.count) { mask[i] = -.infinity }
        }
        if tokens.isEmpty {
            for i in 0..<begin { mask[i] = -.infinity }
            for i in min(mask.count, begin + 51)..<mask.count { mask[i] = -.infinity }
        }
        // Match the reference's probability comparison before timestamp masking.
        if logits[begin...].logSumExp().item(Float.self) > logits[0..<begin].max().item(Float.self) {
            for i in 0..<begin { mask[i] = -.infinity }
        }
        return logits + MLXArray(mask)
    }
}
