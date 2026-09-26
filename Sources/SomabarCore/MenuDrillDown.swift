import Foundation

/// A menu item's key equivalent, as Accessibility reports it (`AXMenuItemCmdChar` and
/// `AXMenuItemCmdModifiers`).
public struct MenuShortcut: Equatable, Sendable {
    public var key: String
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public var command: Bool

    public init(key: String, control: Bool = false, option: Bool = false, shift: Bool = false, command: Bool = true) {
        self.key = key
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
    }

    /// Decodes Accessibility's modifier mask: shift is 1, option 2, control 4, and 8 means *no*
    /// command, since ⌘ is the default. Nil when the item has no key.
    public init?(axKey: String?, axModifiers: Int) {
        guard let axKey, !axKey.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        self.init(
            key: axKey.uppercased(), control: axModifiers & 4 != 0, option: axModifiers & 2 != 0,
            shift: axModifiers & 1 != 0, command: axModifiers & 8 == 0
        )
    }

    /// The glyphs in the order macOS draws them in menus, ⌃⌥⇧⌘ then the key.
    public var displayString: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key
    }
}

/// One entry in a status item's menu, read through Accessibility.
public struct MenuEntry: Equatable, Sendable {
    /// Where the element sits: its index among the raw Accessibility children at each level,
    /// separators and custom views included. The app maps it back to the element to press.
    public var path: [Int]
    public var title: String
    public var isEnabled: Bool
    public var isChecked: Bool
    public var shortcut: MenuShortcut?
    /// A submenu's entries; empty for an item that acts when pressed.
    public var children: [MenuEntry]

    public init(path: [Int], title: String, isEnabled: Bool = true, isChecked: Bool = false, shortcut: MenuShortcut? = nil, children: [MenuEntry] = []) {
        self.path = path
        self.title = title
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.shortcut = shortcut
        self.children = children
    }

    public var hasSubmenu: Bool { !children.isEmpty }

    /// The title the palette shows: the first non-blank line, trimmed. Some apps put a
    /// multi-line status readout in a menu item. Nil for separators and untitled custom views,
    /// which the palette leaves out.
    public static func displayTitle(_ raw: String?) -> String? {
        raw?.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

/// One entry the palette lists, with the submenu titles between the current level and it.
public struct MenuMatch: Equatable, Sendable {
    public var entry: MenuEntry
    /// Empty for an entry at the current level.
    public var trail: [String]

    public init(entry: MenuEntry, trail: [String]) {
        self.entry = entry
        self.trail = trail
    }
}

/// Where the search palette is inside one status item's menu, and what it lists there. Pure,
/// so drilling and filtering are testable without Accessibility.
///
/// A blank query lists the current level. A query searches the current level and every
/// submenu below it, ranked like items (`ItemSearch`) on the entry's own title; ties keep menu
/// order, depth first.
public struct MenuDrillDown: Equatable, Sendable {
    /// One opened submenu, and the query and selection to put back when the person leaves it.
    public struct Level: Equatable, Sendable {
        public var entry: MenuEntry
        public var savedQuery: String
        public var savedSelection: Int?
    }

    public let itemName: String
    public let root: [MenuEntry]
    public private(set) var levels: [Level] = []

    public init(itemName: String, root: [MenuEntry]) {
        self.itemName = itemName
        self.root = root
    }

    /// The entries at the current level.
    public var entries: [MenuEntry] { levels.last?.entry.children ?? root }

    /// The item's name, then each opened submenu's title.
    public var breadcrumb: [String] { [itemName] + levels.map(\.entry.title) }

    public var isAtRoot: Bool { levels.isEmpty }

    public func matches(query: String) -> [MenuMatch] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return entries.map { MenuMatch(entry: $0, trail: []) }
        }
        let flat = Self.flatten(entries, trail: [])
        let candidates = flat.indices.map { SearchCandidate(id: $0, appName: flat[$0].entry.title, title: "", tag: .shown) }
        return ItemSearch.rank(candidates, query: query).map { flat[$0.id] }
    }

    /// Opens `entry`'s submenu. It may sit several levels down, as a search match can; each
    /// submenu on the way is opened too, so going back retraces them. `query` and `selection`
    /// are what to put back when the person comes back out. False when `entry` has no submenu
    /// or is not below the current level.
    @discardableResult
    public mutating func enter(_ entry: MenuEntry, query: String, selection: Int?) -> Bool {
        guard entry.hasSubmenu, let chain = Self.chain(to: entry.path, in: entries) else { return false }
        for (index, step) in chain.enumerated() {
            let isFirst = index == 0
            levels.append(Level(entry: step, savedQuery: isFirst ? query : "", savedSelection: isFirst ? selection : nil))
        }
        return true
    }

    /// Leaves the current submenu and returns the query and selection it was opened from. Nil at
    /// the top of the menu, where going back means leaving the menu altogether.
    public mutating func back() -> (query: String, selection: Int?)? {
        guard let level = levels.popLast() else { return nil }
        return (level.savedQuery, level.savedSelection)
    }

    // MARK: - Tree walking

    private static func flatten(_ entries: [MenuEntry], trail: [String]) -> [MenuMatch] {
        entries.flatMap { entry in
            [MenuMatch(entry: entry, trail: trail)] + flatten(entry.children, trail: trail + [entry.title])
        }
    }

    /// The submenus from `entries` down to the entry at `path`, that entry last.
    private static func chain(to path: [Int], in entries: [MenuEntry]) -> [MenuEntry]? {
        for entry in entries {
            if entry.path == path {
                return [entry]
            }
            if path.starts(with: entry.path), let rest = chain(to: path, in: entry.children) {
                return [entry] + rest
            }
        }
        return nil
    }
}
