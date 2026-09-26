/// The four sections. Sections are the whole mental model; everything else builds on them.
public enum Section: String, Codable, CaseIterable, Sendable, Comparable {
    /// Always in the menu bar.
    case shown
    /// Out of the bar until revealed; rehides automatically.
    case hidden
    /// Never inline; only in the tray or search.
    case tucked
    /// Like Tucked, but opening requires Touch ID or the password.
    case locked

    /// Left-to-right order in the bar.
    public static let barOrder: [Section] = [.locked, .tucked, .hidden, .shown]

    public static func < (lhs: Section, rhs: Section) -> Bool {
        lhs.barIndex < rhs.barIndex
    }

    var barIndex: Int {
        Self.barOrder.firstIndex(of: self) ?? 0
    }

    public var displayName: String {
        switch self {
        case .shown: "Shown"
        case .hidden: "Hidden"
        case .tucked: "Tucked"
        case .locked: "Locked"
        }
    }

    /// Sections whose items never appear inline in the bar.
    public var isAlwaysHidden: Bool {
        self == .tucked || self == .locked
    }
}
