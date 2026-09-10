// OLIVMain (W3-T3) — the process entry point.
//
// The Swift twin of app/__main__.py: before the SwiftUI menu-bar app ever
// builds, peek at CommandLine.arguments for the headless `--e2e-file` harness.
// This is how latency-vs-Wave-1 is measured (the Swift equivalent of the Python
// `--e2e-file`): spawn the sidecar, warm it, run one benchmark clip through
// STT→cleanup, print raw/final/per-stage + total timings, and exit(0/1) WITHOUT
// showing any UI. All other launches fall through to the normal app.

import AVFoundation
import Foundation

@main
enum OLIVMain {
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--e2e-file") {
            guard idx + 1 < args.count else {
                FileHandle.standardError.write(Data("FAIL: --e2e-file needs a wav path\n".utf8))
                exit(2)
            }
            // NO cleanup only if the flag is present (parity with the Python
            // harness's --no-cleanup); cleanup is ON by default.
            let noCleanup = args.contains("--no-cleanup")
            exit(E2ERunner.run(wavPath: args[idx + 1], cleanup: !noCleanup))
        }
        if args.contains("--mic-probe") {
            exit(MicProbe.run(args: args))
        }
        // Normal launch: hand off to the SwiftUI App lifecycle.
        OLIVApp.main()
    }
}

/// Headless capture probe (0.1.10) — the measuring instrument for the
/// speaker-bleed work.
///
/// It records through the REAL AudioCapture with echo cancellation and ducking
/// under flag control and prints what the utterance actually contained, so "does
/// the AEC help?" is answered by two recordings of the same music rather than by
/// an opinion. It lives inside the app binary ON PURPOSE: the voice-processing
/// unit refuses to initialise without microphone TCC (measured: OSStatus -10875
/// from a plain command-line tool), so the probe has to run as the signed,
/// mic-authorised app to mean anything.
///
///   OLIV.app/Contents/MacOS/OLIV --mic-probe 5 --no-aec --out /tmp/clip.wav
enum MicProbe {
    static func run(args: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let seconds = Double(value("--mic-probe") ?? "") ?? 5
        let aec = !args.contains("--no-aec")
        let duck = !args.contains("--no-duck")
        let outPath = value("--out")

        // Same launch recovery the app does: a previous probe killed while it had
        // the volume ducked must not leave this machine quiet, and a probe that
        // never ducks (--no-duck, or the AEC path where macOS owns the dip) would
        // otherwise never reach the per-duck sweep either.
        OutputDucker.restoreOrphaned()

        let capture = AudioCapture()
        // EVERY return below leaves through here, and it restores the output
        // volume SYNCHRONOUSLY. `stop()` only starts a 120 ms fade on a private
        // queue, so any early exit after it — an unwritable --out path is the easy
        // one — used to race the fade and exit with the machine still quiet, i.e.
        // this probe inflicting failure mode 3 from OutputDucker's header on the
        // user it exists to measure for. `shutdown(immediate:)` is idempotent and
        // asks the ducker rather than a flag, so it is also correct on the paths
        // where nothing was ever ducked.
        defer { capture.shutdown(immediate: true) }
        capture.echoCancellation = aec
        capture.duckOtherAudio = duck
        if let uid = value("--device") { capture.deviceSelection = uid }

        print("=== OLIV mic probe ===")
        print("  seconds: \(seconds)  echo-cancel: \(aec)  duck: \(duck)")
        guard capture.authorizationStatus() == .authorized else {
            let message = "FAIL: microphone access is \(capture.authorizationStatus()) — run "
                + "the installed, mic-authorised OLIV.app binary\n"
            FileHandle.standardError.write(Data(message.utf8))
            return 2
        }
        do {
            try capture.start()
        } catch {
            FileHandle.standardError.write(Data("FAIL: capture start: \(error)\n".utf8))
            return 1
        }
        print("  recording… (play the music you want to test against)")
        Thread.sleep(forTimeInterval: seconds)
        let samples = capture.stop()
        guard let stats = capture.stats else { return 1 }

        print(String(format: "  backend=%@ live=%@ samples=%d duration=%.2fs peak=%.4f rms=%.5f",
                     stats.backend.rawValue, stats.deviceLive ? "yes" : "no",
                     stats.sampleCount, stats.durationSeconds, stats.peak, stats.rms))
        if let outPath = outPath {
            do {
                try write(samples: samples, to: outPath)
                print("  wrote \(outPath)")
            } catch {
                FileHandle.standardError.write(Data("FAIL: could not write \(outPath): \(error)\n".utf8))
                return 1
            }
        }
        return 0   // the deferred shutdown puts the volume back before we exit
    }

