import Foundation

/// A user-given name for an item, so search can match "vpn" to Tailscale.
public struct ItemAlias: Codable, Equatable, Sendable {
    public var item: ItemKey
    public var aliases: [String]

    public init(item: ItemKey, aliases: [String]) {
        self.item = item
        self.aliases = aliases
    }
}

public enum DocumentError: Error, Equatable, Sendable {
    /// The file was written by a newer Somabar.
    case newerFormat(version: Int)
    case noProfiles
}

/// The `.somabar` file: layout, profiles, triggers and hotkeys in one human-readable JSON
/// document (M15). It can live in iCloud Drive to sync across Macs without a server.
public struct SomabarDocument: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var version: Int
    public var activeProfile: String
    public var profiles: [Profile]
    public var triggers: [Trigger]
    public var hotkeys: [Hotkey]
    public var aliases: [ItemAlias]
    public var preferences: Preferences
    /// The profile that was active before a trigger switched profiles; restored when the
    /// trigger ends. Nil when no trigger holds a profile (`TriggerRuntime`).
    public var profileBeforeTriggers: String?
    /// Items combined under one glyph (M9, `ItemGroups.swift`). Shared by every profile; each
    /// profile's layout keeps a group's members in one section.
    public var groups: [ItemGroup]
    /// Shortcuts that open one item or group (M11).
    public var itemHotKeys: [ItemHotKey]

    public init(
        version: Int = SomabarDocument.formatVersion,
        activeProfile: String,
        profiles: [Profile],
        triggers: [Trigger] = [],
        hotkeys: [Hotkey] = Hotkey.defaults,
        aliases: [ItemAlias] = [],
        preferences: Preferences = Preferences(),
        profileBeforeTriggers: String? = nil,
        groups: [ItemGroup] = [],
        itemHotKeys: [ItemHotKey] = []
    ) {
        self.version = version
        self.activeProfile = activeProfile
        self.profiles = profiles
        self.triggers = triggers
        self.hotkeys = hotkeys
        self.aliases = aliases
        self.preferences = preferences
        self.profileBeforeTriggers = profileBeforeTriggers
        self.groups = groups
        self.itemHotKeys = itemHotKeys
    }

    private enum CodingKeys: String, CodingKey {
        case version, activeProfile, profiles, triggers, hotkeys, aliases, preferences, profileBeforeTriggers, groups, itemHotKeys
    }

    // Files written before groups and item hot keys existed have neither key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        activeProfile = try container.decode(String.self, forKey: .activeProfile)
        profiles = try container.decode([Profile].self, forKey: .profiles)
        triggers = try container.decode([Trigger].self, forKey: .triggers)
        hotkeys = try container.decode([Hotkey].self, forKey: .hotkeys)
        aliases = try container.decode([ItemAlias].self, forKey: .aliases)
        preferences = try container.decode(Preferences.self, forKey: .preferences)
        profileBeforeTriggers = try container.decodeIfPresent(String.self, forKey: .profileBeforeTriggers)
        groups = try container.decodeIfPresent([ItemGroup].self, forKey: .groups) ?? []
        itemHotKeys = try container.decodeIfPresent([ItemHotKey].self, forKey: .itemHotKeys) ?? []
    }

    /// True when any enabled trigger has to be looked at again as the clock moves.
    public var triggersDependOnTime: Bool {
        triggers.contains { $0.isEnabled && $0.condition.dependsOnTime }
    }

    /// Three profiles derived from one layout, default hotkeys, no triggers.
    public static func makeDefault(layout: Layout = Layout()) -> SomabarDocument {
        SomabarDocument(
            activeProfile: Profile.everydayName,
            profiles: [
                .everyday(layout: layout),
                .presenting(from: layout),
                .focus(from: layout),
            ]
        )
    }

    // MARK: Profiles

    public var active: Profile {
        get { profile(named: activeProfile) ?? profiles[0] }
        set { update(newValue) }
    }

    public func profile(named name: String) -> Profile? {
        profiles.first { $0.name == name }
    }

    public mutating func update(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    /// The profile after the active one, wrapping around.
    public var nextProfileName: String {
        guard let index = profiles.firstIndex(where: { $0.name == activeProfile }) else {
            return profiles.first?.name ?? activeProfile
        }
        return profiles[(index + 1) % profiles.count].name
    }

    // MARK: Items

    /// Records items that appeared for the first time. Each profile places them where its
    /// `newItemsGoTo` says, or beside the rest of their group. Returns the keys that were new
    /// to the active profile.
    @discardableResult
    public mutating func insertNewItems(_ keys: [ItemKey]) -> [ItemKey] {
        var newInActive: [ItemKey] = []
        for index in profiles.indices {
            for key in keys {
                let layout = profiles[index].layout
                let groupSection = group(containing: key)?.members.lazy.compactMap { layout.section(of: $0) }.first
                let added = profiles[index].layout.insertIfNew(key, in: groupSection ?? profiles[index].newItemsGoTo)
                if added && profiles[index].name == activeProfile { newInActive.append(key) }
            }
        }
        return newInActive
    }

    /// Removes every item of one app. Returns how many went. A file that learned Somabar's own
    /// glyph and dividers while a second copy ran is healed with this at launch.
    @discardableResult
    public mutating func forgetItems(ofApp bundleID: String) -> Int {
        let keys = Set(profiles.flatMap { profile in Section.allCases.flatMap { profile.layout[$0] } }.filter { $0.bundleID == bundleID })
        for key in keys {
            forget(key)
        }
        return keys.count
    }

    /// Removes an item from every profile, alias, trigger, group and hot key.
    public mutating func forget(_ key: ItemKey) {
        for index in profiles.indices {
            profiles[index].layout.remove(key)
            profiles[index].notchGuarded.removeAll { $0.key == key }
        }
        aliases.removeAll { $0.item == key }
        triggers.removeAll { trigger in
            switch trigger.action {
            case .show(let k), .hide(let k): k == key
            case .switchProfile, .showGroup, .hideGroup: false
            }
        }
        for index in groups.indices {
            groups[index].members.removeAll { $0 == key }
        }
        itemHotKeys.removeAll { $0.target == .item(key) }
    }

    public func combo(for action: HotkeyAction) -> KeyCombo? {
        hotkeys.first { $0.action == action }?.combo
    }

    // MARK: JSON

    /// Pretty-printed with sorted keys, so the file diffs and syncs cleanly.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SomabarDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(SomabarDocument.self, from: data)
        guard document.version <= formatVersion else {
            throw DocumentError.newerFormat(version: document.version)
        }
        guard !document.profiles.isEmpty else {
            throw DocumentError.noProfiles
        }
        return document
    }
}
