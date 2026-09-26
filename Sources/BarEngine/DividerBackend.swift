import AppKit
import os
import SomabarCore

/// The macOS 26 backend.
///
/// Somabar owns three status items. From right to left: the glyph, the Hidden divider and the
/// Tucked divider. A divider is 8 pt wide when its section is revealed and 10,000 pt wide when
/// collapsed, which pushes every item to its left off the screen. The window server never
/// draws the extra width: the divider's image sits centred 5,000 pt off-screen.
///
/// Bar order, left to right: Locked, Tucked, [Tucked divider], Hidden, [Hidden divider], Shown,
/// [glyph], items macOS owns.
@MainActor
public final class DividerBackend: BarEngine {
    public static let collapsedLength: CGFloat = 10_000
    public static let dividerLength: CGFloat = 8
    public static let hairlineLength: CGFloat = 1

    static let controlAutosaveName = "somabar.control"
    static let hiddenAutosaveName = "somabar.divider.hidden"
    static let tuckedAutosaveName = "somabar.divider.tucked"
    static var autosaveNames: [String] { [controlAutosaveName, hiddenAutosaveName, tuckedAutosaveName] }

    public let capability: BarCapability = .full

    private var control: NSStatusItem?
    private var hiddenDivider: NSStatusItem?
    private var tuckedDivider: NSStatusItem?
    private let log = Logger(subsystem: "app.somabar", category: "DividerBackend")

    public private(set) var isHiddenRevealed = false
    public private(set) var isTuckedRevealed = false
    public var showsDividers = true {
        didSet { applyLengths() }
    }
    public var showsNewItemsDot = false {
        didSet { if showsNewItemsDot != oldValue { applyLengths() } }
    }
    public var onDividerClick: (@MainActor () -> Void)?

    public init() {}

    public var controlButton: NSStatusBarButton? { control?.button }

    public func ownWindow(_ item: OwnItem) -> StatusWindow? {
        let statusItem: NSStatusItem? = switch item {
        case .control: control
        case .hiddenDivider: hiddenDivider
        case .tuckedDivider: tuckedDivider
        }
        guard let frame = statusItem?.button?.window?.frame else { return nil }
        return StatusWindows.window(matching: ScreenGeometry.topLeft(frame), in: StatusWindows.all())
    }

    public var dividerBoundaries: DividerBoundaries? {
        guard let hidden = hiddenDivider?.button?.window?.frame,
              let tucked = tuckedDivider?.button?.window?.frame else { return nil }
        // x is the same in AppKit and window-server coordinates; only y flips.
        return DividerBoundaries(hidden: hidden.maxX, tucked: tucked.maxX)
    }

    public var ownFrames: [CGRect] {
        [control, hiddenDivider, tuckedDivider]
            .compactMap { $0?.button?.window?.frame }
            .map(ScreenGeometry.topLeft)
    }

