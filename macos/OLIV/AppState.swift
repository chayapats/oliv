// Shared observable app state: what the menu-bar icon and menu render.
//
// W3-T1 ships the state model + UI only; the transitions are driven by the
// hotkey/audio/sidecar layers as they land (W3-T2/T3). Keeping the enum here
// (rather than inside the hotkey layer) lets the UI compile and be smoke-run
// before any OS-integration code exists.

import Foundation

/// One utterance's lifecycle, as surfaced to the user via the menu-bar icon.
enum DictationStatus: Equatable {
    /// Waiting for the push-to-talk key.
    case idle
    /// Key held — audio is being captured.
    case recording
    /// Key released — STT + cleanup + paste in flight.
    case processing

    var symbolName: String {
        switch self {
        case .idle: return "mic"
        case .recording: return "mic.fill"
        case .processing: return "waveform"
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .recording: return "Recording…"
        case .processing: return "Transcribing…"
        }
    }
}

/// One successful dictate's headline numbers, shown as a secondary line in the
/// menu ("how long did that take / how much text landed"). Set by the release
/// worker on the sidecar path only — the test-seam transcriber has no timings.
struct LastDictationStats: Equatable {
    let chars: Int
    let sttSeconds: Double
    let cleanupSeconds: Double

    /// "1.4s · 38 chars" — total time (stt + cleanup) to one decimal. Shared
    /// by the menu line and the diagnostics report.
    var summary: String {
        String(format: "%.1fs · %d chars", sttSeconds + cleanupSeconds, chars)
    }

    /// The menu's secondary line: "Last: 1.4s · 38 chars".
    var menuLine: String { "Last: \(summary)" }
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: DictationStatus = .idle

    /// Master on/off for the push-to-talk listener (menu toggle). Off means
    /// the hotkey is ignored entirely; it does NOT quit the app.
    @Published var dictationEnabled: Bool = true

    /// Stats of the most recent successful dictate, or nil before the first
    /// one. Menu-only, never persisted.
    @Published var lastDictation: LastDictationStats?

    /// Recent transcripts for the menu's "Recent…" submenu (0.1.5). In-memory
    /// only (see TranscriptLog); recording is gated by the history toggle at
    /// the DictationController record point, and turning the toggle off clears
    /// what's retained via `clearTranscripts()`.
    @Published private(set) var transcripts = TranscriptLog()

    func recordTranscript(_ text: String) { transcripts.add(text) }

    func clearTranscripts() {
        // Publish-free when already empty: the coordinator calls this on EVERY
        // settings change while history is off, and a fresh TranscriptLog would
        // otherwise fire objectWillChange per keystroke in Settings.
        guard !transcripts.entries.isEmpty else { return }
        transcripts = TranscriptLog()
    }
}
