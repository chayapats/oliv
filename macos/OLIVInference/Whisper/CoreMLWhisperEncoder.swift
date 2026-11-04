import CoreML
import Foundation
import MLX

/// Experimental hybrid: Core ML owns encoder weights, the existing MLX decoder
/// keeps its tokenizer, sampling, fallback and cross-attention cache policy.
final class CoreMLWhisperEncoder {
    private let model: MLModel
    private let dimensions: Int
    private let melBins: Int

    init(url: URL, dimensions: Int, melBins: Int) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: configuration)
        self.dimensions = dimensions
        self.melBins = melBins
        guard model.modelDescription.inputDescriptionsByName["melspectrogram_features"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, melBins, 1, 3000],
              model.modelDescription.outputDescriptionsByName["encoder_output_embeds"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, dimensions, 1, 1500] else {
            throw RuntimeError.invalidModel
        }
    }

    func encode(_ input: MLXArray) throws -> MLXArray {
        guard input.shape == [1, 3000, melBins] else { throw RuntimeError.invalidAudio }
        let source = input.transposed(0, 2, 1).asType(.float16).asArray(Float16.self)
        let mel = try MLMultiArray(shape: [1, NSNumber(value: melBins), 1, 3000], dataType: .float16)
        source.withUnsafeBufferPointer { buffer in
            mel.dataPointer.copyMemory(from: buffer.baseAddress!, byteCount: buffer.count * MemoryLayout<Float16>.stride)
        }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["melspectrogram_features": mel]))
        guard let hidden = result.featureValue(for: "encoder_output_embeds")?.multiArrayValue,
              hidden.shape.map(\.intValue) == [1, dimensions, 1, 1500], hidden.dataType == .float16 else {
            throw RuntimeError.invalidModel
        }
        // Respect Core ML's strides rather than assuming the result is packed.
        let pointer = hidden.dataPointer.assumingMemoryBound(to: Float16.self)
        let strides = hidden.strides.map(\.intValue)
        var values = [Float16](repeating: 0, count: 1500 * dimensions)
        for t in 0..<1500 {
            for d in 0..<dimensions { values[t * dimensions + d] = pointer[d * strides[1] + t * strides[3]] }
        }
        return MLXArray(values, [1, 1500, dimensions])
    }
}