    /// Write the 16 kHz mono capture out as a WAV so it can be listened to and
    /// re-run through the sidecar (`--e2e-file`).
    private static func write(samples: [Float], to path: String) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.targetSampleRate,
            channels: 1, interleaved: false)
        else { throw AudioCapture.CaptureError.converterUnavailable }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioCapture.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: settings)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))
        else { throw AudioCapture.CaptureError.converterUnavailable }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        // An EMPTY capture is a legal outcome here (the device never woke, no
        // callback arrived) and it is exactly the case worth writing out and
        // looking at — so it must not be the case that crashes the probe on a
        // force-unwrapped base address of an empty buffer.
        if let channel = buffer.floatChannelData, !samples.isEmpty {
            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                channel[0].update(from: base, count: samples.count)
            }
        }
        try file.write(from: buffer)
    }
}

/// Headless STT→cleanup latency harness (NO inject — pasting into a background
/// job's focus is unsafe, exactly as the Python `--e2e-file` notes).
enum E2ERunner {
    static func run(wavPath: String, cleanup: Bool) -> Int32 {
        print("=== OLIV Swift end-to-end file test (STT -> cleanup, NO inject) ===\n")
        // W3-T4: resolve the SAME launch config the live app uses — bundled
        // embedded runtime if the .app ships one, else the dev repo venv. Print
        // which one so the packaged e2e can assert it ran on the bundled runtime.
        let launch = SidecarClient.resolveLaunch()
        print("  clip:    \(wavPath)")
        print("  runtime: \(launch.bundled ? "bundled (embedded CPython)" : "dev repo (.venv)")")
        print("  python:  \(launch.command.first ?? "?")")
        print("  root:    \(launch.root)")
        print("  cleanup: \(cleanup ? "on" : "off")")

        // [1/3] Decode the clip to the exact 16 kHz mono Float32 array the live
        // mic tap produces (the SidecarClient payload contract).
        let samples: [Float]
        do {
            print("\n[1/3] Decoding clip to 16 kHz mono float32 ...")
            samples = try AudioCapture.decodeFile(at: wavPath)
        } catch {
            FileHandle.standardError.write(Data("FAIL: could not decode \(wavPath): \(error)\n".utf8))
            return 1
        }
        guard !samples.isEmpty else {
            FileHandle.standardError.write(Data("FAIL: decoded 0 samples from \(wavPath)\n".utf8))
            return 1
        }
        print("  samples=\(samples.count)  duration=\(String(format: "%.2f", Double(samples.count) / 16000))s")

        let client = SidecarClient(command: launch.command, environment: launch.environment)
        defer { client.close() }   // reap the child before we exit — no orphan.

        // [2/3] Warm both stages (front-loads model load / first-run download).
        do {
            print("\n[2/3] Warming sidecar (STT + cleanup) ...")
            let t0 = Date()
            let warm = try client.warm(cleanup: cleanup)
            print(String(format: "  STT load: %.2fs  cleanup load: %.2fs  (wall %.1fs)",
                         warm.tSTTLoad, warm.tCleanupLoad, Date().timeIntervalSince(t0)))
        } catch {
            FileHandle.standardError.write(Data("FAIL: warm failed: \(error)\n".utf8))
            return 1
        }

        // [3/3] Dictate — the measured path.
        let result: DictationResult
        let wall: Double
        do {
            print("\n[3/3] Dictate (STT -> cleanup) ...")
            let t0 = Date()
            result = try client.dictate(samples: samples, cleanup: cleanup)
            wall = Date().timeIntervalSince(t0)
        } catch {
            FileHandle.standardError.write(Data("FAIL: dictate failed (utterance lost): \(error)\n".utf8))
            return 1
        }

        print("\n  RAW   : \(result.raw)")
        print("  FINAL : \(result.final)")
        print(String(
            format: "  timings: t_stt=%.0fms  t_cleanup=%.0fms  total=%.0fms  llm_ran=%@  gate=%@  guardrail=%@",
            result.tSTT * 1000, result.tCleanup * 1000, wall * 1000,
            result.llmRan ? "true" : "false",
            result.gateReason.isEmpty ? "-" : result.gateReason,
            result.guardrailFlag.isEmpty ? "-" : result.guardrailFlag))
        if let err = result.cleanupError {
            print("  cleanup fell back to raw: \(err)")
        }
        print("\n=== e2e file done ===")
        return 0
    }
}