    public func install() {
        guard control == nil else { return }
        let bar = NSStatusBar.system

        // Creation order matters: each new item lands left of the previous one. Positions are
        // remembered under the autosave names, so this only decides the first run.
        let control = bar.statusItem(withLength: NSStatusItem.squareLength)
        control.autosaveName = Self.controlAutosaveName
        control.button?.imagePosition = .imageOnly
        control.button?.toolTip = "Somabar. Click to reveal hidden items; right-click for the menu."

        let hidden = bar.statusItem(withLength: Self.dividerLength)
        hidden.autosaveName = Self.hiddenAutosaveName
        hidden.button?.imagePosition = .imageOnly
        hidden.button?.toolTip = "Items left of this line are Hidden. Hold ⌘ and drag to move them."

        let tucked = bar.statusItem(withLength: Self.dividerLength)
        tucked.autosaveName = Self.tuckedAutosaveName
        tucked.button?.imagePosition = .imageOnly
        tucked.button?.toolTip = "Items left of this line are Tucked."

        for divider in [hidden, tucked] {
            divider.button?.target = self
            divider.button?.action = #selector(dividerClicked(_:))
            divider.button?.sendAction(on: [.leftMouseUp])
        }

        self.control = control
        hiddenDivider = hidden
        tuckedDivider = tucked
        applyLengths()

        // The bar lays the items out over the next run loop turns; judge the order once it has.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.repairOrderIfNeeded()
        }
    }

    public func setHiddenRevealed(_ revealed: Bool) {
        guard revealed != isHiddenRevealed else { return }
        isHiddenRevealed = revealed
        applyLengths()
    }

    public func setTuckedRevealed(_ revealed: Bool) {
        guard revealed != isTuckedRevealed else { return }
        isTuckedRevealed = revealed
        applyLengths()
    }

    /// True when the glyph is right of the Hidden divider, which is right of the Tucked divider.
    /// Also true while the bar has not laid the items out yet (frames missing or stacked), so
    /// nothing is judged from stale geometry.
    public var isOrderCorrect: Bool {
        guard let control = control?.button?.window?.frame,
              let hidden = hiddenDivider?.button?.window?.frame,
              let tucked = tuckedDivider?.button?.window?.frame,
              control.width > 0, hidden.width > 0, tucked.width > 0,
              Set([control.minX, hidden.minX, tucked.minX]).count == 3 else { return true }
        return hidden.maxX <= control.minX + 0.5 && tucked.maxX <= hidden.minX + 0.5
    }

    /// The three frames, for the log.
    private var frameSummary: String {
        [("glyph", control), ("hidden", hiddenDivider), ("tucked", tuckedDivider)]
            .map { name, item in
                let frame = item?.button?.window?.frame ?? .null
                return "\(name) x=\(Int(frame.minX)) w=\(Int(frame.width))"
            }
            .joined(separator: ", ")
    }

    public func resetPositions() {
        let items = [control, hiddenDivider, tuckedDivider].compactMap { $0 }
        for item in items { item.isVisible = false }
        for name in Self.autosaveNames {
            UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position \(name)")
        }
        // Re-shown in creation order, each lands left of the last: glyph rightmost.
        for item in items { item.isVisible = true }
        applyLengths()
        log.notice("Reset the positions of Somabar's status items")
    }

    public func teardown() {
        // Everything back in view before the items go.
        isHiddenRevealed = true
        isTuckedRevealed = true
        applyLengths()
        for item in [control, hiddenDivider, tuckedDivider].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(item)
        }
        control = nil
        hiddenDivider = nil
        tuckedDivider = nil
    }

    // MARK: - Private

    /// A collapsed divider covers the empty bar, so a click on "nothing" lands here. ⌘-clicks are
    /// the person rearranging items, and clicks during a move are Somabar's own synthetic ones.
    @objc private func dividerClicked(_ sender: Any?) {
        log.info("Divider clicked; moving: \(ItemMover.isMoving), command: \(NSEvent.modifierFlags.contains(.command))")
        guard !ItemMover.isMoving else { return }
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.command) { return }
        onDividerClick?()
    }

    private func repairOrderIfNeeded() {
        guard control != nil else { return }
        log.info("Status item frames after install: \(self.frameSummary, privacy: .public)")
        guard !isOrderCorrect else { return }
        log.notice("Somabar's status items are out of order (\(self.frameSummary, privacy: .public)); resetting their positions")
        resetPositions()
    }

    private func applyLengths() {
        let visibleLength = showsDividers ? Self.dividerLength : Self.hairlineLength
        hiddenDivider?.length = isHiddenRevealed ? visibleLength : Self.collapsedLength
        tuckedDivider?.length = isTuckedRevealed ? visibleLength : Self.collapsedLength
        hiddenDivider?.button?.image = showsDividers ? Self.dividerImage(alpha: 0.55) : nil
        tuckedDivider?.button?.image = showsDividers ? Self.dividerImage(alpha: 0.3) : nil
        control?.button?.image = Self.glyph(revealed: isHiddenRevealed, dot: showsNewItemsDot)
    }

    /// The chevron, with a dot in its top-right corner while new items wait (M18). Both variants
    /// are drawn at a fixed size so the glyph never shifts when the dot comes and goes.
    static func glyph(revealed: Bool, dot: Bool) -> NSImage? {
        let name = revealed ? "chevron.right" : "chevron.left"
        let description = revealed ? "Hide items" : "Reveal hidden items"
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        guard let chevron = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration) else { return nil }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let origin = NSPoint(x: (size.width - chevron.size.width) / 2, y: (size.height - chevron.size.height) / 2)
            chevron.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            if dot {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: size.width - 5, y: size.height - 5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = dot ? "\(description). New items arrived" : description
        return image
    }

    private static func dividerImage(alpha: CGFloat) -> NSImage {
        let size = NSSize(width: dividerLength, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: NSRect(x: (size.width - 1) / 2, y: 2, width: 1, height: 14), xRadius: 0.5, yRadius: 0.5).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
