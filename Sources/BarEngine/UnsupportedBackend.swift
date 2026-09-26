import AppKit

/// Used on a macOS version without a backend. Shows the glyph so the app is reachable, hides
/// nothing, and says why.
@MainActor
public final class UnsupportedBackend: BarEngine {
    public let capability: BarCapability
    private var control: NSStatusItem?

    public init(reason: String) {
        capability = .glyphOnly(reason: reason)
    }

    public var controlButton: NSStatusBarButton? { control?.button }
    public var isHiddenRevealed: Bool { true }
    public var isTuckedRevealed: Bool { true }
    public var showsDividers = false
    public var showsNewItemsDot = false
    public var dividerBoundaries: DividerBoundaries? { nil }
    public var ownFrames: [CGRect] {
        [control?.button?.window?.frame].compactMap { $0 }.map(ScreenGeometry.topLeft)
    }
    public var onDividerClick: (@MainActor () -> Void)?

    public func ownWindow(_ item: OwnItem) -> StatusWindow? { nil }

    public func install() {
        guard control == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = DividerBackend.controlAutosaveName
        item.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Somabar cannot manage this menu bar")
        item.button?.imagePosition = .imageOnly
        if case .glyphOnly(let reason) = capability {
            item.button?.toolTip = reason
        }
        control = item
    }

    public func setHiddenRevealed(_ revealed: Bool) {}
    public func setTuckedRevealed(_ revealed: Bool) {}
    public func resetPositions() {}

    public func teardown() {
        if let control {
            NSStatusBar.system.removeStatusItem(control)
        }
        control = nil
    }
}
