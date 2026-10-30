import Foundation

/// Decides when one explicitly started recording is complete. Feed scored audio
/// windows from a speech classifier, not a microphone loudness threshold. This
/// value owns no audio, timer, task, or wall-clock dependency.
public struct SpeechEndpointPolicy: Sendable {
    public struct Configuration: Equatable, Sendable {
        public let initialSilenceTimeout: TimeInterval
        public let trailingSilence: TimeInterval
        public let analysisGracePeriod: TimeInterval
        public let minimumSpeechDuration: TimeInterval
        public let minimumSpeechObservations: Int
        public let maximumDuration: TimeInterval
        public let maximumSpeechGap: TimeInterval

        public static let handsFree = Configuration(defaults: ())

        private init(defaults: Void) {
            initialSilenceTimeout = 8
            trailingSilence = 1.5
            analysisGracePeriod = 1.5
            minimumSpeechDuration = 0.3
            minimumSpeechObservations = 2
            maximumDuration = RecordingLimits.maximumDuration
            maximumSpeechGap = 0.15
        }

        public init(initialSilenceTimeout: TimeInterval = 8,
                    trailingSilence: TimeInterval = 1.5,
                    analysisGracePeriod: TimeInterval = 1.5,
                    minimumSpeechDuration: TimeInterval = 0.3,
                    minimumSpeechObservations: Int = 2,
                    maximumDuration: TimeInterval = RecordingLimits.maximumDuration,
                    maximumSpeechGap: TimeInterval = 0.15) throws {
            let durations = [initialSilenceTimeout, trailingSilence, analysisGracePeriod,
                             minimumSpeechDuration, maximumDuration]
            guard durations.allSatisfy({ $0.isFinite && $0 > 0 }),
                  maximumDuration <= RecordingLimits.maximumDuration,
                  initialSilenceTimeout <= maximumDuration,
                  trailingSilence <= maximumDuration,
                  minimumSpeechDuration <= maximumDuration,
                  (1...64).contains(minimumSpeechObservations),
                  maximumSpeechGap.isFinite, maximumSpeechGap >= 0,
                  maximumSpeechGap <= analysisGracePeriod else {
                throw OlivError.invalidConfiguration(String(localized: "The automatic finish timing is invalid.", bundle: .main))
            }
            self.initialSilenceTimeout = initialSilenceTimeout
            self.trailingSilence = trailingSilence
            self.analysisGracePeriod = analysisGracePeriod
            self.minimumSpeechDuration = minimumSpeechDuration
            self.minimumSpeechObservations = minimumSpeechObservations
            self.maximumDuration = maximumDuration
            self.maximumSpeechGap = maximumSpeechGap
        }
    }

    public enum FinishReason: Equatable, Sendable {
        case trailingSilence, maximumDuration
    }

    public enum CancelReason: Equatable, Sendable {
        case initialSilence, detectorUnavailable, maximumDurationWithoutSpeech
    }

    public enum Decision: Equatable, Sendable {
        case finish(FinishReason)
        case cancel(CancelReason)
    }

    public let configuration: Configuration
    public private(set) var hasDetectedSpeech = false

