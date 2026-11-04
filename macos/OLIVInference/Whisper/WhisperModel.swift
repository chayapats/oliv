// Adapted from mlx-audio-swift (MIT). See UPSTREAM.md.
import Foundation
import MLX
import MLXNN

public final class WhisperModel: Module {
    public let config: WhisperConfig
    public let generationConfig: WhisperGenerationConfig?

    @ModuleInfo(key: "model") var model: WhisperSubmodels

    var tokenizer: WhisperTokenizer?
    var coreMLEncoder: CoreMLWhisperEncoder?
    private var recoverMLXEncoder: (() throws -> WhisperEncoder)?
    private(set) var encoderDidFallback = false
    var encoderBackend: String { coreMLEncoder == nil ? "mlx" : "coreml" }

    func encodeAudio(_ input: MLXArray, shouldStop: (() -> Bool)?) throws -> MLXArray {
        if coreMLEncoder != nil {
            do { return try coreMLEncoder!.encode(input) }
            catch {
                guard recoverMLXEncoder != nil else { throw error }
                // Release the accelerator before allocating recovery weights.
                // Decoder weights and this recording's tokens remain intact.
                coreMLEncoder = nil
                encoderDidFallback = true
                Memory.clearCache()
            }
        }
        if model.encoder == nil, let recoverMLXEncoder {
            let recovered = try recoverMLXEncoder()
            try model.update(modules: ModuleChildren.unflattened([("encoder", recovered)]), verify: .noUnusedKeys)
            self.recoverMLXEncoder = nil
        }
        guard let encoder = model.encoder else { throw RuntimeError.invalidModel }
        return try shouldStop.map { try encoder(input, group: 4, shouldStop: $0) } ?? encoder(input)
    }

    public init(config: WhisperConfig, generationConfig: WhisperGenerationConfig? = nil, useMLXEncoder: Bool = true) {
        self.config = config
        self.generationConfig = generationConfig
        self._model.wrappedValue = WhisperSubmodels(config: config, useMLXEncoder: useMLXEncoder)
    }

    // MARK: - Loading

    /// Source layout for a Whisper safetensors checkpoint.
    enum WeightFormat {
        /// HuggingFace `transformers` layout (`openai/whisper-*`).
        case huggingFace
        /// OpenAI / mlx-whisper layout (`mlx-community/whisper-*`).
        case mlxWhisper
    }

    static func detectFormat(_ weights: [String: MLXArray]) -> WeightFormat {
        for key in weights.keys where key.contains(".blocks.") {
            return .mlxWhisper
        }
        return .huggingFace
    }

    static func sanitize(weights: [String: MLXArray], config: WhisperConfig) -> [String: MLXArray] {
        switch detectFormat(weights) {
        case .huggingFace: return sanitizeHuggingFace(weights)
        case .mlxWhisper: return sanitizeMlxWhisper(weights)
        }
    }

    private static func sanitizeHuggingFace(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized: [String: MLXArray] = [:]
        sanitized.reserveCapacity(weights.count)

        for (rawKey, value) in weights {
            // proj_out is tied to embed_tokens; projectToVocab uses the embedding directly.
            if rawKey == "proj_out.weight" || rawKey == "model.proj_out.weight" {
                continue
            }

            var key = rawKey
            // Re-exports that drop the top-level `model.` still need it for module lookup.
            if !key.hasPrefix("model.") {
                if key.hasPrefix("encoder.") || key.hasPrefix("decoder.") {
                    key = "model." + key
                }
            }

            var newValue = value
            if (key == "model.encoder.conv1.weight" || key == "model.encoder.conv2.weight"), newValue.ndim == 3 {
                // PyTorch Conv1d: [out, in, kernel] -> MLX Conv1d: [out, kernel, in]
                newValue = newValue.transposed(0, 2, 1)
            }
            sanitized[key] = newValue
        }

        return sanitized
    }

    private static func sanitizeMlxWhisper(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized: [String: MLXArray] = [:]
        sanitized.reserveCapacity(weights.count)

        for (rawKey, value) in weights {
            if rawKey == "alignment_heads" { continue }
            guard let mapped = remapMlxWhisperKey(rawKey) else { continue }
            sanitized[mapped] = value
        }

        // mlx-whisper omits the encoder positional embedding because it's a
        // fixed sinusoid; synthesise it so `update(parameters:verify:.all)` passes.
        let encPosKey = "model.encoder.embed_positions.weight"
        if sanitized[encPosKey] == nil, let conv2 = sanitized["model.encoder.conv2.weight"] {
            sanitized[encPosKey] = whisperSinusoids(length: 1500, channels: conv2.shape[0])
        }

        return sanitized
    }

