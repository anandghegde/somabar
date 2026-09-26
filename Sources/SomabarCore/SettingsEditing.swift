import Foundation

// The editing rules behind the Settings window, kept here so they are unit-tested rather than
// buried in SwiftUI views.

// MARK: - Hot keys

/// Why a combo cannot be used for an action.
public enum HotkeyClash: Equatable, Sendable {
    /// Another of Somabar's actions already has it.
    case action(HotkeyAction)
    /// macOS or a well-known system feature owns it.
    case system(String)
    /// An item's or group's own hot key has it; the label names which.
    case item(String)

    /// Combos macOS keeps for itself. Carbon lets an app register some of them, and then one of
    /// the two silently loses.
    public static let systemShortcuts: [(combo: KeyCombo, owner: String)] = [
        (KeyCombo(key: "space", modifiers: [.command]), "Spotlight"),
        (KeyCombo(key: "space", modifiers: [.option, .command]), "Finder search"),
        (KeyCombo(key: "space", modifiers: [.control]), "Input source switching"),
        (KeyCombo(key: "space", modifiers: [.control, .command]), "Emoji & Symbols"),
        (KeyCombo(key: "tab", modifiers: [.command]), "The app switcher"),
        (KeyCombo(key: "3", modifiers: [.shift, .command]), "Screenshot"),
        (KeyCombo(key: "4", modifiers: [.shift, .command]), "Screenshot"),
        (KeyCombo(key: "5", modifiers: [.shift, .command]), "Screenshot"),
        (KeyCombo(key: "q", modifiers: [.control, .command]), "Lock Screen"),
    ]

    /// The clash `combo` would cause if given to `action`, or nil when it is free.
    public static func find(_ combo: KeyCombo, for action: HotkeyAction, in hotkeys: [Hotkey]) -> HotkeyClash? {
        if let other = hotkeys.first(where: { $0.action != action && $0.combo == combo }) {
            return .action(other.action)
        }
        if let system = systemShortcuts.first(where: { $0.combo == combo }) {
            return .system(system.owner)
        }
        return nil
    }

    public var message: String {
        switch self {
        case .action(let other): "Already used for “\(other.displayName)”"
        case .system(let owner): "\(owner) uses this shortcut"
        case .item(let label): "Already opens \(label)"
        }
    }
}

extension SomabarDocument {
    /// Gives `action` a combo (nil clears it). A clashing combo is refused and the document is
    /// left as it was.
    @discardableResult
    public mutating func setCombo(_ combo: KeyCombo?, for action: HotkeyAction) -> HotkeyClash? {
        if let combo, let clash = clash(for: combo, owner: .action(action)) {
            return clash
        }
        if let index = hotkeys.firstIndex(where: { $0.action == action }) {
            hotkeys[index].combo = combo
        } else {
            hotkeys.append(Hotkey(action: action, combo: combo))
        }
        return nil
    }
}

// MARK: - Profiles

public enum ProfileEditError: Error, Equatable, Sendable {
    case emptyName
    case nameTaken
    case lastProfile
    case noSuchProfile
}

