import Foundation

/// Touch-down Shift behavior, separate from host autocapitalization. The view
/// owns the single Shift touch and applies returned states without toggling a
/// second time on release. No timer or work runs while the keyboard is idle.
struct KeyboardShiftPolicy {
    private struct Hold {
        let previous: KeyboardShiftState
        let displayed: KeyboardShiftState
        let beganAt: TimeInterval
        let lockedByDoubleTap: Bool
        var committedCharacter = false
    }

    /// Existing double-tap tolerance, independently configurable for testing.
    /// Native touch-down behavior is measured; this threshold is not an OS API.
    let doubleTapWindow: TimeInterval
    private var hold: Hold?
    private var lastTapAt: TimeInterval?
    private var lastTapState: KeyboardShiftState?

    var isHeld: Bool { hold != nil }
    var heldState: KeyboardShiftState? { hold?.displayed }

    init(doubleTapWindow: TimeInterval = 0.32) {
        precondition(doubleTapWindow.isFinite && doubleTapWindow > 0)
        self.doubleTapWindow = doubleTapWindow
    }

    mutating func begin(current: KeyboardShiftState, at time: TimeInterval) -> KeyboardShiftState {
        if let hold { return hold.displayed }
        guard time.isFinite else { clearTap(); return current }
        let doubleTap = lastTapAt.map { time >= $0 && time - $0 <= doubleTapWindow } == true
            && lastTapState == current
        let displayed: KeyboardShiftState = doubleTap ? .locked : (current == .off ? .on : .off)
        clearTap()
        hold = Hold(previous: current, displayed: displayed, beganAt: time,
                    lockedByDoubleTap: doubleTap)
        return displayed
    }

    /// Call before delivering a character. Held Shift remains stable for a
    /// second finger or a Shift-to-letter slide; plain one-shot Shift is used up.
    mutating func characterCommitted(current: KeyboardShiftState) -> KeyboardShiftState {
        clearTap()
        if var active = hold {
            active.committedCharacter = true
            hold = active
            return active.displayed
        }
        return current == .on ? .off : current
    }

    /// Release after a letter commit restores persistent Caps Lock, or normal
    /// lowercase after a one-shot/chord. A plain tap keeps its touch-down state.
    mutating func end(at time: TimeInterval) -> KeyboardShiftState? {
        guard let active = hold else { return nil }
        hold = nil
        guard time.isFinite, time >= active.beganAt else { clearTap(); return active.previous }
        if active.committedCharacter {
            clearTap()
            return active.previous == .locked ? .locked : .off
        }
        if !active.lockedByDoubleTap, time - active.beganAt <= doubleTapWindow {
            lastTapAt = time
            lastTapState = active.displayed
        } else { clearTap() }
        return active.displayed
    }

    /// Lifecycle cancellation or a release outside any actionable key restores
    /// the pre-press state and cannot seed a later accidental double tap.
    mutating func cancel() -> KeyboardShiftState? {
        let previous = hold?.previous
        hold = nil
        clearTap()
        return previous
    }

    /// A different committed control (Space, language/page switch, etc.) breaks
    /// a double-tap sequence. It does not release another finger's held Shift.
    mutating func otherActionCommitted() { clearTap() }

    private mutating func clearTap() {
        lastTapAt = nil
        lastTapState = nil
    }
}