    private static func whisperSinusoids(length: Int, channels: Int) -> MLXArray {
        precondition(channels % 2 == 0, "Whisper sinusoid channels must be even")
        let half = channels / 2
        let logTimescaleIncrement = log(10000.0) / Double(max(half - 1, 1))
        let inverse = MLX.exp(-Float(logTimescaleIncrement) * MLXArray(0..<half))
        let time = MLXArray(0..<length).expandedDimensions(axis: 1) * inverse.expandedDimensions(axis: 0)
        return concatenated([MLX.sin(time), MLX.cos(time)], axis: 1)
    }

    private static func remapMlxWhisperKey(_ rawKey: String) -> String? {
        if rawKey == "encoder.positional_embedding" {
            return "model.encoder.embed_positions.weight"
        }
        if rawKey == "decoder.positional_embedding" {
            return "model.decoder.embed_positions.weight"
        }
        if rawKey.hasPrefix("decoder.token_embedding.") {
            return "model.decoder.embed_tokens."
                + String(rawKey.dropFirst("decoder.token_embedding.".count))
        }
        if rawKey == "encoder.conv1.weight" || rawKey == "encoder.conv1.bias"
            || rawKey == "encoder.conv2.weight" || rawKey == "encoder.conv2.bias"
        {
            return "model." + rawKey
        }
        if rawKey.hasPrefix("encoder.ln_post.") {
            return "model.encoder.layer_norm." + String(rawKey.dropFirst("encoder.ln_post.".count))
        }
        if rawKey.hasPrefix("decoder.ln.") {
            return "model.decoder.layer_norm." + String(rawKey.dropFirst("decoder.ln.".count))
        }

        for stem in ["encoder", "decoder"] {
            let blocksPrefix = "\(stem).blocks."
            guard rawKey.hasPrefix(blocksPrefix) else { continue }
            let rest = rawKey.dropFirst(blocksPrefix.count)
            guard let dot = rest.firstIndex(of: ".") else { return nil }
            let layerIndex = String(rest[..<dot])
            let suffix = String(rest[rest.index(after: dot)...])
            guard let mapped = remapBlockSuffix(suffix, isDecoder: stem == "decoder") else { return nil }
            return "model.\(stem).layers.\(layerIndex).\(mapped)"
        }

        return nil
    }

    private static func remapBlockSuffix(_ suffix: String, isDecoder: Bool) -> String? {
        let attnNameMap: [String: String] = [
            "query": "q_proj", "key": "k_proj", "value": "v_proj", "out": "out_proj",
        ]

        if let rest = stripPrefix(suffix, "attn_ln.") {
            return "self_attn_layer_norm.\(rest)"
        }
        if isDecoder, let rest = stripPrefix(suffix, "cross_attn_ln.") {
            return "encoder_attn_layer_norm.\(rest)"
        }
        if let rest = stripPrefix(suffix, "mlp_ln.") {
            return "final_layer_norm.\(rest)"
        }
        if let rest = stripPrefix(suffix, "mlp1.") {
            return "fc1.\(rest)"
        }
        if let rest = stripPrefix(suffix, "mlp2.") {
            return "fc2.\(rest)"
        }
        if let rest = stripPrefix(suffix, "attn.") {
            return remapAttnSuffix(rest, container: "self_attn", attnNameMap: attnNameMap)
        }
        if isDecoder, let rest = stripPrefix(suffix, "cross_attn.") {
            return remapAttnSuffix(rest, container: "encoder_attn", attnNameMap: attnNameMap)
        }
        return nil
    }

    private static func remapAttnSuffix(
        _ suffix: String,
        container: String,
        attnNameMap: [String: String]
    ) -> String? {
        guard let dot = suffix.firstIndex(of: ".") else { return nil }
        let projName = String(suffix[..<dot])
        let tail = String(suffix[suffix.index(after: dot)...])
        guard let mappedProj = attnNameMap[projName] else { return nil }
        return "\(container).\(mappedProj).\(tail)"
    }

    private static func stripPrefix(_ string: String, _ prefix: String) -> String? {
        guard string.hasPrefix(prefix) else { return nil }
        return String(string.dropFirst(prefix.count))
    }