extension SomabarDocument {
    /// Renames a profile and every reference to it: the active profile, the profile a trigger
    /// will go back to, and triggers that switch to it.
    public mutating func renameProfile(_ oldName: String, to newName: String) throws(ProfileEditError) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyName }
        guard let index = profiles.firstIndex(where: { $0.name == oldName }) else { throw .noSuchProfile }
        guard trimmed != oldName else { return }
        guard profile(named: trimmed) == nil else { throw .nameTaken }
        profiles[index].name = trimmed
        if activeProfile == oldName { activeProfile = trimmed }
        if profileBeforeTriggers == oldName { profileBeforeTriggers = trimmed }
        for triggerIndex in triggers.indices {
            if case .switchProfile(let name) = triggers[triggerIndex].action, name == oldName {
                triggers[triggerIndex].action = .switchProfile(name: trimmed)
            }
        }
    }

    /// Removes a profile. The last one stays. When the active profile goes, the first remaining
    /// one becomes active. Triggers that switch to it are kept: they log that the profile is
    /// missing, and the person can point them elsewhere.
    public mutating func removeProfile(named name: String) throws(ProfileEditError) {
        guard profiles.count > 1 else { throw .lastProfile }
        guard let index = profiles.firstIndex(where: { $0.name == name }) else { throw .noSuchProfile }
        profiles.remove(at: index)
        if activeProfile == name { activeProfile = profiles[0].name }
        if profileBeforeTriggers == name { profileBeforeTriggers = nil }
    }

    /// Adds a copy of `source` (or the active profile) under a free name based on `baseName`.
    /// Returns the new profile's name.
    @discardableResult
    public mutating func addProfile(basedOn source: String? = nil, baseName: String = "New Profile") -> String {
        let template = source.flatMap { profile(named: $0) } ?? active
        let name = freeProfileName(baseName)
        profiles.append(Profile(name: name, layout: template.layout, newItemsGoTo: template.newItemsGoTo, notch: template.notch))
        return name
    }

    /// "New Profile", then "New Profile 2", "New Profile 3"…
    public func freeProfileName(_ base: String) -> String {
        guard profile(named: base) != nil else { return base }
        var number = 2
        while profile(named: "\(base) \(number)") != nil { number += 1 }
        return "\(base) \(number)"
    }
}

// MARK: - Trigger conditions

/// How the leaves of an edited condition combine. One level deep is all the editor offers;
/// deeper conditions stay editable in the file.
public enum ConditionMatch: String, CaseIterable, Sendable {
    /// `allOf`, or the single leaf itself.
    case all
    /// `anyOf`, or the single leaf itself.
    case any
    /// `not` of the leaf, or `not(anyOf)` of several.
    case none
}

/// The leaf conditions a person can pick. `iconChanged` is the one that needs Screen Recording.
public enum ConditionKind: String, CaseIterable, Identifiable, Sendable {
    case powerSource
    case batteryBelow
    case network
    case display
    case screenSharing
    case mediaInUse
    case appRunning
    case appFrontmost
    case focus
    case timeOfDay
    case external
    case iconChanged

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .powerSource: "Power source is"
        case .batteryBelow: "Battery below"
        case .network: "Network is"
        case .display: "Display"
        case .screenSharing: "The screen is shared"
        case .mediaInUse: "In use"
        case .appRunning: "App is running"
        case .appFrontmost: "App is in front"
        case .focus: "Focus is"
        case .timeOfDay: "Time of day"
        case .external: "Set by a script"
        case .iconChanged: "Item icon changes"
        }
    }
}

/// `DisplayCondition` without its associated value, for a picker.
public enum DisplayKind: String, CaseIterable, Sendable {
    case builtInOnly
    case externalConnected
    case widerThan
}

