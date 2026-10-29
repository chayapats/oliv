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
    }
    private struct Decoded {
        let tokens: [Int]
        let avgLogprob: Double
        let noSpeechProbability: Float
        let temperature: Float
    }

    /// Compute one spectrogram for the entire capture, then seek by Whisper's
    /// timestamp boundaries. Each recording owns its tokens and KV cache.
    func transcribe(_ samples: [Float], language requested: String?, initialPrompt: String?, fallback: Bool) throws -> Transcript {
        guard let tokenizer else { throw RuntimeError.invalidModel }
        if let requested, tokenizer.resolveLanguage(requested) == nil { throw RuntimeError.invalidLanguage }
        let padded = MLX.padded(MLXArray(samples), widths: [.init((0, WhisperAudioConfig.chunkLengthSamples))])
        let mel = WhisperAudio.logMelSpectrogram(padded, nMels: config.numMelBins).transposed(1, 0)
        let contentFrames = max(0, mel.shape[0] - 3000)
        var language = requested
        var allTokens = initialPrompt.map { tokenizer.inner.encode(" " + $0.trimmingCharacters(in: .whitespacesAndNewlines), special: false) } ?? []
        let initialCount = allTokens.count
        var promptReset = 0, seek = 0
        var scores = [Double]()
        while seek < contentFrames {
            let segmentSize = min(3000, contentFrames - seek)
            var features = mel[seek..<(seek + segmentSize)]
            if segmentSize < 3000 { features = MLX.padded(features, widths: [.init((0, 3000 - segmentSize)), .init((0, 0))]) }
            let encoder = model.encoder(features.asType(.float16).expandedDimensions(axis: 0))
            eval(encoder)
            if language == nil {
                var cache = (0..<config.decoderLayers).map { _ in WhisperLayerCache() }
                let hidden = model.decoder(tokens: MLXArray([Int32(tokenizer.startOfTranscriptId)]).expandedDimensions(axis: 0), startPosition: 0, encoderHidden: encoder, caches: &cache)
                let logits = model.decoder.projectToVocab(hidden[0, -1])
                let languages = tokenizer.languageToId.sorted { $0.key < $1.key }
                let ids = MLXArray(languages.map { Int32($0.value) })
                language = languages[logits[ids].argMax().item(Int.self)].key
            }
            var prefix = tokenizer.buildPromptTokens(language: language, timestamps: true)
            let prompt = allTokens.dropFirst(promptReset)
            if !prompt.isEmpty, let previous = tokenizer.prevSotId {
                prefix = [previous] + prompt.suffix(config.maxTargetPositions / 2 - 1) + prefix
            }
            var candidate: Decoded?
            for temperature: Float in fallback ? [0, 0.2, 0.4, 0.6, 0.8, 1] : [0] {
                let result = decode(encoder: encoder, prefix: prefix, temperature: temperature)
                candidate = result
                let text = tokenizer.decode(tokens: result.tokens)
                let compressed = try (Data(text.utf8) as NSData).compressed(using: .zlib)
                let ratio = Double(text.utf8.count) / Double(max(1, compressed.length))
                if (result.avgLogprob >= -1 && ratio <= 2.4) || result.noSpeechProbability > 0.6 { break }
            }
            guard let result = candidate else { break }
            if result.noSpeechProbability > 0.6 && result.avgLogprob <= -1 {
                seek += segmentSize
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
        }
        return Transcript(text: tokenizer.decode(tokens: Array(allTokens.dropFirst(initialCount))), avgLogprob: scores.isEmpty ? -10 : scores.reduce(0, +) / Double(scores.count), language: language ?? "en")
    }

    private func decode(encoder: MLXArray, prefix: [Int], temperature: Float) -> Decoded {
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
        let limit = min(config.maxTargetPositions / 2, config.maxTargetPositions - prefix.count)
        for step in 0..<max(1, limit) {
            var filtered = logits + (step == 0 ? firstMask : regularMask)
            filtered = timestampRules(filtered, tokens: tokens, tokenizer: tokenizer)
            let next = temperature == 0 ? filtered.argMax().item(Int.self) : categorical(filtered / temperature).item(Int.self)
            total += (filtered[next] - filtered.logSumExp()).item(Float.self)
            if next == tokenizer.endOfTextId { break }
            tokens.append(next)
            hidden = model.decoder(tokens: MLXArray([Int32(next)]).expandedDimensions(axis: 0), startPosition: prefix.count + step, encoderHidden: encoder, caches: &caches)
            logits = model.decoder.projectToVocab(hidden[0, -1]).asType(.float32)
            eval(logits)
        }
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
