import Foundation

// MARK: - Groups (M9)

/// Items combined under one glyph ("Dev": Docker, Tailscale, GitHub). Clicking the glyph opens
/// a compact row of the members. A group's members always share one section in each profile,
/// so they move together.
public struct ItemGroup: Codable, Equatable, Identifiable, Sendable {
    /// The PRD's limit: up to 8 items per group.
    public static let maxMembers = 8

    public var id: UUID
    public var name: String
    /// One character is drawn as a letter; anything longer is an SF Symbol name. Empty means
    /// the first letter of the name.
    public var glyph: String
    public var members: [ItemKey]

    public init(id: UUID = UUID(), name: String, glyph: String = "", members: [ItemKey] = []) {
        self.id = id
        self.name = name
        self.glyph = glyph
        self.members = members
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, glyph, members
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        glyph = try container.decodeIfPresent(String.self, forKey: .glyph) ?? ""
        members = try container.decodeIfPresent([ItemKey].self, forKey: .members) ?? []
    }

    /// What the glyph shows.
    public enum Face: Equatable, Sendable {
        case letter(String)
        case symbol(String)
    }

    public var face: Face {
        let trimmed = glyph.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 1 {
            return .symbol(trimmed)
        }
        let letter = trimmed.isEmpty ? String(name.trimmingCharacters(in: .whitespaces).prefix(1)) : trimmed
        return .letter(letter.isEmpty ? "G" : letter.uppercased())
    }
}

public enum GroupEditError: Error, Equatable, Sendable {
    case emptyName
    case nameTaken
    case noSuchGroup
    /// More than `ItemGroup.maxMembers`.
    case tooManyMembers
}

extension SomabarDocument {
    public func group(id: UUID) -> ItemGroup? {
        groups.first { $0.id == id }
    }

    /// The group an item belongs to. An item is in at most one group.
    public func group(containing key: ItemKey) -> ItemGroup? {
        groups.first { $0.members.contains(key) }
    }

    /// Adds an empty group under a free name. Returns its id.
    @discardableResult
    public mutating func addGroup(baseName: String = "New Group") -> UUID {
        var name = baseName
        var number = 2
        while groups.contains(where: { $0.name == name }) {
            name = "\(baseName) \(number)"
            number += 1
        }
        let group = ItemGroup(name: name)
        groups.append(group)
        return group.id
    }

    public mutating func renameGroup(_ id: UUID, to newName: String) throws(GroupEditError) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .emptyName }
        guard let index = groups.firstIndex(where: { $0.id == id }) else { throw .noSuchGroup }
        guard !groups.contains(where: { $0.id != id && $0.name == trimmed }) else { throw .nameTaken }
        groups[index].name = trimmed
    }

    public mutating func setGroupGlyph(_ id: UUID, to glyph: String) throws(GroupEditError) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { throw .noSuchGroup }
        groups[index].glyph = glyph.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a group, the triggers that show or hide it, and its hot key. The members stay
    /// where they are.
    public mutating func removeGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        triggers.removeAll { $0.action.group == id }
        itemHotKeys.removeAll { $0.target == .group(id) }
    }

    /// Replaces a group's members. An item joins at most one group, so a member taken from
    /// another group leaves it. The members are then gathered into one section in every profile.
    public mutating func setGroupMembers(_ id: UUID, _ members: [ItemKey]) throws(GroupEditError) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { throw .noSuchGroup }
        var unique: [ItemKey] = []
        for key in members where !unique.contains(key) {
            unique.append(key)
        }
        guard unique.count <= ItemGroup.maxMembers else { throw .tooManyMembers }
        for other in groups.indices where other != index {
            groups[other].members.removeAll { unique.contains($0) }
        }
        groups[index].members = unique
        gatherGroup(id)
    }

    /// Puts every member of the group in one section of each profile: the section its first
    /// member (in the group's order) is in there.
    public mutating func gatherGroup(_ id: UUID) {
        guard let group = group(id: id) else { return }
        for index in profiles.indices {
            profiles[index].layout.gather(group.members, into: nil)
        }
    }

    /// Moves every member of the group into `section` in the active profile.
    public mutating func moveGroup(_ id: UUID, to section: Section) throws(GroupEditError) {
        guard let group = group(id: id) else { throw .noSuchGroup }
        var profile = active
        profile.layout.gather(group.members, into: section)
        update(profile)
    }

    /// The section the group's members share in the active profile; nil when none is placed.
    public func section(ofGroup id: UUID) -> Section? {
        guard let group = group(id: id) else { return nil }
        let layout = active.layout
        return group.members.lazy.compactMap { layout.section(of: $0) }.first
    }
}

extension Layout {
    /// Puts the given items in one section, next to each other, in the given order. The anchor
    /// is the first item the layout knows; it stays where it is and the rest follow it. With a
    /// `section`, the anchor moves there first (to the right end). Unknown items are skipped.
    public mutating func gather(_ keys: [ItemKey], into section: Section?) {
        let known = keys.filter { contains($0) }
        guard let anchor = known.first else { return }
        if let section, self.section(of: anchor) != section {
            move(anchor, to: section)
        }
        guard let target = self.section(of: anchor) else { return }
        var previous = anchor
        for key in known.dropFirst() {
            remove(key)
            let position = (self[target].firstIndex(of: previous) ?? self[target].count - 1) + 1
            move(key, to: target, at: position)
            previous = key
        }
    }

