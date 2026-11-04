#if OLIV_STATEFUL
import CoreML
import WhisperKit

/// The sampling, timestamp and fallback policies remain WhisperKit's. Only the
/// prediction adapter changes: Core ML owns the persistent decoder KV buffers.
@available(macOS 15.0, *)
final class StatefulTextDecoder: TextDecoder {
    private var state: MLState?
    private var stateModel: ObjectIdentifier?
    private var previousPosition = -1

    override var kvCacheEmbedDim: Int? {
        guard let channels = stateShape?.dropFirst().first else { return nil }
        if model?.modelDescription.stateDescriptionsByName["key_cache"] != nil { return channels }
        let layers = model?.modelDescription.stateDescriptionsByName.keys.filter { $0.hasPrefix("key_cache_") }.count ?? 0
        return layers > 0 ? channels * layers : nil
    }
    override var kvCacheMaxSequenceLength: Int? { stateShape?.last }

    private var stateShape: [Int]? {
        guard let loaded = model,
              let description = loaded.modelDescription.stateDescriptionsByName["key_cache"]
                ?? loaded.modelDescription.stateDescriptionsByName["key_cache_0"],
              let constraint = description.stateConstraint else { return nil }
        return constraint.bufferShape
    }

    override func unloadModel() {
        state = nil
        stateModel = nil
        previousPosition = -1
        super.unloadModel()
    }

    override func predictLogits(
        inputIds: MLMultiArray,
        cacheLength: MLMultiArray,
        keyCache: MLMultiArray,
        valueCache: MLMultiArray,
        kvCacheUpdateMask: MLMultiArray,
        encoderOutputEmbeds: MLMultiArray,
        decoderKeyPaddingMask: MLMultiArray
    ) async throws -> (logits: MLMultiArray?, cache: DecodingCache?)? {
        guard let model, let length = kvCacheMaxSequenceLength,
              (model.modelDescription.stateDescriptionsByName["value_cache"] != nil ||
               model.modelDescription.stateDescriptionsByName["value_cache_0"] != nil) else {
            throw ANEWhisper.Failure.usage("Stateful decoder requires key_cache and value_cache states")
        }
        let position = cacheLength[0].intValue
        guard (0..<length).contains(position) else {
            throw ANEWhisper.Failure.usage("Stateful cache position is out of range")
        }
        // Language detection, each fallback, each audio window and each clip
        // begin at position zero. No state may leak across those boundaries.
        if position == 0 || stateModel != ObjectIdentifier(model) {
            state = model.makeState()
            stateModel = ObjectIdentifier(model)
            previousPosition = -1
        }
        guard let state, position == previousPosition + 1 else {
            throw ANEWhisper.Failure.usage("Stateful decoding requires a sequential cache; prefill cache import is unsupported")
        }
        try Task.checkCancellation()
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .float16)
        mask.dataPointer.initializeMemory(as: UInt8.self, repeating: 0,
                                          count: length * MemoryLayout<Float16>.stride)
        mask[position] = 1
        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": inputIds,
            "cache_length": cacheLength,
            "kv_cache_update_mask": mask,
            "encoder_output_embeds": encoderOutputEmbeds,
            "decoder_key_padding_mask": decoderKeyPaddingMask
        ])
        // The runner uses one worker. Keep the model and its non-Sendable state
        // on this executor, and serialize each stateful prediction explicitly.
        let output = try predict(model: model, inputs: inputs, state: state)
        previousPosition = position
        return (
            output.featureValue(for: "logits")?.multiArrayValue,
            DecodingCache(
                keyCache: output.featureValue(for: "key_cache_updates")?.multiArrayValue,
                valueCache: output.featureValue(for: "value_cache_updates")?.multiArrayValue,
                alignmentWeights: output.featureValue(for: "alignment_heads_weights")?.multiArrayValue
            )
        )
    }

    private func predict(model: MLModel, inputs: MLFeatureProvider, state: MLState) throws -> MLFeatureProvider {
        try model.prediction(from: inputs, using: state, options: MLPredictionOptions())
    }
}
#endif
