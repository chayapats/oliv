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
        case .idle: return String(localized: "Idle")
        case .recording: return String(localized: "Recording…")
        case .processing: return String(localized: "Transcribing…")
        }
    }
}

/// User-visible execution location; unknown engines never imply local privacy.
enum DictationExecution: Equatable {
    case onDevice(String), olivAPI, olivTrial, groq, unknown

    init(engineID: String) {
        switch engineID {
        case "typhoon-turbo-mlx": self = .onDevice("Typhoon")
        case "pathumma-mlx": self = .onDevice("Pathumma")
        case "mlx-large-v3": self = .onDevice("Whisper")
        case OLIVAPIClient.engineID: self = .olivAPI
        case CloudTrial.engineID: self = .olivTrial
        case SidecarClient.cloudEngine: self = .groq
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .onDevice(let name): return String(localized: "On-device · \(name)")
        case .olivAPI: return String(localized: "Cloud · OLIV API")
        case .olivTrial: return String(localized: "Cloud · OLIV free trial")
        case .groq: return String(localized: "Cloud · Groq")
        case .unknown: return String(localized: "Unknown engine")
        }
    }

    /// `label` in English, for the wrong-result report: a public GitHub issue
    /// that maintainers read, the same from every Mac.
    var reportLabel: String {
        switch self {
        case .onDevice(let name): return "On-device · \(name)"
        case .olivAPI: return "Cloud · OLIV API"
        case .olivTrial: return "Cloud · OLIV free trial"
        case .groq: return "Cloud · Groq"
        case .unknown: return "Unknown engine"
        }
    }

    var systemImage: String {
        switch self {
        case .onDevice: return "desktopcomputer"
        case .olivAPI, .olivTrial, .groq: return "cloud"
        case .unknown: return "questionmark.circle"
        }
    }

    var detail: String {
        switch self {
        case .onDevice: return String(localized: "Audio stays on this Mac.")
        case .olivAPI: return String(localized: "Audio is sent to OLIV API for transcription and cleanup.")
        case .olivTrial: return String(localized: "Free trial: audio is sent to the OLIV server until the on-device models finish downloading.")
        case .groq: return String(localized: "Audio is sent to Groq for transcription. Cleanup, when enabled, runs on this Mac.")
        case .unknown: return String(localized: "Check the selected dictation engine.")
        }
    }
}

/// One successful dictate's headline numbers, shown as a secondary line in the
/// menu ("how long did that take / how much text landed"). Set by the release
/// worker on the provider path — the test-seam transcriber has no timings.
struct LastDictationStats: Equatable {
    let chars: Int
    let sttSeconds: Double
    let cleanupSeconds: Double
    var engineID: String? = nil
    var microphoneStartupSeconds: Double? = nil
    var captureBackend: String? = nil

    /// "1.4s · 38 chars" — total time (stt + cleanup) to one decimal, for the
    /// diagnostics report (always English, like the rest of the report).
    var summary: String {
        String(format: "%.1fs · %d chars", sttSeconds + cleanupSeconds, chars)
    }

    /// The menu's secondary line, in the user's language: "Last: 1.4s · 38 chars".
    var menuLine: String {
        let seconds = (sttSeconds + cleanupSeconds).formatted(.number.precision(.fractionLength(1)))
        guard let engineID else { return String(localized: "Last: \(seconds)s · \(chars) chars") }
        let execution = DictationExecution(engineID: engineID).label
        return String(localized: "Last: \(execution) · \(seconds)s · \(chars) chars")
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: DictationStatus = .idle
    /// Frozen at press, so settings edits cannot relabel an active utterance.
    @Published var activeEngineID: String?

    /// Master on/off for the push-to-talk listener (menu toggle). Off means
    /// the hotkey is ignored entirely; it does NOT quit the app.
    @Published var dictationEnabled: Bool = true

    /// Stats of the most recent successful dictate, or nil before the first
    /// one. Menu-only, never persisted.
    @Published var lastDictation: LastDictationStats?

    /// A page the Settings window should switch to (e.g. the menu's "Review
    /// Dictionary Suggestions…"); SettingsView consumes and clears it.
    @Published var requestedSettingsPage: SettingsPage?

    /// Recent transcripts for the menu's "Recent…" submenu (0.1.5). In-memory
    /// only (see TranscriptLog); recording is gated by the history toggle at
    /// the DictationController record point, and turning the toggle off clears
    /// what's retained via `clearTranscripts()`.
    @Published private(set) var transcripts = TranscriptLog()

    func recordTranscript(_ text: String, details: TranscriptLog.Details? = nil) {
        transcripts.add(text, details: details)
    }

    func clearTranscripts() {
        // Publish-free when already empty: the coordinator calls this on EVERY
        // settings change while history is off, and a fresh TranscriptLog would
        // otherwise fire objectWillChange per keystroke in Settings.
        guard !transcripts.entries.isEmpty else { return }
        transcripts = TranscriptLog()
    }
}
