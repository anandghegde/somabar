import AppKit
import SomabarCore

/// Carries an `AXUIElement` inside Sendable values. Somabar only talks to the Accessibility API
/// from the main actor; the wrapper just lets the element ride along with a `DiscoveredItem`.
public final class AXHandle: @unchecked Sendable {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }
}

/// One status item found in the real menu bar.
public struct DiscoveredItem: Sendable, Identifiable {
    public var key: ItemKey
    public var pid: pid_t
    public var appName: String
    /// Global coordinates with the origin at the top-left of the primary display, as the window
    /// server and the Accessibility API report them.
    public var frame: CGRect
    public var windowID: CGWindowID
    /// The item's accessibility element, when Somabar is trusted.
    public var ax: AXHandle?
    /// False when Somabar can see the item but not which app it belongs to. On macOS 26 every
    /// status item window is hosted by Control Center, so without Accessibility access nothing
    /// third-party can be identified. Unidentified items are never written into a layout.
    public var isIdentified: Bool
    /// An Apple agent's item that Control Center hosts, such as Screen Sharing. It can be dragged
    /// behind a divider, but Control Center pulls it back into view when the divider collapses,
    /// so Somabar treats it like an item macOS manages.
    public var isHostedByMacOS: Bool

    public init(
        key: ItemKey, pid: pid_t, appName: String, frame: CGRect, windowID: CGWindowID,
        ax: AXHandle? = nil, isIdentified: Bool = true, isHostedByMacOS: Bool = false
    ) {
        self.key = key
        self.pid = pid
        self.appName = appName
        self.frame = frame
        self.windowID = windowID
        self.ax = ax
        self.isIdentified = isIdentified
        self.isHostedByMacOS = isHostedByMacOS
    }

    /// The key of an item whose app is unknown.
    public static let unknownBundleID = "unknown"

    public var id: CGWindowID { windowID }

    /// Never moved by Somabar: owned by macOS, or hosted by Control Center.
    public var isManagedByMacOS: Bool { SystemItems.isManagedByMacOS(key) || isHostedByMacOS }

    public var placed: PlacedItem { PlacedItem(key: key, frame: frame) }
}

/// Where the sections meet, in global top-left coordinates. Each value is the right edge of a
/// divider: items whose centre is left of it belong to the sections on the left.
public struct DividerBoundaries: Equatable, Sendable {
    public var hidden: CGFloat
    public var tucked: CGFloat

    public init(hidden: CGFloat, tucked: CGFloat) {
        self.hidden = hidden
        self.tucked = tucked
    }
}

public enum BarCapability: Equatable, Sendable {
    /// Hiding, revealing and moving work.
    case full
    /// Only Somabar's own glyph is in the bar; nothing can be hidden.
    case glyphOnly(reason: String)
}

/// Somabar's own status items, the drop targets when it moves other items.
public enum OwnItem: Sendable {
    case control
    case hiddenDivider
    case tuckedDivider
}

/// One backend per macOS version. This is the only code that knows how the bar hides and
/// moves items; everything above it speaks in sections.
@MainActor
public protocol BarEngine: AnyObject {
    var capability: BarCapability { get }

    /// Somabar's glyph. The app attaches its click handling and menu here.
    var controlButton: NSStatusBarButton? { get }

    var isHiddenRevealed: Bool { get }
    var isTuckedRevealed: Bool { get }
    /// M5: dividers can be hidden once the layout is set up.
    var showsDividers: Bool { get set }
    /// M18: a dot on the glyph while an item that arrived Shown waits to be noticed.
    var showsNewItemsDot: Bool { get set }

    /// Right edges of the two dividers; nil until installed or when the backend has none.
    var dividerBoundaries: DividerBoundaries? { get }

    /// Frames of Somabar's own status item windows in global top-left coordinates, so discovery
    /// can leave them out.
    var ownFrames: [CGRect] { get }

    /// A collapsed divider is 10,000 pt wide and covers the empty bar left of the items, so a
    /// click there reaches the divider, not a global mouse monitor. The backend reports it here.
    var onDividerClick: (@MainActor () -> Void)? { get set }

    /// The window-server window of one of Somabar's items, for use as a move target.
    func ownWindow(_ item: OwnItem) -> StatusWindow?

    /// Puts Somabar's items in the bar.
    func install()
    func setHiddenRevealed(_ revealed: Bool)
    func setTuckedRevealed(_ revealed: Bool)
    /// Forgets the remembered positions so the items line up again: glyph, then the dividers.
    func resetPositions()
    /// M19, fail visible: every item back in view, Somabar's own items removed.
    func teardown()
}

public enum BarEngineFactory {
    /// The backend for the running macOS. `SOMABAR_FORCE_DIVIDER=1` runs the macOS 26 backend
    /// on any version for testing.
    @MainActor
    public static func make() -> any BarEngine {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let forced = ProcessInfo.processInfo.environment["SOMABAR_FORCE_DIVIDER"] == "1"
        if version.majorVersion == 26 || forced {
            return DividerBackend()
        }
        return UnsupportedBackend(reason: "Somabar has no menu bar backend for macOS \(version.majorVersion) yet")
    }
}
