import Foundation
import NaturalLanguage

/// A clock-driven hold policy. It owns no timer, task, proxy, or document text.
/// The view supplies monotonic time only while a particular touch owns Delete.
struct KeyboardRepeatPolicy {
    enum DeletionUnit: Equatable, Sendable { case character, word }

    struct Phase: Equatable, Sendable {
        let minimumHold: TimeInterval
        let minimumRepeats: Int
        let interval: TimeInterval
        let unit: DeletionUnit

        init(minimumHold: TimeInterval = 0, minimumRepeats: Int = 0,
             interval: TimeInterval, unit: DeletionUnit = .character) {
            precondition(minimumHold.isFinite && minimumHold >= 0)
            precondition(minimumRepeats >= 0 && interval.isFinite && interval > 0)
            self.minimumHold = minimumHold
            self.minimumRepeats = minimumRepeats
            self.interval = interval
            self.unit = unit
        }
    }

    struct Configuration: Equatable, Sendable {
        let initialDelay: TimeInterval
        /// Later eligible phases take precedence. The first phase must cover
        /// the first repeat; measured profiles can advance by time or count.
        let phases: [Phase]

        init(initialDelay: TimeInterval, phases: [Phase]) {
            precondition(initialDelay.isFinite && initialDelay > 0)
            precondition(phases.first?.minimumHold == 0 && phases.first?.minimumRepeats == 0)
            self.initialDelay = initialDelay
            self.phases = phases
        }

        /// Measured with Apple's English and Thai keyboards on iOS 27:
        /// immediate deletion, repeats at 0.5…2.4 s, then two-word pulses.
        /// A word pulse's context-sensitive execution belongs to the controller.
        static let measuredIOS27 = Configuration(initialDelay: 0.5, phases: [
            .init(interval: 0.1),
            .init(minimumHold: 2.5, minimumRepeats: 20, interval: 0.35, unit: .word)
        ])

        /// Deliberately quicker than the measured native profile, following
        /// device feedback. Word pulses retain native cadence and all guards.
        static let responsive = Configuration(initialDelay: 0.22, phases: [
            .init(interval: 0.06),
            .init(minimumHold: 0.90, minimumRepeats: 10, interval: 0.35, unit: .word)
        ])
    }

    let configuration: Configuration
    private var beganAt: TimeInterval?
    private var lastTime: TimeInterval?
    private var nextDeadline: TimeInterval?
    private var repeats = 0

    init(configuration: Configuration) { self.configuration = configuration }

    /// A fresh press emits exactly one host-defined backward deletion.
    /// Repeated begin calls for the same hold do not emit another deletion.
    mutating func begin(at time: TimeInterval) -> DeletionUnit? {
        guard beganAt == nil, time.isFinite else { return nil }
        beganAt = time
        lastTime = time
        nextDeadline = time + configuration.initialDelay
        repeats = 0
        return .character
    }

    mutating func next(at time: TimeInterval, supportsWordDeletion: @autoclosure () -> Bool = true) -> DeletionUnit? {
        guard let beganAt, let deadline = nextDeadline, let lastTime else { return nil }
        guard time.isFinite, time >= lastTime else { cancel(); return nil }
        self.lastTime = time
        guard time >= deadline else { return nil }
        let eligible = phase(heldFor: time - beganAt, completedRepeats: repeats)
        // Proxy context is cross-process work. Ask only when a word pulse is
        // actually due, never on character repeats or an early timer wakeup.
        let phase = eligible.unit == .word && !supportsWordDeletion()
            ? configuration.phases.first(where: { $0.unit == .character }) ?? eligible
            : eligible
        repeats += 1
        // Preserve cadence through small scheduling jitter instead of adding
        // that jitter to every repeat. Never shorten the next gap below half
        // an interval; missing a full interval starts a fresh cadence instead
        // of replaying overdue deletions after suspension or a busy host app.
        let lateness = time - deadline
        nextDeadline = lateness >= phase.interval
            ? time + phase.interval
            : max(deadline + phase.interval, time + phase.interval / 2)
        return phase.unit
    }

    func delayUntilNext(at time: TimeInterval) -> TimeInterval? {
        guard let nextDeadline, let lastTime, time.isFinite, time >= lastTime else { return nil }
        return max(0, nextDeadline - time)
    }

    mutating func cancel() {
        beganAt = nil
        lastTime = nil
        nextDeadline = nil
        repeats = 0
    }

    private func phase(heldFor duration: TimeInterval, completedRepeats: Int) -> Phase {
        configuration.phases.last {
            duration >= $0.minimumHold && completedRepeats >= $0.minimumRepeats
        } ?? configuration.phases[0]
    }
}

