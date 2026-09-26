import AppKit
import SomabarCore

/// M13: the menu bar style, wired to the controller.
extension SomabarController {
    /// One per app, like the activities. Kept outside the controller's body.
    static let menuBarTint = MenuBarTint()

    /// Draws the current style on every display, or removes it. Runs at launch, when the
    /// displays change and when the style is edited.
    func applyMenuBarStyle() {
        Self.menuBarTint.apply(document.preferences.menuBarStyle)
    }

    func stopMenuBarStyle() {
        Self.menuBarTint.stop()
    }
}
