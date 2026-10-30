import CoreGraphics

/// Converts finger travel into bounded cursor steps. Fractional travel remains
/// available for the next callback; an axis turn discards its orthogonal drift.
struct KeyboardTrackpadGesture {
    enum Motion: Equatable { case horizontal(Int), vertical(Int) }
    private enum Axis { case horizontal, vertical }

    private var anchor: CGPoint?
    private var lastPoint: CGPoint?
    private var axis: Axis?
    private var direction = 0
    private var extreme: CGFloat?

    mutating func begin(at point: CGPoint) {
        reset()
        guard point.x.isFinite, point.y.isFinite else { return }
        anchor = point
        lastPoint = point
    }

    mutating func reset() {
        anchor = nil
        lastPoint = nil
        axis = nil
        direction = 0
        extreme = nil
    }

    mutating func change(to point: CGPoint) -> Motion? {
        guard var anchor, let lastPoint else { return nil }
        guard point.x.isFinite, point.y.isFinite else { reset(); return nil }
        defer { self.lastPoint = point }
        var dx = point.x - anchor.x
        var dy = point.y - anchor.y
        let selected: Axis?
        switch axis {
        case nil:
            if abs(dy) >= 12, abs(dy) >= abs(dx) * 0.75 { selected = .vertical }
            else if abs(dx) >= 8, abs(dx) > abs(dy) * 1.25 { selected = .horizontal }
            else { selected = nil }
        case .vertical:
            selected = abs(dx) >= 16 && abs(dx) > abs(dy) * 1.5 ? .horizontal : .vertical
        case .horizontal:
            selected = abs(dy) >= 12 && abs(dy) >= abs(dx) * 0.75 ? .vertical : .horizontal
        }
        guard let selected else { return nil }
        if selected != axis {
            axis = selected
            direction = 0
            extreme = nil
            if selected == .vertical { anchor.x = point.x }
            else { anchor.y = point.y }
        }

        let position = selected == .vertical ? point.y : point.x
        let previous = selected == .vertical ? lastPoint.y : lastPoint.x
        let origin = selected == .vertical ? anchor.y : anchor.x
        if direction == 0 {
            direction = position < origin ? -1 : 1
            extreme = position
        } else if position != previous, let extreme {
            // Track the furthest point rather than the last emitted step. A
            // one-point reversal clears old fractional travel exactly once;
            // several sub-point callbacks can still establish that reversal.
            let reversal = direction > 0 ? extreme - position : position - extreme
            if reversal >= 1 {
                if selected == .vertical { anchor.y = extreme }
                else { anchor.x = extreme }
                direction = -direction
                self.extreme = position
            } else {
                self.extreme = direction > 0 ? max(extreme, position) : min(extreme, position)
            }
        }
        dx = point.x - anchor.x
        dy = point.y - anchor.y
        let distance = selected == .vertical ? dy : dx
        let threshold: CGFloat = selected == .vertical ? 12 : 8
        guard abs(distance) >= threshold else { self.anchor = anchor; return nil }
        let cap = selected == .vertical ? 4 : 24
        // Clamp before integer conversion so an unexpectedly large coordinate
        // cannot overflow. Consume only emitted steps, retaining capped travel.
        let magnitude = min(CGFloat(cap), (abs(distance) / threshold).rounded(.towardZero))
        let steps = Int(magnitude) * (distance < 0 ? -1 : 1)
        if selected == .vertical {
            anchor.y += CGFloat(steps) * threshold
            anchor.x = point.x
        } else {
            anchor.x += CGFloat(steps) * threshold
            anchor.y = point.y
        }
        self.anchor = anchor
        return selected == .vertical ? .vertical(steps) : .horizontal(steps)
    }
}
