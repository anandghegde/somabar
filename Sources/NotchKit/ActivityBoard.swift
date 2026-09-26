import SomabarCore

/// Where a live activity ranks when several want Compact, highest first.
///
/// The PRD's order is Call > Timer in its last 60 s > Agent needs you > Transfer > Now Playing >
/// Timer > Agent working. Two ranks it does not list sit at the ends: the drop target, which only
/// exists while the person is dragging a file and so always wins, and the screen-share guard's
/// red dot, which is a reminder and gives way to everything else.
public enum ActivityRank: Int, Comparable, CaseIterable, Sendable {
    case dropTarget
    case call
    case timerEnding
    case agentNeedsYou
    case transfer
    case nowPlaying
    case timer
    case agentWorking
    case screenShareGuard

    public static func < (lhs: ActivityRank, rhs: ActivityRank) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Seconds left at which a running timer outranks everything but a call.
    public static let timerEndingSeconds = 60.0

    /// A running timer in its last minute is urgent; a paused one is not.
    public static func timer(remaining: Double, isRunning: Bool) -> ActivityRank {
        isRunning && remaining <= timerEndingSeconds ? .timerEnding : .timer
    }
}

/// One live activity, as far as ordering goes.
public struct LiveActivity: Equatable, Sendable {
    public var kind: ActivityKind
    public var rank: ActivityRank
    /// Seconds on any clock; of two equal ranks, the older one wins.
    public var startedAt: Double

    public init(kind: ActivityKind, rank: ActivityRank, startedAt: Double = 0) {
        self.kind = kind
        self.rank = rank
        self.startedAt = startedAt
    }
}

/// What the notch shows of the live activities: one in Compact, all of them in Expanded.
public struct ActivitySelection: Equatable, Sendable {
    /// The activity drawn beside the camera; nil leaves the notch idle.
    public var compact: LiveActivity?
    /// Every activity the profile allows, highest rank first, the compact one included.
    public var expanded: [LiveActivity]

    /// The activities that did not win Compact.
    public var rest: [LiveActivity] {
        expanded.filter { $0 != compact }
    }
}

/// Picks what the notch shows. Pure: the activity center hands it what is live, the profile's
/// switches and whether the screen is shared.
public struct ActivityBoard: Equatable, Sendable {
    /// The kinds the active profile has switched on (`NotchSettings.enabledActivities`).
    public var enabled: Set<ActivityKind>
    public var isScreenShared: Bool

    /// What Compact may show while the screen is shared. The PRD allows Call and Timer; the
    /// screen-share guard is about the share itself, and the drop target shows no names.
    public static let shareSafeKinds: Set<ActivityKind> = [.call, .timer, .screenShareGuard, .dropToShare]

    public init(enabled: Set<ActivityKind>, isScreenShared: Bool) {
        self.enabled = enabled
        self.isScreenShared = isScreenShared
    }

    public init(settings: NotchSettings, isScreenShared: Bool) {
        self.init(enabled: settings.enabledActivities, isScreenShared: isScreenShared)
    }

    /// The allowed activities, highest rank first; the older wins a tie, then the kind's name
    /// so the order never flickers.
    public func ordered(_ live: [LiveActivity]) -> [LiveActivity] {
        live.filter { enabled.contains($0.kind) }.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    public func select(_ live: [LiveActivity]) -> ActivitySelection {
        let expanded = ordered(live)
        let compact = expanded.first { !isScreenShared || Self.shareSafeKinds.contains($0.kind) }
        return ActivitySelection(compact: compact, expanded: expanded)
    }
}
