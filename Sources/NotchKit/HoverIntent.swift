import CoreGraphics

public struct PointerSample: Equatable, Sendable {
    public var point: CGPoint
    public var time: Double

    public init(point: CGPoint, time: Double) {
        self.point = point
        self.time = time
    }
}

/// Hover-intent, not hover. Expanded opens only if the pointer slows down inside the notch area
/// (under 120 pt/s for 150 ms). A pointer passing through to the menu bar never opens it.
public struct HoverIntentDetector: Equatable, Sendable {
    public var speedThreshold: CGFloat = 120
    public var dwellSeconds: Double = 0.150

    private var last: PointerSample?
    private var slowSince: Double?
    private var fired = false

    public init() {}

    /// Feed every pointer move. Returns true once, when intent is detected; call `reset()` or move
    /// the pointer out of the area to arm it again.
    public mutating func feed(_ sample: PointerSample, inside: Bool) -> Bool {
        guard inside else {
            reset()
            return false
        }
        defer { last = sample }

        let speed: CGFloat
        if let last, sample.time > last.time {
            let dx = sample.point.x - last.point.x
            let dy = sample.point.y - last.point.y
            speed = (dx * dx + dy * dy).squareRoot() / CGFloat(sample.time - last.time)
        } else {
            speed = 0
        }

        if speed < speedThreshold {
            if slowSince == nil { slowSince = sample.time }
            if let since = slowSince, sample.time - since >= dwellSeconds, !fired {
                fired = true
                return true
            }
        } else {
            slowSince = nil
        }
        return false
    }

    public mutating func reset() {
        last = nil
        slowSince = nil
        fired = false
    }
}