    /// After the person moved items by hand: every group with a moved member follows it into
    /// that member's section, placed beside it. Returns the members that followed.
    @discardableResult
    public mutating func keepGroupsTogether(_ groups: [ItemGroup], moved: [ItemKey]) -> [ItemKey] {
        var followed: [ItemKey] = []
        for group in groups {
            guard let leader = moved.first(where: { group.members.contains($0) }),
                  let section = section(of: leader) else { continue }
            let followers = group.members.filter { $0 != leader && contains($0) && self.section(of: $0) != section }
            guard !followers.isEmpty else { continue }
            var previous = leader
            for key in followers {
                remove(key)
                let position = (self[section].firstIndex(of: previous) ?? self[section].count - 1) + 1
                move(key, to: section, at: position)
                previous = key
            }
            followed += followers
        }
        return followed
    }
}

// MARK: - Per-item hot keys (M11)

/// What a per-item hot key opens.
public enum HotKeyTarget: Hashable, Sendable {
    case item(ItemKey)
    case group(UUID)
}

/// A shortcut that opens an item's menu, even when it is Hidden or behind the notch, or
/// reveals a group's section.
///
/// Stored flat so the file stays readable: `{"item": {...}, "combo": {...}}` or
/// `{"group": "UUID", "combo": {...}}`. A nil combo is a row still waiting for its shortcut.
public struct ItemHotKey: Codable, Equatable, Sendable {
    public var target: HotKeyTarget
    public var combo: KeyCombo?

    public init(target: HotKeyTarget, combo: KeyCombo?) {
        self.target = target
        self.combo = combo
    }

    private enum CodingKeys: String, CodingKey {
        case item, group, combo
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let key = try container.decodeIfPresent(ItemKey.self, forKey: .item) {
            target = .item(key)
        } else {
            target = .group(try container.decode(UUID.self, forKey: .group))
        }
        combo = try container.decodeIfPresent(KeyCombo.self, forKey: .combo)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch target {
        case .item(let key): try container.encode(key, forKey: .item)
        case .group(let id): try container.encode(id, forKey: .group)
        }
        try container.encodeIfPresent(combo, forKey: .combo)
    }
}

extension SomabarDocument {
    /// "Docker", "Tailscale · Exit node", or the group's name.
    public func label(for target: HotKeyTarget) -> String {
        switch target {
        case .item(let key):
            var label = key.title.isEmpty ? key.bundleID : "\(key.bundleID) · \(key.title)"
            if key.ordinal > 0 { label += " (\(key.ordinal + 1))" }
            return label
        case .group(let id):
            return "Group “\(group(id: id)?.name ?? "missing")”"
        }
    }

    public func combo(for target: HotKeyTarget) -> KeyCombo? {
        itemHotKeys.first { $0.target == target }?.combo
    }

    /// Adds a row for the target with no shortcut yet. Nothing changes when it has one.
    public mutating func addItemHotKey(for target: HotKeyTarget) {
        guard !itemHotKeys.contains(where: { $0.target == target }) else { return }
        itemHotKeys.append(ItemHotKey(target: target, combo: nil))
    }

    public mutating func removeItemHotKey(for target: HotKeyTarget) {
        itemHotKeys.removeAll { $0.target == target }
    }

    /// Gives the target a combo (nil clears it but keeps the row). A clashing combo is refused
    /// and the document is left as it was.
    @discardableResult
    public mutating func setCombo(_ combo: KeyCombo?, for target: HotKeyTarget) -> HotkeyClash? {
        if let combo, let clash = clash(for: combo, owner: .target(target)) {
            return clash
        }
        if let index = itemHotKeys.firstIndex(where: { $0.target == target }) {
            itemHotKeys[index].combo = combo
        } else {
            itemHotKeys.append(ItemHotKey(target: target, combo: combo))
        }
        return nil
    }

    /// Who would hold a combo: one of the actions, or an item or group.
    public enum HotkeyOwner: Equatable, Sendable {
        case action(HotkeyAction)
        case target(HotKeyTarget)
    }

    /// The clash `combo` would cause for `owner`: another action, another item or group, or a
    /// shortcut macOS keeps. Nil when it is free.
    public func clash(for combo: KeyCombo, owner: HotkeyOwner) -> HotkeyClash? {
        if let other = hotkeys.first(where: { owner != .action($0.action) && $0.combo == combo }) {
            return .action(other.action)
        }
        if let other = itemHotKeys.first(where: { owner != .target($0.target) && $0.combo == combo }) {
            return .item(label(for: other.target))
        }
        if let system = HotkeyClash.systemShortcuts.first(where: { $0.combo == combo }) {
            return .system(system.owner)
        }
        return nil
    }
}

// MARK: - Triggers on groups

extension TriggerAction {
    /// The group a show or hide acts on, if it acts on one.
    public var group: UUID? {
        switch self {
        case .showGroup(let id), .hideGroup(let id): id
        case .show, .hide, .switchProfile: nil
        }
    }
}
