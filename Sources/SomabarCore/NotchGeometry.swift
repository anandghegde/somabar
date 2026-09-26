import CoreGraphics

/// The shape of the top edge of one display, in that display's points with the origin at its
/// top-left corner. Built from `NSScreen` by the engine; pure here so it can be tested.
public struct NotchGeometry: Equatable, Sendable {
    public var screenWidth: CGFloat
    public var menuBarHeight: CGFloat
    /// The camera housing. nil on displays without a notch.
    public var notch: CGRect?
    /// True for the opt-in drawn notch on a display without one.
    public var isDrawn: Bool

    public static let maxCompactExtensionPerSide: CGFloat = 80
    /// Tall enough for the base panel and two live activity rows.
    public static let maxExpandedSize = CGSize(width: 520, height: 300)
    public static let drawnNotchSize = CGSize(width: 180, height: 32)

    public init(screenWidth: CGFloat, menuBarHeight: CGFloat, notch: CGRect?, isDrawn: Bool = false) {
        self.screenWidth = screenWidth
        self.menuBarHeight = menuBarHeight
        self.notch = notch
        self.isDrawn = isDrawn
    }

    /// The notch is the gap between the two auxiliary areas macOS reports beside it.
    public static func fromAuxiliaryAreas(
        screenWidth: CGFloat,
        menuBarHeight: CGFloat,
        left: CGRect?,
        right: CGRect?
    ) -> NotchGeometry {
        guard let left, let right, right.minX > left.maxX else {
            return NotchGeometry(screenWidth: screenWidth, menuBarHeight: menuBarHeight, notch: nil)
        }
        let notch = CGRect(x: left.maxX, y: 0, width: right.minX - left.maxX, height: menuBarHeight)
        return NotchGeometry(screenWidth: screenWidth, menuBarHeight: menuBarHeight, notch: notch)
    }

    /// A 180 × 32 pt pill centred on the menu bar.
    public static func drawn(screenWidth: CGFloat, menuBarHeight: CGFloat) -> NotchGeometry {
        let size = drawnNotchSize
        let notch = CGRect(x: (screenWidth - size.width) / 2, y: 0, width: size.width, height: size.height)
        return NotchGeometry(screenWidth: screenWidth, menuBarHeight: menuBarHeight, notch: notch, isDrawn: true)
    }

    public var hasSurface: Bool {
        notch != nil
    }

    /// The right edge of the notch: only items entirely to its right fit in the bar.
    public var notchMaxX: CGFloat? {
        notch?.maxX
    }

    /// Compact: the notch widened by up to 80 pt on each side, no taller than the menu bar.
    public func compactFrame(extensionPerSide: CGFloat) -> CGRect? {
        guard let notch else { return nil }
        let extra = min(max(extensionPerSide, 0), Self.maxCompactExtensionPerSide)
        return CGRect(x: notch.minX - extra, y: 0, width: notch.width + 2 * extra, height: max(notch.height, menuBarHeight))
    }

    /// Expanded: up to 520 × 180 pt, anchored to the camera's centre, flush with the top edge.
    public func expandedFrame(size requested: CGSize) -> CGRect? {
        guard let notch else { return nil }
        let size = CGSize(
            width: min(max(requested.width, notch.width), Self.maxExpandedSize.width),
            height: min(requested.height, Self.maxExpandedSize.height)
        )
        var x = notch.midX - size.width / 2
        x = min(max(x, 0), screenWidth - size.width)
        return CGRect(x: x, y: 0, width: size.width, height: size.height)
    }
}
