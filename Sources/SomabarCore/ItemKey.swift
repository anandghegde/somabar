import Foundation

/// Identifies one menu bar item across launches.
///
/// `bundleID` is the owning app. `title` is the item's accessibility title, falling back to its
/// description or identifier, and may be empty. `ordinal` separates several same-titled items
/// from one app, counted left to right.
public struct ItemKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var bundleID: String
    public var title: String
    public var ordinal: Int

    public init(bundleID: String, title: String = "", ordinal: Int = 0) {
        self.bundleID = bundleID
        self.title = title
        self.ordinal = ordinal
    }

    public var description: String {
        let base = title.isEmpty ? bundleID : "\(bundleID)/\(title)"
        return ordinal == 0 ? base : "\(base)#\(ordinal)"
    }
}

/// Items that macOS owns. They appear in the layout editor marked "managed by macOS" and are
/// never moved.
public enum SystemItems {
    public static let controlCenter = "com.apple.controlcenter"
    public static let systemUIServer = "com.apple.systemuiserver"
    public static let spotlight = "com.apple.Spotlight"
    public static let siri = "com.apple.Siri"
    /// The agent whose item macOS shows while the screen is being shared; its presence in the
    /// bar is how the screen-sharing condition is read.
    public static let screenSharingAgent = "com.apple.SSMenuAgent"

    public static let managedBundleIDs: Set<String> = [controlCenter, systemUIServer, spotlight, siri]

    public static func isManagedByMacOS(_ key: ItemKey) -> Bool {
        managedBundleIDs.contains(key.bundleID)
    }

    /// Items the Presenting profile keeps in the bar: Clock, Battery, Wi-Fi and Control Center.
    /// Titles are matched loosely because Control Center's accessibility titles vary between
    /// locales and releases.
    public static func isPresentingEssential(_ key: ItemKey) -> Bool {
        guard key.bundleID == controlCenter else { return false }
        let title = normalized(key.title)
        return title.contains("clock")
            || title.contains("battery")
            || title.contains("wi-fi") || title.contains("wifi")
            || title.contains("control center") || title.contains("control centre")
    }

    public static func isClock(_ key: ItemKey) -> Bool {
        key.bundleID == controlCenter && normalized(key.title).contains("clock")
    }

    /// Items macOS keeps at the right end of the bar and never lets anyone drag: the Clock and
    /// the Control Center button. No profile can hide them.
    public static func isPinnedByMacOS(_ key: ItemKey) -> Bool {
        guard key.bundleID == controlCenter else { return false }
        let title = normalized(key.title)
        return title.contains("clock") || title.contains("control center") || title.contains("control centre")
    }

    private static func normalized(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: "\u{2011}", with: "-")  // non-breaking hyphen in "Wi‑Fi"
            .replacingOccurrences(of: "\u{2010}", with: "-")
    }
}