/// A semantic target for a word-repeat pulse, never a count of deleteBackward
/// calls. The host determines whether one call removes a selection, a combining
/// mark, or a whole grapheme. The caller must re-check context between calls.
enum KeyboardDeletionBoundary {
    /// Native accelerated Delete removes two lexical chunks, including each
    /// chunk's leading horizontal separator and trailing punctuation. It must
    /// never guess beyond the available context or split a Swift grapheme.
    static func wordSuffix(in context: String, language: String, wordCount: Int = 2) -> String? {
        guard !context.isEmpty else { return nil }
        let maximumCharacters = 96
        let limited = String(context.suffix(maximumCharacters))
        let wasTruncated = context.count > maximumCharacters
        guard let last = limited.last else { return nil }
        if last.isNewline { return String(last) }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(NLLanguage(rawValue: language))
        tokenizer.string = limited
        var deletionStart = limited.endIndex
        for _ in 0..<min(2, max(1, wordCount)) {
            var contentEnd = deletionStart
            while contentEnd > limited.startIndex {
                let previous = limited.index(before: contentEnd)
                guard limited[previous].isWhitespace, !limited[previous].isNewline else { break }
                contentEnd = previous
            }
            guard contentEnd > limited.startIndex else { break }
            var lastContent = limited.index(before: contentEnd)
            guard !limited[lastContent].isNewline else { break }

            // Preserve punctuation attached to a word ("river."). A run of
            // punctuation without a preceding word remains a single grapheme.
            while limited[lastContent].isPunctuation, lastContent > limited.startIndex {
                let previous = limited.index(before: lastContent)
                guard !limited[previous].isWhitespace else { break }
                lastContent = previous
            }
            let start: String.Index
            if limited[lastContent].isLetter || limited[lastContent].isNumber {
                let token = tokenizer.tokenRange(at: lastContent)
                guard !token.isEmpty, token.upperBound <= contentEnd,
                      !wasTruncated || token.lowerBound != limited.startIndex,
                      limited.indices.contains(token.lowerBound) else { break }
                start = token.lowerBound
            } else {
                start = limited.index(before: contentEnd)
            }
            deletionStart = start
            while deletionStart > limited.startIndex {
                let previous = limited.index(before: deletionStart)
                guard limited[previous].isWhitespace, !limited[previous].isNewline else { break }
                deletionStart = previous
            }
        }
        return deletionStart == limited.endIndex ? String(last) : String(limited[deletionStart...])
    }
}

/// One observed host state. It is never persisted or sent outside the extension.
struct KeyboardDeletionContext {
    let documentID: UUID
    let before: String?
    let after: String?
    let selected: String?

    func matches(_ other: Self) -> Bool {
        documentID == other.documentID && Self.sameScalars(before, other.before)
            && Self.sameScalars(after, other.after) && Self.sameScalars(selected, other.selected)
    }

    static func sameScalars(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some(let lhs), .some(let rhs)): return lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
        default: return false
        }
    }
}

/// Keeps a physical hold in its original document. WebKit can expose a stale
/// caret snapshot at touch-down: before=nil and after=text even though the host
/// has moved the caret to the end. Do not freeze that unready after-context.
/// Bind it once before-context becomes available, then keep it strict.
struct KeyboardDeletionHold {
    private(set) var validationContext: KeyboardDeletionContext
    private var hasBoundAfter: Bool
    private var selectionWasCleared: Bool
    private(set) var isActive = true

    init(context: KeyboardDeletionContext) {
        validationContext = context
        hasBoundAfter = context.before != nil
        selectionWasCleared = context.selected?.isEmpty != false
    }

    mutating func accepts(_ current: KeyboardDeletionContext?) -> Bool {
        guard isActive else { return false }
        guard let current, current.documentID == validationContext.documentID else {
            isActive = false
            return false
        }
        if current.selected?.isEmpty == false {
            guard !selectionWasCleared,
                  KeyboardDeletionContext.sameScalars(validationContext.selected, current.selected) else {
                isActive = false
                return false
            }
        } else {
            selectionWasCleared = true
        }
        if !hasBoundAfter {
            if current.before != nil {
                validationContext = current
                hasBoundAfter = true
            }
            return true
        }
        guard KeyboardDeletionContext.sameScalars(validationContext.after, current.after) else {
            isActive = false
            return false
        }
        return true
    }
}

