/// The four notch states from the PRD.
public enum NotchState: Equatable, Sendable {
    /// Nothing is drawn; pixel-identical to the hardware.
    case idle
    /// The activity sits on both sides of the camera.
    case compact
    /// A one-off event, shown briefly, then back to the previous state.
    case pulse
    /// The panel with full controls and the hidden items tray.
    case expanded
}

public enum NotchEvent: Equatable, Sendable {
    case activityStarted
    case activityEnded
    case oneOffEvent
    case pulseElapsed
    case hoverIntent
    case click
    case pointerLeft
    case pointerReturned
    case leaveElapsed
}

/// The two timers the machine asks the surface to run.
public enum NotchMachineTimer: Equatable, Sendable {
    case pulse
    case leave
}

public enum NotchEffect: Equatable, Sendable {
    case start(NotchMachineTimer, seconds: Double)
    case cancel(NotchMachineTimer)
}

/// The state machine behind the notch surface. Pure: the surface feeds it events and runs the
/// timers it asks for.
///
///     Idle → Compact: activity starts          Compact → Idle: last activity ends
///     Idle/Compact → Pulse: one-off event      Pulse → previous: after 2 s
///     Idle/Compact/Pulse → Expanded: hover-intent or click
///     Expanded → Compact or Idle: pointer leaves for 300 ms
public struct NotchMachine: Equatable, Sendable {
    public static let pulseHoldSeconds = 2.0
    public static let leaveDelaySeconds = 0.3

    public private(set) var state: NotchState = .idle
    public private(set) var liveActivities = 0

    public init() {}

    /// The state the notch rests in when nothing is being pointed at.
    private var restingState: NotchState {
        liveActivities > 0 ? .compact : .idle
    }

    public mutating func handle(_ event: NotchEvent) -> [NotchEffect] {
        switch event {
        case .activityStarted:
            liveActivities += 1
            if state == .idle { state = .compact }
            return []

        case .activityEnded:
            liveActivities = max(0, liveActivities - 1)
            if state == .compact && liveActivities == 0 { state = .idle }
            return []

        case .oneOffEvent:
            switch state {
            case .idle, .compact:
                state = .pulse
                return [.start(.pulse, seconds: Self.pulseHoldSeconds)]
            case .pulse:
                return [.cancel(.pulse), .start(.pulse, seconds: Self.pulseHoldSeconds)]
            case .expanded:
                return []
            }

        case .pulseElapsed:
            guard state == .pulse else { return [] }
            state = restingState
            return []

        case .hoverIntent, .click:
            guard state != .expanded else { return [.cancel(.leave)] }
            let wasPulsing = state == .pulse
            state = .expanded
            return wasPulsing ? [.cancel(.pulse)] : []

        case .pointerLeft:
            guard state == .expanded else { return [] }
            return [.start(.leave, seconds: Self.leaveDelaySeconds)]

        case .pointerReturned:
            guard state == .expanded else { return [] }
            return [.cancel(.leave)]

        case .leaveElapsed:
            guard state == .expanded else { return [] }
            state = restingState
            return []
        }
    }
}