    private struct Window: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let isSpeech: Bool
    }

    private static let maximumPendingWindows = 64
    // Classifier windows are expected to be 0.5 or 1 second. A very long window
    // is not reliable evidence of sustained voice and must not arm a recording.
    private static let maximumWindowDuration: TimeInterval = 2
    private static let tolerance: TimeInterval = 0.000_001
    private var pending: [Window] = []
    private var evaluatedThrough: TimeInterval = 0
    private var analyzedThrough: TimeInterval?
    private var hasUnanalyzedAudio = false
    private var candidateSpeechEnd: TimeInterval?
    private var candidateSpeechDuration: TimeInterval = 0
    private var candidateSpeechObservations = 0
    private var lastSpeechEnd: TimeInterval?
    private var silenceThrough: TimeInterval?
    private var coveredSilence: TimeInterval = 0
    private var decided = false

    public init(configuration: Configuration = .handsFree) {
        self.configuration = configuration
    }

    /// Queue a classifier result, using seconds from the start of this audio
    /// recording. Call evaluate with the current audio duration after feeding
    /// results. Future, overlapping duplicate, and out-of-order results cannot
    /// create speech evidence. No elapsed callback interval is treated as audio.
    public mutating func observe(windowStart: TimeInterval, windowEnd: TimeInterval, isSpeech: Bool) {
        guard !decided, windowStart.isFinite, windowEnd.isFinite,
              windowStart >= 0, windowEnd > windowStart,
              windowEnd - windowStart <= Self.maximumWindowDuration + Self.tolerance else { return }
        if pending.count == Self.maximumPendingWindows { pending.removeFirst() }
        pending.append(Window(start: windowStart, end: windowEnd, isSpeech: isSpeech))
    }

    /// Uses the recorder's actual audio duration, never wall time. A terminal
    /// decision is returned exactly once; later calls and observations are inert.
    /// A detector failure is distinct from silence: the caller can preserve that
    /// recording for manual recovery without automatically uploading it.
    public mutating func evaluate(elapsed: TimeInterval) -> Decision? {
        guard !decided, elapsed.isFinite, elapsed >= evaluatedThrough else { return nil }
        evaluatedThrough = elapsed
        for window in pending {
            guard window.end <= elapsed + Self.tolerance,
                  window.end <= configuration.maximumDuration + Self.tolerance,
                  analyzedThrough.map({ window.end > $0 + Self.tolerance }) ?? true else { continue }
            process(window)
        }
        pending.removeAll(keepingCapacity: true)

        // The hard cap always stops microphone ownership, including a stalled
        // classifier. The audio writer must independently cap its sample count.
        if elapsed >= configuration.maximumDuration {
            return complete(hasDetectedSpeech ? .finish(.maximumDuration) : .cancel(.maximumDurationWithoutSpeech))
        }

        if hasDetectedSpeech, let lastSpeechEnd {
            let deadline = lastSpeechEnd + configuration.trailingSilence
            if elapsed + Self.tolerance >= deadline,
               coveredSilence + Self.tolerance >= configuration.trailingSilence {
                return complete(.finish(.trailingSilence))
            }
            if elapsed - (analyzedThrough ?? 0) > configuration.analysisGracePeriod + Self.tolerance {
                return complete(.cancel(.detectorUnavailable))
            }
        } else if elapsed >= configuration.initialSilenceTimeout {
            if let analyzedThrough, analyzedThrough + Self.tolerance >= configuration.initialSilenceTimeout {
                return complete(.cancel(hasUnanalyzedAudio ? .detectorUnavailable : .initialSilence))
            }
            if elapsed >= configuration.initialSilenceTimeout + configuration.analysisGracePeriod {
                return complete(.cancel(.detectorUnavailable))
            }
        }
        return nil
    }

    private mutating func process(_ window: Window) {
        if window.start > (analyzedThrough ?? 0) + Self.tolerance { hasUnanalyzedAudio = true }
        analyzedThrough = window.end
        if window.isSpeech {
            coveredSilence = 0
            silenceThrough = nil
            if !hasDetectedSpeech {
                if let end = candidateSpeechEnd,
                   window.start > end + configuration.maximumSpeechGap + Self.tolerance {
                    resetCandidate()
                }
                // Classifier windows overlap. Count their union, never the same
                // audio twice, and require separate positive observations.
                candidateSpeechDuration += window.end - max(window.start, candidateSpeechEnd ?? window.start)
                candidateSpeechObservations += 1
                candidateSpeechEnd = window.end
                if candidateSpeechObservations >= configuration.minimumSpeechObservations,
                   candidateSpeechDuration + Self.tolerance >= configuration.minimumSpeechDuration {
                    hasDetectedSpeech = true
                }
            }
            lastSpeechEnd = window.end
        } else if hasDetectedSpeech, let lastSpeechEnd {
            let start = max(window.start, lastSpeechEnd)
            if let end = silenceThrough, start <= end + Self.tolerance {
                coveredSilence += max(0, window.end - max(start, end))
            } else {
                // Missing analysis is unknown audio, not silent audio.
                coveredSilence = max(0, window.end - start)
            }
            silenceThrough = window.end
        } else if let end = candidateSpeechEnd,
                  window.end - end > configuration.maximumSpeechGap + Self.tolerance {
            resetCandidate()
        }
    }

    private mutating func resetCandidate() {
        candidateSpeechEnd = nil
        candidateSpeechDuration = 0
        candidateSpeechObservations = 0
    }

    private mutating func complete(_ decision: Decision) -> Decision {
        decided = true
        pending.removeAll(keepingCapacity: false)
        return decision
    }
}
