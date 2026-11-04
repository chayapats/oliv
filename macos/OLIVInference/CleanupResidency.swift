import Foundation

/// Invalidate stale idle timers and defer pressure eviction until every caller
/// has released its model. Loading and tokenization are callers too.
struct CleanupResidency {
    private(set) var users = 0
    private(set) var epoch: UInt64 = 0
    private(set) var evictionRequested = false

    mutating func begin() {
        users += 1
        epoch &+= 1
    }

    mutating func end() {
        precondition(users > 0)
        users -= 1
        epoch &+= 1
    }

    mutating func requestEviction() {
        evictionRequested = true
        epoch &+= 1
    }

    func canEvict(epoch expected: UInt64) -> Bool {
        users == 0 && epoch == expected
    }

    mutating func didEvict() {
        evictionRequested = false
        epoch &+= 1
    }
}
