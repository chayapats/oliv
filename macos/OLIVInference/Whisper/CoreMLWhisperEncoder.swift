import CoreML
import Foundation
import MLX

/// Experimental hybrid: Core ML owns encoder weights, the existing MLX decoder
/// keeps its tokenizer, sampling, fallback and cross-attention cache policy.
final class CoreMLWhisperEncoder {
    private let model: MLModel
    private let dimensions: Int
    private let melBins: Int
    let windows: CoreMLEncoderWindows

    init(url: URL, dimensions: Int, melBins: Int) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        if #available(macOS 14.4, *) {
            // The finite shapes repeat throughout a recording. Core ML's
            // default frequent-reshape strategy can keep flexible graphs off
            // ANE; specialize these known shapes for prediction instead.
            configuration.optimizationHints.reshapeFrequency = .infrequent
        }
        model = try MLModel(contentsOf: url, configuration: configuration)
        self.dimensions = dimensions
        self.melBins = melBins
        guard let input = model.modelDescription.inputDescriptionsByName["melspectrogram_features"]?.multiArrayConstraint,
              input.dataType == .float16,
              let output = model.modelDescription.outputDescriptionsByName["encoder_output_embeds"]?.multiArrayConstraint,
              output.dataType == .float16,
              CoreMLEncoderWindows.acceptsOutputDescription(output.shape.map(\.intValue), dimensions: dimensions) else {
            throw RuntimeError.invalidModel
        }
        let shapes: [[Int]]
        switch input.shapeConstraint.type {
        case .enumerated: shapes = input.shapeConstraint.enumeratedShapes.map { $0.map(\.intValue) }
        case .unspecified: shapes = [input.shape.map(\.intValue)]
        default: throw RuntimeError.invalidModel
        }
        guard let windows = CoreMLEncoderWindows(shapes: shapes, melBins: melBins) else { throw RuntimeError.invalidModel }
        self.windows = windows
    }

    func encode(_ input: MLXArray) throws -> MLXArray {
        guard input.ndim == 3, input.shape[0] == 1, input.shape[2] == melBins,
              windows.frames.contains(input.shape[1]) else { throw RuntimeError.invalidAudio }
        let frames = input.shape[1], encodedFrames = frames / 2
        let source = input.transposed(0, 2, 1).asType(.float16).asArray(Float16.self)
        let mel = try MLMultiArray(shape: [1, NSNumber(value: melBins), 1, NSNumber(value: frames)], dataType: .float16)
        source.withUnsafeBufferPointer { buffer in
            mel.dataPointer.copyMemory(from: buffer.baseAddress!, byteCount: buffer.count * MemoryLayout<Float16>.stride)
        }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["melspectrogram_features": mel]))
        guard let hidden = result.featureValue(for: "encoder_output_embeds")?.multiArrayValue,
              hidden.shape.map(\.intValue) == [1, dimensions, 1, encodedFrames], hidden.dataType == .float16 else {
            throw RuntimeError.invalidModel
        }
        // Respect Core ML's strides rather than assuming the result is packed.
        let pointer = hidden.dataPointer.assumingMemoryBound(to: Float16.self)
        let strides = hidden.strides.map(\.intValue)
        var values = [Float16](repeating: 0, count: encodedFrames * dimensions)
        for t in 0..<encodedFrames {
            for d in 0..<dimensions { values[t * dimensions + d] = pointer[d * strides[1] + t * strides[3]] }
        }
        return MLXArray(values, [1, encodedFrames, dimensions])
    }
}
