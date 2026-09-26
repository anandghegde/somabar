import CoreGraphics

/// Decides whether a point on the menu bar is on empty bar: right of the app's menus, not on a
/// status item, not on one of Somabar's visible items. Pure, so the gestures can be tested.
public enum EmptyBarHitTest {
    /// A collapsed divider is 10,000 pt wide and lies under the empty bar; anything of
    /// Somabar's wider than this is one of those, and a point over it still counts as empty.
    public static let maxOwnVisibleWidth: CGFloat = 100

    /// - Parameters:
    ///   - bar: The menu bar of the screen under the pointer, global top-left coordinates.
    ///   - statusWindows: Every status item window. On macOS 26 Control Center owns them all,
    ///     Somabar's included, so the ones under `ownFrames` are told apart here.
    ///   - ownFrames: Somabar's own item frames, dividers included.
    ///   - appMenusMaxX: Right edge of the active app's menu titles.
    public static func isEmpty(
        point: CGPoint, bar: CGRect, statusWindows: [StatusWindow], ownFrames: [CGRect], appMenusMaxX: CGFloat
    ) -> Bool {
        guard bar.contains(point), point.x > appMenusMaxX else { return false }
        if ownFrames.contains(where: { $0.width <= maxOwnVisibleWidth && $0.contains(point) }) { return false }
        let others = statusWindows.filter { window in !ownFrames.contains { isOwn($0, window: window) } }
        if others.contains(where: { $0.bounds.contains(point) }) { return false }
        return true
    }

    /// The window is one of Somabar's when an own frame's centre lies inside it on the same row.
    static func isOwn(_ frame: CGRect, window: StatusWindow) -> Bool {
        let bounds = window.bounds
        return frame.midX >= bounds.minX && frame.midX <= bounds.maxX && abs(frame.minY - bounds.minY) <= 2
    }
}
