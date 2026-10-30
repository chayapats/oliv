import ActivityKit
import Foundation

/// Only recording status crosses into the widget process. Transcripts and credentials stay in OLIV.
struct OlivActivityAttributes: ActivityAttributes, Sendable {
    enum Phase: String, Codable, Hashable, Sendable {
        case recording
        case processing
        case ready
        case cancelled
    }

    struct ContentState: Codable, Hashable, Sendable {
        var phase: Phase
    }

    let sessionID: UUID
    let startedAt: Date
}