/// A pulse permits only one unacknowledged host deletion. Stale context waits;
/// confirmed raw-scalar prefix progress permits the next call. A missing or
/// changed context stops the pulse rather than guessing host deletion counts.
struct KeyboardDeletionProgress {
    enum StopReason: Equatable { case completed, contextChanged, timedOut, limitReached }
    enum Step: Equatable { case delete, wait, stop(StopReason) }
#if DEBUG
    enum Rejection { case before, document, selection, after, missing }
    private(set) var diagnosticRejection: Rejection?
#endif

    private let documentID: UUID
    private let contextAfter: String?
    private let target: [Unicode.Scalar]
    private var previous: [Unicode.Scalar]
    private var remainingCalls: Int
    private let deadline: TimeInterval
    private var lastTime: TimeInterval
    private var awaitingAcknowledgement = false
    private(set) var hasAcknowledgedDeletion = false
    private var stopped: StopReason?

    init?(context: KeyboardDeletionContext, deleting suffix: String, at time: TimeInterval,
          maximumDuration: TimeInterval = 0.30, maximumDeletions: Int = 64) {
        guard context.selected?.isEmpty != false, let before = context.before,
              !suffix.isEmpty, maximumDeletions > 0, time.isFinite,
              maximumDuration.isFinite, maximumDuration > 0 else { return nil }
        let all = Array(before.unicodeScalars)
        let removed = Array(suffix.unicodeScalars)
        guard all.count >= removed.count, all.suffix(removed.count).elementsEqual(removed) else { return nil }
        documentID = context.documentID
        contextAfter = context.after
        target = Array(all.dropLast(removed.count))
        previous = all
        remainingCalls = maximumDeletions
        deadline = time + maximumDuration
        lastTime = time
    }

    mutating func next(context: KeyboardDeletionContext?, at time: TimeInterval) -> Step {
        if let stopped { return .stop(stopped) }
        guard time.isFinite, time >= lastTime, time < deadline else { return stop(.timedOut) }
        lastTime = time
        guard let context, context.documentID == documentID,
              context.selected?.isEmpty != false,
              KeyboardDeletionContext.sameScalars(context.after, contextAfter),
              let before = context.before else {
#if DEBUG
            if let context {
                if context.documentID != documentID { diagnosticRejection = .document }
                else if context.selected?.isEmpty == false { diagnosticRejection = .selection }
                else if !KeyboardDeletionContext.sameScalars(context.after, contextAfter) { diagnosticRejection = .after }
                else { diagnosticRejection = .missing }
            } else { diagnosticRejection = .missing }
#endif
            return stop(.contextChanged)
        }
        let current = Array(before.unicodeScalars)
        if awaitingAcknowledgement {
            if current == previous { return .wait }
            guard current.count < previous.count, previous.starts(with: current),
                  current.starts(with: target) else {
#if DEBUG
                diagnosticRejection = .before
#endif
                return stop(.contextChanged)
            }
            previous = current
            hasAcknowledgedDeletion = true
        } else if current != previous {
#if DEBUG
            diagnosticRejection = .before
#endif
            return stop(.contextChanged)
        }
        guard current.count > target.count else { return stop(.completed) }
        guard remainingCalls > 0 else { return stop(.limitReached) }
        remainingCalls -= 1
        awaitingAcknowledgement = true
        return .delete
    }

    private mutating func stop(_ reason: StopReason) -> Step {
        stopped = reason
        return .stop(reason)
    }
}

/// Runs only during an explicit held-Delete pulse. Responsive hosts retain a
/// synchronous fast path; an unchanged proxy gets a main-runloop opportunity to
/// acknowledge its one pending deletion. Cancellation invalidates every resume.
@MainActor
final class KeyboardWordDeletionSession {
    typealias ReadContext = @MainActor () -> KeyboardDeletionContext?
    private let readContext: ReadContext
    private let deleteBackward: @MainActor () -> Void
    private let now: @MainActor () -> TimeInterval
    private let waitForHost: @MainActor () async throws -> Void
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var blockedContext: KeyboardDeletionContext?

