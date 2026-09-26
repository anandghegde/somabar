import Foundation

// MARK: - Groups in the Items window

/// One section of the bar as the Items window lists it: each group with members there, under
/// its own header, then the items in no group.
public struct GroupedItems: Equatable, Sendable {
    public struct Block: Equatable, Identifiable, Sendable {
        public var group: ItemGroup
        /// The members in this section, left to right as in the layout.
        public var members: [ItemKey]

        public var id: UUID { group.id }
    }

    /// Ordered by each group's leftmost member, so the list reads like the bar.
    public var blocks: [Block]
    /// Left to right.
    public var ungrouped: [ItemKey]

    /// `keys` are one section's items, left to right. A group with no member among them is
    /// left out; one split across sections (a member not gathered yet) shows in each.
    public init(keys: [ItemKey], groups: [ItemGroup]) {
        var blocks: [Block] = []
        var ungrouped: [ItemKey] = []
        for key in keys {
            guard let group = groups.first(where: { $0.members.contains(key) }) else {
                ungrouped.append(key)
                continue
            }
            if let index = blocks.firstIndex(where: { $0.group.id == group.id }) {
                blocks[index].members.append(key)
            } else {
                blocks.append(Block(group: group, members: [key]))
            }
        }
        self.blocks = blocks
        self.ungrouped = ungrouped
    }
}

extension SomabarDocument {
    /// Adds an item to a group from the Items window. It leaves any other group, and joins the
    /// section the group's members are in (`setGroupMembers` gathers them). Nothing changes when
    /// it is already a member.
    public mutating func assign(_ key: ItemKey, toGroup id: UUID) throws(GroupEditError) {
        guard let group = group(id: id) else { throw .noSuchGroup }
        guard !group.members.contains(key) else { return }
        try setGroupMembers(id, group.members + [key])
    }

    /// Takes an item out of its group. It stays where it is in every profile.
    public mutating func removeFromGroup(_ key: ItemKey) {
        for index in groups.indices {
            groups[index].members.removeAll { $0 == key }
        }
    }
}
