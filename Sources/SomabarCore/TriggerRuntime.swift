/// Turns evaluated trigger effects into changes over time: what the bar applies now, what it
/// undoes when a condition ends, and which profile to go back to.
///
/// *When [condition], [show item / hide item / switch profile], until [condition ends].* The
/// runtime is pure: the app feeds it the effects of each evaluation and acts on the outcome.
///
/// - Show and hide effects never touch the stored layout. The app lays the applied effects over
///   the active profile (`Layout.applying`) and reconciles the bar to that.
/// - A profile switch remembers the profile it left in `SomabarDocument.profileBeforeTriggers`
///   and goes back to it when no trigger asks for a profile any more. A profile the person
///   switches to by hand while a trigger holds is theirs to keep: the app clears the memory.
/// - An item the person moves while a trigger holds it is suspended: the trigger leaves it alone
///   until its condition ends and starts again.
public struct TriggerRuntime: Equatable, Sendable {
    /// The show and hide effects the bar applies right now. Suspended items are left out and
    /// `profile` is always nil; profiles are handled through the document.
    public private(set) var applied = TriggerEffects()
    /// What the triggers last asked for, before suspensions.
    public private(set) var requested = TriggerEffects()
    /// Items the person moved while a trigger held them.
    public private(set) var suspended: Set<ItemKey> = []

    public init() {}

    public enum ProfileChange: Equatable, Sendable {
        /// A trigger switched to this profile.
        case switched(to: String)
        /// The last profile trigger ended; this is the profile from before it.
        case restored(to: String)
    }

    public struct Outcome: Equatable, Sendable {
        /// The applied show or hide effects changed, so the bar needs reconciling.
        public var layoutChanged = false
        public var profileChange: ProfileChange?
        /// A trigger asked for a profile the document does not have.
        public var unknownProfile: String?

        public init() {}

        public var isEmpty: Bool {
            !layoutChanged && profileChange == nil && unknownProfile == nil
        }
    }

    /// Applies one evaluation. Call it whenever the context or the triggers change, and again
    /// after each scan of the bar.
    public mutating func apply(_ effects: TriggerEffects, to document: inout SomabarDocument) -> Outcome {
        var outcome = Outcome()
        let previousProfile = requested.profile
        requested = effects

        // A suspension lasts until the trigger that held the item lets go.
        let affected = Set(effects.show).union(effects.hide)
        suspended = suspended.intersection(affected)
        let layoutEffects = TriggerEffects(
            show: effects.show.filter { !suspended.contains($0) },
            hide: effects.hide.filter { !suspended.contains($0) }
        )
        if layoutEffects != applied {
            applied = layoutEffects
            outcome.layoutChanged = true
        }

        if let target = effects.profile {
            // Only a change of request switches, so a profile the person picked meanwhile stays.
            guard target != previousProfile else { return outcome }
            guard document.profile(named: target) != nil else {
                outcome.unknownProfile = target
                return outcome
            }
            if document.activeProfile != target {
                if document.profileBeforeTriggers == nil {
                    document.profileBeforeTriggers = document.activeProfile
                }
                document.activeProfile = target
                outcome.profileChange = .switched(to: target)
            }
        } else if let original = document.profileBeforeTriggers {
            document.profileBeforeTriggers = nil
            if document.profile(named: original) != nil, document.activeProfile != original {
                document.activeProfile = original
                outcome.profileChange = .restored(to: original)
            }
        }
        return outcome
    }

    /// The person moved an item. When a trigger holds it, the trigger lets go until its
    /// condition ends. Returns true when the item was held.
    @discardableResult
    public mutating func suspend(_ key: ItemKey) -> Bool {
        guard requested.show.contains(key) || requested.hide.contains(key) else { return false }
        suspended.insert(key)
        applied.show.removeAll { $0 == key }
        applied.hide.removeAll { $0 == key }
        return true
    }

    /// Items a trigger holds right now, suspended or not.
    public var heldItems: Set<ItemKey> {
        Set(requested.show).union(requested.hide)
    }
}

extension TriggerAction {
    /// "show Docker", "hide Slack", "switch to Presenting".
    public var summary: String {
        summary(groups: [])
    }

    /// The summary with group names filled in: "show group Dev".
    public func summary(groups: [ItemGroup]) -> String {
        switch self {
        case .show(let key): "show \(key.description)"
        case .hide(let key): "hide \(key.description)"
        case .switchProfile(let name): "switch to \(name)"
        case .showGroup(let id): "show group \(groups.first { $0.id == id }?.name ?? "(removed)")"
        case .hideGroup(let id): "hide group \(groups.first { $0.id == id }?.name ?? "(removed)")"
        }
    }
}

extension Trigger {
    /// The name, or the action when the trigger has none.
    public var displayName: String {
        name.isEmpty ? action.summary : name
    }
}

extension Condition {
    /// True when the condition, or anything inside it, depends on the time of day, so the
    /// context has to be looked at again every minute.
    public var dependsOnTime: Bool {
        switch self {
        case .timeOfDay: true
        case .not(let inner): inner.dependsOnTime
        case .allOf(let inner), .anyOf(let inner): inner.contains { $0.dependsOnTime }
        default: false
        }
    }
}

/// `somabar://set?docker=on&vpn=off`: conditions switched from outside (`Condition.external`).
public enum ExternalConditionCommand {
    /// Parses a URL query into (name, on) pairs. A name with no value is switched on. Names are
    /// trimmed and lower-cased; empty names and unknown values are skipped.
    public static func parse(query: String?) -> [(name: String, isOn: Bool)] {
        guard let query, !query.isEmpty else { return [] }
        var result: [(name: String, isOn: Bool)] = []
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { continue }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces).lowercased() : "on"
            switch value {
            case "on", "1", "true", "yes": result.append((name, true))
            case "off", "0", "false", "no": result.append((name, false))
            default: continue
            }
        }
        return result
    }
}

/// Names of tunnel interfaces, for the VPN condition.
public enum TunnelInterfaces {
    /// `utun3`, `ipsec0`, `ppp0`, `tun0`, `tap0`, `wg0`.
    public static func isTunnel(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains { prefix in
            let rest = lowered.dropFirst(prefix.count)
            return lowered.hasPrefix(prefix) && !rest.isEmpty && rest.allSatisfy(\.isNumber)
        }
    }
}
