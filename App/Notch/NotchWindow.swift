import AppKit
import SwiftUI

/// The borderless panel the notch surface draws in.
///
/// Non-activating, so a click on it never takes focus from the front app; at `.statusBar`
/// level, above the menu bar and below menus. It stays the same size while visible (the canvas
/// every notch state fits in) and lets clicks through wherever the pointer is not on the black
/// shape, by toggling `ignoresMouseEvents` from the pointer monitor.
final class NotchWindow: NSPanel {
    init(frame: NSRect, model: NotchModel) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NotchHostingView(rootView: NotchRootView(model: model))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Flush with the top edge: AppKit would otherwise push the panel below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Takes the first click, so the profile and timer buttons work while another app is active.
final class NotchHostingView: NSHostingView<NotchRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
