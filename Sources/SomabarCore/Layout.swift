/// Which section each item is in and the order within each section.
///
/// Items are stored left to right. The layout is the source of truth for the bar (M16): the
/// engine reconciles the real menu bar to it, never the other way around except when the user
/// arranges items by hand.
public struct Layout: Codable, Equatable, Sendable {
    public var shown: [ItemKey]
    public var hidden: [ItemKey]
    public var tucked: [ItemKey]
    public var locked: [ItemKey]

    public init(shown: [ItemKey] = [], hidden: [ItemKey] = [], tucked: [ItemKey] = [], locked: [ItemKey] = []) {
        self.shown = shown
        self.hidden = hidden
        self.tucked = tucked
        self.locked = locked
    }

    public subscript(section: Section) -> [ItemKey] {
        get {
            switch section {
            case .shown: shown
            case .hidden: hidden
            case .tucked: tucked
            case .locked: locked
            }
        }
        set {
            switch section {
            case .shown: shown = newValue
            case .hidden: hidden = newValue
            case .tucked: tucked = newValue
            case .locked: locked = newValue
            }
        }
    }

    /// Every item in bar order, left to right.
    public var allItems: [ItemKey] {
        Section.barOrder.flatMap { self[$0] }
    }

    public var isEmpty: Bool {
        Section.allCases.allSatisfy { self[$0].isEmpty }
    }

    public var count: Int {
        Section.allCases.reduce(0) { $0 + self[$1].count }
    }

    public func contains(_ key: ItemKey) -> Bool {
        section(of: key) != nil
    }

    public func section(of key: ItemKey) -> Section? {
        Section.allCases.first { self[$0].contains(key) }
    }

    /// Moves an item into `section`. `index` is the position within that section, counted from
    /// the left; nil appends at the far right of the section. Moving an item within its own
    /// section reorders it.
    public mutating func move(_ key: ItemKey, to section: Section, at index: Int? = nil) {
        remove(key)
        var items = self[section]
        let position = min(max(index ?? items.count, 0), items.count)
        items.insert(key, at: position)
        self[section] = items
    }

    public mutating func remove(_ key: ItemKey) {
        for section in Section.allCases {
            self[section].removeAll { $0 == key }
        }
    }

    /// Adds an item the layout does not know yet. Returns true when it was added.
    @discardableResult
    public mutating func insertIfNew(_ key: ItemKey, in section: Section) -> Bool {
        guard !contains(key) else { return false }
        self[section].append(key)
        return true
    }

    /// Keeps only the given items, in their current sections and order.
    public mutating func retain(_ keys: Set<ItemKey>) {
        for section in Section.allCases {
            self[section].removeAll { !keys.contains($0) }
        }
    }
}
