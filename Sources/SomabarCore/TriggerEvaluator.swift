/// What the active triggers ask for right now.
public struct TriggerEffects: Equatable, Sendable {
    public var show: [ItemKey] = []
    public var hide: [ItemKey] = []
    public var profile: String?

    public init(show: [ItemKey] = [], hide: [ItemKey] = [], profile: String? = nil) {
        self.show = show
        self.hide = hide
        self.profile = profile
    }

    public var isEmpty: Bool {
        show.isEmpty && hide.isEmpty && profile == nil
    }
}

/// Pure evaluation of triggers against a snapshot. Nothing here touches the bar.
public struct TriggerEvaluator: Sendable {
    /// Routers the user has marked as known, by hardware address.
    public var knownRouters: Set<String>

    public init(knownRouters: Set<String> = []) {
        self.knownRouters = knownRouters
    }

    public func holds(_ condition: Condition, in context: ContextSnapshot) -> Bool {
        switch condition {
        case .powerSource(let source):
            return context.powerSource == source
        case .batteryBelow(let percent):
            guard let level = context.batteryPercent else { return false }
            return level < percent
        case .network(let network):
            return networkHolds(network, in: context)
        case .display(let display):
            switch display {
            case .builtInOnly: return !context.hasExternalDisplay
            case .externalConnected: return context.hasExternalDisplay
            case .widerThan(let points): return context.widestDisplayPoints > points
            }
        case .screenSharing:
            return context.isScreenShared
        case .mediaInUse(let device):
            switch device {
            case .microphone: return context.microphoneInUse
            case .camera: return context.cameraInUse
            case .either: return context.microphoneInUse || context.cameraInUse
            }
        case .appRunning(let bundleID):
            return context.runningApps.contains(bundleID)
        case .appFrontmost(let bundleID):
            return context.frontmostApp == bundleID
        case .focus(let name):
            guard let current = context.focus else { return false }
            return current.caseInsensitiveCompare(name) == .orderedSame
        case .timeOfDay(let range):
            return range.contains(minute: context.minuteOfDay)
        case .iconChanged(let key):
            return context.changedIcons.contains(key)
        case .external(let name):
            // `somabar://set` lower-cases names; a trigger may spell its own however it likes.
            return context.externalConditions.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        case .not(let inner):
            return !holds(inner, in: context)
        case .allOf(let inner):
            return inner.allSatisfy { holds($0, in: context) }
        case .anyOf(let inner):
            return inner.contains { holds($0, in: context) }
        }
    }

    private func networkHolds(_ network: NetworkCondition, in context: ContextSnapshot) -> Bool {
        let connected = context.isEthernet || context.isWiFi
        let routerKnown = context.routerAddress.map(knownRouters.contains) ?? false
        switch network {
        case .ethernet: return context.isEthernet
        case .wifi: return context.isWiFi
        case .vpn: return context.isVPN
        case .knownRouter: return routerKnown
        case .unknownNetwork: return connected && !routerKnown
        case .offline: return !connected
        }
    }

    /// Collects the effects of every enabled trigger whose condition holds.
    ///
    /// Show beats hide for the same item. When several triggers switch profile, the last one in
    /// list order wins. A group's show or hide acts on each of its members.
    public func effects(of triggers: [Trigger], in context: ContextSnapshot, groups: [ItemGroup] = []) -> TriggerEffects {
        var effects = TriggerEffects()
        for trigger in triggers where trigger.isEnabled && holds(trigger.condition, in: context) {
            switch trigger.action {
            case .show(let key):
                if !effects.show.contains(key) { effects.show.append(key) }
            case .hide(let key):
                if !effects.hide.contains(key) { effects.hide.append(key) }
            case .switchProfile(let name):
                effects.profile = name
            case .showGroup(let id):
                for key in groups.first(where: { $0.id == id })?.members ?? [] where !effects.show.contains(key) {
                    effects.show.append(key)
                }
            case .hideGroup(let id):
                for key in groups.first(where: { $0.id == id })?.members ?? [] where !effects.hide.contains(key) {
                    effects.hide.append(key)
                }
            }
        }
        effects.hide.removeAll { effects.show.contains($0) }
        return effects
    }
}

extension Layout {
    /// The layout as the bar should look while the effects hold.
    ///
    /// Shown items are inserted at the left end of Shown, next to the divider, so nothing the user
    /// can already see moves. Hidden items go to the right end of Hidden. Locked items are never
    /// shown by a trigger.
    public func applying(_ effects: TriggerEffects) -> Layout {
        var layout = self
        for key in effects.show {
            guard let current = layout.section(of: key), current != .shown, current != .locked else { continue }
            layout.move(key, to: .shown, at: 0)
        }
        for key in effects.hide where layout.section(of: key) == .shown {
            layout.move(key, to: .hidden)
        }
        return layout
    }
}
