import AppKit
import Observation
import os
import SomabarCore
import SwiftUI

/// M13: draws the menu bar style. On macOS 26 the menu bar is transparent, so a borderless
/// window just below the menu bar's level, covering the bar's strip on each display, shows
/// through it. The window takes no clicks, joins every Space and stays out of full-screen apps.
/// Nothing runs while both appearances are plain, or on a display whose menu bar hides itself.
@MainActor
final class MenuBarTint {
    private var windows: [NSWindow] = []
    private let model = MenuBarTintModel()
    private let log = Logger(subsystem: "app.somabar", category: "styling")

    /// Shows `style`, or removes the windows when it draws nothing. Call again when the
    /// displays change.
    func apply(_ style: MenuBarStyle) {
        model.style = style
        guard !style.isPlain else {
            removeAll()
            return
        }
        let frames = NSScreen.screens.compactMap(Self.menuBarFrame)
        guard frames != windows.map(\.frame) else { return }
        removeAll()
        windows = frames.map { makeWindow(frame: $0) }
        log.info("Menu bar style on \(self.windows.count) displays")
    }

    func stop() {
        removeAll()
    }

    private func removeAll() {
        for window in windows {
            window.orderOut(nil)
        }
        windows = []
    }

    /// The strip the menu bar takes on `screen`; nil when the menu bar hides itself there.
    private static func menuBarFrame(_ screen: NSScreen) -> NSRect? {
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        guard height > 0 else { return nil }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
    }

    private func makeWindow(frame: NSRect) -> NSWindow {
        let window = MenuBarTintWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: MenuBarTintView(model: model))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return window
    }
}

/// Flush with the top edge: AppKit would otherwise push the window below the menu bar.
private final class MenuBarTintWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
@Observable
final class MenuBarTintModel {
    var style = MenuBarStyle()
}

/// The tint and the hairline for the current appearance. Follows light and dark mode itself.
struct MenuBarTintView: View {
    let model: MenuBarTintModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let appearance = model.style.appearance(isDark: colorScheme == .dark)
        ZStack(alignment: .bottom) {
            tint(appearance)
            if appearance.hairline {
                Rectangle()
                    .fill(Color.primary.opacity(0.2))
                    .frame(height: 1 / max(displayScale, 1))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appearance)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tint(_ appearance: MenuBarStyle.Appearance) -> some View {
        switch appearance.tint {
        case .none:
            Color.clear
        case .accent:
            Color(nsColor: .controlAccentColor).opacity(appearance.strength)
        case .color:
            Color(.sRGB, red: appearance.color.red, green: appearance.color.green, blue: appearance.color.blue)
                .opacity(appearance.strength)
        }
    }
}
