public enum Modifier: String, Codable, CaseIterable, Sendable, Comparable {
    case control
    case option
    case shift
    case command

    /// Display order, matching how macOS draws shortcuts: ⌃⌥⇧⌘.
    public var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    public static func < (lhs: Modifier, rhs: Modifier) -> Bool {
        let order = Modifier.allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

/// A keyboard shortcut, stored in words so the .somabar file stays readable.
///
/// `key` is a single lowercase character ("b", "/") or a name: "up", "down", "left", "right",
/// "space", "return", "escape", "tab", "delete", "f1" to "f20".
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var modifiers: [Modifier]

    public init(key: String, modifiers: [Modifier]) {
        self.key = key.lowercased()
        self.modifiers = Array(Set(modifiers)).sorted()
    }

    /// "⌃⌥B"
    public var display: String {
        let mods = modifiers.map(\.symbol).joined()
        let keyName: String
        switch key {
        case "up": keyName = "↑"
        case "down": keyName = "↓"
        case "left": keyName = "←"
        case "right": keyName = "→"
        case "space": keyName = "Space"
        case "return": keyName = "↩"
        case "escape": keyName = "⎋"
        case "tab": keyName = "⇥"
        case "delete": keyName = "⌫"
        default: keyName = key.uppercased()
        }
        return mods + keyName
    }
}

public enum HotkeyAction: String, Codable, CaseIterable, Sendable {
    case toggleHidden
    case searchItems
    case openTray
    case cycleProfile
    case startTimer25

    public var displayName: String {
        switch self {
        case .toggleHidden: "Toggle hidden"
        case .searchItems: "Search items"
        case .openTray: "Open tray"
        case .cycleProfile: "Cycle profile"
        case .startTimer25: "Start 25-minute timer"
        }
    }
}

public struct Hotkey: Codable, Equatable, Sendable {
    public var action: HotkeyAction
    /// nil means unassigned.
    public var combo: KeyCombo?

    public init(action: HotkeyAction, combo: KeyCombo?) {
        self.action = action
        self.combo = combo
    }

    /// The defaults from the PRD.
    public static let defaults: [Hotkey] = [
        Hotkey(action: .toggleHidden, combo: KeyCombo(key: "b", modifiers: [.control, .option])),
        Hotkey(action: .searchItems, combo: KeyCombo(key: "/", modifiers: [.control, .option])),
        Hotkey(action: .openTray, combo: KeyCombo(key: "down", modifiers: [.control, .option])),
        Hotkey(action: .cycleProfile, combo: KeyCombo(key: "p", modifiers: [.control, .option])),
        Hotkey(action: .startTimer25, combo: nil),
    ]
}
