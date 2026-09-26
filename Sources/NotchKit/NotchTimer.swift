/// The notch timer: a countdown that is an activity on the notch surface.
///
/// Pure on a passed-in clock (seconds, any monotonic origin) so it can be tested without
/// sleeping. The mutating calls return the machine events they cause: starting from nothing is
/// `.activityStarted`, finishing or cancelling is `.activityEnded`. Restarting a running timer
/// and pausing it are neither; a paused timer is still an activity and stays in the notch.
public struct NotchTimer: Equatable, Sendable {
    /// The length the timer was started with.
    public private(set) var duration: Double = 0
    /// When a running timer reaches zero.
    private var endsAt: Double?
    /// What was left when it was paused.
    private var pausedRemaining: Double?

    public init() {}

    /// Counting down.
    public var isRunning: Bool {
        endsAt != nil
    }

    public var isPaused: Bool {
        pausedRemaining != nil
    }

    /// Running or paused: the timer is shown in the notch.
    public var isActive: Bool {
        isRunning || isPaused
    }

    /// Starts, or restarts, a countdown of `seconds`.
    @discardableResult
    public mutating func start(seconds: Double, at now: Double) -> [NotchEvent] {
        let wasActive = isActive
        duration = max(0, seconds)
        endsAt = now + duration
        pausedRemaining = nil
        return wasActive ? [] : [.activityStarted]
    }

    /// Seconds left; 0 when nothing is counting.
    public func remaining(at now: Double) -> Double {
        if let pausedRemaining { return pausedRemaining }
        guard let endsAt else { return 0 }
        return max(0, endsAt - now)
    }

    /// Stops the timer without the "Time's up" pulse.
    @discardableResult
    public mutating func cancel() -> [NotchEvent] {
        let wasActive = isActive
        endsAt = nil
        pausedRemaining = nil
        return wasActive ? [.activityEnded] : []
    }

    public mutating func pause(at now: Double) {
        guard isRunning else { return }
        pausedRemaining = remaining(at: now)
        endsAt = nil
    }

    public mutating func resume(at now: Double) {
        guard let pausedRemaining else { return }
        endsAt = now + pausedRemaining
        self.pausedRemaining = nil
    }

    /// Call on every tick. Returns `.activityEnded` once, when a running timer reaches zero;
    /// the caller pulses "Time's up".
    @discardableResult
    public mutating func tick(at now: Double) -> [NotchEvent] {
        guard isRunning, remaining(at: now) <= 0 else { return [] }
        endsAt = nil
        return [.activityEnded]
    }

    /// The remaining time as m:ss, rounded up so the display reads 0:00 only at the end.
    public func display(at now: Double) -> String {
        Self.format(seconds: remaining(at: now))
    }

    public static func format(seconds: Double) -> String {
        let whole = Int(max(0, seconds).rounded(.up))
        let secondsPart = whole % 60
        return "\(whole / 60):" + (secondsPart < 10 ? "0" : "") + "\(secondsPart)"
    }
}