/// One leaf condition as the editor holds it: every field any kind might need, so switching
/// kinds back and forth keeps what was typed.
public struct LeafConditionDraft: Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: ConditionKind
    public var powerSource: PowerSource = .battery
    public var percent = 20
    public var network: NetworkCondition = .wifi
    public var display: DisplayKind = .externalConnected
    public var points = 2000
    public var media: MediaDevice = .either
    public var bundleID = ""
    /// The Focus name or the external condition's name.
    public var name = ""
    public var fromMinute = 19 * 60
    public var toMinute = 7 * 60
    /// The item whose icon is watched; nil until one is picked.
    public var item: ItemKey?

    public static let powerSources: [PowerSource] = [.battery, .adapter]
    public static let networks: [NetworkCondition] = [.ethernet, .wifi, .vpn, .knownRouter, .unknownNetwork, .offline]
    public static let mediaDevices: [MediaDevice] = [.microphone, .camera, .either]

    public init(kind: ConditionKind) {
        self.kind = kind
    }

    /// Nil for conditions that are not leaves, or that the editor does not offer.
    public init?(_ condition: Condition) {
        switch condition {
        case .powerSource(let source): self.init(kind: .powerSource); powerSource = source
        case .batteryBelow(let value): self.init(kind: .batteryBelow); percent = value
        case .network(let value): self.init(kind: .network); network = value
        case .display(let value):
            self.init(kind: .display)
            switch value {
            case .builtInOnly: display = .builtInOnly
            case .externalConnected: display = .externalConnected
            case .widerThan(let width): display = .widerThan; points = width
            }
        case .screenSharing: self.init(kind: .screenSharing)
        case .mediaInUse(let device): self.init(kind: .mediaInUse); media = device
        case .appRunning(let id): self.init(kind: .appRunning); bundleID = id
        case .appFrontmost(let id): self.init(kind: .appFrontmost); bundleID = id
        case .focus(let focus): self.init(kind: .focus); name = focus
        case .timeOfDay(let range): self.init(kind: .timeOfDay); fromMinute = range.fromMinute; toMinute = range.toMinute
        case .external(let external): self.init(kind: .external); name = external
        case .iconChanged(let key): self.init(kind: .iconChanged); item = key
        case .not, .allOf, .anyOf: return nil
        }
    }

    public var condition: Condition {
        switch kind {
        case .powerSource: .powerSource(powerSource)
        case .batteryBelow: .batteryBelow(percent: percent)
        case .network: .network(network)
        case .display:
            switch display {
            case .builtInOnly: .display(.builtInOnly)
            case .externalConnected: .display(.externalConnected)
            case .widerThan: .display(.widerThan(points: points))
            }
        case .screenSharing: .screenSharing
        case .mediaInUse: .mediaInUse(media)
        case .appRunning: .appRunning(bundleID: bundleID.trimmingCharacters(in: .whitespaces))
        case .appFrontmost: .appFrontmost(bundleID: bundleID.trimmingCharacters(in: .whitespaces))
        case .focus: .focus(name: name.trimmingCharacters(in: .whitespaces))
        case .timeOfDay: .timeOfDay(TimeRange(fromMinute: fromMinute, toMinute: toMinute))
        case .external: .external(name: name.trimmingCharacters(in: .whitespaces))
        // `isComplete` is false without an item, so the empty key is never saved.
        case .iconChanged: .iconChanged(item ?? ItemKey(bundleID: ""))
        }
    }

    /// False while a field the kind needs is still empty.
    public var isComplete: Bool {
        switch kind {
        case .appRunning, .appFrontmost: !bundleID.trimmingCharacters(in: .whitespaces).isEmpty
        case .focus, .external: !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .iconChanged: item != nil
        default: true
        }
    }
}

/// A condition the editor can show: a combinator and a list of leaves.
public struct ConditionDraft: Equatable, Sendable {
    public var match: ConditionMatch
    public var leaves: [LeafConditionDraft]

    public init(match: ConditionMatch = .all, leaves: [LeafConditionDraft] = [LeafConditionDraft(kind: .external)]) {
        self.match = match
        self.leaves = leaves
    }

    /// Nil when the condition is deeper than the editor goes.
    public init?(_ condition: Condition) {
        switch condition {
        case .allOf(let inner), .anyOf(let inner):
            let leaves = inner.compactMap(LeafConditionDraft.init)
            guard leaves.count == inner.count, !leaves.isEmpty else { return nil }
            if case .allOf = condition { self.init(match: .all, leaves: leaves) } else { self.init(match: .any, leaves: leaves) }
        case .not(.anyOf(let inner)):
            let leaves = inner.compactMap(LeafConditionDraft.init)
            guard leaves.count == inner.count, !leaves.isEmpty else { return nil }
            self.init(match: .none, leaves: leaves)
        case .not(let inner):
            guard let leaf = LeafConditionDraft(inner) else { return nil }
            self.init(match: .none, leaves: [leaf])
        default:
            guard let leaf = LeafConditionDraft(condition) else { return nil }
            self.init(match: .all, leaves: [leaf])
        }
    }

    /// Nil while the draft has no leaves or a leaf is incomplete.
    public var condition: Condition? {
        guard !leaves.isEmpty, leaves.allSatisfy(\.isComplete) else { return nil }
        let conditions = leaves.map(\.condition)
        if conditions.count == 1 {
            return match == .none ? .not(conditions[0]) : conditions[0]
        }
        switch match {
        case .all: return .allOf(conditions)
        case .any: return .anyOf(conditions)
        case .none: return .not(.anyOf(conditions))
        }
    }
}
