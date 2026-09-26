import CoreGraphics
import Foundation

/// One window at the status level. macOS gives every status item its own window at
/// `kCGStatusWindowLevel`, so listing windows finds every item, on or off screen, without any
/// permission. Titles and images need more; see `AccessibilityDiscovery`.
public struct StatusWindow: Equatable, Sendable {
    public var windowID: CGWindowID
    public var pid: pid_t
    public var ownerName: String
    /// Global coordinates, origin top-left.
    public var bounds: CGRect

    public init(windowID: CGWindowID, pid: pid_t, ownerName: String, bounds: CGRect) {
        self.windowID = windowID
        self.pid = pid
        self.ownerName = ownerName
        self.bounds = bounds
    }
}

public enum StatusWindows {
    /// `kCGStatusWindowLevel`, 25.
    public static let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
    /// The menu bar is 24 pt, or the height of the notch beside one. Nothing taller is an item.
    public static let maxHeight: CGFloat = 60

    /// Every status-level window, the caller's own included, left to right.
    public static func all() -> [StatusWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap(parse).sorted { $0.bounds.minX < $1.bounds.minX }
    }

    /// Every status-level window except the caller's own, left to right.
    public static func current(excludingPID pid: pid_t) -> [StatusWindow] {
        all().filter { $0.pid != pid }
    }

    /// The window whose bounds match an `NSStatusItem` frame (global, top-left). On macOS 26
    /// every status item window belongs to Control Center, so `NSWindow.windowNumber` is not
    /// the window server's ID; the frame is the only link. Same row, centre inside the frame,
    /// width within `tolerance`.
    public static func window(matching frame: CGRect, in windows: [StatusWindow], tolerance: CGFloat = 2) -> StatusWindow? {
        windows.first { window in
            abs(window.bounds.minY - frame.minY) <= tolerance
                && window.bounds.midX >= frame.minX && window.bounds.midX <= frame.maxX
                && abs(window.bounds.width - frame.width) <= tolerance
        }
    }

    static func parse(_ info: [String: Any]) -> StatusWindow? {
        guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == statusLevel,
              let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              bounds.height > 0, bounds.height <= maxHeight
        else { return nil }
        let owner = info[kCGWindowOwnerName as String] as? String ?? ""
        return StatusWindow(windowID: windowID, pid: pid, ownerName: owner, bounds: bounds)
    }
}
