import CoreML
import Darwin
import Foundation

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify-component" {
    do {
        try CoreMLEncoderBundle(directory: URL(fileURLWithPath: CommandLine.arguments[2])).verifyModel()
        exit(0)
    } catch { fputs("Invalid encoder component.\n", stderr); exit(1) }
}

// CoreML specialization is intentionally out of process: a first load can take
// minutes, and must never hold dictation's serialized inference request queue.
// Only synthetic zero inputs are used. No checkpoint, recording or text is read.
guard CommandLine.arguments.count == 3 else {
    fputs("usage: oliv-encoder-prepare COMPONENT_DIR MODELS_HOME\n", stderr)
    exit(2)
}

do {
    let component = try CoreMLEncoderBundle(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
    let home = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let lockDirectory = home.appendingPathComponent("oliv-encoder-ready", isDirectory: true)
    try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
    let lock = open(lockDirectory.appendingPathComponent(component.fingerprint + ".lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { throw CoreMLEncoderBundle.Failure.invalidFiles }
    defer { close(lock) }
    // Leave the inode in place so concurrent launches cannot acquire two locks.
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
    if component.isReady(modelsHome: home) { exit(0) }

    let parent = getppid()
    guard parent > 1 else { exit(1) }
    let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
    pressure.setEventHandler { exit(1) }
    pressure.resume()
    let timer = DispatchSource.makeTimerSource(queue: .global())
    let deadline = ProcessInfo.processInfo.systemUptime + 600
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        if getppid() != parent || ProcessInfo.processInfo.systemUptime >= deadline { exit(1) }
    }
    timer.resume()
    defer { timer.cancel(); pressure.cancel() }

    try component.verifyModel()
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    if #available(macOS 14.4, *) { configuration.optimizationHints.reshapeFrequency = .infrequent }
    let model = try MLModel(contentsOf: component.modelURL, configuration: configuration)
    guard let input = model.modelDescription.inputDescriptionsByName["melspectrogram_features"],
          let constraint = input.multiArrayConstraint, constraint.dataType == .float16,
          let output = model.modelDescription.outputDescriptionsByName["encoder_output_embeds"]?.multiArrayConstraint,
          output.dataType == .float16
    else { throw CoreMLEncoderBundle.Failure.invalidFiles }
    let shapes = constraint.shapeConstraint.type == .enumerated
        ? constraint.shapeConstraint.enumeratedShapes.map { $0.map(\.intValue) }
        : [constraint.shape.map(\.intValue)]
    guard let windows = CoreMLEncoderWindows(shapes: shapes, melBins: 128) else {
        throw CoreMLEncoderBundle.Failure.invalidFiles
    }
    for frames in windows.frames {
        try autoreleasepool {
            let mel = try MLMultiArray(shape: [1, 128, 1, NSNumber(value: frames)], dataType: .float16)
            mel.dataPointer.initializeMemory(as: UInt16.self, repeating: 0, count: mel.count)
            let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["melspectrogram_features": mel]))
            guard let result = prediction.featureValue(for: "encoder_output_embeds")?.multiArrayValue,
                  result.dataType == .float16, result.shape.map(\.intValue) == [1, 1280, 1, frames / 2]
            else { throw CoreMLEncoderBundle.Failure.invalidFiles }
        }
    }
    try component.markReady(modelsHome: home)
    print("{\"ok\":true,\"encoder_prepared\":true}")
} catch {
    // No source paths or model content in diagnostics.
    fputs("Encoder preparation failed; dictation can continue with MLX.\n", stderr)
    exit(1)
}