    public static func fromDirectory(
        _ modelDirectory: URL,
        tokenizerDirectory: URL,
        coreMLEncoderURL: URL? = nil,
        allowEncoderFallback: Bool = false
    ) async throws -> WhisperModel {
        let configURL = modelDirectory.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(WhisperConfig.self, from: configData)
        try WhisperAudio.loadMelFilters(directory: tokenizerDirectory, nMels: config.numMelBins)

        var generationConfig: WhisperGenerationConfig? = nil
        let generationConfigURL = modelDirectory.appendingPathComponent("generation_config.json")
        if FileManager.default.fileExists(atPath: generationConfigURL.path),
           let data = try? Data(contentsOf: generationConfigURL)
        {
            generationConfig = try? JSONDecoder().decode(WhisperGenerationConfig.self, from: data)
        }
        if generationConfig == nil {
            let data = try Data(contentsOf: tokenizerDirectory.appendingPathComponent("generation_config.json"))
            generationConfig = try JSONDecoder().decode(WhisperGenerationConfig.self, from: data)
        }

        let environment = ProcessInfo.processInfo.environment
        let explicitPath = environment["OLIV_WHISPER_ANE_ENCODER"]
        let encoderURL = explicitPath.map { URL(fileURLWithPath: $0) } ?? coreMLEncoderURL
        // Explicit experiments remain fail-fast unless recovery is requested;
        // benchmark results must never silently switch their encoder to MLX.
        let allowsFallback = explicitPath != nil
            ? environment["OLIV_WHISPER_ANE_FALLBACK"] == "1" : allowEncoderFallback
        var accelerated: CoreMLWhisperEncoder?
        var failedToLoad = false
        if let encoderURL {
            do { accelerated = try CoreMLWhisperEncoder(url: encoderURL, dimensions: config.dModel, melBins: config.numMelBins) }
            catch {
                guard allowsFallback else { throw error }
                failedToLoad = true
            }
        }
        let model = WhisperModel(config: config, generationConfig: generationConfig, useMLXEncoder: accelerated == nil)
        model.coreMLEncoder = accelerated
        model.encoderDidFallback = failedToLoad
        if accelerated != nil, allowsFallback {
            model.recoverMLXEncoder = { try loadEncoder(from: modelDirectory, config: config, configData: configData) }
        }
        if let quantization = try? JSONDecoder().decode(
            WhisperQuantizedModelConfig.self,
            from: configData
        ).quantization {
            quantize(
                model: model,
                groupSize: quantization.groupSize,
                bits: quantization.bits,
                filter: { path, module in
                    module is Linear || path.hasSuffix("decoder.embed_tokens")
                }
            )
        }

        let weights = try WhisperWeights.load(directory: modelDirectory)
        let selectedWeights = accelerated == nil ? weights : weights.filter {
            !$0.key.hasPrefix("encoder.") && !$0.key.hasPrefix("model.encoder.")
        }
        let sanitized = sanitize(weights: selectedWeights, config: config).mapValues { $0.dtype == .float32 ? $0.asType(.float16) : $0 }
        try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: .all)

        let tokenizerDir = tokenizerDirectory
        model.tokenizer = try await WhisperTokenizer(
            modelDirectory: modelDirectory,
            baseConfig: config,
            generationConfig: generationConfig,
            tokenizerDirectory: tokenizerDir
        )

        eval(model)
        return model
    }

    private static func loadEncoder(from directory: URL, config: WhisperConfig, configData: Data) throws -> WhisperEncoder {
        let encoder = WhisperEncoder(config: config)
        if let quantization = try? JSONDecoder().decode(WhisperQuantizedModelConfig.self, from: configData).quantization {
            quantize(model: encoder, groupSize: quantization.groupSize, bits: quantization.bits,
                     filter: { _, module in module is Linear })
        }
        let selected = try WhisperWeights.load(directory: directory).filter {
            $0.key.hasPrefix("encoder.") || $0.key.hasPrefix("model.encoder.")
        }
        let prefix = "model.encoder."
        let sanitized = sanitize(weights: selected, config: config)
        let parameters = Dictionary(uniqueKeysWithValues: sanitized.compactMap { key, value -> (String, MLXArray)? in
            guard key.hasPrefix(prefix) else { return nil }
            return (String(key.dropFirst(prefix.count)), value.dtype == .float32 ? value.asType(.float16) : value)
        })
        try encoder.update(parameters: ModuleParameters.unflattened(parameters), verify: .all)
        eval(encoder)
        return encoder
    }

}

private struct WhisperQuantizedModelConfig: Decodable {
    let quantization: WhisperQuantizationConfig?
}

private struct WhisperQuantizationConfig: Decodable {
    let groupSize: Int
    let bits: Int

    private enum CodingKeys: String, CodingKey {
        case groupSize = "group_size"
        case bits
    }
}