    var isRunning: Bool { task != nil }
    var onCompletion: (@MainActor (UUID) -> Void)?
#if DEBUG
    private enum Diagnostic: String, CaseIterable {
        case start, issue, wait, done, timeout, beforeMismatch, documentMismatch
        case selectionMismatch, afterMismatch, missingContext, limit, cancel
        case holdDocument, holdAfter, holdSelection, holdUnavailable
        case holdBeforeNilToValue, holdBeforeValueToNil
        case holdAfterNilToEmpty, holdAfterNilToValue, holdAfterEmptyToNil, holdAfterValueToNil
    }
    enum HoldRejection: String, Hashable {
        case holdDocument, holdAfter, holdSelection, holdUnavailable
        case holdBeforeNilToValue, holdBeforeValueToNil
        case holdAfterNilToEmpty, holdAfterNilToValue, holdAfterEmptyToNil, holdAfterValueToNil
    }
    func recordHoldRejection(_ rejection: HoldRejection) {
        guard let diagnostic = Diagnostic(rawValue: rejection.rawValue) else { return }
        count(diagnostic)
        publishDiagnostics()
    }
    private var diagnostics: [Diagnostic: Int] = [:]
    var onDiagnostic: (@MainActor (String) -> Void)?
    var diagnosticSummary: String {
        Diagnostic.allCases.map { "\($0.rawValue)=\(diagnostics[$0, default: 0])" }.joined(separator: ",")
    }
    private func count(_ diagnostic: Diagnostic) {
        diagnostics[diagnostic] = min(10_000, diagnostics[diagnostic, default: 0] + 1)
    }
    private func publishDiagnostics() { onDiagnostic?(diagnosticSummary) }
    private func recordStop(_ reason: KeyboardDeletionProgress.StopReason,
                            rejection: KeyboardDeletionProgress.Rejection?) {
        switch reason {
        case .completed: count(.done)
        case .timedOut: count(.timeout)
        case .limitReached: count(.limit)
        case .contextChanged:
            switch rejection {
            case .before: count(.beforeMismatch)
            case .document: count(.documentMismatch)
            case .selection: count(.selectionMismatch)
            case .after: count(.afterMismatch)
            case .missing, nil: count(.missingContext)
            }
        }
        publishDiagnostics()
    }
#endif

    init(readContext: @escaping ReadContext, deleteBackward: @escaping @MainActor () -> Void,
         now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         waitForHost: @escaping @MainActor () async throws -> Void = {
             try await Task.sleep(for: .milliseconds(4))
         }) {
        self.readContext = readContext
        self.deleteBackward = deleteBackward
        self.now = now
        self.waitForHost = waitForHost
    }

    var supportsWordDeletion: Bool {
        guard let context = readContext() else { return false }
        return supportsWordDeletion(context: context)
    }

    private func supportsWordDeletion(context: KeyboardDeletionContext) -> Bool {
        guard context.selected?.isEmpty != false, context.before?.isEmpty == false else { return false }
        if let blockedContext, blockedContext.matches(context) { return false }
        blockedContext = nil
        return true
    }

    @discardableResult
    func start(language: String) -> Bool {
        // A delayed pulse never overlaps an older pulse or queues catch-up work.
        if task != nil { return true }
        cancel()
        guard let context = readContext(), supportsWordDeletion(context: context), let before = context.before,
              let suffix = KeyboardDeletionBoundary.wordSuffix(in: before, language: language),
              let progress = KeyboardDeletionProgress(context: context, deleting: suffix, at: now()) else { return false }
        let generation = generation
#if DEBUG
        count(.start)
        publishDiagnostics()
#endif
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var progress = progress
            defer {
                if self.generation == generation {
                    self.task = nil
                    if !Task.isCancelled, progress.hasAcknowledgedDeletion,
                       self.readContext()?.documentID == context.documentID {
                        self.onCompletion?(context.documentID)
                    }
                }
            }
            // The deadline is primary. This check bound also handles a broken
            // injected clock/yield without an unbounded loop in tests or hosts.
            for _ in 0..<192 {
                guard !Task.isCancelled, self.generation == generation else { return }
                switch progress.next(context: self.readContext(), at: self.now()) {
                case .delete:
#if DEBUG
                    self.count(.issue)
#endif
                    self.deleteBackward()
                    // Give touch-up/cancellation a chance to run even when a
                    // synchronous host acknowledges every delete immediately.
                    await Task.yield()
                case .wait:
#if DEBUG
                    self.count(.wait)
#endif
                    do { try await self.waitForHost() }
                    catch { return }
                case .stop(let reason):
#if DEBUG
                    self.recordStop(reason, rejection: progress.diagnosticRejection)
#endif
                    if reason == .timedOut { self.blockedContext = self.readContext() }
                    return
                }
            }
            self.blockedContext = self.readContext()
#if DEBUG
            self.count(.limit)
            self.publishDiagnostics()
#endif
        }
        return true
    }

    func cancel(resetFallback: Bool = false) {
#if DEBUG
        if task != nil {
            count(.cancel)
            publishDiagnostics()
        }
#endif
        generation &+= 1
        task?.cancel()
        task = nil
        if resetFallback { blockedContext = nil }
    }
}
