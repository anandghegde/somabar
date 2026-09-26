import CoreGraphics

/// An item and where it is in the bar right now. Frames use the top-left origin; only x matters.
public struct PlacedItem: Equatable, Sendable {
    public var key: ItemKey
    public var frame: CGRect

    public init(key: ItemKey, frame: CGRect) {
        self.key = key
        self.frame = frame
    }
}

/// An item the guard moved out of Shown, with the width it needs to come back.
public struct GuardedItem: Equatable, Codable, Sendable {
    public var key: ItemKey
    public var width: CGFloat

    public init(key: ItemKey, width: CGFloat) {
        self.key = key
        self.width = width
    }
}

public struct NotchGuardPlan: Equatable, Sendable {
    /// Shown → Hidden, nearest the divider first.
    public var hide: [GuardedItem] = []
    /// Guarded → Shown, the most recently guarded first. Each goes to the left end of Shown.
    public var restore: [ItemKey] = []

    public init(hide: [GuardedItem] = [], restore: [ItemKey] = []) {
        self.hide = hide
        self.restore = restore
    }

    public var isEmpty: Bool {
        hide.isEmpty && restore.isEmpty
    }
}

/// M6. Detects Shown items that fall under the camera housing and decides what to move.
///
/// macOS lays status items out from the right, so the items that do not fit are the leftmost
/// Shown ones, nearest the divider. Priority is position: the further right an item sits, the
/// longer it stays, so the layout editor is also the priority editor.
public enum NotchGuard {
    /// - Parameters:
    ///   - shown: the Shown items, left to right, with their current frames.
    ///   - notchMaxX: the right edge of the notch in the same coordinates.
    ///   - guarded: items the guard moved earlier, oldest first.
    public static func plan(shown: [PlacedItem], notchMaxX: CGFloat, guarded: [GuardedItem]) -> NotchGuardPlan {
        let ordered = shown.sorted { $0.frame.minX < $1.frame.minX }
        let covered = ordered.filter { $0.frame.minX < notchMaxX }
        if !covered.isEmpty {
            return NotchGuardPlan(hide: covered.map { GuardedItem(key: $0.key, width: $0.frame.width) })
        }

        // Space frees up: give back the most recently moved item first, while it fits.
        var free = (ordered.first?.frame.minX ?? .greatestFiniteMagnitude) - notchMaxX
        var restore: [ItemKey] = []
        for item in guarded.reversed() {
            guard item.width <= free else { break }
            restore.append(item.key)
            free -= item.width
        }
        return NotchGuardPlan(restore: restore)
    }
}
