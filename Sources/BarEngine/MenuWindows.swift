import CoreGraphics
import Foundation

/// An open menu as the window server sees it: a window at the pop-up menu level, owned by the
/// app whose menu it is. Status item menus, app menus and Somabar's own glyph menu all look
/// alike here, which is what auto-rehide needs (M3: never collapse the bar under an open menu).
public struct MenuWindow: Equatable, Sendable {
    public var windowID: CGWindowID
    public var pid: pid_t
    /// Global coordinates, origin top-left.
    public var bounds: CGRect

    public init(windowID: CGWindowID, pid: pid_t, bounds: CGRect) {
        self.windowID = windowID
        self.pid = pid
        self.bounds = bounds
    }
}

public enum MenuWindows {
    /// `kCGPopUpMenuWindowLevel`, 101.
    public static let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
    /// A status item's menu opens about 7 pt under the bar on macOS 26; allow some room.
    public static let hangSlack: CGFloat = 20

    /// The menus open right now whose top edge hangs from one of the given bars.
    public static func open(hangingFrom bars: [CGRect]) -> [MenuWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap(parse).filter { menu in bars.contains { hangs(menu.bounds, from: $0) } }
    }

    static func parse(_ info: [String: Any]) -> MenuWindow? {
        guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == popUpLevel,
              let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              bounds.width > 0, bounds.height > 0
        else { return nil }
        return MenuWindow(windowID: windowID, pid: pid, bounds: bounds)
    }

    /// True when the menu's top sits just under the bar and the two overlap horizontally.
    public static func hangs(_ menu: CGRect, from bar: CGRect) -> Bool {
        menu.minY >= bar.maxY - 2 && menu.minY <= bar.maxY + hangSlack
            && menu.maxX > bar.minX && menu.minX < bar.maxX
    }
}
