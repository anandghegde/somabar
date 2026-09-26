import AppKit

/// M17: synthetic input only runs while the person is not touching the Mac.
@MainActor
public enum InputSafety {
    /// No key may have gone down within this long.
    public static let quietKeyboardSeconds: Double = 0.5

    public enum Blocker: Equatable, Sendable {
        case mouseButtonDown
        case typing
        case pointerOnMenuBar
    }

    /// Empty when a move may start.
    public static func blockers() -> [Blocker] {
        var result: [Blocker] = []
        if CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right) {
            result.append(.mouseButtonDown)
        }
        if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < quietKeyboardSeconds {
            result.append(.typing)
        }
        if isPointerOnMenuBar() {
            result.append(.pointerOnMenuBar)
        }
        return result
    }

    public static var isIdle: Bool { blockers().isEmpty }

    /// True when the pointer is in the menu bar strip of whatever screen it is on.
    public static func isPointerOnMenuBar() -> Bool {
        let location = NSEvent.mouseLocation
        guard let screen = ScreenGeometry.screen(containingAppKitPoint: location) else { return false }
        return location.y >= screen.frame.maxY - ScreenGeometry.menuBarHeight(of: screen)
    }
}
