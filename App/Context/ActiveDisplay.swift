import AppKit
import BarEngine

/// The display whose menu bar is active, for the "leave inactive displays' bars untouched" rule.
///
/// With "Displays have separate Spaces" on, every display has a menu bar and the active one is
/// where the person last worked: `NSScreen.main`. With it off, only the primary display has a
/// menu bar. The context monitor reads this on app activation, Space changes and display
/// changes, which are the moments the active menu bar moves.
@MainActor
enum ActiveDisplay {
    static var screen: NSScreen? {
        NSScreen.screensHaveSeparateSpaces ? (NSScreen.main ?? ScreenGeometry.primaryScreen) : ScreenGeometry.primaryScreen
    }

    /// 0 when there is no display.
    static var widthPoints: Int {
        Int(screen?.frame.width ?? 0)
    }
}
