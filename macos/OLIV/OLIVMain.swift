// OLIVMain (W3-T3) — the process entry point.
//
// The Swift twin of app/__main__.py: before the SwiftUI menu-bar app ever
// builds, peek at CommandLine.arguments for the headless `--e2e-file` harness.
// This is how latency-vs-Wave-1 is measured (the Swift equivalent of the Python
// `--e2e-file`): spawn the sidecar, warm it, run one benchmark clip through
// STT→cleanup, print raw/final/per-stage + total timings, and exit(0/1) WITHOUT
// showing any UI. All other launches fall through to the normal app.

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
        // Normal launch: hand off to the SwiftUI App lifecycle.
        OLIVApp.main()
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
