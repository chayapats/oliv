import Foundation

/// Optional build-supplied components prepare only while dictation is idle.
/// This process has no MLX or model weights in the UI, and never downloads data.
@MainActor
final class CoreMLEncoderPreparation {
    private var process: Process?
    private var pending: DispatchWorkItem?
    private var completed = false
    private var waitingForPreparation = false
    private var generation = 0

    func cancel() {
        generation &+= 1
        pending?.cancel(); pending = nil
        // Do not block a keypress waiting for CoreML's specialization call.
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    func schedule(onReady: @escaping () -> Void) {
        guard #available(macOS 15, *) else { return }
        guard !completed, process == nil, pending == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        guard environment["OLIV_WHISPER_ANE_ENCODER"] == nil,
              environment["OLIV_WHISPER_ENCODER"] != "mlx" else { return }
        let launch = SidecarClient.resolveLaunch()
        let bin = URL(fileURLWithPath: launch.command[0]).deletingLastPathComponent()
        guard let component = CoreMLEncoderBundle.bundled(beside: bin.appendingPathComponent("oliv-inference")),
              FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("oliv-encoder-prepare").path)
        else { return }
        let home = URL(fileURLWithPath: SidecarClient.modelsHome(), isDirectory: true)
        if component.isReady(modelsHome: home) {
            completed = true
            if waitingForPreparation { onReady() }
            return
        }
        waitingForPreparation = true
        let epoch = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.pending = nil
            let process = Process()
            process.executableURL = bin.appendingPathComponent("oliv-encoder-prepare")
            process.arguments = [component.directory.path, home.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] child in
                let succeeded = child.terminationStatus == 0
                Task { @MainActor in
                    guard let self, self.generation == epoch else { return }
                    self.process = nil
                    self.completed = true // a failure retries on next app launch
                    if succeeded, component.isReady(modelsHome: home) { onReady() }
                }
            }
            self.process = process
            do { try process.run() }
            catch { self.process = nil; self.completed = true }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}
