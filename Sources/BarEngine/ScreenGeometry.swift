import AppKit
import SomabarCore

/// Converts between AppKit's bottom-left screen coordinates and the top-left coordinates used
/// by the window server and the Accessibility API, and reads notch geometry from `NSScreen`.
@MainActor
public enum ScreenGeometry {
    /// The display whose AppKit origin is (0, 0). Global top-left coordinates hang off its top edge.
    public static var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }

    public static var primaryHeight: CGFloat { primaryScreen?.frame.height ?? 0 }

    /// AppKit → top-left. The same flip works in both directions.
    public static func topLeft(_ rect: CGRect) -> CGRect { flip(rect, primaryHeight: primaryHeight) }
    public static func appKit(_ rect: CGRect) -> CGRect { flip(rect, primaryHeight: primaryHeight) }

    public static func topLeft(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    nonisolated public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 24 pt, or the notch height beside a notch. Falls back to the status bar thickness when the
    /// menu bar is set to hide.
    public static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        return height > 0 ? height : NSStatusBar.system.thickness
    }

    /// The menu bar strip of a screen in top-left coordinates.
    public static func menuBarRect(of screen: NSScreen) -> CGRect {
        let height = menuBarHeight(of: screen)
        let strip = CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
        return topLeft(strip)
    }

    /// Notch geometry from the auxiliary areas macOS reports beside the camera housing.
    public static func notchGeometry(for screen: NSScreen) -> NotchGeometry {
        func local(_ rect: CGRect?) -> CGRect? {
            rect.map { CGRect(x: $0.minX - screen.frame.minX, y: 0, width: $0.width, height: $0.height) }
        }
        return NotchGeometry.fromAuxiliaryAreas(
            screenWidth: screen.frame.width,
            menuBarHeight: menuBarHeight(of: screen),
            left: local(screen.auxiliaryTopLeftArea),
            right: local(screen.auxiliaryTopRightArea)
        )
    }

    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    public static var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            displayID(of: screen).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
    }

    /// The screen a point in AppKit coordinates lies on, edges included.
    public static func screen(containingAppKitPoint point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            let frame = screen.frame
            return point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
        }
    }
}
