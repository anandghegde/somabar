import Foundation

/// When a revealed bar goes back to hidden (M3). The timer is the app's; the decisions are here.
public enum RehidePolicy {
    public enum Decision: Equatable, Sendable {
        case hide
        /// A menu hangs from the bar; hiding now would collapse the bar under it.
        case waitForMenu
        /// The pointer is on the bar; the person is still working there.
        case waitForPointer
    }

    /// After the last menu closes, this long before hiding.
    public static let afterMenuCloseSeconds: TimeInterval = 0.4

    /// An open menu wins over everything; then the pointer.
    public static func whenTimerFires(menuOpen: Bool, pointerOnBar: Bool) -> Decision {
        if menuOpen { return .waitForMenu }
        if pointerOnBar { return .waitForPointer }
        return .hide
    }

    /// How long after a menu closes to hide, or nil when the ordinary timer (or nothing) applies.
    /// "Rehide when a menu closes" shortens auto-rehide; it never hides a bar that auto-rehide leaves alone.
    public static func delayAfterMenuClosed(preferences: Preferences, revealed: Bool) -> TimeInterval? {
        guard revealed, preferences.rehideWhenMenuCloses, !preferences.stillMode, preferences.rehideAfterSeconds > 0 else {
            return nil
        }
        return afterMenuCloseSeconds
    }
}
