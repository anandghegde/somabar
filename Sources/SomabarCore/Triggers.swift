import Foundation

public enum PowerSource: String, Codable, Sendable {
    case battery
    case adapter
}

public enum MediaDevice: String, Codable, Sendable {
    case microphone
    case camera
    case either
}

/// Network conditions need no Location permission: the router is known by its hardware address.
public enum NetworkCondition: String, Codable, Sendable {
    case ethernet
    case wifi
    case vpn
    /// The current router's hardware address is in the user's known list.
    case knownRouter
    /// Connected, and the router is not known.
    case unknownNetwork
    case offline
}

public enum DisplayCondition: Codable, Equatable, Sendable {
    case builtInOnly
    case externalConnected
    case widerThan(points: Int)
}

/// Minutes since midnight. Wraps past midnight when `toMinute` is before `fromMinute`.
public struct TimeRange: Codable, Equatable, Sendable {
    public var fromMinute: Int
    public var toMinute: Int

    public init(fromMinute: Int, toMinute: Int) {
        self.fromMinute = fromMinute
        self.toMinute = toMinute
    }

    public func contains(minute: Int) -> Bool {
        if fromMinute <= toMinute {
            return minute >= fromMinute && minute < toMinute
        }
        return minute >= fromMinute || minute < toMinute
    }
}

/// The condition list is kept short on purpose.
public indirect enum Condition: Codable, Equatable, Sendable {
    case powerSource(PowerSource)
    case batteryBelow(percent: Int)
    case network(NetworkCondition)
    case display(DisplayCondition)
    case screenSharing
    case mediaInUse(MediaDevice)
    case appRunning(bundleID: String)
    case appFrontmost(bundleID: String)
    /// Reported by the Focus Filter the user adds in System Settings.
    case focus(name: String)
    case timeOfDay(TimeRange)
    /// 1.1: the only condition that needs Screen Recording.
    case iconChanged(ItemKey)
    /// Set from outside: `somabar set <name> on|off`.
    case external(name: String)
    case not(Condition)
    case allOf([Condition])
    case anyOf([Condition])

    /// True when the condition, or anything inside it, needs Screen Recording.
    public var requiresScreenRecording: Bool {
        switch self {
        case .iconChanged: true
        case .not(let inner): inner.requiresScreenRecording
        case .allOf(let inner), .anyOf(let inner): inner.contains { $0.requiresScreenRecording }
        default: false
        }
    }
}

public enum TriggerAction: Codable, Equatable, Sendable {
    /// Moves the item to Shown while the condition holds.
    case show(ItemKey)
    /// Moves the item to Hidden while the condition holds.
    case hide(ItemKey)
    case switchProfile(name: String)
    /// Moves every member of the group to Shown while the condition holds.
    case showGroup(UUID)
    /// Moves every member of the group to Hidden while the condition holds.
    case hideGroup(UUID)
}

/// *When [condition], [show item / hide item / switch profile], until [condition ends].*
public struct Trigger: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var condition: Condition
    public var action: TriggerAction

    public init(id: UUID = UUID(), name: String = "", isEnabled: Bool = true, condition: Condition, action: TriggerAction) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.condition = condition
        self.action = action
    }
}
